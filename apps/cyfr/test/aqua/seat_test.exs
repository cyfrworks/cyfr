# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SeatTest do
  @moduledoc """
  Aqua as a seat, through the real loop and a scripted model: Aqua runs on
  the crew member its file names, with that member's brain, model and
  mode and its own prompt and tools, its prompt in two parts (its file's,
  then CYFR's) with the job apart from both; a turn pins Aqua's file, so a
  member chosen while a turn is open does not retarget it, recovery
  included, and the next turn runs on the new one once its consent is
  given, which choosing does not give; a member that does not stand
  refuses Aqua's turn with the sentence Aqua's card says; a file that
  names a brain of its own is refused; and the member Aqua runs on is
  still a worker under its own name, briefed as one, which asks nobody.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @gemini "catalyst:local.gemini"
  @context "\n\n---\n\n## Runtime Context\n\n"
  # A rebuilt turn whose consent's shape moved since its root was claimed.
  @consent_moved "Consent required: agent:local.aqua asks for more than its grant holds — " <>
                   "review and grant again"

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

  defp chats(name) do
    Enum.filter(
      ScriptedWorker.calls(),
      &(&1.input["operation"] == "chat" and hd(&1.authority.chain) == Prima.AgentRef.ref(name))
    )
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

    assert [%{input: %{"params" => params}}] = chats("aqua")
    assert chats(holder) == []
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
    assert %{agent: "aqua", agent_mode: "auto"} = pinned
    assert String.starts_with?(pinned.catalyst_ref, @model <> ":")
  end

  # The member Aqua runs on is a worker too, under its own name, in its
  # own thread: a crew member's opening and CYFR's part, never Aqua's
  # prompt, and its own turn asks nobody.
  test "the member Aqua runs on works a job as itself, briefed as a member, and asks nobody",
       %{ctx: ctx, room: room, holder: holder} do
    consent!(ctx, Prima.AgentRef.ref(holder), [%{dep: @model, label: "default"}])

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

    assert [%{input: %{"params" => %{"system" => system}}}] = chats(holder)
    assert chats("aqua") == []
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

  # CYFR's part is one text for both modes: a read-only member is offered
  # a write and refused it, and the request that offered it says what
  # read-only runs, never that every tool it holds runs as it is called.
  test "a read-only worker is not told that its offered writes run",
       %{ctx: ctx, room: room, holder: holder} do
    member!(ctx, holder, %{"mode" => "read-only"})
    consent!(ctx, Prima.AgentRef.ref(holder), [%{dep: @model, label: "default"}])

    script!([
      %{
        "content" => [
          %{
            "type" => "tool_call",
            "id" => "write",
            "name" => "files",
            "arguments" => %{"action" => "delete", "path" => "data/review-missing"}
          }
        ],
        "stop_reason" => "tool_call",
        "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
      },
      reply("Read only.")
    ])

    {:ok, child} = Threads.crew_thread(actor(ctx), room.id, holder)
    turn = accept!(ctx, child, "inspect only", holder)
    assert :completed = run(ctx, turn)
    assert {:ok, %{agent_mode: "read-only"}} = Tape.turn(ctx, turn.id)
    assert [%{input: %{"params" => params}}, %{input: %{"params" => followup}}] = chats(holder)
    assert Enum.any?(params["tools"], &(&1["name"] == "files"))

    assert %{
             "type" => "tool_result",
             "tool_call_id" => "write",
             "name" => "files",
             "content" => Aqua.Loop.Policy.read_only_sentence(holder),
             "is_error" => true
           } in Enum.flat_map(followup["messages"], & &1["content"])

    system = params["system"]
    assert system =~ "In read-only only reads run, and any other call comes back with a sentence"
    refute system =~ "- Every tool you hold runs as you call it"
    refute system =~ "build one by hand. A component the person granted runs"
    refute system =~ "for that one act: nothing but this instruction stops you"
  end

  # A brain picked for the member Aqua runs on asks Aqua's consent on the
  # page (`PrismWeb.AquaLive.AgentsComponent`), never the member's own:
  # that stays on the brain it was given for, so a job of the member's own
  # is refused until the person gives it again, and none of it reaches the
  # new brain before then.
  test "the member Aqua runs on, its brain moved and Aqua consented again, runs no job of its " <>
         "own on the new brain before its own consent",
       %{ctx: ctx, room: room, holder: holder} do
    member_ref = Prima.AgentRef.ref(holder)
    consent!(ctx, member_ref, [%{dep: @model, label: "default"}])

    start_supervised!(
      {ScriptedWorker, ref: [@model, @gemini], script: [reply("Aqua."), reply("The member.")]}
    )

    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @gemini, %{"GEMINI_API_KEY" => "g-test"})
    :ok = member!(ctx, holder, %{"catalyst_ref" => @gemini, "model" => "gemini-pro-latest"})
    consent!(ctx, @soul, [%{dep: @gemini, label: "default"}])

    aqua = accept!(ctx, room, "hello")
    assert :completed = run(ctx, aqua)

    # The member's own job: its consent still holds the old brain only.
    assert {:error, {:consent_required, _}} = Opus.authority_for(ctx, :default, member_ref)
    {:ok, child} = Threads.crew_thread(actor(ctx), room.id, holder)
    refused = accept!(ctx, child, "tidy the notes", holder)
    assert {:failed, _} = run(ctx, refused)
    assert chats(holder) == []

    # Given, the member's next job runs on its new brain.
    consent!(ctx, member_ref, [%{dep: @gemini, label: "default"}])
    done = accept!(ctx, child, "tidy the notes again", holder)
    assert :completed = run(ctx, done)

    assert ["gemini-pro-latest"] = Enum.map(chats(holder), & &1.input["params"]["model"])
    assert ["gemini-pro-latest"] = Enum.map(chats("aqua"), & &1.input["params"]["model"])
  end

  # A turn pins Aqua's file, which names its member: rebuilt as recovery
  # rebuilds it, it runs on the member it started on. Choosing another
  # gives no consent: the next turn waits for the person's, then runs on
  # the new member's brain.
  test "a member chosen during a turn does not retarget it; the next turn runs on the new one once consented",
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
    assert {spec.model, spec.mode} == {"claude-sonnet-5-5", "auto"}

    # The next turn is the new member's: its brain, model and mode.
    {:ok, next} = Compendium.agent_snapshot(ctx, "aqua")

    assert %{
             member: "explorer",
             catalyst_ref: @gemini,
             model: "gemini-pro-latest",
             holder: %{name: "explorer", state: :held}
           } = next.agent

    # Choosing minted nothing: Aqua's consent is the person's to give again.
    assert {:error, {:consent_required, _}} = Opus.authority_for(ctx, :default, @soul)
    refused = accept!(ctx, room, "second")
    assert {:failed, _} = run(ctx, refused)
    assert [_first] = chats("aqua")

    # Given, the next turn runs on the new member's brain and model.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @gemini, %{"GEMINI_API_KEY" => "g-test"})
    consent!(ctx, @soul, [%{dep: @gemini, label: "default"}])
    assert {:ok, _} = Opus.authority_for(ctx, :default, @soul)
    third = accept!(ctx, room, "third")
    assert :completed = run(ctx, third)

    assert ["claude-sonnet-5-5", "gemini-pro-latest"] =
             Enum.map(chats("aqua"), & &1.input["params"]["model"])

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
        {:probe, self()}
      ])

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "twin",
          "title" => "Twin",
          "catalyst_ref" => @model,
          "model" => "claude-sonnet-5-5",
          "mode" => "read-only"
        })

      # The loop holds what it built: another member chosen mid-call, it
      # finishes on its own.
      {live, pids} = open_turn!(ctx, room, "first")
      :ok = aqua!(ctx, %{"member" => "explorer"})
      finish!(pids)
      assert {:ok, %{status: "completed", agent_mode: "auto"}} = Tape.turn(ctx, live)
      assert answers(ctx, room, live) == ["On claude."]
      :ok = aqua!(ctx, %{"member" => holder})

      # A member on the same brain in another mode, chosen mid-call: taken
      # over, the turn runs on the member its pin names, in its mode.
      {same, pids} = open_turn!(ctx, room, "second")
      :ok = aqua!(ctx, %{"member" => "twin"})
      dead = take_over!(pids)

      assert {:ok, %{status: "completed", recovery_attempts: 1, agent_mode: "auto"}} =
               Tape.turn(ctx, same)

      assert answers(ctx, room, same) == ["Taken over."]
      :ok = aqua!(ctx, %{"member" => holder})

      # A member on another brain, chosen mid-call: taken over, the turn is
      # refused, its consent's shape moved, and nothing reaches that brain.
      {other, pids} = open_turn!(ctx, room, "third")
      :ok = aqua!(ctx, %{"member" => "explorer"})
      gone = take_over!(pids)

      assert {:ok, %{status: "failed", error: @consent_moved}} = Tape.turn(ctx, other)
      assert answers(ctx, room, other) == []

      for call <- [dead, gone], do: send(call, :continue)

      # The first turn's call, the second's held and taken-over ones, and
      # the third's held one: each on the member the pin names.
      assert List.duplicate("claude-sonnet-5-5", 4) ==
               Enum.map(chats("aqua"), & &1.input["params"]["model"])

      # The file names the new member; its consent is the person's to give.
      assert {:ok, %{agent: %{holder: %{name: "explorer", state: :held}}}} =
               Compendium.agent_snapshot(ctx, "aqua")

      assert {:error, {:consent_required, _}} = Opus.authority_for(ctx, :default, @soul)
    end

    test "a member whose brain moves while the turn is open never runs it on the new brain: " <>
           "the loop finishes on the brain it started with; taken over, it is refused",
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

      # Taken over after its model moved: its consent's shape moved, and
      # it is refused with the sentence that says so.
      {model, pids} = open_turn!(ctx, room, "second")
      edit.(%{"model" => "claude-opus-5-5"})
      dead = take_over!(pids)
      assert {:ok, %{status: "failed", error: @consent_moved}} = Tape.turn(ctx, model)
      edit.(%{"model" => "claude-sonnet-5-5"})

      # Taken over after its mode moved, which the consent does not hold
      # and the turn's capability digest does: refused as a turn that
      # moved on.
      {mode, pids} = open_turn!(ctx, room, "third")
      edit.(%{"mode" => "read-only"})
      gone = take_over!(pids)

      assert {:ok,
              %{status: "failed", error: "The turn moved on — read the thread again and retry"}} =
               Tape.turn(ctx, mode)

      for call <- [dead, gone], do: send(call, :continue)
      assert answers(ctx, room, model) ++ answers(ctx, room, mode) == []

      assert List.duplicate("claude-sonnet-5-5", 3) ==
               Enum.map(chats("aqua"), & &1.input["params"]["model"])
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

    assert chats("aqua") == []
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
             "Aqua runs on no crew member yet — choose one on Aqua's card on the Aqua page"

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
    assert chats("aqua") == []
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
    assert chats("aqua") == []
  end

  # The door names the member Aqua runs on and gives it no brain of its own.
  test "the aqua tool sets Aqua's member and refuses it a brain; a crew member names no member",
       %{ctx: ctx, holder: holder} do
    for {key, value} <- [
          {"catalyst_ref", @model},
          {"program", "claude"},
          {"install", "cyfr-claude-code claude"},
          {"model", "opus"},
          {"options", %{"effort" => "high"}},
          {"options_patch", %{"effort" => "high"}},
          {"mode", "read-only"}
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

    assert {:ok, %{"member" => "explorer", "catalyst_ref" => @gemini, "mode" => "auto"} = got} =
             Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => "aqua"})

    refute Map.has_key?(got, "member_refusal")

    {:ok, aqua} = Arca.get(actor(ctx), Compendium.AquaPath.soul_file())
    assert aqua =~ "\nmember: explorer\n"
    refute aqua =~ "catalyst_ref"
  end
end
