# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.Provider do
  @moduledoc """
  The `mcp_servers` tool: the operator's external MCP server connections —
  create, update, delete, list, get, test, refresh, enable, disable,
  restart.

  A server has a transport:

    * `http` — a URL and a header map that may name vault entries;
    * `stdio` — backends (`Emissary.External.BackendDefinition`) the MCP bridge
      runs, each a command and an env map whose credentials are vault
      templates. Refused when this server runs no bridge controller
      (`Emissary.External.Backends`) or runs as a cluster.

  Both carry the tool patterns the server is allowed to offer at all. Every
  action but `list` is `permission: :admin`, because it reads or changes
  where this server sends requests, what the bridge runs and which stored
  credential rides along; the listing (names, transport, status and the
  vault entries a server reads) is open to any authenticated caller.

  `create` and `update` are also `consent: :interactive`: a definition
  binds vault entries to a command, a URL or headers, and the server
  unseals those entries by name whenever it starts, so defining or changing
  one is a person's act in an interactive session, like `vault.create` and
  `profile.grant`. An admin API key operates saved servers — get, test,
  refresh, restart, enable, disable, delete — and defines none. No action
  is reachable from a running chain.

  Every write raises the row's epoch. `update` names the epoch it read and
  is refused when the row has moved on. A write that changes what runs —
  update, delete, disable, restart — stops the server's process, which
  releases a stdio server's backends on the bridge; the next use starts it
  again at the new epoch.

  A literal credential in a credential-shaped header is refused rather than
  sealed — `mcp_servers.config_json` is not an encrypted column, and a token
  written there would sit in plaintext. `vault:<name>` is the way in.

  What the connected servers' *tools* then do lives next door:
  `Emissary.External.Proxy` discovers and dispatches them, and both
  modules build their connection config from
  `Emissary.External.Servers`.
  """

  @behaviour Prima.Provider

  require Logger

  @impl true
  def service, do: "emissary"

  alias Emissary.External.BackendDefinition
  alias Emissary.External.Proxy
  alias Emissary.External.Servers
  alias Prima.VaultRef
  alias Sanctum.Context

  @impl true
  def tools, do: [definition()]

  @impl true
  def handle("mcp_servers", %Context{} = ctx, args) when is_map(args), do: handle(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, "Unknown tool: #{tool}"}

  @doc "The tool definition: name, annotations (the gate), and input schema."
  @spec definition() :: map()
  def definition do
    alias Prima.{Arg, Operation}
    # The listing (names, transport, status, the vault entries a server
    # reads) is open to any authenticated caller; a server's connection
    # config is the operator's. Neither is a chain capability: a
    # formula uses the connected servers' TOOLS through its authority
    # grants, it never reads the wiring behind them.
    config_arg =
      Arg.new(
        "config",
        {:record,
         [
           Arg.new(
             "backends",
             {:array,
              Arg.new(
                nil,
                {:record,
                 [
                   Arg.new("command", :string, required: true),
                   Arg.new("env", {:map, Arg.new(nil, :string)}),
                   Arg.new("name", :string, required: true)
                 ]}
              )},
             description:
               "The stdio backends, at most #{BackendDefinition.max_backends()}: {name, command, env}. A command never names a vault entry; every env value is 'vault:ENTRY' except NODE_ENV, LOG_LEVEL, TZ, LANG, LC_ALL, NO_COLOR and DEBUG, which may be literals."
           ),
           Arg.new("console", :boolean,
             description:
               "Allow this server's tools to be called from the console (external plane). Default false: proxied tools are reachable only from inside a chain."
           ),
           Arg.new("headers", {:map, Arg.new(nil, :string)},
             description:
               "HTTP headers (http). Use 'vault:ENTRY' or 'Bearer vault:ENTRY' to reference a single-field vault entry."
           ),
           Arg.new("timeout_ms", :integer,
             description: "Request timeout in milliseconds (default: 30000)"
           ),
           Arg.new("tool_patterns", {:array, Arg.new(nil, :string)},
             description: "The tools the server may offer (default: all)"
           ),
           Arg.new("transport", :string,
             description: "http (default): a URL. stdio: backends the MCP bridge runs.",
             enum: ["http", "stdio"]
           ),
           Arg.new("url", :string, description: "MCP server endpoint URL (http)")
         ]},
        required: true,
        description: "Server configuration (required for create; update replaces it whole)"
      )

    Operation.tool(
      [
        Operation.new(
          "mcp_servers",
          "create",
          "Create mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            ),
            config_arg
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive,
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "update",
          "Update mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            ),
            config_arg,
            Arg.new("epoch", :integer,
              required: true,
              description:
                "The epoch the caller read with get (required for update; refused when the server has changed since)"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive,
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "delete",
          "Delete mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :destructive,
          planes: [:external],
          permission: :admin
        ),
        Operation.new("mcp_servers", "list", "List mcp servers", [],
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "mcp_servers",
          "get",
          "Get mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :read,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "test",
          "Test mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :execute,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "refresh",
          "Refresh mcp servers",
          [
            Arg.new("name", :string,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "enable",
          "Enable mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "disable",
          "Disable mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "restart",
          "Restart mcp servers",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Server name (required for every action but list; refresh without one refreshes every enabled server)"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :admin
        )
      ],
      description:
        "Manage external MCP server connections: HTTP servers (Notion, GitHub, custom servers) and stdio servers the MCP bridge runs (npx packages). Create, update, delete, enable/disable, restart and test them. External server tools appear in tools/list as server_name:tool_name.",
      title: "MCP Servers"
    )
  end

  @admin_actions ~w(create update delete test refresh enable disable restart)

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
    {:error, {:invalid_argument, "Unknown action: #{action}"}}
  end

  def handle(_ctx, _args) do
    {:error, {:invalid_argument, "Missing required parameter: action"}}
  end

  defp dispatch_admin("create", ctx, args), do: handle_create(ctx, args)
  defp dispatch_admin("update", ctx, args), do: handle_update(ctx, args)
  defp dispatch_admin("delete", ctx, args), do: handle_delete(ctx, args)
  defp dispatch_admin("test", ctx, args), do: handle_test(ctx, args)
  defp dispatch_admin("refresh", ctx, args), do: handle_refresh(ctx, args)
  defp dispatch_admin("enable", ctx, args), do: handle_enable_disable(ctx, args, true)
  defp dispatch_admin("disable", ctx, args), do: handle_enable_disable(ctx, args, false)
  defp dispatch_admin("restart", ctx, args), do: handle_restart(ctx, args)

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp handle_create(ctx, args) do
    with {:ok, name, attrs} <- server_args(args),
         :ok <- under_server_cap(ctx) do
      case Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), Map.put(attrs, :name, name)) do
        {:ok, server} ->
          {:ok, connect(ctx, server)}

        {:error, :exists} ->
          {:error, {:conflict, "Server '#{name}' already exists — change it with update"}}

        {:error, reason} ->
          Logger.warning(
            "[Emissary.External.Provider] failed to save server config: #{inspect(reason)}"
          )

          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  # The connection config is replaced whole, at the epoch the caller read;
  # whether the server is enabled is kept.
  defp handle_update(ctx, args) do
    with {:ok, name, attrs} <- server_args(args),
         {:ok, epoch} <- epoch_arg(args) do
      case Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), name, attrs, epoch) do
        {:ok, %{enabled: true} = server} ->
          stop_process(ctx, name)
          {:ok, connect(ctx, server)}

        {:ok, server} ->
          stop_process(ctx, name)
          changed(ctx)
          {:ok, summary(server, %{status: "disabled"})}

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, :stale_epoch} ->
          {:error,
           {:conflict,
            "Server '#{name}' changed since epoch #{epoch} — read it again with get and retry"}}

        {:error, reason} ->
          Logger.warning(
            "[Emissary.External.Provider] failed to update server config: #{inspect(reason)}"
          )

          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  defp epoch_arg(%{"epoch" => epoch}) when is_integer(epoch) and epoch > 0, do: {:ok, epoch}

  defp epoch_arg(_args),
    do: {:error, {:invalid_argument, "Missing required parameter: epoch (read it with get)"}}

  defp server_args(args) do
    name = args["name"]
    config = args["config"] || %{}

    cond do
      is_nil(name) or name == "" ->
        {:error, {:invalid_argument, "Missing required parameter: name"}}

      String.contains?(to_string(name), ":") ->
        {:error,
         {:invalid_argument, "Server name cannot contain ':' (reserved for tool namespacing)"}}

      not is_map(config) ->
        {:error, {:invalid_argument, "config must be an object"}}

      true ->
        with :ok <- validate_tool_patterns(config["tool_patterns"]),
             {:ok, attrs} <- transport_args(config["transport"] || "http", config) do
          {:ok, name, attrs}
        end
    end
  end

  defp transport_args("http", config) do
    cond do
      is_nil(config["url"]) or config["url"] == "" ->
        {:error, {:invalid_argument, "Missing required parameter: config.url"}}

      Map.has_key?(config, "backends") ->
        {:error, {:invalid_argument, "An http server has no backends — use transport stdio"}}

      true ->
        with :ok <- validate_header_credentials(config["headers"]),
             :ok <- validate_create_url(config["url"]) do
          base = %{"headers" => config["headers"] || %{}}

          {:ok,
           %{transport: "http", url: config["url"], config_json: stored_config(base, config)}}
        end
    end
  end

  defp transport_args("stdio", config) do
    cond do
      Map.has_key?(config, "url") ->
        {:error,
         {:invalid_argument, "A stdio server has no url — its backends run on the bridge"}}

      Map.has_key?(config, "headers") ->
        {:error, {:invalid_argument, "A stdio server has no headers — use backend env"}}

      true ->
        with :ok <- stdio_available(),
             {:ok, backends} <- BackendDefinition.validate(config["backends"]) do
          base = %{"backends" => backends}
          {:ok, %{transport: "stdio", url: nil, config_json: stored_config(base, config)}}
        end
    end
  end

  defp transport_args(_other, _config),
    do: {:error, {:invalid_argument, "Unknown transport — use http or stdio"}}

  defp stdio_available do
    cond do
      Application.get_env(:cyfr, :cluster, false) == true ->
        {:error, {:invalid_argument, "stdio servers are not available while CYFR_CLUSTER is on"}}

      not Emissary.External.Backends.running?() ->
        {:error,
         {:invalid_argument,
          "No MCP bridge is configured — set CYFR_MCP_BRIDGE_URL and CYFR_MCP_BRIDGE_KEY " <>
            "to run stdio servers"}}

      true ->
        :ok
    end
  end

  defp under_server_cap(ctx) do
    max = Application.get_env(:cyfr, :max_external_servers, 50)

    case Arca.McpServerStorage.list(Sanctum.Context.actor(ctx)) do
      {:ok, existing} when length(existing) < max -> :ok
      {:ok, _existing} -> {:error, "Maximum server limit (#{max}) reached"}
      {:error, reason} when is_atom(reason) -> {:error, "Storage error: #{reason}"}
      {:error, _reason} -> {:error, {:unavailable, "The server store"}}
    end
  end

  defp validate_create_url(url) do
    case Sanctum.Network.validate_redirect_url(url, private_policy: :operator) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_argument, "Invalid URL: #{reason}"}}
    end
  end

  # A literal value in a credential-shaped header would be persisted
  # UNENCRYPTED in mcp_servers.config_json. Reject it instead of sealing —
  # `vault:NAME` references resolve host-side from the sealed vault
  # (writer-independently).
  defp validate_header_credentials(headers) when is_map(headers) do
    Enum.find_value(headers, :ok, fn {key, value} ->
      cond do
        VaultRef.unresolved_ref?(value) ->
          {:error,
           "Header '#{key}' names a reference this server does not resolve — " <>
             "use \"vault:ENTRY\" (a single-field vault entry)"}

        is_binary(value) and not VaultRef.vault_ref?(value) and
            credential_shaped_header_name?(key) ->
          {:error,
           "Header '#{key}' looks like a credential and must reference a vault entry — " <>
             "use \"vault:ENTRY\" (a single-field vault entry)"}

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
    case Enum.reject(patterns, &Prima.ToolPattern.valid?/1) do
      [] ->
        :ok

      bad ->
        {:error,
         {:invalid_argument,
          "Invalid tool_patterns #{inspect(bad)} — use \"*\", an exact tool name, " <>
            "or a dot-boundary prefix like \"issues.*\""}}
    end
  end

  defp validate_tool_patterns(_),
    do: {:error, {:invalid_argument, "tool_patterns must be a list of strings"}}

  # The stored document: the transport's own keys, the timeout, the tool
  # patterns when given, and console reachability only when set — absent
  # means the in-chain default holds. `console` is not part of the consent
  # digest (`Sanctum.ToolServerDigest`).
  defp stored_config(base, config) do
    base
    |> Map.put("timeout_ms", config["timeout_ms"] || 30_000)
    |> then(fn stored ->
      case config["tool_patterns"] do
        nil -> stored
        patterns -> Map.put(stored, "tool_patterns", patterns)
      end
    end)
    |> then(&if(config["console"] == true, do: Map.put(&1, "console", true), else: &1))
    |> Jason.encode!()
  end

  # The stored server started (or restarted, when its row moved) and its
  # tools discovered, as the answer to a write that leaves it enabled.
  defp connect(ctx, server) do
    changed(ctx)

    case Emissary.External.ServerSupervisor.ensure_started(Servers.server_config(server, ctx)) do
      {:ok, _pid} ->
        case Emissary.External.Server.get_tools(server.name, ctx.athanor_id) do
          {:ok, tools} ->
            summary(server, %{
              status: "ready",
              tools_discovered: length(tools),
              tool_names: Enum.map(tools, & &1["name"])
            })

          {:error, reason} ->
            summary(server, %{status: "error", error: error_text(reason)})
        end

      {:error, reason} ->
        summary(server, %{
          status: "error",
          error: "Failed to start server process: #{error_text(reason)}"
        })
    end
  end

  defp summary(server, extra) do
    Map.merge(
      %{
        id: server.id,
        name: server.name,
        transport: server.transport,
        url: server.url,
        epoch: server.epoch
      },
      extra
    )
  end

  # A server's own sentence as it wrote it; any other reason as the
  # table's sentence — a start failure can carry the row's configuration,
  # and a term is never spelled back.
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: Grimoire.render(reason)

  # The row is deleted first; stopping the process then releases what it
  # ran.
  defp handle_delete(ctx, args) do
    with {:ok, name} <- name_arg(args) do
      case Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), name) do
        {:ok, server} ->
          stop_process(ctx, name)
          changed(ctx)
          {:ok, %{deleted: name, id: server.id}}

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, reason} ->
          Logger.warning(
            "[Emissary.External.Provider] failed to delete server: #{inspect(reason)}"
          )

          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  # A stdio server's backends are released and the server started again at
  # a new epoch.
  defp handle_restart(ctx, args) do
    with {:ok, name} <- name_arg(args) do
      case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
        {:ok, %{transport: transport}} when transport != "stdio" ->
          {:error,
           {:invalid_argument, "Only a stdio server restarts — '#{name}' is #{transport}"}}

        {:ok, %{enabled: false}} ->
          {:error, disabled(name)}

        {:ok, server} ->
          case Arca.McpServerStorage.bump_epoch(
                 Sanctum.Context.actor(ctx),
                 server.id,
                 server.epoch
               ) do
            {:ok, restarted} ->
              stop_process(ctx, name)
              {:ok, ctx |> connect(restarted) |> Map.put(:action, "restarted")}

            {:error, :stale_epoch} ->
              {:error, {:conflict, "Server '#{name}' changed while restarting — retry"}}

            {:error, :not_found} ->
              {:error, {:not_found, "Server", name}}

            {:error, _reason} ->
              {:error, {:unavailable, "The server store"}}
          end

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, reason} ->
          Logger.warning("[Emissary.External.Provider] failed to get server: #{inspect(reason)}")
          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  defp handle_list(ctx) do
    case Arca.McpServerStorage.list(Sanctum.Context.actor(ctx)) do
      {:ok, servers} ->
        server_list =
          Enum.map(servers, fn server ->
            # Listing reads; it does not connect. A server that has never
            # been used reports :disconnected here — invocation (and get,
            # which reports the live tool catalogue) starts it on demand.
            status = Emissary.External.Server.status(server.name, ctx.athanor_id)

            %{
              name: server.name,
              transport: server.transport,
              url: server.url,
              enabled: server.enabled,
              status: format_status(status),
              tool_count: format_tool_count(status),
              # The vault entries this server's headers and env draw on, by
              # name only — so an entry can show who consumes it before
              # someone revokes it out from under a server.
              vault_refs: vault_refs(server)
            }
          end)

        {:ok, %{servers: server_list, count: length(server_list)}}

      {:error, reason} ->
        Logger.warning("[Emissary.External.Provider] failed to list servers: #{inspect(reason)}")
        {:error, {:unavailable, "The server store"}}
    end
  end

  defp handle_get(ctx, args) do
    with {:ok, name} <- name_arg(args) do
      case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
        {:ok, server} ->
          # Auto-start enabled servers so status reflects reality
          if server.enabled do
            server_config = Servers.server_config(server, ctx)
            Emissary.External.ServerSupervisor.ensure_started(server_config)
          end

          status = Emissary.External.Server.status(name, ctx.athanor_id)

          tools =
            with %{status: :ready} <- status,
                 {:ok, tools} <- Emissary.External.Server.get_tools(name, ctx.athanor_id) do
              tools
            else
              _ -> []
            end

          {:ok,
           Map.merge(summary(server, %{}), %{
             enabled: server.enabled,
             config: readable_config(server),
             status: format_status(status),
             server_info: format_server_info(status),
             tools: tools,
             backends: backend_status(ctx, server)
           })}

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, reason} ->
          Logger.warning("[Emissary.External.Provider] failed to get server: #{inspect(reason)}")
          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  # What the bridge reports for a stdio server's backends: status, restarts,
  # tool count and a masked stderr tail. Nil for an http server, or when the
  # bridge runs nothing for it.
  defp backend_status(ctx, %{transport: "stdio"} = server) do
    case Emissary.External.Backends.status(ctx.athanor_id, server.id) do
      {:ok, %{"backends" => backends}} -> backends
      _ -> nil
    end
  end

  defp backend_status(_ctx, _server), do: nil

  defp handle_test(ctx, args) do
    with {:ok, name} <- name_arg(args) do
      case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
        {:ok, %{enabled: false}} ->
          {:error, disabled(name)}

        {:ok, server} ->
          server_config = Servers.server_config(server, ctx)

          case Emissary.External.ServerSupervisor.ensure_started(server_config) do
            {:ok, _pid} ->
              case Emissary.External.Server.reinitialize(name, ctx.athanor_id) do
                {:ok, _status} ->
                  status = Emissary.External.Server.status(name, ctx.athanor_id)

                  {:ok,
                   %{
                     name: name,
                     status: format_status(status),
                     tool_count: format_tool_count(status),
                     server_info: format_server_info(status)
                   }}

                {:error, reason} ->
                  {:ok, %{name: name, status: "error", error: error_text(reason)}}
              end

            {:error, reason} ->
              {:ok,
               %{name: name, status: "error", error: "Failed to start: #{error_text(reason)}"}}
          end

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, reason} ->
          Logger.warning("[Emissary.External.Provider] failed to get server: #{inspect(reason)}")
          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  defp handle_refresh(ctx, args) do
    case args["name"] do
      name when is_binary(name) and name != "" -> refresh_one(ctx, name)
      _ -> refresh_all(ctx)
    end
  end

  defp refresh_one(ctx, name) do
    case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
      {:ok, %{enabled: false}} ->
        {:error, disabled(name)}

      {:ok, server} ->
        server_config = Servers.server_config(server, ctx)

        case Emissary.External.ServerSupervisor.ensure_started(server_config) do
          {:ok, _pid} ->
            case Emissary.External.Server.reinitialize(name, ctx.athanor_id) do
              {:ok, _} ->
                Proxy.invalidate_external_tools_cache(ctx)
                {:ok, %{refreshed: [name]}}

              {:error, reason} ->
                {:error, "Failed to refresh #{name}: #{error_text(reason)}"}
            end

          {:error, reason} ->
            {:error, "Failed to start server '#{name}': #{error_text(reason)}"}
        end

      {:error, :not_found} ->
        {:error, {:not_found, "Server", name}}

      {:error, reason} ->
        Logger.warning("[Emissary.External.Provider] failed to get server: #{inspect(reason)}")
        {:error, {:unavailable, "The server store"}}
    end
  end

  # Every enabled server, in parallel with a concurrency limit.
  defp refresh_all(ctx) do
    case Arca.McpServerStorage.list(Sanctum.Context.actor(ctx)) do
      {:ok, servers} ->
        results =
          servers
          |> Enum.filter(& &1.enabled)
          |> Task.async_stream(
            fn server ->
              server_config = Servers.server_config(server, ctx)

              result =
                case Emissary.External.ServerSupervisor.ensure_started(server_config) do
                  {:ok, _pid} ->
                    Emissary.External.Server.reinitialize(server.name, ctx.athanor_id)

                  {:error, reason} ->
                    {:error, reason}
                end

              {server.name, result}
            end,
            max_concurrency: 10,
            timeout: 60_000,
            on_timeout: :kill_task,
            ordered: false
          )
          |> Enum.map(fn
            {:ok, {name, {:ok, _}}} -> {name, :ok}
            {:ok, {name, {:error, reason}}} -> {name, {:error, reason}}
            {:exit, reason} -> {"unknown", {:error, reason}}
          end)

        refreshed = for {name, :ok} <- results, do: name
        # Client-visible, so it says what failed and not what the refusal
        # was carrying — an OAuth refresh reason can quote the material it
        # could not use.
        failed =
          for {name, {:error, r}} <- results do
            Logger.warning(
              "[Emissary.External.Provider] refresh failed for #{name}: #{inspect(r)}"
            )

            %{name: name, error: Grimoire.Error.render(r)}
          end

        if refreshed != [], do: Proxy.invalidate_external_tools_cache(ctx)

        {:ok, %{refreshed: refreshed, failed: failed}}

      {:error, reason} ->
        Logger.warning("[Emissary.External.Provider] failed to list servers: #{inspect(reason)}")
        {:error, {:unavailable, "The server store"}}
    end
  end

  # A disabled server is started by nothing: enabling it is the one way back.
  defp disabled(name),
    do: {:invalid_argument, "Server '#{name}' is disabled — enable it first"}

  defp handle_enable_disable(ctx, args, enabled) do
    action_name = if enabled, do: "enable", else: "disable"

    with {:ok, name} <- name_arg(args) do
      case Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), name, %{enabled: enabled}) do
        {:ok, server} ->
          # The row's epoch moved either way, so a running process no longer
          # matches it; a disabled server is not started again.
          stop_process(ctx, name)
          changed(ctx)

          {:ok,
           %{
             name: server.name,
             enabled: server.enabled,
             epoch: server.epoch,
             action: "#{action_name}d"
           }}

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, reason} ->
          {:error, "Failed to #{action_name} server: #{error_text(reason)}"}
      end
    end
  end

  defp name_arg(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp name_arg(_args), do: {:error, {:invalid_argument, "Missing required parameter: name"}}

  defp stop_process(ctx, name),
    do: Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id)

  defp changed(ctx) do
    Proxy.invalidate_external_tools_cache(ctx)
    broadcast_mcp_servers_changed(ctx)
  end

  # The connection config as `get` shows it: everything except the literal
  # value of a header. `config_json` is not an encrypted column, and create
  # refuses a literal only in a header whose NAME looks like a credential — a
  # denylist that "x-hub" and "x-signature" walk past. Header names and
  # `vault:` binding names are the operator's wiring; literal values are not
  # shown. Backend env values are vault templates or the non-secret literals
  # `Emissary.External.BackendDefinition` allows, and are shown as stored.
  defp readable_config(server) do
    config = Servers.config_map(server)

    case Map.get(config, "headers") do
      %{} = headers -> Map.put(config, "headers", Map.new(headers, &redact_header/1))
      _ -> config
    end
  end

  # A vault template names a vault entry, which is the binding an operator
  # needs to see; anything else is a literal and only its presence is
  # reported.
  defp redact_header({name, value}) do
    if VaultRef.vault_ref?(value), do: {name, value}, else: {name, "[set]"}
  end

  # The vault entry names a server's header and env templates reference.
  defp vault_refs(server) do
    config = Servers.config_map(server)

    headers =
      case config["headers"] do
        %{} = headers -> VaultRef.names(headers)
        _ -> []
      end

    (headers ++ BackendDefinition.entry_names(config["backends"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp format_status(%{status: status}), do: to_string(status)
  defp format_status(:disconnected), do: "disconnected"
  defp format_status(_), do: "unknown"

  defp format_tool_count(%{tool_count: count}), do: count
  defp format_tool_count(_), do: 0

  defp format_server_info(%{server_info: info}), do: info
  defp format_server_info(_), do: nil

  # Publish mcp_servers updates for both console and MCP subscription clients.
  defp broadcast_mcp_servers_changed(ctx) do
    actor = Sanctum.Context.actor(ctx)

    Cyfr.Bus.broadcast(
      actor,
      Cyfr.Bus.mcp_servers(actor),
      Cyfr.Bus.McpServers.new(actor, :changed)
    )
  end
end
