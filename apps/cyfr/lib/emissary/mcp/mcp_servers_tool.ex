# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.McpServersTool do
  @moduledoc """
  The `mcp_servers` tool: the operator's external MCP server connections —
  create, delete, list, get, test, refresh, enable, disable.

  Connection config is shared infrastructure: a URL, a header map that may
  name vault Connections, and the tool patterns the server is allowed to
  offer at all. Reads are open to any authenticated caller; every mutation
  is `permission: :admin`, because it changes where this server sends
  requests and which stored credential rides along.

  A literal credential in a credential-shaped header is refused rather than
  sealed — `mcp_servers.config_json` is not an encrypted column, and a token
  written there would sit in plaintext. `vault:<name>` is the way in.

  What the connected servers' *tools* then do lives next door:
  `Emissary.MCP.ExternalProvider` discovers and dispatches them, and both
  modules build their connection config from
  `Emissary.MCP.ExternalServers`.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Emissary.MCP.ExternalProvider
  alias Emissary.MCP.ExternalServers
  alias Sanctum.Context

  @impl true
  def tools, do: [definition()]

  @impl true
  def handle("mcp_servers", %Context{} = ctx, args) when is_map(args), do: handle(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, "Unknown tool: #{tool}"}

  @doc "The tool definition: name, annotations (the gate), and input schema."
  @spec definition() :: map()
  def definition do
    %{
      name: "mcp_servers",
      title: "MCP Servers",
      description:
        "Manage external MCP server connections. Create, delete, enable/disable, and test connections to external MCP servers (e.g., Notion, GitHub, custom servers). External server tools appear in tools/list as server_name:tool_name.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          "create" => %{kind: :write, planes: [:external], permission: :admin},
          "delete" => %{kind: :destructive, planes: [:external], permission: :admin},
          # Connection config (URLs, header maps, vault binding names) is
          # shared operator infrastructure, readable by any authenticated
          # user — but it is not a chain capability: a formula uses the
          # connected servers' TOOLS through its authority grants, it never
          # reads the wiring behind them.
          "list" => %{kind: :read, planes: [:external]},
          "get" => %{kind: :read, planes: [:external]},
          "test" => %{kind: :execute, planes: [:external], permission: :admin},
          "refresh" => %{kind: :write, planes: [:external], permission: :admin},
          "enable" => %{kind: :write, planes: [:external], permission: :admin},
          "disable" => %{kind: :write, planes: [:external], permission: :admin}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "create",
              "delete",
              "list",
              "get",
              "test",
              "refresh",
              "enable",
              "disable"
            ],
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
                  "HTTP headers. Use 'vault:CONNECTION' to reference a single-field Connection."
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
  end

  # Server management mutates an outbound HTTP endpoint that can reference
  # stored secrets in its headers — the dispatcher enforces the :admin gate
  # from these actions' annotations. Reads (list/get) stay open to any
  # authenticated caller by annotation.
  @admin_actions ~w(create delete test refresh enable disable)

  def handle(%Context{} = ctx, %{"action" => action} = args)
      when action in @admin_actions do
    dispatch_admin(action, ctx, args)
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    handle_list(ctx)
  end

  def handle(%Context{} = ctx, %{"action" => "get"} = args) do
    handle_get(ctx, args)
  end

  def handle(_ctx, %{"action" => action}) do
    {:error, "Unknown action: #{action}"}
  end

  def handle(_ctx, _args) do
    {:error, "Missing required parameter: action"}
  end

  defp dispatch_admin("create", ctx, args), do: handle_create(ctx, args)
  defp dispatch_admin("delete", ctx, args), do: handle_delete(ctx, args)
  defp dispatch_admin("test", ctx, args), do: handle_test(ctx, args)
  defp dispatch_admin("refresh", ctx, args), do: handle_refresh(ctx, args)
  defp dispatch_admin("enable", ctx, args), do: handle_enable_disable(ctx, args, true)
  defp dispatch_admin("disable", ctx, args), do: handle_enable_disable(ctx, args, false)
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
        with :ok <- validate_header_credentials(config["headers"]),
             :ok <- validate_create_url(config["url"]) do
          handle_create_validated(ctx, name, config)
        end
    end
  end

  defp validate_create_url(url) do
    case Cyfr.Network.validate_redirect_url(url, allow_private: :policy) do
      :ok -> :ok
      {:error, reason} -> {:error, "Invalid URL: #{reason}"}
    end
  end

  # A literal value in a credential-shaped header would be persisted
  # UNENCRYPTED in mcp_servers.config_json. Reject it instead of sealing —
  # `vault:NAME` references resolve host-side from the sealed vault
  # (writer-independently). `secret:` references retired with that plane.
  defp validate_header_credentials(headers) when is_map(headers) do
    Enum.find_value(headers, :ok, fn {key, value} ->
      cond do
        # A retired-scheme reference in ANY header would otherwise be
        # persisted and only fail at server boot ("Failed to resolve
        # header") — refuse it here where the message can explain.
        is_binary(value) and String.starts_with?(value, "secret:") ->
          {:error,
           "Header '#{key}' uses the retired \"secret:\" reference — " <>
             "use \"vault:CONNECTION\" (a single-field vault entry)"}

        is_binary(value) and not String.starts_with?(value, "vault:") and
            credential_shaped_header_name?(key) ->
          {:error,
           "Header '#{key}' looks like a credential and must reference a Connection — " <>
             "use \"vault:CONNECTION\" (a single-field vault entry)"}

        true ->
          nil
      end
    end)
  end

  defp validate_header_credentials(_headers), do: :ok

  defp credential_shaped_header_name?(key) do
    k = key |> to_string() |> String.downcase()

    k in ["authorization", "proxy-authorization", "cookie", "x-api-key"] or
      String.contains?(k, "token") or String.contains?(k, "secret") or
      String.contains?(k, "auth") or String.contains?(k, "key")
  end

  defp validate_tool_patterns(nil), do: :ok

  defp validate_tool_patterns(patterns) when is_list(patterns) do
    case Enum.reject(patterns, &Sanctum.ToolPattern.valid?/1) do
      [] ->
        :ok

      bad ->
        {:error,
         "Invalid tool_patterns #{inspect(bad)} — use \"*\", an exact tool name, " <>
           "or a dot-boundary prefix like \"issues.*\""}
    end
  end

  defp validate_tool_patterns(_), do: {:error, "tool_patterns must be a list of strings"}

  defp handle_create_validated(ctx, name, config) do
    max = Application.get_env(:cyfr, :max_external_servers, 50)

    with {:ok, existing} <- Arca.McpServerStorage.list(ctx),
         true <- length(existing) < max || {:error, "Maximum server limit (#{max}) reached"},
         :ok <- validate_tool_patterns(config["tool_patterns"]) do
      attrs = %{
        name: name,
        url: config["url"],
        config_json:
          encode_config_json(
            %{
              "headers" => config["headers"] || %{},
              "timeout_ms" => config["timeout_ms"] || 30_000
            }
            |> then(fn base ->
              case config["tool_patterns"] do
                nil -> base
                patterns -> Map.put(base, "tool_patterns", patterns)
              end
            end)
          )
      }

      case Arca.McpServerStorage.put(ctx, attrs) do
        {:ok, _server} ->
          ExternalProvider.invalidate_external_tools_cache(ctx)
          broadcast_mcp_servers_changed(ctx)

          server_config =
            ExternalServers.server_config(%{name: name, url: config["url"], config: config}, ctx)

          result =
            case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
              {:ok, _pid} ->
                case Emissary.MCP.ExternalServer.get_tools(
                       name,
                       ctx.athanor_id
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
        ctx.athanor_id
      )

      case Arca.McpServerStorage.delete(ctx, name) do
        :ok ->
          ExternalProvider.invalidate_external_tools_cache(ctx)
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
            # Listing reads; it does not connect. A server that has never
            # been used reports :disconnected here — invocation (and get,
            # which reports the live tool catalogue) starts it on demand.
            status =
              Emissary.MCP.ExternalServer.status(
                server.name,
                ctx.athanor_id
              )

            %{
              name: server.name,
              url: server.url,
              enabled: server.enabled,
              status: format_status(status),
              tool_count: format_tool_count(status),
              # The Connections this server's headers draw on, by name only
              # (`vault:<entry>` values) — so a Connection can show who
              # consumes it before someone revokes it out from under a server.
              vault_refs: vault_refs(server)
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
            server_config = ExternalServers.server_config(server, ctx)
            Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config)
          end

          status =
            Emissary.MCP.ExternalServer.status(
              name,
              ctx.athanor_id
            )

          tools =
            case status do
              %{status: :ready} ->
                case Emissary.MCP.ExternalServer.get_tools(
                       name,
                       ctx.athanor_id
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
             config: ExternalServers.config_map(server),
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
          server_config = ExternalServers.server_config(server, ctx)

          case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
            {:ok, _pid} ->
              case Emissary.MCP.ExternalServer.reinitialize(
                     name,
                     ctx.athanor_id
                   ) do
                {:ok, _status} ->
                  status =
                    Emissary.MCP.ExternalServer.status(
                      name,
                      ctx.athanor_id
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
          server_config = ExternalServers.server_config(server, ctx)

          case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
            {:ok, _pid} ->
              case Emissary.MCP.ExternalServer.reinitialize(
                     name,
                     ctx.athanor_id
                   ) do
                {:ok, _} ->
                  ExternalProvider.invalidate_external_tools_cache(ctx)
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
                server_config = ExternalServers.server_config(server, ctx)

                result =
                  case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
                    {:ok, _pid} ->
                      Emissary.MCP.ExternalServer.reinitialize(
                        server.name,
                        ctx.athanor_id
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

          if refreshed != [], do: ExternalProvider.invalidate_external_tools_cache(ctx)

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
          ExternalProvider.invalidate_external_tools_cache(ctx)
          broadcast_mcp_servers_changed(ctx)

          # Stop the process if disabling
          unless enabled do
            Emissary.MCP.ExternalServerSupervisor.stop(
              name,
              ctx.athanor_id
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

  # The vault entry names a server's headers reference (`vault:<name>`).
  defp vault_refs(server) do
    server
    |> ExternalServers.config_map()
    |> Map.get("headers", %{})
    |> Enum.flat_map(fn
      {_header, "vault:" <> name} when name != "" -> [name]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp encode_config_json(config) when is_map(config) do
    case Jason.encode(config) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp format_status(%{status: status}), do: to_string(status)
  defp format_status(:disconnected), do: "disconnected"
  defp format_status(_), do: "unknown"

  defp format_tool_count(%{tool_count: count}), do: count
  defp format_tool_count(_), do: 0

  defp format_server_info(%{server_info: info}), do: info
  defp format_server_info(_), do: nil

  # Topic name is `mcp_servers`, not `prism:mcp_servers`: the console was the
  # only listener when this was written, but adding or removing a server changes
  # which `server:tool` names exist, so an MCP client holding a
  # `subscriptions/listen` stream is a listener too. The event was never
  # console-specific.
  defp broadcast_mcp_servers_changed(ctx) do
    topic = Prism.Topics.mcp_servers(ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :mcp_servers_changed)
  end
end
