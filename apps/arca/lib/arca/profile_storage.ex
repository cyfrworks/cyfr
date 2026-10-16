# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorage do
  @moduledoc """
  Persistence mechanics for existing profiles: reads, status changes and
  head advances. A profile row is minted only with its first consent
  revision (`Arca.ConsentStorage.mint_profile_with_revision/4`).
  Validation and consent semantics live above, in Sanctum's consent
  domain and `Arca.ConsentStorage`, which call this module beside the
  entry stores that change a profile's status. Every function takes the
  `Prima.Actor` first and matches it in the head, refusing an actor whose
  athanor is nil or the empty string with `{:error, :no_athanor}` before
  any query. Every read and write is keyed by the owning athanor.
  """

  import Ecto.Query

  alias Arca.Schemas.Profile

  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.get", fn ->
      case Arca.Repo.get_by(Profile, id: id, athanor_id: athanor_id) do
        nil -> {:error, :not_found}
        profile -> {:ok, profile}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc "Non-revoked profiles for a name-level source ref within an athanor."
  @spec list_for_source(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_for_source(%Prima.Actor{athanor_id: athanor_id}, source_ref)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.list_for_source", fn ->
      rows =
        from(p in Profile,
          where: p.source_ref == ^source_ref and p.status != "revoked",
          order_by: p.id
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  def list_for_source(%Prima.Actor{}, _source_ref), do: {:error, :no_athanor}

  @doc """
  Move a profile from one of the statuses `from` names (a status, a list
  of them, or `:any` for every status the table lets reach `to`) to `to`,
  as one conditional write: the row changes only while it holds one of
  `from`, so a write raced by another lands wholly before it or finds the
  row moved and changes nothing.

  Every move `from` names must be one `Arca.StatusTransitions`'s profile
  table admits, or nothing is read and the answer is
  `{:error, :illegal_transition}`; so it is when the row holds a status
  outside `from`. A row already `needs_consent` or `revoked` is written so
  again when `from` names that status, so a retry finishes what an earlier
  attempt left; `active → active` is refused, since `active` comes only by
  re-consent. A row the athanor does not hold is `{:error, :not_found}`.
  """
  @spec transition(Prima.Actor.t(), String.t(), :any | String.t() | [String.t()], String.t()) ::
          :ok | {:error, :no_athanor | :not_found | :illegal_transition | :database_error}
  def transition(%Prima.Actor{athanor_id: athanor_id}, id, from, to)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(to) do
    from = sources(from, to)

    if from != [] and admitted?(from, to) do
      Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.transition", fn ->
        case Arca.Repo.update_all(
               from(p in Profile, where: p.id == ^id and p.status in ^from)
               |> Arca.QueryHelpers.where_athanor(athanor_id),
               set: [status: to, updated_at: DateTime.utc_now()]
             ) do
          {1, _} -> :ok
          {0, _} -> refused(athanor_id, id)
        end
      end)
    else
      {:error, :illegal_transition}
    end
  end

  def transition(%Prima.Actor{}, _id, _from, to) when is_binary(to), do: {:error, :no_athanor}

  defp sources(:any, to) do
    case Arca.StatusTransitions.from(:profiles, to) do
      {:ok, allowed} -> allowed
      :error -> []
    end
  end

  defp sources(from, _to), do: List.wrap(from)

  defp admitted?(from, to) do
    case Arca.StatusTransitions.from(:profiles, to) do
      {:ok, allowed} -> Enum.all?(from, &(&1 in allowed))
      :error -> false
    end
  end

  # Why a conditional write changed nothing: no such row, or one whose
  # status `from` did not name.
  defp refused(athanor_id, id) do
    exists? =
      from(p in Profile, where: p.id == ^id)
      |> Arca.QueryHelpers.where_athanor(athanor_id)
      |> Arca.Repo.exists?()

    if exists?, do: {:error, :illegal_transition}, else: {:error, :not_found}
  end

  @doc """
  Revoke every profile of a name-level source ref that is not already
  revoked, within the actor's athanor, in one transaction. Answers the ids
  it revoked. Consent revisions and vault entries are untouched: a revoked
  profile keeps its history.
  """
  @spec revoke_for_source(Prima.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :database_error}
  def revoke_for_source(%Prima.Actor{athanor_id: athanor_id}, source_ref)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(source_ref) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.revoke_for_source", fn ->
      Arca.Repo.transaction(fn ->
        ids =
          from(p in Profile,
            where: p.source_ref == ^source_ref and p.status != "revoked",
            order_by: p.id,
            select: p.id
          )
          |> Arca.QueryHelpers.where_athanor(athanor_id)
          |> Arca.Repo.all()

        from(p in Profile, where: p.id in ^ids)
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.update_all(set: [status: "revoked", updated_at: DateTime.utc_now()])

        ids
      end)
    end)
    |> Arca.Data.project()
  end

  def revoke_for_source(%Prima.Actor{}, _source_ref), do: {:error, :no_athanor}

  @doc """
  Compare-and-swap the head consent pointer. The update counts as applied
  only when the stored head still equals `expected` (or is NULL for the
  bootstrap revision) — a concurrent advance makes this return
  `{:error, :head_moved}` and the caller re-plans.
  """
  @spec advance_head(Prima.Actor.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, :no_athanor | :head_moved | term()}
  def advance_head(%Prima.Actor{athanor_id: athanor_id}, id, expected, new_consent_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.advance_head", fn ->
      base =
        from(p in Profile, where: p.id == ^id)
        |> Arca.QueryHelpers.where_athanor(athanor_id)

      query =
        case expected do
          nil -> from(p in base, where: is_nil(p.head_consent_id))
          expected -> from(p in base, where: p.head_consent_id == ^expected)
        end

      case Arca.Repo.update_all(query,
             set: [head_consent_id: new_consent_id, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :head_moved}
      end
    end)
    |> Arca.Data.project()
  end

  def advance_head(%Prima.Actor{}, _id, _expected, _new_consent_id), do: {:error, :no_athanor}
end
