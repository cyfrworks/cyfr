# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.TwoServices do
  @moduledoc """
  What an integration test needs to run work on the two worker services of
  the test boot at once: the Opus service (`Cyfr.Test.OpusService`,
  `wrk_local`), which runs a component for real in runners that are OS
  processes of their own, and the scripted service
  (`Cyfr.Test.ScriptedWorker`, `wrk_scripted`), which answers from a
  script. Both are reached over HTTP and hold keys of their own. Users are
  `async: false`: the routing, the Opus service, the scripted service and
  the suite's wire are each one.

  - The estate: `lay_seed!/2` lays a seed whose catalyst is the step stub
    (`stub/0`), a `model/chat@1` catalyst Opus runs for real, under the
    limits its manifest asks for; `arm!/2` binds the key it needs.
    `scripted/0` names a reagent only the scripted service runs.
  - The routing: `route!/2` sends the runs of a reference both services
    can run to one of them, until it is called again.
  - Work under one authority: `root!/3` admits a root holding the
    reservation an authority's budget names, and `spawn_child!/6` runs a
    spawn-shaped child of it, charged as a chain's child is;
    `scripted_run!/1` is one such child on the scripted service.
  - The wire: `Wire` is a proxy that forwards what it is told to, loses
    what it is told to, holds a call a test asks for until the test lets
    it go, and records what crossed it, each call read as the host reads
    it. The Opus service's runners reach CYFR's host listener through the
    suite's own wire (`Cyfr.Test.OpusService.wire!/1`) for the whole run,
    so a test holds a guest at one of its host calls (`hold!/2`), reads
    what crossed (`calls/1`, `entered/1`) and loses a call (`plan!/2`)
    without restarting the service.

  Every function that attaches a handler, starts a process or changes
  configuration or the wire undoes it when the test ends
  (`ExUnit.Callbacks.on_exit/1`), so each is called from the test process.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Cyfr.Authority
  alias Cyfr.Test.{AttemptFixtures, AuthorityFixtures, ScriptedWorker}
  alias Sanctum.Consent.{Commit, Plan}

  @stub_wasm Path.expand("test_wasm/step_stub/step_stub.wasm", __DIR__)
  @stub "catalyst:local.step-stub"
  @scripted "reagent:local.two-workers"
  @version "0.1.0"
  @key_field "STUB_API_KEY"

  @stub_limits %{
    "timeout" => "1m",
    "max_memory_bytes" => 67_108_864,
    "max_request_size" => 1_048_576,
    "max_response_size" => 5_242_880,
    "rate_limit" => %{"requests" => 10_000, "window" => "1m"}
  }

  @doc "The step stub's name-level reference: the catalyst `lay_seed!/2` lays."
  @spec stub() :: String.t()
  def stub, do: @stub

  @doc "The version the step stub is laid at."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The name-level reference of the reagent `scripted_run!/1` runs on the scripted service."
  @spec scripted() :: String.t()
  def scripted, do: @scripted

  defmodule Wire do
    @moduledoc """
    A wire between a client and a listener: a Plug served on a loopback
    port that forwards each request, header and body as they are, to its
    `target` and answers what came back.

    What it does with a request is decided, in order, by:

      * its route's plan (`plan/3`): the next planned action of the
        route, consumed — `:forward`; `:forward_then_drop`, which
        forwards and answers 502 in place of the answer (lost after the
        listener acted); or `:drop`, which answers 502 without forwarding
        (lost before it acted);
      * its holds (`hold/3`): a forwarded request a hold's matcher accepts
        is held until its holder releases it (`release/2`) as forwarded or
        dropped, and the holder hears `{Wire, :held, ref, call, conn}`;
        a hold not released in a minute drops the request;
      * its hooks (`after_answer/2`): once a forwarded request's answer is
        back, each hook runs on the call before the answer goes on.

    A call (`t:call/0`) is a request as the host reads it: its route and
    callback, and for a host call the header's verified fields and the
    body and answer opened under the attempt's seal key (the worker root
    derives it); a runner's exit report is read plain; anything else has
    no fields.

    A wire a test starts (`start!/1`) records every request; the suite's
    (`serve!/2`) records only while a test watches it (`watch/1`), and
    `reset/1` forgets everything a test asked of it, dropping every call
    still held.
    """
    @behaviour Plug

    import Plug.Conn

    alias Cyfr.Execution.Keys
    alias Cyfr.{WorkerAuth, WorkerWire}

    @max_hold_ms 60_000

    @typedoc "A request as the host reads it."
    @type call :: %{
            route: String.t(),
            callback: atom() | nil,
            fields: map() | nil,
            args: map() | nil,
            answer: map() | nil,
            action: atom()
          }

    @type t :: %{agent: pid() | atom(), server: pid(), url: String.t()}

    @doc "A wire to `target` for the calling test, stopped when it ends; it records every request."
    @spec start!(String.t()) :: t()
    def start!(target) do
      agent = ExUnit.Callbacks.start_supervised!({Agent, fn -> initial(true) end})

      server =
        ExUnit.Callbacks.start_supervised!(
          {Bandit,
           plug: {__MODULE__, %{agent: agent, target: target}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      wire(agent, server)
    end

    @doc """
    A wire to `target` for the rest of the run, its state kept under
    `name`, held by no test; it records only while watched.
    """
    @spec serve!(String.t(), atom()) :: t()
    def serve!(target, name) do
      {:ok, agent} = Agent.start(fn -> initial(false) end, name: name)

      {:ok, server} =
        Bandit.start_link(
          plug: {__MODULE__, %{agent: agent, target: target}},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      Process.unlink(server)
      wire(name, server)
    end

    defp wire(agent, server) do
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{agent: agent, server: server, url: "http://127.0.0.1:#{port}"}
    end

    defp initial(watching),
      do: %{watching: watching, plan: %{}, holds: [], held: %{}, hooks: [], seen: [], calls: []}

    @doc "Plan the next actions of `route`, in order."
    def plan(%{agent: agent}, route, actions) when is_list(actions),
      do: Agent.update(agent, &put_in(&1, [:plan, route], actions))

    @doc "What the wire did with each request of `route`, in order."
    def seen(%{agent: agent}, route) do
      for {^route, action} <- Enum.reverse(Agent.get(agent, & &1.seen)), do: action
    end

    @doc "Every call recorded, oldest first."
    @spec calls(t()) :: [call()]
    def calls(%{agent: agent}), do: agent |> Agent.get(& &1.calls) |> Enum.reverse()

    @doc "Record every request from now on."
    def watch(%{agent: agent}), do: Agent.update(agent, &%{&1 | watching: true})

    @doc """
    Hold each forwarded call `matcher` accepts, telling `:holder` (default
    the caller) `{Wire, :held, ref, call, conn}`, or what `:notify` makes of
    the call and the held connection; only the first with `once: true`.
    Answers the hold's reference.
    """
    @spec hold(t(), (call() -> as_boolean(term())), keyword()) :: reference()
    def hold(%{agent: agent}, matcher, opts \\ []) when is_function(matcher, 1) do
      ref = make_ref()

      hold = %{
        ref: ref,
        matcher: matcher,
        holder: Keyword.get(opts, :holder, self()),
        notify:
          Keyword.get(opts, :notify, fn call, conn -> {__MODULE__, :held, ref, call, conn} end),
        once: Keyword.get(opts, :once, false)
      }

      Agent.update(agent, &%{&1 | holds: &1.holds ++ [hold]})
      hold.ref
    end

    @doc "Let the held call on `conn` go on: `:forward` it, or `:drop` it as lost."
    def release(conn, how \\ :forward) when is_pid(conn) and how in [:forward, :drop] do
      send(conn, {__MODULE__, :release, how})
      :ok
    end

    @doc "Run `hook` on every call whose answer came back, before the answer goes on."
    def after_answer(%{agent: agent}, hook) when is_function(hook, 1),
      do: Agent.update(agent, &%{&1 | hooks: &1.hooks ++ [hook]})

    @doc """
    Forget every plan, hold, hook and record, and stop recording; drop
    every call still held.
    """
    def reset(%{agent: agent}) do
      held = Agent.get_and_update(agent, fn state -> {Map.keys(state.held), initial(false)} end)
      Enum.each(held, &release(&1, :drop))
    end

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{agent: agent, target: target}) do
      {:ok, body, conn} = read_body(conn, length: 16_000_000)
      route = conn.request_path

      # Unwatched, a request is forwarded as it is and nothing is read: a
      # plan, a hold and a hook are a watching test's.
      {action, answer} =
        if Agent.get(agent, & &1.watching) do
          call = read(route, get_req_header(conn, WorkerWire.auth_header()), body)

          action =
            case planned(agent, route) do
              :forward -> holding(agent, call)
              planned -> planned
            end

          answer = if action == :drop, do: :dropped, else: forward(conn, target, route, body)
          call = %{call | action: action, answer: answered(call, answer)}
          if match?(%Req.Response{}, answer), do: hooks(agent, call)
          record(agent, route, call)
          {action, answer}
        else
          {:forward, forward(conn, target, route, body)}
        end

      case {action, answer} do
        {:forward, %Req.Response{status: status, body: answer}} ->
          conn |> put_resp_content_type("application/json") |> send_resp(status, answer)

        _lost ->
          send_resp(conn, 502, "")
      end
    end

    defp planned(agent, route) do
      Agent.get_and_update(agent, fn state ->
        case get_in(state, [:plan, route]) do
          [action | rest] -> {action, put_in(state, [:plan, route], rest)}
          _ -> {:forward, state}
        end
      end)
    end

    # A hold's matcher runs here, in the request's own process, which may
    # read the database under the holding test's shared sandbox.
    defp holding(agent, call) do
      claimed =
        agent
        |> Agent.get(& &1.holds)
        |> Enum.find(fn hold -> matches?(hold, call) end)
        |> claim(agent)

      case claimed do
        nil ->
          :forward

        hold ->
          send(hold.holder, hold.notify.(call, self()))

          how =
            receive do
              {__MODULE__, :release, how} -> how
            after
              @max_hold_ms -> :drop
            end

          conn = self()
          Agent.update(agent, &%{&1 | held: Map.delete(&1.held, conn)})
          how
      end
    end

    defp matches?(hold, call) do
      hold.matcher.(call)
    rescue
      _ -> false
    end

    defp claim(nil, _agent), do: nil

    # The held connection is this request's process; the update runs in the
    # agent's.
    defp claim(hold, agent) do
      conn = self()

      Agent.get_and_update(agent, fn state ->
        present = Enum.any?(state.holds, &(&1.ref == hold.ref))

        holds =
          if hold.once, do: Enum.reject(state.holds, &(&1.ref == hold.ref)), else: state.holds

        if present,
          do: {hold, %{state | holds: holds, held: Map.put(state.held, conn, hold.ref)}},
          else: {nil, state}
      end)
    end

    defp hooks(agent, call) do
      for hook <- Agent.get(agent, & &1.hooks), do: hook.(call)
    end

    defp record(agent, route, call) do
      Agent.update(agent, fn
        %{watching: true} = state ->
          %{state | seen: [{route, call.action} | state.seen], calls: [call | state.calls]}

        state ->
          state
      end)
    end

    defp forward(conn, target, route, body) do
      headers =
        for {name, value} <- conn.req_headers,
            name in [WorkerWire.auth_header(), "content-type"],
            do: {name, value}

      Req.post!(target <> route,
        headers: headers,
        body: body,
        retry: false,
        decode_body: false,
        receive_timeout: 60_000
      )
    end

    # ---------------------------------------------------------------------------
    # Reading a request as the host does
    # ---------------------------------------------------------------------------

    defp read(route, headers, body) do
      base = %{route: route, callback: nil, fields: nil, args: nil, answer: nil, action: nil}

      with "/host/v1/" <> _ <- route,
           {:ok, callback} <- WorkerWire.host_callback(route),
           [header] <- headers,
           {:ok, fields, args} <- open(callback, header, body) do
        %{base | callback: callback, fields: fields, args: args}
      else
        _ ->
          case WorkerWire.host_callback(route) do
            {:ok, callback} -> %{base | callback: callback}
            :error -> base
          end
      end
    end

    defp open(:runner_exited, header, body) do
      with {:ok, fields, _hash} <-
             WorkerAuth.verify_report_header(Keys.root(), header, now()),
           {:ok, %{"args" => args}} <- Jason.decode(body) do
        {:ok, fields, args}
      end
    end

    defp open(_callback, header, body) do
      with {:ok, standing} <- Keys.standing(),
           {:ok, fields, _hash} <-
             WorkerAuth.verify_host_call_header(Keys.root(), header, now(), standing),
           {:ok, seal_key} <- WorkerAuth.attempt_seal_key(Keys.root(), fields),
           {:ok, json} <- WorkerAuth.open_call(seal_key, :body, fields, body),
           {:ok, %{"args" => args}} <- Jason.decode(json) do
        {:ok, fields, args}
      end
    end

    defp answered(%{fields: nil}, _answer), do: nil
    defp answered(_call, :dropped), do: nil

    defp answered(%{callback: :runner_exited}, %Req.Response{status: 200, body: body}),
      do: decoded(body)

    defp answered(%{fields: fields}, %Req.Response{status: 200, body: sealed}) do
      with {:ok, seal_key} <- WorkerAuth.attempt_seal_key(Keys.root(), fields),
           {:ok, json} <- WorkerAuth.open_call(seal_key, :answer, fields, sealed) do
        decoded(json)
      else
        _ -> nil
      end
    end

    defp answered(_call, _answer), do: nil

    defp decoded(json) do
      case Jason.decode(json) do
        {:ok, %{} = answer} -> answer
        _ -> nil
      end
    end

    defp now, do: System.system_time(:millisecond)
  end

  # ---------------------------------------------------------------------------
  # The estate
  # ---------------------------------------------------------------------------

  @doc """
  Lay a seed at `seed` whose catalyst is the step stub and whose soul runs
  on it, and answer `seed`. `opts[:limits]` is merged over the limits the
  stub's manifest asks for (`caps.limits`), which the consent minted for it
  grants.
  """
  @spec lay_seed!(Path.t(), keyword()) :: Path.t()
  def lay_seed!(seed, opts \\ []) do
    unit = Path.join([seed, "components", "catalysts", "local", "step-stub", @version])
    File.mkdir_p!(unit)
    File.cp!(@stub_wasm, Path.join(unit, "catalyst.wasm"))

    manifest = %{
      "name" => "step-stub",
      "type" => "catalyst",
      "version" => @version,
      "publisher" => "local",
      "description" => "A model/chat@1 catalyst the two-service matrix runs",
      "contracts" => [Cyfr.Models.chat_contract()],
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:step-stub",
          "reason" => "to read a key as a model catalyst does",
          "required" => true,
          "fields" => [@key_field]
        }
      },
      "caps" => %{"limits" => Map.merge(@stub_limits, Keyword.get(opts, :limits, %{}))}
    }

    File.write!(Path.join(unit, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.mkdir_p!(Path.join(seed, "aqua"))

    File.write!(Path.join([seed, "aqua", "aqua.md"]), """
    ---
    title: AQUA
    catalyst_ref: #{@stub}
    model: step-stub
    ---

    You answer the person.
    """)

    seed
  end

  @doc """
  Bind `key` as the stub's vault field, in an entry whose OAuth bundle
  holds `token`, and dispense `token` to every run of the stub once its
  runner has attached, before the attach is answered and its guest runs,
  as a guest's `cyfr:oauth` call dispenses one (`dispense_after_attach!/3`).
  Answers both, the credentials to look for.
  """
  @spec arm!(Sanctum.Context.t(), key: String.t(), token: String.t()) :: [String.t()]
  def arm!(ctx, key: key, token: token), do: arm!(ctx, @stub, key: key, token: token)

  @doc "`arm!/2` for the catalyst `ref`, whose need is the step stub's."
  @spec arm!(Sanctum.Context.t(), String.t(), key: String.t(), token: String.t()) :: [String.t()]
  def arm!(ctx, ref, key: key, token: token) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "#{ref} key",
        kind: "api_key",
        fields: %{@key_field => key},
        oauth: %{"access_token" => token}
      })

    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    dispense_after_attach!(ctx, ref, token)
    [key, token]
  end

  @doc """
  Dispense `token` by an `oauth_token` host call on the attempt of every
  run of `ref` once it is its runner's: when its runner's attach is
  answered, or, for a child a formula's runner is handed at its admission,
  when that admission is answered; in either case before the answer
  reaches the runner, so the token is in the run's masking set before its
  guest starts.
  """
  @spec dispense_after_attach!(Sanctum.Context.t(), String.t(), String.t()) :: :ok
  def dispense_after_attach!(ctx, ref, token) do
    wire = watch!()

    Wire.after_answer(wire, fn
      %{callback: :attach, fields: %{execution_id: id}, answer: %{"ok" => _secrets}} ->
        dispense(ctx, ref, id, token)

      %{callback: :admit_child, answer: %{"ok" => %{"assignment" => assignment}}} ->
        {:ok, %{execution_id: id}} = Cyfr.Assignment.read(assignment)
        dispense(ctx, ref, id, token)

      _call ->
        :ok
    end)
  end

  defp dispense(ctx, ref, id, token) do
    case Arca.Repo.get(Arca.Execution, id) do
      %{reference: reference} ->
        if String.starts_with?(reference, ref <> ":") do
          attempt = AttemptFixtures.current!(ctx.athanor_id, id)

          %{"ok" => ^token} =
            AttemptFixtures.call(attempt, "oauth_token", %{"provider" => "stub"})
        end

        :ok

      nil ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The routing
  # ---------------------------------------------------------------------------

  @doc """
  Send the runs of `refs`, which the scripted service scripts, to
  `:scripted` or to `:opus` from now on: `config :cyfr, :workers` with the
  scripted service's entry for them ahead of the rest, or without it. A run
  is routed when it is dispatched, so one already dispatched stays where it
  is. The caller restores `:workers` when its test ends.
  """
  @spec route!(:scripted | :opus, [String.t()] | String.t()) :: :ok
  def route!(:scripted, refs) do
    configured = Application.get_env(:cyfr, :workers)
    Application.put_env(:cyfr, :workers, ScriptedWorker.workers(refs, configured))
  end

  def route!(:opus, _refs) do
    configured = Application.get_env(:cyfr, :workers, [])
    scripted = ScriptedWorker.service()
    Application.put_env(:cyfr, :workers, Enum.reject(configured, &(&1[:id] == scripted)))
  end

  # ---------------------------------------------------------------------------
  # Work under one authority
  # ---------------------------------------------------------------------------

  @typedoc "A root `root!/3` admitted: its execution id and the attempt that owns it."
  @type root :: %{id: String.t(), attempt: String.t()}

  @doc """
  Admit a synthetic root under `authority`: a running row with the
  invocation reservation the authority's budget names, as a root's
  admission mints it, and no guest. `opts[:cap]` is the reservation's cap
  (default the budget's).
  """
  @spec root!(Sanctum.Context.t(), Authority.t(), keyword()) :: root()
  def root!(ctx, %Authority{budget: budget}, opts \\ []) do
    root_id = "exec_two_services_root_#{System.unique_integer([:positive])}"
    {:ok, grant} = Sanctum.ExecutionStanding.capture(ctx)

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: budget.id, cap: Keyword.get(opts, :cap, budget.cap)},
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    %{id: root_id, attempt: attempt.attempt}
  end

  @doc """
  Run `reference` with `input` as a spawn-shaped child of `root` under
  `authority`, as a chain's child is run: its step charges the root's
  budget, its charge row is taken in the root's reservation, and its
  attempt holds both until it stops. Blocks until the run ends, in the
  calling process, its waiter. `opts[:execution_id]` names the child
  (default a fresh id). Answers what the run answered and the child's id.
  """
  @spec spawn_child!(Sanctum.Context.t(), Authority.t(), root(), String.t(), map(), keyword()) ::
          {{:ok, map()} | {:error, term()}, String.t()}
  def spawn_child!(ctx, %Authority{} = authority, root, reference, input, opts \\ []) do
    child_id = Keyword.get_lazy(opts, :execution_id, &Cyfr.UUID7.execution_id/0)

    charge = %{
      id: "call:t:1:c#{System.unique_integer([:positive])}:g0",
      attempt: root.attempt,
      generation: 0,
      holder_execution_id: child_id
    }

    result =
      Cyfr.Execution.run_child(authority, reference, nil, input,
        ctx: ctx,
        execution_id: child_id,
        parent_execution_id: root.id,
        root_execution_id: root.id,
        declared_needs: [],
        retention_class: "chat_step",
        charge: charge,
        guest_fn: :spawn
      )

    {result, child_id}
  end

  @doc """
  A scripted run: a child of a synthetic root, admitted with the charge
  its authority names, as a chain's child is. Answers the result and the
  child's id.
  """
  @spec scripted_run!(Sanctum.Context.t()) :: {{:ok, map()} | {:error, term()}, String.t()}
  def scripted_run!(ctx) do
    auth = AuthorityFixtures.root!()
    root = root!(ctx, auth, cap: 2)
    spawn_child!(ctx, auth, root, "#{@scripted}:1.0.0", %{"messages" => []})
  end

  # ---------------------------------------------------------------------------
  # The suite's wire: holding a guest, and reading what crossed
  # ---------------------------------------------------------------------------

  @suite_wire __MODULE__.SuiteWire

  @doc """
  Start the suite's wire between the Opus service's runners and `target`,
  CYFR's host listener, for the rest of the run, or answer it if it runs.
  """
  @spec serve_wire!(String.t()) :: Wire.t()
  def serve_wire!(target) do
    case wire() do
      nil ->
        wire = Wire.serve!(target, @suite_wire)
        :persistent_term.put({__MODULE__, :wire}, wire)
        wire

      wire ->
        wire
    end
  end

  @doc "The suite's wire, or nil before it is served."
  @spec wire() :: Wire.t() | nil
  def wire do
    with %{} = wire <- :persistent_term.get({__MODULE__, :wire}, nil),
         true <- Process.alive?(wire.server) do
      wire
    else
      _ -> nil
    end
  end

  @doc """
  Record every call crossing the suite's wire for this test, and forget
  them, with every plan, hold and hook, when it ends. Answers the wire.
  """
  @spec watch!() :: Wire.t()
  def watch! do
    wire = wire() || raise "the suite's wire is not served: run from the umbrella root"
    Wire.watch(wire)
    on_exit(fn -> Wire.reset(wire) end)
    wire
  end

  @doc "Every call that crossed the suite's wire while this test watched it, oldest first."
  @spec calls() :: [Wire.call()]
  def calls, do: Wire.calls(wire())

  @doc "The calls of `callback` that crossed for `execution_id`, oldest first."
  @spec calls(atom(), String.t()) :: [Wire.call()]
  def calls(callback, execution_id) do
    for %{callback: ^callback, fields: %{execution_id: ^execution_id}} = call <- calls(),
        do: call
  end

  @doc "Plan the next actions of the host route of `callback` on the suite's wire (`Wire.plan/3`)."
  @spec plan!(atom(), [atom()]) :: :ok
  def plan!(callback, actions) do
    wire = watch!()
    Wire.plan(wire, Cyfr.WorkerWire.host_route(callback), actions)
  end

  @doc "What the suite's wire did with each call of `callback`, in order."
  @spec seen(atom()) :: [atom()]
  def seen(callback), do: Wire.seen(wire(), Cyfr.WorkerWire.host_route(callback))

  @doc """
  Hold each host call of `callback` that `which` accepts — an execution
  id, or a function of the call's execution row (nil before it has one)
  and the call — on the suite's wire until the test lets it go
  (`release!/2`): the test receives `{:held, execution_id, conn}` for each.
  `once: true` holds only the first.
  """
  @spec hold!(atom(), String.t() | (map() | nil, Wire.call() -> as_boolean(term())), keyword()) ::
          :ok
  def hold!(callback, which, opts \\ []) do
    wire = watch!()

    _ref =
      Wire.hold(
        wire,
        &holding?(&1, callback, which),
        Keyword.merge(opts,
          holder: self(),
          notify: fn call, conn -> {:held, call.fields.execution_id, conn} end
        )
      )

    :ok
  end

  defp holding?(%{callback: callback, fields: %{execution_id: id}} = call, callback, which) do
    case which do
      ^id ->
        true

      fun when is_function(fun, 2) ->
        fun.(Arca.Repo.get(Arca.Execution, id), call)

      _other ->
        false
    end
  end

  defp holding?(_call, _callback, _which), do: false

  @doc "Let a held call go on (`:forward`), or lose it (`:drop`)."
  @spec release!(pid(), :forward | :drop) :: :ok
  def release!(conn, how \\ :forward), do: Wire.release(conn, how)

  @doc """
  The authority the guest of `execution_id` entered with, as the host
  handed it over: the one its assignment carries, read from the attach
  its runner made or, for a child claimed at its admission, from the
  `admit_child` answer that handed it to its runner. Nil when neither
  crossed the suite's wire while this test watched it.
  """
  @spec entered(String.t()) :: Authority.t() | nil
  def entered(execution_id) do
    Enum.find_value(calls(), fn
      %{callback: :attach, fields: %{execution_id: ^execution_id}, args: %{"assignment" => token}} ->
        authority_of(token)

      %{callback: :admit_child, answer: %{"ok" => %{"assignment" => token}}} ->
        case Cyfr.Assignment.read(token) do
          {:ok, %{execution_id: ^execution_id}} -> authority_of(token)
          _ -> nil
        end

      _call ->
        nil
    end)
  end

  defp authority_of(token) do
    {:ok, assignment} = Cyfr.Assignment.read(token)
    {:ok, authority} = Authority.from_wire(assignment.authority)
    authority
  end
end
