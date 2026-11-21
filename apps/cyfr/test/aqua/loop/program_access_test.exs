# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.ProgramAccessTest do
  @moduledoc """
  A crew member's access, through the real loop. On a program brain it is
  one of the member's options, written as the Aqua page's setup writes
  it, and reaches the program's start unchanged, beside the member's
  model: the driver, not CYFR, decides what it means. A member on an API
  brain has no access to choose: one its options set anyway is refused
  before any model is asked, as an option the brain does not declare is.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @api "catalyst:local.claude"
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

    # The shipped brains, a key-only catalyst among them.
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Bootstrap.run(ctx)
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @api, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@api])

    {:ok, room} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, room: room}
  end

  describe "a crew member on an API brain" do
    test "whose options set an access is refused before any model is asked",
         %{ctx: ctx, room: room} do
      member!(ctx, "writer", "Writer", @api, "claude-sonnet-5-5")
      options!(ctx, "writer", %{"access" => "default"})
      script!([reply("never sent")])

      {thread, turn} = accept!(ctx, room, "writer", "what is in notes?")
      sentence = "the brain does not take options.access as it was set"
      assert Aqua.Loop.run(ctx: ctx, turn_id: turn.id) == {:failed, sentence}

      {:ok, ended} = Tape.turn(ctx, turn.id)
      assert %{status: "failed", error: ^sentence} = ended
      assert Tape.steps(ctx, ended) == {:ok, []}
      refute Enum.any?(ScriptedWorker.calls(), &(&1.input["operation"] == "chat"))
      assert lines(ctx, thread, turn) == [{ctx.user_id, "person", "text", "what is in notes?"}]
    end
  end

  describe "an OpenAI Codex member" do
    setup do
      fake = backends!()
      script!([])
      {:ok, fake: fake}
    end

    test "made with its access, as the setup makes it, starts its program with that access " <>
           "unchanged beside its model",
         %{ctx: ctx, room: room, fake: fake} do
      # Made as the setup's Make writes it on the connected program: the
      # model, the effort and the access picked from the program's own
      # listing. A crew member holds no grant of its own.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "openai-codex",
          "title" => "OpenAI Codex",
          "program" => "openai-codex",
          "model" => "gpt-6.1-sol",
          "options" => %{"effort" => "high", "access" => "full-access"}
        })

      {:ok, %{options: stored}} = Compendium.AquaAgent.get(ctx, "openai-codex")
      assert stored == %{"effort" => "high", "access" => "full-access"}

      row =
        program_row!(ctx, "openai-codex", Opus.Programs.Definition.brain("openai-codex").command)

      {thread, turn} = accept!(ctx, room, "openai-codex", "fix the build")
      loop = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
      {start, work} = played!(fake, row, turn)

      assert Map.delete(start, "system") == %{
               "t" => "start",
               "gen" => 0,
               "config" => %{
                 "model" => "gpt-6.1-sol",
                 "effort" => "high",
                 "access" => "full-access"
               },
               "tools" => work["tools"]
             }

      assert Task.await(loop, 30_000) == :completed
      started!(ctx, thread, turn, row)
    end
  end

  # Aqua hands a job to a crew member with `crew.ask`. The member's access
  # is the person's to set on its card: a job's options cannot name it,
  # and the job's other options merge over the member's own.
  describe "Aqua's hand-off to an OpenAI Codex member" do
    setup do
      {:ok, fake: backends!()}
    end

    test "naming an access is refused and queues nothing; with an effort it runs with that " <>
           "effort and the member's saved access",
         %{ctx: ctx, room: room, fake: fake} do
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "openai-codex",
          "title" => "OpenAI Codex",
          "program" => "openai-codex",
          "model" => "gpt-6.1-sol",
          "options" => %{"effort" => "high", "access" => "full-access"}
        })

      row =
        program_row!(ctx, "openai-codex", Opus.Programs.Definition.brain("openai-codex").command)

      ask = %{"action" => "ask", "member" => "openai-codex", "task" => "fix the build"}

      script!([
        call("a1", "crew", Map.put(ask, "options", %{"access" => "full-access"})),
        call("a2", "crew", Map.put(ask, "options", %{"effort" => "low"})),
        reply("Asked.")
      ])

      aqua = accept_in!(ctx, room, "aqua", "fix the build")
      assert Aqua.Loop.run(ctx: ctx, turn_id: aqua.id) == :completed

      # The first hand-off is refused with where access is set.
      sentence =
        "crew.ask's options cannot name access: a crew member's access is set by the " <>
          "person, on the member's card on the Aqua page"

      [_first, second, _third] = chat_messages()

      assert [%{"is_error" => true, "content" => refused}] =
               for(
                 %{"content" => content} <- second,
                 %{"type" => "tool_result", "tool_call_id" => "a1"} = result <- List.wrap(content),
                 do: result
               )

      assert refused =~ sentence

      # Only the second is queued, with its own options.
      assert [%{id: request_id, addressee: "openai-codex"}] = Tape.pending_requests(ctx, room.id)

      {:ok, [record]} =
        Arca.Outbox.pending(Sanctum.Context.actor(ctx), "crew_delivery", "crew_request")

      assert record.snapshot["options"] == %{"effort" => "low"}

      # Delivered, the member's program starts with the job's effort and
      # the member's saved access.
      assert {:ok, %{"applied" => 1}} = Aqua.Crew.drain(ctx.athanor_id)
      [child] = Threads.children(Sanctum.Context.actor(ctx), room.id)

      turn_id =
        Enum.find_value(
          Threads.messages(Sanctum.Context.actor(ctx), child.id),
          &(Tape.payload(&1)["request_id"] == request_id && &1.turn_id)
        )

      {:ok, turn} = Tape.turn(ctx, turn_id)
      {start, _work} = played!(fake, row, turn)

      assert start["config"] == %{
               "model" => "gpt-6.1-sol",
               "effort" => "low",
               "access" => "full-access"
             }
    end
  end

  defp person! do
    n = System.unique_integer([:positive])

    {:ok, person} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|access#{n}",
        provider: "github",
        email: "access#{n}@example.com",
        verified: true,
        name: "Access"
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

  # A crew member the person makes on the Aqua page.
  defp member!(ctx, name, title, catalyst, model) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => name,
        "title" => title,
        "catalyst_ref" => catalyst,
        "model" => model
      })
  end

  # The member's options patched as the Aqua page's card writes one.
  defp options!(ctx, name, patch) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => name,
        "options_patch" => patch
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

  defp script!(items),
    do: start_supervised!({ScriptedWorker, ref: [@api], script: items})

  defp call(id, name, args),
    do: %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }

  # The messages of each chat request the model was sent, in order.
  defp chat_messages do
    for %{input: %{"operation" => "chat", "params" => %{"messages" => messages}}} <-
          ScriptedWorker.calls(),
        do: messages
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  # ---------------------------------------------------------------------------
  # What a turn left

  # The turn on `row` completed on its program, with no line written and
  # no model asked.
  defp started!(ctx, thread, turn, row) do
    {:ok, ended} = Tape.turn(ctx, turn.id)

    assert row(ended) == %{
             agent: turn.agent,
             thread_id: thread.id,
             message_id: turn.message_id,
             status: "completed",
             error: nil,
             catalyst_ref: nil,
             program: row.id,
             paused_reason: nil,
             launch_step_id: nil
           }

    assert system_lines(ctx, thread, turn) == []
    assert ScriptedWorker.calls() == []
  end

  defp row(turn),
    do:
      Map.take(turn, [
        :agent,
        :thread_id,
        :message_id,
        :status,
        :error,
        :catalyst_ref,
        :program,
        :paused_reason,
        :launch_step_id
      ])

  # The thread's rows of `turn` as a person reads them.
  defp lines(ctx, thread, turn) do
    for m <- Threads.messages(Sanctum.Context.actor(ctx), thread.id),
        m.turn_id == turn.id or m.id == turn.message_id,
        do: {m.author, m.sent_by, m.kind, m.content}
  end

  defp system_lines(ctx, thread, turn),
    do: for({_, _, "system", content} <- lines(ctx, thread, turn), do: content)

  # ---------------------------------------------------------------------------
  # The program's driver, as `Aqua.ProgramTest` plays it

  # The programs controller on a scripted backends service, which plays the
  # program's driver.
  defp backends! do
    fake = Scripted.start(self(), @root)
    _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000
    fake
  end

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
