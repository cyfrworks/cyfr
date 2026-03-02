defmodule Emissary.MCP.Router do
  @moduledoc """
  Routes MCP method calls to appropriate handlers.

  Handles:
  - Lifecycle methods (initialize, notifications/initialized)
  - Tool methods (tools/list, tools/call)
  - Resource methods (resources/list, resources/read) [future]
  - Prompt methods (prompts/list, prompts/get) [future]

  ## Dispatch Flow

      Request → Router.dispatch/2 → Handler module → Response

  """

  alias Emissary.MCP.{Message, Session, ToolRegistry, ResourceRegistry}
  alias Sanctum.Context

  @protocol_version "2025-11-25"

  # Tools/actions accessible without authentication.
  # :all means every action on that tool is public.
  @public_tool_actions %{
    "session" => :all,
    "guide" => :all,
    "component" => ~w(search inspect categories setup_plan list),
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

  def dispatch(_session, %Message{type: type}) do
    {:error, :invalid_request, "Unexpected message type: #{type}"}
  end

  # ============================================================================
  # Lifecycle Methods
  # ============================================================================

  defp dispatch_method(_session, "initialize", params, _id) do
    client_version = params["protocolVersion"]

    if compatible_version?(client_version) do
      {:ok,
       %{
         "protocolVersion" => @protocol_version,
         "capabilities" => @server_capabilities,
         "serverInfo" => @server_info,
         "instructions" => "CYFR MCP server. Use tools/list to discover available tools."
       }}
    else
      {:error, :invalid_protocol,
       "Unsupported protocol version: #{client_version}. Server supports: #{@protocol_version}"}
    end
  end

  defp dispatch_method(_session, "ping", _params, _id) do
    {:ok, %{}}
  end

  # ============================================================================
  # Tool Methods
  # ============================================================================

  defp dispatch_method(_session, "tools/list", _params, _id) do
    # Use the new registry for tool discovery
    tools = ToolRegistry.list_tools()
    {:ok, %{"tools" => tools}}
  end

  defp dispatch_method(session, "tools/call", params, _id) do
    name = params["name"]
    arguments = params["arguments"] || %{}
    action = arguments["action"]

    if not session.context.authenticated and not public_tool_action?(name, action) do
      {:error, :auth_required, "Authentication required. Run 'cyfr login' to sign in."}
    else
      case ToolRegistry.call(name, session.context, arguments) do
        {:ok, result} ->
          text = case Jason.encode(result) do
            {:ok, encoded} -> encoded
            {:error, encode_error} ->
              require Logger
              Logger.error("[MCP.Router] Tool #{name} returned non-JSON-encodable result: #{inspect(encode_error)}")
              Jason.encode!(%{error: "Tool returned non-serializable result", tool: name})
          end

          {:ok,
           %{
             "content" => [
               %{
                 "type" => "text",
                 "text" => text
               }
             ]
           }}

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

  # ============================================================================
  # Resource Methods
  # ============================================================================

  defp dispatch_method(_session, "resources/list", _params, _id) do
    resources = ResourceRegistry.list_resources()
    {:ok, %{"resources" => resources}}
  end

  defp dispatch_method(session, "resources/read", params, _id) do
    uri = params["uri"]

    case ResourceRegistry.read(session.context, uri) do
      {:ok, content} ->
        {:ok,
         %{
           "contents" => [
             %{
               "uri" => uri,
               "mimeType" => Map.get(content, :mimeType, "application/json"),
               "text" => encode_content(content)
             }
           ]
         }}

      {:error, reason} ->
        {:error, :invalid_params, "Failed to read resource: #{inspect(reason)}"}
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

  defp encode_content(%{content: content}) when is_binary(content), do: content
  defp encode_content(%{content: content}), do: Jason.encode!(content)
  defp encode_content(content) when is_map(content), do: Jason.encode!(content)
  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: inspect(content)

  # ============================================================================
  # Notifications
  # ============================================================================

  defp dispatch_notification(_session, "notifications/initialized", _params) do
    # Client has completed initialization
    :ok
  end

  defp dispatch_notification(_session, "notifications/cancelled", params) do
    # Client cancelled a request - log it but nothing to do for now
    request_id = params["requestId"]
    require Logger
    Logger.debug("MCP: Client cancelled request #{request_id}")
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

  defp public_tool_action?(name, action) do
    case Map.get(@public_tool_actions, name) do
      :all -> true
      actions when is_list(actions) -> action in actions
      nil -> false
    end
  end

  defp compatible_version?(client_version) do
    # For now, require exact match. Could be more lenient later.
    client_version == @protocol_version
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

    if compatible_version?(client_version) do
      {:ok, session} = Session.create(context, @server_capabilities)

      result = %{
        "protocolVersion" => @protocol_version,
        "capabilities" => @server_capabilities,
        "serverInfo" => @server_info,
        "instructions" => "CYFR MCP server. Use tools/list to discover available tools."
      }

      {:ok, result, session}
    else
      {:error, :invalid_protocol,
       "Unsupported protocol version: #{client_version}. Server supports: #{@protocol_version}"}
    end
  end
end
