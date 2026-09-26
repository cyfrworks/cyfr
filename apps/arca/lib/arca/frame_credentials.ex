# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FrameCredentials do
  @moduledoc """
  The per-open frame credentials' rows (`Arca.Schemas.FrameCredential`):
  one row per frame a shell opened, whose `state` is the standing of the
  bearer the frame holds, so every member of the cell reads the same one.
  `Sanctum.TinctureAuth` is the one caller above this layer; the rows are
  security rows no domain or surface names.

  ## States

  `active`, `suspended` or `revoked`. `suspend/2` and `resume/2` move
  between the first two; `revoke/2` ends a row from either, and nothing
  leaves `revoked`. A standing transition revokes rows in its own
  transaction (`Arca.SecurityTransitions`), and a retired source's rows go
  with `revoke_for_source/2`. Each state change raises `updated_at`, which
  is when a revoked row was retired; `Arca.Retention.FrameCredentials`
  removes revoked rows older than the athanor's value.

  ## Ownership

  A mint and a resume widen what a bearer opens, so each runs in a locking
  transaction that checks the member still owns its slot
  (`Arca.ControlPlane.verify_held/1`) before it writes: a stale owner
  dispenses no credential and re-opens none. A suspend and a revoke only
  narrow, and are never refused for ownership: a member that lost its slot
  may still close what it opened.

  Every function takes the actor first. An athanor actor reads and writes
  its own athanor's rows; `revoke_for_source/2` and `revoke_for_user/2`
  also take the platform system actor, for a retirement that crosses
  athanors. Rows are answered as plain maps (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.FrameCredential

  @required ~w(user_id publisher name version version_digest grant_revision frame_id source_kind source_id deadline)a

  @typedoc "A frame credential row, as a plain map."
  @type row :: %{
          id: String.t(),
          athanor_id: String.t(),
          user_id: String.t(),
          publisher: String.t(),
          name: String.t(),
          version: String.t(),
          version_digest: String.t(),
          grant_revision: non_neg_integer(),
          frame_id: String.t(),
          source_kind: String.t(),
          source_id: String.t(),
          state: String.t(),
          deadline: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @typedoc "The credential a frame credential was minted under: a session's token-hash id, or a key's id."
  @type source :: {:session | :api_key, String.t()}

  @doc """
  Record the frame credential of a frame `attrs.frame_id` opened in the
  actor's athanor: `user_id`, the tincture version it opened (`publisher`,
  `name`, `version`) and its `version_digest`, `grant_revision`,
  `frame_id`, `source_kind` (`"session"` or `"api_key"`), `source_id` and
  `deadline`, each required. The row starts `active`.

  Refused with `:no_athanor` for an actor that names none, `{:invalid,
  errors}` for a missing or malformed field, `:conflict` for a frame id
  the athanor already holds, `:not_owner` on a member that no longer owns
  its slot, and `:database_error` when the store cannot answer.
  """
  @spec mint(Prima.Actor.t(), map()) ::
          {:ok, row()}
          | {:error, :no_athanor | :conflict | :not_owner | :database_error | {:invalid, map()}}
  # arca:db-raise-ok the insert runs inside `owned/2`, which rescues around its transaction.
  def mint(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    changeset = changeset(QueryHelpers.stamp_tenant!(actor, Map.take(attrs, @required)))

    if changeset.valid? do
      owned("Arca.FrameCredentials.mint", fn ->
        case Arca.Repo.insert(changeset) do
          {:ok, row} -> {:ok, row}
          {:error, %Ecto.Changeset{errors: errors} = changeset} -> conflict_or_invalid(errors, changeset)
        end
      end)
    else
      {:error, Arca.Data.invalid(changeset)}
    end
  end

  def mint(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc "The row `id` in the actor's athanor, or `:not_found`."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.FrameCredentials.get", fn ->
      case FrameCredential |> QueryHelpers.where_tenant(actor) |> where([f], f.id == ^id) |> Arca.Repo.one() do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Suspend an active row: the frame's bearer opens nothing until it is
  resumed. A suspended row answers as it is; a revoked one is `:revoked`.
  """
  @spec suspend(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :revoked | :no_athanor | :database_error}
  def suspend(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.FrameCredentials.suspend", fn ->
      Arca.Repo.locking_transaction(fn -> move(actor, id, "active", "suspended") end)
      |> unwrap()
    end)
    |> Arca.Data.project()
  end

  def suspend(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Resume a suspended row, under the member's live ownership. An active row
  answers as it is; a revoked one is `:revoked`, and one past its deadline
  on the database's clock `:expired`, which resumes nothing.
  """
  @spec resume(Prima.Actor.t(), String.t()) ::
          {:ok, row()}
          | {:error,
             :not_found | :revoked | :expired | :not_owner | :no_athanor | :database_error}
  def resume(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    owned("Arca.FrameCredentials.resume", fn ->
      now = Arca.ServerMetaStorage.now!()

      case locked_row(actor, id) do
        %FrameCredential{deadline: deadline} = row ->
          if DateTime.compare(deadline, now) == :gt,
            do: set_state(row, "suspended", "active"),
            else: {:error, :expired}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  def resume(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc "Revoke a row, from any state; revoking a revoked row answers it as it is."
  @spec revoke(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def revoke(%Prima.Actor{athanor_id: athanor_id} = actor, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.FrameCredentials.revoke", fn ->
      Arca.Repo.locking_transaction(fn ->
        case locked_row(actor, id) do
          nil -> {:error, :not_found}
          %FrameCredential{state: "revoked"} = row -> {:ok, row}
          row -> set_state(row, row.state, "revoked")
        end
      end)
      |> unwrap()
    end)
    |> Arca.Data.project()
  end

  def revoke(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Revoke every unrevoked row minted under `source`, the retired session
  or key: in the actor's athanor, or in every athanor for the platform
  system actor. Answers the ids it revoked.
  """
  @spec revoke_for_source(Prima.Actor.t(), source()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def revoke_for_source(%Prima.Actor{} = actor, {kind, source_id})
      when kind in [:session, :api_key] and is_binary(source_id) and source_id != "" do
    kind = Atom.to_string(kind)
    scoped(actor, "Arca.FrameCredentials.revoke_for_source", fn query ->
      where(query, [f], f.source_kind == ^kind and f.source_id == ^source_id)
    end)
  end

  @doc """
  Revoke every unrevoked row of the person `user_id`: in the actor's
  athanor, or in every athanor for the platform system actor. Answers the
  ids it revoked.
  """
  @spec revoke_for_user(Prima.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def revoke_for_user(%Prima.Actor{} = actor, user_id) when is_binary(user_id) and user_id != "" do
    scoped(actor, "Arca.FrameCredentials.revoke_for_user", fn query ->
      where(query, [f], f.user_id == ^user_id)
    end)
  end

  @doc false
  # The retention kind's count: revoked rows of the athanor retired before
  # `cutoff`.
  @spec count_revoked_before(DateTime.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def count_revoked_before(%DateTime{} = cutoff, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("Arca.FrameCredentials.count_revoked_before", fn ->
      {:ok, cutoff |> retired(athanor_id) |> Arca.Repo.aggregate(:count)}
    end)
  end

  @doc false
  # The retention kind's sweep: delete the athanor's revoked rows retired
  # before `cutoff`. An active or suspended row is never swept, whatever
  # its age: it is a standing, not a record.
  @spec delete_revoked_before(DateTime.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_revoked_before(%DateTime{} = cutoff, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("Arca.FrameCredentials.delete_revoked_before", fn ->
      {count, _} = cutoff |> retired(athanor_id) |> Arca.Repo.delete_all()
      {:ok, count}
    end)
  end

  # ---- internals -------------------------------------------------------------

  defp changeset(attrs) do
    %FrameCredential{id: Prima.UUID7.generate_id("frc")}
    |> Ecto.Changeset.cast(attrs, [:athanor_id | @required])
    |> Ecto.Changeset.validate_required([:athanor_id | @required])
    |> Ecto.Changeset.validate_inclusion(:source_kind, FrameCredential.source_kinds())
    |> Ecto.Changeset.validate_number(:grant_revision, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_length(:frame_id, min: 1, max: 64)
    |> Ecto.Changeset.unique_constraint([:athanor_id, :frame_id])
  end

  defp conflict_or_invalid(errors, changeset) do
    if Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end),
      do: {:error, :conflict},
      else: {:error, Arca.Data.invalid(changeset)}
  end

  # A write that widens a bearer: one locking transaction whose first step
  # checks the member's slot on the database's clock, so a takeover that
  # committed first refuses it and one that starts later waits for it.
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

  defp unwrap({:ok, {:ok, row}}), do: {:ok, row}
  defp unwrap({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp locked_row(actor, id) do
    FrameCredential
    |> QueryHelpers.where_tenant(actor)
    |> where([f], f.id == ^id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp move(actor, id, from, to) do
    case locked_row(actor, id) do
      nil -> {:error, :not_found}
      %FrameCredential{state: ^to} = row -> {:ok, row}
      %FrameCredential{state: ^from} = row -> set_state(row, from, to)
      %FrameCredential{state: "revoked"} -> {:error, :revoked}
    end
  end

  defp set_state(%FrameCredential{state: to} = row, _from, to), do: {:ok, row}
  defp set_state(%FrameCredential{state: "revoked"}, _from, _to), do: {:error, :revoked}

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`locked_row/2`).
  defp set_state(%FrameCredential{state: from} = row, from, to) do
    row
    |> Ecto.Changeset.change(state: to, updated_at: Arca.ServerMetaStorage.now!())
    |> Arca.Repo.update()
  end

  defp set_state(%FrameCredential{}, _from, _to), do: {:error, :revoked}

  defp scoped(actor, tag, narrow) do
    case scope(actor) do
      {:ok, query} ->
        Arca.Repo.Errors.with_db_rescue(tag, fn ->
          {:ok, revoke_all(narrow.(query))}
        end)

      {:error, _} = refusal ->
        refusal
    end
  end

  # The platform system actor retires a person's or a source's frames in
  # every athanor; any other actor is held to its own.
  defp scope(%Prima.Actor{scope: :platform, system: true}), do: {:ok, from(f in FrameCredential)}

  defp scope(%Prima.Actor{athanor_id: athanor_id} = actor)
       when is_binary(athanor_id) and athanor_id != "",
       do: {:ok, QueryHelpers.where_tenant(FrameCredential, actor)}

  defp scope(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc false
  @spec revoke_all(Ecto.Queryable.t()) :: [String.t()]
  # Revoke every unrevoked row `query` names, in the caller's transaction
  # or its own statement, answering the ids it revoked, sorted. The one
  # revocation statement: `Arca.SecurityTransitions` runs it inside a
  # standing transition's transaction.
  # arca:unscoped-ok the caller's query carries its own scope: an athanor, a person or a source.
  # arca:db-raise-ok a transaction step: its callers rescue around it, so a raise rolls a transition back.
  def revoke_all(query) do
    now = Arca.ServerMetaStorage.now!()

    {_count, ids} =
      Arca.Repo.update_all(
        from(f in query, where: f.state != "revoked", select: f.id),
        set: [state: "revoked", updated_at: now]
      )

    Enum.sort(ids || [])
  end

  defp retired(cutoff, athanor_id) do
    from(f in FrameCredential,
      where: f.athanor_id == ^athanor_id and f.state == "revoked" and f.updated_at < ^cutoff
    )
  end
end
