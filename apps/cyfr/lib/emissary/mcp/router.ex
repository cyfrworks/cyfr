# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Router do
  @moduledoc """
  Routes MCP method calls to appropriate handlers.

  Handles:
  - Lifecycle methods (initialize, notifications/initialized)
  - Tool methods (tools/list, tools/call)
  - Resource methods (resources/list, resources/read)
  - Prompt methods (prompts/list, prompts/get) [future]

  ## Authorization Model

  The Router authenticates; handlers authorize. The Router enforces session-level
  authentication (is the caller logged in?) via `@public_tool_actions`. Individual
  tool handlers then enforce fine-grained authorization (does this user have
  permission to perform this specific action?) using `Context.require_permission/2`
  or `Context.authorize/2`.

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

  alias Emissary.MCP.{Message, Session, ToolRegistry, ResourceRegistry, InputValidator}
  alias Sanctum.Context

  @protocol_version "2025-11-25"

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
    "registry" => ~w(probe claim-personal get-namespace),
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
    "registry" => ~w(probe claim-personal get-namespace),
    "system" => ~w(status)
  }

  @server_info %{
    "name" => "CYFR",
    "version" => "0.1.0"
  }

  @server_capabilities %{
    "tools" => %{
      "listChanged" => false
    },
    "resources" => %{
      "subscribe" => false,
      "listChanged" => false
    }
    # Future: prompts, logging, completions
  }

  @doc """
  Dispatch an MCP message to the appropriate handler.

  For requests, returns `{:ok, result}` or `{:error, code, message}`.
  For notifications, returns `:ok`.
  """
  def dispatch(session, %Message{type: :request} = msg) do
    dispatch_method(session, msg.method, msg.params, msg.id)
  end

  def dispatch(session, %Message{type: :notification} = msg) do
    dispatch_notification(session, msg.method, msg.params)
  end

  def dispatch(_session, %Message{type: :response}) do
    # MCP spec: client responses (e.g., to server-initiated sampling) return 202
    :ok
  end

  def dispatch(_session, %Message{type: :error}) do
    # MCP spec: client error responses return 202
    :ok
  end

  # ============================================================================
  # Lifecycle Methods
  # ============================================================================

  defp dispatch_method(_session, "initialize", _params, _id) do
    # Per MCP spec, initialize MUST be the first message in a session.
    # If we reach here, the session is already initialized (handled by MCPController).
    {:error, :invalid_request,
     "Session already initialized. Send a new initialize without a session ID to start a new session."}
  end

  defp dispatch_method(_session, "ping", _params, _id) do
    {:ok, %{}}
  end

  # ============================================================================
  # Tool Methods
  # ============================================================================

  defp dispatch_method(session, "tools/list", params, _id) do
    tools = ToolRegistry.list_tools()
    tools = Emissary.MCP.ToolVisibility.filter_for_context(tools, session.context)
    component_ref = is_map(params) && params["component_ref"]

    case component_ref do
      ref when is_binary(ref) ->
        filter_tools_for_component(tools, session.context, ref)

      _ ->
        paginate(tools, "tools", params)
    end
  end

  defp dispatch_method(session, "tools/call", params, id) do
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

              if not session.context.authenticated and not public_tool_action?(name, action) do
                {:error, :auth_required, "Authentication required. Run 'cyfr login' to sign in."}
              else
                has_output_schema =
                  match?({:ok, %{"outputSchema" => _}}, ToolRegistry.get_tool(name))

                case ToolRegistry.call(name, session.context, arguments, mcp_request_id: id) do
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

                    # MCP 2025-11-25: include structuredContent when tool defines outputSchema
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

  defp dispatch_method(_session, "resources/list", params, _id) do
    resources = ResourceRegistry.list_resources()
    paginate(resources, "resources", params)
  end

  defp dispatch_method(_session, "resources/templates/list", params, _id) do
    templates = ResourceRegistry.list_resource_templates()
    paginate(templates, "resourceTemplates", params)
  end

  defp dispatch_method(session, "resources/read", params, _id) do
    uri = params["uri"]

    case ResourceRegistry.read(session.context, uri) do
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

        {:ok, %{"contents" => [content_entry]}}

      {:error, reason} ->
        {:error, :resource_not_found, "Failed to read resource: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Unknown Method
  # ============================================================================

  defp dispatch_method(_session, method, _params, _id) do
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

  defp dispatch_notification(_session, "notifications/initialized", _params) do
    # Client has completed initialization
    :ok
  end

  defp dispatch_notification(session, "notifications/cancelled", params) do
    request_id = params["requestId"]
    reason = params["reason"]
    require Logger

    case Emissary.MCP.RunningTasks.cancel(request_id, session.context) do
      :ok ->
        Logger.info(
          "MCP: Cancelled running request #{inspect(request_id)}, reason: #{inspect(reason)}"
        )

      {:error, :not_found} ->
        Logger.debug(
          "MCP: Cancel requested for #{inspect(request_id)} (reason: #{inspect(reason)}) but no running task found"
        )

      {:error, :unauthorized} ->
        Logger.warning(
          "MCP: Unauthorized cancel attempt for #{inspect(request_id)} by user=#{session.context.user_id}"
        )
    end

    :ok
  end

  defp dispatch_notification(_session, method, _params) do
    require Logger
    Logger.warning("MCP: Unknown notification: #{method}")
    :ok
  end

  # ============================================================================
  # Helpers
  # ============================================================================

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

    {:ok, result}
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

  defp filter_tools_for_component(tools, ctx, component_ref) do
    case Sanctum.ComponentRef.parse(component_ref) do
      {:ok, %{type: "formula"}} ->
        policy =
          case Sanctum.Policy.get_effective(ctx, component_ref) do
            {:ok, policy, _meta} -> policy
            _ -> nil
          end

        filtered = Sanctum.Policy.RestrictedTools.filter_tool_list(:formula, tools, policy)

        {:ok,
         %{
           "tools" => filtered,
           "_meta" => %{"cyfr:component_ref" => component_ref, "cyfr:filtered" => true}
         }}

      {:ok, %{type: type}} ->
        {:ok,
         %{
           "tools" => tools,
           "_meta" => %{
             "cyfr:component_ref" => component_ref,
             "cyfr:component_type" => type,
             "cyfr:filtered" => false
           }
         }}

      {:error, reason} ->
        {:error, :invalid_params, "Invalid component_ref: #{reason}"}
    end
  end

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

  @doc """
  Get the protocol version this server supports.
  """
  def protocol_version, do: @protocol_version

  @doc """
  Handle initialization for a new session.

  Called when receiving an initialize request without an existing session.
  Creates a session and returns the result with session ID.
  """
  def handle_initialize(%Context{} = context, params) do
    client_version = params["protocolVersion"]

    if client_version != @protocol_version do
      require Logger

      Logger.warning(
        "[MCP] Client requested protocol version #{inspect(client_version)}, server supports #{@protocol_version}"
      )
    end

    {:ok, session} = Session.create(context, @server_capabilities)

    result = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => @server_capabilities,
      "serverInfo" => @server_info,
      "instructions" => "CYFR MCP server. Use tools/list to discover available tools."
    }

    {:ok, result, session}
  end
end
