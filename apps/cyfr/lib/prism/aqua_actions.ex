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

  - `parse/1` — extract validated intents from a complete assistant message.
    Returns `%{stripped, intents, drops}`. Each intent is collapsed to its
    on-the-wire shape (navigate-class → `%{kind: "navigate", to: path}`).
  - `strip_blocks/1` — render-time strip that handles partial / mid-stream
    blocks. Used in `message_bubble/1` so raw JSON never flashes to the user.
  - `system_prelude/0` — stable text appended to the orchestrator's system
    prompt teaching the protocol. Module attribute → compiled once → keeps
    the Anthropic prompt cache prefix warm across turns.

  ## Allowlist

  `ui.navigate` paths are validated against a hardcoded list (mirrors the
  routes in `apps/cyfr/lib/prism_web/router.ex`). Configurable via
  `Application.get_env(:cyfr, :aqua_actions_allowed_paths, ...)`.

  Resource-focus actions (`ui.execution.focus`, `ui.component.focus`, etc.)
  compute their target paths internally and don't need to be in the allowlist.
  """

  require Logger

  # Closed fenced block — strict opener `\`\`\`aqua-actions ` with optional
  # trailing whitespace and required newline. Lazy match on body.
  @block_re ~r/```aqua-actions[ \t]*\r?\n(.*?)```/s

  # Render-time strip — matches closed blocks OR open-but-unclosed tails at
  # end-of-string. Used during streaming so partial JSON never flashes.
  @render_strip_re ~r/```aqua-actions[ \t]*\r?\n.*?(```|\z)/s

  @default_allowed_routes ~w(
    /
    /activity /activities /enforcements /executions /schedules
    /components /builds /registry /tinctures
    /secrets /api-keys /webhooks /mcp-servers /settings
    /reports /legal
  )

  @allowed_overlay_states ~w(half full)
  @allowed_risks ~w(low medium high)

  @id_re ~r/^[\w.\-]+$/

  @system_prelude """


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

  - `ui.navigate` `{"path": "/activity" | "/executions" | "/components" | …}`
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
  - `ui.request_approval` `{"title": "...", "summary": "...", "risk": "low"|"medium"|"high", "action_description": "..."}` — ask the user to confirm something YOU are about to do. The decision arrives as a new user turn (`[System: user approved ...]` or `[System: user declined ...]`); act accordingly. Use this before any action that publishes, deletes, sends externally, or costs money.
  """

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

  Returns:

      %{
        stripped: "<message minus all blocks, trimmed>",
        intents:  [%{kind: "navigate", to: "/path"}, ...],
        drops:    [%{raw: term, reason: String.t()}, ...]
      }

  Each intent in `intents` is in its on-the-wire shape (string-keyed `kind`,
  collapsed for the JS dispatcher — navigate/focus actions all become
  `%{kind: "navigate", to: path}`). Validation failures land in `drops`; the
  block is still stripped from `stripped`.
  """
  @spec parse(String.t()) :: %{stripped: String.t(), intents: [map()], drops: [map()]}
  def parse(content) when is_binary(content) do
    {intents, drops} = collect(content, [], [])
    stripped = @block_re |> Regex.replace(content, "") |> String.trim()

    %{stripped: stripped, intents: Enum.reverse(intents), drops: Enum.reverse(drops)}
  end

  def parse(_), do: %{stripped: "", intents: [], drops: []}

  defp collect(content, intents, drops) do
    case Regex.scan(@block_re, content, capture: :all_but_first) do
      [] ->
        {intents, drops}

      bodies ->
        Enum.reduce(bodies, {intents, drops}, fn [body], {is, ds} ->
          process_body(body, is, ds)
        end)
    end
  end

  defp process_body(body, intents, drops) do
    case Jason.decode(body) do
      {:ok, parsed} when is_list(parsed) ->
        Enum.reduce(parsed, {intents, drops}, fn entry, {is, ds} ->
          case validate(entry) do
            {:ok, intent} -> {[intent | is], ds}
            {:error, reason} -> {is, [%{raw: entry, reason: reason} | ds]}
          end
        end)

      {:ok, other} ->
        {intents, [%{raw: other, reason: "block body is not a JSON array"} | drops]}

      {:error, %Jason.DecodeError{} = err} ->
        {intents,
         [%{raw: body, reason: "JSON parse error: #{Exception.message(err)}"} | drops]}
    end
  end

  @doc """
  Validate a single intent map and return its on-the-wire form.

  Public for testability; not part of the streaming hot path.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate(raw) when is_map(raw) do
    case Map.get(raw, "kind") do
      kind when is_binary(kind) -> validate_kind(kind, raw)
      _ -> {:error, "missing or non-string 'kind'"}
    end
  end

  def validate(_), do: {:error, "entry is not an object"}

  defp validate_kind("ui.navigate", obj) do
    with {:ok, path} <- string_field(obj, "path"),
         :ok <- check_allowed_path(path) do
      {:ok, %{kind: "navigate", to: path}}
    end
  end

  defp validate_kind("ui.overlay.open", obj) do
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

  defp validate_kind("ui.overlay.close", _obj), do: {:ok, %{kind: "overlay_close"}}
  defp validate_kind("ui.overlay.focus_input", _obj), do: {:ok, %{kind: "overlay_focus_input"}}

  defp validate_kind("ui.copy_clipboard", obj) do
    case Map.get(obj, "text") do
      text when is_binary(text) -> {:ok, %{kind: "copy_clipboard", text: text}}
      _ -> {:error, "ui.copy_clipboard: requires string 'text'"}
    end
  end

  defp validate_kind("ui.activity.focus", obj),
    do: focus_intent(obj, "id", "req_", &"/activities?id=#{&1}")

  defp validate_kind("ui.execution.focus", obj),
    do: focus_intent(obj, "id", "exec_", &"/executions?id=#{&1}")

  defp validate_kind("ui.schedule.focus", obj),
    do: focus_intent(obj, "id", "sched_", &"/schedules?id=#{&1}")

  defp validate_kind("ui.component.focus", obj) do
    with {:ok, ref} <- string_field(obj, "ref"),
         :ok <- check_id_shape(ref, "ui.component.focus", "ref") do
      {:ok, %{kind: "navigate", to: "/components/#{ref}"}}
    end
  end

  defp validate_kind("ui.tincture.focus", obj) do
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

  defp validate_kind("ui.mcp_server.focus", obj) do
    with {:ok, name} <- string_field(obj, "name") do
      {:ok, %{kind: "navigate", to: "/mcp-servers?name=#{URI.encode_www_form(name)}"}}
    end
  end

  defp validate_kind("ui.request_approval", obj) do
    with {:ok, title} <- string_field(obj, "title"),
         {:ok, summary} <- string_field(obj, "summary"),
         {:ok, action_description} <- string_field(obj, "action_description"),
         {:ok, risk} <- risk_field(obj) do
      {:ok,
       %{
         kind: "request_approval",
         title: title,
         summary: summary,
         risk: risk,
         action_description: action_description
       }}
    end
  end

  defp validate_kind(kind, _obj), do: {:error, "unknown kind: #{inspect(kind)}"}

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
      v when is_binary(v) and v in @allowed_risks -> {:ok, v}
      other -> {:error, "ui.request_approval: risk must be low|medium|high, got #{inspect(other)}"}
    end
  end

  defp check_allowed_path(path) do
    routes = Application.get_env(:cyfr, :aqua_actions_allowed_paths, @default_allowed_routes)

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

  @doc "Stable system-prompt prelude teaching the agent the action protocol."
  @spec system_prelude() :: String.t()
  def system_prelude, do: @system_prelude
end
