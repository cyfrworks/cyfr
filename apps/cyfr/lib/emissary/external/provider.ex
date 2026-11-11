# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.Provider do
  @moduledoc """
  The `mcp_servers` tool: the operator's external MCP server connections —
  create, update, delete, list, get, test, refresh, enable, disable,
  restart.

  A server has a transport:

    * `http` — a URL and a header map that may name vault entries;
    * `stdio` — a program: backends (`Opus.Programs.Definition`) the
      backends service runs, each a command and an env map whose
      credentials are vault templates, which Emissary drives as MCP
      servers over their sessions;
    * `pipe` — a program with one backend, which a catalyst drives over
      its session, never MCP.

  A program also carries its settings, stored as columns of its row
  (`Opus.Programs.Definition.validate_row/1`): its home (`scratch`, or
  `kept`: one home per login entry that survives retirement), its memory
  bound, a kept home's disk bound, the login command a sign-in runs, the
  hosts it may reach (none named: every public host), and, for a kept
  `stdio` row, the login entry its sessions run in, which must
  be an active login entry of this athanor naming the row
  (`Sanctum.Mount.login_entry/3`). A program is refused when this server
  runs no programs controller (`Opus.Programs`) or runs as a cluster.

  `sign_in` runs a kept program's login command on a pseudo-terminal in a
  login entry's home and answers the token a console attaches to
  (`Opus.Programs.sign_in/3`); `reset_home` empties a login entry's kept
  home under the same uid. Both are a person's acts: interactive, admin.

  Both carry the tool patterns the server is allowed to offer at all. Every
  action but `list` is `permission: :admin`, because it reads or changes
  where this server sends requests, what the backends service runs and
  which stored credential rides along; the listing (names, transport,
  status and the vault entries a server reads) is open to any
  authenticated caller.

  `create` and `update` are also `consent: :interactive`: a definition
  binds vault entries to a command, a URL or headers, and the server
  unseals those entries by name whenever it starts, so defining or changing
  one is a person's act in an interactive session, like `vault.create` and
  `profile.grant`. An admin API key operates saved servers — get, test,
  refresh, restart, enable, disable, delete — and defines none. No action
  is reachable from a running chain.

  `create` and `update` refuse a definition whose header names no active
  vault entry with a destination covering the server's URL, or whose
  backend env names no active disclosed entry, reading the entries'
  metadata and unsealing nothing; the refusal names the header or the
  variable, never the entry. A connect holds the entries to the same
  rules again (`Sanctum.VaultReader.unseal_for/3`, `unseal_disclosed/2`),
  so a row changed underneath sends nothing outside them.

  The servers one athanor may hold is the platform setting
  `max_external_servers_per_athanor` (0 is no ceiling), read at each
  create and handed to `Arca.McpServerStorage.insert/2`, which counts the
  athanor's servers and inserts in one transaction under the athanor's row
  lock.

  Every write raises the row's epoch. `update` names the epoch it read and
  is refused when the row has moved on. A write that changes what runs —
  update, delete, disable, restart — stops the server's process, which
  releases a stdio server's backends on the backends service; the next use
  starts it again at the new epoch.

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

  alias Opus.Programs.Definition, as: BackendDefinition
  alias Emissary.External.Proxy
  alias Emissary.External.Servers
  alias Prima.VaultRef
  alias Sanctum.Context

  @impl true
  def tools, do: [definition()]

  # The one stream MCP `subscriptions/listen` serves: the athanor's
  # servers or their tool lists changed. It carries the change's kind and
  # nothing else, takes no subject, and a grant on it lives no longer than
  # the longest subscription window an operator may set (24 hours).
  @impl true
  def streams do
    [
      %Prima.Provider.Stream{
        name: "mcp_servers.changes",
        topic: :mcp_servers,
        projection: ["kind"],
        deadline_bound: 86_400
      }
    ]
  end

  # The gate casts the arguments against `definition/0` first
  # (`Prima.Operation.cast/2`): the action is one this tool declares,
  # every required argument is present and of its declared type, and an
  # enumerated one, a config's transport among them, holds one of its values.
  @impl true
  def handle("mcp_servers", %Context{} = ctx, %{"action" => action} = args),
    do: dispatch(action, ctx, args)

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
               "The stdio backends, at most #{BackendDefinition.max_backends()}: {name, command, env}. A command never names a vault entry; every env value is 'vault:ENTRY' naming a disclosed entry except NODE_ENV, LOG_LEVEL, TZ, LANG, LC_ALL, NO_COLOR and DEBUG, which may be literals."
           ),
           Arg.new("console", :boolean,
             description:
               "Allow this server's tools to be called from the console (external plane). Default false: proxied tools are reachable only from inside a chain."
           ),
           Arg.new("headers", {:map, Arg.new(nil, :string)},
             description:
               "HTTP headers (http). Use 'vault:ENTRY' or 'Bearer vault:ENTRY' to reference a single-field vault entry whose destination covers this server's URL."
           ),
           Arg.new("timeout_ms", :integer,
             description: "Request timeout in milliseconds (default: 30000)"
           ),
           Arg.new("tool_patterns", {:array, Arg.new(nil, :string)},
             description: "The tools the server may offer (default: all)"
           ),
           Arg.new("transport", :string,
             description:
               "http (default): a URL. stdio: a program whose backends Emissary drives as MCP servers. pipe: a program with one backend a catalyst drives.",
             enum: ["http", "stdio", "pipe"]
           ),
           Arg.new("home", :string,
             description:
               "A program's home: scratch (default), scrubbed at retirement, or kept, one home per login entry that survives it.",
             enum: ["scratch", "kept"]
           ),
           Arg.new("memory_bytes", :integer,
             description:
               "A program's memory bound in bytes (default: the backends service's own bound)."
           ),
           Arg.new("home_max_bytes", :integer,
             description:
               "A kept home's disk bound in bytes (default: none beyond the homes volume)."
           ),
           Arg.new("login_command", :string,
             description:
               "The command a sign-in runs on a pseudo-terminal in a kept home, such as 'claude auth login'."
           ),
           Arg.new("login_entry_id", :string,
             description:
               "A kept stdio server's login entry, whose home its backends run in (a pipe server's catalyst names its own)."
           ),
           Arg.new("hosts", {:array, Arg.new(nil, :string)},
             description:
               "A program's network list: the only hosts it reaches beside the deployment's private hosts, at most 32 exact hostnames (no wildcard, scheme or port), resolved each time it starts. A name sharing an address with another admits that other. Default: every public host."
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
        ),
        Operation.new(
          "mcp_servers",
          "sign_in",
          "Sign in to a program",
          [
            Arg.new("name", :string, required: true, description: "The program's server name"),
            Arg.new("entry", :string,
              required: true,
              description:
                "The id of the login entry whose kept home the sign-in runs in; a kept stdio server's own entry"
            )
          ],
          kind: :execute,
          planes: [:external],
          consent: :interactive,
          permission: :admin
        ),
        Operation.new(
          "mcp_servers",
          "reset_home",
          "Reset a login entry's kept home",
          [
            Arg.new("entry", :string,
              required: true,
              description:
                "The id of the login entry whose kept home is emptied, under the same uid"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :admin
        )
      ],
      description:
        "Manage external MCP server connections and programs: HTTP servers (Notion, GitHub, custom servers), stdio servers the backends service runs (npx packages) and pipe programs catalysts drive. Create, update, delete, enable/disable, restart and test them; sign in to a kept program and reset its home. External server tools appear in tools/list as server_name:tool_name.",
      title: "Programs"
    )
  end

  defp dispatch("create", ctx, args), do: handle_create(ctx, args)
  defp dispatch("update", ctx, args), do: handle_update(ctx, args)
  defp dispatch("delete", ctx, args), do: handle_delete(ctx, args)
  defp dispatch("list", ctx, _args), do: handle_list(ctx)
  defp dispatch("get", ctx, args), do: handle_get(ctx, args)
  defp dispatch("test", ctx, args), do: handle_test(ctx, args)
  defp dispatch("refresh", ctx, args), do: handle_refresh(ctx, args)
  defp dispatch("enable", ctx, args), do: handle_enable_disable(ctx, args, true)
  defp dispatch("disable", ctx, args), do: handle_enable_disable(ctx, args, false)
  defp dispatch("restart", ctx, args), do: handle_restart(ctx, args)
  defp dispatch("sign_in", ctx, args), do: handle_sign_in(ctx, args)
  defp dispatch("reset_home", ctx, args), do: handle_reset_home(ctx, args)

  # ============================================================================
  # Action Handlers
  # ============================================================================

  # The cap is read at the write and counted in the insert's own
  # transaction. A cap the store cannot answer refuses: the setting refuses
  # a stale value, and no fallback number stands in for it.
  defp handle_create(ctx, args) do
    with {:ok, name, attrs} <- server_args(ctx, args),
         {:ok, cap} <- server_cap() do
      attrs = Map.merge(attrs, %{name: name, cap: cap})

      case Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), attrs) do
        {:ok, server} ->
          {:ok, ctx |> connect(server) |> with_warnings(server)}

        {:error, :exists} ->
          {:error, {:conflict, "Server '#{name}' already exists — change it with update"}}

        {:error, :server_cap} ->
          {:error, "Maximum server limit (#{cap}) reached"}

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
    with {:ok, name, attrs} <- server_args(ctx, args),
         {:ok, epoch} <- epoch_arg(args) do
      case Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), name, attrs, epoch) do
        {:ok, %{enabled: true} = server} ->
          stop_process(ctx, name)
          {:ok, ctx |> connect(server) |> with_warnings(server)}

        {:ok, server} ->
          stop_process(ctx, name)
          changed(ctx)
          {:ok, server |> summary(%{status: "disabled"}) |> with_warnings(server)}

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

  defp server_args(ctx, %{"name" => name, "config" => config}) do
    cond do
      name == "" ->
        {:error, {:invalid_argument, "Missing required parameter: name"}}

      String.contains?(name, ":") ->
        {:error,
         {:invalid_argument, "Server name cannot contain ':' (reserved for tool namespacing)"}}

      true ->
        with :ok <- validate_tool_patterns(config["tool_patterns"]),
             {:ok, attrs} <- transport_args(ctx, name, config["transport"] || "http", config) do
          {:ok, name, attrs}
        end
    end
  end

  defp transport_args(ctx, _name, "http", config) do
    cond do
      is_nil(config["url"]) or config["url"] == "" ->
        {:error, {:invalid_argument, "Missing required parameter: config.url"}}

      Map.has_key?(config, "backends") ->
        {:error, {:invalid_argument, "An http server has no backends — use transport stdio"}}

      Enum.any?(BackendDefinition.program_keys(), &Map.has_key?(config, &1)) ->
        {:error,
         {:invalid_argument,
          "An http server is no program: it has no home, bounds, login command or hosts"}}

      true ->
        with :ok <- validate_header_credentials(config["headers"]),
             :ok <- header_destinations(ctx, config["headers"], config["url"]),
             :ok <- validate_create_url(config["url"]) do
          base = %{"headers" => config["headers"] || %{}}

          {:ok,
           Map.merge(no_program(), %{
             transport: "http",
             url: config["url"],
             config_json: stored_config(base, config)
           })}
        end
    end
  end

  defp transport_args(ctx, name, transport, config) when transport in ["stdio", "pipe"] do
    cond do
      Map.has_key?(config, "url") ->
        {:error,
         {:invalid_argument,
          "A #{transport} server has no url — its backends run on the backends service"}}

      Map.has_key?(config, "headers") ->
        {:error, {:invalid_argument, "A #{transport} server has no headers — use backend env"}}

      true ->
        with :ok <- stdio_available(),
             {:ok, backends} <- BackendDefinition.validate(config["backends"]),
             :ok <- env_disclosures(ctx, backends),
             {:ok, columns} <-
               BackendDefinition.validate_row(Map.put(config, "transport", transport)),
             :ok <- login_entry(ctx, name, columns.login_entry_id) do
          base = %{"backends" => backends}

          {:ok,
           Map.merge(columns, %{
             transport: transport,
             url: nil,
             config_json: stored_config(base, config)
           })}
        end
    end
  end

  defp transport_args(_ctx, _name, transport, _config),
    do: {:error, {:invalid_argument, "Unknown transport #{inspect(transport)}"}}

  # The program columns an http row carries: none, so an update to http
  # clears what a program row held.
  defp no_program,
    do: %{
      home: "scratch",
      memory_bytes: nil,
      home_max_bytes: nil,
      login_command: nil,
      login_entry_id: nil,
      hosts: nil
    }

  # A kept stdio row names its login entry, which must be a login entry of
  # this athanor naming the row, active or its program not signed in yet:
  # the row is how its program signs in. The refusal names neither the
  # entry's material nor why beyond that.
  defp login_entry(_ctx, _name, nil), do: :ok

  defp login_entry(ctx, name, entry) do
    case Sanctum.Mount.login_entry(ctx, entry, name, for: :sign_in) do
      {:ok, _entry} ->
        :ok

      {:error, _reason} ->
        {:error,
         {:invalid_argument,
          "config.login_entry_id names no login entry of this athanor for program '#{name}'"}}
    end
  end

  defp stdio_available do
    cond do
      Application.get_env(:cyfr, :cluster, false) == true ->
        {:error, {:invalid_argument, "programs are not available while CYFR_CLUSTER is on"}}

      not Opus.Programs.running?() ->
        {:error,
         {:invalid_argument,
          "No backends service is configured — set CYFR_LOCUS_BACKENDS_URL and " <>
            "CYFR_LOCUS_BACKENDS_KEY to run programs"}}

      true ->
        :ok
    end
  end

  defp server_cap do
    case Arca.PlatformSettings.effective("max_external_servers_per_athanor") do
      {:ok, cap} when is_integer(cap) and cap >= 0 -> {:ok, cap}
      {:error, :unavailable} -> {:error, {:unavailable, "The server store"}}
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

  # A header's entry goes to this server's URL on every connect, so the
  # definition is refused unless the entry's destination covers it
  # (`Sanctum.Vault.destination_matches?/3`, metadata only). A missing or
  # inactive entry is refused alike, and the refusal names the header,
  # never the entry.
  defp header_destinations(ctx, headers, url) when is_map(headers) do
    Enum.find_value(headers, :ok, fn {key, value} ->
      with {:vault, %{name: entry}} <- VaultRef.classify(value),
           false <- is_binary(url) and Sanctum.Vault.destination_matches?(ctx, entry, url) do
        {:error,
         {:invalid_argument,
          "Header '#{key}' names no active vault entry whose destination covers " <>
            "this server's URL"}}
      else
        _literal_or_covered -> nil
      end
    end)
  end

  defp header_destinations(_ctx, _headers, _url), do: :ok

  # A backend's environment hands its values to the process it starts, so
  # an env template names only a disclosed entry
  # (`Sanctum.Vault.disclosed?/2`, metadata only). A missing or inactive
  # entry is refused alike, and the refusal names the backend and the
  # variable, never the entry.
  defp env_disclosures(ctx, backends) do
    Enum.find_value(backends, :ok, fn %{"name" => backend, "env" => env} ->
      Enum.find_value(env, fn {var, value} ->
        with {:vault, %{name: entry}} <- VaultRef.classify(value),
             false <- Sanctum.Vault.disclosed?(ctx, entry) do
          {:error,
           {:invalid_argument,
            "Backend '#{backend}' env #{var} names no active disclosed vault entry; " <>
              "a backend's environment takes only a disclosed entry"}}
        else
          _literal_or_disclosed -> nil
        end
      end)
    end)
  end

  defp credential_shaped_header_name?(key) do
    k = key |> to_string() |> String.downcase()

    Prima.Network.credential_header?(k) or String.contains?(k, "token") or
      String.contains?(k, "secret") or
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
  defp connect(ctx, %{transport: "pipe"} = server) do
    changed(ctx)
    summary(server, %{status: "ready"})
  end

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

  # What the stored definition does that its administrator chose and is
  # told of (`Opus.Programs.Definition.warnings/1`): the answer
  # to a create or update and `get` carry it, empty when there is none.
  defp with_warnings(result, server), do: Map.put(result, :warnings, warnings(server))

  defp warnings(%{transport: transport} = server) when transport in ["stdio", "pipe"],
    do: BackendDefinition.warnings(Arca.McpServerStorage.config(server)["backends"])

  defp warnings(_server), do: []

  defp summary(server, extra) do
    Map.merge(
      %{
        id: server.id,
        name: server.name,
        transport: server.transport,
        url: server.url,
        home: server.home,
        epoch: server.epoch
      },
      extra
    )
  end

  # What the programs controller refused, in the refusal vocabulary: its
  # own refusal as it is, anything else as the act being unavailable, with
  # the reason's shape in the log and never its value.
  defp programs_refusal(reason, act) do
    if Sanctum.Refusals.known?(reason) do
      reason
    else
      Prima.LoggerContext.unexpected(__MODULE__, reason)
      {:unavailable, act}
    end
  end

  # A server's own sentence as it wrote it; any other reason as the
  # table's sentence — a start failure can carry the row's configuration,
  # and a term is never spelled back.
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: Sanctum.Refusals.render(reason)

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
        {:ok, %{transport: "http"}} ->
          {:error, {:invalid_argument, "Only a program restarts — '#{name}' is http"}}

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

            {:error, :not_owner} = refused ->
              refused

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

  # A sign-in runs a kept program's login command in a login entry's home:
  # a pipe row's any login entry naming it, a kept stdio row's own entry.
  defp handle_sign_in(ctx, args) do
    with {:ok, name} <- name_arg(args),
         {:ok, entry} <- entry_arg(args),
         {:ok, server} <- program_row(ctx, name),
         :ok <- signs_in(server),
         {:ok, %{id: entry_id}} <- sign_in_entry(ctx, server, entry) do
      case Opus.Programs.sign_in(ctx, server, entry_id) do
        {:ok, token} -> {:ok, %{session: token, program: name, entry: entry_id}}
        {:error, reason} -> {:error, programs_refusal(reason, "Sign-in to #{name}")}
      end
    end
  end

  # Every session in the home ends and it is made again empty, under the
  # same uid.
  defp handle_reset_home(ctx, args) do
    with {:ok, entry} <- entry_arg(args) do
      case Sanctum.Mount.home_of(ctx.athanor_id, entry) do
        {:ok, home_id} ->
          case Opus.Programs.home(ctx.athanor_id, home_id, :reset) do
            :ok -> {:ok, %{reset: entry}}
            {:error, reason} -> {:error, programs_refusal(reason, "The folder reset")}
          end

        :none ->
          {:error, {:not_found, "Login entry", entry}}

        {:error, _reason} ->
          {:error, {:unavailable, "The vault"}}
      end
    end
  end

  defp entry_arg(%{"entry" => entry}) when is_binary(entry) and entry != "", do: {:ok, entry}
  defp entry_arg(_args), do: {:error, {:invalid_argument, "Missing required parameter: entry"}}

  defp program_row(ctx, name) do
    case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
      {:ok, server} -> {:ok, server}
      {:error, :not_found} -> {:error, {:not_found, "Server", name}}
      {:error, _reason} -> {:error, {:unavailable, "The server store"}}
    end
  end

  defp signs_in(%{enabled: false, name: name}), do: {:error, disabled(name)}

  defp signs_in(%{transport: transport, home: "kept", login_command: command})
       when transport in ["stdio", "pipe"] and is_binary(command),
       do: :ok

  defp signs_in(%{name: name}),
    do:
      {:error,
       {:invalid_argument,
        "'#{name}' has no sign-in: a program with a kept home and a login command signs in"}}

  defp sign_in_entry(ctx, server, entry) do
    # A sign-in is how an entry whose program is not signed in (needs_reauth:
    # a new entry, or one a restore left) becomes active, so it is admitted
    # here; a row may name one (`login_entry/3`), and nothing else does.
    case Sanctum.Mount.login_entry(ctx, entry, server.name, for: :sign_in) do
      {:ok, %{id: id}} = found when server.transport == "pipe" or id == server.login_entry_id ->
        found

      {:ok, _other} ->
        {:error,
         {:invalid_argument, "A kept stdio server signs in with its own login entry only"}}

      {:error, _reason} ->
        {:error,
         {:invalid_argument,
          "'#{entry}' is no active login entry of this athanor for program '#{server.name}'"}}
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
              home: server.home,
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
             programs: program_status(ctx, server),
             warnings: warnings(server)
           })}

        {:error, :not_found} ->
          {:error, {:not_found, "Server", name}}

        {:error, reason} ->
          Logger.warning("[Emissary.External.Provider] failed to get server: #{inspect(reason)}")
          {:error, {:unavailable, "The server store"}}
      end
    end
  end

  # What the backends service reports for a program's backends: status,
  # restarts, the last crash, a scratch program's masked stderr tail or a
  # kept one's stderr length alone (a kept home's contents are the
  # person's), its home, the bytes its kept homes hold, whether one is over
  # its cap and its running sessions.
  # Nil for an http server, or when the service runs nothing for it.
  defp program_status(ctx, %{transport: transport} = server)
       when transport in ["stdio", "pipe"] do
    case Opus.Programs.status(ctx.athanor_id, server.id) do
      {:ok, %{"programs" => programs}} -> programs
      _ -> nil
    end
  end

  defp program_status(_ctx, _server), do: nil

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

            %{name: name, error: Sanctum.Refusals.render(r)}
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
  # `Opus.Programs.Definition` allows, and are shown as stored.
  defp readable_config(server) do
    config =
      server
      |> Arca.McpServerStorage.config()
      |> Map.put("transport", server.transport)
      |> with_program(server)

    case Map.get(config, "headers") do
      %{} = headers -> Map.put(config, "headers", Map.new(headers, &redact_header/1))
      _ -> config
    end
  end

  # A program's settings, stored as columns, shown in its config as given.
  defp with_program(config, server), do: Map.merge(config, BackendDefinition.settings(server))

  # A vault template names a vault entry, which is the binding an operator
  # needs to see; anything else is a literal and only its presence is
  # reported.
  defp redact_header({name, value}) do
    if VaultRef.vault_ref?(value), do: {name, value}, else: {name, "[set]"}
  end

  # The vault entry names a server's header and env templates reference.
  defp vault_refs(server) do
    config = Arca.McpServerStorage.config(server)

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
