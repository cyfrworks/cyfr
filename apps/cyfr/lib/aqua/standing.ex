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

  A standing allow for an action that names a program row covers that
  row alone: its constraint is the row the call names, never one the card
  chose, so no answer covers every program.

  A standing allow may carry the bounds the person chose: the lifecycle
  it ends with, a deadline, the resources it covers and the outside
  sources it also follows (none unless chosen, so an allow asks again
  after any outside read it does not name). The lifecycle is named by its
  kind: `:execution` the card's turn's root execution and `:turn` the
  turn, both read from the card's own turn, so a person can bound an
  answer only by the run the card belongs to.

  ## An answer for a schedule

  A schedule of Aqua's fires into the daily thread as a turn of it, and a
  scheduled turn opens no card (`Aqua.Loop`), so its answer is given later
  on a card of a turn the person started, which no schedule started. The
  card offers it with the person's schedules that hold a line for Aqua
  (`schedules/1`), and the person names one: `:always` with `lifecycle:
  :schedule` and `schedule`, its id. The row is agent-wide and ends with
  that schedule, held to it when it is written: a live schedule of the
  context's athanor and person that holds a line for Aqua, else
  `:no_schedule`. The gate covers with it only a call whose execution that
  schedule started, so it follows that schedule's runs on whatever day's
  thread they land, and no run of another schedule and no turn of the
  person's own (`Sanctum.ToolGrants`); it ends when the schedule is
  deleted. An action that takes a standing answer for one thread only
  takes one for a schedule too, and still none agent-wide without it.
  Bounds on `:once` or on a deny are refused rather than dropped.
  """

  alias Sanctum.Context

  @type scope :: :once | :thread | :always | :never

  @typedoc "The run a standing allow ends with, as the person names it."
  @type lifecycle :: :execution | :turn | :schedule

  @aqua_line Arca.CronSchedule.aqua_line()

  @typedoc """
  The bounds a person chose for a standing answer: the `lifecycle` it
  ends with, the time it ends at (`until`), the resources it covers
  (`constraint`, a resource kind and its patterns) and the outside
  `sources` it also follows. Each is optional. An answer for a schedule
  names it (`schedule`, its id) with the lifecycle `:schedule`.
  """
  @type bounds :: %{
          optional(:lifecycle) => lifecycle() | nil,
          optional(:schedule) => String.t() | nil,
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
  `check/2` for a decision with its bounds: an agent-wide answer that ends
  with a schedule is held to the rule of an answer for one thread, since
  it covers that schedule's runs alone.
  """
  @spec check(map(), scope(), bounds()) :: :ok | {:error, {:scope_not_permitted, term()}}
  def check(intent, :always, %{lifecycle: :schedule}), do: check(intent, :thread)
  def check(intent, scope, _bounds), do: check(intent, scope)

  @doc """
  Whether an answer of `scope` (`:thread`, `:always`, or `:schedule`, an
  agent-wide answer that ends with a schedule) is offered for the card's
  intent: the rule `check/3` holds a decision to, which the card's buttons
  and a stopped schedule turn's sentence both read.
  """
  @spec offered?(map(), :thread | :always | :schedule) :: boolean()
  def offered?(intent, :schedule), do: check(intent, :always, %{lifecycle: :schedule}) == :ok
  def offered?(intent, scope) when scope in [:thread, :always], do: check(intent, scope) == :ok

  @doc """
  The schedules an answer may end with: the context's person's live
  schedules that hold a line for Aqua in the context's athanor, oldest
  first, each `%{id, name}`. None when they cannot be read.
  """
  @spec schedules(Context.t()) :: {:ok, [%{id: String.t(), name: String.t()}]}
  def schedules(%Context{user_id: user_id} = ctx) do
    case Arca.CronSchedule.list(Context.actor(ctx), kind: "schedule", limit: :infinity) do
      {:ok, rows} ->
        {:ok,
         for row <- Enum.reverse(rows), aqua_line?(row, user_id) do
           %{id: row.id, name: row.name}
         end}

      {:error, _unread} ->
        {:ok, []}
    end
  end

  @doc """
  The grant rows a decision writes with itself, for the agent the turn
  runs: none for `:once`, an allow at thread or agent scope with the
  bounds the person chose, a deny at agent scope for `:never`. Checked
  against the action's standing rule (`Sanctum.ToolGrants.grant_row/2`).
  """
  @spec rows(Context.t(), map(), map(), scope(), bounds()) :: {:ok, [map()]} | {:error, term()}
  def rows(ctx, turn, proposal, scope, bounds \\ %{})

  def rows(_ctx, _turn, _proposal, :once, bounds), do: unbounded(bounds)

  def rows(
        %Context{} = ctx,
        turn,
        %{"tool" => tool, "action" => action} = proposal,
        scope,
        bounds
      )
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
    with {:ok, bounds} <- own_row(proposal, effect, bounds),
         {:ok, bound} <- bound(ctx, turn, {grant_scope, effect}, bounds),
         {:ok, row} <- Sanctum.ToolGrants.grant_row(ctx, Map.merge(attrs, bound)) do
      {:ok, [row]}
    end
  end

  def rows(_ctx, _turn, _proposal, _scope, bounds), do: unbounded(bounds)

  # An allow for an action that names a program row stands for the row
  # the call names and no other (`Sanctum.ToolGrants`): its constraint is
  # that row, whatever the card sent, written only while the row is the
  # one the card showed (`program_epoch`, the call's own epoch); a call
  # that names none takes no standing answer.
  defp own_row(%{"tool" => tool, "action" => action} = proposal, "allow", bounds) do
    case Sanctum.Catalog.action_declaration("#{tool}.#{action}") do
      {:ok, %{resource: {argument, :program_row}}} ->
        case get_in(proposal, ["args", argument]) do
          row_id when is_binary(row_id) ->
            {:ok,
             bounds
             |> Map.put(:constraint, %{kind: "program_row", patterns: [row_id]})
             |> Map.put(:program_epoch, get_in(proposal, ["args", "epoch"]))}

          _none ->
            {:error, {:scope_not_permitted, :unconstrained_program}}
        end

      _other ->
        {:ok, bounds}
    end
  end

  defp own_row(_proposal, _effect, bounds), do: {:ok, bounds}

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
    with {:ok, lifecycle} <- lifecycle(ctx, turn, row, bounds) do
      {:ok,
       Map.merge(lifecycle, %{
         expires_at: Map.get(bounds, :until),
         constraint: Map.get(bounds, :constraint),
         sources: Map.get(bounds, :sources),
         program_epoch: Map.get(bounds, :program_epoch)
       })}
    end
  end

  defp lifecycle(ctx, turn, row, bounds) do
    case {Map.get(bounds, :lifecycle), Map.get(bounds, :schedule)} do
      {nil, nil} -> {:ok, %{}}
      {kind, nil} -> ended_with(ctx, turn, row, kind)
      {:schedule, id} -> schedule(ctx, row, id)
      {_kind, _schedule} -> {:error, {:scope_not_permitted, :invalid_lifecycle}}
    end
  end

  defp ended_with(_ctx, _turn, {_scope, "deny"}, kind)
       when kind in [:execution, :turn, :schedule],
       do: {:ok, %{lifecycle_kind: Atom.to_string(kind)}}

  defp ended_with(_ctx, %{root_execution_id: id}, _row, :execution) when is_binary(id),
    do: {:ok, %{lifecycle_kind: "execution", lifecycle_id: id}}

  defp ended_with(_ctx, %{id: id}, _row, :turn) when is_binary(id),
    do: {:ok, %{lifecycle_kind: "turn", lifecycle_id: id}}

  # An answer that ends with a schedule names the schedule.
  defp ended_with(_ctx, _turn, _row, :schedule),
    do: {:error, {:scope_not_permitted, :no_schedule}}

  defp ended_with(_ctx, _turn, _row, _kind),
    do: {:error, {:scope_not_permitted, :invalid_lifecycle}}

  # An agent-wide allow ends with the schedule the person named, while it
  # is one of theirs that holds a line for Aqua, read in the caller's
  # athanor: another athanor's, another person's or a deleted one is no
  # schedule to name. A deny's is passed on for the rule to refuse.
  defp schedule(_ctx, {"agent", "deny"}, _id), do: {:ok, %{lifecycle_kind: "schedule"}}

  defp schedule(%Context{user_id: user_id} = ctx, {"agent", "allow"}, id) when is_binary(id) do
    case Arca.CronSchedule.get(Context.actor(ctx), id) do
      {:ok, row} ->
        if aqua_line?(row, user_id),
          do: {:ok, %{lifecycle_kind: "schedule", lifecycle_id: id}},
          else: {:error, {:scope_not_permitted, :no_schedule}}

      {:error, :not_found} ->
        {:error, {:scope_not_permitted, :no_schedule}}

      {:error, _unread} = error ->
        error
    end
  end

  defp schedule(_ctx, _row, _id), do: {:error, {:scope_not_permitted, :invalid_lifecycle}}

  defp aqua_line?(row, user_id) do
    row.kind == "schedule" and row.reference == @aqua_line and row.status != "deleted" and
      is_binary(user_id) and row.user_id == user_id
  end
end
