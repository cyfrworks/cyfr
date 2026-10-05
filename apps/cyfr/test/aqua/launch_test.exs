# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LaunchTest do
  @moduledoc """
  An approved launch runs as the person who approved it, under the origin
  the approved turn's row stores — never `interactive` inferred from the
  person approving. A programmatic turn's launch stays programmatic, and a
  turn whose row stores no origin launches nothing.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.{Approvals, Launch, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Tenancy.{Members, Users}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  # A shipped application that roots its own consent: whatever it
  # answers, its root's row is written as the launch admitted it.
  @application "formula:local.list-models"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "launch_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)
    Application.put_env(:arca, :seed_path, @seed_root)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, %{profile_id: profile_id, consent_id: consent_id}} =
      Crucible.authority_for(ctx, :default, @soul)

    {:ok, %{capability_digest: capability}} = Compendium.AgentIndex.snapshot(ctx, "aqua")

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    pins = %{profile_id: profile_id, consent_id: consent_id, agent_capability_digest: capability}
    {:ok, ctx: ctx, thread: thread, pins: pins, approver: approver!(ctx)}
  end

  # A seated member other than the sender, whose approval the launch runs as.
  defp approver!(ctx) do
    n = System.unique_integer([:positive])

    {:ok, approver} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|launcher#{n}",
        provider: "github",
        email: "launcher#{n}@example.com",
        verified: true,
        name: "Launcher"
      })

    {:ok, _} = Members.ensure(approver.id, scope: "athanor", athanor_id: ctx.athanor_id)
    %{ctx | user_id: approver.id, origin: :interactive}
  end

  # A turn accepted from `sender`, whose context carries the origin its
  # admission path set, and started under its pinned root.
  defp started!(sender, thread, pins) do
    {:ok, %{turn: turn}} =
      Tape.accept(sender, thread.id, %{
        message: %{author: sender.user_id, content: "@aqua launch it"},
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

  # A launch card for the application, as the loop opens it, approved by
  # `approver`: the step the loop hands the dispatcher.
  defp approved_launch!(ctx, turn, approver) do
    {resolved, step_id} = launch_card(ctx, turn, approver)
    assert {:ok, %{decision: "approved", resolution_kind: "launch"}} = resolved
    {:ok, step} = Tape.step(ctx, step_id)
    step
  end

  # What `approver`'s approval of a launch card answers.
  defp approve_launch(ctx, turn, approver) do
    {resolved, _step_id} = launch_card(ctx, turn, approver)
    resolved
  end

  defp launch_card(ctx, turn, approver) do
    proposal = %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{"reference" => @application, "input" => %{}}
    }

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

  test "a turn whose row stores no origin launches nothing, with that reason", %{
    ctx: ctx,
    thread: thread,
    pins: pins,
    approver: approver
  } do
    # No entry builds a context without an origin, so no turn row is
    # written without one: this one is cleared past every writer's guard,
    # as a hand edit or a restored row reaches it.
    assert {:error, :no_origin} =
             Tape.accept(%{ctx | origin: nil}, thread.id, %{
               message: %{author: ctx.user_id, content: "@aqua launch it"},
               turn: %{agent: "aqua", requested_by: ctx.user_id}
             })

    turn = started!(ctx, thread, pins)
    step = approved_launch!(ctx, turn, approver)

    # The row loses its origin after the card was approved under it.
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [origin: nil]
      )

    assert {:ok, %{origin: nil}} = Tape.turn(ctx, turn.id)

    # Never guessed from the person who approved it.
    assert {:error, {:approver_unavailable, :no_origin}} = Launch.dispatch(ctx, step)
    assert launched(ctx) == []
  end

  test "a card on a turn whose row stores no origin is refused: no grant to judge it under", %{
    ctx: ctx,
    thread: thread,
    pins: pins,
    approver: approver
  } do
    turn = started!(ctx, thread, pins)

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [origin: nil]
      )

    {:ok, turn} = Tape.turn(ctx, turn.id)

    # The pin check reads the turn's grant under the origin its row
    # stores, never the approver's: with none it cannot hold.
    assert {:error, :turn_superseded} = approve_launch(ctx, turn, approver)
    assert launched(ctx) == []
  end

  # ---------------------------------------------------------------------------
  # A launch naming an account
  # ---------------------------------------------------------------------------

  @probe Path.expand(
           "../../../opus/test/support/test_wasm/hostile/attached_header_probe.wasm",
           __DIR__
         )
  @math_wasm Path.expand("../support/test_wasm/math.wasm", __DIR__)
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

  # The probe of K.K2's attached-request suite, published as an app of the
  # person's own whose need `api_key` is attached by the rule: it sends its
  # input as its one request and answers what it got.
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
          "attach" => @rule
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
          "fields" => ["KEY"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm), %{
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
  defp approved_named_launch!(ctx, turn, approver, args, vault_entry) do
    proposal =
      %{"tool" => "execution", "action" => "run", "args" => args}
      |> Prima.MapUtil.put_present("vault_entry", vault_entry)

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
            step_kind: "launch"
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
    on_exit(fn -> Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id) end)

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

  test "an origin the sender's request names is not the turn's", %{
    ctx: ctx,
    thread: thread
  } do
    sender = %{ctx | origin: :programmatic}

    {:ok, %{turn: turn}} =
      Tape.accept(sender, thread.id, %{
        message: %{author: sender.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: sender.user_id, origin: :interactive}
      })

    assert turn.origin == "programmatic"
  end
end
