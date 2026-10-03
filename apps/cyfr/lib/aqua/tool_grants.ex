# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolGrants do
  @moduledoc """
  Standing approvals: what a person already answered about one
  `tool.action`, and how that composes with the agent's declared policy.

  Two sources, one rule:

    * **Declared** — the agent's markdown `tool_policy`. The author's
      intent, edited on the AQUA page. A chat click never writes here.
    * **Granted** — a `tool_grants` row. What a human answered when the
      agent asked. `"allow"` makes the pair automatic; `"deny"` is the
      decline verb, and it **beats a declared `"auto"`** — a person who
      said "never" outranks a default they did not write.

  `resolve/2` is the composition, and it is the only thing that should
  ever be handed to a turn as its policy.

  ## An agent's answers live in its athanor

  An agent belongs to the athanor whose `aqua/` tree holds it, and a tape
  runs its own athanor's agents alone, so every row is keyed by the athanor
  in focus: a thread-scope answer by the thread, an agent-scope one
  by the athanor and the agent's name.

  ## Which answers may stand is the identity domain's rule

  Both scopes answer for calls nobody has seen yet, so a standing
  **allow** for a `destructive` or `external` action is refused, and an
  action's `standing:` declaration says how far one reaches: `false` none
  at any scope (a pinned page, read into every turn, is changed one click
  at a time), `:thread` one thread and never agent scope (a filed note
  follows the thread it was kept from, not the agent). A standing
  **deny** always stands: "never do this" is exactly the standing answer
  a destructive action should be able to take. The rule is
  `Sanctum.ToolGrants.check_standing/2`, applied at the write and again
  to every row read here; the same declaration is minted into the
  approval intent the runner checks, so the two gates cannot disagree.

  ## A bounded allow asks

  An allow may carry bounds: the execution, turn or schedule it ends
  with, a deadline, and the resources it covers. `effective/2` keeps them
  on the pair's decision, and the guest reads the pair as `"ask"`: no
  bounded allow is automatic for a whole turn. Each call is decided as it
  is made, and again as it dispatches, by `Sanctum.ToolGrants.admits?/2`
  against the rows as they stand then (`Aqua.Loop.Policy`). A bounded
  allow never narrows what the author made automatic.
  """

  alias Sanctum.Context

  @scopes Sanctum.ToolGrants.scopes()
  @effects Sanctum.ToolGrants.effects()

  # The bounds an allow may carry, as its row names them.
  @bounds [:lifecycle_kind, :lifecycle_id, :expires_at, :constraint]

  @type key :: {tool :: String.t(), action :: String.t()}

  @typedoc "One stored grant, as the plain map `Sanctum.ToolGrants` answers."
  @type grant :: %{required(:scope) => String.t(), optional(atom()) => term()}

  @typedoc """
  A bounded allow's bounds, as its row holds them: the scope it was given
  at, the lifecycle it ends with, its deadline and its constraint.
  """
  @type bounds :: %{
          scope: String.t() | nil,
          lifecycle_kind: String.t() | nil,
          lifecycle_id: String.t() | nil,
          expires_at: DateTime.t() | nil,
          constraint: map() | :corrupt | nil
        }

  @typedoc """
  One effective decision: the mode, and who made it — the author, a
  standing grant, or bounded allows, whose bounds it keeps.
  """
  @type decision :: {:auto | :ask | :deny, :authored | :grant | {:bounded, [bounds()]}}

  @doc """
  The effective policy for a turn, as the guest reads it: `effective/2`
  projected to `"auto" | "ask" | "deny"`. The only thing that should ever
  be handed to a turn — the soul's or a role's — as its policy.
  """
  @spec resolve(map(), [grant()]) :: map()
  def resolve(declared, grants) when is_map(declared) and is_list(grants) do
    declared |> effective(grants) |> to_guest()
  end

  @doc """
  The effective decisions: the agent's authored policy with the standing
  decisions applied and the kind ceiling on top, every decision keyed by
  an exact `tool.action` and carrying who made it.

  Three classes of key. A catalogued tool action — the virtual catalog's
  or the registry's — is decided exactly: a `tool.*` glob is expanded to
  the tool's actions and the glob itself dropped, so no glob can answer
  for a pair a person decided. A role delegation key (`name`, `name.*`)
  and the `native_search` gate are not tool actions; they pass through
  untouched. A key for a tool nobody catalogues passes through too — the
  guest offers no such tool.

  Then the decisions: a bounded allow keeps its bounds on its pair, as
  `{:auto, {:bounded, bounds}}`, unless the author already made the pair
  automatic; an unbounded allow makes its pair `:auto` (a grant's); a
  standing deny KEEPS its pair, as `:deny` — an absent key would let a
  surviving glob answer, and the guest stops at a present one. Last the
  ceiling: an `:auto` on a destructive or external action, or on an
  action whose kind is unknown, becomes `:ask`; an action a catalogued
  tool does not have is dropped. A hand-edited file reaches the guest
  already within the rule.
  """
  @spec effective(map(), [grant()]) :: %{String.t() => decision()}
  def effective(authored, grants) when is_map(authored) and is_list(grants) do
    {denied, allowed} = Enum.split_with(grants, &(&1.effect == "deny"))
    {bounded, unbounded} = allowed |> standing_allows() |> Enum.split_with(&bounded?/1)

    authored
    |> expand_globs()
    |> with_bounded(bounded)
    |> Map.merge(Map.new(unbounded, fn g -> {key_string(g), {:auto, :grant}} end))
    |> Map.merge(Map.new(denied, fn g -> {key_string(g), {:deny, :grant}} end))
    |> ceiling()
  end

  @doc """
  The guest's spelling of `effective/2`: `"auto" | "ask" | "deny"` per
  key. A bounded allow is `"ask"`: it covers only the calls its bounds
  admit, each decided as it is made.
  """
  @spec to_guest(%{String.t() => decision()}) :: map()
  def to_guest(decisions) when is_map(decisions),
    do: Map.new(decisions, fn {key, decision} -> {key, guest_mode(decision)} end)

  defp guest_mode({:auto, {:bounded, _bounds}}), do: "ask"
  defp guest_mode({mode, _by}), do: Atom.to_string(mode)

  # A bounded allow joins its pair's decision, kept beside any other
  # bounded allow for the pair. It never narrows an authored `auto`, and
  # an unbounded allow or a deny merged after it outranks it.
  defp with_bounded(decisions, bounded) do
    Enum.reduce(bounded, decisions, fn grant, acc ->
      bounds = bounds_of(grant)

      Map.update(acc, key_string(grant), {:auto, {:bounded, [bounds]}}, fn
        {:auto, :authored} = authored -> authored
        {:auto, {:bounded, kept}} -> {:auto, {:bounded, kept ++ [bounds]}}
        {_mode, _by} -> {:auto, {:bounded, [bounds]}}
      end)
    end)
  end

  defp bounds_of(grant),
    do: Map.new([:scope | @bounds], &{&1, Map.get(grant, &1)})

  defp bounded?(grant), do: Enum.any?(@bounds, &(not is_nil(Map.get(grant, &1))))

  # Authored values are `"ask" | "auto"` (the parser's grammar); anything
  # else in a file is read as ask, the fail-closed reading the guest
  # shares.
  defp authored_decision("auto"), do: {:auto, :authored}
  defp authored_decision(_), do: {:ask, :authored}

  defp expand_globs(authored) do
    Enum.reduce(authored, %{}, fn {key, value}, acc ->
      case String.split(key, ".", parts: 2) do
        [tool, "*"] ->
          case Aqua.Kinds.actions_of(tool) do
            # A role's glob, or a tool nobody catalogues: not a tool action.
            [] ->
              Map.put(acc, key, authored_decision(value))

            actions ->
              Enum.reduce(
                actions,
                acc,
                &Map.put_new(&2, "#{tool}.#{&1}", authored_decision(value))
              )
          end

        _ ->
          Map.put(acc, key, authored_decision(value))
      end
    end)
    # An exact key the author wrote outranks what a glob expanded to.
    |> then(fn expanded ->
      Enum.reduce(authored, expanded, fn {key, value}, acc ->
        if String.ends_with?(key, ".*"),
          do: acc,
          else: Map.put(acc, key, authored_decision(value))
      end)
    end)
  end

  defp ceiling(decisions) do
    decisions
    |> Enum.flat_map(fn {key, {mode, by}} = decision ->
      case String.split(key, ".", parts: 2) do
        [tool, action] when action != "*" ->
          cond do
            not Aqua.Kinds.catalogued?(tool) ->
              [decision]

            action not in Aqua.Kinds.actions_of(tool) ->
              []

            mode == :auto and not Aqua.Kinds.auto_permitted?(tool, action) ->
              [{key, {:ask, by}}]

            true ->
              [decision]
          end

        _ ->
          [decision]
      end
    end)
    |> Map.new()
  end

  # An allow row is honoured only while the action's current declaration
  # would still accept it as a standing allow — the rule the write applies
  # (`Sanctum.ToolGrants.check_standing/2`), applied again at every read. A
  # row written before an action gained `standing: false` (or by a surface
  # that never went through the write) must not auto-run anything; it
  # simply stops counting. A deny is always honoured. A row that names no
  # scope is read at thread scope, the narrower.
  defp standing_allows(rows) do
    now = DateTime.utc_now()

    Enum.filter(rows, fn row ->
      is_map(row) and
        Sanctum.ToolGrants.check_standing(Map.put_new(row, :scope, "thread"), now) == :ok
    end)
  end

  @typedoc "The grant store could not be read — the caller refuses rather than composes without it."
  @type unavailable :: {:unavailable, String.t()}

  @unavailable {:unavailable, "The standing answers"}

  @doc """
  The standing decisions bearing on one thread and one agent: this
  thread's own, and the agent-scope ones of the athanor.

  A store that cannot be read is `{:error, {:unavailable, _}}`, never an
  empty list: "no rows" would drop every deny and leave an authored
  `auto` automatic — an outage must stop the turn, not widen it.
  """
  @spec for_thread(Context.t(), String.t(), String.t()) ::
          {:ok, [grant()]} | {:error, unavailable()}
  def for_thread(%Context{} = ctx, thread_id, agent_name) do
    with {:ok, by_agent} <- for_agents(ctx, thread_id, [agent_name]) do
      {:ok, Map.get(by_agent, agent_name, [])}
    end
  end

  @doc """
  `for_thread/3` for every agent of a roster at once — one read of
  the thread's rows, split by agent name — so a turn composes the soul
  AND each role it may clone into from the standing decisions made for
  that agent, with no read per role. Fails closed like it.
  """
  @spec for_agents(Context.t(), String.t(), [String.t()]) ::
          {:ok, %{String.t() => [grant()]}} | {:error, unavailable()}
  def for_agents(%Context{} = ctx, thread_id, names) when is_list(names) do
    case Sanctum.ToolGrants.for_thread(ctx, thread_id) do
      {:ok, rows} ->
        by_name = rows |> Enum.filter(&(&1.agent_name in names)) |> Enum.group_by(& &1.agent_name)
        {:ok, Map.new(names, &{&1, Map.get(by_name, &1, [])})}

      {:error, _reason} ->
        {:error, @unavailable}
    end
  end

  @doc """
  Every `{agent_name, tool, action}` a thread has a standing allow for,
  for every agent that has rows in it: what the thread pane lists as the
  thread's standing answers, each revocable, keyed by the agent the
  answer was given for. Standing-checked and deny-subtracted per agent
  exactly as `allowed_keys/1`. Fails closed like the reads.
  """
  @spec allowed_by_agent(Context.t(), String.t()) ::
          {:ok, MapSet.t({String.t(), String.t(), String.t()})} | {:error, unavailable()}
  def allowed_by_agent(%Context{} = ctx, thread_id) do
    case Sanctum.ToolGrants.for_thread(ctx, thread_id) do
      {:ok, rows} ->
        {:ok,
         rows
         |> Enum.group_by(& &1.agent_name)
         |> Enum.flat_map(fn {name, agent_rows} ->
           agent_rows |> allowed_keys() |> Enum.map(fn {tool, action} -> {name, tool, action} end)
         end)
         |> MapSet.new()}

      {:error, _reason} ->
        {:error, @unavailable}
    end
  end

  @doc """
  The `{tool, action}` pairs a person answered with a standing allow that
  still stands — what the chat shows as its standing answers, each
  revocable there. A bounded allow is listed too, though it covers only
  the calls its bounds admit (each decided as it is made, `effective/2`),
  so every standing answer a person gave can be seen and withdrawn. An
  authored `auto` never mints a card, so it is never here; an allow the
  action's current declaration would refuse no longer stands and is not
  here; a deny for the same pair subtracts, since the pair asks no more.
  Nothing decides a call from this list.
  """
  @spec allowed_keys([grant()]) :: MapSet.t(key())
  def allowed_keys(grants) when is_list(grants) do
    denied = grants |> Enum.filter(&(&1.effect == "deny")) |> MapSet.new(&{&1.tool, &1.action})

    grants
    |> Enum.filter(&(&1.effect == "allow"))
    |> standing_allows()
    |> MapSet.new(fn %{tool: tool, action: action} -> {tool, action} end)
    |> MapSet.difference(denied)
  end

  @doc "The grant scopes, as the rows spell them."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Record a decision. `scope` is `"thread"` or `"agent"`, `effect`
  `"allow"` or `"deny"`, and an allow may name its bounds. An answer that
  may not stand is refused with its reason
  (`Sanctum.ToolGrants.check_standing/2`): a standing allow for a
  destructive or external action at either scope, and a deny carrying a
  bound. A plain deny is always recordable.
  """
  @spec put(Context.t(), map()) :: {:ok, grant()} | {:error, term()}
  def put(%Context{} = ctx, %{scope: scope, effect: effect} = attrs)
      when scope in @scopes and effect in @effects,
      do: Sanctum.ToolGrants.put(ctx, attrs)

  @doc """
  The sentence a person reads when a standing answer was refused — one per
  reason a `{:scope_not_permitted, reason}` can carry, whether it came
  from the write path's rule (`Sanctum.ToolGrants.check_standing/2`), from
  the bounds a decision names (`Aqua.Standing`) or from the runner's own
  check of the card's intent (which spells the kind as the intent stores
  it, a string). The atom is the machine's; nobody should read
  `never_standing`.
  """
  @spec refusal_message({:scope_not_permitted, term()}) :: String.t()
  def refusal_message({:scope_not_permitted, kind})
      when kind in [:destructive, :external, "destructive", "external"],
      do: "A #{kind} action always asks — it takes no standing answer."

  def refusal_message({:scope_not_permitted, :never_standing}),
    do: "This action is decided one click at a time — it takes no standing answer."

  def refusal_message({:scope_not_permitted, :thread_only}),
    do: "This action can be pre-answered for this thread only, not for the agent everywhere."

  def refusal_message({:scope_not_permitted, :unknown_kind}),
    do: "This action's kind is unknown, so no standing answer was recorded."

  def refusal_message({:scope_not_permitted, :bounded_deny}),
    do: "A \"never\" answer always stands — it ends with no run or time and covers every path."

  def refusal_message({:scope_not_permitted, :bounds_without_standing}),
    do:
      "Only a standing answer ends with a run or a time, or covers some paths — once takes none."

  def refusal_message({:scope_not_permitted, :invalid_lifecycle}),
    do: "That run is not one this card belongs to, so no answer can end with it."

  def refusal_message({:scope_not_permitted, :no_schedule}),
    do: "This run was not started by a schedule, so no answer can end with one."

  def refusal_message({:scope_not_permitted, :invalid_deadline}),
    do: "The time a standing answer ends at must be a date and time."

  def refusal_message({:scope_not_permitted, :deadline_passed}),
    do: "The time a standing answer ends at has already passed."

  def refusal_message({:scope_not_permitted, :no_resource}),
    do: "This action names no file or domain, so its standing answer cannot be limited to some."

  def refusal_message({:scope_not_permitted, :resource_kind}),
    do: "This action names another kind of resource than the answer is limited to."

  def refusal_message({:scope_not_permitted, :invalid_constraint}),
    do: "The paths or domains the answer is limited to are not valid ones."

  def refusal_message({:scope_not_permitted, _other}),
    do: "A standing answer is not permitted for this action — decide it once."

  @doc "Withdraw a decision. Idempotent — a pair nobody granted is already withdrawn."
  @spec revoke(Context.t(), map()) :: :ok | {:error, term()}
  def revoke(%Context{} = ctx, %{scope: scope} = attrs) when scope in @scopes,
    do: Sanctum.ToolGrants.revoke(ctx, attrs)

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp key_string(%{tool: tool, action: action}), do: "#{tool}.#{action}"
end
