# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Catalog do
  @moduledoc """
  The operation table and the gate that dispatches through it.

  At boot, before any supervisor starts, `load!/0` reads every provider
  configured under `:cyfr, :tool_providers`, audits its declarations and
  writes the table into Grimoire's own `:persistent_term`: the table
  itself (`{Grimoire, :operations}`, tool name → `{provider, tool}`), the
  sorted wire list `tools/list` serves (`{Grimoire, :tool_list}`) and,
  through `Grimoire.Resources`, the resource URI index
  (`{Grimoire, :resources}`). The term is this member's, written once;
  nothing refreshes, rebuilds or invalidates it, and a process that dies
  takes none of it along. Every lookup and every action enumeration reads
  it. The proxied `server:tool` tools are no provider's declarations and
  are not in it: they are the tenant's, cached per athanor by the proxy
  port (`Grimoire.Proxy`).

  Callers outside the gate enter through `Grimoire`; this module is its
  implementation.

  ## Usage

      Grimoire.list_tools()
      Grimoire.call_external("retention", context, %{"action" => "get"})

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

  ## What a handler is given

  The gate decides with the caller's full context. Only after
  authentication, consent, argument validation and lineage have run does
  the handler receive its input, projected once in `route/5`'s handler
  closure: a provider declaring `context_kind: :actor`
  (`Prima.Provider.context_kind/1`) is given `Sanctum.Context.actor/1`
  of that context and nothing else, on either plane; every other provider
  is given the context. The boot audit refuses a provider that declares
  anything else.
  """

  @behaviour Sanctum.Grimoire
  require Logger

  alias Grimoire.Annotations
  alias Grimoire.Error
  alias Prima.Operation
  alias Sanctum.Context

  # Default tool execution timeout (5 minutes)
  @tool_timeout_ms :timer.minutes(5)

  # The operation table's two terms. `Grimoire.Resources` holds the third.
  @operations {Grimoire, :operations}
  @tool_list {Grimoire, :tool_list}

  # ============================================================================
  # The table
  # ============================================================================

  @doc """
  Build the operation table from the configured providers and write it,
  once, into this member's `:persistent_term`. Called by
  `Cyfr.Application.start/2` after the ports are installed and before any
  supervisor starts, so nothing that dispatches can run before the table
  exists.

  A provider that cannot load, or does not export `tools/0`, refuses the
  boot: every consent shape is digested against the table, and a partial
  table would read as the whole. A run without the sibling applications
  (one application's tests) says so with `:tool_providers_lenient`, and
  each such provider is skipped with its reason logged. An action the
  gates cannot classify, a handler input the gate cannot honour, and a
  resource read the gate cannot name refuse the boot the same way.
  """
  @spec load!() :: :ok
  def load! do
    configured_providers()
    |> loadable_roster!()
    |> install!()
  end

  @doc false
  # The table for a block, then the table as it was. A test that plants a
  # probe provider runs it through here, synchronously (`async: false`):
  # the planted providers join the configured roster, pass the same audits
  # as a booted provider, and are gone when the block returns, however it
  # returns.
  @spec with_providers([module()], (-> result)) :: result when result: term()
  def with_providers(providers, fun) when is_list(providers) and is_function(fun, 0) do
    for provider <- providers, not loadable?(provider) do
      raise ArgumentError,
            "#{inspect(provider)} is not a provider: it does not export tools/0"
    end

    saved =
      {:persistent_term.get(@operations), :persistent_term.get(@tool_list),
       Grimoire.Resources.table()}

    try do
      configured_providers()
      |> loadable_roster!()
      |> Enum.concat(providers)
      |> Enum.uniq()
      |> install!()

      fun.()
    after
      {operations, tool_list, resources} = saved
      :persistent_term.put(@operations, operations)
      :persistent_term.put(@tool_list, tool_list)
      Grimoire.Resources.put(resources)
    end
  end

  # The configured providers this boot can load. One that cannot is a
  # refusal, or — leniently — a skip with its reason.
  defp loadable_roster!(configured) do
    case Enum.reject(configured, &loadable?/1) do
      [] ->
        configured

      missing ->
        unless Application.get_env(:cyfr, :tool_providers_lenient, false) do
          raise "configured tool providers failed to load: #{inspect(missing)} — " <>
                  "a catalog missing a provider narrows every consent digest; refusing to boot"
        end

        for module <- missing do
          Logger.warning(
            "[Grimoire.Catalog] tool provider #{inspect(module)} skipped (lenient): " <>
              unloadable_reason(module)
          )
        end

        configured -- missing
    end
  end

  defp unloadable_reason(module) do
    if Code.ensure_loaded?(module),
      do: "it does not export tools/0",
      else: "the module is not available"
  end

  defp install!(providers) do
    audit!(audit_action_kinds(providers), "tool annotations failed the catalog audit", fn f ->
      "#{f.tool}.#{f.action}: #{f.reason}"
    end)

    audit!(
      audit_context_kinds(providers),
      "provider handler inputs failed the catalog audit",
      &"#{inspect(&1.provider)}: #{&1.reason}"
    )

    audit!(
      audit_resource_schemes(providers),
      "resource declarations failed the catalog audit",
      &inspect/1
    )

    operations =
      for module <- providers, tool <- module.tools(), into: %{} do
        {tool.name, {module, canonical(tool)}}
      end

    :persistent_term.put(@operations, operations)
    :persistent_term.put(@tool_list, wire_list(operations))
    Grimoire.Resources.put(Grimoire.Resources.build(providers))

    Logger.info(
      "[Grimoire.Catalog] loaded #{map_size(operations)} tools from #{length(providers)} providers"
    )

    :ok
  end

  defp audit!(:ok, _what, _line), do: :ok

  defp audit!({:error, findings}, what, line) do
    raise "#{what}; refusing to boot:\n" <>
            Enum.map_join(findings, "\n", &("  - " <> line.(&1)))
  end

  # A tool as the table holds it: rebuilt from its operations, so the
  # schema and annotations are the declarations' and nothing else.
  defp canonical(tool) do
    meta =
      Operation.tool(
        Map.fetch!(tool, :operations),
        Map.to_list(Map.take(tool, [:description, :title, :icons, :output_schema]))
      )

    if meta.name != tool.name,
      do: raise(ArgumentError, "registered tool identity does not match its operations")

    meta
  end

  defp wire_list(operations) do
    operations
    |> Enum.map(fn {name, {_module, meta}} -> wire(name, meta) end)
    |> Enum.sort_by(& &1["name"])
  end

  defp wire(name, meta) do
    %{
      "name" => name,
      "description" => meta.description,
      "inputSchema" => meta.input_schema
    }
    |> Prima.MapUtil.put_present("title", meta[:title])
    |> Prima.MapUtil.put_present("icons", meta[:icons])
    |> Prima.MapUtil.put_present("outputSchema", meta[:output_schema])
    |> Prima.MapUtil.put_present("annotations", meta[:annotations])
  end

  @doc "The operation table: tool name → `{provider, tool}`."
  @spec operations() :: %{String.t() => {module(), map()}}
  def operations, do: :persistent_term.get(@operations)

  @doc """
  Every tool the table holds, as `tools/list` serves it, sorted by name.
  """
  @spec list_tools() :: [map()]
  def list_tools, do: :persistent_term.get(@tool_list)

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

  @doc "A tool's provider and its declarations, from the table."
  @spec lookup(String.t()) :: {:ok, {module(), map()}} | :miss
  def lookup(name) do
    case operations() do
      %{^name => entry} -> {:ok, entry}
      _ -> :miss
    end
  end

  @doc """
  Get a specific tool's definition.

  Returns `{:ok, tool_def}` or `{:error, :not_found}`.
  """
  def get_tool(name) do
    case lookup(name) do
      {:ok, {_module, meta}} -> {:ok, wire(name, meta)}
      :miss -> {:error, :not_found}
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

    Grimoire.Visibility.restrict_actions(tool_def, actions, operations)
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
  disconnects can stop it (`Grimoire.cancel_request/1`), for the wire.
  """
  def call_external(name, ctx, args, opts \\ [])

  def call_external(name, %Context{plane: :guest}, _args, _opts) do
    {:error, Error.admission({:guest_plane_call, name})}
  end

  def call_external(name, %Context{} = ctx, args, opts) when is_map(args) do
    # The plane is this function's name, never an option: a caller cannot
    # reach the in-chain arm (its consent-class and proxied-tool rules, its
    # authority) by passing what `call_in_chain/5` passes.
    do_call(name, ctx, args, Keyword.drop(opts, [:in_chain, :authority]))
  end

  def call_external(_name, %Context{}, _args, _opts),
    do: {:error, Error.admission({:invalid_argument, "Arguments must be an object"})}

  @doc """
  Call a tool from **inside a running chain** — the only entry that accepts
  an authority.

  Authorization is a conjunction, decided once, at the gate
  (`do_call/4`), in order: the calling execution's grant must still
  stand; the action must be annotated in-chain-reachable; the caller's
  own authorization applies through the guest-plane permission branch;
  the arguments must cast; and the chain's authority must grant the tool
  (or the matching tool server) through the transition relation. All of
  it runs inside the control-plane fence and the request log, so a member
  that lost its slot takes no budget, and every in-chain call writes one
  log row, a refusal included. Each refusal it makes carries
  `stage: :admission`. Guest-supplied lineage keys are discarded before
  dispatch.

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
  (a caller-owned name for this call, by which `Grimoire.cancel_call/1`
  stops the supervised handler alone), plus `call_external/4`'s
  options. The runner defaults to `:supervised` here: the handler runs on
  a guest's behalf, and a crash or a hang inside it must not take the
  chain's host process with it. A supervised handler that dies, exits or
  times out answers `{:error, {:uncertain, _}}` unless the action is
  declared `recovery: :replay_safe`: its effect may have happened.
  """
  def call_in_chain(name, ctx, args, authority, opts \\ [])

  def call_in_chain(name, %Context{} = ctx, args, %Prima.Authority{} = authority, opts)
      when is_map(args) do
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    # An outbound call is an execution of its own: its id exists before
    # the charge, so the hold names it as its holder and admission can
    # stamp the hold admitted.
    opts =
      if String.contains?(name, ":") and guest_fn == :spawn,
        do: Keyword.put_new_lazy(opts, :execution_id, &Prima.UUID7.execution_id/0),
        else: opts

    opts =
      opts
      |> Keyword.put_new(:runner, :supervised)
      |> Keyword.put(:guest_fn, guest_fn)
      |> with_charge_identity(guest_fn)
      # The authority is conjoined at the gate (`route/5`), after the
      # caller's own authorization and the arguments' cast: one decision.
      |> Keyword.put(:authority, authority)

    args =
      args
      |> Map.drop(["parent_execution_id", "root_execution_id", "thread_id", "attempt"])

    do_call(name, ctx, args, opts)
  end

  def call_in_chain(_name, %Context{}, _args, %Prima.Authority{}, _opts),
    do: {:error, Error.admission({:invalid_argument, "Arguments must be an object"})}

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
          id: Prima.UUID7.generate_id("chg"),
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
  defp hold_of(%Prima.Authority{budget: %{id: reservation_id}}, %{id: id}),
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
    |> Prima.MapUtil.put_present("parent_execution_id", Map.get(lineage, :parent_execution_id))
    |> Prima.MapUtil.put_present("root_execution_id", Map.get(lineage, :root_execution_id))
    # The attempt of the calling execution, so a provider answering the
    # caller its own payload knows which attempt's it is.
    |> Prima.MapUtil.put_present("attempt", Map.get(lineage, :attempt))
    # The thread an approved card came from — host-stamped like the
    # execution ids, so a tool that records provenance reads it from here
    # and never from what the model wrote.
    |> Prima.MapUtil.put_present("thread_id", Map.get(lineage, :thread_id))
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
  heard of (a virtual tool the formula dispatches itself, an external
  `server:tool`) is not refused here, it is simply not this
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
          Prima.Authority.Transition.tool_granted?(authority, name, action),
          do: action

    case {reachable, get_in(tool_def, ["inputSchema", "properties", "action", "enum"])} do
      {[], _} ->
        nil

      {_, listed} when is_list(listed) ->
        case Enum.filter(listed, &(&1 in reachable)) do
          [] -> nil
          ^listed -> tool_def
          pruned -> Grimoire.Visibility.restrict_actions(tool_def, pruned)
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
                Prima.Authority.Transition.external_tool_granted?(authority, digest, remote)

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
         {:ok, tools} <- Grimoire.Proxy.impl!().server_tools(ctx, grant.server_name),
         {:ok, live} <-
           Sanctum.ToolServerDigest.descriptions_digest(tools, grant.tool_patterns) do
      unless Plug.Crypto.secure_compare(live, baseline) do
        Logger.warning(
          "[Grimoire.Catalog] tool descriptions for server '#{grant.server_name}' drifted " <>
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
          "[Grimoire.Catalog] description-drift check could not run: #{inspect(reason)}"
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
        "[Grimoire.Catalog] description-drift check failed: " <>
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
  defp authorize_declared_action(name, ctx, args, in_chain?) do
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
    if Grimoire.Visibility.admits?(annotation, ctx) do
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

  # The gate. Every call, on either plane, is decided here once: the
  # caller's authorization and the arguments' cast and, for a chain's call,
  # the calling execution's standing, the authority's step and its charge —
  # inside the request log and the control-plane fence, before any handler
  # runs. A refusal made here carries `stage: :admission`; what a handler
  # or the call's own ending answers is the execution's.
  defp do_call(name, %Context{} = ctx, args, opts) when is_map(args) do
    in_chain? = match?(%Prima.Authority{}, Keyword.get(opts, :authority))
    opts = Keyword.put(opts, :in_chain, in_chain?)

    # Every call belongs to an ingress request. One that arrived over a
    # transport already carries it; an internal caller has none, so it becomes
    # its own root.
    own_root? = is_nil(ctx.request_id)
    ctx = if own_root?, do: %{ctx | request_id: Prima.UUID7.request_id()}, else: ctx

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
        in_chain? -> Prima.UUID7.generate_id("call")
        true -> ctx.request_id
      end

    action = args["action"] || args[:action]
    logged_args = if in_chain?, do: put_lineage(args, Keyword.get(opts, :lineage)), else: args
    started = %{tool: name, action: action, method: "tools/call", input: logged_args}
    opts = Keyword.put(opts, :action, action)

    Grimoire.RequestLog.around(log_mode, ctx, call_id, started, fn ->
      # A member that lost its cell slot dispatches nothing, catalogued or
      # proxied, and takes no budget: the endpoint's plug refuses new
      # requests, but a connected console, an in-process caller and a
      # running chain's next call all arrive here without passing it.
      if Arca.ControlPlane.held?() do
        route(name, ctx, args, opts, in_chain?)
      else
        {{:error, Error.admission(:control_plane_lost)}, %{}}
      end
    end)
  end

  # A chain's call: the calling execution's standing, the in-chain plane,
  # the caller's own authorization, the cast, and then the authority's
  # step on the target the cast arguments name — in that order, so a
  # refusal of any earlier conjunct takes no budget.
  defp route(name, ctx, args, opts, true = _in_chain?) do
    authority = Keyword.fetch!(opts, :authority)
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    with :ok <- lineage_standing(ctx, Keyword.get(opts, :lineage)),
         :ok <- check_in_chain_reachable(name, args),
         :ok <- authorize_declared_action(name, ctx, args, true),
         {:ok, args} <- validate_chain_arguments(name, args),
         {:ok, target, server} <- in_chain_target(ctx, name, args),
         {:ok, resource} <- authority_step(authority, guest_fn, target, name) do
      warn_on_description_drift(ctx, authority, resource)

      # The server row the transition was judged on is the one dispatch
      # speaks to — one revision per call, never a second read that a
      # change in between could answer.
      charged(name, ctx, args, authority, guest_fn, Keyword.put(opts, :server, server))
    else
      {:error, reason} -> {{:error, Error.admission(reason)}, routed(name)}
    end
  end

  defp route(name, ctx, args, opts, false = _in_chain?) do
    case lookup(name) do
      {:ok, {module, meta}} ->
        with :ok <- authorize_declared_action(name, ctx, args, false),
             {:ok, args} <- Operation.cast(meta, args) do
          dispatch(name, ctx, args, opts)
        else
          {:error, reason} ->
            {{:error, Error.admission(reason)}, %{routed_to: inspect(module)}}
        end

      :miss ->
        dispatch(name, ctx, args, opts)
    end
  end

  defp routed(name) do
    case lookup(name) do
      {:ok, {module, _meta}} -> %{routed_to: inspect(module)}
      :miss -> %{}
    end
  end

  defp authority_step(authority, guest_fn, target, name) do
    case Sanctum.Authority.step(authority, guest_fn, target) do
      {:allow_tool, resource} ->
        {:ok, resource}

      # Rendered through the vocabulary's own renderer — never `inspect`,
      # which put internal terms on the guest's wire.
      {:deny, reason} ->
        {:error, chain_denial(reason, name)}

      {:invalid, {:malformed_target, fun, tag}} ->
        {:error, "Invalid in-chain call: #{fun}/#{tag}"}
    end
  end

  defp chain_denial(reason, name) do
    "Denied by chain authority: " <>
      "#{Prima.Authority.Transition.deny_message(reason)} for '#{name}'"
  end

  # A spawn-shaped transition charged the invoke budget; this process
  # holds the slot, and the executor's wall-clock kill would skip the
  # `after` — the guard releases on :DOWN. With a charge identity the hold
  # is a row too, reclaimable past the dispatcher's own timeout.
  defp charged(name, ctx, args, authority, guest_fn, opts) do
    case charge_row(guest_fn, ctx, authority, opts) do
      :ok ->
        if guest_fn == :spawn, do: Sanctum.Authority.guard_invoke(authority)

        dispatch_opts =
          opts
          |> Keyword.put(:hold, hold_of(authority, Keyword.get(opts, :charge)))
          |> Keyword.drop([:guest_fn, :charge, :authority])

        try do
          {result, meta} = dispatch(name, ctx, args, dispatch_opts)
          {prune_in_chain_discovery(result, name, args, ctx, authority), meta}
        after
          if guest_fn == :spawn do
            Sanctum.Authority.release_invoke(authority)
            release_row(ctx, authority, opts)
          end
        end

      {:error, reason} ->
        # The slot the transition charged goes back: the row refused it.
        Sanctum.Authority.BudgetCounter.release(authority.budget)
        {{:error, Error.admission(chain_denial(reason, name))}, routed(name)}
    end
  end

  # The admitted call, run: a catalogued tool's handler, or — on a miss —
  # the proxy port for a `server:tool` name.
  defp dispatch(name, ctx, args, opts) do
    in_chain? = Keyword.fetch!(opts, :in_chain)
    args = if in_chain?, do: put_lineage(args, Keyword.get(opts, :lineage)), else: args

    case lookup(name) do
      {:ok, {module, _meta}} ->
        result =
          execute_tool_call(name, ctx, opts, fn ->
            module.handle(name, handler_input(module, ctx), args)
          end)

        {result, %{routed_to: inspect(module)}}

      :miss ->
        proxied(name, ctx, args, opts, in_chain?)
    end
  end

  defp proxied(name, ctx, args, opts, in_chain?) do
    # Try external provider for namespaced tools (e.g., "notion:create_page")
    external_result =
      if String.contains?(name, ":") and not ctx.authenticated do
        # External tools carry no per-tool requires_auth metadata; all
        # of them require authentication. The HTTP router never routes
        # unknown names here, so this guards the in-process callers
        # (FormulaHandler, LiveViews). Bare unknown names fall through
        # so they still produce "Unknown tool".
        {:error, Error.admission({:tool_auth_required, name})}
      else
        # The caller's plane rides along: proxied tools are in-chain
        # by declaration, and an external-plane call reaches one only
        # when the server row opts in — enforced where the row is in
        # hand, not left to the wiring.
        plane = if in_chain?, do: :in_chain, else: :external
        proxy = Grimoire.Proxy.impl!()

        execute_tool_call(name, ctx, opts, fn ->
          proxy.try_handle(name, ctx, args, plane,
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
        refusal = Error.admission({:unknown_tool, name})
        {{:error, refusal}, %{code: -32_601, error_text: refusal.message}}

      result ->
        {result, %{routed_to: "external:#{name}"}}
    end
  end

  # The one projection: after the gate has decided with the full context,
  # an `:actor` provider is handed the actor alone — no credential, no
  # permission set, no session reaches a handler that declared it needs
  # none.
  defp handler_input(module, ctx) do
    case Prima.Provider.context_kind(module) do
      :actor -> Context.actor(ctx)
      :context -> ctx
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
  Audit every internal provider's canonical operations and permissions.
  `Prima.Operation` validates the declaration structure; this catalog
  additionally requires each permission to be known by Sanctum.

  The taxonomy is only as good as its coverage: an unannotated action has
  no risk class and no reachability, so it cannot be reasoned about at
  either gate. The catalog runs this at boot and refuses to start on any
  finding.

  Proxied `server:tool` tools are not audited: they are no provider's
  declarations (the `mcp_servers` tool that manages the servers is, and
  is audited). They are classified as `:external` by
  `Aqua.Kinds.kind_for/2` via namespacing, and get their plane from
  `Grimoire.Proxy.default_planes/0`.

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
  Audit every provider's declared handler input
  (`c:Prima.Provider.context_kind/0`). A value outside
  `:context | :actor`, or a declaration that cannot be read, is a finding:
  the gate cannot tell what such a handler may be given, so the catalog
  refuses to boot rather than hand it the full context by default.

  Returns `:ok`, or `{:error, [%{provider: module, reason: :invalid_context_kind}]}`.
  """
  @spec audit_context_kinds([module()]) :: :ok | {:error, [map()]}
  def audit_context_kinds(providers \\ available_providers()) do
    findings =
      for module <- providers,
          not context_kind_valid?(module),
          do: %{provider: module, reason: :invalid_context_kind}

    if findings == [], do: :ok, else: {:error, findings}
  end

  defp context_kind_valid?(module) do
    Prima.Provider.context_kind(module) in [:context, :actor]
  rescue
    _ -> false
  end

  @doc """
  Audit the MCP resource surface against the operation table, so what
  `resources/list` advertises and what `resources/read` can dispatch are
  one declaration.

  The findings:

    * `:unowned_scheme` — a provider advertises a resource URI or template
      whose scheme no operation of that provider declares in
      `resource_schemes`;
    * `:unadvertised_scheme` — an operation declares a scheme its provider
      advertises no resource or template for;
    * `:scheme_declared_twice` — two operations declare one scheme, so a
      read of it could not name one gate;
    * `:malformed_resource_uri` — an advertised URI or template names no
      scheme;
    * `:tool_registered_twice` — two providers (or one, twice) declare the
      same tool name, which the catalog would otherwise overwrite silently.

  Returns `:ok` or `{:error, findings}`; the catalog refuses to boot on
  any finding.
  """
  @spec audit_resource_schemes([module()]) :: :ok | {:error, [map()]}
  def audit_resource_schemes(providers \\ available_providers()) do
    tools = for module <- providers, tool <- module.tools(), do: {module, tool}

    declared =
      for {module, tool} <- tools,
          %Operation{} = operation <- Map.get(tool, :operations, []),
          scheme <- operation.resource_schemes,
          do: {scheme, module, "#{operation.tool}.#{operation.action}"}

    {advertised, malformed} = advertised_schemes(providers)
    owned = MapSet.new(declared, fn {scheme, module, _} -> {scheme, module} end)

    findings =
      malformed ++
        for(
          {scheme, module} <- advertised,
          not MapSet.member?(owned, {scheme, module}),
          do: %{provider: module, scheme: scheme, reason: :unowned_scheme}
        ) ++
        for(
          {scheme, module, operation} <- declared,
          {scheme, module} not in advertised,
          do: %{
            provider: module,
            scheme: scheme,
            operation: operation,
            reason: :unadvertised_scheme
          }
        ) ++
        for(
          {scheme, owners} <- Enum.group_by(declared, &elem(&1, 0), &elem(&1, 2)),
          length(owners) > 1,
          do: %{scheme: scheme, operations: Enum.sort(owners), reason: :scheme_declared_twice}
        ) ++
        for(
          {name, modules} <- Enum.group_by(tools, &elem(&1, 1).name, &elem(&1, 0)),
          length(modules) > 1,
          do: %{tool: name, providers: modules, reason: :tool_registered_twice}
        )

    if findings == [], do: :ok, else: {:error, findings}
  end

  # Every `{scheme, provider}` the providers advertise, and a finding for
  # each advertised URI that names no scheme.
  defp advertised_schemes(providers) do
    entries =
      for module <- providers,
          {fun, key} <- [resources: :uri, resource_templates: :uriTemplate],
          function_exported?(module, fun, 0),
          entry <- apply(module, fun, []),
          do: {module, Map.get(entry, key) || Map.get(entry, Atom.to_string(key))}

    Enum.reduce(entries, {[], []}, fn {module, uri}, {advertised, malformed} ->
      case Prima.Provider.resource_scheme(uri) do
        {:ok, scheme} ->
          {Enum.uniq(advertised ++ [{scheme, module}]), malformed}

        :error ->
          {advertised,
           malformed ++ [%{provider: module, uri: uri, reason: :malformed_resource_uri}]}
      end
    end)
  end

  @doc """
  Every `tool.action` declared `recovery: :replay_safe`, derived from the
  declarations — the table's, or the named providers' — : the operations
  a recovered turn may still dispatch past an uncertain step. There is no
  second list.
  """
  @spec replay_safe_actions(:table | [module()]) :: [String.t()]
  def replay_safe_actions(source \\ :table) do
    source
    |> declared_tools()
    |> Enum.flat_map(fn tool ->
      tool
      |> Annotations.declared_actions()
      |> Enum.filter(fn {_verb, annotation} ->
        Annotations.recovery_of(annotation) == :replay_safe
      end)
      |> Enum.map(fn {verb, _} -> "#{tool.name}.#{verb}" end)
    end)
    |> Enum.sort()
  end

  # The tools a derivation reads: the table's, or — for an audit of
  # providers not loaded — the named providers' own declarations.
  defp declared_tools(:table), do: for({_name, {_module, tool}} <- operations(), do: tool)

  defp declared_tools(providers) when is_list(providers),
    do: Enum.flat_map(providers, & &1.tools())

  # `Operation.validate!/1` has already established that a non-nil
  # permission is an atom by the time the audit reaches this check.
  defp known_permission?(permission),
    do: Atom.to_string(permission) in Sanctum.Atoms.known_permissions()

  @doc """
  The planes an action may be annotated with.
  """
  @spec valid_planes() :: [Prima.Provider.plane()]
  defdelegate valid_planes(), to: Operation

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
        "[Grimoire.Catalog] Tool #{name} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:crashed, "Tool #{name} crashed"}}
  catch
    :exit, reason ->
      Logger.error("[Grimoire.Catalog] Tool #{name} exited: #{inspect(reason)}")
      {:error, {:exit, "Tool #{name} exited unexpectedly"}}
  end

  defp run_supervised(name, ctx, opts, execute_fn) do
    case Keyword.get(opts, :cancel_handle) do
      nil ->
        supervise(name, ctx, opts, nil, execute_fn)

      handle ->
        # Claimed before the task exists, so a cancel that lands first is
        # seen when the task registers, and the handler never runs.
        case Grimoire.RunningTasks.claim(handle) do
          :ok -> supervise(name, ctx, opts, handle, execute_fn)
          :cancelled -> {:error, {:cancelled, "Tool #{name} was cancelled"}}
        end
    end
  end

  defp supervise(name, ctx, opts, handle, execute_fn) do
    # Registered under the server-minted request id, which is also the
    # request's progress topic (`Cyfr.Bus.progress/2`) — one identity per
    # request across both subsystems. The transport cancels through this when its caller hangs up;
    # a context without one (an internal call that bypassed `do_call/4`'s
    # minting) simply is not cancellable that way — its caller cancels by
    # handle.
    request_id = ctx.request_id
    trackable? = is_binary(request_id)

    logger_metadata = Prima.LoggerContext.capture()

    task =
      Task.Supervisor.async_nolink(Grimoire.TaskSupervisor, fn ->
        Prima.LoggerContext.restore(logger_metadata)

        if handle && Grimoire.RunningTasks.register_handle(handle, self()) == :cancelled,
          do: exit(:cancelled),
          else: execute_fn.()
      end)

    if trackable?, do: Grimoire.RunningTasks.register(request_id, task)

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
            "[Grimoire.Catalog] Tool #{name} crashed: #{Exception.format(:error, exception, stacktrace)}"
          )

          # The tuple carries only the tool's name — the exception's own
          # message can hold a query, a path, or the offending bytes, and
          # this tuple renders verbatim on the wire (`Prima.Refusal.message/1`).
          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} crashed; its outcome is unknown"}},
            else: {:error, {:crashed, "Tool #{name} crashed"}}

        {:exit, :cancelled} ->
          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} was cancelled; its outcome is unknown"}},
            else: {:error, {:cancelled, "Tool #{name} was cancelled"}}

        {:exit, reason} ->
          Logger.error("[Grimoire.Catalog] Tool #{name} exited: #{inspect(reason)}")

          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} exited; its outcome is unknown"}},
            else: {:error, {:exit, "Tool #{name} exited unexpectedly"}}

        nil ->
          Logger.error("[Grimoire.Catalog] Tool #{name} timed out after #{@tool_timeout_ms}ms")

          if uncertain?,
            do: {:error, {:uncertain, "Tool #{name} timed out; its outcome is unknown"}},
            else: {:error, {:timeout, "Tool #{name} timed out after #{@tool_timeout_ms}ms"}}
      end

    if trackable?, do: Grimoire.RunningTasks.unregister(request_id, task)
    if handle, do: Grimoire.RunningTasks.release_handle(handle)
    result
  end

  defp replay_safe?(name, action) when is_binary(action) do
    case get_tool(name) do
      {:ok, tool_def} -> Grimoire.Annotations.recovery(tool_def, action) == :replay_safe
      _ -> false
    end
  end

  defp replay_safe?(_name, _action), do: false

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
          "[Grimoire.Catalog] Tool provider #{inspect(module)} not available — skipping. " <>
            "Check that the application is started and the module exists."
        )

        false
      end
    end)
  end

  @impl Sanctum.Grimoire
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
    for tool <- declared_tools(:table),
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
      for tool <- declared_tools(:table),
          {action, _annotation} <- Annotations.actions_of(tool),
          Annotations.host_intercepted?(tool, action),
          do: "#{tool.name}.#{action}"
    )
  end

  # Every `tool.action` the table holds — what a consent shape may name
  # (`Sanctum.Grimoire`).
  @impl Sanctum.Grimoire
  def tool_actions do
    for tool <- declared_tools(:table),
        {action, _annotation} <- Annotations.actions_of(tool),
        do: "#{tool.name}.#{action}"
  end

  # The external tool servers a grant may name (`Sanctum.Grimoire`). The
  # proxied `server:tool` entries are the proxy port's (`Grimoire.Proxy`),
  # so it is what describes them.
  @impl Sanctum.Grimoire
  def tool_server_candidates(%Context{} = ctx),
    do: Grimoire.Proxy.impl!().consent_candidates(ctx)

  @impl Sanctum.Grimoire
  def tool_server_candidate(%Context{} = ctx, name) when is_binary(name),
    do: Grimoire.Proxy.impl!().consent_candidate(ctx, name)

  defp loadable?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :tools, 0)
end
