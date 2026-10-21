# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairedClients do
  @moduledoc """
  The paired clients' rows (`Arca.Schemas.PairedClient`): one row per
  client a person holds in an athanor, carrying the credential it stands
  on (`source_kind`, `source_id`), a paired device's public key
  (`device_public_key`, for a `device_cert` client), a `label` the person
  reads, and its `standing`, which alone decides what the client may do.
  Sanctum is the one caller above this layer (`Sanctum.Pairing`); the rows
  are security rows no domain or surface names.

  ## Standing

  `active`, `suspended` or `revoked`, and nothing leaves `revoked`.
  `revoke/2` ends one row; a standing transition revokes a person's rows,
  and every row of an athanor it archives, in its own transaction
  (`Arca.SecurityTransitions`). Each revocation raises `updated_at`, which
  is when the row was retired, and revokes the client's device
  certificates (`Arca.DeviceCertificates`) and voids the pending
  confirmations it confirmed (`Arca.PendingConfirmations`) in the same
  transaction.

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
  @optional ~w(label device_public_key)a

  @typedoc "A paired client row, as a plain map."
  @type row :: %{
          id: String.t(),
          athanor_id: String.t(),
          user_id: String.t(),
          source_kind: String.t(),
          source_id: String.t(),
          device_public_key: binary() | nil,
          standing: String.t(),
          label: String.t() | nil,
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
  `:revoked` (never revived), `:not_suspended`, `:no_athanor`,
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
  `"device_cert"`, and `source_id`), each required, an optional `label`,
  and for a `device_cert` client the device's 32-byte `device_public_key`
  (required) and, optionally, the `id` a pairing invitation reserved for
  it. The row starts `active`.

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
  Revoke the row `id` in the actor's athanor, with its device certificates
  and the confirmations it confirmed; revoking a revoked row answers it as
  it is.
  """
  @spec revoke(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
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
          nil -> {:error, :not_found}
          %PairedClient{standing: "revoked"} = row -> {:ok, row}
          row -> retire(row)
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
          confirmation_ids: [String.t()]
        }
  # What a client's revocation takes with it, in the caller's transaction:
  # the certificates issued to the revoked clients and the confirmations
  # they confirmed.
  def retire_dependents!([]), do: %{certificate_ids: [], confirmation_ids: []}

  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def retire_dependents!(client_ids) do
    %{
      certificate_ids:
        DeviceCertificates.revoke_all(
          from(c in DeviceCertificate, where: c.paired_client_id in ^client_ids)
        ),
      confirmation_ids: PendingConfirmations.void_confirmed_by!(:paired_client, client_ids)
    }
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

  defp verified(:ok), do: :ok
  defp verified({:error, reason}), do: {:error, reason}
  defp verified(other), do: {:error, other}

  defp changeset(id, attrs) do
    id = if is_binary(id) and String.starts_with?(id, "pcl_"), do: id, else: nil

    %PairedClient{id: id || Prima.UUID7.generate_id("pcl")}
    |> Ecto.Changeset.cast(attrs, [:athanor_id | @required ++ @optional])
    |> Ecto.Changeset.validate_required([:athanor_id | @required])
    |> Ecto.Changeset.validate_inclusion(:source_kind, PairedClient.source_kinds())
    |> Ecto.Changeset.validate_length(:label, max: 80)
    |> validate_device_key()
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
      _ = retire_dependents!([revoked.id])
      {:ok, revoked}
    end
  end
end
