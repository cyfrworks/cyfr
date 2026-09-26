# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PairedClients do
  @moduledoc """
  The paired clients' rows (`Arca.Schemas.PairedClient`): one row per
  client a person holds in an athanor, carrying the confirmation class
  Sanctum assigned it (`Prima.ConfirmationClass`, as its wire spelling),
  the credential it stands on (`source_kind`, `source_id`), a `label` the
  person reads, and its `standing`. Sanctum is the one caller above this
  layer (`Sanctum.Pairing`); the rows are security rows no domain or
  surface names.

  ## Standing

  `active` or `revoked`, and nothing leaves `revoked`. `revoke/2` ends one
  row; `revoke_for_user/2` ends a person's; a standing transition revokes
  a person's rows, and every row of an athanor it archives, in its own
  transaction (`Arca.SecurityTransitions`). Each revocation raises
  `updated_at`, which is when the row was retired.

  ## Ownership

  Recording a client widens what may be confirmed, so `record/2` runs in
  a locking transaction that checks the member still owns its slot
  (`Arca.ControlPlane.verify_held/1`) before it writes: a stale owner
  records nothing. A revocation only narrows, and is never refused for
  ownership.

  Every function takes the actor first. An athanor actor reads and writes
  its own athanor's rows; `revoke_for_user/2` also takes the platform
  system actor, for a retirement that crosses athanors. Rows are answered
  as plain maps (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.PairedClient

  @required ~w(user_id class source_kind source_id)a
  @optional ~w(label)a

  @typedoc "A paired client row, as a plain map."
  @type row :: %{
          id: String.t(),
          athanor_id: String.t(),
          user_id: String.t(),
          class: String.t(),
          source_kind: String.t(),
          source_id: String.t(),
          standing: String.t(),
          label: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc """
  What `list/2` narrows by: `user_id` (one person's clients) and
  `standing` (`:active`, the default, `:revoked` or `:all`).
  """
  @type filters :: [user_id: String.t(), standing: :active | :revoked | :all]

  @doc """
  The paired clients of the actor's athanor, oldest first, narrowed by
  `filters` (`t:filters/0`).
  """
  @spec list(Prima.Actor.t(), filters()) ::
          {:ok, [row()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor, filters)
      when is_binary(athanor_id) and athanor_id != "" and is_list(filters) do
    Arca.Repo.Errors.with_db_rescue("Arca.PairedClients.list", fn ->
      rows =
        PairedClient
        |> QueryHelpers.where_tenant(actor)
        |> by_user(Keyword.get(filters, :user_id))
        |> by_standing(Keyword.get(filters, :standing, :active))
        |> order_by([p], asc: p.inserted_at, asc: p.id)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, filters) when is_list(filters), do: {:error, :no_athanor}

  @doc """
  Record a client of the person `attrs.user_id` in the actor's athanor:
  its `class` (a `Prima.ConfirmationClass` wire spelling), the credential
  it stands on (`source_kind`, `"session"` or `"api_key"`, and
  `source_id`), each required, and an optional `label`. The row starts
  `active`.

  Refused with `:no_athanor` for an actor that names none, `{:invalid,
  errors}` for a missing or malformed field, `:conflict` for a credential
  the athanor already records a client for, `:not_owner` on a member that
  no longer owns its slot, and `:database_error` when the store cannot
  answer.
  """
  @spec record(Prima.Actor.t(), map()) ::
          {:ok, row()}
          | {:error, :no_athanor | :conflict | :not_owner | :database_error | {:invalid, map()}}
  # arca:db-raise-ok the insert runs inside `owned/2`, which rescues around its transaction.
  def record(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    changeset = changeset(QueryHelpers.stamp_tenant!(actor, Map.take(attrs, @required ++ @optional)))

    if changeset.valid? do
      owned("Arca.PairedClients.record", fn ->
        case Arca.Repo.insert(changeset) do
          {:ok, row} -> {:ok, row}
          {:error, %Ecto.Changeset{errors: errors} = changeset} -> conflict_or_invalid(errors, changeset)
        end
      end)
    else
      {:error, Arca.Data.invalid(changeset)}
    end
  end

  def record(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc "Revoke the row `id` in the actor's athanor; revoking a revoked row answers it as it is."
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

  @doc """
  Revoke every active row of the person `user_id`: in the actor's
  athanor, or in every athanor for the platform system actor. Answers the
  ids it revoked, sorted.
  """
  @spec revoke_for_user(Prima.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def revoke_for_user(%Prima.Actor{} = actor, user_id) when is_binary(user_id) and user_id != "" do
    case scope(actor) do
      {:ok, query} ->
        Arca.Repo.Errors.with_db_rescue("Arca.PairedClients.revoke_for_user", fn ->
          {:ok, revoke_all(where(query, [p], p.user_id == ^user_id))}
        end)

      {:error, _} = refusal ->
        refusal
    end
  end

  @doc false
  @spec revoke_all(Ecto.Queryable.t()) :: [String.t()]
  # Revoke every active row `query` names, in the caller's transaction or
  # its own statement, answering the ids it revoked, sorted. The one
  # revocation statement: `Arca.SecurityTransitions` runs it inside a
  # standing transition's transaction.
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

  # ---- internals -------------------------------------------------------------

  defp changeset(attrs) do
    classes = Enum.map(Prima.ConfirmationClass.all(), &Prima.ConfirmationClass.to_string/1)

    %PairedClient{id: Prima.UUID7.generate_id("pcl")}
    |> Ecto.Changeset.cast(attrs, [:athanor_id | @required ++ @optional])
    |> Ecto.Changeset.validate_required([:athanor_id | @required])
    |> Ecto.Changeset.validate_inclusion(:class, classes)
    |> Ecto.Changeset.validate_inclusion(:source_kind, PairedClient.source_kinds())
    |> Ecto.Changeset.validate_length(:label, max: 80)
    |> Ecto.Changeset.unique_constraint([:athanor_id, :source_kind, :source_id])
  end

  defp conflict_or_invalid(errors, changeset) do
    if Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end),
      do: {:error, :conflict},
      else: {:error, Arca.Data.invalid(changeset)}
  end

  defp by_user(query, nil), do: query
  defp by_user(query, user_id) when is_binary(user_id), do: where(query, [p], p.user_id == ^user_id)

  defp by_standing(query, :all), do: query
  defp by_standing(query, :active), do: where(query, [p], p.standing == "active")
  defp by_standing(query, :revoked), do: where(query, [p], p.standing == "revoked")

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`revoke/2`).
  defp retire(%PairedClient{} = row) do
    row
    |> Ecto.Changeset.change(standing: "revoked", updated_at: Arca.ServerMetaStorage.now!())
    |> Arca.Repo.update()
  end

  # A write that widens what may be confirmed: one locking transaction
  # whose first step checks the member's slot on the database's clock, so
  # a takeover that committed first refuses it and one that starts later
  # waits for it.
  defp owned(tag, write) do
    Arca.Repo.Errors.with_db_rescue(tag, fn ->
      with {:ok, slot} <- Arca.ControlPlane.member_slot() do
        Arca.Repo.locking_transaction(fn ->
          case Arca.ControlPlane.verify_held(slot) do
            :ok -> write.() |> committed()
            :lost -> Arca.Repo.rollback(:not_owner)
          end
        end)
      end
    end)
    |> Arca.Data.project()
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)

  # The platform system actor retires a person's clients in every athanor;
  # any other actor is held to its own.
  defp scope(%Prima.Actor{scope: :platform, system: true}), do: {:ok, from(p in PairedClient)}

  defp scope(%Prima.Actor{athanor_id: athanor_id} = actor)
       when is_binary(athanor_id) and athanor_id != "",
       do: {:ok, QueryHelpers.where_tenant(PairedClient, actor)}

  defp scope(%Prima.Actor{}), do: {:error, :no_athanor}
end
