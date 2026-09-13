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

  ## An agent's answers live in its estate

  An agent belongs to the estate whose `aqua/` tree holds it, and a tape
  runs its own estate's agents alone, so every row is keyed by the estate
  in focus: a conversation-scope answer by the thread, an agent-scope one
  by the estate and the agent's name.

  ## Destructive and external actions take no standing allow

  Both scopes answer for calls nobody has seen yet, so a standing
  **allow** for a `destructive` or `external` action is refused here — in
  the write path itself, not only in the runner's card handler — with the
  kind derived from the registry annotation, the same source the card
  shows. A standing **deny** stands: "never do this" is exactly the
  standing answer a destructive action should be able to take.

  ## An action may say how far a standing allow reaches

  A tool declares `standing:` beside `kind:` on an action. `false` means
  no standing allow at any scope (a pinned page, read into every turn, is
  changed one click at a time); `:conversation` means a standing allow for
  one conversation and never agent scope (a filed note follows the thread
  it was kept from, not the agent). Absent means either scope. The same
  declaration is minted into the approval intent the runner checks, so
  the two gates cannot disagree.
  """

  alias Arca.Schemas.ToolGrant
  alias Arca.ToolGrantStorage
  alias Sanctum.Context

  @scopes ToolGrant.scopes()
  @effects ToolGrant.effects()

  @type key :: {tool :: String.t(), action :: String.t()}

  @typedoc "One effective decision: the mode, and whether a grant or the author made it."
  @type decision :: {:auto | :ask | :deny, :authored | :grant}

  @doc """
  The effective policy for a turn, as the guest reads it: `effective/2`
  projected to `"auto" | "ask" | "deny"`. The only thing that should ever
  be handed to a turn — the soul's or a role's — as its policy.
  """
  @spec resolve(map(), [Arca.Schemas.ToolGrant.t()]) :: map()
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

  Then the decisions: a standing allow makes its pair `:auto` (a grant's);
  a standing deny KEEPS its pair, as `:deny` — an absent key would let a
  surviving glob answer, and the guest stops at a present one. Last the
  ceiling: an `:auto` on a destructive or external action, or on an
  action whose kind is unknown, becomes `:ask`; an action a catalogued
  tool does not have is dropped. A hand-edited file reaches the guest
  already within the rule.
  """
  @spec effective(map(), [Arca.Schemas.ToolGrant.t()]) :: %{String.t() => decision()}
  def effective(authored, grants) when is_map(authored) and is_list(grants) do
    {denied, allowed} = Enum.split_with(grants, &(&1.effect == "deny"))

    authored
    |> expand_globs()
    |> Map.merge(Map.new(standing_allows(allowed), fn g -> {key_string(g), {:auto, :grant}} end))
    |> Map.merge(Map.new(denied, fn g -> {key_string(g), {:deny, :grant}} end))
    |> ceiling()
  end

  @doc "The guest's spelling of `effective/2`: `\"auto\" | \"ask\" | \"deny\"` per key."
  @spec to_guest(%{String.t() => decision()}) :: map()
  def to_guest(decisions) when is_map(decisions),
    do: Map.new(decisions, fn {key, {mode, _by}} -> {key, Atom.to_string(mode)} end)

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
  # would still accept it as a standing allow — the same rule `put/2`
  # applies at the write, applied again at every read. A row written
  # before an action gained `standing: false` (or by a surface that never
  # went through `put/2`) must not auto-run anything; it simply stops
  # counting. A deny is always honoured.
  defp standing_allows(rows) do
    Enum.filter(rows, fn row ->
      is_map(row) and check_standing(row, Map.get(row, :scope, "conversation"), "allow") == :ok
    end)
  end

  @typedoc "The grant store could not be read — the caller refuses rather than composes without it."
  @type unavailable :: {:unavailable, String.t()}

  @unavailable {:unavailable, "The standing answers"}

  @doc """
  The standing decisions bearing on one conversation and one agent: this
  thread's own, and the agent-scope ones of the estate.

  A store that cannot be read is `{:error, {:unavailable, _}}`, never an
  empty list: "no rows" would drop every deny and leave an authored
  `auto` automatic — an outage must stop the turn, not widen it.
  """
  @spec for_conversation(Context.t(), String.t(), String.t()) ::
          {:ok, [ToolGrant.t()]} | {:error, unavailable()}
  def for_conversation(%Context{} = ctx, conversation_id, agent_name) do
    with {:ok, by_agent} <- for_agents(ctx, conversation_id, [agent_name]) do
      {:ok, Map.get(by_agent, agent_name, [])}
    end
  end

  @doc """
  `for_conversation/3` for every agent of a roster at once — one read of
  the thread's rows, split by agent name — so a turn composes the soul
  AND each role it may clone into from the standing decisions made for
  that agent, with no read per role. Fails closed like it.
  """
  @spec for_agents(Context.t(), String.t(), [String.t()]) ::
          {:ok, %{String.t() => [ToolGrant.t()]}} | {:error, unavailable()}
  def for_agents(%Context{} = ctx, conversation_id, names) when is_list(names) do
    case ToolGrantStorage.list_for_conversation(Context.athanor!(ctx), conversation_id) do
      {:ok, rows} ->
        by_name = rows |> Enum.filter(&(&1.agent_name in names)) |> Enum.group_by(& &1.agent_name)
        {:ok, Map.new(names, &{&1, Map.get(by_name, &1, [])})}

      {:error, _reason} ->
        {:error, @unavailable}
    end
  end

  @doc """
  Every `{agent_name, tool, action}` a conversation currently auto-approves
  by a grant, for every agent that has rows in it — the runner's fast
  path, keyed by the agent a card names, so an answer given for one
  agent never runs another's card. Standing-checked and deny-subtracted
  per agent exactly as `allowed_keys/1`. Fails closed like the reads.
  """
  @spec allowed_by_agent(Context.t(), String.t()) ::
          {:ok, MapSet.t({String.t(), String.t(), String.t()})} | {:error, unavailable()}
  def allowed_by_agent(%Context{} = ctx, conversation_id) do
    case ToolGrantStorage.list_for_conversation(Context.athanor!(ctx), conversation_id) do
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
  The `{tool, action}` pairs a conversation currently auto-approves BY A
  GRANT — what the runner's fast path checks before re-asking, and what
  the chat shows as its standing grants. An authored `auto` never mints a
  card, so it is never here; a deny for the same pair subtracts, so a
  pair a person refused cannot be auto on the fast path while denied in
  the policy.
  """
  @spec allowed_keys([Arca.Schemas.ToolGrant.t()]) :: MapSet.t(key())
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
  Record a decision. `scope` is `"conversation"` or `"agent"`, `effect`
  `"allow"` or `"deny"`. A standing allow for a destructive or external
  action is refused outright at either scope; a deny is always recordable.
  """
  @spec put(Context.t(), map()) :: {:ok, ToolGrant.t()} | {:error, term()}
  def put(%Context{} = ctx, %{scope: scope, effect: effect} = attrs)
      when scope in @scopes and effect in @effects do
    with {:ok, row} <- row(ctx, attrs), do: ToolGrantStorage.put(row)
  end

  @doc """
  The row a decision writes, checked and not written: `put/2`'s attrs
  with the athanor, the deciding person and the conversation the scope
  keys on, for a caller that lands it inside a transaction of its own
  (`Arca.ToolGrantStorage.put/1`).
  """
  @spec row(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def row(%Context{} = ctx, %{scope: scope, effect: effect} = attrs)
      when scope in @scopes and effect in @effects do
    with :ok <- check_standing(attrs, scope, effect) do
      {:ok,
       attrs
       |> Map.merge(%{athanor_id: Context.athanor!(ctx), granted_by: ctx.user_id})
       |> Map.put(:conversation_id, conversation_for(scope, attrs))}
    end
  end

  @doc """
  The sentence a person reads when a standing answer was refused — one per
  reason a `{:scope_not_permitted, reason}` can carry, whether it came
  from this module's write path or from the runner's own check of the
  card's intent (which spells the kind as the intent stores it, a
  string). The atom is the machine's; nobody should read `never_standing`.
  """
  @spec refusal_message({:scope_not_permitted, term()}) :: String.t()
  def refusal_message({:scope_not_permitted, kind})
      when kind in [:destructive, :external, "destructive", "external"],
      do: "A #{kind} action always asks — it takes no standing answer."

  def refusal_message({:scope_not_permitted, :never_standing}),
    do: "This action is decided one click at a time — it takes no standing answer."

  def refusal_message({:scope_not_permitted, :conversation_only}),
    do:
      "This action can be pre-answered for this conversation only, not for the agent everywhere."

  def refusal_message({:scope_not_permitted, :unknown_kind}),
    do: "This action's kind is unknown, so no standing answer was recorded."

  def refusal_message({:scope_not_permitted, _other}),
    do: "A standing answer is not permitted for this action — decide it once."

  @doc "Withdraw a decision. Idempotent — a pair nobody granted is already withdrawn."
  @spec revoke(Context.t(), map()) :: :ok | {:error, term()}
  def revoke(%Context{} = ctx, %{scope: scope} = attrs) when scope in @scopes do
    attrs
    |> Map.put(:athanor_id, Context.athanor!(ctx))
    |> Map.put(:conversation_id, conversation_for(scope, attrs))
    |> ToolGrantStorage.delete()
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # Standing allows require a known read, write or execute kind and must
  # satisfy the action's standing declaration. Destructive and external
  # actions always require approval; standing denies can always be recorded.
  # Use Aqua.Kinds for both the kind and standing limits.
  defp check_standing(_attrs, _scope, "deny"), do: :ok

  # A row whose scope or effect is outside the vocabulary — nothing writes
  # one, but a stored row is read back trusting nobody — counts for no
  # standing allow.
  defp check_standing(_attrs, scope, _effect) when scope not in @scopes,
    do: {:error, {:scope_not_permitted, :unknown_kind}}

  defp check_standing(%{tool: tool, action: action}, scope, "allow")
       when is_binary(tool) and is_binary(action) and scope in @scopes do
    case Aqua.Kinds.kind_for(tool, action) do
      k when k in [:destructive, :external] -> {:error, {:scope_not_permitted, k}}
      nil -> {:error, {:scope_not_permitted, :unknown_kind}}
      _ -> check_declared_standing(tool, action, scope)
    end
  end

  defp check_declared_standing(tool, action, scope) do
    case Aqua.Kinds.standing_for(tool, action) do
      false -> {:error, {:scope_not_permitted, :never_standing}}
      :conversation when scope == "agent" -> {:error, {:scope_not_permitted, :conversation_only}}
      _ -> :ok
    end
  end

  # An agent-scope row names no conversation: it is the same answer in
  # every thread, and storing the one it happened to be given in would
  # make the key ambiguous.
  defp conversation_for("agent", _attrs), do: nil
  defp conversation_for("conversation", attrs), do: Map.fetch!(attrs, :conversation_id)

  defp key_string(%{tool: tool, action: action}), do: "#{tool}.#{action}"
end
