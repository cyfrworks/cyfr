# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairedClients do
  @moduledoc """
  The paired clients' rows (`Arca.Schemas.PairedClient`): one row per
  client a person holds in an athanor, carrying the credential it stands
  on (`source_kind`, `source_id`), a paired device's public key
  (`device_public_key`, for a `device_cert` client) and its `standing`,
  which alone decides what the client may do. A protected device also
  carries what it reports holds its key (`holder_kind`, `chip` or
  `software`) and the name it shows (`display_name`): information a person
  reads in their devices, never an input to a decision.
  Sanctum is the one caller above this layer (`Sanctum.Pairing`); the rows
  are security rows no domain or surface names.

  ## Standing

  `active`, `suspended` or `revoked`, and nothing leaves `revoked`.
  `revoke/2` ends one row; a standing transition revokes a person's rows,
  and every row of an athanor it archives, in its own transaction
  (`Arca.SecurityTransitions`). Each revocation raises `updated_at`, which
  is when the row was retired, and revokes the client's device
  certificates (`Arca.DeviceCertificates`), voids the pending
  confirmations it confirmed (`Arca.PendingConfirmations`), deletes the
  sessions its unlock created (`Arca.SessionStorage`) and its PIN
  evaluators (`Arca.DevicePinEvaluators`) in the same transaction.

  A declared restore suspends every active row (`Arca.SecurityTransitions`):
  a suspended client stands for nothing, is listed only when its standing
  is asked for (`:suspended` or `:all`), and becomes active again only by
  `reenable/4`, which also closes its person's restore. A suspended row may
  still be revoked, and a revoked one is never re-enabled.

  ## Ownership

  Recording a client, and re-enabling one, widen what may be confirmed,
  so `record/2` and `reenable/4` run in a locking transaction that checks
  the member still owns its slot (`Arca.ControlPlane.verify_held/1`)
  before it writes: a stale owner writes nothing. A revocation only
  narrows, and is never refused for ownership.

  Every function takes the actor first. An athanor actor reads and writes
  its own athanor's rows; `list/2` also takes the platform system actor,
  for one person's rows in every athanor. Rows are answered as plain
  maps (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.{DeviceCertificates, PendingConfirmations, QueryHelpers}
  alias Arca.Schemas.{DeviceCertificate, PairedClient}

  @required ~w(user_id source_kind source_id)a
  @optional ~w(device_public_key holder_kind display_name)a
  @max_display_name 64

  @typedoc "A paired client row, as a plain map."
  @type row :: %{
          id: String.t(),
          athanor_id: String.t(),
          user_id: String.t(),
          source_kind: String.t(),
          source_id: String.t(),
          device_public_key: binary() | nil,
          standing: String.t(),
          holder_kind: String.t() | nil,
          display_name: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc """
  What `list/2` narrows by: `user_id` (one person's clients) and
  `standing` (`:active`, the default, `:suspended`, `:revoked` or `:all`).
  """
  @type filters :: [user_id: String.t(), standing: :active | :suspended | :revoked | :all]

  @doc """
  The paired clients of the actor's athanor, oldest first, narrowed by
  `filters` (`t:filters/0`). The platform system actor reads one person's
  clients in every athanor, and must name the person (`user_id`).
  """
  @spec list(Prima.Actor.t(), filters()) ::
          {:ok, [row()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor, filters)
      when is_binary(athanor_id) and athanor_id != "" and is_list(filters) do
    listed(QueryHelpers.where_tenant(PairedClient, actor), filters)
  end

  def list(%Prima.Actor{scope: :platform, system: true}, filters) when is_list(filters) do
    case Keyword.get(filters, :user_id) do
      user_id when is_binary(user_id) and user_id != "" -> person_listed(filters)
      _no_person -> {:error, :no_athanor}
    end
  end

  def list(%Prima.Actor{}, filters) when is_list(filters), do: {:error, :no_athanor}

  @doc """
  Re-enable the suspended client `id` of the person `user_id` in the
  actor's athanor, in one locking transaction that checks first that this
  member still owns its slot (`Arca.Repo.owned/2`), since a standing
  client widens what may be confirmed: the person's row locked first, the
  head of the standing order a confirmation's consumption also takes, then
  the client's, then `opts[:verify]` handed it as a plain map (anything but `:ok` rolls back
  with that reason), then the row written `active`, and the person's open
  restore closed in the same transaction
  (`Arca.SecurityTransitions.close_restore!/1`), since a re-enabled method
  ends their recovery. Answers the row with `closed_restore_ids`, the
  restores it closed (none when the person had no open row).

  Refusals: `:not_found` (no such row of that person in the athanor),
  `:revoked` (never revived), `:passkey_holder` (a passkey's platform
  holder moves with its credential, `Arca.Passkeys.reenable/4`),
  `:not_suspended`, `:no_athanor`,
  `:not_owner`, `:database_error`, or the verifier's reason.
  """
  @spec reenable(Prima.Actor.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :revoked
             | :not_suspended
             | :no_athanor
             | :not_owner
             | :database_error
             | term()}
  # arca:db-raise-ok the read and the write run inside `Arca.Repo.owned/2`, which rescues around its transaction.
  def reenable(%Prima.Actor{athanor_id: athanor_id} = actor, user_id, id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and is_binary(id) and
             is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.owned("Arca.PairedClients.reenable", fn ->
      _locked = Arca.DirectoryHeads.lock_person!(user_id)

      PairedClient
      |> QueryHelpers.where_tenant(actor)
      |> where([p], p.id == ^id and p.user_id == ^user_id)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()
      |> reenabled(verify)
    end)
  end

  def reenable(%Prima.Actor{}, _user_id, _id, _opts), do: {:error, :no_athanor}

  @doc """
  Record a client of the person `attrs.user_id` in the actor's athanor:
  the credential it stands on (`source_kind`, `"session"`, `"api_key"` or
  `"device_cert"`, and `source_id`), each required, and for a
  `device_cert` client the device's 32-byte `device_public_key`
  (required) and, optionally, the `id` a pairing invitation or an
  enrollment reserved for it, the `holder_kind` a protected device reports
  and the `display_name` it shows. The row starts `active`.

  Refused with `:no_athanor` for an actor that names none, `{:invalid,
  errors}` for a missing or malformed field, `:conflict` for a credential
  (or a reserved id) the athanor already records a client for,
  `:not_owner` on a member that no longer owns its slot, and
  `:database_error` when the store cannot answer.
  """
  @spec record(Prima.Actor.t(), map()) ::
          {:ok, row()}
          | {:error, :no_athanor | :conflict | :not_owner | :database_error | {:invalid, map()}}
  # arca:db-raise-ok the insert runs inside `owned/2`, which rescues around its transaction.
  def record(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    changeset =
      changeset(
        Map.get(attrs, :id),
        QueryHelpers.stamp_tenant!(actor, Map.take(attrs, @required ++ @optional))
      )

    if changeset.valid? do
      Arca.Repo.owned("Arca.PairedClients.record", fn ->
        case Arca.Repo.insert(changeset) do
          {:ok, row} ->
            {:ok, row}

          {:error, %Ecto.Changeset{errors: errors} = changeset} ->
            conflict_or_invalid(errors, changeset)
        end
      end)
    else
      {:error, Arca.Data.invalid(changeset)}
    end
  end

  def record(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc """
  Enroll a protected device's client in the actor's athanor: `record/2`'s
  row, its `attrs` the same, written under the person's lock, the order
  every first method takes (`Arca.DirectoryHeads.lock_person!/1`), with
  the first-method mark (`Arca.PersonIdentities.first_method!/1`).
  `first_method: :claim` enrolls only the person's first method, refused
  `:first_method_used` once the mark is set; `:mark` sets it if unset and
  enrolls either way. `also:` runs after the insert, handed the row, and
  answers `{:ok, _}` or `{:error, reason}`, which rolls the enrollment
  back: the certificate is issued and recorded in the same transaction.
  Refused as `record/2` is.
  """
  @spec enroll(Prima.Actor.t(), map(), keyword()) ::
          {:ok, row()}
          | {:error,
             :no_athanor
             | :conflict
             | :not_owner
             | :first_method_used
             | :database_error
             | {:invalid, map()}
             | term()}
  # arca:db-raise-ok the insert runs inside `owned/2`, which rescues around its transaction.
  def enroll(%Prima.Actor{athanor_id: athanor_id} = actor, %{user_id: user_id} = attrs, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and is_list(opts) do
    first = Keyword.fetch!(opts, :first_method)
    also = Keyword.fetch!(opts, :also)

    changeset =
      changeset(
        Map.get(attrs, :id),
        QueryHelpers.stamp_tenant!(actor, Map.take(attrs, @required ++ @optional))
      )

    if changeset.valid? do
      Arca.Repo.owned("Arca.PairedClients.enroll", fn ->
        _locked = Arca.DirectoryHeads.lock_person!(user_id)

        with :ok <- first_method(user_id, first),
             {:ok, row} <- inserted(changeset),
             {:ok, _also} <- also.(Arca.Data.project(row)) do
          {:ok, row}
        end
      end)
    else
      {:error, Arca.Data.invalid(changeset)}
    end
  end

  def enroll(%Prima.Actor{}, _attrs, _opts), do: {:error, :no_athanor}

  @doc """
  The device client an enrollment committed under the request id
  `request_id` (its `source_id`), in whichever athanor: for the platform's
  own actor, which a lost enrollment answer is resumed under before any
  context exists. `{:error, :not_found}` when none.
  """
  @spec enrolled(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  # arca:unscoped-ok an enrollment is resumed by its request id and the proof of its key before any context exists; only the platform's own actor asks.
  def enrolled(%Prima.Actor{scope: :platform, system: true}, request_id)
      when is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairedClients.enrolled", fn ->
      case Arca.Repo.one(
             from(p in PairedClient,
               where:
                 p.source_kind == "device_cert" and p.source_id == ^request_id and
                   not is_nil(p.holder_kind),
               order_by: [asc: p.inserted_at],
               limit: 1
             )
           ) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def enrolled(%Prima.Actor{}, _request_id), do: {:error, :cross_tenant}

  @doc """
  Revoke the row `id` in the actor's athanor, with its device
  certificates, the confirmations it confirmed and the sessions its unlock
  created, whose token hashes the row answers as `revoked_session_hashes`
  for the caller to drop from every memo; revoking a revoked row answers
  it as it is, with none. A passkey's platform holder is refused
  `:passkey_holder`: it is revoked with its credential
  (`Arca.Passkeys.revoke/3`).
  """
  @spec revoke(Prima.Actor.t(), String.t()) ::
          {:ok, row()}
          | {:error, :not_found | :passkey_holder | :no_athanor | :database_error}
  def revoke(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairedClients.revoke", fn ->
      Arca.Repo.locking_transaction(fn ->
        PairedClient
        |> QueryHelpers.where_tenant(actor)
        |> where([p], p.id == ^id)
        |> QueryHelpers.for_update()
        |> Arca.Repo.one()
        |> case do
          nil ->
            {:error, :not_found}

          %PairedClient{standing: "revoked"} = row ->
            {:ok, Map.put(row, :revoked_session_hashes, [])}

          # A passkey's platform holder is revoked with its credential
          # (`Arca.Passkeys.revoke/3`), never apart from it.
          %PairedClient{source_kind: "passkey"} ->
            {:error, :passkey_holder}

          row ->
            retire(row)
        end
      end)
      |> case do
        {:ok, {:ok, row}} -> {:ok, row}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Arca.Data.project()
  end

  def revoke(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc false
  @spec revoke_all(Ecto.Queryable.t()) :: [String.t()]
  # Revoke every active row `query` names, in the caller's transaction or
  # its own statement, answering the ids it revoked, sorted. The one
  # revocation statement: `Arca.SecurityTransitions` runs it inside a
  # standing transition's transaction, and retires the certificates and
  # confirmations of the ids it answers there.
  # arca:unscoped-ok the caller's query carries its own scope: an athanor or a person.
  # arca:db-raise-ok a transaction step: its callers rescue around it, so a raise rolls a transition back.
  def revoke_all(query) do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(p in query, where: p.standing != "revoked", select: p.id),
        set: [standing: "revoked", updated_at: now]
      )

    Enum.sort(ids || [])
  end

  @doc false
  @spec retire_dependents!([String.t()]) :: %{
          certificate_ids: [String.t()],
          confirmation_ids: [String.t()],
          session_hashes: [binary()]
        }
  # What a client's revocation takes with it, in the caller's transaction:
  # its PIN evaluators, the certificates issued to the revoked clients, the
  # confirmations they confirmed and the sessions their unlock created,
  # whose token hashes the caller drops from every memo once it commits.
  def retire_dependents!([]), do: %{certificate_ids: [], confirmation_ids: [], session_hashes: []}

  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def retire_dependents!(client_ids) do
    # A revoked client's PIN evaluators go with it, so its identifier
    # evaluates nothing again (`Arca.DevicePinEvaluators`).
    _evaluators = Arca.DevicePinEvaluators.delete_clients!(client_ids)

    certificates =
      DeviceCertificates.revoke_all(
        from(c in DeviceCertificate, where: c.paired_client_id in ^client_ids)
      )

    %{
      certificate_ids: certificates.certificate_ids,
      confirmation_ids: PendingConfirmations.void_confirmed_by!(:paired_client, client_ids),
      # The certificates' revocation deleted the sessions of a client still
      # certified; the rest go here. Both hand their hashes on.
      session_hashes:
        Enum.uniq(certificates.session_hashes ++ Arca.SessionStorage.delete_clients!(client_ids))
    }
  end

  @doc false
  @spec project_passkey!(map()) :: %{session_hashes: [binary()]}
  # The passkey `passkey` projected as its platform holder, in the caller's
  # transaction, after the credential's own write and under its person's
  # lock: one row per credential, in the person's own athanor, with
  # `holder_kind` `platform`, `source_kind` `passkey`, the credential's id
  # as `source_id` and no key, so it is listed beside the person's devices
  # and a passkey sign-in's session names it, and never signs as a device.
  # Its standing follows the credential's: written `active` when the
  # credential first stands, moved to `suspended` or `active` with it, and
  # revoked with it, terminally, with what a client's revocation takes
  # (`retire_dependents!/1`), whose session hashes the caller drops once it
  # commits. A pending credential has none yet; a person with no athanor
  # of their own has none at all.
  # arca:unscoped-ok one person's row, named by the credential it projects.
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def project_passkey!(%{id: passkey_id, user_id: user_id, state: state}) do
    existing =
      from(p in PairedClient,
        where: p.user_id == ^user_id and p.source_kind == "passkey" and p.source_id == ^passkey_id
      )
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    now = Arca.ServerMetaStorage.now!()

    case {existing, state} do
      {nil, "active"} ->
        insert_platform!(passkey_id, user_id, now)
        %{session_hashes: []}

      {nil, _not_standing} ->
        %{session_hashes: []}

      {%PairedClient{standing: "revoked"}, _any} ->
        %{session_hashes: []}

      {%PairedClient{} = row, "revoked"} ->
        set_standing!(row, "revoked", now)
        %{session_hashes: retire_dependents!([row.id]).session_hashes}

      {%PairedClient{} = row, standing} when standing in ["active", "suspended"] ->
        if row.standing != standing, do: set_standing!(row, standing, now)
        %{session_hashes: []}

      {%PairedClient{}, "pending"} ->
        %{session_hashes: []}
    end
  end

  defp insert_platform!(passkey_id, user_id, now) do
    case Arca.Repo.one(
           from(u in Arca.Schemas.User, where: u.id == ^user_id, select: u.personal_athanor_id)
         ) do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        Arca.Repo.insert_all(PairedClient, [
          %{
            id: Prima.UUID7.generate_id("pcl"),
            athanor_id: athanor_id,
            user_id: user_id,
            source_kind: "passkey",
            source_id: passkey_id,
            standing: "active",
            holder_kind: "platform",
            display_name: "Passkey",
            inserted_at: now,
            updated_at: now
          }
        ])

      _none ->
        :ok
    end
  end

  defp set_standing!(row, standing, now) do
    from(p in PairedClient, where: p.id == ^row.id)
    |> Arca.Repo.update_all(set: [standing: standing, updated_at: now])
  end

  # ---- internals -------------------------------------------------------------

  # arca:unscoped-ok the caller's query carries its scope: the actor's athanor, or one person (`list/2`).
  defp listed(query, filters) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairedClients.list", fn ->
      rows =
        query
        |> by_user(Keyword.get(filters, :user_id))
        |> by_standing(Keyword.get(filters, :standing, :active))
        |> order_by([p], asc: p.inserted_at, asc: p.id)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  # One person's clients in every athanor, for the platform's own actor:
  # `by_user/2` narrows the query to the person `list/2` required.
  defp person_listed(filters), do: listed(PairedClient, filters)

  # The row read and locked under the actor's athanor and the person
  # (`reenable/4`): only a suspended one moves, and only once the verifier
  # admits it; its person's restore closes with it, after the row's lock,
  # as every re-enabling write orders them: the person, the item, the
  # restore row, then the kit's.
  defp reenabled(nil, _verify), do: {:error, :not_found}
  defp reenabled(%PairedClient{standing: "revoked"}, _verify), do: {:error, :revoked}
  defp reenabled(%PairedClient{source_kind: "passkey"}, _verify), do: {:error, :passkey_holder}

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`reenable/4`).
  defp reenabled(%PairedClient{standing: "suspended"} = row, verify) do
    with :ok <- verified(verify.(Arca.Data.project(row))),
         {:ok, active} <-
           row
           |> Ecto.Changeset.change(standing: "active", updated_at: Arca.ServerMetaStorage.now!())
           |> Arca.Repo.update() do
      closed = Arca.SecurityTransitions.close_restore!(active.user_id)
      {:ok, active |> Arca.Data.project() |> Map.put(:closed_restore_ids, closed)}
    end
  end

  defp reenabled(%PairedClient{}, _verify), do: {:error, :not_suspended}

  defp first_method(user_id, claim) when claim in [:claim, :mark] do
    case {Arca.PersonIdentities.first_method!(user_id), claim} do
      {:marked, _claim} -> :ok
      {:already, :mark} -> :ok
      {:already, :claim} -> {:error, :first_method_used}
      {:no_identity, _claim} -> {:error, :no_identity}
    end
  end

  defp inserted(changeset) do
    case Arca.Repo.insert(changeset) do
      {:ok, row} ->
        {:ok, row}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        conflict_or_invalid(errors, changeset)
    end
  end

  defp verified(:ok), do: :ok
  defp verified({:error, reason}), do: {:error, reason}
  defp verified(other), do: {:error, other}

  defp changeset(id, attrs) do
    id = if is_binary(id) and String.starts_with?(id, "pcl_"), do: id, else: nil

    %PairedClient{id: id || Prima.UUID7.generate_id("pcl")}
    |> Ecto.Changeset.cast(attrs, [:athanor_id | @required ++ @optional])
    |> Ecto.Changeset.validate_required([:athanor_id | @required])
    |> Ecto.Changeset.validate_inclusion(:source_kind, PairedClient.source_kinds())
    |> validate_device_key()
    |> validate_holder()
    |> Ecto.Changeset.unique_constraint([:athanor_id, :source_kind, :source_id])
    |> Ecto.Changeset.unique_constraint(:id, name: :paired_clients_pkey)
    |> Ecto.Changeset.unique_constraint(:id, name: :paired_clients_id_index)
  end

  # A device client carries the key it proved possession of; no other
  # client carries one.
  defp validate_device_key(changeset) do
    key = Ecto.Changeset.get_field(changeset, :device_public_key)

    case Ecto.Changeset.get_field(changeset, :source_kind) do
      "device_cert" ->
        if is_binary(key) and byte_size(key) == 32,
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :device_public_key, "is a 32-byte key")

      _other ->
        if is_nil(key),
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :device_public_key, "is a device client's")
    end
  end

  # What holds a protected device's key, and the name it shows, are a
  # device client's alone, and only as reported.
  defp validate_holder(changeset) do
    changeset =
      changeset
      |> Ecto.Changeset.validate_inclusion(:holder_kind, PairedClient.holder_kinds())
      |> Ecto.Changeset.validate_length(:display_name, min: 1, max: @max_display_name)
      |> Ecto.Changeset.validate_format(:display_name, ~r/\A[^\p{Cc}]+\z/u)

    reported? = Enum.any?([:holder_kind, :display_name], &Ecto.Changeset.get_field(changeset, &1))

    if reported? and Ecto.Changeset.get_field(changeset, :source_kind) != "device_cert",
      do: Ecto.Changeset.add_error(changeset, :holder_kind, "is a device client's"),
      else: changeset
  end

  defp conflict_or_invalid(errors, changeset) do
    if Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end),
      do: {:error, :conflict},
      else: {:error, Arca.Data.invalid(changeset)}
  end

  defp by_user(query, nil), do: query

  defp by_user(query, user_id) when is_binary(user_id),
    do: where(query, [p], p.user_id == ^user_id)

  defp by_standing(query, :all), do: query
  defp by_standing(query, :active), do: where(query, [p], p.standing == "active")
  defp by_standing(query, :suspended), do: where(query, [p], p.standing == "suspended")
  defp by_standing(query, :revoked), do: where(query, [p], p.standing == "revoked")

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`revoke/2`).
  defp retire(%PairedClient{} = row) do
    with {:ok, revoked} <-
           row
           |> Ecto.Changeset.change(
             standing: "revoked",
             updated_at: Arca.ServerMetaStorage.now!()
           )
           |> Arca.Repo.update() do
      dependents = retire_dependents!([revoked.id])
      {:ok, Map.put(revoked, :revoked_session_hashes, dependents.session_hashes)}
    end
  end
end
