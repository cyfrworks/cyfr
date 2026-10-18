# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Catalog do
  @moduledoc """
  The operation table: its load, its lookups and its boot audits.

  At boot, before any supervisor starts, `load!/0` reads every provider
  configured under `:sanctum, :tool_providers`, audits its declarations and
  writes the table into the gate's own `:persistent_term`: the table
  itself (`{Sanctum.Gate, :operations}`, tool name → `{provider, tool}`), the
  sorted wire list `tools/list` serves (`{Sanctum.Gate, :tool_list}`), the
  stream table (`{Sanctum.Gate, :streams}`, stream name → `{provider, stream}`,
  from each provider's `Prima.Provider.streams/1`) and, through
  `Sanctum.Resources`, the resource URI index (`{Sanctum.Gate, :resources}`). The term is this member's, written once;
  nothing refreshes, rebuilds or invalidates it, and a process that dies
  takes none of it along. Every lookup and every action enumeration reads
  it. The proxied `server:tool` tools are no provider's declarations and
  are not in it: they are the tenant's, cached per athanor by the proxy
  port (`Sanctum.Proxy`).

  Consent reads the table here: shape derivation asks which `tool.action`
  pairs it serves (`tool_actions/0`), and the standing rule what one action
  is (`action_declaration/1`). Before `load!/0` has written the table,
  every read of it here raises `Sanctum.Catalog.NotLoadedError` rather
  than answering a narrower roster: a shape derived from no table at all
  would grant nothing and read as a component that asks for nothing.

  Callers outside the gate are admitted through `Sanctum.Gate`, whose
  dispatching entries `Sanctum.Dispatch` implements over this table, and
  read the table here. This module dispatches nothing.

  ## Usage

      Sanctum.Catalog.list_tools()
      Sanctum.Gate.call_external("retention", context, %{"action" => "get"})

  """

  require Logger

  alias Sanctum.Annotations
  alias Prima.Operation
  alias Sanctum.Context

  defmodule NotLoadedError do
    @moduledoc """
    Raised by every read of the operation table before `Sanctum.Catalog.load!/0`
    has written it. An unloaded table is not an empty one: nothing can say
    which actions exist, and nothing guesses.
    """

    defexception message:
                   "the operation table is not loaded: nothing called " <>
                     "Sanctum.Catalog.load!/0. Nothing can read the table until boot loads it."
  end

  @typedoc """
  What one `tool.action` is, as the standing rule reads it: its `kind`,
  its `standing` declaration (`:thread`, `false`, or nil for either
  scope) and its `resource`, the argument that names the resource the
  action touches with that resource's kind (`Prima.Operation`'s
  `resource:`), or nil when it declares none.
  """
  @type action_declaration :: %{
          kind: atom(),
          standing: term(),
          resource: {String.t(), Prima.Operation.resource_kind()} | nil
        }

  # The operation table's three terms. `Sanctum.Resources` holds the fourth.
  @operations {Sanctum.Gate, :operations}
  @tool_list {Sanctum.Gate, :tool_list}
  @streams {Sanctum.Gate, :streams}

  # What a stream open is judged by: the default an action declares
  # nothing beyond — a read, on the external plane, for a signed-in,
  # claimed caller, with no permission, consent class or scope.
  @stream_annotation %{kind: :read, planes: [:external]}

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
  table would read as the whole. Under test only, a run without the
  sibling applications (one application's tests) says so with
  `:tool_providers_lenient`, and each such provider is skipped with its
  reason logged; a build for any other environment compiles neither that
  setting's read nor `with_providers/2`. An action the
  gates cannot classify, an in-chain action that does not say what its
  answers carry, a handler input the gate cannot honour, and a resource
  read the gate cannot name refuse the boot the same way.
  """
  @spec load!() :: :ok
  def load! do
    configured_providers()
    |> loadable_roster!()
    |> install!()
  end

  # The test seams: a planted provider, a lenient roster and a read hook.
  # All three are compiled into the test build alone, so no setting of a
  # release can narrow its table, skip a provider it cannot load or run
  # anything on a read.
  if Mix.env() == :test do
    # The resource index's term, which `Sanctum.Resources` writes only
    # through a load: a block run on an unloaded table erases it by its key.
    @resources {Sanctum.Gate, :resources}

    # The read hook's slot in the process dictionary of the process holding it.
    @read_hook {__MODULE__, :read_hook}

    @doc false
    # The table for a block, then the table as it was. A test that plants a
    # probe provider runs it through here, synchronously (`async: false`):
    # the planted providers join the configured roster, pass the same audits
    # as a booted provider, and are gone when the block returns, however it
    # returns. A table nothing had loaded, as in the Sanctum island's suites,
    # is unloaded again.
    @spec with_providers([module()], (-> result)) :: result when result: term()
    def with_providers(providers, fun) when is_list(providers) and is_function(fun, 0) do
      for provider <- providers, not loadable?(provider) do
        raise ArgumentError,
              "#{inspect(provider)} is not a provider: it does not export tools/0"
      end

      saved = saved_table()

      try do
        configured_providers()
        |> loadable_roster!()
        |> Enum.concat(providers)
        |> Enum.uniq()
        |> install!()

        fun.()
      after
        restore_table(saved)
      end
    end

    defp saved_table do
      case :persistent_term.get(@operations, nil) do
        nil ->
          :not_loaded

        operations ->
          {operations, table!(@tool_list), table!(@streams), Sanctum.Resources.table()}
      end
    end

    defp restore_table(:not_loaded) do
      for key <- [@operations, @tool_list, @streams, @resources], do: :persistent_term.erase(key)
      :ok
    end

    defp restore_table({operations, tool_list, streams, resources}) do
      :persistent_term.put(@operations, operations)
      :persistent_term.put(@tool_list, tool_list)
      :persistent_term.put(@streams, streams)
      Sanctum.Resources.put(resources)
    end

    @doc false
    # Runs `fun` with `hook` called just before each read of the action
    # roster (`tool_actions/0`) made by this process or by a process started
    # on its behalf (one whose `$callers` names it), then removes the hook
    # however `fun` returns. A test counts those reads with it and moves
    # state between two of them. The hook is held in the holding process's
    # own dictionary, so no other test's reads reach it; one that keeps
    # state keeps it where every reading process can reach it.
    @spec with_read_hook((-> term()), (-> result)) :: result when result: term()
    def with_read_hook(hook, fun) when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.put(@read_hook, hook)

      try do
        fun.()
      after
        if previous,
          do: Process.put(@read_hook, previous),
          else: Process.delete(@read_hook)
      end
    end

    defp read_hook do
      case Process.get(@read_hook) || Enum.find_value(callers(), &held_hook/1) do
        nil -> :ok
        hook -> hook.()
      end
    end

    defp callers, do: Process.get(:"$callers", [])

    defp held_hook(pid) when is_pid(pid) do
      with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
           {@read_hook, hook} <- List.keyfind(dictionary, @read_hook, 0) do
        hook
      else
        _none -> nil
      end
    end

    defp held_hook(_name), do: nil

    # The roster without the configured providers that cannot load: a
    # refusal, or — leniently — each skipped with its reason.
    @spec without_unloadable!([module()], [module()]) :: [module()]
    defp without_unloadable!(configured, missing) do
      unless Application.get_env(:sanctum, :tool_providers_lenient, false),
        do: refuse_unloadable!(missing)

      for module <- missing do
        Logger.warning(
          "[Sanctum.Catalog] tool provider #{inspect(module)} skipped (lenient): " <>
            unloadable_reason(module)
        )
      end

      configured -- missing
    end

    defp unloadable_reason(module) do
      if Code.ensure_loaded?(module),
        do: "it does not export tools/0",
        else: "the module is not available"
    end
  else
    @spec without_unloadable!([module()], [module()]) :: no_return()
    defp without_unloadable!(_configured, missing), do: refuse_unloadable!(missing)

    defp read_hook, do: :ok
  end

  # The configured providers this boot can load. One that cannot refuses
  # the boot, the test build's lenient skip aside.
  defp loadable_roster!(configured) do
    case Enum.reject(configured, &loadable?/1) do
      [] -> configured
      missing -> without_unloadable!(configured, missing)
    end
  end

  @spec refuse_unloadable!([module()]) :: no_return()
  defp refuse_unloadable!(missing) do
    raise "configured tool providers failed to load: #{inspect(missing)} — " <>
            "a catalog missing a provider narrows every consent digest; refusing to boot"
  end

  defp install!(providers) do
    audit!(audit_action_kinds(providers), "tool annotations failed the catalog audit", fn f ->
      "#{f.tool}.#{f.action}: #{f.reason}"
    end)

    audit!(
      audit_sources(providers),
      "in-chain actions failed the catalog's sources audit",
      fn f ->
        "#{f.tool}.#{f.action}: #{f.reason}"
      end
    )

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

    streams = stream_table!(providers)

    operations =
      for module <- providers, tool <- module.tools(), into: %{} do
        {tool.name, {module, canonical(tool)}}
      end

    :persistent_term.put(@operations, operations)
    :persistent_term.put(@tool_list, wire_list(operations))
    :persistent_term.put(@streams, streams)
    Sanctum.Resources.put(Sanctum.Resources.build(providers))

    Logger.info(
      "[Sanctum.Catalog] loaded #{map_size(operations)} tools from #{length(providers)} providers"
    )

    :ok
  end

  # Every provider's declared streams, by name. A declaration
  # `Prima.Provider.streams/1` refuses, or one name two providers declare,
  # refuses the boot: an open names a stream, and a name that could mean
  # either would let one provider's grammar and bound admit the other's.
  defp stream_table!(providers) do
    declared =
      for module <- providers,
          stream <- declared_streams!(module),
          do: {stream.name, {module, stream}}

    audit!(
      case for {name, entries} <- Enum.group_by(declared, &elem(&1, 0), &elem(elem(&1, 1), 0)),
               length(entries) > 1,
               do: %{stream: name, providers: entries} do
        [] -> :ok
        findings -> {:error, findings}
      end,
      "stream declarations failed the catalog audit",
      &"#{&1.stream}: declared by #{inspect(&1.providers)}"
    )

    Map.new(declared)
  end

  defp declared_streams!(module) do
    Prima.Provider.streams(module)
  rescue
    exception in ArgumentError ->
      reraise "stream declarations failed the catalog audit; refusing to boot:\n  - " <>
                Exception.message(exception),
              __STACKTRACE__
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

  # The one read of the table's terms. An unloaded table raises
  # `NotLoadedError`, never `:persistent_term`'s bare `ArgumentError`, and
  # never answers as an empty table.
  defp table!(key) do
    case :persistent_term.get(key, nil) do
      nil -> raise NotLoadedError
      term -> term
    end
  end

  @doc """
  The operation table: tool name → `{provider, tool}`. Raises
  `Sanctum.Catalog.NotLoadedError` before `load!/0` has written it, as every
  read of the table below does.
  """
  @spec operations() :: %{String.t() => {module(), map()}}
  def operations, do: table!(@operations)

  @doc """
  Every tool the table holds, as `tools/list` serves it, sorted by name.
  """
  @spec list_tools() :: [map()]
  def list_tools, do: table!(@tool_list)

  @doc """
  Every stream the providers declare, as plain data sorted by name: what
  a tincture's declaration is checked against
  (`Compendium.Tincture.Rules.check_streams/2`) and what an open names.
  """
  @spec streams() :: [Prima.Provider.Stream.t()]
  def streams do
    table!(@streams)
    |> Enum.map(fn {_name, {_module, stream}} -> stream end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Every declared stream with the provider that declares it, sorted by
  name: what the host's boot check reads to name a stream's provider.
  """
  @spec stream_entries() :: [{module(), Prima.Provider.Stream.t()}]
  def stream_entries do
    table!(@streams)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_name, entry} -> entry end)
  end

  @doc "A stream's provider and its declaration, from the table."
  @spec lookup_stream(String.t()) :: {:ok, {module(), Prima.Provider.Stream.t()}} | :miss
  def lookup_stream(name) when is_binary(name) do
    case table!(@streams) do
      %{^name => entry} -> {:ok, entry}
      _ -> :miss
    end
  end

  @doc """
  The gate's authorization of a stream open, as an action with no
  declaration beyond the default is authorized (`@stream_annotation`):
  the same predicate (`Sanctum.Visibility.authorize/4`), on the external
  plane. `name` is the operation name the refusal carries.
  """
  @spec authorize_stream(String.t(), Context.t()) ::
          :ok | {:error, Sanctum.Unauthorized.reason()}
  def authorize_stream(name, %Context{} = ctx) when is_binary(name),
    do: Sanctum.Visibility.authorize(name, @stream_annotation, ctx, false)

  @doc """
  Prune a tools/list payload to the in-chain *plane*: actions whose plane
  annotation includes `:in_chain`. Proxied `server:tool` entries are
  in-chain by wiring and pass through whole; anything without an
  annotation fails closed, mirroring `Sanctum.Gate.call_in_chain/5`.

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
  What `tool.action` is, for every caller that classifies an action: a
  virtual hand's kind from `Sanctum.VirtualTools`; `:external` for an
  upstream `server:tool`, which is namespaced and enumerates no verbs,
  whatever the action; otherwise the catalogued tool's declared kind. No
  default: an unknown tool or an undeclared action is nil, a visible gap.
  """
  @spec tool_kind(String.t(), String.t()) :: atom() | nil
  def tool_kind(tool, action) when is_binary(tool) and is_binary(action) do
    cond do
      kind = Sanctum.VirtualTools.kind_for(tool, action) ->
        kind

      String.contains?(tool, ":") ->
        :external

      true ->
        case get_tool(tool) do
          {:ok, tool_def} -> Annotations.kind(tool_def, action)
          {:error, :not_found} -> nil
        end
    end
  end

  def tool_kind(_tool, _action), do: nil

  @doc """
  The action verbs a tool has — a virtual hand's from `Sanctum.VirtualTools`,
  a catalogued tool's `action` enum in declared order — and `[]` for a
  tool neither holds. What a `tool.*` glob stands for.
  """
  @spec tool_actions(String.t()) :: [String.t()]
  def tool_actions(tool) when is_binary(tool) do
    if Sanctum.VirtualTools.tool?(tool) do
      Sanctum.VirtualTools.actions_of(tool)
    else
      with {:ok, tool_def} <- get_tool(tool),
           verbs when is_list(verbs) <-
             get_in(tool_def, ["inputSchema", "properties", "action", "enum"]) do
        Enum.filter(verbs, &is_binary/1)
      else
        _ -> []
      end
    end
  end

  def tool_actions(_tool), do: []

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

    Sanctum.Visibility.restrict_actions(tool_def, actions, operations)
  end

  @doc """
  Whether a running chain can reach `tool.action` at all.

  An action reachable in-chain says so in its plane annotation; one without
  an annotation, or without `:in_chain`, fails closed. Proxied `server:tool`
  names are the `:external` bucket, in-chain by wiring.

  This is the same predicate `Sanctum.Gate.call_in_chain/5` enforces per
  call, exposed so the surfaces that *offer* actions — the agent capability matrix, the
  prompt's approval section, proposal validation — offer only what the chain
  could actually run, instead of handing someone a button that fails.
  """
  @spec in_chain_reachable?(String.t(), String.t() | nil) :: boolean()
  def in_chain_reachable?(name, action) when is_binary(name) do
    match?(:ok, in_chain_reachability(name, %{"action" => action}))
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

  @doc """
  `in_chain_reachable?/2` with its reason: `:ok`, or the refusal reason
  `Sanctum.Gate.call_in_chain/5` records for a name or action a running
  chain cannot reach. `args` are the call's arguments, whose `action`
  names the action.
  """
  @spec in_chain_reachability(String.t(), map()) :: :ok | {:error, term()}
  def in_chain_reachability(name, args) do
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

  @doc false
  # The dispatch gate: enforce the action's access annotation before the
  # handler runs — a declared action on the caller's plane, then auth,
  # scope, permission and consent through the predicate discovery asks
  # too (`Sanctum.Visibility.authorize/4`). Handlers keep only the
  # residual checks the annotation cannot express (tenant presence,
  # ownership, definition authority, the domain's finer consent arms).
  # Public solely so the discovery-parity test can ask the exact question
  # dispatch answers without executing any handler.
  @spec authorize_annotated_action(String.t(), map(), Context.t(), map(), boolean()) ::
          :ok
          | {:error,
             Sanctum.Unauthorized.reason()
             | :action_missing
             | {:unknown_action, String.t()}
             | Prima.Refusal.t()}
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
        with :ok <- Sanctum.Visibility.authorize(name, annotation, ctx, in_chain?),
             do: reserve_admits(name, meta, action, ctx, args)
    end
  end

  # Below the storage reserve's mark (`Arca.StorageReserve`) the gate
  # admits only what spends no reserve or takes authority away: a read, an
  # action declared `reduces_authority`, and, for such an action's request
  # alone, the confirmation that completes it. `confirmation.pending` is a
  # read and answers then only the caller's records of such actions
  # (`Sanctum.Providers.Confirmation`), so a client that reconnects finds
  # a revocation waiting on it; with a `request` it names one of those. A
  # proof, a re-authentication and a cancel are admitted only by a `ref`
  # naming one, so no other request's record is proven or spent. A
  # reference that names no record of the caller's, or a record of an
  # action not declared so, is refused alike.
  defp reserve_admits(name, meta, action, ctx, args) do
    if Arca.StorageReserve.depleted?(),
      do: depleted_admits(name, declared_operation(meta, action), ctx, args),
      else: :ok
  end

  defp depleted_admits("confirmation", _operation, ctx, args) do
    case {args["action"] || args[:action], args["request"] || args[:request]} do
      {"pending", nil} -> :ok
      {"pending", request} -> flagged_admits(ctx, request)
      {_proof_or_cancel, _request} -> flagged_admits(ctx, args["ref"] || args[:ref])
    end
  end

  defp depleted_admits(_name, %Operation{reduces_authority: true}, _ctx, _args), do: :ok
  defp depleted_admits(_name, %Operation{kind: :read}, _ctx, _args), do: :ok
  defp depleted_admits(_name, _operation, _ctx, _args), do: {:error, reserve_refusal()}

  defp declared_operation(%{operations: operations}, action),
    do: Enum.find(operations, &(&1.action == action))

  defp declared_operation(_meta, _action), do: nil

  # The caller's own pending record under `reference`, in the athanor in
  # focus, asked by an action declared `reduces_authority`.
  defp flagged_request?(%Context{user_id: user_id, athanor_id: athanor_id} = ctx, reference)
       when is_binary(reference) and reference != "" and is_binary(user_id) and user_id != "" and
              is_binary(athanor_id) and athanor_id != "" do
    case Arca.PendingConfirmations.get(Context.actor(ctx), reference) do
      {:ok, %{user_id: ^user_id, operation: operation}} -> reduces_authority?(operation)
      _absent_another_or_unanswered -> false
    end
  end

  defp flagged_request?(_ctx, _reference), do: false

  defp flagged_admits(ctx, reference),
    do: if(flagged_request?(ctx, reference), do: :ok, else: {:error, reserve_refusal()})

  defp reserve_refusal, do: Prima.Refusal.classify(Arca.StorageReserve.refusal())

  @doc """
  The admission under the storage reserve of a write the table declares
  no operation for: a proxied `server:tool` call (`Sanctum.Dispatch`) and
  the person's seal (`Sanctum.Seal`). None is a read or takes authority
  away, so while the reserve is depleted each is refused as every other
  such operation is, before anything is written.
  """
  @spec undeclared_write_admission() :: :ok | {:error, Prima.Refusal.t()}
  def undeclared_write_admission do
    if Arca.StorageReserve.depleted?(), do: {:error, reserve_refusal()}, else: :ok
  end

  @doc """
  Whether the table declares the action `name` (`tool.action`)
  `reduces_authority` (`Prima.Operation`): one of the few the gate admits
  while the storage reserve is depleted. False for a name the table does
  not hold.
  """
  @spec reduces_authority?(String.t()) :: boolean()
  def reduces_authority?(name) when is_binary(name) do
    with {tool, action} <- split_action(name),
         {:ok, {_module, meta}} <- lookup(tool),
         %Operation{reduces_authority: true} <- declared_operation(meta, action) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Whether an admitted call of `tool.action` is recorded by the decision
  audit (`Sanctum.Decisions`): false for an action the table declares
  `recorded: false` (`Prima.Operation`), which only a read may be; true
  for every other, an action the table does not hold among them.
  """
  @spec recorded?(term(), term()) :: boolean()
  def recorded?(tool, action) when is_binary(tool) and is_binary(action) do
    with {:ok, {_module, meta}} <- lookup(tool),
         %Operation{recorded: false} <- declared_operation(meta, action) do
      false
    else
      _ -> true
    end
  end

  def recorded?(_tool, _action), do: true

  # An action name holds no dot, so a pair splits at the last one.
  defp split_action(name) do
    case String.split(name, ".") do
      [_, _ | _] = parts ->
        {tool, [action]} = Enum.split(parts, -1)
        {Enum.join(tool, "."), action}

      _ ->
        :error
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
  `tool_kind/2` via namespacing, and get their plane from
  `Sanctum.Proxy.default_planes/0`.

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
  Audit every provider's in-chain actions for a `sources:` declaration
  (`Prima.Operation`). What a chain's call answers joins the run's ledger,
  and what an assistant's call answers joins its turn, as that
  declaration says (`Prima.Operation.result_sources/3`), and an action
  that declares none is read as outside material: a read of the
  athanor's own records would mark every run and turn that makes it, and
  every standing approval would ask again. So each in-chain action says
  what its answers carry — `[]` for the athanor's own, `[:outside]` or an
  answer reader for what reaches outside — and the catalog refuses to
  boot on an omission, as it does on an unannotated action. An action
  served only outside a chain joins no ledger and is not audited.

  Returns `:ok`, or `{:error, [%{provider: module, tool: name, action:
  verb, reason: :undeclared_sources}]}`.
  """
  @spec audit_sources([module()]) :: :ok | {:error, [map()]}
  def audit_sources(providers \\ available_providers()) do
    findings =
      for module <- providers,
          %{name: name, operations: operations} when is_list(operations) <- module.tools(),
          %Operation{sources: nil, planes: planes, action: action} <- operations,
          :in_chain in planes,
          do: %{provider: module, tool: name, action: action, reason: :undeclared_sources}

    if findings == [], do: :ok, else: {:error, findings}
  end

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

  # The tools a derivation reads: the table's.
  defp declared_tools, do: for({_name, {_module, tool}} <- operations(), do: tool)

  # `Operation.validate!/1` has already established that a non-nil
  # permission is an atom by the time the audit reaches this check.
  defp known_permission?(permission),
    do: Atom.to_string(permission) in Sanctum.Atoms.known_permissions()

  @doc """
  The planes an action may be annotated with.
  """
  @spec valid_planes() :: [Prima.Provider.plane()]
  defdelegate valid_planes(), to: Operation

  @doc """
  Every provider named in config, loaded or not. The status roster reads
  this set, so a configured provider that failed to load is reported as
  such rather than silently absent.

  The single reader of `:sanctum, :tool_providers` — config always sets the
  key, so the default is an empty list, never a hidden second roster.
  """
  @spec configured_providers() :: [module()]
  def configured_providers, do: Application.get_env(:sanctum, :tool_providers, [])

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
          "[Sanctum.Catalog] Tool provider #{inspect(module)} not available — skipping. " <>
            "Check that the application is started and the module exists."
        )

        false
      end
    end)
  end

  @doc """
  Every `tool.action` served outside a running chain: the declared
  actions whose planes include `:external`.
  """
  @spec external_tool_actions() :: [String.t()]
  def external_tool_actions do
    for tool <- declared_tools(),
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
      for tool <- declared_tools(),
          {action, _annotation} <- Annotations.actions_of(tool),
          Annotations.host_intercepted?(tool, action),
          do: "#{tool.name}.#{action}"
    )
  end

  @doc """
  Every `tool.action` the table holds, from its loaded providers: what a
  consent shape may name.
  """
  @spec tool_actions() :: [String.t()]
  def tool_actions do
    read_hook()

    for tool <- declared_tools(),
        {action, _annotation} <- Annotations.actions_of(tool),
        do: "#{tool.name}.#{action}"
  end

  @doc """
  One `tool.action` as the standing rule reads it, by its name, classified
  as `tool_kind/2` classifies it: a virtual hand from its table, an
  upstream `server:tool` as external (it declares no standing and names no
  resource), a catalogued action from its operation. An action name holds
  no dot, so the pair splits at the last one, and a server's tool name
  keeps any dot of its own. `{:error, :not_found}` for a pair nothing
  declares.
  """
  @spec action_declaration(String.t()) :: {:ok, action_declaration()} | {:error, :not_found}
  def action_declaration(name) when is_binary(name) do
    case String.split(name, ".") do
      [_, _ | _] = parts ->
        {tool, [action]} = Enum.split(parts, -1)
        declaration(Enum.join(tool, "."), action)

      _ ->
        {:error, :not_found}
    end
  end

  defp declaration(tool, action) when tool == "" or action == "", do: {:error, :not_found}

  defp declaration(tool, action) do
    cond do
      Sanctum.VirtualTools.tool?(tool) ->
        case Sanctum.VirtualTools.action(tool, action) do
          %{kind: kind} = declared ->
            {:ok, %{kind: kind, standing: nil, resource: Map.get(declared, :resource)}}

          nil ->
            {:error, :not_found}
        end

      String.contains?(tool, ":") ->
        {:ok, %{kind: :external, standing: nil, resource: nil}}

      true ->
        with {:ok, {_module, %{operations: operations}}} <- lookup(tool),
             %Operation{} = operation <- Enum.find(operations, &(&1.action == action)) do
          {:ok,
           %{kind: operation.kind, standing: operation.standing, resource: operation.resource}}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp loadable?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :tools, 0)
end
