# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.ReadOnlyBrainTest do
  @moduledoc """
  A read-only crew member whose brain runs a program CYFR cannot keep
  read-only, through the real loop: a catalyst whose manifest declares a
  `login` need (the shipped `openai-codex` catalyst),
  or a program row whose driver is `cyfr-codex`, the shipped OpenAI
  Codex member's own among them. Its turn ends unrun
  before anything runs: the sentence that says to switch it to auto is a
  line in its thread and the turn's error, no model is asked, no step is
  written, no session opens and the root starts no child. The same member
  in auto runs, so only the mode refuses it; a read-only member on a
  key-only catalyst runs, and one on a `cyfr-claude-code` row passes the
  check and reaches the program's holder, which starts it read-only.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @api "catalyst:local.claude"
  @openai_codex "catalyst:local.openai-codex"
  @root :crypto.strong_rand_bytes(32)
  @session "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    # The athanor is its person's own, minted for the test, its tree under
    # the partition's storage root and removed when the test ends.
    ctx = person!()
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

    # The shipped brains: a key-only catalyst, and the harness that signs
    # in to a program of its own.
    Cyfr.Test.SeedBundle.lay!(~w(claude files http openai-codex))
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Bootstrap.run(ctx)
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @api, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@api, @openai_codex])

    {:ok, room} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, room: room}
  end

  describe "a crew member" do
    test "read-only on a catalyst that signs in to a program of its own ends unrun with " <>
           "the line and dispatches nothing; in auto it runs",
         %{ctx: ctx, room: room} do
      member!(ctx, "coder", "Coder", @openai_codex, "default")
      signed_in!(ctx, "coder", @openai_codex, "openai-codex")
      mode!(ctx, "coder", "read-only")
      script!([reply("built")])

      {thread, turn} = accept!(ctx, room, "coder", "build the page")

      assert Aqua.Loop.run(ctx: ctx, turn_id: turn.id) ==
               {:failed, {:read_only_unheld, "Coder", "openai-codex"}}

      line =
        "Coder can't run read-only: its brain, openai-codex, runs a program CYFR can't keep " <>
          "read-only, so nothing ran. Switch Coder to auto on the Aqua page to use it."

      assert Aqua.Models.unheld_sentence("Coder", "openai-codex") == line
      refused!(ctx, thread, turn, "build the page", line)

      # The same member, switched to auto, runs on the same brain.
      mode!(ctx, "coder", "auto")
      again = accept_in!(ctx, thread, "coder", "build the page")
      assert Aqua.Loop.run(ctx: ctx, turn_id: again.id) == :completed
      ran!(ctx, thread, again, "auto", @openai_codex, "build the page", "built")
    end

    test "read-only on a catalyst that runs no program of its own runs",
         %{ctx: ctx, room: room} do
      member!(ctx, "reader", "Reader", @api, "claude-sonnet-5-5")
      keyed!(ctx, "reader")
      mode!(ctx, "reader", "read-only")
      script!([reply("three notes")])

      {thread, turn} = accept!(ctx, room, "reader", "what is in notes?")
      assert Aqua.Loop.run(ctx: ctx, turn_id: turn.id) == :completed
      ran!(ctx, thread, turn, "read-only", @api, "what is in notes?", "three notes")
    end
  end

  # Both shipped harness members name a program row: Claude Code's driver
  # holds a read-only start ("the soul on a program row"), and Codex's
  # cannot, so the shipped OpenAI Codex member is refused before its row's
  # session opens. A made member's refusal on a catalyst that signs in is
  # above.
  describe "the shipped OpenAI Codex member" do
    setup do
      fake = Scripted.start(self(), @root)
      _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
      assert_receive {:control, "reconcile", _message, _fields}, 2_000
      script!([])
      {:ok, fake: fake}
    end

    test "switched to read-only, is refused with its own title and its program's name before " <>
           "a session opens; in auto the holder starts it on its shipped model",
         %{ctx: ctx, room: room, fake: fake} do
      {:ok, codex} = Compendium.AquaAgent.get(ctx, "openai-codex")
      assert {codex.program, codex.model} == {"openai-codex", "gpt-6.1-sol"}
      row = program_row!(ctx, codex.program, codex.install)
      mode!(ctx, "openai-codex", "read-only")

      {thread, turn} = accept!(ctx, room, "openai-codex", "fix the build")

      assert Aqua.Loop.run(ctx: ctx, turn_id: turn.id) ==
               {:failed, {:read_only_unheld, "OpenAI Codex", "openai-codex"}}

      line = Aqua.Models.unheld_sentence("OpenAI Codex", "openai-codex")
      refused!(ctx, thread, turn, "fix the build", line)
      refute_received {:session, _type, _message, _fields}
      assert Scripted.sessions(fake, row.id) == %{}

      # The same member in auto passes the check: the holder starts a new
      # native session on its shipped model, with the turn's tools, which
      # Codex takes at its thread's start alone.
      mode!(ctx, "openai-codex", "auto")
      again = accept_in!(ctx, thread, "openai-codex", "fix the build")
      loop = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: again.id) end)
      {start, work} = played!(fake, row, again)
      assert work["tools"] != []

      assert Map.delete(start, "system") == %{
               "t" => "start",
               "gen" => 0,
               "config" => %{"model" => "gpt-6.1-sol", "read_only" => false},
               "tools" => work["tools"]
             }

      assert Task.await(loop, 30_000) == :completed
      started!(ctx, thread, again, "auto", row)
    end
  end

  describe "the soul on a program row" do
    setup %{ctx: ctx} do
      fake = Scripted.start(self(), @root)
      _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
      assert_receive {:control, "reconcile", _message, _fields}, 2_000
      # The soul's own catalyst is scripted too, so a model asked shows.
      script!([])
      mode!(ctx, "aqua", "read-only")
      {:ok, fake: fake}
    end

    test "read-only on a cyfr-codex row is refused before the start and starts nothing; " <>
           "in auto it starts",
         %{ctx: ctx, room: room, fake: fake} do
      row = program_row!(ctx, "codex", "cyfr-codex npx -y @openai/codex@0.167.0")
      turn = accept_on!(ctx, room, row, "what is in notes.md?")

      assert Aqua.Loop.run(ctx: ctx, turn_id: turn.id) ==
               {:failed, {:read_only_unheld, "Aqua", "codex"}}

      line = Aqua.Models.unheld_sentence("Aqua", "codex")
      refused!(ctx, room, turn, "what is in notes.md?", line, program: row.id)
      refute_received {:session, _type, _message, _fields}
      assert Scripted.sessions(fake, row.id) == %{}

      # The same soul in auto passes the check: the holder starts it.
      mode!(ctx, "aqua", "auto")
      again = accept_on!(ctx, room, row, "what is in notes.md?")
      loop = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: again.id) end)
      {played, work} = played!(fake, row, again)
      assert Map.delete(played, "system") == start(ctx, false, work)
      assert Task.await(loop, 30_000) == :completed
      started!(ctx, room, again, "auto", row)
    end

    test "read-only on a row naming cyfr-codex by its installed path is refused before a session opens",
         %{ctx: ctx, room: room, fake: fake} do
      row =
        program_row!(ctx, "codex-path", "/usr/local/bin/cyfr-codex npx -y @openai/codex@0.167.0")

      turn = accept_on!(ctx, room, row, "what is in notes.md?")
      task = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
      answer = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
      assert Scripted.sessions(fake, row.id) == %{}
      assert answer == {:ok, {:failed, {:read_only_unheld, "Aqua", "codex-path"}}}
    end

    test "read-only on a cyfr-claude-code row passes the check, and the holder starts it " <>
           "read-only",
         %{ctx: ctx, room: room, fake: fake} do
      row = program_row!(ctx, "claude-code", "cyfr-claude-code npx -y @anthropic-ai/claude-code")
      turn = accept_on!(ctx, room, row, "what is in notes.md?")
      loop = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
      {played, work} = played!(fake, row, turn)
      assert Map.delete(played, "system") == start(ctx, true, work)
      assert Task.await(loop, 30_000) == :completed
      started!(ctx, room, turn, "read-only", row)
    end
  end

  # ---------------------------------------------------------------------------
  # The athanor

  # A person minted for the test with their own athanor, signed in
  # through Prism.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, person} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|read-only#{n}",
        provider: "github",
        email: "read-only#{n}@example.com",
        verified: true,
        name: "Read Only"
      })

    %{
      Sanctum.TestContext.local(:prism)
      | user_id: person.id,
        athanor_id: Sanctum.Test.People.athanor!(person).id
    }
  end

  # The athanor's tree under the partition's storage root, which no earlier
  # test may have left behind.
  defp own_tree!(ctx) do
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"
    tree
  end

  # ---------------------------------------------------------------------------
  # The crew

  # A crew member the person makes on the Aqua page, in auto.
  defp member!(ctx, name, title, catalyst, model) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => name,
        "title" => title,
        "catalyst_ref" => catalyst,
        "model" => model,
        "content" => "# #{title}"
      })
  end

  # The member's mode switched on the Aqua page.
  defp mode!(ctx, name, mode) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => name, "mode" => mode})
  end

  # The member's brain on the key the catalyst's own profile binds,
  # selected as a person's consent selects it.
  defp keyed!(ctx, name),
    do: commit!(ctx, Prima.AgentRef.ref(name), %{selections: [%{dep: @api, label: "default"}]})

  # The member's brain signed in to a program row of its own, the one its
  # login need names (the need is named for its program): bound on the
  # catalyst's consent and on the member's edge into it.
  defp signed_in!(ctx, name, catalyst, program) do
    row = program_row!(ctx, program, "npx -y #{program}")
    commit!(ctx, catalyst, %{bindings: [%{need: program, entry_id: row.id}]})

    commit!(ctx, Prima.AgentRef.ref(name), %{
      selections: [%{dep: catalyst, need: program, entry_id: row.id}]
    })
  end

  defp commit!(ctx, ref, over) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, over)
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  # A driven program row with a kept folder, as the Programs page sets one up.
  defp program_row!(ctx, name, command) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json: Jason.encode!(%{"command" => command, "env" => %{}})
      })

    row
  end

  # ---------------------------------------------------------------------------
  # Turns

  # The person's post to `member` in its own thread off the room.
  defp accept!(ctx, room, member, text) do
    {:ok, thread} = Threads.crew_thread(Sanctum.Context.actor(ctx), room.id, member)
    {thread, accept_in!(ctx, thread, member, text)}
  end

  defp accept_in!(ctx, thread, member, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: member, requested_by: ctx.user_id}
      })

    turn
  end

  # A turn of the soul on `row`'s brain: the person's post, and the program
  # row pinned before the loop builds it (`Aqua.Loop.Turn`).
  defp accept_on!(ctx, room, row, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, room.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, turn} =
      TurnStorage.pin_program(Sanctum.Context.actor(ctx), turn.id, row.id, %{fence: turn.fence})

    turn
  end

  defp script!(items),
    do: start_supervised!({ScriptedWorker, ref: [@api, @openai_codex], script: items})

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  # ---------------------------------------------------------------------------
  # What a turn left

  # The turn ended unrun on `line`: its row failed with it, read-only and
  # pinned to no brain it did not already name; the thread holds the
  # person's post and the line; no step was written, no model asked and
  # the root started no child.
  defp refused!(ctx, thread, turn, post, line, pinned \\ []) do
    {:ok, ended} = Tape.turn(ctx, turn.id)

    assert row(ended) == %{
             agent: turn.agent,
             thread_id: thread.id,
             message_id: turn.message_id,
             status: "failed",
             error: line,
             agent_mode: "read-only",
             catalyst_ref: nil,
             program: Keyword.get(pinned, :program),
             paused_reason: nil,
             launch_step_id: nil
           }

    assert lines(ctx, thread, turn) == [
             {ctx.user_id, "person", "text", post},
             {Prima.Author.system(), turn.agent, "system", line}
           ]

    assert Tape.steps(ctx, ended) == {:ok, []}
    assert ScriptedWorker.calls() == []
    assert root_status(ended) == "failed"
    assert children(ended) == []
  end

  # The turn ran on `catalyst` and completed with the model's `text`, its
  # one step the model's.
  defp ran!(ctx, thread, turn, mode, catalyst, post, text) do
    {:ok, ended} = Tape.turn(ctx, turn.id)

    assert %{row(ended) | catalyst_ref: name_of(ended.catalyst_ref)} == %{
             agent: turn.agent,
             thread_id: thread.id,
             message_id: turn.message_id,
             status: "completed",
             error: nil,
             agent_mode: mode,
             catalyst_ref: catalyst,
             program: nil,
             paused_reason: nil,
             launch_step_id: nil
           }

    assert lines(ctx, thread, turn) == [
             {ctx.user_id, "person", "text", post},
             {Prima.Author.agent(), turn.agent, "text", text}
           ]

    assert {:ok, [%{kind: "model", dispatch_state: "closed", outcome: "ok"}]} =
             Tape.steps(ctx, ended)

    assert Enum.any?(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))
  end

  # The turn on `row` completed on its program, with no line written and
  # no model asked.
  defp started!(ctx, thread, turn, mode, row) do
    {:ok, ended} = Tape.turn(ctx, turn.id)

    assert row(ended) == %{
             agent: turn.agent,
             thread_id: thread.id,
             message_id: turn.message_id,
             status: "completed",
             error: nil,
             agent_mode: mode,
             catalyst_ref: nil,
             program: row.id,
             paused_reason: nil,
             launch_step_id: nil
           }

    assert system_lines(ctx, thread, turn) == []
    assert ScriptedWorker.calls() == []
  end

  # The start the holder writes for the soul: its model, the mode the
  # turn's row stored as `read_only`, and, since it opens a new native
  # session, the work's tools.
  defp start(ctx, read_only?, work) do
    {:ok, soul} = Compendium.AquaAgent.get(ctx, "aqua")

    %{
      "t" => "start",
      "gen" => 0,
      "config" => %{"model" => soul.model, "read_only" => read_only?},
      "tools" => work["tools"]
    }
  end

  defp row(turn),
    do:
      Map.take(turn, [
        :agent,
        :thread_id,
        :message_id,
        :status,
        :error,
        :agent_mode,
        :catalyst_ref,
        :program,
        :paused_reason,
        :launch_step_id
      ])

  defp name_of(ref) do
    {:ok, name} = Prima.ComponentRef.to_name_ref(ref)
    name
  end

  # The thread's rows of `turn` as a person reads them.
  defp lines(ctx, thread, turn) do
    for m <- Threads.messages(Sanctum.Context.actor(ctx), thread.id),
        m.turn_id == turn.id or m.id == turn.message_id,
        do: {m.author, m.sent_by, m.kind, m.content}
  end

  defp system_lines(ctx, thread, turn),
    do: for({_, _, "system", content} <- lines(ctx, thread, turn), do: content)

  defp root_status(%{root_execution_id: root}),
    do: Arca.Repo.one!(from(e in "executions", where: e.id == ^root, select: e.status))

  defp children(%{root_execution_id: root}),
    do:
      Arca.Repo.all(from(e in "executions", where: e.parent_execution_id == ^root, select: e.id))

  # ---------------------------------------------------------------------------
  # The program's driver, as `Aqua.ProgramTest` plays it

  defp say(fake, row, event), do: Scripted.write(fake, row.id, Jason.encode!(event))

  # The next command the holder wrote to the driver.
  defp sent(timeout \\ 10_000) do
    assert_receive {:session, "send", %{"lines" => [line]}, _fields}, timeout
    Jason.decode!(line)
  end

  # The driver's session opens for `row` and says hello once it stands;
  # the holder's start is taken, then the turn's work and its post, and
  # the idle that answers the post ends the turn. Answers the start and
  # the work as the holder wrote them.
  defp played!(fake, row, turn) do
    assert_receive {:session, "open", %{"mode" => "run", "home_id" => home}, _fields}, 10_000
    assert home == row.id

    Prima.Test.Wait.wait_until(
      fn -> Enum.any?(Scripted.sessions(fake, row.id), fn {_id, s} -> s.running end) end,
      10_000,
      "the driver's session to stand"
    )

    say(fake, row, %{
      "t" => "hello",
      "v" => Opus.Brain.Wire.version(),
      "driver" => Arca.McpServerStorage.driver(row),
      "boot" => "boot-one"
    })

    start = sent()
    assert %{"t" => "start"} = start
    say(fake, row, %{"t" => "started", "session" => @session, "fresh" => true, "held" => []})
    assert %{"t" => "work", "id" => id} = work = sent()
    say(fake, row, %{"t" => "accepted", "id" => id})
    assert %{"t" => "post", "id" => input} = sent()
    say(fake, row, %{"t" => "accepted", "id" => input})

    say(fake, row, %{
      "t" => "idle",
      "gen" => 0,
      "work" => turn.id,
      "answered" => [input],
      "stop" => "end_turn"
    })

    {start, work}
  end
end
