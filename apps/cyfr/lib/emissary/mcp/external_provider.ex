# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalProvider do
  @moduledoc """
  MCP tool provider for managing external MCP server connections.

  Provides:
  - `mcp_servers` tool: CRUD operations for external MCP server configs
  - `list_external_tools/1`: Returns discovered tools from all enabled servers (called by SystemProvider)
  - `try_handle/3`: Dispatches namespaced tool calls to external servers (called by ToolRegistry)

  External tools appear in `tools/list` as `server_name:tool_name` (e.g., `notion:create_page`).
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Sanctum.Context
  require Logger

  @external_tools_cache_ttl :timer.seconds(30)

  # ============================================================================
  # ToolProvider Callbacks
  # ============================================================================

  @impl true
  def tools do
    [
      %{
        name: "mcp_servers",
        title: "MCP Servers",
        description:
          "Manage external MCP server connections. Create, delete, enable/disable, and test connections to external MCP servers (e.g., Notion, GitHub, custom servers). External server tools appear in tools/list as server_name:tool_name.",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: true,
          actions: %{
            "create" => %{kind: :write},
            "delete" => %{kind: :destructive},
            "list" => %{kind: :read},
            "get" => %{kind: :read},
            "test" => %{kind: :execute},
            "refresh" => %{kind: :write},
            "enable" => %{kind: :write},
            "disable" => %{kind: :write}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["create", "delete", "list", "get", "test", "refresh", "enable", "disable"],
              "description" => "Action to perform"
            },
            "name" => %{
              "type" => "string",
              "description" =>
                "Server name (required for create/delete/get/test/refresh/enable/disable)"
            },
            "config" => %{
              "type" => "object",
              "properties" => %{
                "url" => %{
                  "type" => "string",
                  "description" => "MCP server endpoint URL"
                },
                "headers" => %{
                  "type" => "object",
                  "description" =>
                    "HTTP headers. Use 'secret:SECRET_NAME' to reference stored secrets."
                },
                "timeout_ms" => %{
                  "type" => "integer",
                  "description" => "Request timeout in milliseconds (default: 30000)"
                }
              },
              "description" => "Server configuration (required for create)"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  @impl true
  def handle("mcp_servers", %Context{} = ctx, %{"action" => "create"} = args) do
    handle_create(ctx, args)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "delete"} = args) do
    handle_delete(ctx, args)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "list"}) do
    handle_list(ctx)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "get"} = args) do
    handle_get(ctx, args)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "test"} = args) do
    handle_test(ctx, args)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "refresh"} = args) do
    handle_refresh(ctx, args)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "enable"} = args) do
    handle_enable_disable(ctx, args, true)
  end

  def handle("mcp_servers", %Context{} = ctx, %{"action" => "disable"} = args) do
    handle_enable_disable(ctx, args, false)
  end

  def handle("mcp_servers", _ctx, %{"action" => action}) do
    {:error, "Unknown action: #{action}"}
  end

  def handle("mcp_servers", _ctx, _args) do
    {:error, "Missing required parameter: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # External Tool Discovery (called by SystemProvider)
  # ============================================================================

  @doc """
  List all tools from enabled external MCP servers for the given tenant.

  Returns tool definitions with names prefixed as `server_name:tool_name`.
  Called by `SystemProvider.handle("tools", ctx, %{"action" => "list"})`.
  """
  @spec list_external_tools(Context.t()) :: [map()]
  def list_external_tools(%Context{} = ctx) do
    cache_key = {:external_tools, norm_org(ctx), ctx.project_id}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} ->
        cached

      :miss ->
        tools = fetch_external_tools(ctx)

        case Arca.Cache.put(cache_key, tools, @external_tools_cache_ttl) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("[ExternalProvider] Cache put failed: #{inspect(reason)}")
        end

        tools
    end
  end

  @doc """
  Invalidate the cached external tools list for the given tenant.
  Called after add, delete, enable, disable, and refresh operations.
  """
  @spec invalidate_external_tools_cache(Context.t()) :: :ok
  def invalidate_external_tools_cache(%Context{} = ctx) do
    Arca.Cache.invalidate({:external_tools, norm_org(ctx), ctx.project_id})
  end

  defp fetch_external_tools(%Context{} = ctx) do
    case Arca.McpServerStorage.list(ctx) do
      {:ok, servers} ->
        servers
        |> Enum.filter(& &1.enabled)
        |> Task.async_stream(
          fn server -> {server, ensure_server_started(server, ctx)} end,
          max_concurrency: 10,
          timeout: 15_000,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, {server, {:ok, tools}}} ->
            Enum.map(tools, fn tool ->
              upstream_ann = tool["annotations"] || %{}

              %{
                "name" => "#{server.name}:#{tool["name"]}",
                "description" => "[#{server.name}] #{tool["description"] || ""}",
                "inputSchema" => tool["inputSchema"] || tool["parameters"] || %{},
                # Pass through upstream MCP-spec hints. AQUA classifies any
                # `server:tool`-namespaced tool as `:external` via
                # `Prism.AquaActions.kind_for/2`; no per-action annotation
                # needed. Users still override per-action in their
                # tool_policy if they want to auto-allow trusted reads.
                "annotations" => %{
                  "readOnlyHint" => upstream_ann["readOnlyHint"],
                  "destructiveHint" => upstream_ann["destructiveHint"],
                  "openWorldHint" => upstream_ann["openWorldHint"]
                }
              }
            end)

          {:ok, {_server, {:error, reason}}} ->
            Logger.warning(
              "[ExternalProvider] Failed to get tools from server: #{inspect(reason)}"
            )

            []

          {:exit, reason} ->
            Logger.warning(
              "[ExternalProvider] Server tool fetch timed out or crashed: #{inspect(reason)}"
            )

            []
        end)

      {:error, reason} ->
        Logger.warning(
          "[ExternalProvider] Failed to list servers: #{inspect(reason)}"
        )

        []
    end
  end

  # ============================================================================
  # External Tool Dispatch (called by ToolRegistry on cache miss)
  # ============================================================================

  @doc """
  Try to handle a tool call as an external server tool.

  Parses `server_name:tool_name` format and dispatches to the appropriate
  external server. Returns `{:error, :not_external}` if the tool name
  doesn't match an external server.
  """
  @spec try_handle(String.t(), Context.t(), map()) ::
          {:ok, map()} | {:error, :not_external | String.t()}
  def try_handle(tool_name, %Context{} = ctx, args) do
    case String.split(tool_name, ":", parts: 2) do
      [server_name, remote_tool] ->
        case Arca.McpServerStorage.get(ctx, server_name) do
          {:ok, server} ->
            if server.enabled do
              server_config = build_server_config(server, ctx)

              case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
                {:ok, _pid} ->
                  arguments = Map.delete(args, "action")

                  Emissary.MCP.ExternalServer.call_tool(
                    server_name,
                    norm_org(ctx),
                    ctx.project_id,
                    remote_tool,
                    arguments
                  )

                {:error, reason} ->
                  {:error, "Failed to start server '#{server_name}': #{inspect(reason)}"}
              end
            else
              {:error, "Server '#{server_name}' is disabled"}
            end

          {:error, :not_found} ->
            {:error, :not_external}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      _ ->
        {:error, :not_external}
    end
  end

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp handle_create(ctx, args) do
    name = args["name"]
    config = args["config"] || %{}

    cond do
      is_nil(name) or name == "" ->
        {:error, "Missing required parameter: name"}

      String.contains?(to_string(name), ":") ->
        {:error, "Server name cannot contain ':' (reserved for tool namespacing)"}

      is_nil(config["url"]) or config["url"] == "" ->
        {:error, "Missing required parameter: config.url"}

      true ->
        case Cyfr.Network.validate_redirect_url(config["url"],
               allow_private: not Sanctum.auth_configured?()
             ) do
          {:error, reason} ->
            {:error, "Invalid URL: #{reason}"}

          :ok ->
            handle_create_validated(ctx, name, config)
        end
    end
  end

  defp handle_create_validated(ctx, name, config) do
    max = Application.get_env(:cyfr, :max_external_servers, 50)

    with {:ok, existing} <- Arca.McpServerStorage.list(ctx),
         true <- length(existing) < max || {:error, "Maximum server limit (#{max}) reached"} do
      attrs = %{
        name: name,
        url: config["url"],
        config_json: %{
          "headers" => config["headers"] || %{},
          "timeout_ms" => config["timeout_ms"] || 30_000
        }
      }

      case Arca.McpServerStorage.put(ctx, attrs) do
        {:ok, _server} ->
          invalidate_external_tools_cache(ctx)
          broadcast_mcp_servers_changed(ctx)

          server_config =
            build_server_config(%{name: name, url: config["url"], config: config}, ctx)

          result =
            case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
              {:ok, _pid} ->
                case Emissary.MCP.ExternalServer.get_tools(
                       name,
                       norm_org(ctx),
                       ctx.project_id
                     ) do
                  {:ok, tools} ->
                    %{
                      name: name,
                      url: config["url"],
                      status: "ready",
                      tools_discovered: length(tools),
                      tool_names: Enum.map(tools, & &1["name"])
                    }

                  {:error, reason} ->
                    %{
                      name: name,
                      url: config["url"],
                      status: "error",
                      error: inspect(reason)
                    }
                end

              {:error, reason} ->
                %{
                  name: name,
                  url: config["url"],
                  status: "error",
                  error: "Failed to start server process: #{inspect(reason)}"
                }
            end

          {:ok, result}

        {:error, reason} ->
          {:error, "Failed to save server config: #{inspect(reason)}"}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, "Storage error: #{reason}"}
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, other} -> {:error, inspect(other)}
    end
  end

  defp handle_delete(ctx, args) do
    name = args["name"]

    if is_nil(name) or name == "" do
      {:error, "Missing required parameter: name"}
    else
      # Stop the running server process
      Emissary.MCP.ExternalServerSupervisor.stop(
        name,
        norm_org(ctx),
        ctx.project_id
      )

      case Arca.McpServerStorage.delete(ctx, name) do
        :ok ->
          invalidate_external_tools_cache(ctx)
          broadcast_mcp_servers_changed(ctx)
          {:ok, %{deleted: name}}

        {:error, reason} ->
          {:error, "Failed to delete server: #{inspect(reason)}"}
      end
    end
  end

  defp handle_list(ctx) do
    case Arca.McpServerStorage.list(ctx) do
      {:ok, servers} ->
        server_list =
          Enum.map(servers, fn server ->
            # Auto-start enabled servers so status reflects reality
            if server.enabled do
              server_config = build_server_config(server, ctx)
              Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config)
            end

            status =
              Emissary.MCP.ExternalServer.status(
                server.name,
                norm_org(ctx),
                ctx.project_id
              )

            %{
              name: server.name,
              url: server.url,
              enabled: server.enabled,
              status: format_status(status),
              tool_count: format_tool_count(status)
            }
          end)

        {:ok, %{servers: server_list, count: length(server_list)}}

      {:error, reason} ->
        {:error, "Failed to list servers: #{inspect(reason)}"}
    end
  end

  defp handle_get(ctx, args) do
    name = args["name"]

    if is_nil(name) or name == "" do
      {:error, "Missing required parameter: name"}
    else
      case Arca.McpServerStorage.get(ctx, name) do
        {:ok, server} ->
          # Auto-start enabled servers so status reflects reality
          if server.enabled do
            server_config = build_server_config(server, ctx)
            Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config)
          end

          status =
            Emissary.MCP.ExternalServer.status(
              name,
              norm_org(ctx),
              ctx.project_id
            )

          tools =
            case status do
              %{status: :ready} ->
                case Emissary.MCP.ExternalServer.get_tools(
                       name,
                       norm_org(ctx),
                       ctx.project_id
                     ) do
                  {:ok, t} -> t
                  {:error, _} -> []
                end

              _ ->
                []
            end

          {:ok,
           %{
             name: server.name,
             url: server.url,
             enabled: server.enabled,
             config: server.config,
             status: format_status(status),
             server_info: format_server_info(status),
             tools: tools
           }}

        {:error, :not_found} ->
          {:error, "Server '#{name}' not found"}

        {:error, reason} ->
          {:error, "Failed to get server: #{inspect(reason)}"}
      end
    end
  end

  defp handle_test(ctx, args) do
    name = args["name"]

    if is_nil(name) or name == "" do
      {:error, "Missing required parameter: name"}
    else
      case Arca.McpServerStorage.get(ctx, name) do
        {:ok, server} ->
          server_config = build_server_config(server, ctx)

          case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
            {:ok, _pid} ->
              case Emissary.MCP.ExternalServer.reinitialize(
                     name,
                     norm_org(ctx),
                     ctx.project_id
                   ) do
                {:ok, _status} ->
                  status =
                    Emissary.MCP.ExternalServer.status(
                      name,
                      norm_org(ctx),
                      ctx.project_id
                    )

                  {:ok,
                   %{
                     name: name,
                     status: format_status(status),
                     tool_count: format_tool_count(status),
                     server_info: format_server_info(status)
                   }}

                {:error, reason} ->
                  {:ok, %{name: name, status: "error", error: inspect(reason)}}
              end

            {:error, reason} ->
              {:ok,
               %{
                 name: name,
                 status: "error",
                 error: "Failed to start: #{inspect(reason)}"
               }}
          end

        {:error, :not_found} ->
          {:error, "Server '#{name}' not found"}

        {:error, reason} ->
          {:error, "Failed to get server: #{inspect(reason)}"}
      end
    end
  end

  defp handle_refresh(ctx, args) do
    name = args["name"]

    if name && name != "" do
      # Refresh single server — verify tenant ownership first
      case Arca.McpServerStorage.get(ctx, name) do
        {:ok, server} ->
          server_config = build_server_config(server, ctx)

          case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
            {:ok, _pid} ->
              case Emissary.MCP.ExternalServer.reinitialize(
                     name,
                     norm_org(ctx),
                     ctx.project_id
                   ) do
                {:ok, _} ->
                  invalidate_external_tools_cache(ctx)
                  {:ok, %{refreshed: [name]}}

                {:error, reason} ->
                  {:error, "Failed to refresh #{name}: #{inspect(reason)}"}
              end

            {:error, reason} ->
              {:error, "Failed to start server '#{name}': #{inspect(reason)}"}
          end

        {:error, :not_found} ->
          {:error, "Server '#{name}' not found"}

        {:error, reason} ->
          {:error, "Failed to get server: #{inspect(reason)}"}
      end
    else
      # Refresh all servers — parallel with concurrency limit
      case Arca.McpServerStorage.list(ctx) do
        {:ok, servers} ->
          results =
            servers
            |> Task.async_stream(
              fn server ->
                server_config = build_server_config(server, ctx)

                result =
                  case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
                    {:ok, _pid} ->
                      Emissary.MCP.ExternalServer.reinitialize(
                        server.name,
                        norm_org(ctx),
                        ctx.project_id
                      )

                    {:error, reason} ->
                      {:error, reason}
                  end

                {server.name, result}
              end,
              max_concurrency: 10,
              timeout: 30_000,
              on_timeout: :kill_task,
              ordered: false
            )
            |> Enum.map(fn
              {:ok, {name, {:ok, _}}} -> {name, :ok}
              {:ok, {name, {:error, reason}}} -> {name, {:error, reason}}
              {:exit, reason} -> {"unknown", {:error, reason}}
            end)

          refreshed = for {name, :ok} <- results, do: name
          failed = for {name, {:error, r}} <- results, do: %{name: name, error: inspect(r)}

          if refreshed != [], do: invalidate_external_tools_cache(ctx)

          {:ok, %{refreshed: refreshed, failed: failed}}

        {:error, reason} ->
          {:error, "Failed to list servers: #{inspect(reason)}"}
      end
    end
  end

  defp handle_enable_disable(ctx, args, enabled) do
    name = args["name"]
    action_name = if enabled, do: "enable", else: "disable"

    if is_nil(name) or name == "" do
      {:error, "Missing required parameter: name"}
    else
      case Arca.McpServerStorage.update(ctx, name, %{enabled: enabled}) do
        {:ok, server} ->
          invalidate_external_tools_cache(ctx)
          broadcast_mcp_servers_changed(ctx)

          # Stop the process if disabling
          unless enabled do
            Emissary.MCP.ExternalServerSupervisor.stop(
              name,
              norm_org(ctx),
              ctx.project_id
            )
          end

          {:ok, %{name: server.name, enabled: server.enabled, action: "#{action_name}d"}}

        {:error, :not_found} ->
          {:error, "Server '#{name}' not found"}

        {:error, reason} ->
          {:error, "Failed to #{action_name} server: #{inspect(reason)}"}
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp ensure_server_started(server, ctx) do
    server_config = build_server_config(server, ctx)

    case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
      {:ok, _pid} ->
        Emissary.MCP.ExternalServer.get_tools(
          server.name,
          norm_org(ctx),
          ctx.project_id
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_server_config(%{name: name, url: url} = server, %Context{} = ctx) do
    config = Map.get(server, :config) || %{}

    [
      name: name,
      url: url,
      headers: config["headers"] || %{},
      timeout_ms: config["timeout_ms"] || 30_000,
      org_id: norm_org(ctx),
      project_id: ctx.project_id
    ]
  end

  defp norm_org(ctx), do: ctx.org_id || ""

  defp format_status(%{status: status}), do: to_string(status)
  defp format_status(:disconnected), do: "disconnected"
  defp format_status(_), do: "unknown"

  defp format_tool_count(%{tool_count: count}), do: count
  defp format_tool_count(_), do: 0

  defp format_server_info(%{server_info: info}), do: info
  defp format_server_info(_), do: nil

  defp broadcast_mcp_servers_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:mcp_servers", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :mcp_servers_changed)
  end
end