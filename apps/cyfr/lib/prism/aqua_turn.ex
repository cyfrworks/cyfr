# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaTurn do
  @moduledoc """
  One AQUA turn, as data: the orchestrator lookup, the formula input a
  message becomes, the execution that runs it, and what its output turns
  into afterwards. `Prism.ConversationRunner` owns the process; this
  module owns the shapes, so the runner stays a small state machine and the
  turn can be exercised without one.
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

  @doc "The athanor's orchestrators — `[%{\"name\", \"title\"}]`, manifest order."
  @spec orchestrators(Context.t()) :: [map()]
  def orchestrators(%Context{} = ctx) do
    case call_aqua(ctx, %{"action" => "list", "type" => "orchestrator"}) do
      {:ok, result} ->
        (result["guides"] || [])
        |> Enum.map(fn g -> %{"name" => g["name"], "title" => g["title"] || g["name"]} end)
        |> Enum.reject(fn g -> is_nil(g["name"]) end)

      _ ->
        []
    end
  end

  @doc "One orchestrator's run-time detail, or `nil`."
  @spec orchestrator(Context.t(), String.t() | nil) :: orchestrator() | nil
  def orchestrator(_ctx, nil), do: nil

  def orchestrator(%Context{} = ctx, name) when is_binary(name) do
    case call_aqua(ctx, %{"action" => "get", "name" => name}) do
      {:ok, %{"type" => "orchestrator"} = detail} ->
        %{
          "name" => name,
          "title" => detail["title"] || name,
          "catalyst_ref" => detail["catalyst_ref"],
          "model" => detail["model"],
          "tool_policy" => detail["tool_policy"] || %{}
        }

      _ ->
        nil
    end
  end

  @doc """
  An explicit `@name` in the message names the orchestrator for this turn.
  Returns `{message_without_mention, name | nil}`.
  """
  @spec parse_mention(String.t(), [map()]) :: {String.t(), String.t() | nil}
  def parse_mention(message, orchestrators) do
    if not String.contains?(message, "@") or orchestrators == [] do
      {message, nil}
    else
      names = Enum.map(orchestrators, & &1["name"])
      sorted = Enum.sort_by(names, &(-String.length(&1)))

      Enum.find_value(sorted, {message, nil}, fn name ->
        re = Regex.compile!("(?<![\\w@])@#{Regex.escape(name)}(?![\\w-])", "i")

        if Regex.match?(re, message) do
          cleaned = Regex.replace(re, message, "") |> String.trim()
          {if(cleaned == "", do: message, else: cleaned), name}
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
  `:model` (an override for the orchestrator's model), `:group` (`true` in
  a group athanor — the system prompt then explains that people are
  speaking, each line of the task prefixed with the speaker's name).

  Returns `%{input: map, tool_policy: map}` — the policy is what the turn's
  intents are later checked against.
  """
  @spec build_input(Context.t(), orchestrator(), String.t(), keyword()) ::
          %{input: map(), tool_policy: map()}
  def build_input(%Context{} = ctx, %{"name" => name} = orchestrator, message, opts \\ []) do
    tool_policy = orchestrator["tool_policy"] || %{}

    # The aqua-actions text-intent protocol is appended only at the
    # orchestrator call-site. Sub-agents are scoped task-runners — they
    # never emit UI intents.
    system_prompt =
      Prism.AgentConfig.build_system_prompt(ctx, name) <>
        Prism.AquaActions.system_prelude(tool_policy) <>
        group_prelude(Keyword.get(opts, :group, false))

    resolved_catalyst =
      case Prism.AgentConfig.resolve_catalyst(ctx, orchestrator["catalyst_ref"]) do
        {:ok, ref} -> ref
        _ -> orchestrator["catalyst_ref"]
      end

    sub_agents =
      Prism.AgentConfig.sub_agent_definitions(ctx, name, resolved_catalyst, orchestrator["model"])

    input =
      %{
        "task" => message,
        "system" => system_prompt,
        "sub_agents" => sub_agents,
        "catalyst_ref" => resolved_catalyst,
        "model" => Keyword.get(opts, :model) || orchestrator["model"]
      }
      |> Prism.AgentConfig.put_formula_tool_surface(tool_policy)
      |> put_attachments(Keyword.get(opts, :attachments, []))
      |> put_messages(Keyword.get(opts, :history, []))

    %{input: input, tool_policy: tool_policy}
  end

  # A group's agent hears several people; the runner writes each line of the
  # task as `Name: text`, and the prompt says so, so the model attributes
  # rather than assumes one speaker.
  @group_prelude "\n\nThis is a group conversation with several people. Each line of the " <>
                   "task is prefixed with the name of the person who said it, as `Name: text`. " <>
                   "Address people by name when it helps; you are the group's assistant, not " <>
                   "any one person's."

  defp group_prelude(true), do: @group_prelude
  defp group_prelude(_), do: ""

  defp put_attachments(input, []), do: input
  defp put_attachments(input, attachments), do: Map.put(input, "attachments", attachments)

  defp put_messages(input, []), do: input

  defp put_messages(input, history) when is_list(history) do
    # Strip aqua-actions blocks from assistant turns before handing the
    # history back: the model must not meet its own literal block again and
    # copy it instead of treating it as already executed.
    cleaned = Enum.map(history, &strip_actions_in_message/1)
    Map.put(input, "messages", Prism.ConversationCompactor.compact(cleaned))
  end

  defp put_messages(input, _), do: input

  defp strip_actions_in_message(%{"role" => "assistant", "content" => content} = msg)
       when is_binary(content) do
    %{msg | "content" => Prism.AquaActions.strip_blocks(content)}
  end

  defp strip_actions_in_message(%{"role" => "assistant", "content" => parts} = msg)
       when is_list(parts) do
    %{msg | "content" => Enum.map(parts, &strip_actions_in_part/1)}
  end

  defp strip_actions_in_message(msg), do: msg

  defp strip_actions_in_part(%{"type" => "text", "text" => text} = part) when is_binary(text) do
    %{part | "text" => Prism.AquaActions.strip_blocks(text)}
  end

  defp strip_actions_in_part(part), do: part

  @doc "How a person is named in a group turn: display name, else email, else id."
  @spec display_name(String.t() | nil) :: String.t()
  def display_name(nil), do: "someone"

  def display_name(user_id) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{display_name: name}} when is_binary(name) and name != "" -> name
      {:ok, %{email: email}} when is_binary(email) and email != "" -> email
      _ -> user_id
    end
  end

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  @doc """
  Start the AQUA formula as a root execution under `ctx` (the person whose
  message this is — their consented authority, their attribution). Returns
  the execution id; the caller subscribes to its events.
  """
  @spec start(Context.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def start(%Context{} = ctx, input) when is_map(input) do
    result =
      Emissary.MCP.ToolRegistry.call_external("execution", ctx, %{
        "action" => "run_stream",
        "reference" => @agent_ref,
        "input" => input
      })

    case result do
      {:ok, %{execution_id: eid}} -> {:ok, eid}
      {:ok, %{"execution_id" => eid}} -> {:ok, eid}
      {:ok, other} -> {:error, {:no_execution_id, other}}
      {:error, reason} -> {:error, reason}
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
  @spec cancel(Context.t(), String.t()) :: :ok | {:error, term()}
  def cancel(%Context{} = ctx, execution_id), do: Cyfr.Execution.cancel(ctx, execution_id)

  @doc "Cancel a running turn because a consent delta applies to future roots."
  @spec cancel_for_restart(Context.t(), String.t(), map()) :: :ok | {:error, term()}
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
  `Prism.AquaActions.parse/2`), the client intents (navigate/copy…), and
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
      Prism.AquaActions.parse(String.trim(raw), tool_policy)

    Enum.each(drops, fn drop ->
      Logger.warning("[Prism.AquaTurn] dropped aqua-actions intent: #{inspect(drop)}")
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
  # — those are the security-relevant ones. Routine drops (malformed JSON, a
  # path outside the allowlist) stay in the log.
  defp tripwires(drops) do
    drops
    |> Enum.filter(fn
      %{raw: %{"kind" => "ui.request_approval"}, reason: reason} when is_binary(reason) ->
        reason =~ "allowlist"

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
  """
  @spec run_approved(map(), Context.t()) :: {:ok, term()} | {:error, term()}
  def run_approved(%{tool: "execution", action: action, args: args}, %Context{} = ctx)
      when action in ["run", "run_stream"] do
    launch_args =
      (args || %{})
      |> Map.put("action", action)
      |> Map.drop(["parent_execution_id", "root_execution_id"])

    Emissary.MCP.ToolRegistry.call_external("execution", ctx, launch_args)
  end

  def run_approved(%{tool: tool, action: action, args: args}, %Context{} = ctx)
      when is_binary(tool) and is_binary(action) do
    case Cyfr.Execution.authority_for(ctx, nil, @agent_ref) do
      {:ok, authority} ->
        Emissary.MCP.ToolRegistry.call_in_chain(
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
    short = inspect(reason) |> String.slice(0, 200)
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

  # ---------------------------------------------------------------------------
  # aqua tool
  # ---------------------------------------------------------------------------

  # Every aqua-tool call goes through here so guide maps arrive with ONE key
  # spelling: in-process results are atom-keyed, wire round-trips
  # string-keyed.
  @doc false
  def call_aqua(%Context{} = ctx, args) do
    case Emissary.MCP.ToolRegistry.call_external("aqua", ctx, args) do
      {:ok, result} -> {:ok, Prism.AgentConfig.stringify_deep(result)}
      other -> other
    end
  end
end
