# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Writers do
  @moduledoc """
  The fixture writers no production path calls: rows a test needs without
  the contract that writes them in production (the consent sequence for a
  profile, admission for an execution).

  Each writes through the schema's own changeset, over Arca's public
  functions and `Arca.Repo` alone, so a row it writes is one the schema
  admits, and answers as a storage call does: `{:ok, row}` projected, or
  `{:error, reason}`.
  """

  import Ecto.Query

  alias Arca.Schemas.Execution, as: Row
  alias Arca.Schemas.Profile

  # The outcomes an ended execution's attempt may close with, by the
  # status it ends in (`Arca.Execution`'s own table).
  @end_outcomes %{
    "completed" => ["ok"],
    "failed" => ["error", "uncertain", "result_lost"],
    "cancelled" => ["cancelled"]
  }

  @doc """
  A profile row from `attrs`, under a fresh `prof_` id unless `attrs`
  names one: `{:ok, row}`, `{:error, {:invalid_label, label}}` for a label
  the label rule refuses, or `{:error, {:invalid, errors}}` for any other
  field the profile vocabulary refuses. The athanor arrives in `attrs` and
  its absence raises.
  """
  @spec put_profile(map()) :: {:ok, map()} | {:error, term()}
  # arca:unscoped-ok the athanor arrives in attrs and its absence fails loudly two lines down.
  def put_profile(attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.Test.Writers.put_profile", fn ->
      _ = Map.fetch!(attrs, :athanor_id)
      row = Map.put_new(attrs, :id, Prima.UUID7.generate_id("prof"))

      # The schema's changeset holds the row to the profile vocabulary and
      # carries the active-identity index. A label refusal keeps the typed
      # shape the consent verbs answer with.
      case Arca.Repo.insert(Profile.changeset(%Profile{}, row)) do
        {:error, %Ecto.Changeset{errors: errors}} = refusal ->
          if Keyword.has_key?(errors, :label),
            do: {:error, {:invalid_label, Map.get(row, :label)}},
            else: refusal

        result ->
          result
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  An execution row with no attempt and no admission, in a status of the
  execution vocabulary (the start changeset's): `{:ok, row}`, `{:error,
  :illegal_transition}` when `attrs` names an attempt, or `{:error,
  {:invalid, errors}}`. A row that names no root is its own, as an
  admitted root is. A row it writes has no stamp to match, so it ends on
  its status alone.
  """
  @spec record_start(map()) :: {:ok, map()} | {:error, term()}
  def record_start(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :current_attempt) do
      {:error, :illegal_transition}
    else
      Arca.Repo.Errors.with_db_rescue("Arca.Test.Writers.record_start", fn ->
        attrs
        |> Map.put(:root_execution_id, Map.get(attrs, :root_execution_id) || Map.get(attrs, :id))
        |> Row.start_changeset()
        |> Arca.Repo.insert()
        |> duplicate_child_key()
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  End a running execution row in the terminal status `attrs` names: a
  status that ends nothing, `running` included, is `{:error, {:invalid,
  %{status: ["is invalid"]}}}`, an outcome must be one that status allows
  (`{:error, :illegal_transition}` otherwise), and the write
  carries an atomic `status == "running"` precondition (`{:error,
  :not_running}`). `opts`: `attempt:` narrows the write to the attempt
  that owns the row; `grant:` and `verify:` (required,
  `Arca.ExecutionStanding`) are the completion's standing, asked before
  the row is written.
  """
  @spec record_complete(Prima.Actor.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def record_complete(actor, id, attrs, opts \\ [])

  def record_complete(%Prima.Actor{} = actor, id, attrs, opts) when is_list(opts) do
    if outcome_allowed?(Map.get(attrs, :status), Map.get(attrs, :outcome)),
      do: complete(actor, id, attrs, opts),
      else: {:error, :illegal_transition}
  end

  defp duplicate_child_key({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    case Keyword.get(errors, :child_key) do
      {_message, [constraint: :unique, constraint_name: _name]} -> {:error, :duplicate_child_key}
      _other -> {:error, changeset}
    end
  end

  defp duplicate_child_key(other), do: other

  defp complete(actor, id, attrs, opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Test.Writers.record_complete", fn ->
      case Arca.ExecutionStanding.inputs(opts, fn -> stored_of(actor, id) end) do
        {:ok, %Prima.ExecutionGrant{} = grant, verify} ->
          complete_standing(actor, id, attrs, opts, grant, verify)

        {:ok, nil, _verify} ->
          {:error, :missing_grant}

        {:error, :missing_grant} = refused ->
          refused
      end
    end)
    |> Arca.Data.project()
  end

  defp outcome_allowed?(_status, nil), do: true
  defp outcome_allowed?(status, outcome), do: outcome in Map.get(@end_outcomes, status, [])

  # The standing first, then the row: the grant is checked before the row
  # is locked by its write, and must be the stamp of the row's attempt.
  # arca:db-raise-ok inside the caller's rescue.
  defp complete_standing(actor, id, attrs, opts, grant, verify) do
    fn ->
      Arca.ExecutionStanding.verify!(grant, verify)

      case row_of(actor, id) do
        nil ->
          Arca.Repo.rollback(:not_found)

        {:error, reason} ->
          Arca.Repo.rollback(reason)

        execution ->
          if execution.athanor_id != grant.athanor_id or not stamped?(execution, grant),
            do: Arca.Repo.rollback(:not_standing)

          # The cast runs on the row with its status cleared, so the status
          # is always a change and the terminal-status check always runs: a
          # `running` cast onto a running row is otherwise no change, passes,
          # and ends nothing while stamping the row completed.
          changeset = Row.complete_changeset(%{execution | status: nil}, attrs)
          if not changeset.valid?, do: Arca.Repo.rollback(changeset)

          from(e in Row, where: e.id == ^id, where: e.status == "running")
          |> fenced(Keyword.take(opts, [:attempt]))
          |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
          |> Arca.Repo.update_all(set: Map.to_list(changeset.changes))
          |> case do
            {1, _} -> Ecto.Changeset.apply_changes(changeset)
            {0, _} -> Arca.Repo.rollback(:not_running)
          end
      end
    end
    |> Arca.Repo.locking_transaction()
  end

  # A row with an attempt carries that attempt's stamp; one with none (a
  # `record_start/1` row) has only its athanor to match.
  # arca:db-raise-ok inside the caller's transaction
  defp stamped?(%Row{current_attempt: nil}, _grant), do: true

  defp stamped?(%Row{athanor_id: athanor_id, id: id}, grant),
    do:
      Arca.ExecutionStanding.stored_of_execution(Prima.Actor.in_athanor(athanor_id), id) ==
        grant

  # The stamp of the current attempt of an execution the actor may read.
  # arca:db-raise-ok inside the caller's rescue.
  defp stored_of(actor, id) do
    case row_of(actor, id) do
      %Row{athanor_id: athanor_id} ->
        Arca.ExecutionStanding.stored_of_execution(Prima.Actor.in_athanor(athanor_id), id)

      _none ->
        nil
    end
  end

  defp row_of(actor, id) do
    from(e in Row, where: e.id == ^id)
    |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
    |> Arca.Repo.one()
  end

  defp fenced(query, fence) do
    Enum.reduce(fence, query, fn
      {_key, nil}, q -> q
      {:attempt, attempt}, q -> where(q, [e], e.current_attempt == ^attempt)
      {_other, _}, q -> q
    end)
  end
end
