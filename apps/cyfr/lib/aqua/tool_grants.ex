# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolGrants do
  @moduledoc """
  Standing approvals: what a person already answered about one
  `tool.action`, and how that composes with the agent's declared policy.

  Two sources, one rule:

    * **Declared** — the agent's markdown `tool_policy`. The author's
      intent, edited on the agents page. A chat click never writes here.
    * **Granted** — a `tool_grants` row. What a human answered when the
      agent asked. `"allow"` makes the pair automatic; `"deny"` is the
      decline verb, and it **beats a declared `"auto"`** — a person who
      said "never" outranks a default they did not write.

  `resolve/2` is the composition, and it is the only thing that should
  ever be handed to a turn as its policy.

  ## Agent scope follows the agent

  An agent-scope row is written only while the agent's owner IS the
  focused estate — "Always" clicked in a shared estate must not follow a
  borrowed agent home (`authorize_scope/3`). But once written at home, the
  row travels: `for_conversation/4` reads the **owner** athanor's
  agent-scope rows wherever the agent runs, so "always" and "never"
  answered in your own estate hold in every thread you bring the agent to.
  Write narrow, read wide — the decision is made where the agent lives,
  and applies wherever it works.

  ## A foreign standing answer narrows, loudly

  "Always"/"Never" clicked for a borrowed agent cannot write agent scope —
  but silently doing nothing would leave the person believing a standing
  answer stood. `put/2` writes **conversation scope instead** and says so:
  the success shape is `{:ok, %{row: row, narrowed?: boolean}}`, and a
  narrowed answer is the caller's to surface. `:never` on a borrowed agent
  is a conversation-scope deny — the verb exists in both directions.

  ## Destructive and external actions take no standing allow

  Both scopes answer for calls nobody has seen yet, so a standing
  **allow** for a `destructive` or `external` action is refused here — in
  the write path itself, not only in the runner's card handler — with the
  kind derived from the registry annotation, the same source the card
  shows. A standing **deny** stands: "never do this" is exactly the
  standing answer a destructive action should be able to take.
  """

  alias Arca.ToolGrantStorage
  alias Sanctum.Context

  @scopes ~w(conversation agent)
  @effects ~w(allow deny)

  @type key :: {tool :: String.t(), action :: String.t()}

  @doc """
  The effective policy for a turn: the agent's declared policy with the
  standing decisions applied.

  `grants` is what `for_conversation/4` read. Allowed pairs become
  `"auto"`; denied pairs are removed outright, so an action a person
  refused is not merely demoted to "ask" — it leaves the surface, which is
  what makes it uncallable.
  """
  @spec resolve(map(), [Arca.Schemas.ToolGrant.t()]) :: map()
  def resolve(declared, grants) when is_map(declared) and is_list(grants) do
    {denied, allowed} = Enum.split_with(grants, &(&1.effect == "deny"))

    declared
    |> Map.merge(Map.new(allowed, fn g -> {key_string(g), "auto"} end))
    |> Map.drop(Enum.map(denied, &key_string/1))
  end

  @doc """
  The standing decisions bearing on one conversation and one agent — this
  thread's own, plus the agent-scope ones that follow the agent from its
  OWNER's estate. When the owner is the focus, the focus read already
  carries them; when the agent is borrowed, the owner's are read where
  they live.
  """
  @spec for_conversation(Context.t(), String.t(), String.t(), String.t()) ::
          [Arca.Schemas.ToolGrant.t()]
  def for_conversation(%Context{} = ctx, conversation_id, agent_athanor_id, agent_name) do
    focus = Context.athanor!(ctx)

    local =
      focus
      |> ToolGrantStorage.list_for_conversation(conversation_id)
      |> Enum.filter(&(&1.agent_athanor_id == agent_athanor_id and &1.agent_name == agent_name))

    followed =
      if agent_athanor_id == focus,
        do: [],
        else: ToolGrantStorage.list_agent_scope(agent_athanor_id, agent_name)

    local ++ followed
  end

  @doc """
  The `{tool, action}` pairs a conversation currently auto-approves — what
  the runner's fast path checks before re-asking, and what the chat shows
  as its standing grants.
  """
  @spec allowed_keys([Arca.Schemas.ToolGrant.t()]) :: MapSet.t(key())
  def allowed_keys(grants) when is_list(grants) do
    for %{effect: "allow", tool: tool, action: action} <- grants,
        into: MapSet.new(),
        do: {tool, action}
  end

  @doc """
  Whether this estate may make a decision at this scope for this agent.

  Conversation scope is always available. Agent scope requires the agent's
  owner to be the focused estate — see the moduledoc.
  """
  @spec authorize_scope(Context.t(), String.t(), String.t()) ::
          :ok | {:error, {:scope_not_permitted, :foreign_agent}}
  def authorize_scope(%Context{} = _ctx, "conversation", _agent_athanor_id), do: :ok

  def authorize_scope(%Context{} = ctx, "agent", agent_athanor_id) do
    if Context.athanor!(ctx) == agent_athanor_id,
      do: :ok,
      else: {:error, {:scope_not_permitted, :foreign_agent}}
  end

  @doc """
  Record a decision. `scope` is `"conversation"` or `"agent"`, `effect`
  `"allow"` or `"deny"`. Success is `{:ok, %{row: row, narrowed?: bool}}`.

  Agent scope for an agent this estate does not own is **narrowed to
  conversation scope** rather than refused or silently dropped —
  `narrowed?: true` on the answer is the caller's cue to say so. An
  agent-scope request that names no conversation to narrow into keeps the
  refusal. A standing allow for a destructive or external action is
  refused outright at either scope.
  """
  @spec put(Context.t(), map()) ::
          {:ok, %{row: Arca.Schemas.ToolGrant.t(), narrowed?: boolean()}} | {:error, term()}
  def put(%Context{} = ctx, %{scope: scope, effect: effect} = attrs)
      when scope in @scopes and effect in @effects do
    agent_athanor_id = Map.fetch!(attrs, :agent_athanor_id)

    with :ok <- check_kind(attrs, effect) do
      case authorize_scope(ctx, scope, agent_athanor_id) do
        :ok ->
          write(ctx, attrs, scope, false)

        {:error, {:scope_not_permitted, :foreign_agent}} = refusal ->
          if is_binary(attrs[:conversation_id]),
            do: write(ctx, attrs, "conversation", true),
            else: refusal
      end
    end
  end

  @doc "Withdraw a decision. Idempotent — a pair nobody granted is already withdrawn."
  @spec revoke(Context.t(), map()) :: :ok | {:error, term()}
  def revoke(%Context{} = ctx, %{scope: scope} = attrs) when scope in @scopes do
    with :ok <- authorize_scope(ctx, scope, Map.fetch!(attrs, :agent_athanor_id)) do
      attrs
      |> Map.put(:athanor_id, Context.athanor!(ctx))
      |> Map.put(:conversation_id, conversation_for(scope, attrs))
      |> ToolGrantStorage.delete()
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp write(ctx, attrs, scope, narrowed?) do
    row =
      attrs
      |> Map.merge(%{
        scope: scope,
        athanor_id: Context.athanor!(ctx),
        granted_by: ctx.user_id
      })
      |> Map.put(:conversation_id, conversation_for(scope, attrs))

    with {:ok, stored} <- ToolGrantStorage.put(row) do
      {:ok, %{row: stored, narrowed?: narrowed?}}
    end
  end

  # A standing ALLOW for a destructive or external action is refused at
  # the write itself — the runner's card handler checks the same rule on
  # the intent's stored kind, but this is the SSOT for grant writes and a
  # future surface must not be able to hand one past it. The kind comes
  # from `Aqua.Actions.kind_for/2` — the SAME classifier the card derives
  # its risk from: the virtual-tool catalog (`files`/`storage`/`http` are
  # callable but live in the formula, not the registry), then the
  # `server:tool` external namespace, then the registry annotation. A nil
  # kind is refused too: "not known" and "registry not up yet" read the
  # same here, and only the second could otherwise write a standing allow
  # for something destructive. A deny needs no kind — "never do this" is
  # always recordable.
  defp check_kind(_attrs, "deny"), do: :ok

  defp check_kind(%{tool: tool, action: action}, "allow")
       when is_binary(tool) and is_binary(action) do
    case Aqua.Actions.kind_for(tool, action) do
      k when k in [:destructive, :external] -> {:error, {:scope_not_permitted, k}}
      nil -> {:error, {:scope_not_permitted, :unknown_kind}}
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
