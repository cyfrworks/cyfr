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
  │  │   └── {:mcp_tool, "execution"} => {Cyfr.Execution.MCP, %{...}}        │
  │  └── Providers: [Emissary.MCP.Tools.RecordsProvider, Cyfr.Execution.MCP, ...]                       │
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
  and nothing else — and only through `Sanctum.Authority.step/3`, the
  transition relation with a spawn's budget charged, which answers for the
  chain's grants; the identity conjunct is then the caller's own
  permission. An external-plane caller, a person or a
  key, is judged by the annotations alone: plane, auth, permission,
  consent class, scope. There is no rule that depends on which runner is
  asking.
  """

  use GenServer

  @behaviour Sanctum.Catalog
  require Logger

  alias Cyfr.Ops.{Annotations, Operation}
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

  An empty build is never memoized. A server with no tools is not a state
  this catalog reaches — it refuses to boot without its providers — so an
  empty scan means the table is gone or its rebuild is in flight, and
  caching that answer for a minute is the "Unknown tool" window the
  rebuild exists to close.
  """
  def list_tools do
    case Arca.Cache.get(:mcp_tool_list) do
      {:ok, tools} ->
        tools

      :miss ->
        case build_tool_list() do
          [] ->
            []

          tools ->
            Arca.Cache.put(:mcp_tool_list, tools, :timer.seconds(60))
            tools
        end
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
            pruned -> restrict_tool(tool_def, pruned)
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
    meta =
      Operation.tool(
        Map.fetch!(meta, :operations),
        Map.to_list(Map.take(meta, [:description, :title, :icons, :output_schema]))
      )

    if meta.name != name,
      do: raise(ArgumentError, "registered tool identity does not match its operations")

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
  Restrict a wire tool definition to the selected actions.

  A registered tool's schema is rebuilt from its declarations, so the
  properties of hidden actions leave with them; a definition the catalog
  does not own (a remote server's tool) narrows only its action enum.
  """
  @spec restrict_tool(map(), [String.t()]) :: map()
  def restrict_tool(%{"name" => name} = tool_def, actions) when is_list(actions) do
    operations =
      case lookup(name) do
        {:ok, {_module, %{operations: operations}}} when is_list(operations) -> operations
        _ -> nil
      end

    Cyfr.Ops.Visibility.restrict_actions(tool_def, actions, operations)
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

  def call_external(_name, %Context{}, _args, _opts),
    do: {:error, {:invalid_argument, "Arguments must be an object"}}

  @doc """
  Call a tool from **inside a running chain** — the only entry that accepts
  an authority.

  Authorization is a conjunction, in order: the calling execution's
  grant must still stand; the action must be annotated
  in-chain-reachable; the chain's authority must grant the tool (or the
  matching tool server) through the transition relation; and the provider's
  own identity check still applies via the guest-plane permission branch.
  Guest-supplied lineage keys are discarded before dispatch.

  The grant is the one the calling execution's attempt stores, found by
  the host-stamped `opts[:lineage]`: its `attempt` must be an open attempt
  of its `parent_execution_id` in the caller's athanor, and the grant it
  stores must stand (`Sanctum.ExecutionStanding.verify/1`). Absent or
  mismatched lineage, or a grant whose estate was archived, admits nothing;
  nothing in `args` can supply it. The discovery predicates
  (`in_chain_view/1`, `in_chain_reachable?/2`) read no lineage and admit
  no call.

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

  def call_in_chain(name, %Context{} = ctx, args, %Cyfr.Authority{} = authority, opts)
      when is_map(args) do
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    # An outbound call is an execution of its own: its id exists before
    # the charge, so the hold names it as its holder and admission can
    # stamp the hold admitted.
    opts =
      if String.contains?(name, ":") and guest_fn == :spawn,
        do: Keyword.put_new_lazy(opts, :execution_id, &Cyfr.UUID7.execution_id/0),
        else: opts

    opts = opts |> Keyword.put_new(:runner, :supervised) |> with_charge_identity(guest_fn)

    args =
      args
      |> Map.drop(["parent_execution_id", "root_execution_id", "thread_id", "attempt"])

    with :ok <- lineage_standing(ctx, Keyword.get(opts, :lineage)),
         :ok <- check_in_chain_reachable(name, args),
         :ok <- authorize_declared_action(name, ctx, args, true),
         {:ok, args} <- validate_chain_arguments(name, args),
         {:ok, target, server} <- in_chain_target(ctx, name, args) do
      case Sanctum.Authority.step(authority, guest_fn, target) do
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
                  |> Keyword.put(:hold, hold_of(authority, Keyword.get(opts, :charge)))
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
              Sanctum.Authority.BudgetCounter.release(authority.budget)

              {:error,
               "Denied by chain authority: " <>
                 "#{Cyfr.Authority.Transition.deny_message(reason)} for '#{name}'"}
          end

        {:deny, reason} ->
          # Rendered through the vocabulary's own renderer — never
          # `inspect`, which put internal terms on the guest's wire.
          {:error,
           "Denied by chain authority: " <>
             "#{Cyfr.Authority.Transition.deny_message(reason)} for '#{name}'"}

        {:invalid, {:malformed_target, fun, tag}} ->
          {:error, "Invalid in-chain call: #{fun}/#{tag}"}
      end
    end
  end

  def call_in_chain(_name, %Context{}, _args, %Cyfr.Authority{}, _opts),
    do: {:error, {:invalid_argument, "Arguments must be an object"}}

  # The calling execution's grant, found by the host's lineage: an open
  # attempt of the parent execution, in the caller's own athanor, storing
  # a grant that stands.
  defp lineage_standing(%Context{} = ctx, %{attempt: attempt, parent_execution_id: parent})
       when is_binary(attempt) and is_binary(parent) do
    case Arca.ExecutionAttempts.standing?(Context.actor(ctx), attempt, parent,
           grant: :stored,
           verify: &Sanctum.ExecutionStanding.verify/1
         ) do
      true ->
        :ok

      {:error, reason} when reason in [:unavailable, :database_error] ->
        {:error, {:unavailable, "The calling execution's standing"}}

      _refused ->
        {:error, :archived}
    end
  end

  defp lineage_standing(_ctx, _lineage),
    do: {:error, {:invalid_argument, "An in-chain call names the execution that makes it"}}

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
          holder_execution_id: Keyword.get(opts, :execution_id)
        })

      _ ->
        opts
    end
  end

  defp with_charge_identity(opts, _guest_fn), do: opts

  # The hold an outbound execution's admission stamps: the reservation the
  # chain's authority was minted with and the charge row taken at the gate.
  defp hold_of(%Cyfr.Authority{budget: %{id: reservation_id}}, %{id: id}),
    do: %{reservation_id: reservation_id, id: id}

  defp hold_of(_authority, _charge), do: nil

  # `opts[:charge]` is `%{id, attempt, generation, holder_execution_id}`;
  # the row's deadline is the dispatcher's own timeout.
  defp charge_row(:spawn, %Context{athanor_id: athanor_id} = ctx, authority, opts)
       when is_binary(athanor_id) do
    case Keyword.get(opts, :charge) do
      %{id: _} = charge ->
        deadline = DateTime.add(DateTime.utc_now(), @tool_timeout_ms, :millisecond)

        case Arca.BudgetReservations.charge(Context.actor(ctx), authority.budget.id, charge, 1,
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

  defp release_row(%Context{athanor_id: athanor_id} = ctx, authority, opts)
       when is_binary(athanor_id) do
    case Keyword.get(opts, :charge) do
      %{id: id} -> Arca.BudgetReservations.release(Context.actor(ctx), authority.budget.id, id)
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
    # The thread an approved card came from — host-stamped like the
    # execution ids, so a tool that records provenance reads it from here
    # and never from what the model wrote.
    |> Cyfr.MapUtil.put_present("thread_id", Map.get(lineage, :thread_id))
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

          cond do
            is_nil(Annotations.annotation(meta, action)) ->
              with {:ok, _} <- Operation.cast(meta, args),
                   do: {:error, {:unknown_action, "#{name}.#{action}"}}

            :in_chain in planes ->
              :ok

            true ->
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
          Cyfr.Authority.Transition.tool_granted?(authority, name, action),
          do: action

    case {reachable, get_in(tool_def, ["inputSchema", "properties", "action", "enum"])} do
      {[], _} ->
        nil

      {_, listed} when is_list(listed) ->
        case Enum.filter(listed, &(&1 in reachable)) do
          [] -> nil
          ^listed -> tool_def
          pruned -> Cyfr.Ops.Visibility.restrict_actions(tool_def, pruned)
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
                Cyfr.Authority.Transition.external_tool_granted?(authority, digest, remote)

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
    with {:ok, server} <- Arca.McpServerStorage.get(Sanctum.Context.actor(ctx), server_name),
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
        # dispatchable, whatever the handler would have said.
        {:error, {:unknown_action, "#{name}.#{action}"}}

      not in_chain? and :external not in Annotations.planes(meta, action) ->
        # An action a running chain alone may call is not served outside one.
        {:error, {:unknown_action, "#{name}.#{action}"}}

      true ->
        with :ok <- check_auth(name, ctx, annotation),
             :ok <- check_scope(ctx, annotation),
             :ok <- check_permission(ctx, annotation) do
          check_consent(ctx, annotation, in_chain?)
        end
    end
  end

  # A declared action is authorized before its remaining fields are
  # validated. Missing or unknown action identity stays a cast error so
  # every ingress reports the same refusal. Remote `server:tool` names
  # keep their existing proxied authorization.
  @doc false
  @spec authorize_declared_action(String.t(), Context.t(), term(), boolean()) ::
          :ok
          | {:error,
             Sanctum.Unauthorized.reason() | :action_missing | {:unknown_action, String.t()}}
  def authorize_declared_action(name, ctx, args, in_chain? \\ false)

  def authorize_declared_action(_name, _ctx, args, _in_chain?) when not is_map(args), do: :ok

  def authorize_declared_action(name, ctx, args, in_chain?) when is_binary(name) do
    if String.contains?(name, ":") do
      :ok
    else
      case lookup(name) do
        {:ok, {_module, meta}} -> authorize_declared_action(name, meta, ctx, args, in_chain?)
        :miss -> :ok
      end
    end
  end

  defp authorize_declared_action(name, meta, ctx, args, in_chain?) when is_map(meta) do
    action = args["action"] || args[:action]

    if is_binary(action) and match?(%{}, Annotations.annotation(meta, action)) do
      authorize_annotated_action(name, meta, ctx, args, in_chain?)
    else
      :ok
    end
  end

  @doc "Validate a registered operation's arguments through its canonical declaration."
  @spec validate_arguments(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def validate_arguments(name, args) do
    case lookup(name) do
      {:ok, {_module, meta}} -> Operation.cast(meta, args)
      :miss -> {:error, {:not_found, "tool", name}}
    end
  end

  # Remote tools carry their own schemas and are not local operation providers.
  defp validate_chain_arguments(name, args) do
    if String.contains?(name, ":"), do: {:ok, args}, else: validate_arguments(name, args)
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
    # when they inherit the root request id, and their start row is written
    # before the effect; an in-process caller's own root rides the
    # write-behind, start and close alike. Exclude mcp_log to avoid logging
    # its own queries.
    log_mode =
      cond do
        name == "mcp_log" -> false
        in_chain? -> true
        own_root? -> :behind
        true -> false
      end

    should_log? = log_mode != false

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
    logged_args = if in_chain?, do: put_lineage(args, Keyword.get(opts, :lineage)), else: args
    started = %{tool: name, action: action, method: "tools/call", input: logged_args}
    opts = Keyword.put(opts, :action, action)

    Emissary.MCP.RequestLog.around(log_mode, ctx, call_id, started, fn ->
      # A member that lost its cell slot dispatches nothing, catalogued or
      # proxied: the endpoint's plug refuses new requests, but a connected
      # console, an in-process caller and a running chain's next call all
      # arrive here without passing it.
      if Arca.ControlPlane.held?() do
        route(name, ctx, args, opts, in_chain?)
      else
        {{:error, :control_plane_lost}, %{}}
      end
    end)
  end

  defp route(name, ctx, args, opts, in_chain?) do
    case lookup(name) do
      {:ok, {module, meta}} ->
        result =
          with :ok <- authorize_declared_action(name, ctx, args, in_chain?),
               {:ok, args} <- Operation.cast(meta, args) do
            args = if in_chain?, do: put_lineage(args, Keyword.get(opts, :lineage)), else: args
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
              args = if in_chain?, do: put_lineage(args, Keyword.get(opts, :lineage)), else: args

              execute_tool_call(name, ctx, opts, fn ->
                Emissary.MCP.ExternalProvider.try_handle(name, ctx, args, plane,
                  server: Keyword.get(opts, :server),
                  execution_id: Keyword.get(opts, :execution_id),
                  step: Keyword.get(opts, :step),
                  hold: Keyword.get(opts, :hold),
                  retention_class: Keyword.get(opts, :retention_class)
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
  Audit every internal provider's canonical operations and permissions.
  `Cyfr.Ops.Operation` validates the declaration structure; this catalog
  additionally requires each permission to be known by Sanctum.

  The taxonomy is only as good as its coverage: an unannotated action has
  no risk class and no reachability, so it cannot be reasoned about at
  either gate. The catalog runs this at boot and refuses to start on any
  finding.

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

  defp audit_tool(module, %{name: name, operations: operations})
       when is_list(operations) and operations != [] do
    Enum.flat_map(operations, fn operation ->
      result =
        try do
          Operation.validate!(operation)

          cond do
            operation.tool != name ->
              {:error, :invalid_operation}

            Enum.count(operations, &(is_map(&1) and Map.get(&1, :action) == operation.action)) !=
                1 ->
              {:error, :invalid_operation}

            not is_nil(operation.permission) and not known_permission?(operation.permission) ->
              {:error, :invalid_permission}

            true ->
              :ok
          end
        rescue
          ArgumentError -> {:error, :invalid_operation}
        end

      case result do
        :ok ->
          []

        {:error, reason} ->
          [
            %{
              provider: module,
              tool: name,
              action: if(is_map(operation), do: Map.get(operation, :action)),
              reason: reason
            }
          ]
      end
    end)
  end

  defp audit_tool(module, tool),
    do: [
      %{provider: module, tool: Map.get(tool, :name), action: nil, reason: :missing_operations}
    ]

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
          Annotations.recovery_of(annotation) == :replay_safe
        end)
        |> Enum.map(fn {verb, _} -> "#{tool.name}.#{verb}" end)
      end)
    end)
    |> Enum.sort()
  end

  # `Operation.validate!/1` has already established that a non-nil
  # permission is an atom by the time the audit reaches this check.
  defp known_permission?(permission),
    do: Atom.to_string(permission) in Sanctum.Atoms.known_permissions()

  @doc """
  The planes an action may be annotated with.
  """
  @spec valid_planes() :: [Cyfr.Ops.Provider.plane()]
  defdelegate valid_planes(), to: Operation

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

    # An action the gates cannot classify is a boot failure, like a
    # provider that cannot load.
    case audit_action_kinds() do
      :ok ->
        :ok

      {:error, findings} ->
        lines = Enum.map(findings, &"  - #{&1.tool}.#{&1.action}: #{&1.reason}")

        raise "tool annotations failed the catalog audit; refusing to boot:\n" <>
                Enum.join(lines, "\n")
    end

    # Watched before the catalogue is written, for the reason `handle_info
    # (:rebuild_cache, …)` gives: an owner lost mid-load must leave a
    # `:DOWN` in the mailbox, not a live monitor over a half-written table.
    state = watch_cache_owner(%{})
    load_providers()
    schedule_refresh()
    {:ok, state}
  end

  # The catalogue lives in `Arca.Cache`, whose table dies with its owner,
  # `Arca.Cache.Sweeper`. That owner is started by the `arca` application,
  # one app below this one, so no supervisor here can hold both it and
  # this registry — the `:rest_for_one` group that used to restart the two
  # together cannot span two applications. A monitor keeps the same
  # guarantee: when the owner goes, the catalogue goes with it, and this
  # rebuilds into the table the replacement owner creates rather than
  # answering an empty catalogue until the next refresh, a day later.
  @cache_owner_retry_ms 100

  defp watch_cache_owner(state) do
    case Arca.Cache.monitor_owner() do
      nil ->
        # No table to watch: it is gone, or not created yet. Come back and
        # REBUILD rather than only re-arm — an owner that died while this
        # was repopulating leaves nothing to monitor, and a monitor alone
        # would wait for a `:DOWN` that has already happened while the
        # catalogue stayed lost.
        Process.send_after(self(), :rebuild_cache, @cache_owner_retry_ms)
        Map.put(state, :cache_owner, nil)

      ref ->
        Map.put(state, :cache_owner, ref)
    end
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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cache_owner: ref} = state) do
    send(self(), :rebuild_cache)
    {:noreply, state}
  end

  @impl true
  def handle_info(:rebuild_cache, state) do
    # `ensure_table/0` is a call on the table's owner, so it answers only
    # once the supervisor has restarted it and the table is back. Until
    # then it says the cache is unavailable, and this waits rather than
    # writing a catalogue into a table about to be replaced.
    case Arca.Cache.Sweeper.ensure_table() do
      :ok ->
        # Watch the replacement owner BEFORE writing the catalogue into its
        # table. An owner killed while `load_providers/0` is halfway through
        # takes the entries written so far with it; the rest land in the
        # next owner's table, and a monitor armed AFTERWARDS finds that
        # owner alive and waits for a `:DOWN` that will never come, leaving
        # the catalogue permanently short. Armed first, the `:DOWN` is
        # already queued and the rebuild runs again as soon as this returns.
        state = watch_cache_owner(state)
        load_providers()
        # The memo is built from the table, so one taken while the rebuild
        # was in flight describes a partial catalog; drop it rather than
        # serve it out for the next minute.
        Arca.Cache.invalidate(:mcp_tool_list)
        {:noreply, state}

      {:error, :cache_unavailable} ->
        Process.send_after(self(), :rebuild_cache, @cache_owner_retry_ms)
        {:noreply, state}
    end
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
          # this tuple renders verbatim on the wire (`Cyfr.Refusal.message/1`).
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
          register_tool(tool.name, module, tool)
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

  @doc """
  Every `tool.action` served outside a running chain: the declared
  actions whose planes include `:external`.
  """
  @spec external_tool_actions() :: [String.t()]
  def external_tool_actions do
    for module <- available_providers(),
        tool <- module.tools(),
        {action, annotation} <- Annotations.actions_of(tool),
        :external in Map.get(annotation, :planes, []),
        do: "#{tool.name}.#{action}"
  end

  @doc """
  Every `tool.action` annotated `host: :intercepted`: the actions a
  formula's host runs under the chain's authority rather than dispatching
  through the catalog, sorted.
  """
  @spec host_intercepted_actions() :: [String.t()]
  def host_intercepted_actions do
    Enum.sort(
      for module <- available_providers(),
          tool <- module.tools(),
          {action, _annotation} <- Annotations.actions_of(tool),
          Annotations.host_intercepted?(tool, action),
          do: "#{tool.name}.#{action}"
    )
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
