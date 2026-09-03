# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Turn do
  @moduledoc """
  One AQUA turn, as data: the orchestrator lookup, the formula input a
  message becomes, the execution that runs it, and what its output turns
  into afterwards. `Aqua.ConversationRunner` owns the process; this
  module owns the shapes, so the runner stays a small state machine and the
  turn can be exercised without one.

  Two roads reach the engine, on purpose: STARTING work (`start/3`, an
  approved app launch) goes through the `execution` MCP tool so it passes
  the same registry gates and audit any external caller's start would;
  everything that manages an execution already started — pin, subscribe,
  cancel, events, status — goes through the `Cyfr.Execution` port directly,
  because those are the harness's own hands on its own turn, not a tool
  call anyone else could make.
  """

  require Logger

  alias Sanctum.Context

  @agent_ref "formula:local.aqua"

  @type orchestrator :: %{
          required(String.t()) => term()
        }

  @doc "The bundled AQUA formula every conversation turn runs."
  @spec agent_ref() :: String.t()
  def agent_ref, do: @agent_ref

  # ---------------------------------------------------------------------------
  # Orchestrators
  # ---------------------------------------------------------------------------

  @doc """
  The orchestrators this person can address here: **their own crew, and the
  estate's**.

  Agents belong to whoever owns the tree they live in. Yours travel with
  you — the same Tom, wherever you are working — while an estate may also
  keep agents of its own (the trip's assistant, the company's). Each entry
  carries `"owner"`, the athanor whose `aqua/` tree it came from, so a
  later resolve reads it from the right place and a rename cannot make the
  stored name point somewhere else — and `"estate?"`, whether that owner is
  the estate in focus.

  A name collision keeps BOTH entries. The roster is identity, not
  precedence: which one a bare `@aqua` means is `parse_mention/2`'s rule
  (the estate's wins; the personal one stays reachable as
  `@your-slug.aqua`). A roster that deduplicated here once made the
  qualified grammar unreachable in exactly the case it exists for.
  Estate entries sort first, so "the athanor's first orchestrator" and the
  picker's top row are the estate's.
  """
  @spec orchestrators(Context.t()) :: [map()]
  def orchestrators(%Context{} = ctx) do
    focus = ctx.athanor_id

    for owner <- roster_sources(ctx), entry <- orchestrators_of(ctx, owner) do
      Map.put(entry, "estate?", owner == focus)
    end
    |> Enum.sort_by(&{!&1["estate?"], &1["name"]})
  end

  # Whose trees to read, in precedence order: the person's own, then the
  # estate in focus. One athanor when they are the same — a person working
  # in their own estate reads one tree, as before.
  defp roster_sources(%Context{} = ctx) do
    [personal_athanor(ctx), ctx.athanor_id]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp personal_athanor(%Context{user_id: user_id}) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{personal_athanor_id: id}} -> id
      _ -> nil
    end
  end

  defp personal_athanor(_), do: nil

  defp orchestrators_of(ctx, owner) do
    case Context.refocus(ctx, owner) do
      {:ok, read_ctx} -> orchestrators_in(read_ctx, owner)
      # An unreachable tree contributes nothing — the same fail-open the
      # catalog read below chooses.
      {:error, _} -> []
    end
  end

  defp orchestrators_in(ctx, owner) do
    # Resolved once per roster build, not once per entry per message:
    # `parse_mention/2` is a pure function over the roster it is handed.
    slug = owner_slug(owner)

    case Aqua.AgentConfig.call_aqua(ctx, %{"action" => "list", "type" => "orchestrator"}) do
      {:ok, result} ->
        (result["guides"] || [])
        |> Enum.map(fn g ->
          %{
            "name" => g["name"],
            "title" => g["title"] || g["name"],
            "owner" => owner,
            "owner_slug" => slug
          }
        end)
        |> Enum.reject(fn g -> is_nil(g["name"]) end)

      # Fail-open BY CHOICE: a broken aqua tool reads as "no orchestrators"
      # — the chat still renders, which beats refusing the whole
      # conversation for a catalog read. (A SEND with an empty roster and
      # no prior orchestrator is still refused `:no_orchestrator` by the
      # runner; the generic fallback prompt covers only a name that
      # resolves but whose content read fails.)
      _ ->
        []
    end
  end

  @doc """
  One orchestrator's run-time detail, or `nil`.

  `owner` is the athanor whose tree holds it — from the roster entry, never
  guessed. Reading an agent from the estate in focus when it belongs to the
  person would find a different agent of the same name, or none.
  """
  @spec orchestrator(Context.t(), String.t() | nil, String.t() | nil) :: orchestrator() | nil
  def orchestrator(ctx, name, owner \\ nil)

  def orchestrator(_ctx, nil, _owner), do: nil

  def orchestrator(%Context{} = ctx, name, owner) when is_binary(name) do
    owner_id = owner || ctx.athanor_id

    with {:ok, read_ctx} <- reach(ctx, owner),
         {:ok, %{"type" => "orchestrator"} = detail} <-
           Aqua.AgentConfig.call_aqua(read_ctx, %{"action" => "get", "name" => name}) do
      %{
        "name" => name,
        "owner" => owner_id,
        # For the composer's qualified handle when the owner is not the
        # estate in focus — the ID stays the identity, the slug is what a
        # person can type.
        "owner_slug" => owner_slug(owner_id),
        "title" => detail["title"] || name,
        "catalyst_ref" => detail["catalyst_ref"],
        "model" => detail["model"],
        "tool_policy" => detail["tool_policy"] || %{}
      }
    else
      # Same deliberate fail-open as orchestrators/1: nil means "run on
      # the fallback prompt", never "refuse the turn" — and an owner tree
      # the caller cannot reach reads as no agent at all.
      _ -> nil
    end
  end

  # The owner's tree through the refocus chokepoint: a member's context
  # takes the member branch; recovery's system context crosses by design
  # and still refuses an archived estate.
  defp reach(ctx, nil), do: {:ok, ctx}
  defp reach(ctx, owner), do: Context.refocus(ctx, owner)

  @doc """
  An explicit `@name` in the message names the orchestrator for this turn.

  Two spellings, because a person's crew and an estate's may share a name:

    * `@tom` — the roster entry called `tom`, with the estate's winning a
      collision (it is the one a bare mention means where you are).
    * `@alice.tom` — qualified by the owning estate's slug, which is how a
      personal agent shadowed by an estate's is still reachable.

  The collision rule lives HERE, and only here: the roster hands over both
  same-named entries, and the sort below puts the estate's bare handle
  ahead of the personal one — deterministically, not by roster order, which
  lists the personal tree first. Returns
  `{message_without_mention, entry | nil}` — the whole roster entry, not
  just the name, because the caller needs to know WHOSE tree to read it
  from. Matching longest-first so `@aqua_planner` is not read as `@aqua`
  with a suffix.
  """
  @spec parse_mention(String.t(), [map()]) :: {String.t(), map() | nil}
  def parse_mention(message, orchestrators) do
    if not String.contains?(message, "@") or orchestrators == [] do
      {message, nil}
    else
      orchestrators
      |> Enum.flat_map(&handles/1)
      |> Enum.sort_by(fn {handle, entry} ->
        {-String.length(handle), if(entry["estate?"], do: 0, else: 1)}
      end)
      |> Enum.find_value({message, nil}, fn {handle, entry} ->
        re = Regex.compile!("(?<![\\w@])@#{Regex.escape(handle)}(?![\\w.-])", "i")

        if Regex.match?(re, message) do
          cleaned = Regex.replace(re, message, "") |> String.trim()
          {if(cleaned == "", do: message, else: cleaned), entry}
        end
      end)
    end
  end

  # Every way one entry may be addressed. The qualifier is the owning
  # estate's SLUG rather than its id: a slug is what a person can type, and
  # binding the entry to the owner's id (not the qualifier) means renaming
  # the estate cannot make a stored mention point elsewhere.
  defp handles(%{"name" => name, "owner_slug" => slug} = entry) when is_binary(slug),
    do: [{"#{slug}.#{name}", entry}, {name, entry}]

  defp handles(%{"name" => name} = entry), do: [{name, entry}]

  defp owner_slug(owner) when is_binary(owner) do
    case Sanctum.Tenancy.Athanors.get(owner) do
      {:ok, athanor} -> athanor.slug
      _ -> nil
    end
  end

  defp owner_slug(_), do: nil

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
  this grants), `:owner` / `:focus` (whose agent, whose estate).

  Returns `{:ok, %{input: map, tool_policy: map}}` — the policy is what the
  turn's intents are later checked against — or
  `{:error, {:catalyst_not_in_estate, ref}}` when the agent's model does
  not resolve in the estate the turn runs in. That refusal is deliberate
  and crisp: a catalyst is a component, components belong to the working
  estate, and handing the formula an unresolved ref surfaced as a
  confusing runtime error instead of "this estate has no such model".
  """
  @spec build_input(Context.t(), orchestrator(), String.t(), keyword()) ::
          {:ok, %{input: map(), tool_policy: map()}}
          | {:error, {:catalyst_not_in_estate, String.t() | nil}}
  def build_input(%Context{} = ctx, %{"name" => _name} = orchestrator, message, opts \\ []) do
    tool_policy = orchestrator["tool_policy"] || %{}

    # One composer owns the whole prompt — including the aqua-actions
    # protocol, which is an orchestrator's alone (sub-agents are scoped
    # task-runners and never emit UI intents).
    system_prompt =
      Aqua.Prompt.compose(ctx,
        agent: orchestrator,
        authority: Keyword.get(opts, :authority),
        owner: Keyword.get(opts, :owner),
        focus: Keyword.get(opts, :focus),
        several_people?: Keyword.get(opts, :group, false)
      )

    # Resolved against the estate the turn RUNS in — see the doc. Fails
    # CLOSED for a NAMED ref this estate does not hold; the empty roster
    # and a missing prompt stay fail-open (documented on their own sites),
    # but a model that is not here is not a degraded turn, it is no turn.
    # An agent that pins no catalyst at all is a different, pre-existing
    # path — nil rides through to the engine's default, exactly as before.
    case resolve_or_pass(ctx, orchestrator["catalyst_ref"]) do
      {:ok, resolved_catalyst} ->
        sub_agents =
          Aqua.AgentConfig.sub_agent_definitions(
            ctx,
            orchestrator,
            resolved_catalyst,
            orchestrator["model"]
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
          |> put_messages(Keyword.get(opts, :history, []))

        {:ok, %{input: input, tool_policy: tool_policy}}

      _ ->
        {:error, {:catalyst_not_in_estate, orchestrator["catalyst_ref"]}}
    end
  end

  defp resolve_or_pass(_ctx, ref) when ref in [nil, ""], do: {:ok, nil}
  defp resolve_or_pass(ctx, ref), do: Aqua.AgentConfig.resolve_catalyst(ctx, ref)

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
    %{msg | "content" => Aqua.Actions.strip_blocks(content)}
  end

  defp strip_actions_in_message(%{"role" => "assistant", "content" => parts} = msg)
       when is_list(parts) do
    %{msg | "content" => Enum.map(parts, &strip_actions_in_part/1)}
  end

  defp strip_actions_in_message(msg), do: msg

  defp strip_actions_in_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => Aqua.Actions.strip_blocks(text)}
  end

  defp strip_actions_in_part(part), do: part

  @doc "How a person is named in a group turn: display name, else email, else id."
  @spec display_name(String.t() | nil) :: String.t()
  defdelegate display_name(user_id), to: Sanctum.Tenancy.Users

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  @doc """
  Resolve — and pin — the profile this turn will run as.

  The first of a turn's three steps: **pin, compose, run**. It exists as a
  step of its own because both of the others need its answer. `run/3` must
  name the profile rather than re-select one, and the prompt composer must
  know what the authority actually grants before it can describe the
  agent's tools honestly.

  `:default` selects the single active owner profile of the agent formula.
  Two active owner labels answer `{:ambiguous, ids}`, and a turn **refuses**
  rather than picking: which authority a person's agent runs under is not
  something to guess at, and the guess used to be invisible.

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
      Aqua.MCPHelpers.call_tool("execution", ctx, %{
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

  # The port answers `{:ok, map()}`, not `:ok` — the spec said the opposite
  # in both directions, so a caller matching on it was matching on fiction.
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
  `Aqua.Actions.parse/2`), the client intents (navigate/copy…), and
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
      Aqua.Actions.parse(String.trim(raw), tool_policy)

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

  # Only request_approval drops whose proposal violated policy are surfaced
  # — those are the security-relevant ones, told by the drop's typed tag,
  # never by matching the reason's wording (a rewording in AquaActions once
  # silently disabled this). Routine drops (malformed JSON, an action the
  # chat plane refuses) stay in the log.
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

  @doc "True when the intent's `{tool, action}` is in the conversation's grant set."
  @spec granted?(map(), MapSet.t()) :: boolean()
  def granted?(%{proposal: %{tool: t, action: a}}, grants) when is_binary(t) and is_binary(a),
    do: MapSet.member?(grants, {t, a})

  def granted?(_, _), do: false

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

  `profile_id` is the profile the *turn* pinned, and passing it is what
  makes "the same consented authority" true. This used to re-derive the
  authority with no selector, which resolves to the single active owner
  profile — correct only while there is exactly one. With a second profile
  on the agent formula, an approval would silently root a graph the turn
  never ran under, and "fails closed" would not have caught it: the
  re-derivation succeeds, at the wrong profile.
  """
  @spec run_approved(map(), Context.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def run_approved(proposal, ctx, profile_id)

  def run_approved(
        %{tool: "execution", action: action, args: args},
        %Context{} = ctx,
        _profile_id
      )
      when action in ["run", "run_stream"] do
    launch_args =
      (args || %{})
      |> Map.put("action", action)
      |> Map.drop(["parent_execution_id", "root_execution_id"])

    Aqua.MCPHelpers.call_tool("execution", ctx, launch_args)
  end

  def run_approved(%{tool: tool, action: action, args: args}, %Context{} = ctx, profile_id)
      when is_binary(tool) and is_binary(action) and is_binary(profile_id) do
    case Cyfr.Execution.authority_for(ctx, {:id, profile_id}, @agent_ref) do
      {:ok, authority} ->
        Aqua.MCPHelpers.call_in_chain(
          tool,
          Context.enter_guest(ctx),
          Map.put(args || %{}, "action", action),
          authority
        )

      {:error, reason} ->
        {:error, reason}
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
