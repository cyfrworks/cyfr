# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LaunchTest do
  @moduledoc """
  An approved launch runs as the person who approved it, under the origin
  the approved turn's row stores — never `interactive` inferred from the
  person approving. A programmatic turn's launch stays programmatic, and no
  turn is written without an origin.

  It runs only as its card bound it: the turn's sources and the app's
  grant as they stood when the card was drawn. A source the turn read
  since, or another revision of the grant, refuses it as stale before
  anything starts; otherwise its root runs under the step's id, seeded
  with those sources and letting flow the classes the card named.

  A launch with no card stands on the app's grant: under `auto` it is
  decided to run where that grant covers what the turn has read, and runs
  as the turn's person, under the turn's stored origin, with the
  arguments of its recorded call, seeded with the turn's sources and
  letting no class flow. Anything the decision read that moved before it
  dispatches — a source, the grant's revision, the account — runs
  nothing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.{Approvals, Launch, Tape}
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

    {:ok, ctx: ctx, thread: thread, pins: pins, approver: %{ctx | origin: :interactive}}
  end

  # The person of their own athanor, signed in through Prism: who sends the
  # turn and whose approval, given from the console, the launch runs as.
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
          agent_mode: "auto",
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })
      )

    turn
  end

  # A launch card for the application, as the loop opens it, approved by
  # `approver`: the step the loop hands the dispatcher.
  defp approved_launch!(ctx, turn, approver) do
    {resolved, step_id} = launch_card(ctx, turn, approver)
    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} = resolved
    {:ok, step} = Tape.step(ctx, step_id)
    step
  end

  defp launch_card(ctx, turn, approver) do
    proposal = bound_proposal(ctx, turn, %{"reference" => @application, "input" => %{}})

    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "execution.run",
            tool: "execution",
            action: "run",
            arguments: proposal["args"],
            kind: "execute",
            step_kind: "launch"
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "execution.run",
      "action_kind" => "execute",
      "standing" => nil,
      "tool_call_id" => "c1",
      "proposal" => proposal
    }

    {:ok, %{approval: approval}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: "execution.run?", payload: %{"intent" => intent}},
        expires_at: nil
      })

    {Approvals.resolve(approver, approval.id, %{decision: :approved}), step.id}
  end

  # The proposal of a launch card for `args` as the loop draws one: the
  # call, the account its card binds when `vault_entry` is given, the
  # turn's sources as they stand and what they let flow to the app's grant
  # (`Aqua.Loop.Policy.launch_flow/3`).
  defp bound_proposal(ctx, turn, args, vault_entry \\ nil) do
    {:ok, call} = Aqua.Loop.Binding.resolve("execution.run", args)
    sources = turn_sources(ctx, turn)
    launch = call |> Aqua.Loop.Policy.launch_flow(ctx, sources) |> Map.put(:sources, sources)
    account = if vault_entry, do: %{vault_entry: vault_entry, name: args["connection"]}
    Aqua.Loop.Policy.proposal(call, account, launch)
  end

  defp turn_sources(ctx, turn) do
    {:ok, %{sources: sources}} = Tape.turn(ctx, turn.id)
    Prima.Source.decode(sources)
  end

  defp launched(ctx) do
    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{@application}%"),
        select: %{user_id: e.user_id, origin: e.origin, parent: e.parent_execution_id}
      )
    )
  end

  test "a programmatic turn's launch, approved by a person, runs as that person and stays programmatic",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    sender = %{ctx | origin: :programmatic}
    turn = started!(sender, thread, pins)
    assert turn.origin == "programmatic"

    step = approved_launch!(ctx, turn, approver)
    dispatched = Launch.dispatch(ctx, step)

    assert [%{user_id: user_id, origin: origin, parent: nil}] = launched(ctx),
           "launch answered #{inspect(dispatched)}"

    assert user_id == approver.user_id
    assert origin == "programmatic"
  end

  test "an interactive turn's launch keeps the turn's origin", %{
    ctx: ctx,
    thread: thread,
    pins: pins,
    approver: approver
  } do
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = approved_launch!(ctx, turn, approver)
    dispatched = Launch.dispatch(ctx, step)

    assert [%{origin: "interactive"}] = launched(ctx), "launch answered #{inspect(dispatched)}"
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

  # The attached-request probe, published as an app of the person's own
  # whose need `api_key` is attached by the rule: it sends its input as its
  # one request and answers what it got.
  defp publish_probe!(ctx) do
    name = "launch-probe-#{System.unique_integer([:positive])}"

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
      "caps" => %{
        "egress" => %{
          "domains" => ["127.0.0.1"],
          "methods" => ["GET"],
          "schemes" => ["http"],
          "private_ips" => ["127.0.0.1"]
        }
      }
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

  # A launch card for `args`, its proposal binding `vault_entry` when one
  # is given, as the loop opens it; approved by `approver`. Answers the step.
  defp approved_named_launch!(ctx, turn, approver, args, vault_entry, root_id \\ nil) do
    proposal = bound_proposal(ctx, turn, args, vault_entry)

    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "execution.run",
            tool: "execution",
            action: "run",
            arguments: args,
            kind: "execute",
            step_kind: "launch",
            child_execution_id: root_id
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "execution.run",
      "action_kind" => "execute",
      "standing" => false,
      "tool_call_id" => "c1",
      "proposal" => proposal
    }

    {:ok, %{approval: approval}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: "execution.run?", payload: %{"intent" => intent}},
        expires_at: nil
      })

    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} =
             Approvals.resolve(approver, approval.id, %{decision: :approved})

    {:ok, step} = Tape.step(ctx, step.id)
    step
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

  test "a launch naming an account attaches that account's value at the upstream, never the " <>
         "default's, and consumes its once under its own binding key",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
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

    probe = publish_probe!(ctx)
    default = attached_entry!(ctx, port, "default", @default_secret)
    named = attached_entry!(ctx, port, "supabase 2", @named_secret)

    profile_id =
      grant!(ctx, probe, [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", name: "Supabase 2", entry_id: named.id, lifetime: %{kind: "once"}}
      ])

    turn = started!(%{ctx | origin: :interactive}, thread, pins)

    args = %{
      "reference" => probe <> ":1.0.0",
      "input" => %{
        "connection" => "api_key",
        "method" => "GET",
        "url" => "http://127.0.0.1:#{port}/hello",
        "headers" => %{"accept" => "text/plain"}
      },
      "connection" => "Supabase 2"
    }

    step = approved_named_launch!(ctx, turn, approver, args, named.id)

    assert {:ok, %{execution_id: execution_id}} = Launch.dispatch(ctx, step)
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

  test "an approval binds the account its card showed: another entry, a name gone or an " <>
         "account the card did not show launches nothing",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    app = publish_app!(ctx)
    default = disclosed_entry!(ctx, "default")
    work = disclosed_entry!(ctx, "work")
    other = disclosed_entry!(ctx, "other")

    grant!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: work.id}
    ])

    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    named = %{"reference" => app <> ":1.0.0", "input" => %{}, "connection" => "Work"}
    plain = Map.delete(named, "connection")

    stale = fn result ->
      assert {:error, {:conflict, sentence}} = result
      assert sentence =~ "not the one this launch was approved for"
      assert launched_of(ctx, app) == []
    end

    # The card showed Work's entry; the grant has since moved Work to another.
    shown_work = approved_named_launch!(ctx, turn, approver, named, work.id)

    grant!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: other.id}
    ])

    stale.(Launch.dispatch(ctx, shown_work))

    # The card showed an account its proposal bound no entry for, or bound
    # an entry for a launch naming none.
    stale.(Launch.dispatch(ctx, approved_named_launch!(ctx, turn, approver, named, nil)))
    stale.(Launch.dispatch(ctx, approved_named_launch!(ctx, turn, approver, plain, other.id)))

    # The name is gone from the app's grant.
    shown_other = approved_named_launch!(ctx, turn, approver, named, other.id)
    grant!(ctx, app, [%{need: "api_key", entry_id: default.id}])
    stale.(Launch.dispatch(ctx, shown_other))

    # The grant now stores the account under another spelling: the card
    # showed `Work`, which is not the name its binding stores.
    grant!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "WORK", entry_id: other.id}
    ])

    stale.(Launch.dispatch(ctx, approved_named_launch!(ctx, turn, approver, named, other.id)))

    # A launch the model spells in yet another case asks under the stored
    # name: the card the loop draws for it shows `WORK` and binds its entry,
    # and that card, approved, launches.
    {:ok, call} = Aqua.Loop.Binding.resolve("execution.run", %{named | "connection" => "work"})

    assert {:ask, %{vault_entry: entry, name: "WORK"} = account} =
             Aqua.Loop.Policy.decide(call, %{"execution.run" => "ask"}, ctx: ctx)

    assert entry == other.id

    assert %{
             "proposal" => %{"args" => %{"connection" => "WORK"} = shown, "vault_entry" => ^entry}
           } =
             Aqua.Loop.Policy.card(call, account: account)

    _ = Launch.dispatch(ctx, approved_named_launch!(ctx, turn, approver, shown, entry))
    assert [_launched] = launched_of(ctx, app)
  end

  # ---------------------------------------------------------------------------
  # The entry the card bound, at the run's root
  # ---------------------------------------------------------------------------

  @stale_work "The account \"Work\" is not the one this launch was approved for, so nothing " <>
                "ran: ask again to approve the account as it stands now"

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

  defp attempts_of(ctx) do
    Arca.Repo.aggregate(
      from(a in Arca.Schemas.ExecutionAttempt, where: a.athanor_id == ^ctx.athanor_id),
      :count
    )
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

  # A launch of `work_app!/1`'s app naming `Work`, its card approved on
  # Work's entry: the fixture, with the step the loop hands the dispatcher.
  defp approved_work_launch!(ctx, thread, pins, approver) do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{args: args, work: work} = fixture = work_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    Map.put(fixture, :step, approved_named_launch!(ctx, turn, approver, args, work.id))
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
  defp assert_stale_at_root!(ctx, step, app) do
    attempts = attempts_of(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Launch.run(ctx, step) == {:refused, {:conflict, @stale_work}}
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
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    %{app: app, default: default, other: other, step: step} =
      approved_work_launch!(ctx, thread, pins, approver)

    regrant_at_admission!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: other.id}
    ])

    assert_stale_at_root!(ctx, step, app)
  end

  test "a head that drops the launch's account after the dispatcher's check refuses at the " <>
         "run's root as the same stale approval, never as an account to grant",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    %{app: app, default: default, step: step} = approved_work_launch!(ctx, thread, pins, approver)

    regrant_at_admission!(ctx, app, [%{need: "api_key", entry_id: default.id}])

    assert_stale_at_root!(ctx, step, app)
  end

  test "a head that stores the launch's account under another spelling, on the same entry, " <>
         "after the dispatcher's check refuses at the run's root as stale",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    %{app: app, default: default, work: work, step: step} =
      approved_work_launch!(ctx, thread, pins, approver)

    regrant_at_admission!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "WORK", entry_id: work.id}
    ])

    assert_stale_at_root!(ctx, step, app)
  end

  test "an unchanged account's launch is rooted on the entry its card bound, read with that " <>
         "entry in hand, and the run carries no expectation past its root's admission",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, work: work, args: args} = work_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = approved_named_launch!(ctx, turn, approver, args, work.id)

    {_dispatched, calls} =
      traced([@root_load, @attempt_open], fn -> Launch.dispatch(ctx, step) end)

    # The root's load reads the head with the approved account in hand:
    # the entry the card bound and the name its binding stored. Before it,
    # the dispatcher's own read of the grant, its early refusal of a moved
    # one, is the approver's and carries nothing the card bound.
    assert [[early_ctx, _, _], [root_ctx, _profile, _opts]] = args_of(calls, @root_load)

    assert {Map.fetch(early_ctx, :approved_entry), Map.fetch(early_ctx, :launch)} ==
             {{:ok, nil}, {:ok, nil}}

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

  test "an external execution.run cannot supply the approved entry: an argument naming it is " <>
         "refused, and the run it starts is rooted with none",
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
  # What the card bound of the launch: the turn's sources and the grant
  # ---------------------------------------------------------------------------

  # An app of the person's own granted with a default entry alone: its one
  # exit is `api.example.com`, and its grant declares no flow to it.
  defp granted_app!(ctx) do
    app = publish_app!(ctx)
    default = disclosed_entry!(ctx, "default")
    grant!(ctx, app, [%{need: "api_key", entry_id: default.id}])
    %{app: app, default: default, args: %{"reference" => app <> ":1.0.0", "input" => %{}}}
  end

  defp stale_launch!(ctx, step, app, reason) do
    attempts = attempts_of(ctx)
    assert Launch.run(ctx, step) == {:refused, {:conflict, Prima.Refusal.message(reason)}}
    assert launched_of(ctx, app) == []
    assert attempts_of(ctx) == attempts
  end

  test "a launch whose turn read a source after its card was approved is refused as stale, " <>
         "with nothing started",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    %{app: app, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = approved_named_launch!(ctx, turn, approver, args, nil)

    # The turn reads outside material after the card was drawn and approved.
    {:ok, _} =
      Tape.record_model_intent(ctx, turn, %{sources: [Prima.Source.outside("news.example")]})

    stale_launch!(ctx, step, app, :approved_sources_moved)
  end

  test "a launch whose app's grant moved since its card was approved is refused as stale, " <>
         "with nothing started",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    %{app: app, default: default, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = approved_named_launch!(ctx, turn, approver, args, nil)

    # A new revision of the app's grant: one more account bound.
    work = disclosed_entry!(ctx, "work")

    grant!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: work.id}
    ])

    stale_launch!(ctx, step, app, :approved_grant_moved)
  end

  test "a card drawn when its app had no grant lets nothing flow, whatever grant its root loads",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    app = publish_app!(ctx)
    args = %{"reference" => app <> ":1.0.0", "input" => %{}}
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    pinned = Prima.Source.new(:pinned)
    {:ok, _} = Tape.record_model_intent(ctx, turn, %{sources: [pinned]})

    # No grant to judge the turn's sources against: the card binds none,
    # and lets nothing flow.
    assert %{"lets_flow" => []} = proposal = bound_proposal(ctx, turn, args)
    refute Map.has_key?(proposal, "consent_id")

    root_id = Prima.UUID7.execution_id()
    step = approved_named_launch!(ctx, turn, approver, args, nil, root_id)
    default = disclosed_entry!(ctx, "default")
    grant!(ctx, app, [%{need: "api_key", entry_id: default.id}])
    dispatched = Launch.dispatch(ctx, step)

    # The grant made since decides the run's sends alone: seeded with the
    # turn's sources, the root lets no class flow.
    assert launched_of(ctx, app) == [root_id], "launch answered #{inspect(dispatched)}"
    actor = Sanctum.Context.actor(ctx)

    assert {:ok, %{launch_classes: [], sources: seeded}} =
             Arca.Execution.flow_state(actor, root_id)

    assert pinned in seeded
  end

  test "an approved launch roots under the step's id, seeded with the turn's sources, with the " <>
         "classes its card lets flow in the root's policy",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    pinned = Prima.Source.new(:pinned)
    news = Prima.Source.outside("news.example")
    {:ok, _} = Tape.record_model_intent(ctx, turn, %{sources: [pinned, news]})

    # Neither class has a flow to the app's one exit, and the outside
    # material came from another host: the card lets both flow.
    proposal = bound_proposal(ctx, turn, args)
    assert %{"lets_flow" => ["pinned", "outside"], "consent_id" => consent_id} = proposal
    {:ok, %{consent_id: ^consent_id}} = Opus.authority_for(ctx, :default, app)

    root_id = Prima.UUID7.execution_id()
    step = approved_named_launch!(ctx, turn, approver, args, nil, root_id)
    dispatched = Launch.dispatch(ctx, step)

    assert launched_of(ctx, app) == [root_id], "launch answered #{inspect(dispatched)}"
    actor = Sanctum.Context.actor(ctx)

    assert {:ok, %{launch_classes: [:pinned, :outside]}} =
             Arca.Execution.flow_state(actor, root_id)

    assert {:ok, [%{type: "execution.started"} = started | _]} =
             Arca.ExecutionEvents.since(actor, root_id, 0)

    assert Arca.ExecutionEvents.data(started)["sources"] ==
             Prima.Source.to_json_list([pinned, news])

    # Its caller is the agent whose turn launched it, which the stamp
    # alone carries, not the person who approved the card.
    assert %{caller: caller} = Arca.Execution.get_tenant(actor, root_id)
    assert caller == "agent:" <> turn.agent
  end

  # ---------------------------------------------------------------------------
  # A launch with no card: on the app's grant, as the turn's person
  # ---------------------------------------------------------------------------

  @auto %{"execution.run" => "auto"}
  @ask %{"execution.run" => "ask"}
  @news Prima.Source.outside("news.example")

  # An app of the person's own with no exit at all, no egress and no tool
  # server, granted with nothing to bind: its grant covers every source.
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

  # `granted_app!/1`'s app whose manifest declares that outside material
  # may reach its one exit, granted.
  defp flowing_app!(ctx) do
    name = "flowing-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "caps" => %{
        "egress" => %{"domains" => ["api.example.com"]},
        "flows" => [%{"from" => "outside", "to" => "api.example.com"}]
      }
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    app = "reagent:local." <> name
    grant!(ctx, app, [])
    %{app: app, args: %{"reference" => app <> ":1.0.0", "input" => %{}}}
  end

  # A launch step for `args` as the loop records it, with no card: the one
  # call of a response, its row the one the loop recalls the call from.
  defp launch_step!(ctx, turn, args, root_id \\ nil) do
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "execution.run",
            tool: "execution",
            action: "run",
            arguments: args,
            kind: "execute",
            step_kind: "launch",
            child_execution_id: root_id
          }
        ]
      })

    step
  end

  # The loop's decision for a launch of `args` in `turn` under `policy`,
  # where the turn's sources are read from its row.
  defp decide(ctx, turn, args, policy \\ @auto) do
    {:ok, call} = Aqua.Loop.Binding.resolve("execution.run", args)

    Aqua.Loop.Policy.decide(call, policy,
      ctx: ctx,
      agent: "aqua",
      thread_id: turn.thread_id,
      turn_id: turn.id,
      execution_id: turn.root_execution_id
    )
  end

  defp read!(ctx, turn, sources),
    do: {:ok, _} = Tape.record_model_intent(ctx, turn, %{sources: sources})

  defp consent_of(ctx, app) do
    {:ok, %{consent_id: consent_id}} = Opus.authority_for(ctx, :default, app)
    consent_id
  end

  @decided_sources "This turn read more since the run was decided, so nothing ran: propose it " <>
                     "again to decide it on what the turn has read now."
  @decided_grant "The component's grant changed since the run was decided, so nothing ran: " <>
                   "propose it again to decide it on the grant as it stands now."
  @decided_work "The account \"Work\" is not the one this run was decided on, so nothing " <>
                  "ran: propose it again to run it on the account as it stands now"

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

  defp gate_runs(ctx) do
    Arca.Repo.aggregate(
      from(d in Arca.Schemas.DecisionLog,
        where: d.athanor_id == ^ctx.athanor_id and d.tool == "execution" and d.action == "run"
      ),
      :count
    )
  end

  test "under auto a launch is decided on its app's grant: with no card where the grant covers " <>
         "every source the turn has read, and with its card where one is not covered",
       %{ctx: ctx, thread: thread, pins: pins} do
    granted = granted_app!(ctx)
    flowing = flowing_app!(ctx)
    quiet = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)

    # Nothing read yet: the one exit of each grant has nothing to carry,
    # and each is decided on its grant's revision, letting nothing flow.
    for %{app: app, args: args} <- [granted, flowing, quiet] do
      assert decide(ctx, turn, args) ==
               {:auto,
                %{
                  call: %{action: "run", args: args},
                  account: nil,
                  binding: %{sources: [], consent_id: consent_of(ctx, app), classes: []}
                }}
    end

    # Outside material read: the grant that declares no flow of it to its
    # exit asks; the one that declares it, and the one with no exit, run.
    read!(ctx, turn, [@news])
    assert decide(ctx, turn, granted.args) == :ask

    for %{app: app, args: args} <- [flowing, quiet] do
      assert {:auto, %{binding: %{sources: [@news], consent_id: consent_id, classes: []}}} =
               decide(ctx, turn, args)

      assert consent_id == consent_of(ctx, app)
    end

    # The pinned page read beside it is covered by none of the exits'
    # flows: only the app with no exit still runs.
    read!(ctx, turn, [Prima.Source.new(:pinned)])
    assert decide(ctx, turn, flowing.args) == :ask
    assert {:auto, %{binding: %{sources: [_, _]}}} = decide(ctx, turn, quiet.args)

    # Under ask every launch asks, the person's own choice; a policy that
    # denies execution.run, or names it not at all, denies it.
    for %{args: args} <- [granted, flowing, quiet] do
      assert decide(ctx, turn, args, @ask) == :ask
      assert {:deny, _} = decide(ctx, turn, args, %{"execution.run" => "deny"})

      assert decide(ctx, turn, args, %{}) ==
               {:deny, "execution.run is not in the agent's policy"}
    end
  end

  # An app whose manifest declares that the pinned page may reach its one
  # exit, and nothing else, granted.
  defp pinned_flow_app!(ctx) do
    name = "pinned-flow-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "caps" => %{
        "egress" => %{"domains" => ["api.example.com"]},
        "flows" => [%{"from" => "pinned", "to" => "api.example.com"}]
      }
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    app = "reagent:local." <> name
    grant!(ctx, app, [])
    %{app: app, args: %{"reference" => app <> ":1.0.0", "input" => %{}}}
  end

  # A turn that read the prompt as it is composed now, as the loop's
  # first model step records what the prompt read: one of a thread of its
  # own, since one turn holds a thread at a time.
  defp prompted!(ctx, _thread, pins) do
    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    composed = Aqua.Prompt.compose(ctx, agent: %{"prompt" => "", "tool_policy" => %{}})
    read!(ctx, turn, composed.sources)
    turn
  end

  test "an about-you page Aqua wrote after reading outside material makes every later turn's " <>
         "launch of an app whose grant lets only the page out ask; the person's own write or " <>
         "Remove on the Aqua page ends it",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{args: args} = pinned_flow_app!(ctx)

    # The person's own page: the grant lets it out, and the launch runs.
    {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Flies to Lisbon on the 3rd.")
    assert {:auto, _} = decide(ctx, prompted!(ctx, thread, pins), args)

    # Aqua rewrites it after reading the news, with no card: every turn that
    # reads the page from then on carries the news, which the grant does
    # not let out, so each launch asks.
    {:ok, _} =
      Aqua.Notes.pin(ctx, "about-you", "Flies to Lisbon on the 3rd; fares rise Monday.",
        kept_by: Prima.Author.agent(),
        thread: thread.id,
        sources: [@news]
      )

    for _turn <- 1..2, do: assert(:ask = decide(ctx, prompted!(ctx, thread, pins), args))

    # The person saves the page as their own on the Aqua page: the next
    # turn runs the app with no card again.
    {:ok, %{revision: revision}} = Aqua.Notes.read(ctx, "about-you")

    {:ok, _} =
      Aqua.Notes.pin(ctx, "about-you", "Flies to Lisbon on the 3rd; fares rise Monday.", [],
        revision: revision
      )

    assert {:auto, _} = decide(ctx, prompted!(ctx, thread, pins), args)

    # Or removes Aqua's page, over the revision the Aqua page read.
    {:ok, _} =
      Aqua.Notes.pin(ctx, "about-you", "Fares rise Monday.",
        kept_by: Prima.Author.agent(),
        thread: thread.id,
        sources: [@news]
      )

    assert :ask = decide(ctx, prompted!(ctx, thread, pins), args)
    {:ok, %{revision: revision}} = Aqua.Notes.read(ctx, "about-you")
    {:ok, %{cleared: "about-you"}} = Aqua.Notes.pin(ctx, "about-you", "", [], revision: revision)
    assert {:auto, _} = decide(ctx, prompted!(ctx, thread, pins), args)
  end

  test "a thread the turn's posts came from is no material a grant must cover",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    read!(ctx, turn, [Prima.Source.thread("thr_other")])

    assert {:auto, %{binding: %{sources: [%Prima.Source{class: :thread}]}}} =
             decide(ctx, turn, args)

    # What the thread's posts carried is: outside material they held asks.
    read!(ctx, turn, [@news])
    assert decide(ctx, turn, args) == :ask
  end

  test "under auto a launch naming an account decides on the entry it resolves to, and a name " <>
         "its app does not bind is setup required",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, work: work, args: args} = work_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)

    assert {:auto, %{account: %{vault_entry: entry, name: "Work"}, binding: %{classes: []}}} =
             decide(ctx, turn, %{args | "connection" => "work"})

    assert entry == work.id
    versioned = app <> ":1.0.0"

    assert decide(ctx, turn, %{args | "connection" => "Home"}) ==
             {:setup_required, versioned, {nil, "Home"}}
  end

  test "a decided launch runs once as the turn's person, under its stored origin, with its " <>
         "recorded call's arguments, seeded with the turn's sources and letting nothing flow",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :programmatic}, thread, pins)
    read!(ctx, turn, [@news])
    root_id = Prima.UUID7.execution_id()

    # The recorded call names a lineage of its own: it is dropped.
    forged = Map.merge(args, %{"parent_execution_id" => "exec_forged", "thread_id" => "thr_x"})
    step = launch_step!(ctx, turn, forged, root_id)
    assert {:auto, decided} = decide(ctx, turn, forged)
    dispatched = Launch.run(ctx, step, decided)

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

    assert {:ok, %{launch_classes: [], sources: seeded}} =
             Arca.Execution.flow_state(actor, root_id)

    assert @news in seeded
  end

  test "a decided launch whose turn read a source, or whose app's grant moved, since its " <>
         "decision runs nothing",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, default: default, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = launch_step!(ctx, turn, args)
    assert {:auto, decided} = decide(ctx, turn, args)

    # A source the turn read since, even one the app may be handed:
    # nothing ran, and proposed again it is decided on it.
    read!(ctx, turn, [Prima.Source.thread("thr_other")])
    ran_nothing!(ctx, step, decided, app, @decided_sources)

    # A new revision of the app's grant, one that covers as much.
    other = launch_step!(ctx, turn, args)
    assert {:auto, decided} = decide(ctx, turn, args)
    work = disclosed_entry!(ctx, "work")

    grant!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: work.id}
    ])

    ran_nothing!(ctx, other, decided, app, @decided_grant)
  end

  test "a decided launch whose app's grant moves after the dispatcher's check is refused at " <>
         "the run's root, with nothing started",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, default: default, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    step = launch_step!(ctx, turn, args)
    assert {:auto, decided} = decide(ctx, turn, args)
    work = disclosed_entry!(ctx, "work")

    regrant_at_admission!(ctx, app, [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: work.id}
    ])

    attempts = attempts_of(ctx)

    _log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Launch.run(ctx, step, decided) == {:refused, {:conflict, @decided_grant}}
      end)

    assert_received :regranted
    assert launched_of(ctx, app) == []
    assert attempts_of(ctx) == attempts
  end

  test "a decided launch naming an account that now resolves to another entry runs nothing, " <>
         "before the dispatcher's check or after it",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, default: default, other: other, args: args} = work_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)

    moved = [
      %{need: "api_key", entry_id: default.id},
      %{need: "api_key", name: "Work", entry_id: other.id}
    ]

    early = launch_step!(ctx, turn, args)
    assert {:auto, decided} = decide(ctx, turn, args)
    grant!(ctx, app, moved)
    ran_nothing!(ctx, early, decided, app, @decided_work)

    # Decided again on the grant as it stands, and moved back at the
    # gate's admission of the run: its root refuses it.
    late = launch_step!(ctx, turn, args)
    assert {:auto, decided} = decide(ctx, turn, args)
    regrant_at_admission!(ctx, app, [%{need: "api_key", entry_id: default.id}])

    _log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Launch.run(ctx, late, decided) == {:refused, {:conflict, @decided_work}}
      end)

    assert_received :regranted
    assert launched_of(ctx, app) == []
  end

  # Review round one, finding 1 (#3464): a stored answer never stands for
  # a launch, so none brings in one the author left out.
  test "with no execution.run line the launch is denied: the store refuses a standing allow for " <>
         "it, and one stored past the store changes nothing",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    denied = {:deny, "execution.run is not in the agent's policy"}
    assert decide(ctx, turn, args, %{}) == denied

    allow = %{
      scope: "thread",
      effect: "allow",
      thread_id: thread.id,
      agent_name: "aqua",
      tool: "execution",
      action: "run"
    }

    for scope <- [allow, %{allow | scope: "agent", thread_id: nil}] do
      assert Sanctum.ToolGrants.put(ctx, scope) ==
               {:error, {:scope_not_permitted, :never_standing}}
    end

    {:ok, _} =
      Arca.ToolGrantStorage.put(
        Map.merge(allow, %{athanor_id: ctx.athanor_id, granted_by: ctx.user_id})
      )

    {:ok, rows} = Sanctum.ToolGrants.for_thread(ctx, thread.id)
    assert [%{tool: "execution", action: "run"}] = rows

    for setting <- [{:ok, true}, {:ok, false}] do
      policy = Aqua.ToolGrants.resolve(%{}, rows, setting)
      refute Map.has_key?(policy, "execution.run")
      assert decide(ctx, turn, args, policy) == denied
    end

    # Beside a line, the row counts for nothing either: the author's line
    # decides.
    assert Aqua.ToolGrants.resolve(%{"execution.run" => "ask"}, rows, {:ok, true}) ==
             %{"execution.run" => "ask"}

    refute Sanctum.ToolGrants.admits?(ctx, %{
             agent_name: "aqua",
             thread_id: thread.id,
             tool: "execution",
             action: "run",
             args: args,
             sources: []
           })
  end

  # Review round one, finding 2 (#3464): no grant is no cover.
  test "under auto a launch of an app with no grant asks on its card, as a launch always did, " <>
         "and a decision that carries no revision runs nothing, whatever grant then appears",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    app = publish_app!(ctx)
    args = %{"reference" => app <> ":1.0.0", "input" => %{}}
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    read!(ctx, turn, [@news])
    assert decide(ctx, turn, args) == :ask

    # A decision with no revision, handed to the dispatcher anyway, runs
    # nothing and asks the gate nothing, though a first grant whose one
    # exit does not cover the turn's source would appear at the gate's
    # admission.
    step = launch_step!(ctx, turn, args)

    unpinned = %{
      call: %{action: "run", args: args},
      account: nil,
      binding: %{sources: [@news], consent_id: nil, classes: []}
    }

    regrant_at_admission!(ctx, app, [%{need: "api_key", entry_id: disclosed_entry!(ctx, "d").id}])
    decisions = gate_runs(ctx)
    assert Launch.run(ctx, step, unpinned) == {:refused, :not_approved}
    refute_received :regranted
    assert gate_runs(ctx) == decisions
    assert launched_of(ctx, app) == []
  end

  test "a launch of an app with no grant, approved on its card, is answered by the gate that " <>
         "the app is not granted, and nothing of it runs",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    app = publish_app!(ctx)
    args = %{"reference" => app <> ":1.0.0", "input" => %{}}
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    assert decide(ctx, turn, args) == :ask

    step = approved_named_launch!(ctx, turn, approver, args, nil)
    assert {:error, refused} = Launch.dispatch(ctx, step)
    assert %Prima.Refusal{class: :consent_required} = Sanctum.Refusals.classify(refused)
    assert launched_of(ctx, app) == []
  end

  # What the loop hands the dispatcher for a launch of `args` with no card:
  # its decision, made on that call.
  defp handed(decided, args), do: %{decided | call: %{action: "run", args: args}}

  test "a decided launch refuses an agent or a hand its step's row names, and a step whose row " <>
         "records no launch",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    assert {:auto, decided} = decide(ctx, turn, args)

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

    # With no decision a step with no approval runs nothing, as before.
    assert Launch.run(ctx, step) == {:refused, :not_approved}
  end

  test "a decided launch runs what its step's row records: a decision made on another call runs " <>
         "nothing and asks the gate nothing",
       %{ctx: ctx, thread: thread, pins: pins} do
    Cyfr.Test.Sandbox.stop_work_on_exit()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    %{app: app, args: args} = quiet_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    assert {:auto, decided} = decide(ctx, turn, args)
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

  # The account is read again, as the approver, before anything runs: a
  # head stored damaged since the card was drawn is that damage, in its
  # own class and sentence, never a stale approval to ask again and never
  # an outcome that could not be confirmed. Nothing reaches the gate.
  test "a launch naming an account over the app's own head stored damaged is refused as the " <>
         "damaged head, with nothing started",
       %{ctx: ctx, thread: thread, pins: pins, approver: approver} do
    %{app: app, step: step} = approved_work_launch!(ctx, thread, pins, approver)
    profile_id = own_profile_id(ctx, app)
    :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id, blob_digest: @zero_digest)
    attempts = attempts_of(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Launch.dispatch(ctx, step) == {:error, {:head_corrupt, profile_id}}
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

  # A card is drawn only over a head that reads: one stored damaged, or an
  # active profile that lost its head, refuses the call in the damaged
  # head's sentence, never a setup to make over a profile that exists.
  test "a launch naming an account over the app's own head stored damaged, or lost, opens no " <>
         "card and refuses as the damaged head",
       %{ctx: ctx} do
    policy = %{"execution.run" => "ask"}

    for damage <- [
          &Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, &1, blob_digest: @zero_digest),
          &set_profile!(ctx, &1, head_consent_id: nil)
        ] do
      %{app: app, args: args} = work_app!(ctx)
      profile_id = own_profile_id(ctx, app)
      {:ok, call} = Aqua.Loop.Binding.resolve("execution.run", args)

      assert {:ask, %{name: "Work"}} = Aqua.Loop.Policy.decide(call, policy, ctx: ctx)

      damage.(profile_id)

      assert Aqua.Loop.Policy.decide(call, policy, ctx: ctx) ==
               {:refuse,
                "the account \"Work\" of #{call.target} could not be read: " <>
                  damaged_head_sentence(profile_id)}
    end
  end

  test "under auto a launch whose app's grant cannot be read is refused, never read as a grant",
       %{ctx: ctx, thread: thread, pins: pins} do
    %{app: app, args: args} = granted_app!(ctx)
    turn = started!(%{ctx | origin: :interactive}, thread, pins)
    profile_id = own_profile_id(ctx, app)
    :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile_id, blob_digest: @zero_digest)

    assert decide(ctx, turn, args) ==
             {:refuse,
              "the grant of #{app}:1.0.0 could not be read: " <>
                damaged_head_sentence(profile_id)}
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
