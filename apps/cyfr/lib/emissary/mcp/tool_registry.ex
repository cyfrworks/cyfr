# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolRegistry do
  @moduledoc """
  Cache-backed registry for MCP tools.

  At startup, discovers all configured tool providers and caches
  them via Arca.Cache for O(1) tool lookup. This follows the OTP pattern of
  "configure in config, initialize in Application".

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │  Emissary.MCP.ToolRegistry (GenServer)                          │
  │  ├── Arca.Cache keys: {:mcp_tool, name}                         │
  │  │   └── {:mcp_tool, "retention"} => {Emissary.MCP.Tools.RecordsProvider, %{desc, ...}}   │
  │  │   └── {:mcp_tool, "execution"} => {Opus.MCP, %{...}}        │
  │  └── Providers: [Emissary.MCP.Tools.RecordsProvider, Opus.MCP, ...]                       │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Usage

      # List all tools
      ToolRegistry.list_tools()

      # Call a tool
      ToolRegistry.call_external("retention", context, %{"action" => "get"})

  ## Future: Distributed

  When running multiple workers, this registry will be extended to
  track node availability and route using :pg or Horde.
  """

  use GenServer
  require Logger

  alias Sanctum.Context

  # 24 hours
  @cache_ttl :timer.hours(24)
  # Refresh 1 hour before TTL expires to prevent cache misses
  @refresh_interval :timer.hours(23)
  # Default tool execution timeout (5 minutes)
  @tool_timeout_ms :timer.minutes(5)

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all registered tools.

  Returns a list of tool definitions suitable for MCP tools/list response.
  """
  def list_tools do
    Arca.Cache.match({:mcp_tool, :_})
    |> Enum.map(fn {_key, {_module, meta}} ->
      name = meta.name

      %{
        "name" => name,
        "description" => meta.description,
        "inputSchema" => meta.input_schema
      }
      |> maybe_put("title", meta[:title])
      |> maybe_put("icons", meta[:icons])
      |> maybe_put("outputSchema", meta[:output_schema])
      |> maybe_put("annotations", meta[:annotations])
    end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Prune a tools/list payload to what a component running in a chain can
  reach: actions whose plane annotation includes `:in_chain`. Proxied
  `server:tool` entries are in-chain by wiring and pass through whole;
  anything without an annotation fails closed, mirroring `call_in_chain/5`.
  This is a discovery view — per-call enforcement stays with the chain
  authority's transition relation.
  """
  def in_chain_view(tool_defs) when is_list(tool_defs) do
    tool_defs
    |> Enum.map(&prune_to_in_chain/1)
    |> Enum.reject(&is_nil/1)
  end

  defp prune_to_in_chain(%{"name" => name} = tool_def) do
    if String.contains?(name, ":") do
      tool_def
    else
      actions = get_in(tool_def, ["annotations", :actions]) || %{}

      reachable =
        for {action, %{planes: planes}} <- actions, :in_chain in planes, do: action

      case {reachable, get_in(tool_def, ["inputSchema", "properties", "action", "enum"])} do
        {[], _} ->
          nil

        {_, listed} when is_list(listed) ->
          case Enum.filter(listed, &(&1 in reachable)) do
            [] -> nil
            ^listed -> tool_def
            pruned -> put_in(tool_def, ["inputSchema", "properties", "action", "enum"], pruned)
          end

        {_, _} ->
          tool_def
      end
    end
  end

  defp prune_to_in_chain(_tool_def), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Get a specific tool's definition.

  Returns `{:ok, tool_def}` or `{:error, :not_found}`.
  """
  def get_tool(name) do
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {_module, meta}} ->
        tool_def =
          %{
            "name" => name,
            "description" => meta.description,
            "inputSchema" => meta.input_schema
          }
          |> maybe_put("title", meta[:title])
          |> maybe_put("icons", meta[:icons])
          |> maybe_put("outputSchema", meta[:output_schema])
          |> maybe_put("annotations", meta[:annotations])

        {:ok, tool_def}

      :miss ->
        {:error, :not_found}
    end
  end

  @doc """
  Call a tool from the **external plane** — an ingress outside any running
  component: the HTTP MCP surface, console LiveViews, the CLI.

  A context that has entered a guest closure is rejected here regardless of
  its permissions: whichever entry it reaches, a guest-planed context can
  never authorize an external-plane call. In-chain callers use
  `call_in_chain/5`; there is deliberately no plane-ambiguous entry point —
  a new call site must choose, at compile time.

  The work runs in a task registered under `ctx.request_id`, so a transport
  whose caller disconnects can stop it (`Emissary.MCP.RunningTasks`).
  """
  def call_external(name, ctx, args, opts \\ [])

  def call_external(name, %Context{plane: :guest}, _args, _opts) do
    {:error, "Unauthorized: guest-plane context cannot make external-plane call to '#{name}'"}
  end

  def call_external(name, %Context{} = ctx, args, opts) when is_map(args) do
    do_call(name, ctx, args, opts)
  end

  @doc """
  Call a tool from **inside a running chain** — the only entry that accepts
  an authority.

  Authorization is a conjunction, in order: the action must be annotated
  in-chain-reachable; the chain's authority must grant the tool (or the
  matching tool server) through the transition relation; and the provider's
  own identity check still applies via the guest-plane permission branch.
  Guest-supplied lineage keys are discarded before dispatch.

  A `:spawn`-shaped call charges the root invoke budget inside the
  transition step and releases it when the synchronous dispatch returns.

  Options: `:guest_fn` (`:call` | `:spawn`, default `:call`), plus
  `call_external/4`'s options.
  """
  def call_in_chain(name, ctx, args, authority, opts \\ [])

  def call_in_chain(name, %Context{} = ctx, args, %Sanctum.Authority{} = authority, opts)
      when is_map(args) do
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    args =
      args
      |> Map.drop(["parent_execution_id", "root_execution_id"])
      |> put_lineage(Keyword.get(opts, :lineage))

    with :ok <- check_in_chain_reachable(name, args),
         {:ok, target} <- in_chain_target(ctx, name, args) do
      case Sanctum.Authority.Transition.step(authority, guest_fn, target) do
        {:allow_tool, resource} ->
          warn_on_description_drift(ctx, authority, resource)

          try do
            do_call(
              name,
              ctx,
              args,
              opts |> Keyword.delete(:guest_fn) |> Keyword.put(:in_chain, true)
            )
            |> prune_in_chain_discovery(name, args, ctx, authority)
          after
            if guest_fn == :spawn, do: Sanctum.Authority.release_invoke(authority)
          end

        {:deny, reason} ->
          {:error, "Denied by chain authority: #{inspect(reason)} for '#{name}'"}

        {:invalid, {:malformed_target, fun, tag}} ->
          {:error, "Invalid in-chain call: #{fun}/#{tag}"}
      end
    end
  end

  # Host-supplied lineage, re-injected after the guest's own keys were
  # dropped. This is the only channel a provider can trust for "which
  # chain is calling" — the execution provider uses it to keep cancel,
  # logs and list inside the caller's own subtree.
  defp put_lineage(args, nil), do: args

  defp put_lineage(args, lineage) when is_map(lineage) do
    args
    |> put_present("parent_execution_id", Map.get(lineage, :parent_execution_id))
    |> put_present("root_execution_id", Map.get(lineage, :root_execution_id))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # An action reachable in-chain says so in its plane annotation; an action
  # without one, or without :in_chain, fails closed. Proxied server:tool
  # names are the :external bucket, in-chain by wiring.
  defp check_in_chain_reachable(name, args) do
    if String.contains?(name, ":") do
      :ok
    else
      action = args["action"] || args[:action]

      case Arca.Cache.get({:mcp_tool, name}) do
        {:ok, {_module, meta}} ->
          planes = get_in(meta, [:annotations, :actions, action, :planes]) || []

          if :in_chain in planes do
            :ok
          else
            {:error, "Tool action '#{name}.#{action}' is not reachable from a running chain"}
          end

        :miss ->
          {:error, "Unknown tool: #{name}"}
      end
    end
  end

  # Discovery pruning for in-chain callers: `tools.list` shows a chain only
  # what it can reach — internal tools through the same :in_chain plane
  # annotations `call_in_chain/5` enforces per call, and external
  # `server:tool` entries only when the chain authority's tool_servers
  # grants cover them. Per-call enforcement stays with the transition
  # relation; this keeps the discovery view (and the untrusted upstream
  # descriptions it carries) from reaching an agent that holds no grant.
  defp prune_in_chain_discovery({:ok, %{tools: tools}}, "tools", args, ctx, authority)
       when is_list(tools) do
    if (args["action"] || args[:action]) == "list" do
      {internal, external} =
        Enum.split_with(tools, fn t -> not String.contains?(t["name"] || "", ":") end)

      {:ok, %{tools: in_chain_view(internal) ++ granted_external_tools(ctx, authority, external)}}
    else
      {:ok, %{tools: tools}}
    end
  end

  defp prune_in_chain_discovery(result, _name, _args, _ctx, _authority), do: result

  defp granted_external_tools(_ctx, _authority, []), do: []

  defp granted_external_tools(ctx, authority, external) do
    case authority.resources do
      %{tool_servers: servers} when is_list(servers) and servers != [] ->
        external
        |> Enum.group_by(fn t -> t["name"] |> String.split(":", parts: 2) |> hd() end)
        |> Enum.flat_map(fn {server_name, tools} ->
          digest = resolve_server_digest(ctx, server_name)

          case Enum.find(servers, &(&1.server_digest == digest)) do
            nil ->
              []

            %{tool_patterns: patterns} ->
              Enum.filter(tools, fn t ->
                case String.split(t["name"], ":", parts: 2) do
                  [_, remote] -> Enum.any?(patterns, &Sanctum.ToolPattern.matches?(&1, remote))
                  _ -> false
                end
              end)
          end
        end)
        |> Enum.sort_by(& &1["name"])

      _ ->
        []
    end
  end

  defp in_chain_target(ctx, name, args) do
    case String.split(name, ":", parts: 2) do
      [server_name, remote_tool] ->
        # The edge names the server by digest, so patterns match the
        # REMOTE tool name — the server prefix would make every pattern
        # server-qualified twice.
        {:ok,
         {:external_tool,
          %{server_digest: resolve_server_digest(ctx, server_name), tool: remote_tool}}}

      _ ->
        case args["action"] || args[:action] do
          action when is_binary(action) and action != "" ->
            {:ok, {:tool, %{tool: name, action: action}}}

          _ ->
            {:error, "In-chain call to '#{name}' requires an action"}
        end
    end
  end

  # D8: within granted patterns an upstream server can rewrite tool
  # descriptions at will, and agents feed those strings to a model holding
  # the profile's authority. The config digest defends the transport;
  # this defends nothing — it NAMES the residual: warn on drift from the
  # consent-time baseline, never block (a legitimate server adds tools).
  # Best-effort by design; a check failure must never affect dispatch.
  defp warn_on_description_drift(ctx, authority, {:tool_server, digest}) do
    with %{tool_servers: servers} <- authority.resources,
         %{descriptions_digest: baseline} = grant when is_binary(baseline) <-
           Enum.find(servers, &(&1.server_digest == digest)),
         {:ok, tools} <-
           Emissary.MCP.ExternalServer.get_tools(grant.server_name, ctx.athanor_id),
         {:ok, live} <-
           Sanctum.ToolServerDigest.descriptions_digest(tools, grant.tool_patterns) do
      unless Plug.Crypto.secure_compare(live, baseline) do
        Logger.warning(
          "[ToolRegistry] tool descriptions for server '#{grant.server_name}' drifted " <>
            "from their consent-time baseline — treat upstream descriptions as untrusted"
        )

        :telemetry.execute(
          [:sanctum, :tool_server, :description_drift],
          %{count: 1},
          %{server: grant.server_name, profile_id: authority.profile_id}
        )
      end

      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp warn_on_description_drift(_ctx, _authority, _resource), do: :ok

  # The consent identity of the named server, derived from its stored
  # configuration at read (a stored digest is a cache someone forgets to
  # recompute). A missing or unreadable server resolves to a sentinel no
  # edge can name — fail closed, not fail absent.
  defp resolve_server_digest(ctx, server_name) do
    cache_key = Arca.Cache.Keys.tool_server_digest(ctx.athanor_id, server_name)

    case Arca.Cache.get(cache_key) do
      {:ok, digest} ->
        digest

      :miss ->
        with {:ok, server} <- Arca.McpServerStorage.get(ctx, server_name),
             {:ok, digest} <- Sanctum.ToolServerDigest.from_server(server) do
          Arca.Cache.put(cache_key, digest)
          digest
        else
          _ -> "sha256:unresolved-server"
        end
    end
  end

  @doc false
  # The dispatch gate: enforce the action's access annotation — auth,
  # permission, consent — before the handler runs. Handlers keep only the
  # residual checks the annotation cannot express (tenant presence,
  # ownership, definition authority, the domain's finer consent arms).
  # Public solely so the discovery-parity test can ask the exact question
  # dispatch answers without executing any handler.
  @spec authorize_annotated_action(String.t(), map(), Context.t(), map()) ::
          :ok | {:error, String.t()}
  def authorize_annotated_action(name, meta, ctx, args) do
    action = args["action"] || args[:action]
    annotation = action && get_in(meta, [:annotations, :actions, action])

    cond do
      is_nil(action) ->
        {:error, "Missing required argument: action"}

      is_nil(annotation) ->
        # Default-deny: an action without an access declaration is not
        # dispatchable, whatever the handler would have said. The HTTP path
        # never gets here (InputValidator enforces the schema enum first);
        # this refuses the in-process callers.
        {:error, "Unknown action: #{name}.#{action}"}

      true ->
        with :ok <- check_auth(name, ctx, annotation),
             :ok <- check_scope(ctx, annotation),
             :ok <- check_permission(ctx, annotation) do
          check_consent(ctx, annotation)
        end
    end
  end

  # `scope: :platform` is the operator capability, not a widened tenant scope:
  # the caller still works inside one athanor and only the membership fact
  # (`platform_admin`) admits them.
  defp check_scope(ctx, annotation) do
    case Map.get(annotation, :scope) do
      nil -> :ok
      :platform when ctx.platform_admin -> :ok
      :platform -> {:error, "Unauthorized: platform admin required"}
    end
  end

  defp check_auth(name, ctx, annotation) do
    if Emissary.MCP.ToolVisibility.admits?(annotation, ctx) do
      :ok
    else
      {:error, "Unauthorized: tool '#{name}' requires authentication"}
    end
  end

  defp check_permission(ctx, annotation) do
    case Map.get(annotation, :permission) do
      nil -> :ok
      permission -> Context.require_permission_for_plane(ctx, permission)
    end
  end

  defp check_consent(ctx, annotation) do
    case Map.get(annotation, :consent) do
      nil ->
        :ok

      :interactive ->
        case Sanctum.Consent.Authz.authorize_interactive(ctx) do
          {:ok, :interactive} -> :ok
          {:error, refusal} -> {:error, consent_refusal(refusal)}
        end

      :staging ->
        case Sanctum.Consent.Authz.authorize_staging(ctx) do
          :ok -> :ok
          {:error, refusal} -> {:error, consent_refusal(refusal)}
        end
    end
  end

  # The same vocabulary Sanctum.MCP.ProfileTool speaks for domain-level
  # refusals, so a caller sees one phrasing whichever layer refused.
  defp consent_refusal({:surface_not_permitted, method}),
    do: "consent_class_required: this surface (#{method}) cannot consent"

  defp consent_refusal(:guest_plane),
    do: "consent_class_required: guest-plane contexts cannot consent"

  defp consent_refusal(other), do: "consent_class_required: #{inspect(other)}"

  defp do_call(name, %Context{} = ctx, args, opts) when is_map(args) do
    in_chain? = Keyword.get(opts, :in_chain, false)

    # Every call belongs to an ingress request. One that arrived over a
    # transport already carries it; an internal caller has none, so it becomes
    # its own root.
    own_root? = is_nil(ctx.request_id)
    ctx = if own_root?, do: %{ctx | request_id: Emissary.UUID7.request_id()}, else: ctx

    # Who logs what: a transport logs the request it received, and each
    # in-chain call logs itself. Without the second arm nothing recorded a
    # component's own tool calls at all — the context they run under inherits
    # the root's request id through the guest closure, which the guard used to
    # read as "the transport already logged this".
    #
    # `mcp_log` never logs, or it would record its own listing every time.
    should_log? = name != "mcp_log" and (in_chain? or own_root?)

    # A root call *is* its request, so it is filed under the request id. An
    # in-chain call is one of several beneath that request and needs its own
    # key; `request_id` on the row is what ties them together.
    call_id =
      cond do
        not should_log? -> nil
        in_chain? -> Emissary.UUID7.generate_id("call")
        true -> ctx.request_id
      end

    if should_log? do
      action = args["action"] || args[:action]

      Emissary.MCP.RequestLog.log_started(ctx, call_id, %{
        tool: name,
        action: action,
        method: "tools/call",
        input: args
      })
    end

    start_time = System.monotonic_time()

    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, {module, meta}} ->
        result =
          case authorize_annotated_action(name, meta, ctx, args) do
            :ok ->
              execute_tool_call(name, ctx, opts, fn -> module.handle(name, ctx, args) end)

            {:error, _} = refusal ->
              refusal
          end

        if should_log? do
          duration_ms =
            System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

          case result do
            {:ok, output} ->
              Emissary.MCP.RequestLog.log_completed(ctx, call_id, %{
                output: output,
                duration_ms: duration_ms,
                routed_to: inspect(module)
              })

            {:error, reason} ->
              Emissary.MCP.RequestLog.log_failed(ctx, call_id, %{
                error: inspect(Sanctum.Sanitizer.sanitize(reason)),
                code: -32_603,
                duration_ms: duration_ms,
                routed_to: inspect(module)
              })
          end
        end

        result

      :miss ->
        # Try external provider for namespaced tools (e.g., "notion:create_page")
        external_result =
          cond do
            String.contains?(name, ":") and not ctx.authenticated ->
              # External tools carry no per-tool requires_auth metadata; all
              # of them require authentication. The HTTP router never routes
              # unknown names here, so this guards the in-process callers
              # (FormulaHandler, LiveViews). Bare unknown names fall through
              # so they still produce "Unknown tool".
              {:error, "Unauthorized: tool '#{name}' requires authentication"}

            true ->
              execute_tool_call(name, ctx, opts, fn ->
                Emissary.MCP.ExternalProvider.try_handle(name, ctx, args)
              end)
          end

        case external_result do
          {:error, :not_external} ->
            if should_log? do
              duration_ms =
                System.convert_time_unit(
                  System.monotonic_time() - start_time,
                  :native,
                  :millisecond
                )

              Emissary.MCP.RequestLog.log_failed(ctx, call_id, %{
                error: "Unknown tool: #{name}",
                code: -32_601,
                duration_ms: duration_ms
              })
            end

            {:error, "Unknown tool: #{name}"}

          result ->
            if should_log? do
              duration_ms =
                System.convert_time_unit(
                  System.monotonic_time() - start_time,
                  :native,
                  :millisecond
                )

              case result do
                {:ok, output} ->
                  Emissary.MCP.RequestLog.log_completed(ctx, call_id, %{
                    output: output,
                    duration_ms: duration_ms,
                    routed_to: "external:#{name}"
                  })

                {:error, reason} ->
                  Emissary.MCP.RequestLog.log_failed(ctx, call_id, %{
                    error: inspect(Sanctum.Sanitizer.sanitize(reason)),
                    code: -32_603,
                    duration_ms: duration_ms,
                    routed_to: "external:#{name}"
                  })
              end
            end

            result
        end
    end
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    case Arca.Cache.get({:mcp_tool, name}) do
      {:ok, _} -> true
      :miss -> false
    end
  end

  @doc """
  Refresh the registry by re-reading from all providers.

  Useful for development/testing. In production, providers are
  loaded once at startup.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc """
  Audit every internal tool provider for complete per-action annotations.
  For each tool, checks that every value in
  `input_schema.properties.action.enum` has a matching key in
  `annotations.actions` carrying both a non-nil `kind` and a non-empty
  `planes` list of valid planes.

  The taxonomy is only as good as its coverage: an unannotated action has
  no risk class and no reachability, so it cannot be reasoned about at
  either gate. A CI test asserts this returns `:ok` — the boot-time call is
  advisory (and rescued) precisely so a taxonomy bug cannot take the
  registry down.

  Skips `Emissary.MCP.ExternalProvider` (its `mcp_servers` definition is
  audited; the upstream-tool proxy is exempt — those are classified as
  `:external` by `Prism.AquaActions.kind_for/2` via namespacing, and get
  their plane from `ExternalProvider.default_planes/0`).

  Returns `:ok` when all tools are clean, or `{:error, [missing]}` where
  each entry is `%{provider: module, tool: name, action: verb, reason: r}`.
  """
  @spec audit_action_kinds() :: :ok | {:error, [map()]}
  def audit_action_kinds do
    missing =
      available_providers()
      |> Enum.flat_map(fn module ->
        Enum.flat_map(module.tools(), fn tool ->
          audit_tool(module, tool)
        end)
      end)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  defp audit_tool(module, tool) do
    enum =
      get_in(tool, [Access.key(:input_schema, %{}), "properties", "action", "enum"]) || []

    # Every provider writes atom-keyed annotations with string verb keys;
    # there is deliberately no second accepted spelling.
    actions_meta = get_in(tool, [Access.key(:annotations, %{}), :actions]) || %{}

    Enum.flat_map(enum, fn verb ->
      case audit_action(Map.get(actions_meta, verb)) do
        :ok -> []
        {:error, reason} -> [%{provider: module, tool: tool.name, action: verb, reason: reason}]
      end
    end)
  end

  @valid_planes [:external, :in_chain]
  @valid_auth [:anonymous, :signed_in, :required]
  @valid_consent [:interactive, :staging]
  @valid_scopes [:platform]

  defp audit_action(%{} = annotation) do
    kind = Map.get(annotation, :kind)
    planes = Map.get(annotation, :planes)
    auth = Map.get(annotation, :auth, :required)
    permission = Map.get(annotation, :permission)
    consent = Map.get(annotation, :consent)
    scope = Map.get(annotation, :scope)

    cond do
      is_nil(kind) or not is_atom(kind) -> {:error, :missing_kind}
      not is_list(planes) or planes == [] -> {:error, :missing_planes}
      not Enum.all?(planes, &(&1 in @valid_planes)) -> {:error, :invalid_planes}
      auth not in @valid_auth -> {:error, :invalid_auth}
      not (is_nil(permission) or known_permission?(permission)) -> {:error, :invalid_permission}
      not (is_nil(consent) or consent in @valid_consent) -> {:error, :invalid_consent}
      not (is_nil(scope) or scope in @valid_scopes) -> {:error, :invalid_scope}
      # An operator-only action is an external-plane act; nothing in a chain is one.
      scope == :platform and planes != [:external] -> {:error, :invalid_scope}
      true -> :ok
    end
  end

  defp audit_action(_annotation), do: {:error, :missing_annotation}

  defp known_permission?(permission) when is_atom(permission),
    do: Atom.to_string(permission) in Sanctum.Atoms.known_permissions()

  defp known_permission?(_), do: false

  @doc """
  The planes an action may be annotated with.
  """
  @spec valid_planes() :: [Emissary.MCP.ToolProvider.plane()]
  def valid_planes, do: @valid_planes

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Load all configured providers into Arca.Cache
    load_providers()
    schedule_refresh()
    # Audit deferred to handle_continue so a bug in the audit (or in any
    # provider's tools/0) can't take down ToolRegistry at boot. Worst case,
    # a future refactor logs a warning instead of crashing the supervisor.
    {:ok, %{}, {:continue, :audit_action_kinds}}
  end

  @impl true
  def handle_continue(:audit_action_kinds, state) do
    log_action_kinds_audit()
    {:noreply, state}
  end

  # Run the action-kind audit and log any missing :kind annotations. The
  # audit never raises from this hook — drift is surfaced through logs (or,
  # for tests, by calling `audit_action_kinds/0` directly and asserting on
  # the result). Wrapped in try/rescue so a malformed tool definition can't
  # bring down ToolRegistry.
  defp log_action_kinds_audit do
    case audit_action_kinds() do
      :ok ->
        :ok

      {:error, missing} ->
        lines = Enum.map(missing, &"  - #{&1.tool}.#{&1.action} (#{inspect(&1.provider)})")
        Logger.warning("MCP tool actions missing :kind annotation:\n" <> Enum.join(lines, "\n"))
    end
  rescue
    e ->
      Logger.error("[ToolRegistry] action-kinds audit crashed: #{Exception.message(e)}")
      :ok
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    # Load new entries first, then clean up stale ones to avoid
    # a window where concurrent requests see missing tools
    old_tools =
      Arca.Cache.match({:mcp_tool, :_}) |> Enum.map(fn {{:mcp_tool, name}, _} -> name end)

    count = load_providers()

    new_tools =
      Arca.Cache.match({:mcp_tool, :_}) |> Enum.map(fn {{:mcp_tool, name}, _} -> name end)

    stale = old_tools -- new_tools
    for name <- stale, do: Arca.Cache.invalidate({:mcp_tool, name})
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:refresh_cache, state) do
    # Overwrite in-place; load_providers uses Arca.Cache.put which replaces
    # existing entries atomically. Stale tools from removed providers will
    # expire naturally via TTL.
    load_providers()
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # The handler runs under `async_nolink`, never `Task.async`. `Task.async` links,
  # and the caller here is the request process, which does not trap exits — so a
  # handler raising would propagate a link exit signal and kill the request
  # outright, returning a bare 500 instead of a JSON-RPC error. A signal is not
  # catchable by try/rescue, so the crash clauses below could never have fired for
  # that case. Without a link, a crash arrives as `{:exit, reason}` from `yield/2`.
  defp execute_tool_call(name, ctx, _opts, execute_fn) do
    # Registered under the server-minted request id, which is also the key
    # `Emissary.MCP.Progress` uses — one identity per request across both
    # subsystems. The transport cancels through this when its caller hangs up;
    # a context without one (an internal call that bypassed `do_call/4`'s
    # minting) simply is not cancellable.
    request_id = ctx.request_id
    trackable? = is_binary(request_id)

    task = Task.Supervisor.async_nolink(Emissary.TaskSupervisor, execute_fn)

    if trackable?, do: Emissary.MCP.RunningTasks.register(request_id, task)

    result =
      case Task.yield(task, @tool_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, {exception, stacktrace}} when is_exception(exception) ->
          Logger.error("Tool #{name} crashed: #{Exception.format(:error, exception, stacktrace)}")

          {:error, {:crashed, "Tool #{name} crashed: #{Exception.message(exception)}"}}

        {:exit, :cancelled} ->
          {:error, {:exit, "Tool #{name} was cancelled"}}

        {:exit, reason} ->
          Logger.error("Tool #{name} exited: #{inspect(reason)}")
          {:error, {:exit, "Tool #{name} exited unexpectedly"}}

        nil ->
          Logger.error("Tool #{name} timed out after #{@tool_timeout_ms}ms")
          {:error, {:timeout, "Tool #{name} timed out after #{@tool_timeout_ms}ms"}}
      end

    if trackable?, do: Emissary.MCP.RunningTasks.unregister(request_id)
    result
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_cache, @refresh_interval)
  end

  defp load_providers do
    providers = available_providers()

    tools =
      providers
      |> Enum.flat_map(fn module ->
        module.tools()
        |> Enum.map(fn tool ->
          meta = %{
            name: tool.name,
            description: tool.description,
            input_schema: tool.input_schema,
            # Optional per-tool fields
            title: Map.get(tool, :title),
            icons: Map.get(tool, :icons),
            output_schema: Map.get(tool, :output_schema),
            # Per-action access declarations ride in annotations.actions —
            # the dispatch gate and discovery both read them from here.
            annotations: Map.get(tool, :annotations)
          }

          Arca.Cache.put({:mcp_tool, tool.name}, {module, meta}, @cache_ttl)
          tool.name
        end)
      end)

    Logger.info(
      "MCP ToolRegistry loaded #{length(tools)} tools from #{length(providers)} providers"
    )

    length(tools)
  end

  @doc """
  The configured tool providers that are actually loadable, warning about
  any that aren't (an app-scoped test run without the sibling apps).

  The single reader of `:cyfr, :tool_providers` — config always sets the
  key, so the default is an empty list, never a hidden second roster.
  """
  @spec available_providers() :: [module()]
  def available_providers do
    Application.get_env(:cyfr, :tool_providers, [])
    |> Enum.filter(fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :tools, 0) do
        true
      else
        Logger.warning(
          "Tool provider #{inspect(module)} not available — skipping. " <>
            "Check that the application is started and the module exists."
        )

        false
      end
    end)
  end
end
