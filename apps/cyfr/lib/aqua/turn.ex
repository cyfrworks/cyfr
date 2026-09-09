# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Turn do
  @moduledoc """
  One AQUA turn: the orchestrator lookup, the road from a picked agent and
  a task to a running execution (`begin/5` — resolve, pin, compose,
  start), the formula input a message becomes, and what the output turns
  into afterwards. `Aqua.ConversationRunner` owns the process, the
  conversation's rows and the cursor over them; this module owns the
  shapes and the turn's start, so the runner stays a state machine over
  messages and a turn can be begun and exercised without one.

  Two roads reach the engine, on purpose: STARTING work (`start/3`, an
  approved app launch) goes through the `execution` MCP tool so it passes
  the same registry gates and audit any external caller's start would;
  everything that manages an execution already started — pin, subscribe,
  cancel, events, status — goes through the `Cyfr.Execution` port directly,
  because those are the harness's own hands on its own turn, not a tool
  call anyone else could make. The runner reads that engine half from
  `:cyfr, :aqua_turn` and hands it to `begin/5` as `:engine`, so a suite
  can stand in a fake for the calls that reach Opus and keep the rest.
  """

  require Logger

  alias Aqua.Orchestrator
  alias Sanctum.Context

  @agent_ref "formula:local.aqua"

  @typedoc """
  One agent's run-time detail, string-keyed as the `aqua` tool projects it
  — `"name"`, `"title"`, `"catalyst_ref"`, `"model"`,
  `"tool_policy"` — the `agent` an `Aqua.Orchestrator` carries once
  resolved.
  """
  @type agent :: %{
          required(String.t()) => term()
        }

  @typedoc """
  What `begin/5` hands the runner to install: the execution to follow,
  the policy its intents are checked against (the composition over the
  standing grants, not the authored one), the resolved agent, the profile
  the turn pinned, and the conversation's standing allows keyed by the
  agent they were answered for.
  """
  @type started :: %{
          execution_id: String.t(),
          tool_policy: map(),
          orchestrator: Orchestrator.t(),
          profile_id: String.t(),
          grants: MapSet.t({String.t(), String.t(), String.t()})
        }

  # ---------------------------------------------------------------------------
  # Orchestrators
  # ---------------------------------------------------------------------------

  @doc """
  Who can be addressed on this tape: the estate's soul first, then its
  roles — the tree in focus and no other. A room's tape is the room's:
  `@aqua` reaches the room's soul, and a role mention (`@aqua_builder`)
  runs that role directly for one turn; a person's own assistant lives in
  their own athanor and rides along in its own panel, never on a shared
  tape.
  """
  @spec roster(Context.t()) :: [map()]
  def roster(%Context{} = ctx) do
    case Aqua.AgentConfig.roster(ctx) do
      {:ok, agents} ->
        Enum.map(agents, fn agent ->
          %{"name" => agent["name"], "title" => agent["title"] || agent["name"]}
        end)

      # Fail-open BY CHOICE, and said in the log by the read itself: an
      # unreadable tree reads as "nobody here" — the chat still renders,
      # which beats refusing the whole conversation for a catalog read.
      # (A SEND with an empty roster and no prior pick is still refused
      # `:no_orchestrator` by the runner, and the turn's own roster read
      # in `build_input/4` refuses outright.)
      {:error, _} ->
        []
    end
  end

  @doc """
  An explicit `@name` in the message names the orchestrator for this turn
  — the roster entry called `name`. Returns `{message_without_mention,
  entry | nil}`: the whole entry, since the caller carries it into the
  turn. Matching longest-first so `@aqua_planner` is not read as `@aqua`
  with a suffix.
  """
  @spec parse_mention(String.t(), [map()]) :: {String.t(), map() | nil}
  def parse_mention(message, orchestrators) do
    if not String.contains?(message, "@") or orchestrators == [] do
      {message, nil}
    else
      orchestrators
      |> Enum.filter(&is_binary(&1["name"]))
      |> Enum.sort_by(&(-String.length(&1["name"])))
      |> Enum.find_value({message, nil}, fn %{"name" => name} = entry ->
        re = Regex.compile!("(?<![\\w@])@#{Regex.escape(name)}(?![\\w.-])", "i")

        if Regex.match?(re, message) do
          cleaned = Regex.replace(re, message, "") |> String.trim()
          {if(cleaned == "", do: message, else: cleaned), entry}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Input
  # ---------------------------------------------------------------------------

  @doc """
  The formula input for one turn.

  `opts`: `:history` (provider-shape messages from the previous turn),
  `:attachments` (`[%{"filename", "media_type", "data"}]`, base64 data),
  `:model` (an override for the orchestrator's model), `:group` (several
  people are speaking, so the task's lines are name-prefixed),
  `:authority` (what the turn is rooted at — the prompt describes only what
  this grants), `:role_grants` (a function from role names to their
  standing rows, so each role's definition is composed like the soul's),
  `:roster` (the estate's tree as already read, so it is not read again),
  `:room_context` (text read for the person beside the task — a room open
  next to this thread — placed as the input's `transient`, never in the
  system prompt and never in the history).

  Two reads, each once: the tree the agent lives in
  (`Aqua.AgentConfig.roster/1` — the orchestrator's own prompt and every
  role come out of it; `begin/5` reads it once and hands it in) and the
  working estate's catalyst listing (`Aqua.AgentConfig.catalyst_listing/1`
  — the orchestrator's model and each role's resolve against it). Neither
  is a tool call per role.

  Returns `{:ok, %{input: map, tool_policy: map}}` — the policy is what the
  turn's intents are later checked against — or a refusal:
  `{:error, {:catalyst_not_in_estate, ref}}` when the agent's model does
  not resolve in the estate the turn runs in (deliberate and crisp: a
  catalyst is a component, components belong to the working estate, and
  handing the formula an unresolved ref surfaced as a confusing runtime
  error instead of "this estate has no such model"); or
  `{:error, {:unavailable, _}}` when the tree cannot be read — a turn is
  never quietly composed on an empty roster.
  """
  @spec build_input(Context.t(), agent(), String.t(), keyword()) ::
          {:ok, %{input: map(), tool_policy: map()}}
          | {:error, {:catalyst_not_in_estate, String.t() | nil}}
          | {:error, {:unavailable, String.t()}}
  def build_input(%Context{} = ctx, %{"name" => _name} = orchestrator, message, opts \\ []) do
    tool_policy = orchestrator["tool_policy"] || %{}

    # The listing is read whether or not the orchestrator pins a model —
    # the roles resolve theirs against it — and a listing that cannot be
    # read is empty here BY CHOICE for the roles (they fall back to the
    # parent's catalyst) while a NAMED orchestrator ref still fails closed
    # below: a model that is not here is not a degraded turn, it is no
    # turn. An agent that pins no catalyst rides nil through to the
    # engine's default.
    with {:ok, roster} <- roster_for(ctx, Keyword.get(opts, :roster)),
         listing = catalyst_listing_or_empty(ctx),
         {:ok, resolved_catalyst} <- resolve_or_pass(listing, orchestrator["catalyst_ref"]),
         {:ok, _protocol} <- Aqua.ModelCatalyst.protocol(resolved_catalyst) do
      # One composer owns the whole prompt — including the aqua-actions
      # protocol, which is an orchestrator's alone (sub-agents are scoped
      # task-runners and never emit UI intents). The authored prompt comes
      # off the roster just read; only an agent the roster does not list
      # (disabled, or a stand-in map) sends the composer back to the tree.
      system_prompt =
        Aqua.Prompt.compose(ctx,
          agent: with_prompt(orchestrator, roster),
          authority: Keyword.get(opts, :authority),
          several_people?: Keyword.get(opts, :group, false)
        )

      sub_agents =
        Aqua.AgentConfig.role_definitions(
          roster,
          listing,
          resolved_catalyst,
          orchestrator["model"],
          role_grants(roster, Keyword.get(opts, :role_grants))
        )

      input =
        %{
          "task" => message,
          "system" => system_prompt,
          "sub_agents" => sub_agents,
          "catalyst_ref" => resolved_catalyst,
          "model" => Keyword.get(opts, :model) || orchestrator["model"]
        }
        |> Aqua.AgentConfig.put_formula_tool_surface(tool_policy)
        |> put_attachments(Keyword.get(opts, :attachments, []))
        |> put_transient(Aqua.Prompt.transient(Keyword.get(opts, :room_context)))
        |> put_messages(Keyword.get(opts, :history, []))

      {:ok, %{input: input, tool_policy: tool_policy}}
    else
      {:error, {:unavailable, _}} = refusal ->
        refusal

      # A model this table does not know: refused here, not sent a
      # Claude-shaped request with every tool silently dropped.
      {:error, {:unsupported_model_catalyst, _}} = refusal ->
        refusal

      {:error, _catalyst_miss} ->
        {:error, {:catalyst_not_in_estate, orchestrator["catalyst_ref"]}}
    end
  end

  # The roster the caller already read (`begin/5` resolves the pick from
  # it), else the estate's tree.
  defp roster_for(_ctx, roster) when is_list(roster), do: {:ok, roster}
  defp roster_for(ctx, _none), do: Aqua.AgentConfig.roster(ctx)

  defp catalyst_listing_or_empty(ctx) do
    case Aqua.AgentConfig.catalyst_listing(ctx) do
      {:ok, components} -> components
      {:error, _} -> []
    end
  end

  # The standing decisions for every role the roster holds, read once from
  # the thread (`Aqua.ToolGrants.for_agents/4`) through the function
  # `begin/5` hands over — or none, for a caller composing a turn without
  # a conversation. A role's definition is composed from them exactly as
  # the soul's is.
  defp role_grants(roster, reader) when is_function(reader, 1) do
    roster
    |> Enum.filter(&(&1["type"] == Compendium.AquaAgent.role_type()))
    |> Enum.map(& &1["name"])
    |> reader.()
  end

  defp role_grants(_roster, _none), do: %{}

  defp with_prompt(%{"name" => name} = orchestrator, roster) do
    case Enum.find(roster, &(&1["name"] == name)) do
      %{"content" => content} when is_binary(content) -> Map.put(orchestrator, "prompt", content)
      _ -> orchestrator
    end
  end

  defp resolve_or_pass(_listing, ref) when ref in [nil, ""], do: {:ok, nil}
  defp resolve_or_pass(listing, ref), do: Aqua.AgentConfig.resolve_catalyst(listing, ref)

  # Read beside the task for this one call: the guest places it as a part
  # of the task's user turn and takes it out before the history comes back.
  defp put_transient(input, nil), do: input
  defp put_transient(input, text), do: Map.put(input, "transient", text)

  defp put_attachments(input, []), do: input
  defp put_attachments(input, attachments), do: Map.put(input, "attachments", attachments)

  defp put_messages(input, []), do: input

  defp put_messages(input, history) when is_list(history) do
    # Strip aqua-actions blocks from assistant turns before handing the
    # history back: the model must not meet its own literal block again and
    # copy it instead of treating it as already executed.
    cleaned = Enum.map(history, &strip_actions_in_message/1)
    Map.put(input, "messages", Aqua.ConversationCompactor.compact(cleaned))
  end

  defp put_messages(input, _), do: input

  defp strip_actions_in_message(%{"role" => "assistant", "content" => content} = msg)
       when is_binary(content) do
    %{msg | "content" => Aqua.Wire.strip_blocks(content)}
  end

  defp strip_actions_in_message(%{"role" => "assistant", "content" => parts} = msg)
       when is_list(parts) do
    %{msg | "content" => Enum.map(parts, &strip_actions_in_part/1)}
  end

  defp strip_actions_in_message(msg), do: msg

  defp strip_actions_in_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => Aqua.Wire.strip_blocks(text)}
  end

  defp strip_actions_in_part(part), do: part

  @doc "How a person is named in a group turn: display name, else email, else id."
  @spec display_name(String.t() | nil) :: String.t()
  defdelegate display_name(user_id), to: Sanctum.Tenancy.Users

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  @doc """
  Begin a turn: resolve the picked agent from the estate's tree, pin the
  profile, compose the formula input, start the execution. The whole road
  from what the runner decided in its loop (who is addressed, what the
  task says) to an execution it can follow — run in the turn-start task,
  never in the runner's `handle_call`, because every step reaches storage
  or MCP.

  The order is the point. The profile is pinned FIRST because the other
  two steps need it: the run must name it rather than re-select one, and
  the prompt must describe what this authority actually grants. The
  grants are keyed by THIS turn's resolved agent, never by runner state —
  the previous turn may have run a different agent, and a first turn has
  no previous at all.

  `opts`: `:engine` — the module answering `pin_profile/1` and `start/3`
  (this one; a suite stands in a fake); `:attachments` — the refs of the
  task's rows (`Aqua.Attachments.attachments_of/1`), loaded here;
  `:history`, `:model`, `:group`, `:room_context` as `build_input/4`
  takes them.

  Refusals: `{:error, :no_orchestrator}` for a name the estate's tree does
  not hold; `pin_profile/1`'s, `build_input/4`'s and the engine's own on
  `start/3` pass through unchanged.
  """
  @spec begin(Context.t(), String.t(), Orchestrator.t(), String.t(), keyword()) ::
          {:ok, started()} | {:error, term()}
  def begin(%Context{} = ctx, conversation_id, %Orchestrator{} = pick, task, opts \\ [])
      when is_binary(conversation_id) and is_binary(task) do
    engine = Keyword.get(opts, :engine, __MODULE__)

    with {:ok, orchestrator, roster} <- Orchestrator.resolve_with_roster(ctx, pick),
         {:ok, authority} <- engine.pin_profile(ctx),
         # Authored policy is the agent's markdown; the standing answers a
         # person already gave are rows — read ONCE for every agent of the
         # roster, so the soul and each role it may clone into compose the
         # same way. A store that cannot be read refuses the turn: composing
         # without the rows would drop every "never".
         {:ok, grants_by_agent} <-
           Aqua.ToolGrants.for_agents(ctx, conversation_id, Enum.map(roster, & &1["name"])),
         {:ok, allowed} <- Aqua.ToolGrants.allowed_by_agent(ctx, conversation_id) do
      orchestrator =
        Orchestrator.with_grants(orchestrator, Map.get(grants_by_agent, orchestrator.name, []))

      attachments =
        Aqua.Attachments.load(ctx, conversation_id, Keyword.get(opts, :attachments, []))

      build =
        build_input(ctx, Orchestrator.for_turn(orchestrator), task,
          history: Keyword.get(opts, :history, []),
          attachments: attachments,
          model: Keyword.get(opts, :model),
          group: Keyword.get(opts, :group, false),
          # The prompt describes what THIS authority grants, so it is
          # composed after the pin, not before it.
          authority: authority,
          room_context: Keyword.get(opts, :room_context),
          roster: roster,
          role_grants: fn names -> Map.take(grants_by_agent, names) end
        )

      with {:ok, %{input: input, tool_policy: tool_policy}} <- build,
           {:ok, execution_id} <- engine.start(ctx, input, authority.profile_id) do
        {:ok,
         %{
           execution_id: execution_id,
           tool_policy: tool_policy,
           orchestrator: orchestrator,
           profile_id: authority.profile_id,
           grants: allowed
         }}
      end
    end
  end

  @doc """
  Resolve — and pin — the profile this turn will run as.

  The first of a turn's three steps: **pin, compose, run**. It exists as a
  step of its own because both of the others need its answer. `run/3` must
  name the profile rather than re-select one, and the prompt composer must
  know what the authority actually grants before it can describe the
  agent's tools honestly.

  `:default` selects the single active owner profile of the agent formula.
  Multiple active owner profiles return `{:ambiguous, ids}` and refuse the turn.

  Returns the resolved `Sanctum.Authority` — the profile id to pin is its
  `:profile_id`.
  """
  @spec pin_profile(Context.t()) :: {:ok, struct()} | {:error, term()}
  def pin_profile(%Context{} = ctx) do
    Cyfr.Execution.authority_for(ctx, :default, @agent_ref)
  end

  @doc """
  Start the AQUA formula as a root execution under `ctx` (the person whose
  message this is — their consented authority, their attribution). Returns
  the execution id; the caller subscribes to its events.

  `profile_id` is what `pin_profile/1` resolved. It is passed explicitly so
  the run cannot select a *different* profile than the one the turn was
  composed for, and it lands on the execution row as the record of which
  consent this turn ran under.
  """
  @spec start(Context.t(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def start(%Context{} = ctx, input, profile_id)
      when is_map(input) and is_binary(profile_id) do
    result =
      Aqua.Ops.call_tool("execution", ctx, %{
        "action" => "run_stream",
        "reference" => @agent_ref,
        "input" => input,
        "profile" => profile_id
      })

    # Normalize once, match one spelling — keeping both an atom-key and a
    # string-key clause after normalizing would leave dead defensive code.
    case result do
      {:ok, reply} ->
        case Aqua.AgentConfig.stringify_deep(reply) do
          %{"execution_id" => eid} -> {:ok, eid}
          other -> {:error, {:no_execution_id, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether an execution engine is registered and ready."
  @spec engine_available?() :: boolean()
  def engine_available?, do: Cyfr.Execution.available?()

  @doc "Follow an execution's events from the calling process."
  @spec subscribe(String.t(), Context.t()) :: :ok | {:error, term()}
  def subscribe(execution_id, %Context{} = ctx),
    do: Cyfr.Execution.subscribe_events(execution_id, ctx)

  @doc "Stop following an execution's events."
  @spec unsubscribe(String.t(), Context.t()) :: :ok | {:error, term()}
  def unsubscribe(execution_id, %Context{} = ctx),
    do: Cyfr.Execution.unsubscribe_events(execution_id, ctx)

  @doc "Cancel a running turn."
  @spec cancel(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(%Context{} = ctx, execution_id), do: Cyfr.Execution.cancel(ctx, execution_id)

  @doc "Cancel a running turn because a consent delta applies to future roots."
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel_for_restart(%Context{} = ctx, execution_id, payload),
    do: Cyfr.Execution.cancel_for_restart(ctx, execution_id, payload)

  @doc "The buffered events of an execution (recovery after a restart)."
  @spec events_since(String.t(), String.t()) :: [map()]
  def events_since(execution_id, athanor_id),
    do: Cyfr.Execution.events_since(execution_id, 0, athanor_id)

  @doc "Whether an execution is still running."
  @spec running?(Context.t(), String.t()) :: boolean()
  def running?(%Context{} = ctx, execution_id) do
    match?({:ok, %{status: :running}}, Cyfr.Execution.get(ctx, execution_id))
  end

  # ---------------------------------------------------------------------------
  # Completion
  # ---------------------------------------------------------------------------

  @doc """
  What a finished turn's text becomes: the display text with the
  aqua-actions block removed, the approval intents (each an
  `%{id, title, summary, proposal, action_kind, ...}` map from
  `Aqua.Wire.parse/2`), the client intents (navigate/copy…), and
  the tripwire notices — intents the agent tried outside its policy, which
  the thread shows as errors.
  """
  @spec parse_completion(String.t(), map()) :: %{
          text: String.t(),
          approvals: [map()],
          intents: [map()],
          tripwires: [String.t()]
        }
  def parse_completion(raw, tool_policy) when is_binary(raw) and is_map(tool_policy) do
    %{stripped: stripped, intents: intents, drops: drops} =
      Aqua.Wire.parse(String.trim(raw), tool_policy)

    # `drop.raw` is the model's verbatim entry — a rejected clipboard write
    # alone can carry 100KB — so the log gets the refusal and a bounded
    # kind, never the content.
    Enum.each(drops, fn drop ->
      kind = if is_map(drop.raw), do: drop.raw["kind"], else: nil

      Logger.warning(
        "[Aqua.Turn] dropped aqua-actions intent kind=#{inspect(kind)} reason=#{drop.reason}"
      )
    end)

    {approvals, client} = Enum.split_with(intents, &(&1.kind == "request_approval"))

    %{
      text: stripped,
      approvals: approvals,
      intents: client,
      tripwires: tripwires(drops)
    }
  end

  # Surface request_approval policy violations by their typed drop tag.
  # Other drops, including malformed JSON and unsupported actions, stay
  # in the log.
  defp tripwires(drops) do
    drops
    |> Enum.filter(fn
      %{raw: %{"kind" => "ui.request_approval"}} = drop ->
        Map.get(drop, :tag) in [:not_in_allowlist, :unknown_allowlist_value]

      _ ->
        false
    end)
    |> Enum.map(fn %{reason: reason, raw: raw} ->
      label =
        case raw do
          %{"proposal" => %{"tool" => t, "action" => a}} -> "#{t}.#{a}"
          _ -> "(no proposal)"
        end

      "⚠ Agent requested an action outside policy: #{label} — #{reason}"
    end)
  end

  @doc """
  True when `{agent, tool, action}` is in the conversation's grant set —
  the agent being the one the CARD names, never the runner's current
  turn: an answer given for one agent runs no other agent's card.
  """
  @spec granted?(String.t() | nil, map(), MapSet.t()) :: boolean()
  def granted?(agent, %{proposal: %{tool: t, action: a}}, grants)
      when is_binary(agent) and is_binary(t) and is_binary(a),
      do: MapSet.member?(grants, {agent, t, a})

  def granted?(_agent, _intent, _grants), do: false

  # ---------------------------------------------------------------------------
  # Approvals
  # ---------------------------------------------------------------------------

  @doc """
  Run an approved proposal. The human decision unblocks the call; it never
  supplies authority.

  An approved `execution.run`/`run_stream` is a deliberate app launch: the
  target roots its OWN consented authority (`run_root` re-resolves the ref
  and profile), and the approver's identity supplies only ingress. It runs
  on the external plane — routing it in-chain under the agent's authority
  would leave every app the agent has no edge to inert. Guest-supplied
  lineage keys are dropped, exactly as the in-chain path would.

  Every other approved tool runs under the agent formula's consented
  authority through the in-chain chokepoint, guest-planed so it cannot
  reach the approver's external-plane powers. If that authority is
  unavailable (no profile, revoked, re-consent required) this FAILS CLOSED
  — never falling back to the approver's own context.

  Pass the `profile_id` pinned by the turn so approval uses the same
  consented authority, even when the formula has multiple profiles.
  """
  @spec run_approved(map(), Context.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def run_approved(proposal, ctx, profile_id)

  def run_approved(
        %{tool: "execution", action: action, args: args} = proposal,
        %Context{} = ctx,
        profile_id
      )
      when action in ["run", "run_stream"] do
    reference = (args || %{})["reference"]
    input = (args || %{})["input"] || %{}

    # Decided again here, whatever the card said: the assistant itself is
    # never launched as an app, and a wrapped catalyst is the virtual
    # action its input denotes — run under the kind ceiling and the pinned
    # authority, never as a root. `Aqua.Wire` canonicalises a proposal
    # before the card exists; this is the same rule at the last door.
    cond do
      is_binary(reference) and Aqua.VirtualTools.self_reference?(reference) ->
        {:error, {:invalid_argument, "the assistant itself is not a tool to run"}}

      is_binary(reference) and match?({:ok, _}, Aqua.VirtualTools.canonical(reference, input)) ->
        {:ok, [canonical | _]} = Aqua.VirtualTools.canonical(reference, input)
        run_approved(Map.merge(proposal, canonical), ctx, profile_id)

      true ->
        launch_args =
          (args || %{})
          |> Map.put("action", action)
          |> Map.drop(["parent_execution_id", "root_execution_id"])

        Aqua.Ops.call_tool("execution", ctx, launch_args)
    end
  end

  def run_approved(
        %{tool: tool, action: action, args: args} = proposal,
        %Context{} = ctx,
        profile_id
      )
      when is_binary(tool) and is_binary(action) and is_binary(profile_id) do
    with {:ok, authority} <- Cyfr.Execution.authority_for(ctx, {:id, profile_id}, @agent_ref) do
      cond do
        Aqua.VirtualTools.virtual_tool?(tool) ->
          run_virtual(proposal, ctx, authority)

        Aqua.Ops.child_execution?(tool, action) ->
          run_child_execution(proposal, ctx, authority)

        true ->
          Aqua.Ops.call_in_chain(
            tool,
            Context.enter_guest(ctx),
            Map.put(args || %{}, "action", action),
            authority,
            lineage: registry_lineage(proposal)
          )
      end
    end
  end

  # An approved execution runs as a CHILD of the card's pinned authority
  # — the way the formula host runs one for a chain — with the card's own
  # execution as lineage and the assistant as the invoking reference, so
  # the child's row keeps a digest of its reply, never through the catalog
  # from a guest-planed context.
  defp run_child_execution(%{args: args} = proposal, ctx, authority) do
    args = args || %{}

    case Map.get(args, "reference") do
      reference when is_binary(reference) and reference != "" ->
        lineage = Map.get(proposal, :lineage) || %{}
        execution_id = lineage[:execution_id] || lineage["execution_id"]

        opts =
          [ctx: Context.enter_guest(ctx), parent_reference: @agent_ref]
          |> Arca.QueryHelpers.maybe_put(:parent_execution_id, execution_id)
          |> Arca.QueryHelpers.maybe_put(:root_execution_id, execution_id)

        Cyfr.Execution.run_child(
          authority,
          reference,
          Map.get(args, "need"),
          Map.get(args, "input") || %{},
          opts
        )

      _ ->
        {:error, {:invalid_argument, "execution.run needs a reference"}}
    end
  end

  @doc false
  # The card's own execution and conversation, as the registry stamps
  # them onto an in-chain call: the execution is both parent and root of
  # what the approval runs. Public for its test alone.
  def registry_lineage(%{lineage: %{} = lineage}) do
    execution_id = lineage[:execution_id]

    %{
      parent_execution_id: execution_id,
      root_execution_id: execution_id,
      conversation_id: lineage[:conversation_id]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  def registry_lineage(_proposal), do: %{}

  # An approved virtual action runs the catalyst the guest would have run
  # for it, as a CHILD of the card's pinned authority — the same hop the
  # formula host makes for the guest — with the card's own execution as
  # lineage. Never `call_in_chain("execution", …)`: the registry refuses a
  # guest-planed `execution.run` by design, and never a fresh root. A UI
  # event (`request_setup`) is not a catalyst and has no card to run.
  defp run_virtual(%{tool: tool, action: action, args: args} = proposal, ctx, authority) do
    with {:ok, %{catalyst: catalyst, input: input}} <-
           Aqua.VirtualTools.child_call(tool, action, args || %{}) do
      lineage = Map.get(proposal, :lineage) || %{}
      execution_id = lineage[:execution_id] || lineage["execution_id"]

      opts =
        [ctx: Context.enter_guest(ctx), parent_reference: @agent_ref]
        |> Arca.QueryHelpers.maybe_put(:parent_execution_id, execution_id)
        |> Arca.QueryHelpers.maybe_put(:root_execution_id, execution_id)

      Cyfr.Execution.run_child(authority, catalyst, nil, input, opts)
    else
      {:error, reason} -> {:error, {:invalid_argument, reason}}
    end
  end

  @doc """
  The `{result_summary, system_text}` pair for a resolved approval — the
  short line the card shows, and the synthetic turn appended to the history
  so the agent sees the outcome.
  """
  @spec outcome_summary(:approved | :declined | :error, map(), String.t()) ::
          {String.t() | nil, String.t()}
  def outcome_summary(:approved, %{result: result}, title) do
    short = result_short(result)
    {short, "[System: user approved '#{title}'. Result: #{short}]"}
  end

  def outcome_summary(:declined, %{reason: reason}, title) do
    txt =
      if reason && reason != "",
        do: "[System: user declined '#{title}'. Reason: #{reason}]",
        else: "[System: user declined '#{title}'.]"

    {reason, txt}
  end

  def outcome_summary(:error, %{reason: reason}, title) do
    # This text becomes history the model reads on the next turn — sanitize
    # BEFORE flattening, since a flattened string is past the sanitizer's
    # reach. A binary reason is a crafted, client-safe diagnosis as-is.
    short =
      case reason do
        r when is_binary(r) -> String.slice(r, 0, 200)
        r -> Sanctum.Sanitizer.sanitize(r) |> inspect() |> String.slice(0, 200)
      end

    {short, "[System: action '#{title}' failed: #{short}]"}
  end

  defp result_short(result) when is_map(result) do
    result
    |> Map.take([:status, "status", :id, "id", :name, "name"])
    |> case do
      empty when map_size(empty) == 0 -> "ok"
      m -> inspect(m) |> String.slice(0, 120)
    end
  end

  defp result_short(other), do: other |> inspect() |> String.slice(0, 120)

  # ---------------------------------------------------------------------------
  # Tool activity
  # ---------------------------------------------------------------------------

  @doc """
  Mark the most recent running tool-activity entry for `tool` as done,
  attaching `preview`; appends a done entry if none was running.
  """
  @spec mark_tool_done([map()], String.t(), String.t() | nil) :: [map()]
  def mark_tool_done(activity, tool, preview) do
    target =
      activity
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {entry, _i} -> entry.tool == tool and entry.status == :running end)

    case target do
      {_entry, i} -> List.update_at(activity, i, &%{&1 | status: :done, preview: preview})
      nil -> activity ++ [%{tool: tool, status: :done, preview: preview}]
    end
  end
end
