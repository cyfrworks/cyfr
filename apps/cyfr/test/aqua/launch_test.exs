# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LaunchTest do
  @moduledoc """
  A launch is an `execution.run` of a component that a member offered it
  runs at once. Decided on the call its step's row records, it runs once
  as the turn's person, under the origin the turn's row stores — a
  programmatic turn's launch stays programmatic, and no turn is written
  without an origin — under the account its decision resolved, seeded
  with the turn's read threads as its row holds them when the launch is
  dispatched, on whatever grant its app roots at when it runs. An app
  with no grant is answered by the gate that it is not granted, and a
  grant that cannot be read refuses as the damage it is. Nothing is
  checked of where the turn's material came from: egress refuses no send
  for what the run read, and a thread the turn read since the decision
  is one more read thread the root is seeded with.

  A launch runs nothing when the account its name resolved to moved
  before it runs: refused by the dispatcher before the gate is asked, or
  at the run's root.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.{Launch, Tape}
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  # A shipped application that roots its own consent: whatever it
  # answers, its root's row is written as the launch admitted it.
  @application "formula:local.list-models"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "launch_#{System.unique_integer([:positive])}")
    keys = [:base_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    Cyfr.Test.SeedBundle.lay!(~w(claude files http), formulas: ~w(list-models))

    ctx = person!()
    Sanctum.TestContext.ready!(ctx.athanor_id)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, %{profile_id: profile_id, consent_id: consent_id}} =
      Opus.authority_for(ctx, :default, @soul)

    {:ok, %{revision_digest: revision, capability_digest: capability}} =
      Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))

    pins = %{
      profile_id: profile_id,
      consent_id: consent_id,
      agent_revision_digest: revision,
      agent_capability_digest: capability
    }

    {:ok, ctx: ctx, thread: thread, pins: pins}
  end

  # The person of their own athanor, signed in through Prism: who sends the
  # turn and whom its launches run as.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, person} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|launcher#{n}",
        provider: "github",
        email: "launcher#{n}@example.com",
        verified: true,
        name: "Launcher"
      })

    %{
      Sanctum.TestContext.local(:prism)
      | user_id: person.id,
        athanor_id: Sanctum.Test.People.athanor!(person).id
    }
  end

  # A turn accepted from `sender`, whose context carries the origin its
  # admission path set, and started under its pinned root.
  defp started!(sender, thread, pins) do
    {:ok, %{turn: turn}} =
      Tape.accept(sender, thread.id, %{
        message: %{author: sender.user_id, sent_by: "person", content: "@aqua launch it"},
        turn: %{agent: "aqua", requested_by: sender.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_launch_#{System.unique_integer([:positive])}",
          reference: @soul,
          user_id: sender.user_id,
          athanor_id: sender.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: sender.origin
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(sender.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(
        sender,
        turn,
        Map.merge(pins, %{
          root_execution_id: execution.id,
          attempt: attempt.attempt,
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })
      )

    turn
  end

  # A launch step for `args` as the loop records it: the one call of a
  # response, its row the one the dispatcher recalls the call from.
  defp launch_step!(ctx, turn, args, root_id \\ nil) do
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{asks: [%{step: step}]}} =
      Tape.commit_events(
        ctx,
        %{thread: turn.thread_id, agent: turn.agent, turn: %{id: turn.id, fence: turn.fence}},
        %{
          events: [
            {:ask,
             %{
               kind: "launch",
               tool: "execution",
               action: "run",
               child_execution_id: root_id,
               idempotency_key: "call:#{turn.id}:#{model_step.id}:c1",
               call: %{
                 kind: "tool_call",
                 content: "execution.run",
                 payload: %{
                   "tool_call_id" => "c1",
                   "name" => "execution.run",
                   "tool" => "execution",
                   "action" => "run",
                   "arguments" => args,
                   "kind" => "execute",
                   "step_id" => model_step.id
                 }
               }
             }}
          ],
          position: {:step, model_step.id}
        }
      )

    step
  end

  @offered %{"execution.run" => "offered"}

  # The loop's decision for a launch of `args` in a turn, among `offered`:
  # made on the call and the account it names, reading nothing of the
  # turn.
  defp decide(ctx, _turn, args, offered \\ @offered) do
    {:ok, call} = Aqua.Loop.Binding.resolve("execution.run", args)
    Aqua.Loop.Policy.decide(call, offered, ctx: ctx, title: "Aqua")
  end

  # The decision a launch of `args` runs on: its call and the account it
  # names as resolved, and nothing of what the turn read.
  defp run_on(args, account \\ nil),
    do: {:run, %{call: %{action: "run", args: args}, account: account}}

  # What the loop hands the dispatcher for a launch of `args` in `turn`.
  defp decided!(ctx, turn, args) do
    assert {:run, decided} = decide(ctx, turn, args)
    decided
  end

  defp read!(ctx, turn, threads),
    do: {:ok, _} = Tape.record_model_intent(ctx, turn, %{threads: threads})

  defp launched(ctx) do
    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{@application}%"),
        select: %{user_id: e.user_id, origin: e.origin, parent: e.parent_execution_id}
      )
    )
  end

  test "an interactive turn's launch keeps the turn's origin", %{
    ctx: ctx,
    thread: thread,
    pins: pins
  } do
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    args = %{"reference" => @application, "input" => %{}}
    step = launch_step!(ctx, turn, args)
    dispatched = Launch.run(ctx, step, decided!(ctx, turn, args))

    assert [%{user_id: user_id, origin: "interactive", parent: nil}] = launched(ctx),
           "launch answered #{inspect(dispatched)}"

    assert user_id == turn.requested_by
  end

  test "a context without an origin writes no turn", %{ctx: ctx, thread: thread} do
    assert {:error, :no_origin} =
             Tape.accept(%{ctx | origin: nil}, thread.id, %{
               message: %{author: ctx.user_id, sent_by: "person", content: "@aqua launch it"},
               turn: %{agent: "aqua", requested_by: ctx.user_id}
             })
  end

  # ---------------------------------------------------------------------------
  # A launch naming an account
  # ---------------------------------------------------------------------------

  @probe Path.expand(
           "../../../locus/test/support/runtime/test_wasm/hostile/attached_header_probe.wasm",
           __DIR__
         )
  @default_secret "sk-launch-default-0c1d"
  @named_secret "sk-launch-supabase2-7e9a"
  @rule %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}

  defmodule Upstream do
    @moduledoc "The loopback upstream: every request is told to the test."
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{parent: parent}) do
      {:ok, body, conn} = read_body(conn)

      send(parent, {
        :upstream,
        %{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}
      })

      send_resp(conn, 200, "hello from upstream")
    end
  end

  # The loopback upstream, started for this test: its port.
  defp upstream_port!(ctx) do
    Cyfr.Test.Sandbox.stop_work_on_exit()

    upstream =
      start_supervised!(
        {Bandit,
         plug: {Upstream, %{parent: self()}},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)
    port
  end

  # The attached-request probe, published as an app of the person's own
  # whose need `api_key` is attached by the rule: it sends its input as
  # its one request and answers what it got.
  defp publish_probe!(ctx) do
    name = "launch-probe-#{System.unique_integer([:positive])}"

    egress = %{
      "domains" => ["127.0.0.1"],
      "methods" => ["GET"],
      "schemes" => ["http"],
      "private_ips" => ["127.0.0.1"]
    }

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:upstream.test",
          "reason" => "to call the upstream with your key",
          "fields" => ["KEY"],
          "attach" => @rule,
          "hosts" => ["127.0.0.1"]
        }
      },
      "caps" => %{"egress" => egress}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    "catalyst:local." <> name
  end

  # A launch of `probe` whose one request is a GET of the upstream's
  # `/hello`, attached with its need's account.
  defp probe_args(probe, port) do
    %{
      "reference" => probe <> ":1.0.0",
      "input" => %{
        "connection" => "api_key",
        "method" => "GET",
        "url" => "http://127.0.0.1:#{port}/hello",
        "headers" => %{"accept" => "text/plain"}
      }
    }
  end

  defp attached_entry!(ctx, port, label, secret) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "launch #{label} #{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "upstream.test",
        fields: %{"KEY" => secret},
        destination: %{
          "hosts" => ["127.0.0.1"],
          "scheme" => "http",
          "port" => port,
          "methods" => ["GET"]
        }
      })

    entry
  end

  # An app of the person's own whose need is disclosed to it: a launch that
  # names an account is refused or admitted before anything of it runs.
  defp publish_app!(ctx) do
    name = "launch-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "fields" => ["KEY"],
          "hosts" => ["api.example.com"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    "reagent:local." <> name
  end

  defp disclosed_entry!(ctx, label) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "launch #{label} #{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "example.com",
        fields: %{"KEY" => "k-#{label}"},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    entry
  end

  # `ref`'s grant on its own calls, through the consent walk.
  defp grant!(ctx, ref, bindings) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: bindings}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, %{profile_id: profile_id}} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    profile_id
  end

  defp launched_of(ctx, ref) do
    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{ref}%"),
        select: e.id
      )
    )
  end

  defp upstream! do
    receive do
      {:upstream, request} -> request
    after
      10_000 -> flunk("the upstream received nothing")
    end
  end

  @decided_work "The account \"Work\" is not the one this run was decided on, so nothing " <>
                  "ran: propose it again to run it on the account as it stands now"
  @decided_default "The default account is not the one this run was decided on, so nothing " <>
                     "ran: propose it again to run it on the account as it stands now"

  defp attempts_of(ctx) do
    Arca.Repo.aggregate(
      from(a in Arca.Schemas.ExecutionAttempt, where: a.athanor_id == ^ctx.athanor_id),
      :count
    )
  end

  defp gate_runs(ctx) do
    Arca.Repo.aggregate(
      from(d in Arca.Schemas.DecisionLog,
        where: d.athanor_id == ^ctx.athanor_id and d.tool == "execution" and d.action == "run"
      ),
      :count
    )
  end

  # The decided launch `step` runs nothing: refused with `sentence` by the
  # dispatcher's own check, before the gate is asked — no decision of the
  # gate's, no execution row and no attempt.
  defp ran_nothing!(ctx, step, decided, app, sentence) do
    attempts = attempts_of(ctx)
    decisions = gate_runs(ctx)
    assert Launch.run(ctx, step, decided) == {:refused, {:conflict, sentence}}
    assert launched_of(ctx, app) == []
    assert attempts_of(ctx) == attempts
    assert gate_runs(ctx) == decisions
  end

  test "a launch naming an account attaches that account's value at the upstream, never the " <>
         "default's, and consumes its once under its own binding key",
       %{ctx: ctx, thread: thread, pins: pins} do
    port = upstream_port!(ctx)
    probe = publish_probe!(ctx)
    default = attached_entry!(ctx, port, "default", @default_secret)
    named = attached_entry!(ctx, port, "supabase 2", @named_secret)

    profile_id =
      grant!(ctx, probe, [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", name: "Supabase 2", entry_id: named.id, lifetime: %{kind: "once"}}
      ])

    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    args = Map.put(probe_args(probe, port), "connection", "Supabase 2")
    step = launch_step!(ctx, turn, args)
    decided = decided!(ctx, turn, args)
    assert {:run, decided} == run_on(args, %{vault_entry: named.id, name: "Supabase 2"})

    assert {:ok, %{execution_id: execution_id}} = Launch.run(ctx, step, decided)
    assert is_binary(execution_id)

    # CYFR attached the named account's value to the request the app made,
    # never the default's.
    sent = upstream!()
    assert sent.path == "/hello"
    assert for({"x-api-key", value} <- sent.headers, do: value) == [@named_secret]

    # The once is consumed by the launch's root under the named binding's
    # own key; the default's stands untouched.
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(probe)

    {:ok, head} =
      Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)

    refs = Map.new(head.vault_refs, &{&1.binding_key, &1})

    assert %{lifetime_kind: "once", consumed_by_root: ^execution_id} =
             refs[Prima.Authority.Blob.binding_key(name_ref, "@ingress", "Supabase 2")]

    assert %{consumed_by_root: nil} =
             refs[Prima.Authority.Blob.binding_key(name_ref, "@ingress", nil)]
  end

  test "a decided launch runs under the account its decision resolved: another entry, a name " <>
         "gone, another stored spelling or an account it did not resolve runs nothing",
       %{ctx: ctx, thread: thread, pins: pins} do
    app = publish_app!(ctx)
    default = disclosed_entry!(ctx, "default")
    work = disclosed_entry!(ctx, "work")
    other = disclosed_entry!(ctx, "other")

    work_on =
      &[%{need: "api_key", entry_id: default.id}, %{need: "api_key", name: &1, entry_id: &2}]

    grant!(ctx, app, work_on.("Work", work.id))

    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    named = %{"reference" => app <> ":1.0.0", "input" => %{}, "connection" => "Work"}
    plain = Map.delete(named, "connection")

    # Decided on Work's entry; the grant has since moved Work to another.
    step = launch_step!(ctx, turn, named)
    decided = decided!(ctx, turn, named)
    assert {:run, decided} == run_on(named, %{vault_entry: work.id, name: "Work"})
    grant!(ctx, app, work_on.("Work", other.id))
    ran_nothing!(ctx, step, decided, app, @decided_work)

    # A decision that resolved no account for a call naming one, or one
    # for a call naming none.
    step = launch_step!(ctx, turn, named)
    ran_nothing!(ctx, step, %{decided!(ctx, turn, named) | account: nil}, app, @decided_work)

    step = launch_step!(ctx, turn, plain)
    unnamed = %{decided!(ctx, turn, plain) | account: %{vault_entry: other.id, name: "Work"}}
    ran_nothing!(ctx, step, unnamed, app, @decided_default)

    # The name is gone from the app's grant.
    step = launch_step!(ctx, turn, named)
    decided = decided!(ctx, turn, named)
    grant!(ctx, app, [%{need: "api_key", entry_id: default.id}])
    ran_nothing!(ctx, step, decided, app, @decided_work)

    # The grant now stores the account under another spelling, on the same
    # entry: the decision bound `Work`, which is not the name its binding
    # stores.
    grant!(ctx, app, work_on.("Work", other.id))
    step = launch_step!(ctx, turn, named)
    decided = decided!(ctx, turn, named)
    grant!(ctx, app, work_on.("WORK", other.id))
    ran_nothing!(ctx, step, decided, app, @decided_work)

    # A launch the model spells in yet another case is decided under the
    # stored name, on its entry, and launches.
    lower = %{named | "connection" => "work"}
    assert decide(ctx, turn, lower) == run_on(lower, %{vault_entry: other.id, name: "WORK"})
    step = launch_step!(ctx, turn, lower)
    _ = Launch.run(ctx, step, decided!(ctx, turn, lower))
    assert [_launched] = launched_of(ctx, app)
  end

  # ---------------------------------------------------------------------------
  # The entry the decision resolved, at the run's root
  # ---------------------------------------------------------------------------

  @root_load {Sanctum.Consent.Loader, :load_root, 3}
  @attempt_open {Opus.Attempt, :open, 1}

  # An app whose own calls bind a default and `Work`, with a third entry
  # a later grant can move `Work` to; and a launch of it naming `Work`.
  defp work_app!(ctx) do
    app = publish_app!(ctx)
    default = disclosed_entry!(ctx, "default")
    work = disclosed_entry!(ctx, "work")
    other = disclosed_entry!(ctx, "other")

    grant!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: work.id}
    ])

    %{
      app: app,
      default: default,
      work: work,
      other: other,
      args: %{"reference" => app <> ":1.0.0", "input" => %{}, "connection" => "Work"}
    }
  end

  # `fun`'s answer, and the calls this process made to `mfas` while it ran,
  # in order. A process's call trace is not delivered to itself, so a
  # collector takes it; every trace message is delivered before the
  # collector is asked for what it holds.
  defp traced(mfas, fun) do
    test = self()
    collector = spawn_link(fn -> collect(test, []) end)

    on_exit(fn -> for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global]) end)

    # A pattern applies only to a loaded module, so each is loaded first,
    # and one that matched nothing fails here rather than tracing nothing.
    for {module, _function, _arity} = mfa <- mfas do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:global]) == 1
    end

    :erlang.trace(test, true, [:call, {:tracer, collector}])

    answer =
      try do
        fun.()
      after
        :erlang.trace(test, false, [:call])
      end

    delivered = :erlang.trace_delivered(test)
    assert_receive {:trace_delivered, ^test, ^delivered}, 5_000
    send(collector, {:done, delivered})
    assert_receive {:collected, ^delivered, calls}, 5_000
    {answer, calls}
  end

  defp collect(test, calls) do
    receive do
      {:trace, ^test, :call, call} -> collect(test, [call | calls])
      {:done, ref} -> send(test, {:collected, ref, Enum.reverse(calls)})
    end
  end

  defp args_of(calls, {module, function, _arity}),
    do: for({^module, ^function, args} <- calls, do: args)

  # A launch of `work_app!/1`'s app naming `Work`, decided on Work's
  # entry: the fixture, with the step the loop hands the dispatcher and
  # its decision.
  defp decided_work_launch!(ctx, thread, pins) do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{args: args, work: work} = fixture = work_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = launch_step!(ctx, turn, args)
    decided = decided!(ctx, turn, args)
    assert {:run, decided} == run_on(args, %{vault_entry: work.id, name: "Work"})
    Map.merge(fixture, %{step: step, decided: decided})
  end

  # The app's grant becomes `bindings` at the gate's admission of the
  # dispatched call: past the dispatcher's own check, and before the
  # provider builds the run's root.
  defp regrant_at_admission!(ctx, app, bindings) do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :decision, :admitted],
        fn _event, _measurements, %{tool: tool, action: action}, _config ->
          if self() == test and {tool, action} == {"execution", "run"} and
               not Process.get(:regranted, false) do
            Process.put(:regranted, true)
            grant!(ctx, app, bindings)
            send(test, :regranted)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The launch `step` is refused in the stale sentence a person reads, with
  # nothing started: no execution row and no attempt. The gate's trail
  # records the call as the conflict it is, and nothing reads the refusal
  # as a reason the refusal table does not know.
  defp assert_stale_at_root!(ctx, step, decided, app) do
    attempts = attempts_of(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Launch.run(ctx, step, decided) == {:refused, {:conflict, @decided_work}}
      end)

    assert_received :regranted

    assert launched_of(ctx, app) == []
    assert attempts_of(ctx) == attempts

    assert Arca.Repo.all(
             from(d in Arca.Schemas.DecisionLog,
               where:
                 d.athanor_id == ^ctx.athanor_id and d.tool == "execution" and d.action == "run",
               select: {d.admission, d.completion, d.completion_class}
             )
           ) == [{"admitted", "failed", "conflict"}]

    refute log =~ "Prima.Refusal"
  end

  test "a head that binds the launch's account to another entry after the dispatcher's check " <>
         "refuses at the run's root, in the stale sentence, with nothing started",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, default: default, other: other, step: step, decided: decided} =
      decided_work_launch!(ctx, thread, pins)

    regrant_at_admission!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: other.id}
    ])

    assert_stale_at_root!(ctx, step, decided, app)
  end

  test "a head that drops the launch's account after the dispatcher's check refuses at the " <>
         "run's root as the same stale launch, never as an account to grant",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, default: default, step: step, decided: decided} =
      decided_work_launch!(ctx, thread, pins)

    regrant_at_admission!(ctx, app, [%{need: "api_key", entry_id: default.id}])

    assert_stale_at_root!(ctx, step, decided, app)
  end

  test "a head that stores the launch's account under another spelling, on the same entry, " <>
         "after the dispatcher's check refuses at the run's root as stale",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, default: default, work: work, step: step, decided: decided} =
      decided_work_launch!(ctx, thread, pins)

    regrant_at_admission!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "WORK", entry_id: work.id}
    ])

    assert_stale_at_root!(ctx, step, decided, app)
  end

  test "an unchanged account's launch is rooted on the entry its decision resolved, read with " <>
         "that entry in hand, and the run carries no expectation past its root's admission",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, work: work, step: step, decided: decided} =
      decided_work_launch!(ctx, thread, pins)

    {_dispatched, calls} =
      traced([@root_load, @attempt_open], fn -> Launch.run(ctx, step, decided) end)

    # A decided launch binds no grant revision, so the dispatcher loads no
    # grant of its own: the one load is the root's, which reads the head
    # with the decided account in hand, the entry the decision resolved
    # and the name its binding stored.
    assert [[root_ctx, _profile, _opts]] = args_of(calls, @root_load)
    assert Map.fetch(root_ctx, :approved_entry) == {:ok, %{entry: work.id, name: "Work"}}

    # The run is admitted under that entry, and the context its attempt
    # (and so its chain, its children and its calls), its close and its
    # assignment carry on holds none.
    assert [execution_id] = launched_of(ctx, app)
    assert [[opened]] = args_of(calls, @attempt_open)
    assert opened[:execution_id] == execution_id
    assert opened[:authority].resources.vault.entry_id == work.id
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(app)

    assert opened[:authority].resources.vault.binding_key ==
             Prima.Authority.Blob.binding_key(name_ref, "@ingress", "Work")

    for carried <- [opened[:ctx], opened[:close].ctx, opened[:assignment].ctx] do
      assert Map.fetch(carried, :approved_entry) == {:ok, nil}
      assert Map.fetch(carried, :launch) == {:ok, nil}
    end
  end

  test "an external execution.run cannot supply the account a launch's decision resolved: an " <>
         "`approved_entry` argument is refused, and the run it starts is rooted with none",
       %{ctx: ctx} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, other: other, args: args} = work_app!(ctx)
    run = Map.put(args, "action", "run")

    {refused, calls} =
      traced([@root_load], fn ->
        Sanctum.Gate.call_external("execution", ctx, Map.put(run, "approved_entry", other.id))
      end)

    assert {:error,
            %Prima.Refusal{
              class: :invalid_argument,
              stage: :admission,
              message: "Unknown field: approved_entry"
            }} = refused

    assert args_of(calls, @root_load) == []
    assert launched_of(ctx, app) == []

    # Named nowhere, the expectation is absent: the root is loaded with
    # none, and the run goes ahead under the account the call names.
    {_ran, calls} =
      traced([@root_load], fn -> Sanctum.Gate.call_external("execution", ctx, run) end)

    assert [[root_ctx, _profile, _opts]] = args_of(calls, @root_load)
    assert Map.fetch(root_ctx, :approved_entry) == {:ok, nil}
    assert [_launched] = launched_of(ctx, app)
  end

  # ---------------------------------------------------------------------------
  # What the launch carries: the turn's read threads, on the grant as it stands
  # ---------------------------------------------------------------------------

  # An app of the person's own granted with a default entry alone: its one
  # exit is `api.example.com`.
  defp granted_app!(ctx) do
    app = publish_app!(ctx)
    default = disclosed_entry!(ctx, "default")
    grant!(ctx, app, [%{need: "api_key", entry_id: default.id}])
    %{app: app, default: default, args: %{"reference" => app <> ":1.0.0", "input" => %{}}}
  end

  # An app of the person's own with no exit at all, no egress and no tool
  # server, granted with nothing to bind.
  defp quiet_app!(ctx) do
    name = "quiet-app-#{System.unique_integer([:positive])}"

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(%{"name" => name, "version" => "1.0.0", "type" => "reagent"})
      })

    app = "reagent:local." <> name
    grant!(ctx, app, [])
    %{app: app, args: %{"reference" => app <> ":1.0.0", "input" => %{}}}
  end

  defp consent_of(ctx, app) do
    {:ok, %{consent_id: consent_id}} = Opus.authority_for(ctx, :default, app)
    consent_id
  end

  test "a decided launch runs on the grant its app roots at when it runs: one granted since " <>
         "the decision runs on that grant, seeded with the turn's read threads",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    app = publish_app!(ctx)
    args = %{"reference" => app <> ":1.0.0", "input" => %{}}
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    read!(ctx, turn, ["thr_read"])

    # Decided while the app has no grant: the decision reads none.
    root_id = Prima.UUID7.execution_id()
    step = launch_step!(ctx, turn, args, root_id)
    decided = decided!(ctx, turn, args)
    assert {:run, decided} == run_on(args)

    default = disclosed_entry!(ctx, "default")
    grant!(ctx, app, [%{need: "api_key", entry_id: default.id}])
    dispatched = Launch.run(ctx, step, decided)

    # The grant made since is the one the root loads, and the root is
    # seeded with the turn's read threads.
    assert launched_of(ctx, app) == [root_id], "launch answered #{inspect(dispatched)}"
    actor = Sanctum.Context.actor(ctx)
    assert %{consent_id: consent_id} = Arca.Execution.get_tenant(actor, root_id)
    assert consent_id == consent_of(ctx, app)
    assert Arca.Execution.read_threads(actor, root_id) == {:ok, ["thr_read"]}
  end

  test "a decided launch runs once as the turn's person, under its stored origin, with its " <>
         "recorded call's arguments, under the step's id, seeded with the turn's read threads",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :programmatic}, thread, pins)
    read!(ctx, turn, ["thr_read", "thr_other"])
    root_id = Prima.UUID7.execution_id()

    # The recorded call names a lineage of its own: it is dropped.
    forged = Map.merge(args, %{"parent_execution_id" => "exec_forged", "thread_id" => "thr_x"})
    step = launch_step!(ctx, turn, forged, root_id)
    dispatched = Launch.run(ctx, step, decided!(ctx, turn, forged))

    assert {:ok, %{execution_id: ^root_id}} = dispatched

    assert [%{user_id: user_id, origin: "programmatic", parent: nil}] =
             Arca.Repo.all(
               from(e in Arca.Schemas.Execution,
                 where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{app}%"),
                 select: %{user_id: e.user_id, origin: e.origin, parent: e.parent_execution_id}
               )
             )

    assert user_id == turn.requested_by
    actor = Sanctum.Context.actor(ctx)
    assert Arca.Execution.read_threads(actor, root_id) == {:ok, ["thr_other", "thr_read"]}

    # Its start names its attempt alone, and nothing of what it read.
    assert {:ok, [%{type: "execution.started"} = started | _]} =
             Arca.ExecutionEvents.since(actor, root_id, 0)

    assert Map.keys(Arca.ExecutionEvents.data(started)) == ["attempt"]

    # Its caller is Aqua, the crew's one caller whichever member's turn
    # launched it, which the stamp alone carries, not the person it runs as.
    assert %{caller: "agent:aqua"} = Arca.Execution.get_tenant(actor, root_id)
  end

  test "a decided launch whose turn read a thread since its decision runs, seeded with every " <>
         "read thread the turn holds when it is dispatched",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    read!(ctx, turn, ["thr_read"])
    root_id = Prima.UUID7.execution_id()
    step = launch_step!(ctx, turn, args, root_id)
    decided = decided!(ctx, turn, args)
    assert {:run, decided} == run_on(args)

    # Another thread's posts, read since the decision: the launch runs
    # all the same, its root seeded with that thread beside what the turn
    # read before it.
    read!(ctx, turn, ["thr_other"])
    assert {:ok, %{execution_id: ^root_id}} = Launch.run(ctx, step, decided)
    assert launched_of(ctx, app) == [root_id]

    assert Arca.Execution.read_threads(Sanctum.Context.actor(ctx), root_id) ==
             {:ok, ["thr_other", "thr_read"]}
  end

  test "a decided launch whose turn's person was denied since its decision runs nothing and " <>
         "asks the gate nothing",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = launch_step!(ctx, turn, args)
    decided = decided!(ctx, turn, args)
    {:ok, person} = Sanctum.Tenancy.Users.get(turn.requested_by)
    {:ok, _} = Sanctum.Tenancy.Users.deny(person)
    attempts = attempts_of(ctx)
    decisions = gate_runs(ctx)

    assert Launch.run(ctx, step, decided) == {:refused, {:approver_unavailable, :denied}}
    assert launched_of(ctx, app) == []
    assert attempts_of(ctx) == attempts
    assert gate_runs(ctx) == decisions
  end

  # ---------------------------------------------------------------------------
  # The decision, and what a launch's sends reach
  # ---------------------------------------------------------------------------

  test "a launch is decided to run on its call whatever the turn read, with a grant or " <>
         "with none, binding no grant, and one not offered is denied",
       %{ctx: ctx, thread: thread, pins: pins} do
    ungranted = publish_app!(ctx)

    apps = [
      granted_app!(ctx).args,
      quiet_app!(ctx).args,
      %{"reference" => ungranted <> ":1.0.0", "input" => %{}}
    ]

    turn = started!(%{ctx | origin: :interactive}, thread, pins)

    # Nothing read, then another thread's posts read: each launch is
    # decided the same, on its call and nothing of what the turn read.
    for read <- [[], ["thr_other"]] do
      if read != [], do: read!(ctx, turn, read)
      for args <- apps, do: assert(decide(ctx, turn, args) == run_on(args))
    end

    for args <- apps do
      assert decide(ctx, turn, args, %{}) ==
               {:deny, "execution.run is not among the tools Aqua is offered"}
    end
  end

  # A turn whose prompt is composed now, as the loop's first model step
  # opens with it: one of a thread of its own, since one turn holds a
  # thread at a time. The step opens with what the turn's rows carry,
  # here none. Answers the turn and the prompt's text.
  defp prompted!(ctx, pins) do
    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    %{text: text} = Aqua.Prompt.compose(ctx, agent: %{"prompt" => ""})
    read!(ctx, turn, [])
    {turn, text}
  end

  test "an about-you page in a later turn's prompt seeds its launch with no thread, the " <>
         "person's own or one Aqua wrote in a thread",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{args: args} = quiet_app!(ctx)
    actor = Sanctum.Context.actor(ctx)

    # A launch dispatched in a later turn whose prompt shows `page`: the
    # read threads its root is seeded with.
    launches = fn page ->
      {turn, text} = prompted!(ctx, pins)
      assert text =~ page
      root_id = Prima.UUID7.execution_id()
      step = launch_step!(ctx, turn, args, root_id)
      assert {:ok, %{execution_id: ^root_id}} = Launch.run(ctx, step, decided!(ctx, turn, args))
      Arca.Execution.read_threads(actor, root_id)
    end

    # The person's own page.
    {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Flies to Lisbon on the 3rd.")
    assert launches.("Flies to Lisbon on the 3rd.") == {:ok, []}

    # Aqua's page, written in a thread: what a note holds outlives that
    # thread, so a turn that reads the page never read the thread.
    {:ok, _} =
      Aqua.Notes.pin(ctx, "about-you", "Fares rise Monday.",
        kept_by: Prima.Author.agent(),
        thread: thread.id
      )

    assert launches.("Fares rise Monday.") == {:ok, []}
  end

  test "a decided launch's sends reach the host its grant allows whatever the turn read: " <>
         "another thread's posts",
       %{ctx: ctx, thread: thread, pins: pins} do
    port = upstream_port!(ctx)
    default = attached_entry!(ctx, port, "default", @default_secret)
    probe = publish_probe!(ctx)
    grant!(ctx, probe, [%{need: "api_key", entry_id: default.id}])
    turn = started!(%{ctx | origin: :interactive}, thread, pins)

    launch = fn ->
      args = probe_args(probe, port)
      step = launch_step!(ctx, turn, args)
      Launch.run(ctx, step, decided!(ctx, turn, args))
    end

    # The turn read another thread's posts: the send goes out.
    read!(ctx, turn, ["thr_other"])
    assert {:ok, _} = launch.()
    assert %{path: "/hello"} = upstream!()
  end

  test "a launch naming an account decides on the entry it resolves to, and a name " <>
         "its app does not bind is setup required",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, work: work, args: args} = work_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    lower = %{args | "connection" => "work"}

    assert decide(ctx, turn, lower) == run_on(lower, %{vault_entry: work.id, name: "Work"})
    versioned = app <> ":1.0.0"

    assert decide(ctx, turn, %{args | "connection" => "Home"}) ==
             {:setup_required, versioned, {nil, "Home"}}
  end

  test "a launch naming an account of an app with no grant is setup required, and " <>
         "one naming a profile that cannot be told is refused, never a setup",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, args: args} = granted_app!(ctx)
    ungranted = publish_app!(ctx) <> ":1.0.0"
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    named = Map.put(args, "connection", "Work")

    assert decide(ctx, turn, %{named | "reference" => ungranted}) ==
             {:setup_required, ungranted, {nil, "Work"}}

    assert decide(ctx, turn, Map.put(named, "profile", "elsewhere")) ==
             {:refuse,
              "the account \"Work\" of #{app}:1.0.0 could not be read: " <>
                Aqua.Ops.render_refusal({:not_found, "elsewhere"})}
  end

  test "a launch of an app with no grant runs on none: the gate answers that the " <>
         "app is not granted, and nothing of it runs",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    app = publish_app!(ctx)
    args = %{"reference" => app <> ":1.0.0", "input" => %{}}
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = launch_step!(ctx, turn, args)
    refused = {:consent_required, %{cause: :no_grant, ref: app}}
    assert Launch.run(ctx, step, decided!(ctx, turn, args)) == {:error, refused}
    assert %Prima.Refusal{class: :consent_required} = Sanctum.Refusals.classify(refused)
    assert launched_of(ctx, app) == []
  end

  # What the loop hands the dispatcher for a launch of `args`: `decided`,
  # made on that call.
  defp handed(decided, args), do: %{decided | call: %{action: "run", args: args}}

  test "a decided launch refuses Aqua itself or a hand its step's row names, and a step whose " <>
         "row records no launch",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    decided = decided!(ctx, turn, args)

    soul = %{"reference" => @soul, "input" => %{}}
    agent = launch_step!(ctx, turn, soul)

    assert Launch.run(ctx, agent, handed(decided, soul)) ==
             {:refused, {:invalid_argument, "an agent is not a tool to run"}}

    files = %{"reference" => "catalyst:local.files", "input" => %{}}
    hand = launch_step!(ctx, turn, files)

    assert Launch.run(ctx, hand, handed(decided, files)) ==
             {:refused, {:invalid_argument, "catalyst:local.files is a hand, not a launch"}}

    # A step recorded for anything but a launch, or naming no call, records
    # none: nothing runs.
    step = launch_step!(ctx, turn, args)

    for unlaunched <- [
          %{step | kind: "tool"},
          %{step | action: "logs"},
          %{step | message_id: nil}
        ] do
      assert Launch.run(ctx, unlaunched, decided) ==
               {:refused, {:invalid_argument, "the step records no launch"}}
    end

    # With no decision a step runs nothing.
    assert Launch.run(ctx, step) == {:refused, :not_approved}
  end

  test "a decided launch runs what its step's row records: a decision made on another call runs " <>
         "nothing and asks the gate nothing",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    decided = decided!(ctx, turn, args)
    step = launch_step!(ctx, turn, args)

    sentence =
      "the call this run was decided on is not the one its step recorded, so nothing ran"

    for other <- [
          handed(decided, Map.put(args, "input", %{"n" => 1})),
          %{decided | call: %{action: "run_stream", args: args}},
          handed(decided, Map.put(args, "connection", "Work"))
        ] do
      attempts = attempts_of(ctx)
      decisions = gate_runs(ctx)
      assert Launch.run(ctx, step, other) == {:refused, {:invalid_argument, sentence}}
      assert launched_of(ctx, app) == []
      assert attempts_of(ctx) == attempts
      assert gate_runs(ctx) == decisions
    end

    # The row's own action key, which a launch's action replaces, is no
    # other call.
    named = launch_step!(ctx, turn, Map.put(args, "action", "run"))
    assert {:ok, %{execution_id: _}} = Launch.run(ctx, named, decided)
    assert [_once] = launched_of(ctx, app)
  end

  # ---------------------------------------------------------------------------
  # The app's own head read damaged
  # ---------------------------------------------------------------------------

  @zero_digest "sha256:" <> String.duplicate("0", 64)

  defp own_profile_id(ctx, app) do
    {:ok, [%{id: id}]} = Sanctum.Consent.profiles(ctx, app)
    id
  end

  defp damaged_head_sentence(profile_id),
    do:
      "This app's consent is damaged and cannot be used — revoke profile #{profile_id} " <>
        "and grant it again."

  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile, where: p.athanor_id == ^ctx.athanor_id and p.id == ^id),
        set: changes
      )
  end

  # The account is read again, as the turn's person, before anything runs:
  # a head stored damaged since the launch was decided is that damage, in
  # its own class and sentence, never a stale launch to propose again and
  # never an outcome that could not be confirmed. Nothing reaches the gate.
  test "a launch naming an account over the app's own head stored damaged is refused as the " <>
         "damaged head, with nothing started",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, step: step, decided: decided} = decided_work_launch!(ctx, thread, pins)
    profile_id = own_profile_id(ctx, app)
    :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id, blob_digest: @zero_digest)
    attempts = attempts_of(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Launch.run(ctx, step, decided) == {:refused, {:head_corrupt, profile_id}}
      end)

    assert launched_of(ctx, app) == []
    assert attempts_of(ctx) == attempts

    assert Arca.Repo.all(
             from(d in Arca.Schemas.DecisionLog,
               where:
                 d.athanor_id == ^ctx.athanor_id and d.tool == "execution" and d.action == "run",
               select: d.admission
             )
           ) == []

    refute log =~ "Prima.Refusal"

    assert %Prima.Refusal{class: :corrupt, message: message} =
             Sanctum.Refusals.classify({:head_corrupt, profile_id})

    assert message == damaged_head_sentence(profile_id)
  end

  # A launch is decided only over a head that reads: one stored damaged,
  # or an active profile that lost its head, refuses the call in the
  # damaged head's sentence, never a setup to make over a profile that
  # exists.
  test "a launch naming an account over the app's own head stored damaged, or lost, is " <>
         "refused as the damaged head",
       %{ctx: ctx} do
    for damage <- [
          &Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, &1, blob_digest: @zero_digest),
          &set_profile!(ctx, &1, head_consent_id: nil)
        ] do
      %{app: app, work: work, args: args} = work_app!(ctx)
      profile_id = own_profile_id(ctx, app)
      {:ok, call} = Aqua.Loop.Binding.resolve("execution.run", args)
      decide = fn -> Aqua.Loop.Policy.decide(call, @offered, ctx: ctx) end

      assert decide.() == run_on(args, %{vault_entry: work.id, name: "Work"})

      damage.(profile_id)

      assert decide.() ==
               {:refuse,
                "the account \"Work\" of #{call.target} could not be read: " <>
                  damaged_head_sentence(profile_id)}
    end
  end

  test "a launch whose app's grant cannot be read is decided, and its root refuses " <>
         "it as the damaged head, never as an app to grant",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    profile_id = own_profile_id(ctx, app)
    :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id, blob_digest: @zero_digest)

    step = launch_step!(ctx, turn, args)
    decided = decided!(ctx, turn, args)
    assert {:run, decided} == run_on(args)
    assert Launch.run(ctx, step, decided) == {:error, {:head_corrupt, profile_id}}
    assert launched_of(ctx, app) == []

    assert %Prima.Refusal{class: :corrupt, message: message} =
             Sanctum.Refusals.classify({:head_corrupt, profile_id})

    assert message == damaged_head_sentence(profile_id)
  end

  test "an origin the sender's request names is not the turn's", %{
    ctx: ctx,
    thread: thread
  } do
    sender = %{ctx | origin: :programmatic}

    {:ok, %{turn: turn}} =
      Tape.accept(sender, thread.id, %{
        message: %{author: sender.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: sender.user_id, origin: :interactive}
      })

    assert turn.origin == "programmatic"
  end
end
