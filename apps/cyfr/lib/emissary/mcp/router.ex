# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Router do
  @moduledoc """
  Routes MCP method calls to appropriate handlers.

  Handles:
  - Discovery (server/discover)
  - Tool methods (tools/list, tools/call)
  - Resource methods (resources/list, resources/templates/list, resources/read)
  - Subscriptions (subscriptions/listen, answered by the controller because its
    response is an open stream)

  ## Authorization Model

  The Router gates; handlers authorize. The Router answers only the coarse
  question — may an unauthenticated caller reach this tool action at all? — via
  `@public_tool_actions`. Individual tool handlers then enforce fine-grained
  authorization (does this caller have permission to perform this specific
  action?) using `Context.require_permission/2` or `Context.authorize/2`.

  Authentication itself happens earlier, in `EmissaryWeb.Plugs.Authenticate`.

  ## Public Tool Actions

  `@public_tool_actions` defines tools/actions accessible without authentication.
  These are intentionally public because they serve discovery and onboarding:

  - `session` — all actions: session lifecycle (login, status) must work pre-auth
  - `aqua` — list/get only: read-only agent discovery and docs (create/update/delete require auth)
  - `component` search/inspect/categories/setup_plan/list — read-only component
    browsing to let unauthenticated clients discover available components
  - `system` status — health check endpoint

  ## Resource Methods

  `resources/list`, `resources/templates/list` are intentionally unauthenticated
  at the Router level. Resource metadata is non-sensitive; individual `resources/read`
  handlers enforce their own authorization (e.g. `Context.authorize(ctx, :read)`).

  ## Dispatch Flow

      Request → Router.dispatch/2 → Handler module → Response

  """

  alias Emissary.MCP.{Message, Protocol, ToolRegistry, ResourceRegistry, InputValidator}

  # Tools/actions accessible without authentication.
  # :all means every action on that tool is public.
  #
  # `registry.probe` and `registry.claim-personal` are bootstrap actions
  # called during the OAuth login flow — before the user has a cyfr session.
  # They authenticate via the IdP `access_token` carried in the arguments
  # (cyfr.run verifies it with GitHub/Google), not via a cyfr-side session.
  # `registry.get-namespace` is public read per the cyfr.run spec.
  @public_tool_actions %{
    "session" => :all,
    "aqua" => ~w(list get),
    "component" => ~w(search inspect categories setup_plan list),
    "registry" => ~w(probe claim_personal get_namespace),
    "system" => ~w(status)
  }

  # When auth is configured, the anonymous surface narrows — component browsing
  # requires a signed-in user. Registry bootstrap actions stay public: even
  # then, claim-personal is the first-login gate, and gating it behind auth
  # would create a deadlock.
  @public_tool_actions_with_auth %{
    "session" => :all,
    "aqua" => ~w(list get),
    "component" => ~w(categories setup_plan),
    "registry" => ~w(probe claim_personal get_namespace),
    "system" => ~w(status)
  }

  @server_capabilities %{
    # `listChanged: true` is a promise to actually push. It is true for tools
    # because the catalogue genuinely changes — registering, removing, enabling
    # or disabling an external MCP server changes which `server:tool` names
    # exist — and `subscriptions/listen` delivers that event. It stays false for
    # resources, whose list is a fixed set of providers with no change feed;
    # claiming otherwise would leave a client waiting for a notification that
    # cannot arrive, which reads as "nothing changed" rather than "nobody is
    # watching".
    "tools" => %{
      "listChanged" => true
    },
    "resources" => %{
      "listChanged" => false
    },
    # Optional protocol extensions this server speaks. Empty until one is
    # implemented — the field is declared so a client can read it uniformly
    # rather than distinguishing "no extensions" from "old server".
    "extensions" => %{}
  }

  # How long a client may treat a cacheable result as fresh, and who may hold it.
  #
  # The tool and resource catalogues change only when a component is registered
  # or removed, so a few minutes of staleness costs a client one out-of-date
  # listing and saves the server a poll per turn. They are `private` rather than
  # `public` because `ToolVisibility` filters the list by the caller's
  # permissions — two callers legitimately see different tools, so a shared
  # cache would serve one caller's view to another.
  @catalogue_ttl_ms :timer.minutes(5)
  @catalogue_scope "private"

  # Discovery carries no per-caller data: same versions, same capabilities, same
  # identity for everyone, so an intermediary may share it.
  @discover_ttl_ms :timer.hours(1)
  @discover_scope "public"

  # Resource contents are read under the caller's context and can differ per
  # caller. Never shared, and short — a resource is a live read, not a catalogue.
  @resource_ttl_ms :timer.seconds(30)
  @resource_scope "private"

  @doc """
  Dispatch an MCP message to the appropriate handler.

  For requests, returns `{:ok, result}` or `{:error, code, message}`.
  For notifications, returns `:ok`.
  """
  def dispatch(ctx, %Message{type: :request} = msg) do
    dispatch_method(ctx, msg.method, msg.params, msg.id)
  end

  def dispatch(ctx, %Message{type: :notification} = msg) do
    dispatch_notification(ctx, msg.method, msg.params)
  end

  def dispatch(_ctx, %Message{type: :response}) do
    # MCP spec: client responses (e.g., to server-initiated sampling) return 202
    :ok
  end

  def dispatch(_ctx, %Message{type: :error}) do
    # MCP spec: client error responses return 202
    :ok
  end

  # ============================================================================
  # Lifecycle Methods
  # ============================================================================

  # Version and capability discovery, without establishing anything. A client
  # may call it before any other request to pick a mutually supported revision,
  # or skip it and handle `UnsupportedProtocolVersion` on the request it wanted
  # to make anyway. It replaces `initialize`, whose only remaining job this is.
  defp dispatch_method(_ctx, "server/discover", _params, _id) do
    {:ok,
     cacheable(
       %{
         "supportedVersions" => Protocol.supported(),
         "capabilities" => @server_capabilities,
         "instructions" =>
           "CYFR runs sandboxed WebAssembly components under explicit, per-app consent. " <>
             "Call tools/list for the catalogue; `execution.run` executes a component, " <>
             "`component.search` and `component.inspect` describe what is installed."
       },
       @discover_ttl_ms,
       @discover_scope
     )}
  end

  # ============================================================================
  # Tool Methods
  # ============================================================================

  defp dispatch_method(ctx, "tools/list", params, _id) do
    ToolRegistry.list_tools()
    |> Emissary.MCP.ToolVisibility.filter_for_context(ctx)
    |> paginate("tools", params)
  end

  defp dispatch_method(ctx, "tools/call", params, _id) do
    name = params["name"]

    unless is_binary(name) do
      {:error, :invalid_params, "Missing required field: name"}
    else
      # Check tool existence first — unknown tools are protocol errors per spec
      case ToolRegistry.get_tool(name) do
        {:error, :not_found} ->
          {:error, :invalid_params, "Unknown tool: #{name}"}

        {:ok, tool_def} ->
          arguments = params["arguments"] || %{}

          case InputValidator.validate(
                 arguments,
                 tool_def["inputSchema"] || tool_def[:input_schema] || %{}
               ) do
            {:error, validation_msg} ->
              {:error, :invalid_params, validation_msg}

            :ok ->
              action = arguments["action"]

              if not ctx.authenticated and not public_tool_action?(name, action) do
                {:error, :auth_required, "Authentication required. Run 'cyfr login' to sign in."}
              else
                has_output_schema =
                  match?({:ok, %{"outputSchema" => _}}, ToolRegistry.get_tool(name))

                case ToolRegistry.call_external(name, ctx, arguments) do
                  {:ok, result} ->
                    text =
                      case Jason.encode(result) do
                        {:ok, encoded} ->
                          encoded

                        {:error, encode_error} ->
                          require Logger

                          Logger.error(
                            "[MCP.Router] Tool #{name} returned non-JSON-encodable result: #{inspect(encode_error)}"
                          )

                          ~s({"error":"Tool returned non-serializable result"})
                      end

                    call_result = %{
                      "content" => [%{"type" => "text", "text" => text}],
                      "isError" => false
                    }

                    # A tool that declares an outputSchema also answers in structuredContent,
                    # so a client gets the typed value without re-parsing the text block.
                    call_result =
                      if has_output_schema and is_map(result) do
                        Map.put(call_result, "structuredContent", result)
                      else
                        call_result
                      end

                    {:ok, call_result}

                  {:error, reason} ->
                    {:ok,
                     %{
                       "content" => [
                         %{
                           "type" => "text",
                           "text" => format_error_reason(reason)
                         }
                       ],
                       "isError" => true
                     }}
                end
              end
          end
      end
    end
  end

  # ============================================================================
  # Resource Methods
  # Intentionally unauthenticated at Router level — resource metadata is
  # non-sensitive. Individual read handlers enforce their own authorization.
  # ============================================================================

  defp dispatch_method(_ctx, "resources/list", params, _id) do
    resources = ResourceRegistry.list_resources()
    paginate(resources, "resources", params)
  end

  defp dispatch_method(_ctx, "resources/templates/list", params, _id) do
    templates = ResourceRegistry.list_resource_templates()
    paginate(templates, "resourceTemplates", params)
  end

  defp dispatch_method(ctx, "resources/read", params, _id) do
    uri = params["uri"]

    case ResourceRegistry.read(ctx, uri) do
      {:ok, content} ->
        mime_type = Map.get(content, :mimeType, "application/json")
        encoded = encode_content(content)

        # Per MCP spec: binary content uses "blob" field, text uses "text" field
        content_entry =
          if binary_mime?(mime_type) do
            %{"uri" => uri, "mimeType" => mime_type, "blob" => encoded}
          else
            %{"uri" => uri, "mimeType" => mime_type, "text" => encoded}
          end

        {:ok, cacheable(%{"contents" => [content_entry]}, @resource_ttl_ms, @resource_scope)}

      {:error, reason} ->
        {:error, :resource_not_found, "Failed to read resource: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Unknown Method
  # ============================================================================

  defp dispatch_method(_ctx, method, _params, _id) do
    {:error, :method_not_found, "Unknown method: #{method}"}
  end

  defp format_error_reason({:timeout, msg}) when is_binary(msg), do: msg
  defp format_error_reason({:crashed, msg}) when is_binary(msg), do: msg
  defp format_error_reason({:exit, msg}) when is_binary(msg), do: msg
  defp format_error_reason(reason) when is_binary(reason), do: reason
  defp format_error_reason(reason), do: inspect(reason)

  defp binary_mime?("application/octet-stream"), do: true
  defp binary_mime?("image/" <> _), do: true
  defp binary_mime?("audio/" <> _), do: true
  defp binary_mime?("video/" <> _), do: true
  defp binary_mime?("application/pdf"), do: true
  defp binary_mime?("application/zip"), do: true
  defp binary_mime?("application/gzip"), do: true
  defp binary_mime?("application/wasm"), do: true
  defp binary_mime?(_), do: false

  defp encode_content(%{content: content}) when is_binary(content), do: content

  defp encode_content(%{content: content}) do
    case Jason.encode(content) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(content)
    end
  end

  defp encode_content(content) when is_map(content) do
    case Jason.encode(content) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(content)
    end
  end

  # ============================================================================
  # Notifications
  # ============================================================================

  # There is deliberately no `notifications/cancelled` clause. This revision
  # confines that notification to stdio — "on Streamable HTTP, closing the SSE
  # response stream is itself the cancellation signal and no
  # `notifications/cancelled` message is expected" — and this server speaks
  # only Streamable HTTP. `EmissaryWeb.MCPController` cancels on stream close;
  # accepting the notification as well would be a second, unspecified way in.
  defp dispatch_notification(_ctx, method, _params) do
    require Logger
    Logger.warning("MCP: Unknown notification: #{method}")
    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Freshness hints. The specification requires both fields on every cacheable
  # result; `ttlMs` is how long a client may skip re-fetching, `cacheScope`
  # decides whether an intermediary may hold the answer for someone else.
  #
  # `cacheScope` is a disclosure decision, not a performance one: `public` means
  # "this answer is the same for every caller and may be served to any of them".
  # Getting it wrong hands one tenant's view to another, which is why nothing
  # filtered by caller permissions is ever marked public.
  defp cacheable(result, ttl_ms, scope) when is_map(result) do
    result
    |> Map.put("ttlMs", ttl_ms)
    |> Map.put("cacheScope", scope)
  end

  @default_page_size 50
  # Defense-in-depth ceiling on a client-supplied cursor offset. Not a real
  # overflow risk (Elixir ints are arbitrary-precision and a too-large offset
  # just yields an empty page), but it bounds any pathological value up front.
  @max_cursor_offset 1_000_000

  defp paginate(items, key, params) do
    cursor = is_map(params) && params["cursor"]
    offset = decode_cursor(cursor)

    page = Enum.slice(items, offset, @default_page_size)
    next_offset = offset + length(page)

    result = %{key => page}

    result =
      if next_offset < length(items) do
        Map.put(result, "nextCursor", encode_cursor(next_offset))
      else
        result
      end

    # Every page carries its own hints; the specification treats each page as an
    # independently cacheable response with its own freshness clock, and requires
    # one scope across all pages of a list.
    {:ok, cacheable(result, @catalogue_ttl_ms, @catalogue_scope)}
  end

  defp decode_cursor(nil), do: 0
  defp decode_cursor(false), do: 0

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, raw} ->
        case Integer.parse(raw) do
          {offset, ""} when offset >= 0 -> min(offset, @max_cursor_offset)
          _ -> 0
        end

      :error ->
        0
    end
  end

  defp encode_cursor(offset) do
    Base.url_encode64(Integer.to_string(offset), padding: false)
  end

  # `tools/list` took an extra `component_ref` parameter that returned the
  # in-chain view of the catalogue. It is gone: the specification defines
  # `cursor` as the only parameter, and nothing in this repository — no client,
  # no guide, no test — ever sent it. The view it produced is still reachable
  # where it is actually used, through the `tools` tool
  # (`Emissary.MCP.Tools.SystemProvider`), which is how a running component
  # discovers what it may call.

  defp public_tool_action?(name, action) do
    # With no auth configured the instance is public — anonymous browsing
    # (search/inspect/list) is allowed. Once auth is configured, the anonymous
    # surface narrows to registry bootstrap; browsing requires a signed-in user.
    actions_map =
      if Sanctum.auth_configured?(),
        do: @public_tool_actions_with_auth,
        else: @public_tool_actions

    case Map.get(actions_map, name) do
      :all -> true
      actions when is_list(actions) -> action in actions
      nil -> false
    end
  end
end
