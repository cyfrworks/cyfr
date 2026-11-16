# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.PageCallsTest do
  @moduledoc """
  A page Aqua put into a workspace thread's window calls CYFR, and each
  call is Aqua's own call in that thread (`Aqua.PageCalls`): the person's
  browser (`Opus.Browser`, its driver a script that speaks the driver's
  framing, `Cyfr.Test.ScriptedDriver`) announces it, the thread's runner
  makes it a step, the loop decides and dispatches it as a model's call,
  and the page is answered that step's result through the browser.

  A tincture's page calls only what its manifest declares, and a call it
  does not declare leaves no step; a plain page's call is decided by
  policy alone. A granted component whose grant covers the page, which a
  call carries as outside material, runs with no card; one whose grant
  does not asks on a card of its own each time while the page waits, and
  the yes runs that one call once. A turn a schedule started asks nobody.
  A request that is gone runs nothing, a call its runner dies holding is
  answered unavailable, and a call over the rate is refused.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait, only: [wait_until: 3]

  alias Aqua.{Approvals, Runner, Tape}
  alias Aqua.Providers.Browser, as: Provider
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedDriver, as: Driver
  alias Cyfr.Test.ScriptedWorker
  alias Opus.Programs

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @root :crypto.strong_rand_bytes(32)

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    # The test's storage is the tree of the person's own athanor, minted
    # for this test alone: nothing else names it, and it is removed, and
    # nothing else, when the test ends.
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id, origin: :interactive}
    tree = own_tree!(ctx)
    keys = [cyfr: :locus_runtime_workers]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    on_exit(fn ->
      File.rm_rf!(tree)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    # The runners stop before their tree is removed and the seed restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The person's browser, its programs answered by a script and its
    # driver a script of the test's.
    fake = Scripted.start(self(), @root)
    _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000
    driver = Driver.start(self())
    Scripted.set(fake, :terminal, driver)

    # Filled, as a person's athanor stands once its fill has run; the
    # soul's consent is among what it minted.
    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    browser_row!(ctx)

    {:ok, ctx: ctx, driver: driver}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp own_tree!(ctx) do
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"
    tree
  end

  defp browser_row!(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: Programs.Definition.browser_name(),
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json: Jason.encode!(%{"command" => "cyfr-browser", "env" => %{}})
      })

    row
  end

  # The scripted worker answers the model and every app of `apps`, from
  # one script consumed in order across their runs.
  defp worker!(apps), do: start_supervised!({ScriptedWorker, ref: [@model | apps], script: []})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp workspace!(ctx) do
    thread =
      %Arca.Schemas.Thread{}
      |> Arca.Schemas.Thread.changeset(%{
        id: Prima.UUID7.generate_id("thread"),
        athanor_id: ctx.athanor_id,
        kind: "workspace",
        workspace_state: "open",
        title: "Show the page",
        created_by: ctx.user_id
      })
      |> Arca.Repo.insert!()

    :ok = Runner.subscribe(thread.id, ctx.athanor_id)
    thread
  end

  # A page Aqua puts into `thread`'s window from a turn `ctx` sends, as its
  # `browser.page` call does: the turn's model is held while the page is
  # put under the turn's lineage, then answers, and the turn ends. The
  # page's calls run as that turn's person, under its origin. Answers it.
  defp put!(ctx, thread, page) do
    ScriptedWorker.script([{:probe, self()}, reply("It is in the window.")])
    {:ok, %{turn_id: turn_id}} = Runner.send_message(ctx, thread.id, "@aqua show it")
    assert_receive {:scripted_probe, model, _child}, 60_000
    {:ok, turn} = Tape.turn(ctx, turn_id)

    lineage = %{
      "thread_id" => thread.id,
      "root_execution_id" => turn.root_execution_id,
      "parent_execution_id" => turn.root_execution_id
    }

    args = page |> Map.merge(lineage) |> Map.put("action", "page")
    assert {:ok, _shown} = Provider.handle("browser", Sanctum.Context.enter_guest(ctx), args)
    # The page's calls name the put they belong to, as the driver names it.
    assert_receive {:driver, :put, _session, %{"id" => put, "win" => win}, _bytes}, 5_000
    assert win == thread.id
    Process.put({:put, thread.id}, put)
    send(model, :continue)
    assert %{status: "completed"} = ended!(ctx, turn_id)
  end

  @html %{"html" => "<p>a page Aqua wrote</p>"}

  # An app of the person's own, granted with nothing to bind: with no
  # exit at all, or with the exit and the flows `caps` declare.
  defp app!(ctx, caps \\ nil, grant? \\ true) do
    name = "page-app-#{System.unique_integer([:positive])}"

    manifest =
      Prima.MapUtil.put_present(
        %{"name" => name, "version" => "1.0.0", "type" => "reagent"},
        "caps",
        caps
      )

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    ref = "reagent:local." <> name
    if grant?, do: walk!(ctx, %{ref: ref, bindings: []})
    ref
  end

  # One exit; a grant of it covers outside material only where the
  # manifest declares that flow.
  @exit %{"egress" => %{"domains" => ["api.example.com"]}}
  # A turn that asked a model holds what its model's key disclosed, and
  # work with no model starts with the putting turn's sources: a grant
  # lets the page out only where it lets both flow.
  @flowing Map.put(@exit, "flows", [
             %{"from" => "outside", "to" => "api.example.com"},
             %{"from" => "vault_disclosed", "to" => "api.example.com"}
           ])

  # A grant through the consent walk, as a person makes it.
  defp walk!(ctx, decisions) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, Map.take(decisions, [:ref, :label]))
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

  # Aqua's policy with `patch` over it, as the Aqua page writes it, and the
  # soul's grant walked again for the shape that moved.
  defp policy!(ctx, patch) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tool_policy_patch" => patch
      })

    walk!(ctx, %{ref: @soul, selections: [%{dep: @model, label: "default"}]})
  end

  # A tincture version in the athanor, declaring `deps` as its static
  # dependencies and `actions` as its system actions, with an entry the
  # browser puts.
  defp tincture!(ctx, deps, actions) do
    name = "page-tincture-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => name,
      "tincture" => %{"entry" => "index.html", "actions" => actions},
      "dependencies" => %{"static" => Enum.map(deps, &%{"ref" => &1, "reason" => "calls it"})}
    }

    unit =
      Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
        manifest: manifest,
        files: [{"index.html", "<html><head></head><body>t</body></html>"}]
      )

    {:ok, _registered} = Compendium.Registry.register_from_arca(ctx, unit)
    "tincture:local.#{name}:1.0.0"
  end

  # The page in `thread`'s window calls `invoke` of `ref`, or the action
  # `operation`, as its SDK posts the call; `id` is the driver's.
  defp invoke(driver, thread, id, ref, args \\ %{}) do
    body = Prima.TinctureWire.request(:invoke, %{ref: ref, operation: "go", args: args})
    :ok = Driver.call(driver, id, thread.id, put_of(thread), "invoke", Jason.encode!(body))
  end

  defp action(driver, thread, id, operation, args \\ %{}) do
    body = Prima.TinctureWire.request(:action, %{operation: operation, args: args})
    :ok = Driver.call(driver, id, thread.id, put_of(thread), "action", Jason.encode!(body))
  end

  defp put_of(thread), do: Process.get({:put, thread.id})

  # What the page was answered for its call `id`: the status and the
  # wire's answer, decoded.
  defp answered!(id) do
    assert_receive {:driver, :answer, _session, ^id, status, body}, 60_000
    {status, Jason.decode!(body)}
  end

  defp result(value), do: %{"v" => 1, "ok" => true, "result" => value}

  # The turn a card paused, and its one card waiting.
  defp paused!(ctx) do
    assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: turn_id}}, 60_000
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, turn)
    {turn, approval}
  end

  defp intent!(ctx, approval) do
    {:ok, card} = Tape.message(ctx, approval.message_id)
    Tape.payload(card)["intent"]
  end

  @terminal ~w(completed failed cancelled uncertain)

  defp ended!(ctx, turn_id) do
    wait_until(
      fn ->
        match?({:ok, %{status: status}} when status in @terminal, Tape.turn(ctx, turn_id))
      end,
      60_000,
      "turn #{turn_id} to end"
    )

    {:ok, turn} = Tape.turn(ctx, turn_id)
    turn
  end

  # The calls the thread's runner holds waiting to become steps.
  defp waiting!(thread, n) do
    wait_until(
      fn -> length(:sys.get_state(Runner.whereis(thread.id)).pages) == n end,
      10_000,
      "#{n} calls to wait in the runner"
    )
  end

  # The turns of `thread` after the put's, oldest first, each with its steps.
  defp turns_after(ctx, thread, put) do
    from(t in Arca.Schemas.Turn,
      where: t.athanor_id == ^ctx.athanor_id and t.thread_id == ^thread.id and t.id != ^put.id,
      order_by: [asc: t.accepted_at, asc: t.id],
      select: t.id
    )
    |> Arca.Repo.all()
    |> Enum.map(fn id ->
      {:ok, turn} = Tape.turn(ctx, id)
      {:ok, steps} = Tape.steps(ctx, turn)
      {turn, steps}
    end)
  end

  # The rows of a page's calls in `thread`, oldest first.
  defp page_rows(ctx, thread),
    do:
      ctx
      |> Sanctum.Context.actor()
      |> Threads.messages(thread.id)
      |> Enum.filter(&(&1.kind in ["page_call", "page_result"]))

  defp runs_of(ctx, ref) do
    Arca.Repo.all(
      from(e in Arca.Schemas.Execution,
        where: e.athanor_id == ^ctx.athanor_id and like(e.reference, ^"#{ref}%"),
        select: %{id: e.id, user_id: e.user_id, origin: e.origin, parent: e.parent_execution_id}
      )
    )
  end

  # The runs the worker was handed of an app the page invoked.
  defp app_runs, do: Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "go"))
  defp chats, do: Enum.count(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))

  # ---------------------------------------------------------------------------
  # With no card
  # ---------------------------------------------------------------------------

  test "a granted component with no exit, or whose grant lets the page out, runs once with " <>
         "no card in two workspace threads, as a model's launch runs",
       %{ctx: ctx, driver: driver} do
    quiet = app!(ctx)
    flowing = app!(ctx, @flowing)
    worker!([quiet, flowing])

    for {{app, room}, id} <-
          Enum.with_index([{quiet, workspace!(ctx)}, {flowing, workspace!(ctx)}], 1) do
      put = put!(ctx, room, @html)
      ScriptedWorker.script([{:output, %{"answered" => id}}])
      asked = chats()

      invoke(driver, room, id, app <> ":1.0.0", %{"n" => id})
      assert answered!(id) == {200, result(%{"answered" => id})}

      # A turn of its own, asking no model, as the put's person under its
      # origin: one launch, closed with no card and the run's result.
      assert [{%{id: turn_id}, _steps}] = turns_after(ctx, room, put)
      turn = ended!(ctx, turn_id)

      assert {turn.status, turn.requested_by, turn.origin, turn.agent} ==
               {"completed", ctx.user_id, "interactive", "aqua"}

      assert {:ok, []} = Tape.pending_approvals(ctx, turn)
      {:ok, [step]} = Tape.steps(ctx, turn)

      assert %{
               purpose: "page",
               kind: "launch",
               dispatch_state: "closed",
               outcome: "ok",
               approval_id: nil,
               child_execution_id: root_id,
               result_message_id: result_id
             } = step

      assert [
               %{kind: "page_call", id: call_id, content: "execution.run", payload: call},
               %{kind: "page_result", id: ^result_id, content: answer, payload: closed}
             ] = page_rows(ctx, room)

      assert step.message_id == call_id and turn.message_id == call_id
      assert Jason.decode!(answer) == result(%{"answered" => id})
      assert %{"status" => 200, "is_error" => false} = Jason.decode!(closed)

      assert %{
               "name" => "execution.run",
               "arguments" => %{
                 "reference" => reference,
                 "input" => %{"operation" => "go", "params" => %{"n" => ^id}}
               },
               "tool" => "execution",
               "action" => "run",
               "user_id" => user_id
             } = Jason.decode!(call)

      assert reference == app <> ":1.0.0" and user_id == ctx.user_id

      # Dispatched once, as the turn's person under its origin; no model
      # was asked.
      assert runs_of(ctx, app) == [
               %{id: root_id, user_id: ctx.user_id, origin: "interactive", parent: nil}
             ]

      assert chats() == asked
    end
  end

  # ---------------------------------------------------------------------------
  # What a page is held to
  # ---------------------------------------------------------------------------

  test "a tincture's page is refused a component or an action it does not declare, and " <>
         "the refusal leaves no step",
       %{ctx: ctx, driver: driver} do
    declared = app!(ctx)
    undeclared = app!(ctx)
    worker!([declared, undeclared])
    room = workspace!(ctx)
    put = put!(ctx, room, %{"tincture" => tincture!(ctx, [declared], ["component.list"])})

    invoke(driver, room, 1, undeclared <> ":1.0.0")
    action(driver, room, 2, "crew.list")

    for {id, what} <- [{1, "component"}, {2, "action"}] do
      assert answered!(id) ==
               {403,
                %{
                  "v" => 1,
                  "ok" => false,
                  "error" => %{
                    "class" => "forbidden",
                    "message" => "This tincture does not declare that #{what}.",
                    "stage" => "execution"
                  }
                }}
    end

    assert turns_after(ctx, room, put) == []
    assert page_rows(ctx, room) == []
    assert runs_of(ctx, undeclared) == []

    # What it declares is decided by policy, as any call is.
    ScriptedWorker.script([{:output, %{"declared" => true}}])
    invoke(driver, room, 3, declared <> ":1.0.0")
    assert answered!(3) == {200, result(%{"declared" => true})}
    action(driver, room, 4, "component.list")
    assert {200, %{"ok" => true}} = answered!(4)
    assert [_one] = runs_of(ctx, declared)
  end

  test "a plain page's call is held to no declaration and is decided by policy alone",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    ScriptedWorker.script([{:output, %{"plain" => true}}])
    invoke(driver, room, 1, app <> ":1.0.0")
    assert answered!(1) == {200, result(%{"plain" => true})}
    action(driver, room, 2, "crew.list")
    assert {200, %{"ok" => true}} = answered!(2)

    # An action Aqua's policy asks for asks.
    action(driver, room, 3, "notes.keep", %{"name" => "from-page", "content" => "x"})
    {_turn, approval} = paused!(ctx)

    assert %{"purpose" => "page", "proposal" => %{"tool" => "notes", "action" => "keep"}} =
             intent!(ctx, approval)

    steps = for {_turn, steps} <- turns_after(ctx, room, put), step <- steps, do: step

    assert [
             %{purpose: "page", kind: "launch", outcome: "ok", approval_id: nil},
             %{purpose: "page", tool: "crew", action: "list", outcome: "ok", approval_id: nil},
             %{purpose: "page", tool: "notes", dispatch_state: "proposed", approval_id: card}
           ] = steps

    assert card == approval.id
  end

  # ---------------------------------------------------------------------------
  # A card for one run
  # ---------------------------------------------------------------------------

  test "a component whose grant lets nothing of the page out asks on one card while the page " <>
         "waits, the yes runs it once, and its next call asks on a card of its own",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    approvals =
      for id <- [1, 2] do
        invoke(driver, room, id, app <> ":1.0.0", %{"n" => id})
        {turn, approval} = paused!(ctx)

        # The page waits: nothing answered it, and nothing ran.
        refute_received {:driver, :answer, _session, ^id, _status, _body}
        assert app_runs() == id - 1
        {:ok, steps} = Tape.steps(ctx, turn)

        assert [%{purpose: "page", kind: "launch", dispatch_state: "proposed", approval_id: card}] =
                 Enum.filter(steps, &(&1.dispatch_state == "proposed"))

        assert card == approval.id

        # The launch's card, for this one run, saying the page asks and
        # what of the page it lets out.
        assert %{
                 "purpose" => "page",
                 "proposal" => %{
                   "tool" => "execution",
                   "action" => "run",
                   "lets_flow" => ["vault_disclosed", "outside"]
                 }
               } = intent!(ctx, approval)

        ScriptedWorker.script([{:output, %{"run" => id}}])

        assert {:ok, %{decision: "approved"}} =
                 Approvals.resolve(ctx, approval.id, %{decision: :approved})

        # The answer is that run's result, and the run appended once.
        assert answered!(id) == {200, result(%{"run" => id})}
        assert %{status: "completed"} = ended!(ctx, turn.id)
        assert app_runs() == id
        approval.id
      end

    assert [_, _] = Enum.uniq(approvals)

    steps = for {_turn, steps} <- turns_after(ctx, room, put), step <- steps, do: step

    assert [%{outcome: "ok", approval_id: first}, %{outcome: "ok", approval_id: second}] =
             Enum.filter(steps, &(&1.purpose == "page"))

    assert [first, second] == approvals
    assert length(runs_of(ctx, app)) == 2
  end

  test "a call that arrives while a card waits opens no card until that one is decided, " <>
         "then one of its own",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, first} = paused!(ctx)
    invoke(driver, room, 2, app <> ":1.0.0")
    waiting!(room, 1)

    # No card and no step for it while the first card waits.
    assert {:ok, [%{id: only}]} = Tape.pending_approvals(ctx, turn)
    assert only == first.id
    assert [{_turn, [_one]}] = turns_after(ctx, room, put)

    ScriptedWorker.script([{:output, %{"run" => 1}}])
    {:ok, _} = Approvals.resolve(ctx, first.id, %{decision: :approved})
    assert answered!(1) == {200, result(%{"run" => 1})}

    {_turn, second} = paused!(ctx)
    assert second.id != first.id
    refute_received {:driver, :answer, _session, 2, _status, _body}
    assert app_runs() == 1

    {:ok, _} = Approvals.resolve(ctx, second.id, %{decision: :declined})
    assert {403, %{"ok" => false}} = answered!(2)
    assert app_runs() == 1

    steps = for {_turn, steps} <- turns_after(ctx, room, put), step <- steps, do: step

    assert [%{outcome: "ok", approval_id: asked}, %{outcome: "denied", approval_id: later}] =
             steps

    assert {asked, later} == {first.id, second.id}
  end

  test "with execution.run at ask every call asks, and with it denied every call is refused",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    policy!(ctx, %{"execution.run" => "ask"})

    for id <- [1, 2] do
      invoke(driver, room, id, app <> ":1.0.0")
      {turn, approval} = paused!(ctx)
      refute_received {:driver, :answer, _session, ^id, _status, _body}
      {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :declined})
      assert {403, %{"ok" => false}} = answered!(id)
      ended!(ctx, turn.id)
    end

    policy!(ctx, %{"execution.run" => nil})

    for id <- [3, 4] do
      invoke(driver, room, id, app <> ":1.0.0")

      assert {403,
              %{
                "ok" => false,
                "error" => %{
                  "class" => "forbidden",
                  "message" => "execution.run is not in the agent's policy"
                }
              }} = answered!(id)
    end

    steps = for {_turn, steps} <- turns_after(ctx, room, put), step <- steps, do: step

    assert [
             %{outcome: "denied", approval_id: asked_1},
             %{outcome: "denied", approval_id: asked_2},
             %{outcome: "denied", approval_id: nil, error: refused},
             %{outcome: "denied", approval_id: nil}
           ] = steps

    assert is_binary(asked_1) and is_binary(asked_2) and asked_1 != asked_2
    assert refused == "execution.run is not in the agent's policy"
    assert runs_of(ctx, app) == []
  end

  test "a component with no grant asks, and its yes is refused with nothing run",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, nil, false)
    worker!([app])
    room = workspace!(ctx)
    _put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, approval} = paused!(ctx)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert {_status, %{"ok" => false}} = answered!(1)
    turn = ended!(ctx, turn.id)
    assert {:ok, [%{kind: "launch", outcome: "error", approval_id: card}]} = Tape.steps(ctx, turn)
    assert card == approval.id
    assert runs_of(ctx, app) == [] and app_runs() == 0
  end

  test "in a turn a schedule started, a call that would ask opens no card and ends the run failed",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    {:ok, scheduled} = Sanctum.Tenancy.continuation(ctx.user_id, ctx.athanor_id, "schedule")

    # A page a scheduled run put: its call's turn runs under the schedule.
    room = workspace!(ctx)
    put = put!(scheduled, room, @html)
    assert put.origin == "schedule"
    invoke(driver, room, 1, app <> ":1.0.0")

    assert {403, %{"ok" => false, "error" => %{"class" => "forbidden", "message" => said}}} =
             answered!(1)

    assert [{%{id: turn_id}, _}] = turns_after(ctx, room, put)
    turn = ended!(ctx, turn_id)
    assert {turn.status, turn.origin, turn.error} == {"failed", "schedule", said}
    assert said =~ "This scheduled run needed your approval to run #{app}"
    assert {:ok, []} = Tape.pending_approvals(ctx, turn)
    assert {:ok, [%{outcome: "denied", approval_id: nil, error: ^said}]} = Tape.steps(ctx, turn)
    refute_received %ThreadEvent{kind: :turn_paused}
    assert runs_of(ctx, app) == []
  end

  test "a decline answers the page a refusal and runs nothing", %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, approval} = paused!(ctx)

    assert {:ok, %{decision: "declined"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :declined, reason: "not now"})

    assert {403, %{"ok" => false, "error" => %{"class" => "forbidden"}}} = answered!(1)
    assert %{status: "completed"} = ended!(ctx, turn.id)

    assert [{_turn, [%{purpose: "page", outcome: "denied", approval_id: card}]}] =
             turns_after(ctx, room, put)

    assert card == approval.id
    assert runs_of(ctx, app) == [] and app_runs() == 0
  end

  # ---------------------------------------------------------------------------
  # Aqua's actions
  # ---------------------------------------------------------------------------

  test "an auto action runs, an ask action cards, and a denied one is refused",
       %{ctx: ctx, driver: driver} do
    worker!([])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    policy!(ctx, %{"crew.list" => nil})

    action(driver, room, 1, "component.list")
    assert {200, %{"ok" => true}} = answered!(1)

    action(driver, room, 2, "crew.list")

    assert {403,
            %{
              "ok" => false,
              "error" => %{
                "class" => "forbidden",
                "message" => "crew.list is not in the agent's policy"
              }
            }} = answered!(2)

    action(driver, room, 3, "notes.keep", %{"name" => "from-page", "content" => "kept"})
    {turn, approval} = paused!(ctx)
    refute_received {:driver, :answer, _session, 3, _status, _body}
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})
    assert {200, %{"ok" => true}} = answered!(3)
    ended!(ctx, turn.id)
    assert {:ok, %{content: "kept"}} = Aqua.Notes.read(ctx, "from-page")

    steps = for {_turn, steps} <- turns_after(ctx, room, put), step <- steps, do: step

    assert [
             %{action: "list", tool: "component", outcome: "ok", approval_id: nil},
             %{action: "list", tool: "crew", outcome: "denied", approval_id: nil},
             %{action: "keep", tool: "notes", outcome: "ok", approval_id: card}
           ] = steps

    assert card == approval.id
  end

  # ---------------------------------------------------------------------------
  # A request that ends
  # ---------------------------------------------------------------------------

  test "a request that is gone skips its step, and a late yes runs nothing",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    _put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, approval} = paused!(ctx)
    {:ok, [step]} = Tape.steps(ctx, turn)

    # The driver gives the request up: the page left the window.
    :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "callend", "id" => 1}))

    wait_until(
      fn -> match?({:ok, %{outcome: "skipped"}}, Tape.step(ctx, step.id)) end,
      10_000,
      "the gone request's step to be skipped"
    )

    assert {:ok, %{status: status}} = Tape.approval(ctx, approval.id)
    refute status in ["pending", "approved"]

    ScriptedWorker.script([{:output, %{"late" => true}}])
    _ = Approvals.resolve(ctx, approval.id, %{decision: :approved})
    assert {:ok, %{status: ^status}} = Tape.approval(ctx, approval.id)
    assert {:ok, %{dispatch_state: "closed", outcome: "skipped"}} = Tape.step(ctx, step.id)
    assert {:ok, [_only]} = Tape.steps(ctx, turn)
    assert runs_of(ctx, app) == [] and app_runs() == 0
    refute_received {:driver, :answer, _session, 1, _status, _body}
  end

  test "a call waiting to become a step when its runner is killed is answered unavailable " <>
         "and leaves no step",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, _approval} = paused!(ctx)
    invoke(driver, room, 2, app <> ":1.0.0")
    waiting!(room, 1)

    runner = Runner.whereis(room.id)
    ref = Process.monitor(runner)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}, 5_000

    unavailable = Prima.TinctureWire.refusal(Sanctum.Refusals.classify(:unavailable))
    assert answered!(2) == {503, unavailable}
    assert answered!(1) == {503, unavailable}

    # The call that waited is in no row and no step; the one its card held
    # is skipped by the runner that recovers the turn.
    wait_until(
      fn -> match?({:ok, [%{outcome: "skipped"}]}, Tape.steps(ctx, turn)) end,
      30_000,
      "the held call's step to be skipped"
    )

    assert [{_turn, [_one]}] = turns_after(ctx, room, put)
    assert [%{kind: "page_call"}, %{kind: "page_result"}] = page_rows(ctx, room)
    assert runs_of(ctx, app) == []
  end

  test "a call over the rate is refused, and leaves no step", %{ctx: ctx, driver: driver} do
    Cyfr.Test.Settings.put("frame_invocation_max", 1)
    worker!([])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    action(driver, room, 1, "component.list")
    assert {200, %{"ok" => true}} = answered!(1)
    action(driver, room, 2, "component.list")
    assert {429, %{"ok" => false, "error" => %{"class" => "rate_limited"}}} = answered!(2)

    assert [{turn, [%{outcome: "ok"}]}] = turns_after(ctx, room, put)
    ended!(ctx, turn.id)
    assert [%{kind: "page_call"}, %{kind: "page_result"}] = page_rows(ctx, room)
  end

  # ---------------------------------------------------------------------------
  # Found by these tests; each passes once its fix outside Aqua.PageCalls lands
  # ---------------------------------------------------------------------------

  test "the yes to a call that waited behind a card runs it once, on what the turn read by then",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    _put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {_turn, first} = paused!(ctx)
    invoke(driver, room, 2, app <> ":1.0.0")
    waiting!(room, 1)

    ScriptedWorker.script([{:output, %{"run" => 1}}])
    {:ok, _} = Approvals.resolve(ctx, first.id, %{decision: :approved})
    assert answered!(1) == {200, result(%{"run" => 1})}

    {turn, second} = paused!(ctx)
    ScriptedWorker.script([{:output, %{"run" => 2}}])
    {:ok, _} = Approvals.resolve(ctx, second.id, %{decision: :approved})
    assert answered!(2) == {200, result(%{"run" => 2})}
    assert %{status: "completed"} = ended!(ctx, turn.id)
    assert app_runs() == 2 and length(runs_of(ctx, app)) == 2
  end

  test "a component with no grant is answered consent_required, and the thread asks for its grant",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, nil, false)
    worker!([app])
    room = workspace!(ctx)
    _put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, approval} = paused!(ctx)
    {:ok, _} = Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert {403, %{"ok" => false, "error" => %{"class" => "consent_required"}}} = answered!(1)

    assert_receive %ThreadEvent{kind: :consent_required, data: %{ref: ref, user_id: user_id}},
                   10_000

    assert {ref, user_id} == {app <> ":1.0.0", ctx.user_id}
    ended!(ctx, turn.id)
    assert runs_of(ctx, app) == []
  end

  test "a turn whose last call's request is gone ends", %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    _put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    {turn, _approval} = paused!(ctx)
    :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "callend", "id" => 1}))

    assert %{status: "completed"} = ended!(ctx, turn.id)
    assert {:ok, [%{outcome: "skipped"}]} = Tape.steps(ctx, turn)
    # The runner hears the loop's end after the rows say it.
    wait_until(
      fn -> match?(%{running: false, paused: false}, Runner.state(room.id, ctx.athanor_id)) end,
      10_000,
      "the runner hears the turn end"
    )
  end
end
