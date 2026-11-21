# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SeatTest do
  @moduledoc """
  Aqua as a seat, through the real loop and a scripted model: Aqua runs on
  the crew member its file names, with that member's brain, model and
  options and its own prompt and tools, its prompt in two parts (its file's,
  then CYFR's) with the job apart from both; a turn pins Aqua's file, so a
  member chosen while a turn is open does not retarget it, recovery
  included, and the next turn runs on the new one once its consent is
  given, which choosing does not give; a member that does not stand
  refuses Aqua's turn with the sentence Aqua's card says; a file that
  names a brain of its own is refused; and the member Aqua runs on is
  still a worker under its own name, briefed as one, which asks nobody.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @gemini "catalyst:local.gemini"
  @context "\n\n---\n\n## Runtime Context\n\n"
  # A rebuilt turn whose pins moved since its root was claimed.
  @moved_on "The turn moved on — read the thread again and retry"

  setup do
    # Deliberate crashes in other tests must not spend this test's restart budget.
    restart_runner_supervisor!()
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    athanor = Sanctum.Test.People.athanor!(user)
    ctx = %{ctx | athanor_id: athanor.id, origin: :interactive}
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    on_exit(fn -> File.rm_rf!(tree) end)

    # The seed's Aqua runs on its own crew member on the Claude catalyst
    # (`Cyfr.Test.SeedBundle.seat!/2`), beside two more members of the
    # seed's own to choose: one on Gemini and one on a program.
    seed = Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))

    :ok =
      Cyfr.Test.SeedBundle.member!(seed, "explorer",
        catalyst_ref: @gemini,
        model: "gemini-pro-latest"
      )

    :ok =
      Cyfr.Test.SeedBundle.member!(seed, "claude-code",
        title: "Claude Code",
        program: "claude",
        model: "opus"
      )

    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)

    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})

    ScriptedWorker.fresh_limits!(ctx, [
      @model,
      @gemini,
      "catalyst:local.files",
      "catalyst:local.http"
    ])

    {:ok, room} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(room.id, ctx.athanor_id)
    {:ok, ctx: ctx, room: room, holder: Cyfr.Test.SeedBundle.seat_member()}
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  defp accept!(ctx, thread, text, agent \\ "aqua") do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: agent, requested_by: ctx.user_id}
      })

    turn
  end

  defp run(ctx, turn), do: Aqua.Loop.run(ctx: ctx, turn_id: turn.id)

  # The model calls of `name`'s turns: every call names the crew's one
  # grant, Aqua's, so the worker is the turn the call's root holds.
  defp chats(ctx, name) do
    Enum.filter(
      ScriptedWorker.calls(),
      &(&1.input["operation"] == "chat" and worker_of(ctx, &1) == name)
    )
  end

  defp worker_of(ctx, %{execution_id: id}) do
    case Arca.Execution.get_tenant(actor(ctx), id) do
      %{root_execution_id: root} ->
        Arca.Repo.one(
          from(t in Arca.Schemas.Turn,
            where: t.athanor_id == ^ctx.athanor_id and t.root_execution_id == ^(root || id),
            select: t.agent
          )
        )

      _another_athanors ->
        nil
    end
  end

  defp aqua!(ctx, args) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, Map.merge(args, %{"action" => "update", "name" => "aqua"}))

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    :ok
  end

  # Aqua's consent given again as a person gives it, its brain's key the
  # one the catalyst's own profile binds.
  defp consent!(ctx, ref, selections) do
    decisions = %{ref: ref, selections: selections}
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    :ok
  end

  # The head of the crew's one grant, Aqua's.
  defp grant_head(ctx) do
    {:ok, [profile]} = Arca.ConsentStorage.profiles(actor(ctx), @soul)
    {:ok, head, _refs} = Arca.ConsentStorage.get_head(actor(ctx), profile.id)
    {:ok, head}
  end

  defp seat_prompt do
    {:ok, %{prompt: prompt}} = Compendium.AquaTemplate.shipped_agent("aqua")
    String.trim_trailing(prompt)
  end

  defp system_lines(ctx, thread) do
    for row <- Threads.messages(actor(ctx), thread.id), row.kind == "system", do: row.content
  end

  # What the agent said in the thread in turn `turn_id`.
  defp answers(ctx, thread, turn_id) do
    agent = Arca.Schemas.Message.agent_author()

    for %{author: ^agent, turn_id: ^turn_id} = row <- Threads.messages(actor(ctx), thread.id),
        do: row.content
  end

  defp restart_runner_supervisor! do
    :ok = Supervisor.terminate_child(Aqua.RunnerTree, Aqua.RunnerSupervisor)
    {:ok, _supervisor} = Supervisor.restart_child(Aqua.RunnerTree, Aqua.RunnerSupervisor)
    :ok
  end

  # The thread's runner and loop, once the turn's model call is held open.
  defp running!(thread) do
    assert_receive {:scripted_probe, call, _}, 60_000
    runner = Aqua.Runner.whereis(thread.id)
    %{live: %{task: %Aqua.Loop.Worker.Handle{pid: loop}}} = :sys.get_state(runner)
    %{runner: runner, loop: loop, call: call}
  end

  # Aqua's turn on `text`, its model call held open until released.
  defp open_turn!(ctx, room, text) do
    {:ok, %{turn_id: turn_id}} = Aqua.Runner.send_message(ctx, room.id, "@aqua " <> text)
    {turn_id, running!(room)}
  end

  # The held call released, and the loop runs the turn to its end.
  defp finish!(pids) do
    send(pids.call, :continue)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
  end

  # The runner killed mid-call, and its restart takes the turn over. The
  # dead call is answered, for the test to release once nothing else is
  # scripted after it, and the restart budget is fresh again.
  defp take_over!(pids) do
    :ok = kill_and_await!(pids)
    assert_receive %ThreadEvent{kind: :turn_finished}, 60_000
    restart_runner_supervisor!()
    pids.call
  end

  # The member `name` edited as its card on the Aqua page edits it.
  defp member!(ctx, name, edit) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, Map.merge(edit, %{"action" => "update", "name" => name}))

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    :ok
  end

  # The runner killed, its loop and the held call going with it; its
  # supervisor restarts it, and the restart takes the turn over.
  defp kill_and_await!(%{runner: runner} = pids) do
    refs = for {_name, pid} <- pids, into: %{}, do: {Process.monitor(pid), pid}
    Process.exit(runner, :kill)
    for {ref, _pid} <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
    _ = :sys.get_state(Aqua.RunnerSupervisor)
    :ok
  end

  # Aqua's request: its brain and model are its member's, its prompt its
  # file's then CYFR's part for that brain, and the job is the message,
  # never the prompt.
  test "Aqua runs on its member's brain and model, its own prompt then CYFR's part, the job apart",
       %{ctx: ctx, room: room, holder: holder} do
    script!([reply("Hello.")])
    turn = accept!(ctx, room, "say hello to the fern")
    assert :completed = run(ctx, turn)

    assert [%{input: %{"params" => params}}] = chats(ctx, "aqua")
    assert chats(ctx, holder) == []
    assert params["model"] == "claude-sonnet-5-5"

    [opening, context] = String.split(params["system"], @context, parts: 2)
    assert opening == seat_prompt() <> "\n\n---\n\n" <> Aqua.Prompt.briefing(false, false)
    refute opening =~ "## Crew member"
    refute params["system"] =~ "folder"
    refute params["system"] =~ "say hello to the fern"
    assert context =~ "\n\n---\n\n## Scrolls\n\n"

    assert [%{"role" => "user", "content" => content}] = params["messages"]
    assert Jason.encode!(content) =~ "say hello to the fern"

    {:ok, pinned} = Tape.turn(ctx, turn.id)
    assert %{agent: "aqua"} = pinned
    assert String.starts_with?(pinned.catalyst_ref, @model <> ":")
  end

  # The member Aqua runs on is a worker too, under its own name, in its
  # own thread: a crew member's opening and CYFR's part, never Aqua's
  # prompt, and its own turn asks nobody.
  test "the member Aqua runs on works a job as itself, briefed as a member, and asks nobody",
       %{ctx: ctx, room: room, holder: holder} do
    script!([
      reply("Done."),
      %{
        "content" => [
          %{
            "type" => "tool_call",
            "id" => "c1",
            "name" => "crew",
            "arguments" => %{"action" => "ask", "member" => "explorer", "task" => "help"}
          }
        ],
        "stop_reason" => "tool_call",
        "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
      },
      reply("Nobody else.")
    ])

    {:ok, child} = Threads.crew_thread(actor(ctx), room.id, holder)

    turn = accept!(ctx, child, "tidy the notes", holder)
    assert :completed = run(ctx, turn)

    assert [%{input: %{"params" => %{"system" => system}}}] = chats(ctx, holder)
    assert chats(ctx, "aqua") == []
    [opening, _context] = String.split(system, @context, parts: 2)
    assert opening == Aqua.Prompt.crew_briefing(false, false)
    refute system =~ seat_prompt()

    # Its own turn's crew.ask of a member that is ready reaches the
    # admission rule, which only Aqua's turn in a daily or workspace thread
    # passes: refused, nothing written.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @gemini, %{"GEMINI_API_KEY" => "g-test"})
    assert :ok = Aqua.Crew.ready(ctx, "explorer")
    asking = accept!(ctx, child, "get explorer to help", holder)
    assert :completed = run(ctx, asking)
    {:ok, steps} = Tape.steps(ctx, elem(Tape.turn(ctx, asking.id), 1))

    assert [%{outcome: outcome, error: error}] =
             Enum.filter(steps, &(&1.tool == "crew" and &1.action == "ask"))

    refute outcome == "ok"
    assert is_binary(error)
    assert List.last(answers(ctx, child, asking.id)) == "Nobody else."

    for thread <- [room, child],
        do: assert(Threads.pending_requests(actor(ctx), thread_id: thread.id) == [])
  end

  # A brain picked for the member Aqua runs on asks nothing: the crew's one
  # grant names every brain the athanor can connect, so Aqua's turn and a
  # job of the member's own run on the new brain at once, each with that
  # brain's own key, under the one grant.
  test "the member Aqua runs on, its brain moved, runs Aqua's turn and a job of its own on the " <>
         "new brain at once, with that brain's key",
       %{ctx: ctx, room: room, holder: holder} do
    start_supervised!(
      {ScriptedWorker, ref: [@model, @gemini], script: [reply("Aqua."), reply("The member.")]}
    )

    {:ok, %{revision: revision}} = grant_head(ctx)
    key = Sanctum.Test.ConsentFixtures.bind_key!(ctx, @gemini, %{"GEMINI_API_KEY" => "g-test"})
    :ok = member!(ctx, holder, %{"catalyst_ref" => @gemini, "model" => "gemini-pro-latest"})

    aqua = accept!(ctx, room, "hello")
    assert :completed = run(ctx, aqua)
    {:ok, child} = Threads.crew_thread(actor(ctx), room.id, holder)
    done = accept!(ctx, child, "tidy the notes", holder)
    assert :completed = run(ctx, done)

    for name <- ["aqua", holder] do
      assert [%{input: %{"params" => %{"model" => "gemini-pro-latest"}}, authority: authority}] =
               chats(ctx, name)

      assert authority.chain == [@soul, @gemini]
      assert authority.resources.vault.entry_id == key.id
    end

    # Nothing was granted along the way: the grant is the one the fill made.
    assert {:ok, %{revision: ^revision}} = grant_head(ctx)
  end

  # A turn pins Aqua's file, which names its member: rebuilt as recovery
  # rebuilds it, it runs on the member it started on. Choosing another asks
  # nothing and changes no grant: the next turn runs on the new member's
  # brain under the same grant.
  # The crew's grant is Aqua's whatever brain its member runs on: Aqua on a
  # member whose brain is a program that stands reads the grant's stale
  # state, as Aqua on a catalyst does, and its refused turn asks for the
  # grant.
  test "Aqua on a program brain reads the crew's stale grant, and its refused turn asks for it",
       %{ctx: ctx, room: room} do
    {:ok, _row} =
      Arca.McpServerStorage.insert(actor(ctx), %{
        cap: 0,
        name: "claude",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => "cyfr-claude-code claude", "env" => %{}})
      })

    :ok = aqua!(ctx, %{"member" => "claude-code"})
    agents = [%{"name" => "aqua", "program" => "claude"}]
    assert %{"aqua" => {:ready, "claude"}} = Aqua.Models.model_status(ctx, agents)

    # A tool Aqua gains moves the grant's shape: stale until granted again.
    :ok = aqua!(ctx, %{"tools_add" => [ungranted_action(ctx)]})
    assert %{"aqua" => {:consent_stale, "claude"}} = Aqua.Models.model_status(ctx, agents)

    turn = accept!(ctx, room, "hello?")
    assert {:failed, :setup_required} = run(ctx, turn)
    assert {:ok, %{status: "failed", root_execution_id: nil}} = Tape.turn(ctx, turn.id)
    room_id = room.id

    assert_receive %ThreadEvent{
                     thread_id: ^room_id,
                     kind: :consent_required,
                     data: %{ref: @soul}
                   },
                   5_000
  end

  # A grant there is none of (here, the person revoked it) is Aqua's own
  # state whatever brain its member runs on, the brain's own grant
  # standing: never the brain's to connect and never ready. A member on
  # that brain reads its brain alone.
  test "Aqua without its grant reads that state on a program brain and on a catalyst",
       %{ctx: ctx, holder: holder} do
    {:ok, _row} =
      Arca.McpServerStorage.insert(actor(ctx), %{
        cap: 0,
        name: "claude",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => "cyfr-claude-code claude", "env" => %{}})
      })

    on_program = [%{"name" => "aqua", "program" => "claude"}]
    on_catalyst = [%{"name" => "aqua", "catalyst_ref" => @model}]
    member = [%{"name" => holder, "catalyst_ref" => @model}]
    assert %{"aqua" => {:ready, "claude"}} = Aqua.Models.model_status(ctx, on_program)
    assert %{"aqua" => {:ready, _}} = Aqua.Models.model_status(ctx, on_catalyst)

    {:ok, %{revoked: [_ | _]}} = Sanctum.Consent.revoke_source(ctx, @soul)

    assert %{"aqua" => {:consent_absent, "claude"}} = Aqua.Models.model_status(ctx, on_program)
    assert %{"aqua" => {:consent_absent, resolved}} = Aqua.Models.model_status(ctx, on_catalyst)
    assert String.starts_with?(resolved, @model <> ":")
    assert %{^holder => {:ready, _}} = Aqua.Models.model_status(ctx, member)
  end

  # A catalog action Aqua's list does not reach, of a tool no bundled
  # catalyst serves, so granting it adds no dependency.
  defp ungranted_action(ctx) do
    {:ok, soul} = Compendium.AquaAgent.get(ctx, "aqua")
    held = Sanctum.Consent.ShapeDerivation.expand_tools(soul.tools)

    Enum.find(Sanctum.Catalog.tool_actions(), fn key ->
      [tool, _action] = String.split(key, ".", parts: 2)

      key not in held and key not in Prima.Manifest.Caps.agent_only_tools() and
        Sanctum.VirtualTools.catalyst_for(tool) == nil
    end)
  end

  test "a member chosen during a turn does not retarget it; the next turn runs on the new one, asking nothing",
       %{ctx: ctx, room: room, holder: holder} do
    start_supervised!(
      {ScriptedWorker, ref: [@model, @gemini], script: [reply("First."), reply("Third.")]}
    )

    first = accept!(ctx, room, "first")
    assert :completed = run(ctx, first)
    {:ok, pinned} = Tape.turn(ctx, first.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)

    :ok = aqua!(ctx, %{"member" => "explorer"})

    {:ok, spec} = Aqua.Loop.Turn.build(ctx, pinned, authority: authority, excerpt?: false)
    assert %{state: :held, name: ^holder} = spec.agent["holder"]
    assert String.starts_with?(spec.catalyst, @model <> ":")
    assert spec.model == "claude-sonnet-5-5"

    # The next turn is the new member's: its brain and model.
    {:ok, next} = Compendium.agent_snapshot(ctx, "aqua")

    assert %{
             member: "explorer",
             catalyst_ref: @gemini,
             model: "gemini-pro-latest",
             holder: %{name: "explorer", state: :held}
           } = next.agent

    # Choosing changed no grant: the next turn, its brain connected, runs
    # on the new member's brain and model under the same grant.
    assert {:ok, again} = Opus.authority_for(ctx, :default, @soul)
    assert again.consent_id == authority.consent_id
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @gemini, %{"GEMINI_API_KEY" => "g-test"})
    third = accept!(ctx, room, "third")
    assert :completed = run(ctx, third)

    assert ["claude-sonnet-5-5", "gemini-pro-latest"] =
             Enum.map(chats(ctx, "aqua"), & &1.input["params"]["model"])

    assert {:ok, %{agent: "aqua", catalyst_ref: @gemini <> ":" <> _}} = Tape.turn(ctx, third.id)
    assert answers(ctx, room, third.id) == ["Third."]
  end

  # A turn pins Aqua's file, which names its member; the member's file is
  # read as it stands, under the capability digest the turn pinned and the
  # consent its root was claimed under (`Compendium.AquaAgent.resolve/3`).
  # A loop holds what it built for its whole run; a rebuilt one, as a
  # takeover after its runner dies rebuilds it (`Aqua.Loop.run_nested/1`),
  # runs on the member the pin names or is refused, never on another
  # brain. Each turn's model call is held open while what Aqua runs on
  # changes.
  describe "a change while Aqua's turn is open" do
    test "a member chosen while the turn is open never retargets it: the loop finishes on the " <>
           "member it started on; taken over, it runs on that member or is refused",
         %{ctx: ctx, room: room, holder: holder} do
      script!([
        {:probe, self()},
        reply("On claude."),
        {:probe, self()},
        reply("Taken over."),
        {:probe, self()},
        reply("Taken over again.")
      ])

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "twin",
          "title" => "Twin",
          "catalyst_ref" => @model,
          "model" => "claude-opus-5-5"
        })

      # The loop holds what it built: another member chosen mid-call, it
      # finishes on its own.
      {live, pids} = open_turn!(ctx, room, "first")
      :ok = aqua!(ctx, %{"member" => "explorer"})
      finish!(pids)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, live)
      assert answers(ctx, room, live) == ["On claude."]
      :ok = aqua!(ctx, %{"member" => holder})

      # A member on the same brain with another model, chosen mid-call:
      # taken over, the turn runs on the member its pin names, its model.
      {same, pids} = open_turn!(ctx, room, "second")
      :ok = aqua!(ctx, %{"member" => "twin"})
      dead = take_over!(pids)

      assert {:ok, %{status: "completed", recovery_attempts: 1}} = Tape.turn(ctx, same)

      assert answers(ctx, room, same) == ["Taken over."]
      :ok = aqua!(ctx, %{"member" => holder})

      # A member on another brain, chosen mid-call: the crew's grant does
      # not follow it, so taken over, the turn runs on the member its pin
      # names, and nothing reaches the other brain.
      {:ok, %{consent_id: grant}} = Opus.authority_for(ctx, :default, @soul)
      {other, pids} = open_turn!(ctx, room, "third")
      :ok = aqua!(ctx, %{"member" => "explorer"})
      gone = take_over!(pids)

      assert {:ok, %{status: "completed", recovery_attempts: 1}} = Tape.turn(ctx, other)
      assert answers(ctx, room, other) == ["Taken over again."]

      for call <- [dead, gone], do: send(call, :continue)

      # The first turn's call, the second's and the third's held and
      # taken-over ones: each on the member the pin names.
      assert List.duplicate("claude-sonnet-5-5", 5) ==
               Enum.map(chats(ctx, "aqua"), & &1.input["params"]["model"])

      # The file names the new member, and the grant is the one it was.
      assert {:ok, %{agent: %{holder: %{name: "explorer", state: :held}}}} =
               Compendium.agent_snapshot(ctx, "aqua")

      assert {:ok, %{consent_id: ^grant}} = Opus.authority_for(ctx, :default, @soul)
    end

    test "a member whose brain or access moves while the turn is open never runs it on the " <>
           "new one: the loop finishes on what it started with; taken over, it is refused",
         %{ctx: ctx, room: room, holder: holder} do
      script!([{:probe, self()}, reply("On sonnet."), {:probe, self()}, {:probe, self()}])
      edit = &member!(ctx, holder, &1)

      # The loop holds what it built.
      {live, pids} = open_turn!(ctx, room, "first")
      edit.(%{"model" => "claude-opus-5-5"})
      finish!(pids)
      assert {:ok, %{status: "completed"}} = Tape.turn(ctx, live)
      assert answers(ctx, room, live) == ["On sonnet."]
      edit.(%{"model" => "claude-sonnet-5-5"})

      # Taken over after its model moved, which the grant does not hold
      # and the turn's capability digest does: refused as a turn that moved
      # on, and never run on the new model.
      {model, pids} = open_turn!(ctx, room, "second")
      edit.(%{"model" => "claude-opus-5-5"})
      dead = take_over!(pids)

      assert {:ok, %{status: "failed", error: @moved_on}} =
               Tape.turn(ctx, model)

      edit.(%{"model" => "claude-sonnet-5-5"})

      # Taken over after its access moved, an option the turn's capability
      # digest holds as it holds the model: refused as a turn that moved
      # on, and never run with the new access.
      {access, pids} = open_turn!(ctx, room, "third")
      edit.(%{"options_patch" => %{"access" => "another"}})
      gone = take_over!(pids)

      assert {:ok, %{status: "failed", error: @moved_on}} =
               Tape.turn(ctx, access)

      for call <- [dead, gone], do: send(call, :continue)
      assert answers(ctx, room, model) ++ answers(ctx, room, access) == []

      assert List.duplicate("claude-sonnet-5-5", 3) ==
               Enum.map(chats(ctx, "aqua"), & &1.input["params"]["model"])
    end

    # A member's turn keeps the revision of the crew's grant it was claimed
    # under: the person granting Aqua's sheet again while it is open, a
    # rebuilt loop finds the grant moved and is refused, and nothing runs
    # under the newer grant.
    test "a member's job open while the crew's grant is granted again is refused once taken " <>
           "over, never run under the newer grant",
         %{ctx: ctx, room: room, holder: holder} do
      script!([{:probe, self()}])
      {:ok, child} = Threads.crew_thread(actor(ctx), room.id, holder)
      :ok = Aqua.Runner.subscribe(child.id, ctx.athanor_id)
      {:ok, %{turn_id: job}} = Aqua.Runner.send_message(ctx, child.id, "tidy the notes")
      pids = running!(child)
      assert {:ok, %{agent: ^holder, consent_id: claimed}} = Tape.turn(ctx, job)

      consent!(ctx, @soul, [%{dep: @model, label: "default"}])
      assert {:ok, %{consent_id: newer}} = Opus.authority_for(ctx, :default, @soul)
      refute newer == claimed

      dead = take_over!(pids)
      send(dead, :continue)
      assert {:ok, %{status: "failed", error: @moved_on}} = Tape.turn(ctx, job)
      assert answers(ctx, child, job) == []
      assert [%{authority: %{consent_id: ^claimed}}] = chats(ctx, holder)
    end
  end

  # Each way the member can fail to stand, said as the turn refuses it
  # and as Aqua's card says it (`aqua.get`'s `member_refusal`), one
  # sentence (`Prima.Refusal`).
  test "a member that is unnamed, misnamed, gone, disabled or refused refuses Aqua's turn with its card's sentence",
       %{ctx: ctx, room: room, holder: holder} do
    script!([])
    file = Compendium.AquaPath.crew_file(holder)
    {:ok, bytes} = Arca.get(actor(ctx), file)

    cases = [
      {fn -> aqua!(ctx, %{"member" => nil}) end, {:aqua_runs_on, :none, nil}},
      {fn -> aqua!(ctx, %{"member" => "ghost"}) end, {:aqua_runs_on, :missing, "ghost"}},
      {fn ->
         aqua!(ctx, %{"member" => holder})

         {:ok, _} =
           Cyfr.Test.AquaTool.call(ctx, %{
             "action" => "update",
             "name" => holder,
             "disabled" => true
           })

         {:ok, _} = Compendium.AgentIndex.sync(ctx)
       end, {:aqua_runs_on, :disabled, holder}},
      {fn ->
         :ok = Arca.put(actor(ctx), file, bytes <> "\nYou are Claude.\n")
         {:ok, _} = Compendium.AgentIndex.sync(ctx)
       end, {:aqua_runs_on, :refused, holder}},
      # Written by hand in Files, a name no crew member can have: the
      # tool refuses to write one, so only the file can name it.
      {fn ->
         soul_file = Compendium.AquaPath.soul_file()
         {:ok, soul} = Arca.get(actor(ctx), soul_file)
         named = String.replace(soul, "\nmember: #{holder}\n", "\nmember: Claude Code\n")
         refute named == soul
         :ok = Arca.put(actor(ctx), soul_file, named)
         {:ok, _} = Compendium.AgentIndex.sync(ctx)
       end, {:aqua_runs_on, :invalid, "Claude Code"}}
    ]

    for {make, reason} <- cases do
      make.()
      sentence = Prima.Refusal.message(reason)

      assert {:ok, %{"member_refusal" => ^sentence}} =
               Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => "aqua"})

      {:ok, thread} = Arca.Test.Days.thread(actor(ctx))
      turn = accept!(ctx, thread, "are you there?")
      assert {:failed, _} = run(ctx, turn)
      assert {:ok, %{status: "failed", error: ^sentence}} = Tape.turn(ctx, turn.id)
      assert system_lines(ctx, thread) == [sentence]
    end

    assert chats(ctx, "aqua") == []
    _ = room
  end

  # A turn whose consent already stands on Aqua with no member runs as
  # far as its pinned file, which refuses it with the same sentence.
  test "Aqua consented with no member refuses its turn with the sentence, never a missing model",
       %{ctx: ctx, room: room} do
    script!([])
    :ok = aqua!(ctx, %{"member" => nil})
    consent!(ctx, @soul, [])

    turn = accept!(ctx, room, "hello?")
    assert {:failed, {:aqua_runs_on, :none, nil}} = run(ctx, turn)
    sentence = Prima.Refusal.message({:aqua_runs_on, :none, nil})

    assert sentence ==
             "Aqua isn't set up yet — on your Aqua page, connect a brain, make a crew member " <>
               "and choose the one Aqua runs on"

    assert {:ok, %{status: "failed", error: ^sentence}} = Tape.turn(ctx, turn.id)
    assert system_lines(ctx, room) == [sentence]
  end

  # A member whose brain is a program not installed here refuses Aqua's
  # turn in the sentence Aqua's card says, naming the member, whose own
  # card installs it.
  test "Aqua on a member whose program is not installed refuses with that member's sentence",
       %{ctx: ctx, room: room} do
    script!([])
    :ok = aqua!(ctx, %{"member" => "claude-code"})
    consent!(ctx, @soul, [])

    turn = accept!(ctx, room, "hello?")
    reason = {:crew_unready, "Claude Code", :program_missing}
    assert {:failed, ^reason} = run(ctx, turn)
    sentence = Prima.Refusal.message(reason)
    assert {:ok, %{status: "failed", error: ^sentence}} = Tape.turn(ctx, turn.id)
    assert system_lines(ctx, room) == [sentence]
    assert chats(ctx, "aqua") == []
  end

  # No old key is read: Aqua's file naming a brain of its own refuses
  # Aqua, on the page and as the thread's line.
  test "Aqua's file with a brain of its own is refused with the sentence that says what to delete",
       %{ctx: ctx, room: room} do
    script!([])
    file = Compendium.AquaPath.soul_file()
    {:ok, bytes} = Arca.get(actor(ctx), file)
    "---\n" <> rest = bytes

    :ok =
      Arca.put(
        actor(ctx),
        file,
        "---\ncatalyst_ref: #{@model}\nmodel: claude-sonnet-5-5\n" <> rest
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    sentence = Prima.AgentRef.seat_has_brain()

    assert {:error, {:conflict, ^sentence}} =
             Compendium.Providers.Aqua.handle(ctx, %{"action" => "list", "detail" => true})

    turn = accept!(ctx, room, "hello?")
    assert {:failed, :seat_has_brain} = run(ctx, turn)
    assert system_lines(ctx, room) == [sentence]
    assert chats(ctx, "aqua") == []
  end

  # The door names the member Aqua runs on and gives it no brain of its own.
  test "the aqua tool sets Aqua's member and refuses it a brain; a crew member names no member",
       %{ctx: ctx, holder: holder} do
    for {key, value} <- [
          {"catalyst_ref", @model},
          {"program", "claude"},
          {"model", "opus"},
          {"options", %{"effort" => "high"}},
          {"options_patch", %{"effort" => "high"}}
        ] do
      assert {:error, {:invalid_argument, said}} =
               Compendium.Providers.Aqua.handle(ctx, %{
                 "action" => "update",
                 "name" => "aqua",
                 key => value
               })

      assert said =~ "Aqua has no brain of its own", key
    end

    assert {:error, {:invalid_argument, _}} =
             Compendium.Providers.Aqua.handle(ctx, %{
               "action" => "update",
               "name" => holder,
               "member" => "explorer"
             })

    assert {:error, {:invalid_argument, _}} =
             Compendium.Providers.Aqua.handle(ctx, %{
               "action" => "update",
               "name" => "aqua",
               "member" => "aqua"
             })

    :ok = aqua!(ctx, %{"member" => "explorer"})

    assert {:ok, %{"member" => "explorer", "catalyst_ref" => @gemini} = got} =
             Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => "aqua"})

    refute Map.has_key?(got, "member_refusal")

    {:ok, aqua} = Arca.get(actor(ctx), Compendium.AquaPath.soul_file())
    assert aqua =~ "\nmember: explorer\n"
    refute aqua =~ "catalyst_ref"
  end
end
