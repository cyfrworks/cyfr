# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Catalog do
  @moduledoc """
  Cache-backed registry for MCP tools.

  At startup, discovers all configured tool providers and caches
  them via Arca.Cache for O(1) tool lookup. This follows the OTP pattern of
  "configure in config, initialize in Application".

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │  Cyfr.Ops.Catalog (GenServer)                          │
  │  ├── Arca.Cache keys: {:mcp_tool, name}                         │
  │  │   └── {:mcp_tool, "retention"} => {Emissary.MCP.Tools.RecordsProvider, %{desc, ...}}   │
  │  │   └── {:mcp_tool, "execution"} => {Opus.MCP, %{...}}        │
  │  └── Providers: [Emissary.MCP.Tools.RecordsProvider, Opus.MCP, ...]                       │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Usage

      # List all tools
      Cyfr.Ops.Catalog.list_tools()

      # Call a tool
      Cyfr.Ops.Catalog.call_external("retention", context, %{"action" => "get"})

  ## One node, honestly

  The catalog routes calls within the local node.

  ## The gate, as it is

  Who may run an operation is decided once, here, and the answer has
  three arms. A guest-planed context with no Authority is denied every
  operation: a component reaches nothing by itself. A guest-planed
  context with an Authority reaches the in-chain set — the actions whose
  annotation names the `:in_chain` plane, derived from the declarations
  and nothing else — and only through `Sanctum.Authority.Transition.step/3`,
  which answers for the chain's grants; the identity conjunct is then
  the caller's own permission. An external-plane caller, a person or a
  key, is judged by the annotations alone: plane, auth, permission,
  consent class, scope. There is no rule that depends on which runner is
  asking.
  """

  use GenServer

  @behaviour Sanctum.Catalog
  require Logger

  alias Cyfr.Ops.Annotations
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

  Memoized briefly: the raw build is an `:ets.match_object` table scan
  over the whole shared cache on every `tools/list` request; the catalog
  changes only at registration/refresh (which invalidates the memo), so
  the short TTL is a backstop, not the freshness mechanism.
  """
  def list_tools do
    case Arca.Cache.get(:mcp_tool_list) do
      {:ok, tools} ->
        tools

      :miss ->
        tools = build_tool_list()
        Arca.Cache.put(:mcp_tool_list, tools, :timer.seconds(60))
        tools
    end
  end

  defp build_tool_list do
    Arca.Cache.match({:mcp_tool, :_})
    |> Enum.map(fn {_key, {_module, meta}} ->
      name = meta.name

      %{
        "name" => name,
        "description" => meta.description,
        "inputSchema" => meta.input_schema
      }
      |> Cyfr.MapUtil.put_present("title", meta[:title])
      |> Cyfr.MapUtil.put_present("icons", meta[:icons])
      |> Cyfr.MapUtil.put_present("outputSchema", meta[:output_schema])
      |> Cyfr.MapUtil.put_present("annotations", meta[:annotations])
    end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Prune a tools/list payload to the in-chain *plane*: actions whose plane
  annotation includes `:in_chain`. Proxied `server:tool` entries are
  in-chain by wiring and pass through whole; anything without an
  annotation fails closed, mirroring `call_in_chain/5`.

  This is the authority-less plane view, for surfaces where no chain
  authority applies (the `tools.list component_ref` preview). The in-chain
  catalogue a running chain sees is additionally grant-filtered in
  `prune_in_chain_discovery/5`.
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
      actions = Annotations.actions_of(tool_def)

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

  @doc """
  Look up a registered tool's provider module and cached meta.

  The one reader of the registry's cache representation — everything
  outside this module asks here, never the cache key.
  """
  @spec lookup(String.t()) :: {:ok, {module(), map()}} | :miss
  def lookup(name), do: Arca.Cache.get({:mcp_tool, name})

  @doc false
  # Install one tool under a provider module, exactly as `load_providers/0`
  # does. Tests plant probe providers through here instead of writing the
  # cache key, which is this module's private representation.
  def register_tool(name, module, meta, ttl \\ @cache_ttl) do
    Arca.Cache.put({:mcp_tool, name}, {module, meta}, ttl)
    Arca.Cache.invalidate(:mcp_tool_list)
  end

  @doc false
  def unregister_tool(name) do
    Arca.Cache.invalidate({:mcp_tool, name})
    Arca.Cache.invalidate(:mcp_tool_list)
  end

  @doc """
  Get a specific tool's definition.

  Returns `{:ok, tool_def}` or `{:error, :not_found}`.
  """
  def get_tool(name) do
    case lookup(name) do
      {:ok, {_module, meta}} ->
        tool_def =
          %{
            "name" => name,
            "description" => meta.description,
            "inputSchema" => meta.input_schema
          }
          |> Cyfr.MapUtil.put_present("title", meta[:title])
          |> Cyfr.MapUtil.put_present("icons", meta[:icons])
          |> Cyfr.MapUtil.put_present("outputSchema", meta[:output_schema])
          |> Cyfr.MapUtil.put_present("annotations", meta[:annotations])

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

  How the handler is run is the adapter's choice (`:runner`): `:inline`
  (the default) is a function call on the caller's own process — the
  gate, the contract and the handler, nothing else — for the console and
  the assistant, which already hold an authenticated context and a
  process of their own; `:supervised` runs it in a task under a timeout,
  registered under `ctx.request_id` so a transport whose caller
  disconnects can stop it (`Emissary.MCP.RunningTasks`), for the wire.
  """
  def call_external(name, ctx, args, opts \\ [])

  def call_external(name, %Context{plane: :guest}, _args, _opts) do
    {:error, {:guest_plane_call, name}}
  end

  def call_external(name, %Context{} = ctx, args, opts) when is_map(args) do
    # The plane is this function's name, never an option: a caller cannot
    # reach the in-chain arm (its consent-class and proxied-tool rules) by
    # passing the flag `call_in_chain/5` sets.
    do_call(name, ctx, args, Keyword.delete(opts, :in_chain))
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

  Options: `:guest_fn` (`:call` | `:spawn`, default `:call`), `:cancel_handle`
  (a caller-owned name for this call, `Emissary.MCP.RunningTasks.cancel_handle/1`
  stops the supervised handler by it alone), plus `call_external/4`'s
  options. The runner defaults to `:supervised` here: the handler runs on
  a guest's behalf, and a crash or a hang inside it must not take the
  chain's host process with it. A supervised handler that dies, exits or
  times out answers `{:error, {:uncertain, _}}` unless the action is
  declared `recovery: :replay_safe`: its effect may have happened.
  """
  def call_in_chain(name, ctx, args, authority, opts \\ [])

  def call_in_chain(name, %Context{} = ctx, args, %Sanctum.Authority{} = authority, opts)
      when is_map(args) do
    guest_fn = Keyword.get(opts, :guest_fn, :call)
    opts = opts |> Keyword.put_new(:runner, :supervised) |> with_charge_identity(guest_fn)

    args =
      args
      |> Map.drop(["parent_execution_id", "root_execution_id", "conversation_id", "attempt"])
      |> put_lineage(Keyword.get(opts, :lineage))

    with :ok <- check_in_chain_reachable(name, args),
         {:ok, target, server} <- in_chain_target(ctx, name, args) do
      case Sanctum.Authority.Transition.step(authority, guest_fn, target) do
        {:allow_tool, resource} ->
          warn_on_description_drift(ctx, authority, resource)

          # A spawn-shaped transition charged the invoke budget; this
          # process holds the slot, and the executor's wall-clock kill
          # would skip the `after` — the guard releases on :DOWN. With a
          # charge identity the hold is a row too, reclaimable past the
          # dispatcher's own timeout.
          case charge_row(guest_fn, ctx, authority, opts) do
            :ok ->
              if guest_fn == :spawn, do: Sanctum.Authority.guard_invoke(authority)

              try do
                do_call(
                  name,
                  ctx,
                  args,
                  opts
                  |> Keyword.drop([:guest_fn, :charge])
                  |> Keyword.put(:in_chain, true)
                  # The server row the transition was judged on is the one
                  # dispatch speaks to — one revision per call, never a
                  # second read that a change in between could answer.
                  |> Keyword.put(:server, server)
                )
                |> prune_in_chain_discovery(name, args, ctx, authority)
              after
                if guest_fn == :spawn do
                  Sanctum.Authority.release_invoke(authority)
                  release_row(ctx, authority, opts)
                end
              end

            {:error, reason} ->
              # The slot the transition charged goes back: the row refused it.
              Sanctum.Authority.Budget.release(authority.budget)

              {:error,
               "Denied by chain authority: " <>
                 "#{Sanctum.Authority.Transition.deny_message(reason)} for '#{name}'"}
          end

        {:deny, reason} ->
          # Rendered through the vocabulary's own renderer — never
          # `inspect`, which put internal terms on the guest's wire.
          {:error,
           "Denied by chain authority: " <>
             "#{Sanctum.Authority.Transition.deny_message(reason)} for '#{name}'"}

        {:invalid, {:malformed_target, fun, tag}} ->
          {:error, "Invalid in-chain call: #{fun}/#{tag}"}
      end
    end
  end

  # A spawn-shaped call charges the reservation row beside the slot. The
  # loop names the charge per dispatch; a call under a chain's attempt
  # without one — a guest's own call, its attempt on the host-stamped
  # lineage — is given a charge of its own, with no holder, so the row's
  # deadline is the dispatcher's timeout. Under no attempt at all the
  # slot alone is the hold.
  defp with_charge_identity(opts, :spawn) do
    case {Keyword.get(opts, :charge), get_in(opts, [:lineage, :attempt])} do
      {%{id: _}, _} ->
        opts

      {nil, attempt} when is_binary(attempt) ->
        Keyword.put(opts, :charge, %{
          id: Cyfr.UUID7.generate_id("chg"),
          attempt: attempt,
          generation: 0,
          holder_execution_id: nil
        })

      _ ->
        opts
    end
  end

  defp with_charge_identity(opts, _guest_fn), do: opts

  # `opts[:charge]` is `%{id, attempt, generation, holder_execution_id}`;
  # the row's deadline is the dispatcher's own timeout.
  defp charge_row(:spawn, %Context{athanor_id: athanor_id}, authority, opts)
       when is_binary(athanor_id) do
    case Keyword.get(opts, :charge) do
      %{id: _} = charge ->
        deadline = DateTime.add(DateTime.utc_now(), @tool_timeout_ms, :millisecond)

        case Arca.BudgetReservations.charge(athanor_id, authority.budget.id, charge, 1,
               holder_deadline: deadline
             ) do
          :ok -> :ok
          :exhausted -> {:error, :invoke_budget_exhausted}
          :stale_attempt -> {:error, :invoke_budget_exhausted}
          :released -> {:error, :invoke_budget_exhausted}
          {:error, _} -> {:error, :invoke_budget_exhausted}
        end

      _ ->
        :ok
    end
  end

  defp charge_row(_guest_fn, _ctx, _authority, _opts), do: :ok

  defp release_row(%Context{athanor_id: athanor_id}, authority, opts)
       when is_binary(athanor_id) do
    case Keyword.get(opts, :charge) do
      %{id: id} -> Arca.BudgetReservations.release(athanor_id, authority.budget.id, id)
      _ -> :ok
    end
  end

  defp release_row(_ctx, _authority, _opts), do: :ok

  # Host-supplied lineage, re-injected after the guest's own keys were
  # dropped. This is the only channel a provider can trust for "which
  # chain is calling" — the execution provider uses it to keep cancel,
  # logs and list inside the caller's own subtree.
  defp put_lineage(args, nil), do: args

  defp put_lineage(args, lineage) when is_map(lineage) do
    args
    |> Cyfr.MapUtil.put_present("parent_execution_id", Map.get(lineage, :parent_execution_id))
    |> Cyfr.MapUtil.put_present("root_execution_id", Map.get(lineage, :root_execution_id))
    # The attempt of the calling execution, so a provider answering the
    # caller its own payload knows which attempt's it is.
    |> Cyfr.MapUtil.put_present("attempt", Map.get(lineage, :attempt))
    # The conversation an approved card came from — host-stamped like the
    # execution ids, so a tool that records provenance reads it from here
    # and never from what the model wrote.
    |> Cyfr.MapUtil.put_present("conversation_id", Map.get(lineage, :conversation_id))
  end

  @doc """
  Whether a running chain can reach `tool.action` at all.

  An action reachable in-chain says so in its plane annotation; one without
  an annotation, or without `:in_chain`, fails closed. Proxied `server:tool`
  names are the `:external` bucket, in-chain by wiring.

  This is the same predicate `call_in_chain/5` enforces per call, exposed so
  the surfaces that *offer* actions — the agent capability matrix, the
  prompt's approval section, proposal validation — offer only what the chain
  could actually run, instead of handing someone a button that fails.
  """
  @spec in_chain_reachable?(String.t(), String.t() | nil) :: boolean()
  def in_chain_reachable?(name, action) when is_binary(name) do
    match?(:ok, check_in_chain_reachable(name, %{"action" => action}))
  end

  @doc """
  Whether a running chain can run `tool.action` at all: through the
  catalog (`in_chain_reachable?/2`), or through the host — an action
  annotated `host: :intercepted`, which the formula host runs under the
  chain's authority before any catalog call.
  """
  @spec chain_reachable?(String.t(), String.t() | nil) :: boolean()
  def chain_reachable?(name, action) when is_binary(name) do
    in_chain_reachable?(name, action) or host_intercepted?(name, action)
  end

  @doc "Whether the host, not the catalog, runs `tool.action` for a chain."
  @spec host_intercepted?(String.t(), String.t() | nil) :: boolean()
  def host_intercepted?(name, action) when is_binary(name) do
    case lookup(name) do
      {:ok, {_module, meta}} -> Annotations.host_intercepted?(meta, action)
      :miss -> false
    end
  end

  def host_intercepted?(_name, _action), do: false

  @doc """
  Whether this registry *knows* `tool.action` and says a chain may not run
  it at all — the answer a surface needs before refusing to offer something.

  Distinct from `not chain_reachable?/2`: a tool the registry has never
  heard of (a cold cache, a virtual tool the formula dispatches itself, an
  external `server:tool`) is not refused here, it is simply not this
  registry's to judge.
  """
  @spec in_chain_refused?(String.t(), String.t() | nil) :: boolean()
  def in_chain_refused?(name, action) when is_binary(name) do
    not String.contains?(name, ":") and
      match?({:ok, _}, lookup(name)) and
      not chain_reachable?(name, action)
  end

  def in_chain_refused?(_name, _action), do: false

  defp check_in_chain_reachable(name, args) do
    if String.contains?(name, ":") do
      :ok
    else
      action = args["action"] || args[:action]

      case lookup(name) do
        {:ok, {_module, meta}} ->
          planes = Annotations.planes(meta, action)

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
  # what it can reach — internal actions through the same two questions
  # `call_in_chain/5` asks per call (the :in_chain plane and the chain
  # authority's tool grants), and external `server:tool` entries only when
  # the authority's tool_servers grants cover them. Per-call enforcement
  # stays with the transition relation; this keeps the catalogue from
  # advertising what a call would be denied, and the untrusted upstream
  # descriptions from reaching an agent that holds no grant.
  defp prune_in_chain_discovery({:ok, %{tools: tools}}, "tools", args, ctx, authority)
       when is_list(tools) do
    if (args["action"] || args[:action]) == "list" do
      {internal, external} =
        Enum.split_with(tools, fn t -> not String.contains?(t["name"] || "", ":") end)

      {:ok,
       %{
         tools:
           granted_internal_tools(internal, authority) ++
             granted_external_tools(ctx, authority, external)
       }}
    else
      {:ok, %{tools: tools}}
    end
  end

  defp prune_in_chain_discovery(result, _name, _args, _ctx, _authority), do: result

  # The internal half of the same pruning: the plane question in_chain_view
  # asks, conjoined with the authority's tool grants — mirroring dispatch,
  # where check_in_chain_reachable runs before the transition's tool_bound.
  # No resources, no catalogue: fail closed like the external arm.
  defp granted_internal_tools(_internal, %{resources: :none}), do: []

  defp granted_internal_tools(internal, authority) do
    internal
    |> Enum.map(&prune_to_granted(&1, authority))
    |> Enum.reject(&is_nil/1)
  end

  defp prune_to_granted(%{"name" => name} = tool_def, authority) do
    actions = Annotations.actions_of(tool_def)

    reachable =
      for {action, %{planes: planes}} <- actions,
          :in_chain in planes,
          Sanctum.Authority.Transition.tool_granted?(authority, name, action),
          do: action

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

  defp granted_external_tools(_ctx, _authority, []), do: []

  defp granted_external_tools(ctx, authority, external) do
    case authority.resources do
      %{tool_servers: [_ | _]} ->
        external
        |> Enum.group_by(fn t -> t["name"] |> String.split(":", parts: 2) |> hd() end)
        |> Enum.flat_map(fn {server_name, tools} ->
          digest = resolve_server_digest(ctx, server_name)

          Enum.filter(tools, fn t ->
            case String.split(t["name"], ":", parts: 2) do
              [_, remote] ->
                Sanctum.Authority.Transition.external_tool_granted?(authority, digest, remote)

              _ ->
                false
            end
          end)
        end)
        |> Enum.sort_by(& &1["name"])

      _ ->
        []
    end
  end

  # The transition's target, and — for a proxied tool — the server row
  # its digest was derived from, so dispatch speaks to that revision.
  defp in_chain_target(ctx, name, args) do
    case String.split(name, ":", parts: 2) do
      [server_name, remote_tool] ->
        # The edge names the server by digest, so patterns match the
        # REMOTE tool name — the server prefix would make every pattern
        # server-qualified twice.
        {server, digest} = resolve_server(ctx, server_name)
        {:ok, {:external_tool, %{server_digest: digest, tool: remote_tool}}, server}

      _ ->
        case args["action"] || args[:action] do
          action when is_binary(action) and action != "" ->
            {:ok, {:tool, %{tool: name, action: action}}, nil}

          _ ->
            {:error, "In-chain call to '#{name}' requires an action"}
        end
    end
  end

  # Within granted patterns an upstream server can rewrite tool
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
          "[Cyfr.Ops.Catalog] tool descriptions for server '#{grant.server_name}' drifted " <>
            "from their consent-time baseline — treat upstream descriptions as untrusted"
        )

        :telemetry.execute(
          [:cyfr, :sanctum, :tool_server, :description_drift],
          %{count: 1},
          %{server: grant.server_name, profile_id: authority.profile_id}
        )
      end

      :ok
    else
      # Without a pinned baseline or tool server, skip the drift check.
      nil ->
        :ok

      %{} ->
        :ok

      # The upstream could not be reached, or its tool list would not digest.
      # That is a check that did not happen, and the whole point of the
      # `rescue` below is that a check which never runs must not read like
      # "no drift" — the same is true when the failure arrives as a value.
      {:error, reason} ->
        Logger.warning(
          "[Cyfr.Ops.Catalog] description-drift check could not run: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:cyfr, :sanctum, :tool_server, :description_drift_check_failed],
          %{count: 1},
          %{}
        )

        :ok
    end
  rescue
    # Log drift-check failures; the check remains best-effort.
    e ->
      Logger.warning(
        "[Cyfr.Ops.Catalog] description-drift check failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      :telemetry.execute(
        [:cyfr, :sanctum, :tool_server, :description_drift_check_failed],
        %{count: 1},
        %{}
      )

      :ok
  end

  defp warn_on_description_drift(_ctx, _authority, _resource), do: :ok

  # The named server's row and its consent identity, derived from the
  # row's stored configuration at every read: a cached digest is the copy
  # someone forgets to drop when the row changes, and the row itself is
  # handed on to dispatch so both see one revision. A missing or
  # unreadable server resolves to no row and a digest no edge can name —
  # fail closed, not fail absent.
  defp resolve_server(ctx, server_name) do
    with {:ok, server} <- Arca.McpServerStorage.get(ctx, server_name),
         {:ok, digest} <- Sanctum.ToolServerDigest.from_server(server) do
      {server, digest}
    else
      _ -> {nil, "sha256:unresolved-server"}
    end
  end

  defp resolve_server_digest(ctx, server_name), do: elem(resolve_server(ctx, server_name), 1)

  @doc false
  # The dispatch gate: enforce the action's access annotation — auth,
  # permission, consent — before the handler runs. Handlers keep only the
  # residual checks the annotation cannot express (tenant presence,
  # ownership, definition authority, the domain's finer consent arms).
  # Public solely so the discovery-parity test can ask the exact question
  # dispatch answers without executing any handler.
  @spec authorize_annotated_action(String.t(), map(), Context.t(), map(), boolean()) ::
          :ok
          | {:error,
             Sanctum.Unauthorized.reason() | :action_missing | {:unknown_action, String.t()}}
  def authorize_annotated_action(name, meta, ctx, args, in_chain? \\ false) do
    action = args["action"] || args[:action]
    annotation = Annotations.annotation(meta, action)

    cond do
      is_nil(action) ->
        {:error, :action_missing}

      is_nil(annotation) ->
        # Default-deny: an action without an access declaration is not
        # dispatchable, whatever the handler would have said. The HTTP path
        # never gets here (Cyfr.Ops.Contract enforces the schema enum first);
        # this refuses the in-process callers.
        {:error, {:unknown_action, "#{name}.#{action}"}}

      true ->
        with :ok <- check_auth(name, ctx, annotation),
             :ok <- check_scope(ctx, annotation),
             :ok <- check_permission(ctx, annotation) do
          check_consent(ctx, annotation, in_chain?)
        end
    end
  end

  # Validate declared input schemas for HTTP and in-process calls.
  # Tools without a schema are unconstrained here.
  defp validate_against_schema(meta, args) do
    case Map.get(meta, :input_schema) do
      schema when is_map(schema) and map_size(schema) > 0 ->
        case Cyfr.Ops.Contract.validate(args, without_action_rules(schema)) do
          :ok -> :ok
          {:error, message} -> {:error, {:invalid_argument, message}}
        end

      _ ->
        :ok
    end
  end

  # The annotation layer validates action and returns its typed errors.
  # Schema validation covers the remaining input fields.
  defp without_action_rules(schema) do
    schema
    |> update_in_if(["properties", "action"], &Map.delete(&1, "enum"))
    |> Map.replace_lazy("required", fn required ->
      if is_list(required), do: required -- ["action"], else: required
    end)
  end

  defp update_in_if(schema, path, fun) do
    if get_in(schema, path), do: update_in(schema, path, fun), else: schema
  end

  # `scope: :platform` is the operator capability, not a widened tenant scope:
  # the caller still works inside one athanor and only the membership fact
  # (`platform_admin`) admits them.
  defp check_scope(ctx, annotation) do
    case Map.get(annotation, :scope) do
      nil -> :ok
      :platform when ctx.platform_admin -> :ok
      :platform -> {:error, :platform_admin_required}
    end
  end

  defp check_auth(name, ctx, annotation) do
    if Cyfr.Ops.Visibility.admits?(annotation, ctx) do
      :ok
    else
      {:error, {:tool_auth_required, name}}
    end
  end

  defp check_permission(ctx, annotation) do
    case Map.get(annotation, :permission) do
      nil -> :ok
      permission -> Context.require_permission(ctx, permission, :in_chain)
    end
  end

  # Preserve typed consent refusals for rendering through Authz.message/1.
  # In-chain interactive calls retain the surface check; the approved
  # proposal supplies consent for the guest plane. Staging actions require
  # the full surface and plane checks and are unavailable in-chain.
  defp check_consent(ctx, annotation, in_chain?) do
    case Map.get(annotation, :consent) do
      nil ->
        :ok

      :interactive ->
        interactive =
          if in_chain?,
            do: Sanctum.Consent.Authz.authorize_interactive_in_chain(ctx),
            else: Sanctum.Consent.Authz.authorize_interactive(ctx)

        case interactive do
          {:ok, :interactive} -> :ok
          {:error, refusal} -> {:error, {:consent_class_required, refusal}}
        end

      :staging ->
        case Sanctum.Consent.Authz.authorize_staging(ctx) do
          :ok -> :ok
          {:error, refusal} -> {:error, {:consent_class_required, refusal}}
        end
    end
  end

  defp do_call(name, %Context{} = ctx, args, opts) when is_map(args) do
    in_chain? = Keyword.get(opts, :in_chain, false)

    # Every call belongs to an ingress request. One that arrived over a
    # transport already carries it; an internal caller has none, so it becomes
    # its own root.
    own_root? = is_nil(ctx.request_id)
    ctx = if own_root?, do: %{ctx | request_id: Cyfr.UUID7.request_id()}, else: ctx

    # Transports log incoming requests; in-chain calls log themselves even
    # when they inherit the root request id. Exclude mcp_log to avoid logging
    # its own queries.
    should_log? = name != "mcp_log" and (in_chain? or own_root?)

    # A root call *is* its request, so it is filed under the request id. An
    # in-chain call is one of several beneath that request and needs its own
    # key; `request_id` on the row is what ties them together.
    call_id =
      cond do
        not should_log? -> nil
        in_chain? -> Cyfr.UUID7.generate_id("call")
        true -> ctx.request_id
      end

    action = args["action"] || args[:action]
    started = %{tool: name, action: action, method: "tools/call", input: args}
    opts = Keyword.put(opts, :action, action)

    Emissary.MCP.RequestLog.around(should_log?, ctx, call_id, started, fn ->
      # A boot that lost its database's control plane dispatches nothing,
      # catalogued or proxied: the endpoint's plug refuses new requests,
      # but a connected console, an in-process caller and a running
      # chain's next call all arrive here without passing it.
      case Cyfr.ControlPlane.assert_owner() do
        :ok -> route(name, ctx, args, opts, in_chain?)
        {:error, _} = refusal -> {refusal, %{}}
      end
    end)
  end

  defp route(name, ctx, args, opts, in_chain?) do
    case lookup(name) do
      {:ok, {module, meta}} ->
        result =
          with :ok <- validate_against_schema(meta, args),
               :ok <- authorize_annotated_action(name, meta, ctx, args, in_chain?) do
            execute_tool_call(name, ctx, opts, fn -> module.handle(name, ctx, args) end)
          else
            {:error, _} = refusal -> refusal
          end

        {result, %{routed_to: inspect(module)}}

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
              {:error, {:tool_auth_required, name}}

            true ->
              # The caller's plane rides along: proxied tools are in-chain
              # by declaration, and an external-plane call reaches one only
              # when the server row opts in — enforced where the row is in
              # hand, not left to the wiring.
              plane = if Keyword.get(opts, :in_chain, false), do: :in_chain, else: :external

              execute_tool_call(name, ctx, opts, fn ->
                Emissary.MCP.ExternalProvider.try_handle(name, ctx, args, plane,
                  server: Keyword.get(opts, :server)
                )
              end)
          end

        case external_result do
          {:error, :not_external} ->
            error = "Unknown tool: #{name}"
            {{:error, error}, %{code: -32_601, error_text: error}}

          result ->
            {result, %{routed_to: "external:#{name}"}}
        end
    end
  end

  @doc """
  Check if a tool exists.
  """
  def exists?(name) do
    case lookup(name) do
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
  `:external` by `Aqua.Kinds.kind_for/2` via namespacing, and get
  their plane from `ExternalProvider.default_planes/0`).

  Returns `:ok` when all tools are clean, or `{:error, [missing]}` where
  each entry is `%{provider: module, tool: name, action: verb, reason: r}`.
  """
  @spec audit_action_kinds([module()]) :: :ok | {:error, [map()]}
  def audit_action_kinds(providers \\ available_providers()) do
    missing =
      providers
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

    # Strict read on purpose: the audit must reject exactly the spelling
    # the registry load would break on, not tolerate it.
    actions_meta = Annotations.declared_actions(tool)

    Enum.flat_map(enum, fn verb ->
      case audit_action(Map.get(actions_meta, verb)) do
        :ok -> []
        {:error, reason} -> [%{provider: module, tool: tool.name, action: verb, reason: reason}]
      end
    end)
  end

  @valid_planes [:external, :in_chain]
  @valid_host [:intercepted]
  @valid_auth [:anonymous, :signed_in, :required]
  @valid_consent [:interactive, :staging]
  @valid_scopes [:platform]
  @valid_standing [:conversation, false]
  @valid_recovery [:replay_safe]

  defp audit_action(%{} = annotation) do
    kind = Map.get(annotation, :kind)
    planes = Map.get(annotation, :planes)
    auth = Map.get(annotation, :auth, :required)
    permission = Map.get(annotation, :permission)
    consent = Map.get(annotation, :consent)
    scope = Map.get(annotation, :scope)
    standing = Map.get(annotation, :standing)
    host = Map.get(annotation, :host)
    recovery = Map.get(annotation, :recovery)

    cond do
      is_nil(kind) or not is_atom(kind) -> {:error, :missing_kind}
      not is_list(planes) or planes == [] -> {:error, :missing_planes}
      not Enum.all?(planes, &(&1 in @valid_planes)) -> {:error, :invalid_planes}
      not (is_nil(host) or host in @valid_host) -> {:error, :invalid_host}
      # The host intercepts what the catalog never dispatches in-chain.
      host == :intercepted and :in_chain in planes -> {:error, :invalid_host}
      auth not in @valid_auth -> {:error, :invalid_auth}
      not (is_nil(permission) or known_permission?(permission)) -> {:error, :invalid_permission}
      not (is_nil(consent) or consent in @valid_consent) -> {:error, :invalid_consent}
      not (is_nil(scope) or scope in @valid_scopes) -> {:error, :invalid_scope}
      not (is_nil(standing) or standing in @valid_standing) -> {:error, :invalid_standing}
      # An operator-only action is an external-plane act; nothing in a chain is one.
      scope == :platform and planes != [:external] -> {:error, :invalid_scope}
      not (is_nil(recovery) or recovery in @valid_recovery) -> {:error, :invalid_recovery}
      # Replay safety is a reviewed property of a read; a write can never carry it.
      not is_nil(recovery) and kind != :read -> {:error, :invalid_recovery}
      true -> :ok
    end
  end

  defp audit_action(_annotation), do: {:error, :missing_annotation}

  @doc """
  Every `tool.action` declared `recovery: :replay_safe`, derived from the
  providers' declarations: the operations a recovered turn may still
  dispatch past an uncertain step. There is no second list.
  """
  @spec replay_safe_actions([module()]) :: [String.t()]
  def replay_safe_actions(providers \\ available_providers()) do
    providers
    |> Enum.flat_map(fn module ->
      Enum.flat_map(module.tools(), fn tool ->
        tool
        |> Annotations.declared_actions()
        |> Enum.filter(fn {_verb, annotation} ->
          Map.get(annotation, :recovery) == :replay_safe
        end)
        |> Enum.map(fn {verb, _} -> "#{tool.name}.#{verb}" end)
      end)
    end)
    |> Enum.sort()
  end

  defp known_permission?(permission) when is_atom(permission),
    do: Atom.to_string(permission) in Sanctum.Atoms.known_permissions()

  defp known_permission?(_), do: false

  @doc """
  The planes an action may be annotated with.
  """
  @spec valid_planes() :: [Cyfr.Ops.Provider.plane()]
  def valid_planes, do: @valid_planes

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # A provider that cannot load is a boot failure, never a narrower
    # catalog: every consent shape is digested against what is loaded, and
    # a partial catalog would read as the whole. A run without the sibling
    # apps (one app's tests) says so in config and boots leniently.
    case providers_loaded() do
      :ok ->
        :ok

      {:error, missing} ->
        if Application.get_env(:cyfr, :tool_providers_lenient, false) do
          Logger.warning(
            "[Cyfr.Ops.Catalog] tool providers not loaded (lenient): #{inspect(missing)}"
          )
        else
          raise "configured tool providers failed to load: #{inspect(missing)} — " <>
                  "a catalog missing a provider narrows every consent digest; refusing to boot"
        end
    end

    # Load all configured providers into Arca.Cache
    load_providers()
    schedule_refresh()
    # Defer provider auditing to handle_continue and log failures without stopping the catalog.
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
  # bring down the catalog.
  defp log_action_kinds_audit do
    case audit_action_kinds() do
      :ok ->
        :ok

      {:error, missing} ->
        lines = Enum.map(missing, &"  - #{&1.tool}.#{&1.action} (#{inspect(&1.provider)})")

        Logger.warning(
          "[Cyfr.Ops.Catalog] MCP tool actions missing :kind annotation:\n" <>
            Enum.join(lines, "\n")
        )
    end
  rescue
    e ->
      Logger.error("[Cyfr.Ops.Catalog] action-kinds audit crashed: #{Exception.message(e)}")
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
    for name <- stale, do: unregister_tool(name)
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
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
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
  # The adapter's runner. Inline is the in-process call: the handler on the
  # caller's own process, with a raised authorization refusal answered as
  # the refusal it is and any other crash contained to this call.
  defp execute_tool_call(name, ctx, opts, execute_fn) do
    case Keyword.get(opts, :runner, :inline) do
      :inline -> run_inline(name, execute_fn)
      :supervised -> run_supervised(name, ctx, opts, execute_fn)
    end
  end

  defp run_inline(name, execute_fn) do
    execute_fn.()
  rescue
    refusal in Sanctum.UnauthorizedError ->
      {:error, refusal.reason}

    exception ->
      Logger.error(
        "[Cyfr.Ops.Catalog] Tool #{name} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:crashed, "Tool #{name} crashed"}}
  catch
    :exit, reason ->
      Logger.error("[Cyfr.Ops.Catalog] Tool #{name} exited: #{inspect(reason)}")
      {:error, {:exit, "Tool #{name} exited unexpectedly"}}
  end

  defp run_supervised(name, ctx, opts, execute_fn) do
    case Keyword.get(opts, :cancel_handle) do
      nil ->
        supervise(name, ctx, opts, nil, execute_fn)

      handle ->
        # Claimed before the task exists, so a cancel that lands first is
        # seen when the task registers, and the handler never runs.
        case Emissary.MCP.RunningTasks.claim(handle) do
          :ok -> supervise(name, ctx, opts, handle, execute_fn)
          :cancelled -> {:error, {:exit, "Tool #{name} was cancelled"}}
        end
    end
  end

  defp supervise(name, ctx, opts, handle, execute_fn) do
    # Registered under the server-minted request id, which is also the key
    # `Emissary.MCP.Progress` uses — one identity per request across both
    # subsystems. The transport cancels through this when its caller hangs up;
    # a context without one (an internal call that bypassed `do_call/4`'s
    # minting) simply is not cancellable that way — its caller cancels by
    # handle.
    request_id = ctx.request_id
    trackable? = is_binary(request_id)

    logger_metadata = Cyfr.LoggerContext.capture()

    task =
      Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)

        if handle && Emissary.MCP.RunningTasks.register_handle(handle, self()) == :cancelled,
          do: exit(:cancelled),
          else: execute_fn.()
      end)

    if trackable?, do: Emissary.MCP.RunningTasks.register(request_id, task)

    # An in-chain effect the handler may have made before it died is not
    # undone by its death: unless the action is reviewed as replay-safe,
    # the caller learns that the outcome is unknown, not that it failed.
    uncertain? =
      Keyword.get(opts, :in_chain, false) and
        not replay_safe?(name, Keyword.get(opts, :action))

    result =
      case Task.yield(task, @tool_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, {%Sanctum.UnauthorizedError{reason: reason}, _stacktrace}} ->
          # An authorization refusal that surfaced as a raise inside the
          # handler (`Context.athanor!/1`, `require_tenant!/1`) is a
          # refusal, not a crash: no error log, and the router answers it
          # with the auth error code instead of an isError "crashed" text.
          # The reason travels, not the sentence — the wire boundary renders
          # it the same way it renders the returned form, which is how the
          # raised one gets its own code rather than everything landing on
          # `:insufficient_permissions`.
          {:error, reason}

        {:exit, {exception, stacktrace}} when is_exception(exception) ->
          Logger.error(
            "[Cyfr.Ops.Catalog] Tool #{name} crashed: #{Exception.format(:error, exception, stacktrace)}"
          )

          # The tuple carries only the tool's name — the exception's own
          # message can hold a query, a path, or the offending bytes, and
          # this tuple renders verbatim on the wire (`Cyfr.Ops.Error.message/1`).
          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} crashed; its outcome is unknown"}},
            else: {:error, {:crashed, "Tool #{name} crashed"}}

        {:exit, :cancelled} ->
          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} was cancelled; its outcome is unknown"}},
            else: {:error, {:exit, "Tool #{name} was cancelled"}}

        {:exit, reason} ->
          Logger.error("[Cyfr.Ops.Catalog] Tool #{name} exited: #{inspect(reason)}")

          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} exited; its outcome is unknown"}},
            else: {:error, {:exit, "Tool #{name} exited unexpectedly"}}

        nil ->
          Logger.error("[Cyfr.Ops.Catalog] Tool #{name} timed out after #{@tool_timeout_ms}ms")

          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} timed out; its outcome is unknown"}},
            else: {:error, {:timeout, "Tool #{name} timed out after #{@tool_timeout_ms}ms"}}
      end

    if trackable?, do: Emissary.MCP.RunningTasks.unregister(request_id, task)
    if handle, do: Emissary.MCP.RunningTasks.release_handle(handle)
    result
  end

  defp replay_safe?(name, action) when is_binary(action) do
    case get_tool(name) do
      {:ok, tool_def} -> Cyfr.Ops.Annotations.recovery(tool_def, action) == :replay_safe
      _ -> false
    end
  end

  defp replay_safe?(_name, _action), do: false

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

          register_tool(tool.name, module, meta)
          tool.name
        end)
      end)

    Logger.info(
      "[Cyfr.Ops.Catalog] loaded #{length(tools)} tools from #{length(providers)} providers"
    )

    length(tools)
  end

  @doc """
  Every provider named in config, loaded or not. The status roster reads
  this set, so a configured provider that failed to load is reported as
  such rather than silently absent.

  The single reader of `:cyfr, :tool_providers` — config always sets the
  key, so the default is an empty list, never a hidden second roster.
  """
  @spec configured_providers() :: [module()]
  def configured_providers, do: Application.get_env(:cyfr, :tool_providers, [])

  @doc """
  The configured tool providers that are actually loadable, warning about
  any that aren't (an app-scoped test run without the sibling apps).
  """
  @spec available_providers() :: [module()]
  def available_providers do
    configured_providers()
    |> Enum.filter(fn module ->
      if loadable?(module) do
        true
      else
        Logger.warning(
          "[Cyfr.Ops.Catalog] Tool provider #{inspect(module)} not available — skipping. " <>
            "Check that the application is started and the module exists."
        )

        false
      end
    end)
  end

  @impl Sanctum.Catalog
  def providers_loaded do
    case Enum.reject(configured_providers(), &loadable?/1) do
      [] -> :ok
      missing -> {:error, missing}
    end
  end

  # Every `tool.action` the loaded providers declare — what a consent
  # shape may name (`Sanctum.Catalog`).
  @impl Sanctum.Catalog
  def tool_actions do
    for module <- available_providers(),
        tool <- module.tools(),
        {action, _annotation} <- Annotations.actions_of(tool),
        do: "#{tool.name}.#{action}"
  end

  # The external tool servers a grant may name (`Sanctum.Catalog`). The
  # proxied `server:tool` entries are the external provider's, so it is
  # what describes them.
  @impl Sanctum.Catalog
  def tool_server_candidates(%Context{} = ctx),
    do: Emissary.MCP.ExternalProvider.consent_candidates(ctx)

  @impl Sanctum.Catalog
  def tool_server_candidate(%Context{} = ctx, name) when is_binary(name),
    do: Emissary.MCP.ExternalProvider.consent_candidate(ctx, name)

  defp loadable?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :tools, 0)
end
