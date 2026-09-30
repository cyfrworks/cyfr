# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Standing do
  @moduledoc """
  The standing half of a card's decision: whether the answer a person
  gives may stand for calls nobody has seen yet, and the rows it becomes.

  `:once` answers this call alone. `:thread` and `:always` are
  standing allows: both are refused for a destructive or external action,
  and the action's own standing rule — minted onto the card's intent from
  the declaration `Sanctum.ToolGrants` reads at the write — has the last
  word: `false` takes no standing answer at all, `"thread"` none at agent
  scope. `:never` is a standing deny, always recordable. The card hides
  the buttons a rule refuses, but the card is a client; the rule is
  decided here, on what the intent carries, and again where the row is
  built.

  A standing allow may carry the bounds the person chose: the lifecycle
  it ends with, a deadline, and the resources it covers. The lifecycle is
  named by its kind and read from the card's own turn — `:execution` the
  turn's root execution, `:turn` the turn, `:schedule` the schedule that
  root was started by, refused when there is none — so a person can bound
  an answer only by the run the card belongs to. Bounds on `:once` or on
  a deny are refused rather than dropped.
  """

  alias Sanctum.Context

  @type scope :: :once | :thread | :always | :never

  @typedoc "The run a standing allow ends with, as the person names it."
  @type lifecycle :: :execution | :turn | :schedule

  @typedoc """
  The bounds a person chose for a standing answer: the `lifecycle` it
  ends with, the time it ends at (`until`) and the resources it covers
  (`constraint`, a resource kind and its patterns). Each is optional.
  """
  @type bounds :: %{
          optional(:lifecycle) => lifecycle() | nil,
          optional(:until) => DateTime.t() | nil,
          optional(:constraint) => %{kind: String.t(), patterns: [String.t()]} | nil
        }

  @doc "Whether `scope` may stand for the card's intent."
  @spec check(map(), scope()) :: :ok | {:error, {:scope_not_permitted, term()}}
  def check(intent, scope) when scope in [:thread, :always] do
    standing = Grimoire.standing_scope(intent["standing"])

    cond do
      intent["action_kind"] in ["destructive", "external"] ->
        {:error, {:scope_not_permitted, intent["action_kind"]}}

      standing == false ->
        {:error, {:scope_not_permitted, :never_standing}}

      standing == :thread and scope == :always ->
        {:error, {:scope_not_permitted, :thread_only}}

      true ->
        :ok
    end
  end

  def check(_intent, _scope), do: :ok

  @doc """
  The grant rows a decision writes with itself, for the agent the turn
  runs: none for `:once`, an allow at thread or agent scope with the
  bounds the person chose, a deny at agent scope for `:never`. Checked
  against the action's standing rule (`Sanctum.ToolGrants.grant_row/2`).
  """
  @spec rows(Context.t(), map(), map(), scope(), bounds()) :: {:ok, [map()]} | {:error, term()}
  def rows(ctx, turn, proposal, scope, bounds \\ %{})

  def rows(_ctx, _turn, _proposal, :once, bounds), do: unbounded(bounds)

  def rows(%Context{} = ctx, turn, %{"tool" => tool, "action" => action}, scope, bounds)
      when scope in [:thread, :always, :never] and is_binary(tool) and is_binary(action) do
    {grant_scope, effect} =
      case scope do
        :thread -> {"thread", "allow"}
        :always -> {"agent", "allow"}
        :never -> {"agent", "deny"}
      end

    attrs = %{
      scope: grant_scope,
      effect: effect,
      thread_id: turn.thread_id,
      agent_name: turn.agent,
      tool: tool,
      action: action
    }

    # The rule is identity's, and so are the row, its tenant and who
    # decided: built from the context and written by the turn store in the
    # decision's own transaction.
    with {:ok, bound} <- bound(ctx, turn, effect, bounds),
         {:ok, row} <- Sanctum.ToolGrants.grant_row(ctx, Map.merge(attrs, bound)) do
      {:ok, [row]}
    end
  end

  def rows(_ctx, _turn, _proposal, _scope, bounds), do: unbounded(bounds)

  @doc "The words a standing answer is called by on the tape."
  @spec answer(scope()) :: String.t()
  def answer(:never), do: "\"Never\""
  def answer(:always), do: "\"Always\""
  def answer(:thread), do: "\"Always for this thread\""
  def answer(:once), do: "\"Once\""

  # An answer that writes no row takes no bound.
  defp unbounded(bounds) do
    if Enum.any?(Map.values(bounds), &(not is_nil(&1))),
      do: {:error, {:scope_not_permitted, :bounds_without_standing}},
      else: {:ok, []}
  end

  # The bounds as the row names them. A deny's are passed on unresolved,
  # for the rule to refuse; an allow's lifecycle is read from the card's
  # own turn.
  defp bound(ctx, turn, effect, bounds) do
    with {:ok, lifecycle} <- lifecycle(ctx, turn, effect, Map.get(bounds, :lifecycle)) do
      {:ok,
       Map.merge(lifecycle, %{
         expires_at: Map.get(bounds, :until),
         constraint: Map.get(bounds, :constraint)
       })}
    end
  end

  defp lifecycle(_ctx, _turn, _effect, nil), do: {:ok, %{}}

  defp lifecycle(_ctx, _turn, "deny", kind) when kind in [:execution, :turn, :schedule],
    do: {:ok, %{lifecycle_kind: Atom.to_string(kind)}}

  defp lifecycle(_ctx, %{root_execution_id: id}, _effect, :execution) when is_binary(id),
    do: {:ok, %{lifecycle_kind: "execution", lifecycle_id: id}}

  defp lifecycle(_ctx, %{id: id}, _effect, :turn) when is_binary(id),
    do: {:ok, %{lifecycle_kind: "turn", lifecycle_id: id}}

  # The schedule the turn's root was started by, read from its row in the
  # caller's athanor.
  defp lifecycle(ctx, %{root_execution_id: id}, _effect, :schedule) when is_binary(id) do
    case Arca.Execution.get_tenant(Context.actor(ctx), id) do
      %{schedule_id: schedule_id} when is_binary(schedule_id) ->
        {:ok, %{lifecycle_kind: "schedule", lifecycle_id: schedule_id}}

      {:error, _unreadable} = error ->
        error

      _unscheduled ->
        {:error, {:scope_not_permitted, :no_schedule}}
    end
  end

  defp lifecycle(_ctx, _turn, _effect, _kind),
    do: {:error, {:scope_not_permitted, :invalid_lifecycle}}
end
