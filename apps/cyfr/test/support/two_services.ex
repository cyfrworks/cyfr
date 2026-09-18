# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.TwoServices do
  @moduledoc """
  What an integration test needs to run work on the two worker services of
  the test boot at once: the Opus service (`Cyfr.Test.OpusService`,
  `wrk_local`), which runs a component for real, and the scripted service
  (`Cyfr.Test.ScriptedWorker`, `wrk_scripted`), which answers from a
  script. Both are reached over HTTP and hold keys of their own. Users are
  `async: false`: the routing, the Opus service and the scripted service
  are each one.

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
  - Holding a guest: `await_entry!/1` and `hold_children!/1` stop a guest
    the Opus service runs at its authority's entry until the test lets it
    go.
  - The wire: `Wire` is a proxy that loses what it is told to, and
    `point_opus_at!/1` puts it between the Opus service and CYFR's host
    listener.

  Every function that attaches a handler, starts a process or changes
  configuration undoes it when the test ends (`ExUnit.Callbacks.on_exit/1`),
  so each is called from the test process.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Cyfr.Authority
  alias Cyfr.Test.{AttemptFixtures, AuthorityFixtures, OpusService, ScriptedWorker}
  alias Sanctum.Consent.{Commit, Plan}

  @stub_wasm Path.expand("test_wasm/step_stub/step_stub.wasm", __DIR__)
  @stub "catalyst:local.step-stub"
  @scripted "reagent:local.two-workers"
  @version "0.1.0"
  @key_field "STUB_API_KEY"
  @entered [:cyfr, :opus, :runtime, :authority_entered]
  @hold_ms 60_000

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

  # A wire between a client and a listener that loses what it is told to:
  # a Plug served on a loopback port that forwards each request, header and
  # body as they are, to `target` and answers what came back — or, as
  # planned per route, forwards it and answers 502 in place of the answer
  # (lost after the listener acted), or answers 502 without forwarding
  # (lost before it acted). What it did for each route is kept, in order.
  defmodule Wire do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    def start!(target) do
      agent = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{plan: %{}, seen: []} end})

      server =
        ExUnit.Callbacks.start_supervised!(
          {Bandit,
           plug: {__MODULE__, %{agent: agent, target: target}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{agent: agent, url: "http://127.0.0.1:#{port}"}
    end

    def plan(%{agent: agent}, route, actions) when is_list(actions),
      do: Agent.update(agent, &put_in(&1, [:plan, route], actions))

    def seen(%{agent: agent}, route) do
      for {^route, action} <- Enum.reverse(Agent.get(agent, & &1.seen)), do: action
    end

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{agent: agent, target: target}) do
      {:ok, body, conn} = read_body(conn, length: 16_000_000)
      route = conn.request_path

      action =
        Agent.get_and_update(agent, fn state ->
          case get_in(state, [:plan, route]) do
            [action | rest] -> {action, put_in(state, [:plan, route], rest)}
            _ -> {:forward, state}
          end
        end)

      answer =
        if action == :drop do
          :dropped
        else
          headers =
            for {name, value} <- conn.req_headers,
                name in ["x-cyfr-auth", "content-type"],
                do: {name, value}

          Req.post!(target <> route,
            headers: headers,
            body: body,
            retry: false,
            decode_body: false,
            receive_timeout: 60_000
          )
        end

      Agent.update(agent, &%{&1 | seen: [{route, action} | &1.seen]})

      case {action, answer} do
        {:forward, %Req.Response{status: status, body: answer}} ->
          conn |> put_resp_content_type("application/json") |> send_resp(status, answer)

        _lost ->
          send_resp(conn, 502, "")
      end
    end
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
  holds `token`, and dispense `token` to every run of the stub as its
  guest starts. Answers both, the credentials to look for.
  """
  @spec arm!(Sanctum.Context.t(), key: String.t(), token: String.t()) :: [String.t()]
  def arm!(ctx, key: key, token: token) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "#{@stub} key",
        kind: "api_key",
        fields: %{@key_field => key},
        oauth: %{"access_token" => token}
      })

    {:ok, plan} = Plan.plan(ctx, %{ref: @stub})
    decisions = %{ref: @stub, bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    handler = "two-services-dispense-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @entered,
        fn _event, _measurements, %{execution_id: id, reference: reference}, _config ->
          if String.starts_with?(reference, @stub <> ":") do
            attempt = AttemptFixtures.current!(ctx.athanor_id, id)

            %{"ok" => ^token} =
              AttemptFixtures.call(attempt, "oauth_token", %{"provider" => "stub"})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    [key, token]
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

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: budget.id, cap: Keyword.get(opts, :cap, budget.cap)}
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
  # Holding a guest
  # ---------------------------------------------------------------------------

  @doc """
  Hold the guest of `id` at its authority's entry until the test sends
  `:continue` to the process it names: the test receives
  `{:entered, id, guest}` once the guest is held.
  """
  @spec await_entry!(String.t()) :: :ok
  def await_entry!(id) do
    test = self()

    hold!("entry", fn metadata ->
      if metadata.execution_id == id do
        send(test, {:entered, id, self()})
        held()
      end
    end)
  end

  @doc """
  Children of `root_id` wait at their guest's entry for `:continue`: the
  test receives `{:held, guest, id}` for each.
  """
  @spec hold_children!(String.t()) :: :ok
  def hold_children!(root_id) do
    test = self()

    hold!("children", fn %{execution_id: id} ->
      case Arca.Repo.get(Arca.Execution, id) do
        %{parent_execution_id: ^root_id} ->
          send(test, {:held, self(), id})
          held()

        _ ->
          :ok
      end
    end)
  end

  # The handler runs in the guest's process, as it enters its authority.
  defp hold!(label, entered) do
    handler = "two-services-#{label}-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @entered,
        fn _event, _measurements, metadata, _config -> entered.(metadata) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp held do
    receive do
      :continue -> :ok
    after
      @hold_ms -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The wire
  # ---------------------------------------------------------------------------

  @doc """
  Point the Opus service's host calls at `url` for this test, restarting
  it (a new boot), and back at the host listener when the test ends.
  """
  @spec point_opus_at!(String.t()) :: :ok
  def point_opus_at!(url) do
    previous = Application.get_env(:opus, :host_url)
    Application.put_env(:opus, :host_url, url)
    OpusService.restart!()

    on_exit(fn ->
      Application.put_env(:opus, :host_url, previous)
      OpusService.restart!()
    end)
  end
end
