# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.Provider do
  @moduledoc """
  The `mcp_servers` tool: the operator's external MCP server connections —
  create, update, delete, list, get, test, refresh, enable, disable,
  restart.

  A row is one of two kinds, named by its transport:

    * `http` — a tool server elsewhere: a URL and a header map that may
      name vault entries;
    * `program` — a program CYFR runs: one command and an env map whose
      credentials are vault templates (`Opus.Programs.Definition`), which
      the backends service runs. Its mark says how it is spoken to: `mcp`,
      Emissary speaking MCP over its session and offering its tools, or
      `driven`, a program a person or a brain runs, never MCP.

  A program also carries its settings, stored as columns of its row
  (`Opus.Programs.Definition.validate_row/1`): its mark, its home
  (`scratch`, or `kept`: the row's own folder, which survives its
  sessions and is retired with the row), its memory bound, a kept home's
  disk bound, the login command a sign-in runs and the hosts it may reach
  (none named: every public host). A program is refused when this server
  runs no programs controller (`Opus.Programs`) or runs as a cluster.

  `sign_in` runs a kept program's login command on a pseudo-terminal in
  the row's home and answers the token a console attaches to
  (`Opus.Programs.sign_in/2`); `reset_home` empties a kept program's home
  under the same uid. Both are a person's acts: interactive, admin.

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

  A program's definition is also a sensitive change (`program_definition`
  in `Sanctum.Pairing`'s table), confirmed by the person whatever surface
  asks: adding a program, an update that lets it reach more than the
  stored row (a new host, a new or changed vault binding, a larger memory
  or disk bound, another command, sign-in command, mark or kind of
  folder), and its removal, which names the grants that use it and will
  ask again. The confirmation shows and binds the whole definition
  (`definition_change/4`), so one given for `TOKEN=vault:personal` does
  not admit `TOKEN=vault:work`. An update that only narrows asks nothing,
  and a tool server elsewhere asks none.

  `create` and `update` refuse a definition whose header names no active
  vault entry with a destination covering the server's URL, or whose
  env names no active disclosed entry, reading the entries'
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
  releases a program on the backends service; the next use starts it
  again at the new epoch. A deleted program's sessions end and its kept
  home is retired (`Emissary.External.Reconciler.row_deleted/2`).

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

  alias Emissary.External.Proxy
  alias Emissary.External.Servers
  alias Opus.Programs.Definition
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
           Arg.new("command", :string,
             description:
               "A program's command, run by a shell on the backends service. It never names a vault entry."
           ),
           Arg.new("env", {:map, Arg.new(nil, :string)},
             description:
               "A program's environment. Every value is 'vault:ENTRY' naming a disclosed entry except NODE_ENV, LOG_LEVEL, TZ, LANG, LC_ALL, NO_COLOR and DEBUG, which may be literals."
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
               "http (default): a tool server elsewhere, at a URL. program: a program CYFR runs on the backends service.",
             enum: ["http", "program"]
           ),
           Arg.new("mark", :string,
             description:
               "How a program is spoken to: mcp, CYFR speaks MCP to it and offers its tools; driven, a person or a brain runs it.",
             enum: ["mcp", "driven"]
           ),
           Arg.new("home", :string,
             description:
               "A program's home: scratch (default), scrubbed at retirement, or kept, the program's own folder, kept until the program is deleted.",
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
            ),
            Arg.new("keep_headers", {:array, Arg.new(nil, :string)},
              description:
                "Headers of a tool server that keep the value stored at that epoch, which get shows as [set] and never answers; a name kept is not also given in config.headers"
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
            Arg.new("name", :string,
              required: true,
              description: "The program's server name; the sign-in runs in its kept home"
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
          "Reset a program's kept home",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "The program's server name; its kept home is emptied, under the same uid"
            )
          ],
          kind: :destructive,
          planes: [:external],
          consent: :interactive,
          permission: :admin
        )
      ],
      description:
        "Manage programs and tool servers: tool servers elsewhere over HTTP (Notion, GitHub, custom servers) and programs CYFR runs on the backends service (npx packages), each marked mcp (CYFR offers its tools) or driven (a person or a brain runs it). Create, update, delete, enable/disable, restart and test them; sign in to a kept program and reset its home. A tool server's and an mcp program's tools appear in tools/list as server_name:tool_name.",
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
         {:ok, cap} <- server_cap(),
         :ok <- confirm_definition(ctx, "mcp_servers.create", name, nil, attrs) do
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
  # whether the server is enabled is kept. A header named in
  # `keep_headers` takes the value the row stores at that epoch, so a
  # literal the caller was never shown survives the replacement; the
  # update's own epoch check refuses it should the row move meanwhile.
  defp handle_update(ctx, args) do
    with {:ok, epoch} <- epoch_arg(args),
         {:ok, args} <- kept_headers(ctx, args, epoch),
         {:ok, name, attrs} <- server_args(ctx, args),
         {:ok, stored} <- stored_at(ctx, name, epoch),
         :ok <- confirm_definition(ctx, "mcp_servers.update", name, stored, attrs) do
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

  defp kept_headers(_ctx, %{"keep_headers" => []} = args, _epoch), do: {:ok, args}

  defp kept_headers(ctx, %{"keep_headers" => names, "name" => name} = args, epoch)
       when is_list(names) and is_binary(name) do
    config = args["config"] || %{}
    given = Map.get(config, "headers") || %{}

    with {:ok, %{transport: "http", epoch: ^epoch} = server} <- stored_for_keep(ctx, name),
         stored = Arca.McpServerStorage.config(server)["headers"] || %{},
         :ok <- keepable(names, stored, given) do
      kept = Map.take(stored, names)
      {:ok, put_in(args, ["config", "headers"], Map.merge(given, kept))}
    else
      {:ok, %{transport: "http"}} ->
        {:error,
         {:conflict,
          "Server '#{name}' changed since epoch #{epoch} — read it again with get and retry"}}

      {:ok, _program} ->
        {:error, {:invalid_argument, "Only a tool server's headers are kept: a program has none"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp kept_headers(_ctx, args, _epoch), do: {:ok, args}

  # The row an update replaces, at the epoch the caller read: what its
  # confirmation is decided against.
  defp stored_at(ctx, name, epoch) do
    case stored_for_keep(ctx, name) do
      {:ok, %{epoch: ^epoch} = stored} ->
        {:ok, stored}

      {:ok, _moved} ->
        {:error,
         {:conflict,
          "Server '#{name}' changed since epoch #{epoch} — read it again with get and retry"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp stored_for_keep(ctx, name) do
    case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
      {:ok, server} -> {:ok, server}
      {:error, :not_found} -> {:error, {:not_found, "Server", name}}
      {:error, _reason} -> {:error, {:unavailable, "The server store"}}
    end
  end

  # A kept header is one the row stores, and not one the caller also sets.
  defp keepable(names, stored, given) do
    cond do
      (missing = Enum.reject(names, &Map.has_key?(stored, &1))) != [] ->
        {:error,
         {:invalid_argument,
          "keep_headers names a header this server does not store: #{Enum.join(missing, ", ")}"}}

      (both = Enum.filter(names, &Map.has_key?(given, &1))) != [] ->
        {:error,
         {:invalid_argument, "A header is kept or given, not both: #{Enum.join(both, ", ")}"}}

      true ->
        :ok
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
             {:ok, attrs} <- transport_args(ctx, config["transport"] || "http", config) do
          {:ok, name, attrs}
        end
    end
  end

  defp transport_args(ctx, "http", config) do
    cond do
      is_nil(config["url"]) or config["url"] == "" ->
        {:error, {:invalid_argument, "Missing required parameter: config.url"}}

      Map.has_key?(config, "command") or Map.has_key?(config, "env") ->
        {:error,
         {:invalid_argument, "An http server has no command or env — use transport program"}}

      Enum.any?(Definition.program_keys(), &Map.has_key?(config, &1)) ->
        {:error,
         {:invalid_argument,
          "An http server is no program: it has no mark, home, bounds, login command or hosts"}}

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

  defp transport_args(ctx, "program", config) do
    cond do
      Map.has_key?(config, "url") ->
        {:error, {:invalid_argument, "A program has no url — it runs on the backends service"}}

      Map.has_key?(config, "headers") ->
        {:error, {:invalid_argument, "A program has no headers — use env"}}

      true ->
        with :ok <- programs_available(),
             {:ok, definition} <- Definition.validate(config),
             :ok <- env_disclosures(ctx, definition),
             {:ok, columns} <- Definition.validate_row(config) do
          base = definition

          {:ok,
           Map.merge(columns, %{
             transport: "program",
             url: nil,
             config_json: stored_config(base, config)
           })}
        end
    end
  end

  defp transport_args(_ctx, transport, _config),
    do: {:error, {:invalid_argument, "Unknown transport #{inspect(transport)}"}}

  # The program columns an http row carries: none, so an update to http
  # clears what a program row held.
  defp no_program,
    do: %{
      mark: nil,
      home: "scratch",
      memory_bytes: nil,
      home_max_bytes: nil,
      login_command: nil,
      hosts: nil
    }

  defp programs_available do
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

  # A program's environment hands its values to the process it starts, so
  # an env template names only a disclosed entry
  # (`Sanctum.Vault.disclosed?/2`, metadata only). A missing or inactive
  # entry is refused alike, and the refusal names the variable, never the
  # entry.
  defp env_disclosures(ctx, %{"env" => env}) do
    Enum.find_value(env, :ok, fn {var, value} ->
      with {:vault, %{name: entry}} <- VaultRef.classify(value),
           false <- Sanctum.Vault.disclosed?(ctx, entry) do
        {:error,
         {:invalid_argument,
          "config.env #{var} names no active disclosed vault entry; " <>
            "a program's environment takes only a disclosed entry"}}
      else
        _literal_or_disclosed -> nil
      end
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
  defp connect(ctx, %{mark: "driven"} = server) do
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

  defp warnings(%{transport: "program"} = server),
    do: Definition.warnings(Arca.McpServerStorage.config(server))

  defp warnings(_server), do: []

  defp summary(server, extra) do
    Map.merge(
      %{
        id: server.id,
        name: server.name,
        transport: server.transport,
        mark: server.mark,
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
    with {:ok, name} <- name_arg(args),
         {:ok, stored} <- program_row(ctx, name),
         :ok <- confirm_removal(ctx, name, stored) do
      case Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), name) do
        {:ok, server} ->
          stop_process(ctx, name)
          Emissary.External.Reconciler.row_deleted(ctx.athanor_id, server)
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

  # ============================================================================
  # A program's definition, confirmed
  # ============================================================================

  # A program row's definition is a sensitive change (`program_definition`,
  # `Sanctum.Pairing`): adding one, from Add program, an install block or
  # the command line; an update that lets the stored row reach more
  # (`widens?/2`); and its removal. A tool server elsewhere asks none, and
  # neither does an update that only narrows what a program reaches.
  defp confirm_definition(ctx, operation, name, stored, %{transport: "program"} = attrs) do
    if is_nil(stored) or widens?(stored, attrs) do
      row = Map.merge(%{id: folder_id(stored), enabled: enabled?(stored)}, attrs)
      confirmed(ctx, definition_change(operation, name, row, nil))
    else
      :ok
    end
  end

  defp confirm_definition(_ctx, _operation, _name, _stored, _attrs), do: :ok

  defp folder_id(nil), do: "new"
  defp folder_id(%{id: id}), do: id

  defp enabled?(nil), do: true
  defp enabled?(%{enabled: enabled}), do: enabled == true

  # A removal names the grants it asks again (`Sanctum.Mount.granted_to/2`)
  # before it is given: they are part of what is confirmed.
  defp confirm_removal(ctx, name, %{transport: "program"} = stored) do
    case Sanctum.Mount.granted_to(ctx.athanor_id, stored.id) do
      {:ok, grants} ->
        confirmed(ctx, definition_change("mcp_servers.delete", name, stored, grants))

      {:error, :unavailable} ->
        {:error, {:unavailable, "The grants that use '#{name}'"}}
    end
  end

  defp confirm_removal(_ctx, _name, _stored), do: :ok

  defp confirmed(ctx, {:ok, change}) do
    case Sanctum.Consent.confirm_program_definition(ctx, change) do
      {:error, :invalid_request} -> {:error, unshowable()}
      decided -> decided
    end
  end

  defp confirmed(_ctx, {:error, _unrecorded}), do: {:error, unshowable()}

  defp unshowable,
    do:
      {:invalid_argument,
       "This program cannot be shown in full in its confirmation, so it is not asked: " <>
         "its command at most #{Prima.Confirmation.Preview.max_text()} bytes and at most " <>
         "64 environment variables."}

  @doc """
  The `program_definition` change `operation` (`mcp_servers.create`,
  `update` or `delete`) makes to the program row `row` named `name`, as
  `Sanctum.Consent.confirm_program_definition/2` takes it: what the confirmation shows
  and what it binds, from one definition.

  The row is a stored row, or the row an add or update would store (its
  `id` the stored row's, `"new"` for an add). What is shown is its record
  (`Sanctum.ToolServerDigest.recorded/1`): the command, and each
  environment variable by its name with the vault entry it names
  (`TOKEN=vault:personal`), a literal by its name alone, and its
  settings: the folder (a kept program's is the row's own, `"new"` until
  it is made; a scratch program's is `"scratch"`), the hosts, the memory
  and disk bounds and the sign-in command; and beside it the mark. A removal also names
  `grants`, the components whose grant binds the row and asks again
  (`Sanctum.Mount.granted_to/2`). The arguments are the same definition
  with the row's stored config beside it, so a literal's value is bound
  without being shown. `{:error, _}` for a row that is no program or
  whose record does not read.
  """
  @spec definition_change(String.t(), String.t(), map(), [String.t()] | nil) ::
          {:ok, map()} | {:error, term()}
  def definition_change(operation, name, row, grants) do
    with {:ok, record} <- Sanctum.ToolServerDigest.recorded(row) do
      kept? = record["folder"] == "kept"

      shown =
        %{
          "command" => record["address"],
          "environment" => environment(record["env"]),
          "mark" => row.mark,
          "folder" => if(kept?, do: row.id, else: "scratch"),
          "hosts" => record["hosts"] || "every public host",
          "memory_bytes" => bound(record["memory_bytes"], "the backends service's bound"),
          "home_max_bytes" =>
            if(kept?,
              do: bound(record["home_max_bytes"], "the folders' volume"),
              else: "scratch folder"
            )
        }
        |> put_present("sign_in_command", record["sign_in_command"])
        |> put_present("grants_asking_again", if(grants == [], do: "none", else: grants))

      {:ok,
       %{
         operation: operation,
         arguments: Map.merge(shown, %{"name" => name, "config" => row.config_json}),
         resource: name,
         details: shown
       }}
    end
  end

  defp environment([]), do: "none"

  defp environment(variables) do
    Enum.map(variables, fn
      %{"name" => name, "entry" => entry} = variable ->
        "#{name}=#{scheme(variable)}vault:#{entry}"

      %{"name" => name} ->
        "#{name} (a literal, not shown)"
    end)
  end

  defp scheme(%{"scheme" => scheme}), do: scheme <> " "
  defp scheme(_variable), do: ""

  defp bound(bytes, _absent) when is_integer(bytes), do: Integer.to_string(bytes)
  defp bound(nil, absent), do: absent

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Whether `attrs`, a program's definition, reaches more than the stored
  # row: a tool server made a program; another command, sign-in command,
  # mark or kind of folder; a host the stored list does not hold, or no
  # list where one stood; a larger memory or disk bound, or none where one
  # stood; an environment variable bound to a vault entry, or to another
  # entry, that it was not. Removing a binding, a host or raising nothing
  # is no widening.
  defp widens?(%{transport: "program"} = stored, attrs) do
    old = Arca.McpServerStorage.config(stored)
    new = Jason.decode!(attrs.config_json)

    stored.mark != attrs.mark or old["command"] != new["command"] or
      stored.login_command != attrs.login_command or stored.home != attrs.home or
      larger?(stored.memory_bytes, attrs.memory_bytes) or
      larger?(stored.home_max_bytes, attrs.home_max_bytes) or
      more_hosts?(Definition.settings(stored)["hosts"], Definition.settings(attrs)["hosts"]) or
      new_binding?(old["env"] || %{}, new["env"] || %{})
  end

  defp widens?(_tool_server, _attrs), do: true

  # No bound is the largest.
  defp larger?(nil, _new), do: false
  defp larger?(old, new) when is_integer(old) and is_integer(new), do: new > old
  defp larger?(_old, _new), do: true

  # No list is every public host; a stored list that does not read is
  # read as reaching nothing, so any new list asks.
  defp more_hosts?(nil, _new), do: false

  defp more_hosts?(old, new) when is_list(old) and is_list(new),
    do: not MapSet.subset?(MapSet.new(new), MapSet.new(old))

  defp more_hosts?(_old, _new), do: true

  defp new_binding?(old, new),
    do: Enum.any?(new, fn {var, value} -> VaultRef.vault_ref?(value) and old[var] != value end)

  # A program is released and started again at a new epoch.
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

  # A sign-in runs a kept program's login command in the row's own home.
  defp handle_sign_in(ctx, args) do
    with {:ok, name} <- name_arg(args),
         {:ok, server} <- program_row(ctx, name),
         :ok <- signs_in(server) do
      case Opus.Programs.sign_in(ctx, server) do
        {:ok, token} -> {:ok, %{session: token, program: name}}
        {:error, reason} -> {:error, programs_refusal(reason, "Sign-in to #{name}")}
      end
    end
  end

  # Every session in the row's home ends and it is made again empty, under
  # the same uid.
  defp handle_reset_home(ctx, args) do
    with {:ok, name} <- name_arg(args),
         {:ok, server} <- program_row(ctx, name),
         :ok <- kept(server) do
      case Opus.Programs.home(ctx.athanor_id, server.id, :reset) do
        :ok -> {:ok, %{reset: name}}
        {:error, reason} -> {:error, programs_refusal(reason, "The folder reset")}
      end
    end
  end

  defp program_row(ctx, name) do
    case Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), name) do
      {:ok, server} -> {:ok, server}
      {:error, :not_found} -> {:error, {:not_found, "Server", name}}
      {:error, _reason} -> {:error, {:unavailable, "The server store"}}
    end
  end

  defp signs_in(%{enabled: false, name: name}), do: {:error, disabled(name)}

  defp signs_in(%{transport: "program", home: "kept", login_command: command})
       when is_binary(command),
       do: :ok

  defp signs_in(%{name: name}),
    do:
      {:error,
       {:invalid_argument,
        "'#{name}' has no sign-in: a program with a kept home and a login command signs in"}}

  defp kept(%{transport: "program", home: "kept"}), do: :ok

  defp kept(%{name: name}),
    do: {:error, {:invalid_argument, "'#{name}' keeps no home: only a kept program's resets"}}

  defp handle_list(ctx) do
    case Arca.McpServerStorage.list(Sanctum.Context.actor(ctx)) do
      {:ok, servers} ->
        server_list =
          Enum.map(servers, fn server ->
            # Listing reads; it does not connect. A server that has never
            # been used reports :disconnected here — invocation (and get,
            # which reports the live tool catalogue) starts it on demand.
            status = live_status(server, ctx)

            %{
              name: server.name,
              transport: server.transport,
              mark: server.mark,
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

          status = live_status(server, ctx)

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

  # What the backends service reports for a program: status,
  # restarts, the last crash, a scratch program's masked stderr tail or a
  # kept one's stderr length alone (a kept home's contents are the
  # person's), its home, the bytes its kept homes hold, whether one is over
  # its cap and its running sessions.
  # Nil for an http server, a disabled program, which nothing runs (the
  # box's fence refuses it), or when the service runs nothing for it.
  defp program_status(_ctx, %{enabled: false}), do: nil

  defp program_status(ctx, %{transport: "program"} = server) do
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
  # shown. A program's env values are vault templates or the non-secret literals
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
  defp with_program(config, server), do: Map.merge(config, Definition.settings(server))

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

    (headers ++ Definition.entry_names(config))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A disabled row is stopped whatever a process stopping for it last
  # said: nothing starts it again until it is enabled.
  defp live_status(%{enabled: false}, _ctx), do: :stopped
  defp live_status(server, ctx), do: Emissary.External.Server.status(server.name, ctx.athanor_id)

  defp format_status(:stopped), do: "stopped"
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
