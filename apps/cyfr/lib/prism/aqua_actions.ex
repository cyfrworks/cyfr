# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaActions do
  @moduledoc """
  Server-side parser/dispatcher for the `aqua-actions` text-intent protocol.

  Elixir port of `apps/porta/src-ui/src/harness/porta-actions-parser.ts`. The
  AQUA agent emits a fenced block at the end of its reply containing a JSON
  array of typed UI intents:

      ```aqua-actions
      [{"kind": "ui.execution.focus", "id": "exec_abc"}]
      ```

  Cyfr's host (`PrismWeb.AquaLive`) parses + strips the block on stream
  complete, then `push_event/3`s the validated intents to the `Aqua` JS hook
  for client-side dispatch.

  ## Public API

  - `parse/2` — extract validated intents from a complete assistant message
    against the calling agent's `tool_policy`. Returns
    `%{stripped, intents, drops}`. Each intent is collapsed to its on-the-wire
    shape (navigate-class → `%{kind: "navigate", to: path}`).
  - `strip_blocks/1` — render-time strip that handles partial / mid-stream
    blocks. Used in `message_bubble/1` so raw JSON never flashes to the user.
  - `system_prelude/1` — text appended to the orchestrator's system prompt
    teaching the protocol; lists the actions the agent must request approval
    for — the `"ask"` entries in its `tool_policy` allowlist.

  ## Allowlist

  `ui.navigate` paths are validated against a hardcoded list (mirrors the
  routes in `apps/cyfr/lib/prism_web/router.ex`). Configurable via
  `Application.get_env(:cyfr, :aqua_actions_allowed_paths, ...)`.

  Resource-focus actions (`ui.execution.focus`, `ui.component.focus`, etc.)
  compute their target paths internally and don't need to be in the allowlist.

  ## Approval proposals

  `ui.request_approval` may carry a `proposal: {tool, action, args}` payload
  describing a concrete tool call. The validator looks the pair up in the
  agent's `tool_policy` allowlist (`{"tool.action" | "tool.*" => "ask" | "auto"}`):
  only `"ask"` is accepted — `"auto"` means the agent should call it directly,
  and an absent key means it isn't permitted. Risk visualization is derived
  from the action's `kind` (read/write/execute/destructive/external), which
  lives in the tool definition's annotations or the AQUA virtual-tool catalog.
  External upstream MCP tools are namespaced `server:tool` and classified
  as `:external` directly without consulting annotations.
  """

  @block_re ~r/```aqua-actions[ \t]*\r?\n(.*?)```/s
  @render_strip_re ~r/```aqua-actions[ \t]*\r?\n.*?(```|\z)/s

  # Live navigation targets, derived from the router at first use (see
  # `allowed_routes/0`) so the allowlist cannot drift from what actually
  # mounts. Redirect stubs and parameterized detail routes are excluded —
  # an agent navigates to pages, not to individual records.
  @excluded_routes ~w(/logs /logs/:id /components/:ref)

  @allowed_overlay_states ~w(half full)
  # Risk values for `ui.request_approval`. Prism derives its own risk from
  # the action's `kind`; Porta displays this field on the approval card, so
  # the vocabulary is shared intent shape, not advisory decoration.
  @allowed_risks ~w(low medium high)

  @id_re ~r/^[\w.\-]+$/

  @doc """
  Strip every `aqua-actions` block (closed or mid-stream) from a text chunk
  for display. Safe-for-rendering — does not parse or validate.
  """
  @spec strip_blocks(String.t()) :: String.t()
  def strip_blocks(content) when is_binary(content) do
    Regex.replace(@render_strip_re, content, "")
  end

  def strip_blocks(content), do: content

  @doc """
  Parse closed `aqua-actions` blocks out of a complete assistant message.

  `tool_policy` is the calling agent's allowlist (string keys `"tool.action"`
  or `"tool.*"` globs, values `"ask" | "auto"`). Used to validate
  `ui.request_approval` proposals — only `"ask"` actions may be requested.

  Returns:

      %{
        stripped: "<message minus all blocks, trimmed>",
        intents:  [%{kind: "navigate", to: "/path"}, ...],
        drops:    [%{raw: term, reason: String.t()}, ...]
      }
  """
  @spec parse(String.t(), map()) :: %{
          stripped: String.t(),
          intents: [map()],
          drops: [map()]
        }
  def parse(content, tool_policy \\ %{})

  def parse(content, tool_policy) when is_binary(content) and is_map(tool_policy) do
    {intents, drops} = collect(content, tool_policy, [], [])
    stripped = @block_re |> Regex.replace(content, "") |> String.trim()

    %{stripped: stripped, intents: Enum.reverse(intents), drops: Enum.reverse(drops)}
  end

  def parse(_, _), do: %{stripped: "", intents: [], drops: []}

  defp collect(content, tool_policy, intents, drops) do
    case Regex.scan(@block_re, content, capture: :all_but_first) do
      [] ->
        {intents, drops}

      bodies ->
        Enum.reduce(bodies, {intents, drops}, fn [body], {is, ds} ->
          process_body(body, tool_policy, is, ds)
        end)
    end
  end

  defp process_body(body, tool_policy, intents, drops) do
    case Jason.decode(body) do
      {:ok, parsed} when is_list(parsed) ->
        Enum.reduce(parsed, {intents, drops}, fn entry, {is, ds} ->
          case validate(entry, tool_policy) do
            {:ok, intent} -> {[intent | is], ds}
            {:error, reason} -> {is, [%{raw: entry, reason: reason} | ds]}
          end
        end)

      {:ok, other} ->
        {intents, [%{raw: other, reason: "block body is not a JSON array"} | drops]}

      {:error, %Jason.DecodeError{} = err} ->
        {intents, [%{raw: body, reason: "JSON parse error: #{Exception.message(err)}"} | drops]}
    end
  end

  @doc """
  Validate a single intent map against an agent's `tool_policy`. Public for
  testability.
  """
  @spec validate(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def validate(raw, tool_policy \\ %{})

  def validate(raw, tool_policy) when is_map(raw) and is_map(tool_policy) do
    case Map.get(raw, "kind") do
      kind when is_binary(kind) -> validate_kind(kind, raw, tool_policy)
      _ -> {:error, "missing or non-string 'kind'"}
    end
  end

  def validate(_, _), do: {:error, "entry is not an object"}

  defp validate_kind("ui.navigate", obj, _policy) do
    with {:ok, path} <- string_field(obj, "path"),
         :ok <- check_allowed_path(path) do
      {:ok, %{kind: "navigate", to: path}}
    end
  end

  defp validate_kind("ui.overlay.open", obj, _policy) do
    case Map.get(obj, "state") do
      nil ->
        {:ok, %{kind: "overlay_open"}}

      state when is_binary(state) ->
        if state in @allowed_overlay_states do
          {:ok, %{kind: "overlay_open", state: state}}
        else
          {:error, "ui.overlay.open: state must be \"half\" or \"full\", got #{inspect(state)}"}
        end

      other ->
        {:error, "ui.overlay.open: state must be a string, got #{inspect(other)}"}
    end
  end

  defp validate_kind("ui.overlay.close", _obj, _policy), do: {:ok, %{kind: "overlay_close"}}

  defp validate_kind("ui.overlay.focus_input", _obj, _policy),
    do: {:ok, %{kind: "overlay_focus_input"}}

  defp validate_kind("ui.copy_clipboard", obj, _policy) do
    case Map.get(obj, "text") do
      text when is_binary(text) -> {:ok, %{kind: "copy_clipboard", text: text}}
      _ -> {:error, "ui.copy_clipboard: requires string 'text'"}
    end
  end

  defp validate_kind("ui.activity.focus", obj, _policy),
    do: focus_intent(obj, "id", "req_", &"/activities?id=#{&1}")

  defp validate_kind("ui.execution.focus", obj, _policy),
    do: focus_intent(obj, "id", "exec_", &"/executions?id=#{&1}")

  defp validate_kind("ui.schedule.focus", obj, _policy),
    do: focus_intent(obj, "id", "sched_", &"/schedules?id=#{&1}")

  defp validate_kind("ui.component.focus", obj, _policy) do
    with {:ok, ref} <- string_field(obj, "ref"),
         :ok <- check_id_shape(ref, "ui.component.focus", "ref") do
      {:ok, %{kind: "navigate", to: "/components/#{ref}"}}
    end
  end

  defp validate_kind("ui.tincture.focus", obj, _policy) do
    with {:ok, publisher} <- string_field(obj, "publisher"),
         {:ok, name} <- string_field(obj, "name"),
         :ok <- check_id_shape(publisher, "ui.tincture.focus", "publisher"),
         :ok <- check_id_shape(name, "ui.tincture.focus", "name") do
      path =
        "/tinctures?publisher=#{URI.encode_www_form(publisher)}" <>
          "&tincture_name=#{URI.encode_www_form(name)}"

      {:ok, %{kind: "navigate", to: path}}
    end
  end

  defp validate_kind("ui.mcp_server.focus", obj, _policy) do
    with {:ok, name} <- string_field(obj, "name") do
      {:ok, %{kind: "navigate", to: "/mcp-servers?name=#{URI.encode_www_form(name)}"}}
    end
  end

  defp validate_kind("ui.request_approval", obj, tool_policy) do
    with {:ok, title} <- string_field(obj, "title"),
         {:ok, summary} <- string_field(obj, "summary"),
         {:ok, action_description} <- string_field(obj, "action_description"),
         {:ok, hinted_risk} <- risk_field(obj),
         {:ok, proposal, action_kind} <-
           validate_proposal(Map.get(obj, "proposal"), tool_policy) do
      {:ok,
       %{
         kind: "request_approval",
         id: Emissary.UUID7.generate_id("apr"),
         title: title,
         summary: summary,
         # Risk derived from the action's `kind`, not from the policy mode
         # or the agent's hinted risk. Kind comes from the tool definition's
         # annotations (or AquaVirtualTools for `files`/`storage`/`http`).
         # Approval cards color themselves from this kind.
         action_kind: action_kind,
         hinted_risk: hinted_risk,
         action_description: action_description,
         proposal: proposal
       }}
    end
  end

  defp validate_kind(kind, _obj, _policy), do: {:error, "unknown kind: #{inspect(kind)}"}

  # Pure-confirmation card with no executable proposal. Used when the agent
  # wants explicit user buy-in before continuing freeform reasoning. Kind is
  # `nil` because no specific action is bound.
  defp validate_proposal(nil, _policy), do: {:ok, nil, nil}

  defp validate_proposal(%{} = p, tool_policy) do
    with {:ok, tool} <- string_field(p, "tool"),
         :ok <- check_id_shape(tool, "ui.request_approval.proposal", "tool"),
         {:ok, action} <- string_field(p, "action"),
         :ok <- check_id_shape(action, "ui.request_approval.proposal", "action"),
         args <- Map.get(p, "args", %{}),
         :ok <- ensure_object(args, "ui.request_approval.proposal.args"),
         :ok <- lookup_proposal(tool_policy, tool, action) do
      kind = kind_for(tool, action)
      {:ok, %{tool: tool, action: action, args: args}, kind}
    end
  end

  defp validate_proposal(_, _),
    do: {:error, "ui.request_approval: proposal must be an object when present"}

  # Allowlist values: "ask" (request approval) | "auto" (call directly). An
  # absent key (and no matching `tool.*` glob) means the agent cannot perform
  # the action at all. Only "ask" should result in a proposal flowing to the
  # user; the others are validation errors at this stage.
  defp lookup_proposal(policy, tool, action) do
    key = "#{tool}.#{action}"

    case policy_value(policy, tool, action) do
      "ask" ->
        :ok

      "auto" ->
        {:error,
         "ui.request_approval: '#{key}' is allowlisted as 'auto' — call it directly, do not request approval"}

      nil ->
        {:error, "ui.request_approval: '#{key}' is not in your tool allowlist"}

      other ->
        {:error, "ui.request_approval: '#{key}' has unknown allowlist value #{inspect(other)}"}
    end
  end

  # Resolve the allowlist value for `tool.action`, falling back to a `tool.*`
  # glob over all of that tool's actions.
  defp policy_value(policy, tool, action) when is_map(policy) do
    Map.get(policy, "#{tool}.#{action}") || Map.get(policy, "#{tool}.*")
  end

  defp policy_value(_, _, _), do: nil

  # Resolve the kind of a tool.action.
  #
  # 1. AQUA virtual-tool catalog (`files`/`storage`/`http`/`request_setup`).
  # 2. External upstream MCP tools are namespaced `server:tool` and have no
  #    enumerable action verbs — short-circuit to `:external` regardless of
  #    the action arg.
  # 3. Internal cyfr tools must declare `kind` per action in
  #    `annotations.actions[verb].kind`. No `_default` fallback — a missing
  #    annotation returns `nil` so the gap is visible (and caught by the
  #    `audit_action_kinds/0` startup check).
  @spec kind_for(String.t(), String.t()) :: atom() | nil
  def kind_for(tool, action) when is_binary(tool) and is_binary(action) do
    cond do
      kind = Prism.AquaVirtualTools.kind_for(tool, action) ->
        kind

      String.contains?(tool, ":") ->
        :external

      true ->
        lookup_internal_kind(tool, action)
    end
  end

  def kind_for(_, _), do: nil

  defp lookup_internal_kind(tool, action) do
    with {:ok, tool_def} <- Emissary.MCP.ToolRegistry.get_tool(tool),
         actions_meta when is_map(actions_meta) <-
           get_in(tool_def, ["annotations", "actions"]) || %{},
         meta when is_map(meta) <- actions_meta[action] do
      case meta do
        %{kind: k} when is_atom(k) -> k
        %{"kind" => k} when is_binary(k) -> safe_to_atom(k)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp safe_to_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp ensure_object(value, _label) when is_map(value), do: :ok
  defp ensure_object(_, label), do: {:error, "#{label}: must be a JSON object"}

  defp focus_intent(obj, key, prefix, path_fn) do
    with {:ok, id} <- string_field(obj, key),
         :ok <- check_id_shape(id, "focus", key),
         :ok <- check_prefix(id, prefix, key) do
      {:ok, %{kind: "navigate", to: path_fn.(id)}}
    end
  end

  defp string_field(obj, key) do
    case Map.get(obj, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "requires non-empty string '#{key}'"}
    end
  end

  defp risk_field(obj) do
    case Map.get(obj, "risk") do
      v when is_binary(v) and v in @allowed_risks ->
        {:ok, v}

      other ->
        {:error, "ui.request_approval: risk must be low|medium|high, got #{inspect(other)}"}
    end
  end

  defp check_allowed_path(path) do
    routes = Application.get_env(:cyfr, :aqua_actions_allowed_paths, allowed_routes())

    cond do
      path in routes -> :ok
      matches_query_form?(path, routes) -> :ok
      true -> {:error, "ui.navigate: path #{inspect(path)} not in allowlist"}
    end
  end

  defp matches_query_form?(path, routes) do
    case String.split(path, "?", parts: 2) do
      [base, _query] -> base in routes
      _ -> false
    end
  end

  # GET-mounted router paths minus the exclusions — memoized, since the
  # router's route table is fixed for the VM lifetime.
  defp allowed_routes do
    case :persistent_term.get({__MODULE__, :allowed_routes}, :miss) do
      :miss ->
        routes =
          PrismWeb.Router.__routes__()
          |> Enum.filter(&(&1.verb == :get and not String.contains?(&1.path, ":")))
          |> Enum.map(& &1.path)
          |> Enum.uniq()
          |> Kernel.--(@excluded_routes)

        :persistent_term.put({__MODULE__, :allowed_routes}, routes)
        routes

      routes ->
        routes
    end
  end

  defp check_id_shape(value, kind, key) do
    if Regex.match?(@id_re, value) do
      :ok
    else
      {:error, "#{kind}: #{key} #{inspect(value)} contains disallowed characters"}
    end
  end

  defp check_prefix(value, prefix, key) do
    if String.starts_with?(value, prefix) do
      :ok
    else
      {:error, "focus.#{key} #{inspect(value)} must start with #{prefix}"}
    end
  end

  @system_prelude_base """


  ---

  ## AQUA Shell Control

  When the user asks you to change the interface, or you want to bring
  something on screen, end your reply with a fenced block:

  ```aqua-actions
  [{"kind": "ui.execution.focus", "id": "exec_..."}]
  ```

  The block executes after your reply completes. Guidelines:

  - Only emit it when navigation/UI control actually helps. Most replies do
    not need a block.
  - One block per reply. Multiple actions may be listed in the same array;
    they execute in order.
  - Do not mention or describe the JSON in prose — the user will not see it.
  - Prefer focus actions over plain `ui.navigate` when targeting a specific
    resource.

  Available action kinds:

  - `ui.navigate` `{"path": "/activities" | "/executions" | "/components" | …}`
  - `ui.overlay.open` `{"state"?: "half" | "full"}`
  - `ui.overlay.close`
  - `ui.overlay.focus_input`
  - `ui.copy_clipboard` `{"text": "..."}`
  - `ui.activity.focus` `{"id": "req_..."}`
  - `ui.execution.focus` `{"id": "exec_..."}`
  - `ui.schedule.focus` `{"id": "sched_..."}`
  - `ui.component.focus` `{"ref": "publisher.name@version"}`
  - `ui.tincture.focus` `{"publisher": "...", "name": "..."}`
  - `ui.mcp_server.focus` `{"name": "..."}`
  - `ui.request_approval` `{"title": "...", "summary": "...", "risk": "low"|"medium"|"high", "action_description": "...", "proposal"?: {"tool": "...", "action": "...", "args": {...}}}` — ask the user to confirm something. The decision arrives as a new user turn (`[System: user approved ...]` / `[System: user declined ...]`); act accordingly. With a `proposal` payload, the harness executes the tool call on your behalf when the user clicks Approve. Use this for any action that publishes, deletes, sends externally, or costs money — and for every action listed under "Actions that need approval" below.
  """

  @doc """
  Build the system-prompt prelude for an agent, listing the approvable
  `(tool, action)` targets derived from its `tool_policy`. The text is
  appended after the orchestrator's base prompt.

  Stable for prompt-caching: the approvable list is sorted deterministically
  so the prefix only invalidates when the manifest changes.
  """
  @spec system_prelude(map()) :: String.t()
  def system_prelude(tool_policy \\ %{}) when is_map(tool_policy) do
    @system_prelude_base <> approval_section(tool_policy)
  end

  defp approval_section(tool_policy) when is_map(tool_policy) do
    approvals =
      tool_policy
      |> Enum.flat_map(fn
        {"native_search", _} -> []
        {key, "ask"} -> [key]
        _ -> []
      end)
      |> Enum.sort()

    case approvals do
      [] ->
        ""

      keys ->
        lines = Enum.map(keys, fn key -> "  - `#{key}`" end)

        "\n## Actions that need approval\n\n" <>
          "You cannot call these tool actions directly. To run any of them, end\n" <>
          "your reply with a `ui.request_approval` block carrying a `proposal`\n" <>
          "payload — the harness executes it on user approval and reports the\n" <>
          "result back as the next user turn (`[System: user approved … Result: …]` /\n" <>
          "`[System: user declined …]`).\n\n" <>
          Enum.join(lines, "\n") <> "\n"
    end
  end
end
