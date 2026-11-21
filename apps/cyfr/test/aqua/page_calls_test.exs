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
  does not declare leaves no step; a plain page's call is held to no
  declaration. A call is decided under Aqua's mode in the turn it joins
  or opens, and nothing asks: on auto what Aqua is offered runs at once,
  a component whatever of the page its grant lets out, and on read-only
  a read runs and any other call is refused in the read-only sentence,
  the thread told once. A call Aqua is not offered is refused, and a turn
  a schedule started is decided as any other. A request that is gone
  runs nothing, a call its runner dies holding is answered unavailable,
  and a call over the rate is refused.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait, only: [wait_until: 3]

  alias Aqua.{Runner, Tape}
  alias Aqua.Providers.Browser, as: Provider
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedDriver, as: Driver
  alias Cyfr.Test.ScriptedWorker
  alias Opus.Programs

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @http "catalyst:local.http"
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

  defp browser_row!(ctx, chrome \\ :person) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: Programs.Definition.browser_name(chrome),
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

  # A workspace thread whose first row is its opening, as `workspace.open`
  # writes one, made apart when `apart`.
  defp workspace!(ctx, apart \\ false) do
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

    {:ok, _opening} =
      Arca.ThreadStorage.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: ctx.user_id,
        sent_by: "person",
        kind: "opening",
        content: "Show the page",
        payload: %{"ask" => "Show the page", "asked_by" => ctx.user_id, "apart" => apart}
      })

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
  # egress at all, or with the egress `caps` declare.
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

  # One egress domain.
  @exit %{"egress" => %{"domains" => ["api.example.com"]}}

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

  # Aqua switched to `mode`, as the Aqua page switches it: the mode of the
  # crew member it runs on.
  defp mode!(ctx, mode) do
    assert {:ok, %{"updated" => "claude"}} =
             Cyfr.Test.AquaTool.call(ctx, %{
               "action" => "update",
               "name" => Cyfr.Test.SeedBundle.seat_member(),
               "mode" => mode
             })
  end

  # Aqua offered its tools less `tools`, as the Aqua page writes it, and
  # its grant walked again for the shape that moved.
  defp unoffer!(ctx, tools) do
    assert {:ok, %{"updated" => "aqua"}} =
             Cyfr.Test.AquaTool.call(ctx, %{
               "action" => "update",
               "name" => "aqua",
               "tools_remove" => tools
             })

    walk!(ctx, %{ref: @soul})
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

  # The wire's answer to a call its step refused in `message`.
  defp refused(message),
    do: %{
      "v" => 1,
      "ok" => false,
      "error" => %{"class" => "forbidden", "message" => message, "stage" => "execution"}
    }

  # What a fetch the page asked for answers it: the fetch's data.
  @fetched %{"body" => "x", "status" => 200}
  @get %{"url" => "https://example.test/x"}
  @keep %{"name" => "from-page", "content" => "x"}

  # Work of its own opened on the page's fetch, the fetch held, and a
  # `notes.keep` after it proposed as a step of that work, which waits
  # for the work's next round. Answers the held fetch and the work.
  defp held_fetch!(ctx, driver, room, put) do
    ScriptedWorker.script([{:hold, self()}, @fetched])
    action(driver, room, 1, "http.get", @get)
    assert_receive {:scripted_probe, fetch, _child}, 60_000
    action(driver, room, 2, "notes.keep", @keep)
    proposed!(ctx, room, put, 1)
    [{%{id: work}, _steps}] = turns_after(ctx, room, put)
    {fetch, work}
  end

  # The work after the put's, `n` of its steps proposed behind the first.
  defp proposed!(ctx, room, put, n) do
    wait_until(
      fn ->
        case turns_after(ctx, room, put) do
          [{_turn, [%{dispatch_state: "dispatched"} | rest]}] ->
            length(rest) == n and Enum.all?(rest, &(&1.dispatch_state == "proposed"))

          _other ->
            false
        end
      end,
      10_000,
      "#{n} calls to be steps of the work"
    )
  end

  # Work of its own opened on the page's launch of `app`, the app's run
  # held with the work paused around it, and a second launch of it
  # waiting in the runner, no step yet. Answers the held run and the work.
  defp held_launch!(ctx, driver, room, put, app) do
    ScriptedWorker.script([{:hold, self()}, {:output, %{"run" => 1}}, {:output, %{"run" => 2}}])
    invoke(driver, room, 1, app <> ":1.0.0")
    assert_receive {:scripted_probe, launched, _child}, 60_000

    assert [{%{id: work, status: "paused", paused_reason: "launch"}, _}] =
             turns_after(ctx, room, put)

    invoke(driver, room, 2, app <> ":1.0.0")
    waiting!(room, 1)
    {launched, work}
  end

  # The step at `seq` of `work` skipped.
  defp skipped!(ctx, work, seq) do
    wait_until(
      fn -> match?(%{outcome: "skipped"}, Enum.at(steps!(ctx, work), seq - 1)) end,
      10_000,
      "step #{seq} to be skipped"
    )
  end

  # The browser of `chrome` killed outright, with no word of its calls.
  defp kill_browser!(ctx, chrome) do
    [{holder, _}] = Registry.lookup(Opus.Browser.Registry, {ctx.athanor_id, ctx.user_id, chrome})
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 5_000
  end

  # The thread's runner has taken the end of its work: the next call
  # opens work of its own.
  defp settled!(ctx, room) do
    wait_until(
      fn -> match?(%{running: false, paused: false}, Runner.state(room.id, ctx.athanor_id)) end,
      30_000,
      "the thread's work to settle"
    )
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

  # The requests of the page's calls in `thread`, as their rows name them,
  # oldest first.
  defp requests(ctx, thread),
    do: for(%{kind: "page_call", client_id: request} <- page_rows(ctx, thread), do: request)

  # A turn's steps as a case compares them: every field but those minted
  # (ids, clocks, digests, child runs), with the kinds of the rows a step
  # carries its call and its answer in.
  defp steps!(ctx, turn_id) do
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)

    for step <- steps do
      %{
        seq: step.seq,
        kind: step.kind,
        purpose: step.purpose,
        tool: step.tool,
        action: step.action,
        dispatch_state: step.dispatch_state,
        outcome: step.outcome,
        generation: step.generation,
        recovery: step.recovery,
        idempotency_key: step.idempotency_key,
        error: step.error,
        cancel_requested?: step.cancel_requested_at != nil,
        carried: kind_of(ctx, step.message_id),
        answered: kind_of(ctx, step.result_message_id)
      }
    end
  end

  defp kind_of(_ctx, nil), do: nil

  defp kind_of(ctx, id) do
    {:ok, row} = Tape.message(ctx, id)
    row.kind
  end

  # The step of the page's call `request` of `name` in `turn_id`, closed
  # with `outcome` and `error`; of the calls here only the lists are
  # replay-safe.
  defp page_step(seq, turn_id, request, name, outcome, error \\ nil) do
    [tool, action] = String.split(name, ".")

    %{
      seq: seq,
      kind: if(name == "execution.run", do: "launch", else: "tool"),
      purpose: "page",
      tool: tool,
      action: action,
      dispatch_state: "closed",
      outcome: outcome,
      generation: 0,
      recovery: if(name in ["component.list", "crew.list"], do: "replay_safe"),
      idempotency_key: "page_call:#{turn_id}:#{request}",
      error: error,
      cancel_requested?: false,
      carried: "page_call",
      answered: "page_result"
    }
  end

  # The thread's rows, oldest first, each whole but for its id and clock,
  # which are minted.
  defp rows!(ctx, thread) do
    for row <- Threads.messages(Sanctum.Context.actor(ctx), thread.id),
        do: Map.drop(row, [:id, :inserted_at])
  end

  # A row of `thread` as `rows!/2` reads it: `fields` over the columns a
  # row leaves empty.
  defp row(thread, fields) do
    Map.merge(
      %{
        thread_id: thread.id,
        athanor_id: thread.athanor_id,
        payload: nil,
        status: nil,
        resolved_by: nil,
        carried_by: nil,
        resolved_at: nil,
        execution_id: nil,
        turn_id: nil,
        client_id: nil,
        addressee: nil,
        reply_to: nil,
        outcome: nil,
        workspace_id: nil
      },
      fields
    )
  end

  # ---------------------------------------------------------------------------
  # On auto
  # ---------------------------------------------------------------------------

  test "a granted component with no egress, or with egress, runs once in two workspace " <>
         "threads, as a model's launch runs",
       %{ctx: ctx, driver: driver} do
    quiet = app!(ctx)
    reaching = app!(ctx, @exit)
    worker!([quiet, reaching])

    for {{app, room}, id} <-
          Enum.with_index([{quiet, workspace!(ctx)}, {reaching, workspace!(ctx)}], 1) do
      put = put!(ctx, room, @html)
      ScriptedWorker.script([{:output, %{"answered" => id}}])
      asked = chats()

      invoke(driver, room, id, app <> ":1.0.0", %{"n" => id})
      assert answered!(id) == {200, result(%{"answered" => id})}

      # A turn of its own, asking no model, as the put's person under its
      # origin: one launch, closed with the run's result.
      assert [{%{id: turn_id}, _steps}] = turns_after(ctx, room, put)
      turn = ended!(ctx, turn_id)

      assert {turn.status, turn.requested_by, turn.origin, turn.agent} ==
               {"completed", ctx.user_id, "interactive", "aqua"}

      {:ok, [step]} = Tape.steps(ctx, turn)

      assert %{
               purpose: "page",
               kind: "launch",
               dispatch_state: "closed",
               outcome: "ok",
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

  test "a plain page's call is held to no declaration and is decided by Aqua's mode alone: " <>
         "on auto each runs at once, a step that does more than read among them",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    ScriptedWorker.script([{:output, %{"plain" => true}}])
    invoke(driver, room, 1, app <> ":1.0.0")
    assert answered!(1) == {200, result(%{"plain" => true})}
    settled!(ctx, room)
    action(driver, room, 2, "crew.list")
    assert {200, %{"ok" => true}} = answered!(2)
    settled!(ctx, room)
    action(driver, room, 3, "notes.keep", @keep)
    assert {200, %{"ok" => true}} = answered!(3)
    settled!(ctx, room)

    # Each opened work of its own on auto, which ran it at once.
    [launch, list, keep] = requests(ctx, room)

    assert [{%{id: first}, _}, {%{id: second}, _}, {%{id: third}, _}] =
             turns_after(ctx, room, put)

    for id <- [first, second, third],
        do: assert(%{status: "completed", agent_mode: "auto", error: nil} = ended!(ctx, id))

    assert [steps!(ctx, first), steps!(ctx, second), steps!(ctx, third)] == [
             [page_step(1, first, launch, "execution.run", "ok")],
             [page_step(1, second, list, "crew.list", "ok")],
             [page_step(1, third, keep, "notes.keep", "ok")]
           ]

    assert {:ok, %{content: "x"}} = Aqua.Notes.read(ctx, "from-page")
    assert app_runs() == 1
  end

  # ---------------------------------------------------------------------------
  # Aqua's mode and its tools
  # ---------------------------------------------------------------------------

  test "on read-only a page's read runs and any other call is refused in the read-only " <>
         "sentence, the thread told once, and nothing pauses",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([@http, app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    mode!(ctx, "read-only")

    # The page's fetch opens work of its own and is held there, so the
    # keep and the launch after it are steps of that work, decided in its
    # next round.
    {fetch, work} = held_fetch!(ctx, driver, room, put)
    invoke(driver, room, 3, app <> ":1.0.0")
    proposed!(ctx, room, put, 2)
    send(fetch, :continue)

    sentence = Aqua.Loop.Policy.read_only_sentence("Aqua")
    assert answered!(1) == {200, result(@fetched)}
    assert answered!(2) == {403, refused(sentence)}
    assert answered!(3) == {403, refused(sentence)}

    assert %{status: "completed", agent_mode: "read-only", error: nil, root_execution_id: root} =
             ended!(ctx, work)

    refute_received %ThreadEvent{kind: :turn_paused}
    [get, keep, launch] = requests(ctx, room)

    assert steps!(ctx, work) == [
             page_step(1, work, get, "http.get", "ok"),
             page_step(2, work, keep, "notes.keep", "denied", sentence),
             page_step(3, work, launch, "execution.run", "denied", sentence)
           ]

    # The thread is told once, right after the first refusal's answer.
    rows = rows!(ctx, room)
    [said] = for %{kind: "system"} = row <- rows, do: row
    [_fetched, first_refused, _second] = for %{kind: "page_result"} = row <- rows, do: row.seq

    assert said ==
             row(room, %{
               seq: said.seq,
               author: Prima.Author.system(),
               kind: "system",
               content: sentence,
               execution_id: root,
               turn_id: work,
               client_id: "read-only:" <> work,
               sent_by: "aqua"
             })

    assert said.seq == first_refused + 1
    assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
    assert runs_of(ctx, app) == [] and app_runs() == 0
  end

  test "a call Aqua is not offered is refused, a launch among them, and nothing of it runs",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    # Granted and on auto, the launch would run but for the tools.
    unoffer!(ctx, ["crew.list", "execution.run"])

    action(driver, room, 1, "component.list")
    assert {200, %{"ok" => true}} = answered!(1)
    settled!(ctx, room)
    action(driver, room, 2, "crew.list")
    assert answered!(2) == {403, refused("crew.list is not among the tools Aqua is offered")}
    settled!(ctx, room)
    invoke(driver, room, 3, app <> ":1.0.0")

    assert answered!(3) ==
             {403, refused("execution.run is not among the tools Aqua is offered")}

    settled!(ctx, room)
    [offered, list, launch] = requests(ctx, room)

    assert [{%{id: first}, _}, {%{id: second}, _}, {%{id: third}, _}] =
             turns_after(ctx, room, put)

    assert [steps!(ctx, first), steps!(ctx, second), steps!(ctx, third)] == [
             [page_step(1, first, offered, "component.list", "ok")],
             [
               page_step(
                 1,
                 second,
                 list,
                 "crew.list",
                 "denied",
                 "crew.list is not among the tools Aqua is offered"
               )
             ],
             [
               page_step(
                 1,
                 third,
                 launch,
                 "execution.run",
                 "denied",
                 "execution.run is not among the tools Aqua is offered"
               )
             ]
           ]

    assert runs_of(ctx, app) == [] and app_runs() == 0
  end

  test "a component with egress runs at once each time, once, with nothing asked",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    for id <- [1, 2] do
      ScriptedWorker.script([{:output, %{"run" => id}}])
      invoke(driver, room, id, app <> ":1.0.0", %{"n" => id})
      assert answered!(id) == {200, result(%{"run" => id})}
      settled!(ctx, room)
      assert app_runs() == id
    end

    [one, two] = requests(ctx, room)
    assert [{%{id: first}, _}, {%{id: second}, _}] = turns_after(ctx, room, put)

    assert [steps!(ctx, first), steps!(ctx, second)] == [
             [page_step(1, first, one, "execution.run", "ok")],
             [page_step(1, second, two, "execution.run", "ok")]
           ]

    assert length(runs_of(ctx, app)) == 2
  end

  test "in a turn a schedule started, a page's call is decided by the mode as any turn's: " <>
         "on auto it runs, and on read-only it is refused and the turn completes",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, @exit)
    worker!([app])
    {:ok, scheduled} = Sanctum.Tenancy.continuation(ctx.user_id, ctx.athanor_id, "schedule")

    # A page a scheduled run put: its calls' work runs under the schedule.
    room = workspace!(ctx)
    put = put!(scheduled, room, @html)
    assert put.origin == "schedule"

    ScriptedWorker.script([{:output, %{"run" => 1}}])
    invoke(driver, room, 1, app <> ":1.0.0")
    assert answered!(1) == {200, result(%{"run" => 1})}
    settled!(ctx, room)

    mode!(ctx, "read-only")
    sentence = Aqua.Loop.Policy.read_only_sentence("Aqua")
    invoke(driver, room, 2, app <> ":1.0.0")
    assert answered!(2) == {403, refused(sentence)}
    settled!(ctx, room)

    [ran, stopped] = requests(ctx, room)
    assert [{%{id: first}, _}, {%{id: second}, _}] = turns_after(ctx, room, put)

    # Neither ended failed: the refusal is no question, and the turn went on.
    assert Enum.map([first, second], fn id ->
             turn = ended!(ctx, id)
             {turn.status, turn.origin, turn.agent_mode, turn.error}
           end) == [
             {"completed", "schedule", "auto", nil},
             {"completed", "schedule", "read-only", nil}
           ]

    assert [steps!(ctx, first), steps!(ctx, second)] == [
             [page_step(1, first, ran, "execution.run", "ok")],
             [page_step(1, second, stopped, "execution.run", "denied", sentence)]
           ]

    assert length(runs_of(ctx, app)) == 1
  end

  # ---------------------------------------------------------------------------
  # A request that ends
  # ---------------------------------------------------------------------------

  test "a request that is gone skips its step, which never runs, and the work it was a step " <>
         "of ends once the rest has run",
       %{ctx: ctx, driver: driver} do
    worker!([@http])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    {fetch, work} = held_fetch!(ctx, driver, room, put)

    # The driver gives the keep's request up: the page left the window.
    :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "callend", "id" => 2}))
    skipped!(ctx, work, 2)
    send(fetch, :continue)

    assert answered!(1) == {200, result(@fetched)}
    assert %{status: "completed"} = ended!(ctx, work)
    # The runner hears the work's end after the rows say it.
    settled!(ctx, room)
    [get, keep] = requests(ctx, room)

    assert steps!(ctx, work) == [
             page_step(1, work, get, "http.get", "ok"),
             page_step(2, work, keep, "notes.keep", "skipped")
           ]

    assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
    refute_received {:driver, :answer, _session, 2, _status, _body}
  end

  test "a call whose browser is killed outright skips its step, which never runs",
       %{ctx: ctx, driver: driver} do
    worker!([@http])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    {fetch, work} = held_fetch!(ctx, driver, room, put)

    # The fetch already at work runs to its end; the keep never starts.
    kill_browser!(ctx, :person)
    skipped!(ctx, work, 2)
    send(fetch, :continue)

    assert %{status: "completed"} = ended!(ctx, work)
    [get, keep] = requests(ctx, room)

    assert steps!(ctx, work) == [
             page_step(1, work, get, "http.get", "ok"),
             page_step(2, work, keep, "notes.keep", "skipped")
           ]

    assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
  end

  test "a call whose browser is killed outright before its runner takes it runs nothing, " <>
         "and the turn opened on it ends",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    wait_until(
      fn -> match?(%{running: false, paused: false}, Runner.state(room.id, ctx.athanor_id)) end,
      10_000,
      "the putting turn to settle"
    )

    runner = Runner.whereis(room.id)
    [{holder, _}] = Registry.lookup(Opus.Browser.Registry, {ctx.athanor_id, ctx.user_id, :person})
    ScriptedWorker.script([{:output, %{"late" => true}}])

    # The call is taken from the browser while its runner cannot take it
    # yet, and the browser dies with no word of it.
    :ok = :sys.suspend(runner)

    try do
      invoke(driver, room, 1, app <> ":1.0.0")

      wait_until(
        fn ->
          Enum.any?(:sys.get_state(holder).calls, fn {_request, call} ->
            is_reference(call.monitor)
          end)
        end,
        5_000,
        "the call taker to hold the call"
      )

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 5_000
    after
      :sys.resume(runner)
    end

    wait_until(fn -> turns_after(ctx, room, put) != [] end, 10_000, "the turn opened on the call")
    [{turn, _steps}] = turns_after(ctx, room, put)
    assert %{status: "completed"} = ended!(ctx, turn.id)
    # The end reached the call before its step or after: no step, or one skipped.
    assert [{_turn, steps}] = turns_after(ctx, room, put)
    assert Enum.all?(steps, &match?(%{dispatch_state: "closed", outcome: "skipped"}, &1))
    assert runs_of(ctx, app) == [] and app_runs() == 0
  end

  test "a call waiting behind a launch when its browser is killed outright never becomes a " <>
         "step, and runs nothing",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    {launched, work} = held_launch!(ctx, driver, room, put, app)

    kill_browser!(ctx, :person)
    waiting!(room, 0)
    send(launched, :continue)

    # The launch already at work runs to its end; the one that waited
    # leaves no row and no step.
    assert %{status: "completed"} = ended!(ctx, work)
    [launch] = requests(ctx, room)
    assert steps!(ctx, work) == [page_step(1, work, launch, "execution.run", "ok")]
    assert [%{kind: "page_call"}, %{kind: "page_result"}] = page_rows(ctx, room)
    assert app_runs() == 1 and length(runs_of(ctx, app)) == 1
  end

  test "in a thread kept apart, a page's call is the second Chrome's, and that browser killed " <>
         "outright skips its step, which never runs",
       %{ctx: ctx, driver: driver} do
    browser_row!(ctx, :apart)
    worker!([@http])
    room = workspace!(ctx, true)
    put = put!(ctx, room, @html)
    {fetch, work} = held_fetch!(ctx, driver, room, put)

    # The person's own Chrome never started: the page is in the second.
    assert [] = Registry.lookup(Opus.Browser.Registry, {ctx.athanor_id, ctx.user_id, :person})
    kill_browser!(ctx, :apart)
    skipped!(ctx, work, 2)
    send(fetch, :continue)

    assert %{status: "completed"} = ended!(ctx, work)
    [get, keep] = requests(ctx, room)

    assert steps!(ctx, work) == [
             page_step(1, work, get, "http.get", "ok"),
             page_step(2, work, keep, "notes.keep", "skipped")
           ]

    assert {:error, _} = Aqua.Notes.read(ctx, "from-page")
  end

  test "a call waiting to become a step when its runner is killed is answered unavailable " <>
         "and leaves no step",
       %{ctx: ctx, driver: driver} do
    worker!([@http])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    # The page's fetch is lost with its waiter: its work stops on the
    # unknown outcome, and a call after it waits in the runner.
    ScriptedWorker.script([{:crash, :before_response}])
    action(driver, room, 1, "http.get", @get)

    assert_receive %ThreadEvent{kind: :turn_paused, data: %{turn_id: work, reason: :uncertain}},
                   60_000

    action(driver, room, 2, "component.list")
    waiting!(room, 1)

    runner = Runner.whereis(room.id)
    ref = Process.monitor(runner)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}, 5_000

    unavailable = Prima.TinctureWire.refusal(Sanctum.Refusals.classify(:unavailable))
    assert answered!(2) == {503, unavailable}
    assert answered!(1) == {503, unavailable}

    # The runner that recovers the work holds neither: the call that
    # waited is in no row and no step.
    wait_until(
      fn -> match?(%{paused: true}, Runner.state(room.id, ctx.athanor_id)) end,
      30_000,
      "the recovered work to wait on its unknown outcome"
    )

    [get] = requests(ctx, room)
    assert [{%{id: ^work}, _steps}] = turns_after(ctx, room, put)

    assert steps!(ctx, work) == [
             %{
               page_step(1, work, get, "http.get", "uncertain", "killed")
               | dispatch_state: "uncertain",
                 answered: nil
             }
           ]

    assert [%{kind: "page_call"}] = page_rows(ctx, room)
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

  test "a call that waited while its work was paused around a launch runs once after it",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)
    {launched, work} = held_launch!(ctx, driver, room, put, app)
    send(launched, :continue)

    assert answered!(1) == {200, result(%{"run" => 1})}
    assert answered!(2) == {200, result(%{"run" => 2})}
    settled!(ctx, room)
    [first, second] = requests(ctx, room)

    # It is a step of the work once that runs again, or, when the work
    # ended first, of work of its own.
    case turns_after(ctx, room, put) do
      [{%{id: ^work}, _}] ->
        assert steps!(ctx, work) == [
                 page_step(1, work, first, "execution.run", "ok"),
                 page_step(2, work, second, "execution.run", "ok")
               ]

      [{%{id: ^work}, _}, {%{id: own}, _}] ->
        assert [steps!(ctx, work), steps!(ctx, own)] == [
                 [page_step(1, work, first, "execution.run", "ok")],
                 [page_step(1, own, second, "execution.run", "ok")]
               ]
    end

    assert app_runs() == 2 and length(runs_of(ctx, app)) == 2
  end

  test "a component with no grant is answered consent_required, and the thread asks for its grant",
       %{ctx: ctx, driver: driver} do
    app = app!(ctx, nil, false)
    worker!([app])
    room = workspace!(ctx)
    put = put!(ctx, room, @html)

    invoke(driver, room, 1, app <> ":1.0.0")
    assert {403, %{"ok" => false, "error" => %{"class" => "consent_required"}}} = answered!(1)

    assert_receive %ThreadEvent{kind: :consent_required, data: %{ref: ref, user_id: user_id}},
                   10_000

    assert {ref, user_id} == {app <> ":1.0.0", ctx.user_id}
    [launch] = requests(ctx, room)
    assert [{%{id: work}, _}] = turns_after(ctx, room, put)
    assert %{status: "completed"} = ended!(ctx, work)
    said = "Consent required: #{app} has not been granted — grant it to run it"
    assert steps!(ctx, work) == [page_step(1, work, launch, "execution.run", "error", said)]
    assert runs_of(ctx, app) == [] and app_runs() == 0
  end
end
