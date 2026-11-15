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
  it ends with, a deadline, the resources it covers and the outside
  sources it also follows (none unless chosen, so an allow asks again
  after any outside read it does not name). The lifecycle is
  named by its kind and read from the card's own turn — `:execution` the
  turn's root execution, `:turn` the turn, and for this thread's answer
  only `:schedule`, the schedule that root was started by or else the
  schedule whose own thread the card's turn runs in (`Arca.CronSchedule.of_thread/2`:
  a schedule's line for Aqua runs every fire there), refused when there is
  none — so a person can bound an answer only by the run or the schedule
  the card belongs to. An answer for this thread ending with the schedule
  holds for that schedule's turns in that thread (`Sanctum.ToolGrants`
  covers a call only when its execution was started by the schedule), and
  ends when the schedule is deleted or the thread is. Bounds on `:once` or
  on a deny are refused rather than dropped.
  """

  alias Sanctum.Context

  @type scope :: :once | :thread | :always | :never

  @typedoc "The run a standing allow ends with, as the person names it."
  @type lifecycle :: :execution | :turn | :schedule

  @typedoc """
  The bounds a person chose for a standing answer: the `lifecycle` it
  ends with, the time it ends at (`until`), the resources it covers
  (`constraint`, a resource kind and its patterns) and the outside
  `sources` it also follows. Each is optional.
  """
  @type bounds :: %{
          optional(:lifecycle) => lifecycle() | nil,
          optional(:until) => DateTime.t() | nil,
          optional(:constraint) => %{kind: String.t(), patterns: [String.t()]} | nil,
          optional(:sources) => [Prima.Source.t()] | nil
        }

  @doc "Whether `scope` may stand for the card's intent."
  @spec check(map(), scope()) :: :ok | {:error, {:scope_not_permitted, term()}}
  def check(intent, scope) when scope in [:thread, :always] do
    standing = Sanctum.Annotations.standing(intent["standing"])

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
  Whether an answer of `scope` (`:thread` or `:always`) is offered for the
  card's intent: the rule `check/2` holds a decision to, which the card's
  buttons and a stopped schedule turn's sentence both read.
  """
  @spec offered?(map(), :thread | :always) :: boolean()
  def offered?(intent, scope) when scope in [:thread, :always], do: check(intent, scope) == :ok

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
    with {:ok, bound} <- bound(ctx, turn, {grant_scope, effect}, bounds),
         {:ok, row} <- Sanctum.ToolGrants.grant_row(ctx, Map.merge(attrs, bound)) do
      {:ok, [row]}
    end
  end

  def rows(_ctx, _turn, _proposal, _scope, bounds), do: unbounded(bounds)

  # An answer that writes no row takes no bound.
  defp unbounded(bounds) do
    if Enum.any?(Map.values(bounds), &(not is_nil(&1))),
      do: {:error, {:scope_not_permitted, :bounds_without_standing}},
      else: {:ok, []}
  end

  # The bounds as the row names them. A deny's are passed on unresolved,
  # for the rule to refuse; an allow's lifecycle is read from the card's
  # own turn.
  defp bound(ctx, turn, row, bounds) do
    with {:ok, lifecycle} <- lifecycle(ctx, turn, row, Map.get(bounds, :lifecycle)) do
      {:ok,
       Map.merge(lifecycle, %{
         expires_at: Map.get(bounds, :until),
         constraint: Map.get(bounds, :constraint),
         sources: Map.get(bounds, :sources)
       })}
    end
  end

  defp lifecycle(_ctx, _turn, _row, nil), do: {:ok, %{}}

  defp lifecycle(_ctx, _turn, {_scope, "deny"}, kind)
       when kind in [:execution, :turn, :schedule],
       do: {:ok, %{lifecycle_kind: Atom.to_string(kind)}}

  defp lifecycle(_ctx, %{root_execution_id: id}, _row, :execution) when is_binary(id),
    do: {:ok, %{lifecycle_kind: "execution", lifecycle_id: id}}

  defp lifecycle(_ctx, %{id: id}, _row, :turn) when is_binary(id),
    do: {:ok, %{lifecycle_kind: "turn", lifecycle_id: id}}

  # An answer for this thread may end with a schedule: the one the turn's
  # root was started by, read from its row in the caller's athanor, else
  # the one whose own thread this is. An agent-wide answer ends with none:
  # a schedule's turn opens no card, so no agent-wide card has a schedule
  # to end with.
  defp lifecycle(ctx, turn, {"thread", _effect}, :schedule) do
    with :none <- started_by(ctx, turn),
         :none <- thread_of(ctx, turn) do
      {:error, {:scope_not_permitted, :no_schedule}}
    end
  end

  defp lifecycle(_ctx, _turn, _row, _kind),
    do: {:error, {:scope_not_permitted, :invalid_lifecycle}}

  defp started_by(ctx, %{root_execution_id: id}) when is_binary(id) do
    case Arca.Execution.get_tenant(Context.actor(ctx), id) do
      %{schedule_id: schedule_id} when is_binary(schedule_id) -> ended_with(schedule_id)
      {:error, _unreadable} = error -> error
      _unscheduled -> :none
    end
  end

  defp started_by(_ctx, _turn), do: :none

  defp thread_of(ctx, %{thread_id: thread_id}) when is_binary(thread_id) do
    case Arca.CronSchedule.of_thread(Context.actor(ctx), thread_id) do
      {:ok, %{id: schedule_id}} -> ended_with(schedule_id)
      {:error, :not_found} -> :none
      {:error, _unreadable} = error -> error
    end
  end

  defp thread_of(_ctx, _turn), do: :none

  defp ended_with(schedule_id),
    do: {:ok, %{lifecycle_kind: "schedule", lifecycle_id: schedule_id}}
end
