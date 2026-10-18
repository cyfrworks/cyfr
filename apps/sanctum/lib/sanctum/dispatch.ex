# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Dispatch do
  @moduledoc """
  The gate's dispatch: the two entries `Sanctum.Gate` delegates to, the
  admission each call passes, and the run of the admitted handler.

  `call_external/4` and `call_in_chain/5` are reached only through
  `Sanctum.Gate`, the one admission entry; this module is not on
  Sanctum's exports, and nothing outside Sanctum names it. It reads the
  operation table through `Sanctum.Catalog`, which holds the table, its
  load, its lookups and its boot audits and dispatches nothing.

  ## One node, honestly

  The gate routes calls within the local node.

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
  the handler receive its input, projected once in `dispatch/4`'s handler
  closure: a provider declaring `context_kind: :actor`
  (`Prima.Provider.context_kind/1`) is given `Sanctum.Context.actor/1`
  of that context and nothing else, on either plane; every other provider
  is given the context. The boot audit refuses a provider that declares
  anything else.

  ## How a handler runs

  An admitted handler runs inline on the caller's process or supervised
  under `Sanctum.Gate.TaskSupervisor` with a timeout, registered with
  `Sanctum.RunningTasks` so a cancel stops it (`call_external/4`'s
  `:runner`).

  ## A handler that does not answer

  A handler that raises, exits, times out or is cancelled once it may
  have run answers `{:error, {:uncertain, _}}` on either plane and under
  either runner, unless its action is declared `recovery: :replay_safe`:
  an effect it made before it stopped is not undone by its stopping, so
  its caller learns the outcome is unknown, never that it failed. A
  replay-safe action answers the ordinary `:crashed`, `:exit`, `:timeout`
  or `:cancelled`, as does a call cancelled before its handler started,
  and a raised authorization refusal is the refusal it is.
  """

  require Logger

  alias Sanctum.Annotations
  alias Sanctum.Catalog
  alias Sanctum.Refusals
  alias Prima.Operation
  alias Sanctum.Context

  # Default tool execution timeout (5 minutes)
  @tool_timeout_ms :timer.minutes(5)

  # The exit of a supervised task whose registration was refused: its
  # handler never ran.
  @not_started {__MODULE__, :not_started}

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
  disconnects can stop it (`Sanctum.RunningTasks.cancel/1`), for the wire.

  Every call is one admission decision (`Sanctum.Decisions`), recorded
  under `opts[:call_id]` — a `call_` id an entry minted before its own
  checks — or, without one, an id the gate mints before its first check.
  `opts[:method]` names the wire method the call's request-log row
  records (default `"tools/call"`).
  """
  def call_external(name, ctx, args, opts \\ [])

  def call_external(name, %Context{plane: :guest} = ctx, _args, opts) do
    head_refused(name, ctx, opts, :external, Refusals.admission({:guest_plane_call, name}))
  end

  def call_external(name, %Context{} = ctx, args, opts) when is_map(args) do
    # The plane is this function's name, never an option: a caller cannot
    # reach the in-chain arm (its consent-class and proxied-tool rules, its
    # authority) by passing what `call_in_chain/5` passes.
    do_call(name, ctx, args, Keyword.drop(opts, [:in_chain, :authority]))
  end

  def call_external(name, %Context{} = ctx, _args, opts),
    do: head_refused(name, ctx, opts, :external, not_an_object())

  @doc """
  Call a tool from **inside a running chain** — the only entry that accepts
  an authority.

  Authorization is a conjunction, decided once, at the gate
  (`do_call/4`), in order: the calling execution's grant must still
  stand; the action must be annotated in-chain-reachable; the caller's
  own authorization applies through the guest-plane permission branch;
  the arguments must cast; and the chain's authority must grant the tool
  (or the matching tool server) through the transition relation. All of
  it runs inside the control-plane fence, so a member that lost its slot
  takes no budget, and every in-chain call is recorded as one admission
  decision, a refusal included, whose parent call is `opts[:lineage]`'s
  `call_id` — the call that admitted the calling execution. Each refusal
  it makes carries `stage: :admission`. Guest-supplied lineage and call
  keys are discarded before dispatch.

  The grant is the one the calling execution's attempt stores, found by
  the host-stamped `opts[:lineage]`: its `attempt` must be an open attempt
  of its `parent_execution_id` in the caller's athanor, and the grant it
  stores must stand (`Sanctum.ExecutionStanding.verify/1`). Absent or
  mismatched lineage, or a grant whose athanor was archived, admits nothing;
  nothing in `args` can supply it. The discovery predicates
  (`Sanctum.Catalog.in_chain_view/1`,
  `Sanctum.Catalog.in_chain_reachable?/2`) read no lineage and admit no
  call.

  A `:spawn`-shaped call charges the root invoke budget inside the
  transition step and releases it when the synchronous dispatch returns.

  Options: `:guest_fn` (`:call` | `:spawn`, default `:call`), `:cancel_handle`
  (a caller-owned name for this call, by which `Sanctum.RunningTasks.cancel_handle/1`
  stops the supervised handler alone), plus `call_external/4`'s
  options. The runner defaults to `:supervised` here: the handler runs on
  a guest's behalf, and a crash or a hang inside it must not take the
  chain's host process with it. A handler that does not answer is
  answered as on the external plane (the moduledoc's "A handler that
  does not answer").
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
      Map.drop(args, [
        "parent_execution_id",
        "root_execution_id",
        "thread_id",
        "attempt",
        "call_id",
        "parent_call_id"
      ])

    do_call(name, ctx, args, opts)
  end

  def call_in_chain(name, %Context{} = ctx, _args, %Prima.Authority{}, opts),
    do: head_refused(name, ctx, opts, :in_chain, not_an_object())

  defp not_an_object, do: Refusals.admission({:invalid_argument, "Arguments must be an object"})

  # A refusal at the entry's head — a guest plane, arguments that are not
  # an object — made before `do_call/4` and its identity: recorded as the
  # gate records every refusal, under the entry's call id or a fresh one,
  # on the head's plane, with a request-log row when the caller has an
  # athanor. The refusal is the answer either way.
  defp head_refused(name, %Context{} = ctx, opts, plane, %Prima.Refusal{} = refusal) do
    # An internal caller with no ingress request is its own root, as in
    # `do_call/4`.
    decision =
      Sanctum.Decisions.refused(ctx, refusal,
        call_id: Keyword.get(opts, :call_id),
        request_id: ctx.request_id || Prima.UUID7.request_id(),
        plane: plane,
        parent_call_id: if(plane == :in_chain, do: parent_call_id(Keyword.get(opts, :lineage))),
        tool: name
      )

    Sanctum.Decisions.open(ctx, decision, %{
      method: Keyword.get(opts, :method) || "tools/call",
      input: %{}
    })

    {:error, refusal}
  end

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
          pruned -> Sanctum.Visibility.restrict_actions(tool_def, pruned)
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
         {:ok, tools} <- Sanctum.Proxy.impl!().server_tools(ctx, grant.server_name),
         {:ok, live} <-
           Sanctum.ToolServerDigest.descriptions_digest(tools, grant.tool_patterns) do
      unless Plug.Crypto.secure_compare(live, baseline) do
        Logger.warning(
          "[Sanctum.Dispatch] tool descriptions for server '#{grant.server_name}' drifted " <>
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
          "[Sanctum.Dispatch] description-drift check could not run: #{inspect(reason)}"
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
        "[Sanctum.Dispatch] description-drift check failed: " <>
          Prima.LogFilter.format_exception(:error, e, __STACKTRACE__)
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

  # A declared action is authorized before its remaining fields are
  # validated. Missing or unknown action identity stays a cast error so
  # every ingress reports the same refusal. Remote `server:tool` names
  # keep their existing proxied authorization, and while the storage
  # reserve is depleted an authenticated caller's are refused here, before
  # any budget is taken, as every operation that is no read and takes no
  # authority away is (`Sanctum.Catalog.undeclared_write_admission/0`); an
  # unauthenticated caller is still refused for that first.
  defp authorize_declared_action(name, ctx, args, in_chain?) do
    if String.contains?(name, ":") do
      if ctx.authenticated, do: Catalog.undeclared_write_admission(), else: :ok
    else
      case Catalog.lookup(name) do
        {:ok, {_module, meta}} -> authorize_declared_action(name, meta, ctx, args, in_chain?)
        :miss -> :ok
      end
    end
  end

  defp authorize_declared_action(name, meta, ctx, args, in_chain?) when is_map(meta) do
    action = args["action"] || args[:action]

    if is_binary(action) and match?(%{}, Annotations.annotation(meta, action)) do
      Catalog.authorize_annotated_action(name, meta, ctx, args, in_chain?)
    else
      :ok
    end
  end

  # Remote tools carry their own schemas and are not local operation providers.
  defp validate_chain_arguments(name, args) do
    if String.contains?(name, ":"), do: {:ok, args}, else: Catalog.validate_arguments(name, args)
  end

  # The gate. Every call, on either plane, is decided here once: the
  # caller's authorization and the arguments' cast and, for a chain's call,
  # the calling execution's standing, the authority's step and its charge —
  # inside the control-plane fence, before any handler runs. A refusal
  # made here carries `stage: :admission`; what a handler or the call's
  # own ending answers is the execution's.
  #
  # Each decision is recorded once (`Sanctum.Decisions`): a refusal where
  # it is made, an admission after the last check and before the work
  # runs, and the admitted work's completion on this process once it
  # returns. The call's identity exists before the first check.
  defp do_call(name, %Context{} = ctx, args, opts) when is_map(args) do
    call_id = call_id!(Keyword.get(opts, :call_id))
    inserted_at = DateTime.utc_now()

    in_chain? = match?(%Prima.Authority{}, Keyword.get(opts, :authority))
    opts = Keyword.put(opts, :in_chain, in_chain?)

    # Every call belongs to an ingress request. One that arrived over a
    # transport already carries it; an internal caller has none, so it becomes
    # its own root. The handler is handed the admission it runs inside.
    ctx = if is_nil(ctx.request_id), do: %{ctx | request_id: Prima.UUID7.request_id()}, else: ctx
    ctx = %{ctx | call_id: call_id}

    action = args["action"] || args[:action]
    # The request log never holds an argument's bulk content, only its
    # size and digest (`Sanctum.Catalog.logged_input/2`).
    logged_args = Catalog.logged_input(name, args)

    logged_args =
      if in_chain?, do: put_lineage(logged_args, Keyword.get(opts, :lineage)), else: logged_args

    audit = %{
      ctx: ctx,
      call_id: call_id,
      parent_call_id: if(in_chain?, do: parent_call_id(Keyword.get(opts, :lineage))),
      plane: if(in_chain?, do: :in_chain, else: :external),
      tool: bounded(name),
      name: name,
      inserted_at: inserted_at,
      recorded?: Sanctum.Catalog.recorded?(name, action),
      projection: %{method: Keyword.get(opts, :method) || "tools/call", input: logged_args}
    }

    opts = opts |> Keyword.put(:action, action) |> Keyword.put(:audit, audit)

    # A member that lost its cell slot dispatches nothing, catalogued or
    # proxied, and takes no budget: the endpoint's plug refuses new
    # requests, but a connected console, an in-process caller and a
    # running chain's next call all arrive here without passing it.
    outcome =
      if Arca.ControlPlane.held?(),
        do: route(name, ctx, args, opts, in_chain?),
        else: refused(opts, args, Refusals.admission(:control_plane_lost))

    settle(audit, outcome)
  end

  # The call's identity: the entry's, when it minted one before its own
  # checks, else a new one (`Sanctum.Decisions.call_id!/1`).
  defp call_id!(call_id), do: Sanctum.Decisions.call_id!(call_id)

  # The call that admitted the calling execution, as the host stamped it
  # on the lineage — never anything the guest's arguments carry.
  defp parent_call_id(%{call_id: "call_" <> _ = call_id}), do: call_id
  defp parent_call_id(_lineage), do: nil

  # A decision's operation names, as stored (`Sanctum.Decisions.bounded/1`).
  defp bounded(value), do: Sanctum.Decisions.bounded(value)

  defp action_of(args), do: bounded(args["action"] || args[:action])

  # The call admitted: its decision recorded, then the work run. The
  # duration is the work's alone.
  defp admitted(opts, args, run) do
    decide(Keyword.fetch!(opts, :audit), :admitted, action_of(args), nil)
    started = System.monotonic_time()
    {result, meta} = run.()
    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
    {:admitted, result, meta, elapsed}
  end

  # The call refused before any work ran: its decision recorded, the
  # refusal answered.
  defp refused(opts, args, %Prima.Refusal{} = refusal) do
    audit = opts |> Keyword.fetch!(:audit) |> undeclared_withheld()
    decide(audit, :refused, action_of(args), refusal)
    {:refused, {:error, refusal}}
  end

  # A refused call's row holds no argument its own declaration refuses:
  # each top-level argument the operation declares whose value fails that
  # declaration, as the cast checks it (`Prima.Arg.cast/2`), is the
  # sanitizer's placeholder, so a malformed value — whatever it carries —
  # never reaches the log. An argument the operation does not declare, and
  # a tool the catalog does not hold, are left to the row's sanitizer
  # (`Sanctum.RequestLog`), as every input is.
  defp undeclared_withheld(%{projection: %{input: input} = projection} = audit)
       when is_map(input) do
    case declared_args(audit.name, input) do
      declared when map_size(declared) == 0 ->
        audit

      declared ->
        input = Map.new(input, fn {key, value} -> {key, withheld(declared, key, value)} end)
        %{audit | projection: %{projection | input: input}}
    end
  end

  defp undeclared_withheld(audit), do: audit

  defp declared_args(name, input) do
    action = input["action"] || input[:action]

    with {:ok, {_module, %{operations: operations}}} <- Catalog.lookup(name),
         %Operation{args: args} <- Enum.find(operations, &(&1.action == action)) do
      Map.new(args, &{&1.name, &1})
    else
      _ -> %{}
    end
  end

  defp withheld(declared, key, value) do
    with %Prima.Arg{} = arg <- Map.get(declared, key),
         {:error, _message} <- Prima.Arg.cast([arg], %{key => value}) do
      Prima.Sanitizer.placeholder()
    else
      _ -> value
    end
  end

  # An admitted call `Sanctum.Catalog.recorded?/2` leaves out (discovery,
  # the audit's own reads, the shell's reads of the caller's own state) is
  # neither appended nor emitted. A refusal of any call is both: it is what
  # an audit exists to see.
  defp decide(%{recorded?: false}, :admitted, _action, _refusal), do: :ok

  defp decide(audit, admission, action, refusal) do
    ctx = audit.ctx

    decision = %Prima.Decision{
      call_id: audit.call_id,
      parent_call_id: audit.parent_call_id,
      request_id: ctx.request_id,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      plane: audit.plane,
      tool: audit.tool,
      action: action,
      inserted_at: audit.inserted_at,
      admission: admission,
      refusal_class: refusal && refusal.class,
      reason: refusal && Refusals.render(refusal)
    }

    Sanctum.Decisions.open(ctx, decision, audit.projection)
  end

  # The admitted work's completion, recorded by the process that ran it
  # once it returned; the answer is the work's either way.
  defp settle(_audit, {:refused, result}), do: result
  defp settle(%{recorded?: false}, {:admitted, result, _meta, _elapsed}), do: result

  defp settle(audit, {:admitted, result, meta, elapsed}) do
    Sanctum.Decisions.close(audit.ctx, audit.call_id, %{
      result: result,
      duration_ms: elapsed,
      routed_to: Map.get(meta, :routed_to)
    })

    result
  end

  # A chain's call: the calling execution's standing, the in-chain plane,
  # the caller's own authorization, the cast, and then the authority's
  # step on the target the cast arguments name — in that order, so a
  # refusal of any earlier conjunct takes no budget.
  defp route(name, ctx, args, opts, true = _in_chain?) do
    authority = Keyword.fetch!(opts, :authority)
    guest_fn = Keyword.get(opts, :guest_fn, :call)

    with :ok <- lineage_standing(ctx, Keyword.get(opts, :lineage)),
         :ok <- Catalog.in_chain_reachability(name, args),
         :ok <- authorize_declared_action(name, ctx, args, true),
         {:ok, cast} <- validate_chain_arguments(name, args),
         {:ok, target, server} <- in_chain_target(ctx, name, cast),
         {:ok, resource} <- authority_step(authority, guest_fn, target) do
      warn_on_description_drift(ctx, authority, resource)

      # The server row the transition was judged on is the one dispatch
      # speaks to — one revision per call, never a second read that a
      # change in between could answer.
      charged(name, ctx, cast, authority, guest_fn, Keyword.put(opts, :server, server))
    else
      # Recorded with the arguments as the caller sent them.
      {:error, reason} -> refused(opts, args, Refusals.admission(reason))
    end
  end

  defp route(name, ctx, args, opts, false = _in_chain?) do
    case Catalog.lookup(name) do
      {:ok, {_module, meta}} ->
        with :ok <- authorize_declared_action(name, ctx, args, false),
             {:ok, cast} <- Operation.cast(meta, args) do
          dispatch(name, ctx, cast, opts)
        else
          # Recorded with the arguments as the caller sent them.
          {:error, reason} -> refused(opts, args, Refusals.admission(reason))
        end

      # A name the table does not hold: a proxied `server:tool` is admitted
      # by the same check a chain's call passes.
      :miss ->
        case authorize_declared_action(name, ctx, args, false) do
          :ok -> dispatch(name, ctx, args, opts)
          {:error, reason} -> refused(opts, args, Refusals.admission(reason))
        end
    end
  end

  defp authority_step(authority, guest_fn, target) do
    case Sanctum.Authority.step(authority, guest_fn, target) do
      {:allow_tool, resource} ->
        {:ok, resource}

      # Rostered reasons (`Prima.Refusal`), which the table renders in the
      # authority vocabulary's own sentence and classes `forbidden`.
      {:deny, reason} ->
        {:error, {:invoke_denied, reason}}

      {:invalid, {:malformed_target, _fun, _tag} = malformed} ->
        {:error, {:invoke_invalid, malformed}}
    end
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
          case dispatch(name, ctx, args, dispatch_opts) do
            {:admitted, result, meta, elapsed} ->
              {:admitted, prune_in_chain_discovery(result, name, args, ctx, authority), meta,
               elapsed}

            {:refused, _result} = refused ->
              refused
          end
        after
          if guest_fn == :spawn do
            Sanctum.Authority.release_invoke(authority)
            release_row(ctx, authority, opts)
          end
        end

      {:error, reason} ->
        # The slot the transition charged goes back: the row refused it.
        Sanctum.Authority.BudgetCounter.release(authority.budget)
        refused(opts, args, Refusals.admission({:invoke_denied, reason}))
    end
  end

  # The admitted call, run: a catalogued tool's handler, or — on a miss —
  # the proxy port for a `server:tool` name, once it has resolved the name
  # and the call is admitted.
  defp dispatch(name, ctx, args, opts) do
    in_chain? = Keyword.fetch!(opts, :in_chain)
    args = if in_chain?, do: put_lineage(args, Keyword.get(opts, :lineage)), else: args

    case Catalog.lookup(name) do
      {:ok, {module, _meta}} ->
        admitted(opts, args, fn ->
          result =
            execute_tool_call(name, ctx, opts, fn ->
              module.handle(name, handler_input(module, ctx), args)
            end)

          # The row names the service that answered, as `system.status`
          # names it.
          {result, %{routed_to: Sanctum.Services.service_name(module)}}
        end)

      :miss ->
        proxied(name, ctx, args, opts, in_chain?)
    end
  end

  # A namespaced name (e.g. "notion:create_page") is asked of the proxy
  # port: resolved first — the server, the tool, the plane — as part of
  # the admission, then run.
  defp proxied(name, ctx, args, opts, in_chain?) do
    if String.contains?(name, ":") and not ctx.authenticated do
      # External tools carry no per-tool requires_auth metadata; all of
      # them require authentication. The HTTP router never routes unknown
      # names here, so this guards the in-process callers (FormulaHandler,
      # LiveViews). Bare unknown names fall through so they still produce
      # "Unknown tool".
      refused(opts, args, Refusals.admission({:tool_auth_required, name}))
    else
      # The caller's plane rides along: proxied tools are in-chain by
      # declaration, and an external-plane call reaches one only when the
      # server row opts in — enforced where the row is in hand, not left to
      # the wiring.
      plane = if in_chain?, do: :in_chain, else: :external
      proxy = Sanctum.Proxy.impl!()

      case proxy.resolve(name, ctx, plane, server: Keyword.get(opts, :server)) do
        {:ok, target} ->
          admitted(opts, args, fn ->
            result =
              execute_tool_call(name, ctx, opts, fn ->
                proxy.dispatch(target, ctx, args, plane,
                  execution_id: Keyword.get(opts, :execution_id),
                  step: Keyword.get(opts, :step),
                  hold: Keyword.get(opts, :hold),
                  retention_class: Keyword.get(opts, :retention_class)
                )
              end)

            {result, %{routed_to: "external:#{name}"}}
          end)

        {:error, :not_external} ->
          refused(opts, args, Refusals.admission({:unknown_tool, name}))

        {:error, reason} ->
          refused(opts, args, Refusals.admission(reason))
      end
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
  # A handler that does not answer is answered by `unanswered/3`, on
  # either plane and under either runner.
  defp execute_tool_call(name, ctx, opts, execute_fn) do
    action = Keyword.get(opts, :action)

    case Keyword.get(opts, :runner, :inline) do
      :inline -> run_inline({name, action}, execute_fn)
      :supervised -> run_supervised({name, action}, ctx, opts, execute_fn)
    end
  end

  defp run_inline({name, _action} = op, execute_fn) do
    execute_fn.()
  rescue
    refusal in Sanctum.UnauthorizedError ->
      {:error, refusal.reason}

    exception ->
      Logger.error(
        "[Sanctum.Dispatch] Tool #{name} crashed: " <>
          Prima.LogFilter.format_exception(:error, exception, __STACKTRACE__)
      )

      unanswered(op, :crashed, {:crashed, "Tool #{name} crashed"})
  catch
    :exit, reason ->
      Logger.error(
        "[Sanctum.Dispatch] Tool #{name} exited: #{Prima.LogFilter.inspect_reason(reason)}"
      )

      unanswered(op, :exited, {:exit, "Tool #{name} exited unexpectedly"})
  end

  defp run_supervised({name, _action} = op, ctx, opts, execute_fn) do
    case Keyword.get(opts, :cancel_handle) do
      nil ->
        supervise(op, ctx, nil, execute_fn)

      handle ->
        # Claimed before the task exists, so a cancel that lands first is
        # seen when the task registers, and the handler never runs.
        case Sanctum.RunningTasks.claim(handle) do
          :ok -> supervise(op, ctx, handle, execute_fn)
          :cancelled -> {:error, {:cancelled, "Tool #{name} was cancelled"}}
        end
    end
  end

  defp supervise({name, _action} = op, ctx, handle, execute_fn) do
    # Registered under the server-minted request id, which is also the
    # request's progress topic (`Cyfr.Bus.progress/2`) — one identity per
    # request across both subsystems. The transport cancels through this when its caller hangs up;
    # a context without one (an internal call that bypassed `do_call/4`'s
    # minting) simply is not cancellable that way — its caller cancels by
    # handle.
    #
    # The claim is taken before the task exists and the task registers
    # against it from inside itself before the handler runs, so a cancel
    # that lands in between is seen at the registration and the handler
    # never runs.
    request_id = ctx.request_id
    claim = if is_binary(request_id), do: Sanctum.RunningTasks.claim_request(request_id)

    logger_metadata = Prima.LoggerContext.capture()

    task =
      Task.Supervisor.async_nolink(Sanctum.Gate.TaskSupervisor, fn ->
        Prima.LoggerContext.restore(logger_metadata)

        # A refused registration exits with a reason of its own: the
        # handler never ran, so the call is cancelled whatever its action.
        case register_task(request_id, claim, handle) do
          :ok -> execute_fn.()
          _refused -> exit(@not_started)
        end
      end)

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
            "[Sanctum.Dispatch] Tool #{name} crashed: #{Prima.LogFilter.format_exception(:error, exception, stacktrace)}"
          )

          # The tuple carries only the tool's name — the exception's own
          # message can hold a query, a path, or the offending bytes, and
          # this tuple renders verbatim on the wire (`Prima.Refusal.message/1`).
          unanswered(op, :crashed, {:crashed, "Tool #{name} crashed"})

        {:exit, @not_started} ->
          {:error, {:cancelled, "Tool #{name} was cancelled"}}

        {:exit, :cancelled} ->
          unanswered(op, :cancelled, {:cancelled, "Tool #{name} was cancelled"})

        {:exit, reason} ->
          Logger.error(
            "[Sanctum.Dispatch] Tool #{name} exited: #{Prima.LogFilter.inspect_reason(reason)}"
          )

          unanswered(op, :exited, {:exit, "Tool #{name} exited unexpectedly"})

        nil ->
          Logger.error("[Sanctum.Dispatch] Tool #{name} timed out after #{@tool_timeout_ms}ms")

          unanswered(
            op,
            :timed_out,
            {:timeout, "Tool #{name} timed out after #{@tool_timeout_ms}ms"}
          )
      end

    if claim, do: Sanctum.RunningTasks.unregister(request_id, claim)
    if handle, do: Sanctum.RunningTasks.release_handle(handle)
    result
  end

  # A handler that ended without answering once it may have run. An effect
  # it made before it stopped is not undone by its stopping: unless its
  # action is reviewed as replay-safe (the operation's declaration, read
  # here and nowhere else), its caller learns the outcome is unknown, not
  # that it failed; a replay-safe read answers the ordinary typed error.
  defp unanswered({name, action}, how, ordinary) do
    if replay_safe?(name, action),
      do: {:error, ordinary},
      else: {:error, {:uncertain, uncertain_message(name, how)}}
  end

  @stopped %{
    crashed: "crashed",
    exited: "exited",
    cancelled: "was cancelled",
    timed_out: "timed out"
  }

  @doc """
  The sentence a call answers `{:error, {:uncertain, sentence}}` with when
  tool `name`'s handler stopped once it may have acted, by how it stopped:
  `"Tool <name> crashed; its outcome is unknown"`, and likewise for
  `:exited`, `:cancelled` and `:timed_out`. Its one definition: the gate
  answers with it and the component guide quotes it.
  """
  @spec uncertain_message(String.t(), :crashed | :exited | :cancelled | :timed_out) ::
          String.t()
  def uncertain_message(name, how) when is_map_key(@stopped, how),
    do: "Tool #{name} #{Map.fetch!(@stopped, how)}; its outcome is unknown"

  # Run from inside the task. `:cancelled` or `:released` from either
  # registration means the handler must not run.
  defp register_task(request_id, claim, handle) do
    with :ok <-
           if(claim, do: Sanctum.RunningTasks.register(request_id, claim, self()), else: :ok) do
      if handle, do: Sanctum.RunningTasks.register_handle(handle, self()), else: :ok
    end
  end

  defp replay_safe?(name, action) when is_binary(action) do
    case Catalog.get_tool(name) do
      {:ok, tool_def} -> Sanctum.Annotations.recovery(tool_def, action) == :replay_safe
      _ -> false
    end
  end

  defp replay_safe?(_name, _action), do: false
end
