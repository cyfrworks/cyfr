# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ModelContractTest do
  @moduledoc """
  The `model/chat@1` contract at the platform: whatever a model catalyst
  emits and answers within the contract, Opus carries, Host masks and
  numbers, and Aqua turns into a correct turn.

  The catalyst is the chat fixture (`test_wasm/chat_fixture/`), which plays
  the script the person's message carries, run by the Opus service over
  the wire as the soul's model. Every case is a turn a person sends
  (`Aqua.Runner.send_message/4`) on an estate filled from a seed
  (`Sanctum.Provisioning.provision/2`), and is read where a person or
  another node could read it: the thread's topic, the executions topic and
  each execution's event stream (`Cyfr.Test.ChatFixture.observe!/2`), the
  rows, the retained payloads and the log. Nothing here attaches to the
  engine or reads a process of it.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.ChatFixture
  import Cyfr.Test.Wait
  import ExUnit.CaptureLog

  alias Aqua.{Approvals, Runner, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ChatFixture, as: Fixture
  alias Sanctum.Consent.Source

  @moduletag timeout: 180_000

  @canary "sk-canary-7f3a9c51e8b24d06"
  @redacted "[REDACTED]"
  @turn_ms 90_000
  @emit_budget 3000
  @settle_ms 10_000

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    run_dir = Path.join(System.tmp_dir!(), "model_contract_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :registry_url]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    seed = Fixture.lay_seed!(Path.join(run_dir, "seed"), limits: Map.get(tags, :limits, %{}))
    Application.put_env(:cyfr, :base_path, Path.join(run_dir, "data"))
    Application.put_env(:cyfr, :seed_path, seed)
    Application.put_env(:cyfr, :consent_source, Source.DB)
    # The seed names no published component, and nothing may be dialled.
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(run_dir)
    end)

    # The turns' work stops before the paths it runs under are restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Fixture.estate!()
    on_exit(fn -> Cyfr.Slots.forgive_unreaped(Cyfr.Execution.Slots, ctx.athanor_id) end)
    :ok = Fixture.bind_key!(ctx, @canary)
    {:ok, ctx: ctx}
  end

  test "the fixture's binary and sources are the ones its README records" do
    readme = File.read!(Fixture.readme_path())
    dir = Path.dirname(Fixture.wasm_path())

    for name <- ["src/lib.rs", "Cargo.lock", "chat_fixture.wasm"] do
      assert [_, recorded] =
               Regex.run(~r/^#{Regex.escape(name)}\s+(sha256:[0-9a-f]{64})$/m, readme)

      assert Cyfr.Digest.sha256(File.read!(Path.join(dir, name))) == recorded, name
    end
  end

  test "V1: a person's hello on a provisioned estate completes, and the key shows nowhere",
       %{ctx: ctx} do
    played = play(ctx, "@aqua hello")

    assert %{status: "completed"} = played.turn
    assert [%{kind: "text", content: "The fixture answers."}] = agent_rows(played)

    assert [%{dispatch_state: "closed", outcome: "ok", child_execution_id: id}] =
             model_steps(played)

    assert {:ok, _row, request} = Arca.ExecutionPayloads.get(ctx, id, "input")
    assert request =~ "@aqua hello"
    assert {:ok, _row, result} = Arca.ExecutionPayloads.get(ctx, id, "result")
    assert result =~ "The fixture answers."

    # The scan finds what is there: the person's line in its row and in the
    # retained request.
    assert {:table, "messages", "content"} in Fixture.leaks("@aqua hello")
    assert {:term, :payloads} in Fixture.leaks("@aqua hello", payloads: payloads(ctx))
    assert [] = key_leaks(ctx, played)
  end

  test "text streamed in deltas reaches the thread in order, the held tail ahead of the row",
       %{ctx: ctx} do
    # The last delta ends in the first bytes of the bound key, which the
    # host holds back until the stream says no more is coming.
    deltas = ["Streaming ", "naïve ☕ text, ", "in order, ending ", key(0, 9)]
    whole = "Streaming naïve ☕ text, in order, ending " <> binary_part(@canary, 0, 9)

    played =
      play(ctx, [
        %{
          "emit" => Enum.map(deltas, &text/1) ++ [usage(tokens(7, 9)), stop("end_turn")],
          "answer" => answer([text_block(Enum.join(deltas))], "end_turn", tokens(7, 9))
        }
      ])

    assert %{status: "completed"} = played.turn
    assert [%{kind: "text", content: ^whole} = row] = agent_rows(played)

    # The thread: every delta of the step in stream order, then the row.
    assert [%{child_execution_id: id, id: step_id}] = model_steps(played)
    {streamed, landed} = Enum.split_while(played.seen.thread, &(not match?({:message, ^row}, &1)))
    assert [{:message, ^row} | _] = landed
    thread_deltas = for {:delta, %{step_id: ^step_id} = delta} <- streamed, do: delta
    assert Enum.map_join(thread_deltas, & &1.text) == whole
    assert thread_deltas == Enum.sort_by(thread_deltas, & &1.seq)
    refute Enum.any?(landed, &match?({:delta, _}, &1))

    # The execution's stream: the text whole ahead of `stop`, numbered under
    # one durable event, and the terminal event after both.
    stream = Map.fetch!(played.seen.streams, id)
    emitted = emitted(stream)
    assert streamed_text(emitted) == whole
    # The tail the host held leaves ahead of `stop`; an event of another
    # kind, `usage` here, does not wait behind it.
    assert [%{"type" => "text.delta", "text" => "sk-canary"}, %{"type" => "stop"}] =
             Enum.take(emitted, -2)

    assert usage(tokens(7, 9)) in emitted

    # The guest was answered the number of the last event each emit released:
    # none for the delta held whole, and the stream's last for `stop`.
    replies = report(ctx, id)["emitted"]
    numbers = for %{type: "emit", sequence: sequence} <- stream, do: sequence
    named = for %{"sequence" => sequence} <- replies, do: sequence
    assert length(replies) == 6 and Enum.all?(replies, &(&1["ok"] == true))
    assert Enum.at(replies, 3) == %{"ok" => true}
    assert named == Enum.filter(numbers, &(&1 in named))
    assert List.last(named) == List.last(numbers)
    assert length(numbers) == 6 and numbers == Enum.uniq(numbers)
    # A subscriber hears the stream in the order it is numbered.
    assert stream == Enum.sort_by(stream, &{&1.durable, &1.delta || 0})
    assert for(%{type: "emit"} = e <- stream, do: e.origin) |> Enum.uniq() == ["guest"]
    assert %{type: "execution.completed"} = List.last(stream)

    # A viewer keeps the answer while it streams and the row once it lands.
    assert kept_text(streamed) == [whole]
    assert kept_text(played.seen.thread) == []
  end

  test "a catalyst that ends without stop still has its held tail flushed before the answer lands",
       %{ctx: ctx} do
    whole = "No stop follows " <> binary_part(@canary, 0, 12)

    played =
      play(ctx, [
        %{
          "emit" => [text("No stop follows "), text(key(0, 12))],
          "answer" =>
            answer([text_block("No stop follows " <> key(0, 12))], "end_turn", tokens(3, 4))
        }
      ])

    assert %{status: "completed"} = played.turn
    assert [%{kind: "text", content: ^whole} = row] = agent_rows(played)
    assert [%{outcome: "ok", child_execution_id: id, id: step_id}] = model_steps(played)

    # The guest was told the tail was held, and the close sent it.
    assert [%{"ok" => true, "sequence" => _}, held] = report(ctx, id)["emitted"]
    assert held == %{"ok" => true}

    stream = Map.fetch!(played.seen.streams, id)
    assert streamed_text(emitted(stream)) == whole
    refute Enum.any?(emitted(stream), &(&1["type"] == "stop"))
    assert %{type: "execution.completed"} = List.last(stream)

    {streamed, [{:message, ^row} | _]} =
      Enum.split_while(played.seen.thread, &(not match?({:message, ^row}, &1)))

    assert Enum.map_join(for({:delta, %{step_id: ^step_id} = d} <- streamed, do: d), & &1.text) ==
             whole
  end

  test "tool calls streamed in fragments become the proposed calls, run through the gate, and return to the next chat",
       %{ctx: ctx} do
    {:ok, _} = Aqua.Notes.keep(ctx, "brew", "naïve ☕ \"quoted\" back\\slash 😀 tab\there")

    # One call, then three beside each other; the arguments are JSON text cut
    # where a catalyst's provider may cut it: between the bytes of an escape,
    # between the halves of a surrogate pair, and around multi-byte
    # characters.
    search = %{"action" => "search", "query" => "naïve ☕ \"quoted\" back\\slash"}
    search_json = ~S({"action":"search","query":"naïve ☕ \"quoted\" back\\slash"})
    assert Jason.decode!(search_json) == search

    emoji = %{"action" => "search", "query" => "😀 tab\there"}
    # U+1F600 as JSON spells it outside the basic plane: a surrogate pair of
    # two escapes, cut between them below.
    high = "\\" <> "ud83d"
    low = "\\" <> "ude00"
    emoji_json = ~S({"action":"search","query":") <> high <> low <> ~S( tab\there"})
    assert Jason.decode!(emoji_json) == emoji

    list = %{"action" => "list", "limit" => 5}
    list_json = ~S({"action":"list","limit":5})
    status = %{"action" => "status"}
    status_json = ~S({"action":"status"})

    # After the brace; on either side of a two-byte and of a three-byte
    # character; inside `\"`; inside `\\`.
    one =
      fragments(search_json, [
        1,
        cut(search_json, "ïve", 0),
        cut(search_json, "ïve", 2),
        cut(search_json, "☕", 0),
        cut(search_json, "☕", 3),
        cut(search_json, ~S(\"q), 1),
        cut(search_json, ~S(\\s), 1)
      ])

    # Inside the first escape of the pair, and between the pair's escapes.
    [e1, e2, e3] = fragments(emoji_json, [cut(emoji_json, high, 3), cut(emoji_json, low, 0)])

    # An event is JSON text handed over as a WIT string, so a cut inside a
    # character's bytes is not something `emit` can be given.
    assert_raise ArgumentError, fn -> fragments(search_json, [cut(search_json, "☕", 1)]) end

    [l1, l2] = fragments(list_json, [cut(list_json, "limit", 2)])

    played =
      play(ctx, [
        %{
          "emit" =>
            [text("Looking."), call_start(0, "c1", "notes")] ++
              Enum.map(one, &call_delta(0, &1)) ++
              [call_end(0), usage(tokens(10, 5)), stop("tool_call")],
          "answer" =>
            answer(
              [text_block("Looking."), call_block("c1", "notes", search)],
              "tool_call",
              tokens(10, 5)
            )
        },
        %{
          "emit" => [
            call_start(0, "c2", "notes"),
            call_start(1, "c3", "notes"),
            call_delta(0, l1),
            call_delta(1, e1),
            call_start(2, "c4", "system"),
            call_delta(1, e2),
            call_delta(2, status_json),
            call_delta(0, l2),
            call_end(0),
            call_delta(1, e3),
            call_end(2),
            call_end(1),
            usage(tokens(20, 8)),
            stop("tool_call")
          ],
          "answer" =>
            answer(
              [
                call_block("c2", "notes", list),
                call_block("c3", "notes", emoji),
                call_block("c4", "system", status)
              ],
              "tool_call",
              tokens(20, 8)
            )
        },
        %{
          "emit" => [text("Done."), usage(tokens(30, 2)), stop("end_turn")],
          "answer" => answer([text_block("Done.")], "end_turn", tokens(30, 2))
        }
      ])

    assert %{status: "completed"} = played.turn

    assert [
             %{kind: "model", outcome: "ok"} = first,
             %{kind: "tool", tool: "notes", action: "search", outcome: "ok"} = c1,
             %{kind: "model", outcome: "ok"} = second,
             %{kind: "tool", tool: "notes", action: "list", outcome: "ok"} = c2,
             %{kind: "tool", tool: "notes", action: "search", outcome: "ok"} = c3,
             %{kind: "tool", tool: "system", action: "status", outcome: "ok"} = c4,
             %{kind: "model", outcome: "ok"} = third
           ] = played.steps

    # The proposed calls are the calls sent, argument for argument.
    for {step, id, name, arguments} <- [
          {c1, "c1", "notes", search},
          {c2, "c2", "notes", list},
          {c3, "c3", "notes", emoji},
          {c4, "c4", "system", status}
        ] do
      assert {:ok, %{kind: "tool_call"} = row} = Tape.message(ctx, step.message_id)

      assert %{"tool_call_id" => ^id, "name" => ^name, "arguments" => ^arguments} =
               Tape.payload(row)

      assert step.dispatch_state == "closed" and is_binary(step.result_message_id)
    end

    # The searches ran with those arguments: each found the note kept above.
    for step <- [c1, c3] do
      assert {:ok, %{kind: "tool_result", content: content}} =
               Tape.message(ctx, step.result_message_id)

      assert content =~ "brew"
    end

    # The stream carried each call's fragments in the guest's order, whole.
    first_stream = emitted(Map.fetch!(played.seen.streams, first.child_execution_id))
    assert streamed_text(first_stream) == "Looking."
    assert streamed_arguments(first_stream) == %{0 => search_json}

    assert Enum.find(first_stream, &(&1["type"] == "tool_call.start")) ==
             call_start(0, "c1", "notes")

    assert shape(first_stream) ==
             ~w(text.delta tool_call.start tool_call.delta tool_call.end usage stop)

    second_stream = emitted(Map.fetch!(played.seen.streams, second.child_execution_id))

    assert streamed_arguments(second_stream) == %{
             0 => list_json,
             1 => emoji_json,
             2 => status_json
           }

    assert for(%{"type" => "tool_call.start"} = e <- second_stream, do: {e["index"], e["id"]}) ==
             [{0, "c2"}, {1, "c3"}, {2, "c4"}]

    assert for(%{"type" => "tool_call.end"} = e <- second_stream, do: e["index"]) == [0, 2, 1]
    # Nothing a call streams reaches the thread as text.
    assert [] = for({:delta, %{step_id: id}} <- played.seen.thread, id == second.id, do: id)

    # The next chat was given the calls and their results.
    assert %{"step" => 1, "received" => %{"messages" => messages}} =
             report(ctx, second.child_execution_id)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => said},
             %{"role" => "tool", "content" => [result]}
           ] =
             messages

    assert [
             %{"type" => "text", "text" => "Looking."},
             %{"type" => "tool_call", "id" => "c1", "name" => "notes", "arguments" => ^search}
           ] =
             said

    {:ok, c1_result} = Tape.message(ctx, c1.result_message_id)

    assert %{
             "type" => "tool_result",
             "tool_call_id" => "c1",
             "name" => "notes",
             "is_error" => false
           } =
             result

    assert result["content"] == c1_result.content

    assert %{"step" => 2, "received" => %{"messages" => messages}} =
             report(ctx, third.child_execution_id)

    assert %{"role" => "tool", "content" => results} = List.last(messages)
    # Reads run beside each other, so their results land as they finish.
    assert results |> Enum.map(& &1["tool_call_id"]) |> Enum.sort() == ["c2", "c3", "c4"]
    refute Enum.any?(results, & &1["is_error"])

    # Usage is counted once a step: the thread's totals are the answers' sum.
    assert for(step <- [first, second, third], do: Jason.decode!(step.usage)) ==
             [tokens(10, 5), tokens(20, 8), tokens(30, 2)]

    # Each chat step's execution keeps the usage its answer carried.
    assert for(step <- [first, second, third], do: execution_usage(step.child_execution_id)) ==
             [tokens(10, 5), tokens(20, 8), tokens(30, 2)]

    assert [%{input: 10, output: 5}, %{input: 30, output: 13}, %{input: 60, output: 15}] =
             for({:usage, totals} <- played.seen.thread, do: totals)

    assert {:ok, []} = Arca.BudgetReservations.charges(ctx.athanor_id, played.turn.budget_id)

    # Each call passed the gate, which keeps a row of it with what it was
    # asked; the rows close behind the calls.
    gated = fn ->
      {:ok, rows} = Arca.McpLog.list(athanor_id: ctx.athanor_id, limit: 100)
      for %{tool: tool} = row <- rows, tool in ["notes", "system"], do: row
    end

    wait_until(
      fn -> Enum.count(gated.(), &(&1.status == "success")) == 4 end,
      @settle_ms,
      "the gate's rows of the four calls to close"
    )

    assert gated.() |> Enum.map(&"#{&1.tool}.#{&1.action}") |> Enum.sort() ==
             ["notes.list", "notes.search", "notes.search", "system.status"]

    assert gated.()
           |> Enum.filter(&(&1.action == "search"))
           |> Enum.map(&Jason.decode!(&1.input)["query"])
           |> Enum.sort() == Enum.sort([search["query"], emoji["query"]])
  end

  test "the tools a catalyst is given are the gate's flat schemas", %{ctx: ctx} do
    played = play(ctx, "@aqua hello")
    assert [%{child_execution_id: id}] = model_steps(played)

    assert %{"received" => %{"model" => "chat-fixture", "tools" => tools, "system" => system}} =
             report(ctx, id)

    assert is_binary(system) and system != ""
    assert Enum.map(tools, & &1["name"]) == ["notes", "system", "ui", "request_setup"]

    for %{"name" => name, "description" => description, "parameters" => schema} = tool <- tools do
      assert map_size(tool) == 3
      assert is_binary(description) and description != ""
      assert %{"type" => "object", "properties" => %{} = properties} = schema
      assert List.wrap(schema["required"]) -- Map.keys(properties) == []

      for combinator <- ~w(oneOf anyOf allOf not if then else $ref $defs),
          do:
            refute(Map.has_key?(schema, combinator), "#{name} carries a top-level #{combinator}")

      for {property, rendered} <- properties,
          do: assert(is_map_key(rendered, "type"), "#{name}.#{property} names no type")
    end

    # A catalog tool's schema is the one the gate derives for the actions the
    # policy offers, and nothing the policy does not offer is named.
    for {name, actions} <- [{"notes", ~w(keep list read search)}, {"system", ~w(status)}] do
      {:ok, definition} = Cyfr.Ops.Catalog.get_tool(name)
      derived = Cyfr.Ops.Catalog.restrict_tool(definition, actions)["inputSchema"]
      %{"parameters" => given} = Enum.find(tools, &(&1["name"] == name))

      assert given == Jason.decode!(Jason.encode!(derived))
      assert given["properties"]["action"]["enum"] == actions
      assert given["additionalProperties"] == false
    end
  end

  test "a call that asks pauses the turn on a card, and the approved call runs and returns to the next chat",
       %{ctx: ctx} do
    keep = %{"action" => "keep", "name" => "kept", "content" => "from the fixture"}

    steps = [
      %{
        "emit" => [
          call_start(0, "k1", "notes"),
          call_delta(0, Jason.encode!(keep)),
          call_end(0),
          stop("tool_call")
        ],
        "answer" => answer([call_block("k1", "notes", keep)], "tool_call", tokens(4, 4))
      },
      %{
        "emit" => [text("Kept."), stop("end_turn")],
        "answer" => answer([text_block("Kept.")], "end_turn", tokens(6, 1))
      }
    ]

    paused = play(ctx, steps)
    assert %{status: "paused", paused_reason: "approval"} = paused.turn

    assert [%{kind: "model", outcome: "ok"}, %{action: "keep", dispatch_state: "proposed"} = step] =
             paused.steps

    assert {:error, _} = Aqua.Notes.read(ctx, "kept")
    assert {:ok, [approval]} = Tape.pending_approvals(ctx, paused.turn)
    assert approval.id == step.approval_id

    assert {:ok, %{decision: "approved"}} =
             Approvals.resolve(ctx, approval.id, %{decision: :approved})

    resumed = finish(ctx, paused)

    assert %{status: "completed"} = resumed.turn

    assert [
             _,
             %{action: "keep", dispatch_state: "closed", outcome: "ok"},
             %{kind: "model", outcome: "ok"} = last
           ] = resumed.steps

    assert {:ok, %{content: "from the fixture"}} = Aqua.Notes.read(ctx, "kept")
    assert %{kind: "text", content: "Kept."} = List.last(agent_rows(resumed))

    assert %{"step" => 1, "received" => %{"messages" => messages}} =
             report(ctx, last.child_execution_id)

    assert %{"role" => "tool", "content" => [%{"tool_call_id" => "k1", "is_error" => false}]} =
             List.last(messages)
  end

  test "a bound key split across two text deltas and across two argument fragments shows nowhere",
       %{ctx: ctx} do
    query = %{"action" => "search", "query" => key()}
    masked_query = %{"action" => "search", "query" => @redacted}
    masked_json = ~s({"action":"search","query":"#{@redacted}"})

    steps = [
      %{
        "emit" => [
          text("The key is " <> key(0, 6)),
          # Another stream's events between the halves change nothing.
          call_start(0, "m1", "notes"),
          call_delta(0, ~s({"action":"search","query":") <> key(0, 11)),
          text(key(6) <> ", whole."),
          call_delta(0, key(11) <> ~s("})),
          call_end(0),
          usage(tokens(5, 5)),
          stop("tool_call")
        ],
        "answer" =>
          answer(
            [text_block("The key is " <> key() <> ", whole."), call_block("m1", "notes", query)],
            "tool_call",
            tokens(5, 5)
          )
      },
      %{
        # And across three, the middle one nothing but key.
        "emit" => [
          text("Said " <> key(0, 5)),
          text(key(5, 13)),
          text(key(13) <> "."),
          stop("end_turn")
        ],
        "answer" => answer([text_block("Said " <> key() <> ".")], "end_turn", tokens(8, 3))
      }
    ]

    played = play(ctx, steps)

    # The turn completes on the masked text and the masked call.
    assert %{status: "completed"} = played.turn

    assert [
             %{outcome: "ok"} = first,
             %{kind: "tool", outcome: "ok"} = call,
             %{outcome: "ok"} = second
           ] = played.steps

    assert {:ok, row} = Tape.message(ctx, call.message_id)
    assert %{"arguments" => ^masked_query} = Tape.payload(row)

    assert ["The key is #{@redacted}, whole.", "Said #{@redacted}."] ==
             for(%{kind: "text", content: content} <- agent_rows(played), do: content)

    first_stream = emitted(Map.fetch!(played.seen.streams, first.child_execution_id))
    assert streamed_text(first_stream) == "The key is #{@redacted}, whole."
    assert streamed_arguments(first_stream) == %{0 => masked_json}
    second_stream = emitted(Map.fetch!(played.seen.streams, second.child_execution_id))
    assert streamed_text(second_stream) == "Said #{@redacted}."

    # The next chat is given the masked text and the masked call, as the rows
    # hold them.
    assert %{"received" => %{"messages" => messages}} = report(ctx, second.child_execution_id)

    assert [_person, %{"role" => "assistant", "content" => [said, called]}, %{"role" => "tool"}] =
             messages

    assert said == text_block("The key is #{@redacted}, whole.")
    assert %{"type" => "tool_call", "id" => "m1", "arguments" => ^masked_query} = called

    assert [] = key_leaks(ctx, played)
  end

  test "every stop reason the contract names ends its step ok, and a turn with no calls ends",
       %{ctx: ctx} do
    for reason <- ~w(end_turn max_tokens content_filter other) do
      said = "Stopped by #{reason}."

      played =
        play(ctx, [
          %{
            "emit" => [text(said), usage(tokens(2, 3)), stop(reason)],
            "answer" => answer([text_block(said)], reason, tokens(2, 3))
          }
        ])

      assert %{status: "completed"} = played.turn, reason

      assert [%{dispatch_state: "closed", outcome: "ok", id: step_id, child_execution_id: id}] =
               played.steps

      assert [%{kind: "text", content: ^said}] = agent_rows(played)
      assert List.last(emitted(Map.fetch!(played.seen.streams, id))) == stop(reason)

      assert [%{"stop_reason" => ^reason, "calls" => 0, "usage" => usage}] =
               turn_events(ctx, played, "model.completed", step_id)

      assert usage == tokens(2, 3)
      assert {:turn_finished} in played.seen.thread
    end
  end

  test "an error event with a typed refusal fails the turn, withdraws what streamed, and leaves the thread usable",
       %{ctx: ctx} do
    refusal = %{"type" => "provider_error", "message" => "the provider said no"}

    played =
      play(ctx, [
        %{
          "emit" => [
            text("Half an ans" <> key(0, 4)),
            error("provider_error", "the provider said no")
          ],
          "refuse" => %{"status" => 502, "error" => refusal}
        }
      ])

    assert %{status: "failed", error: "the provider said no"} = played.turn

    assert [
             %{
               dispatch_state: "closed",
               outcome: "error",
               error: "the provider said no",
               id: step_id,
               child_execution_id: id
             }
           ] = played.steps

    # The held tail goes out ahead of the error, and the stream ends there.
    emitted = emitted(Map.fetch!(played.seen.streams, id))
    assert streamed_text(emitted) == "Half an ans" <> binary_part(@canary, 0, 4)
    assert List.last(emitted) == error("provider_error", "the provider said no")

    # What streamed is withdrawn, and the person is told why.
    assert [%{step_id: ^step_id}] =
             for({:delta_abandoned, marker} <- played.seen.thread, do: marker)

    assert kept_text(played.seen.thread) == []
    assert [] = agent_rows(played)

    assert Enum.any?(
             played.rows,
             &(&1.content =~ "The model could not answer: the provider said no")
           )

    assert {:turn_finished} in played.seen.thread

    # The thread takes the next turn, which a script of its own plays.
    again = play(ctx, back(), played.thread)
    assert %{status: "completed"} = again.turn
    assert %{kind: "text", content: "Back."} = List.last(agent_rows(again))
  end

  test "an answer that contradicts what streamed is the answer kept", %{ctx: ctx} do
    played =
      play(ctx, [
        %{
          "emit" => [
            text("A draft that streamed."),
            call_start(0, "x1", "notes"),
            call_delta(0, ~S({"action":"list"})),
            call_end(0),
            usage(tokens(100, 100)),
            stop("tool_call")
          ],
          "answer" => answer([text_block("The answer given.")], "end_turn", tokens(1, 2))
        }
      ])

    assert %{status: "completed"} = played.turn
    assert [%{kind: "model", outcome: "ok", id: step_id} = step] = played.steps
    assert [%{kind: "text", content: "The answer given."}] = agent_rows(played)
    assert Jason.decode!(step.usage) == tokens(1, 2)
    assert [%{input: 1, output: 2}] = for({:usage, totals} <- played.seen.thread, do: totals)

    assert [%{"stop_reason" => "end_turn", "calls" => 0}] =
             turn_events(ctx, played, "model.completed", step_id)

    # A viewer who kept the draft is left with the row alone.
    {streamed, [{:message, _row} | _]} =
      Enum.split_while(
        played.seen.thread,
        &(not match?({:message, %{content: "The answer given."}}, &1))
      )

    assert kept_text(streamed) == ["A draft that streamed."]
    assert kept_text(played.seen.thread) == []
  end

  test "a trap ends the step with the engine's error and fails the turn", %{ctx: ctx} do
    played =
      play(ctx, [%{"emit" => [text("About to tr" <> key(0, 5))], "then" => "trap"}])

    assert %{status: "failed"} = played.turn

    assert [
             %{
               dispatch_state: "closed",
               outcome: "error",
               error: error,
               id: step_id,
               child_execution_id: id
             }
           ] = played.steps

    # The error is the trap. The exit of the call that trapped also names the
    # call's arguments, the whole request: none of it is the run's error,
    # which the rows below, the thread and the log all carry.
    assert error =~ ~r/^Component call failed for .*wasm trap/
    assert %{status: "failed", error_message: ^error} = Arca.Repo.get!(Arca.Execution, id)
    assert %{error: turn_error} = played.turn
    told = Enum.find(played.rows, &(&1.content =~ "The model could not be reached"))
    assert %{author: "system"} = told
    failed = Enum.find(Map.fetch!(played.seen.streams, id), &(&1.type == "execution.failed"))

    request = ["play the script", "chat-fixture", "You answer the person"]

    for said <- [error, turn_error, told.content, inspect(failed.data)],
        part <- request ++ ["GenServer", "#PID"],
        do: refute(said =~ part)

    # What the engine and the host said of the trap, the crash report among
    # it; the queries' own lines carry the person's line as the row it is.
    said_of_it = logged(played.log, ["warning", "error"])
    assert said_of_it =~ "wasm trap"
    for part <- request, do: refute(said_of_it =~ part)

    # The close still sent the tail the guest left held.
    stream = Map.fetch!(played.seen.streams, id)
    assert streamed_text(emitted(stream)) == "About to tr" <> binary_part(@canary, 0, 5)
    assert %{type: "execution.failed"} = List.last(stream)

    assert [%{step_id: ^step_id}] =
             for({:delta_abandoned, marker} <- played.seen.thread, do: marker)

    assert {:turn_finished} in played.seen.thread
    assert %{status: "failed"} = Arca.Repo.get!(Arca.Execution, played.turn.root_execution_id)
    assert [] = key_leaks(ctx, played)

    # The thread takes the next turn, which a script of its own plays.
    again = play(ctx, back(), played.thread)
    assert %{status: "completed"} = again.turn
    assert %{kind: "text", content: "Back."} = List.last(agent_rows(again))
  end

  @tag limits: %{"timeout" => "3s"}
  test "a catalyst that runs past its deadline is stopped, and the turn fails", %{ctx: ctx} do
    played =
      play(ctx, [
        %{
          "emit" => [text("Thinking")],
          "sleep_ms" => 8_000,
          "answer" => answer([], "end_turn", %{})
        }
      ])

    assert %{status: "failed"} = played.turn

    assert [%{dispatch_state: "closed", outcome: "error", error: error, child_execution_id: id}] =
             played.steps

    assert error =~ ~r/^Execution timeout after \d+ms$/
    assert %{status: "failed", error_message: ^error} = Arca.Repo.get!(Arca.Execution, id)
    assert %{type: "execution.failed"} = List.last(Map.fetch!(played.seen.streams, id))
    assert [] = agent_rows(played)
    assert {:turn_finished} in played.seen.thread
  end

  test "an event over the size bound is refused to the guest, and the run goes on", %{ctx: ctx} do
    played =
      play(ctx, [
        %{
          "emit" => [
            text("Before. "),
            text(fill("x", 1_100_000)),
            text("After."),
            stop("end_turn")
          ],
          "answer" => answer([text_block("Before. After.")], "end_turn", tokens(1, 1))
        }
      ])

    assert %{status: "completed"} = played.turn
    assert [%{outcome: "ok", child_execution_id: id}] = played.steps

    assert [
             %{"ok" => true},
             %{"error" => %{"type" => "resource_limit"}},
             %{"ok" => true},
             %{"ok" => true}
           ] =
             report(ctx, id)["emitted"]

    assert streamed_text(emitted(Map.fetch!(played.seen.streams, id))) == "Before. After."
    assert [%{kind: "text", content: "Before. After."}] = agent_rows(played)
  end

  test "an emit past the execution's budget is refused to the guest, and the run goes on", %{
    ctx: ctx
  } do
    played =
      play(ctx, [
        %{
          "emit" => [repeat(@emit_budget + 1, text(".")), stop("end_turn")],
          "answer" => answer([text_block("Flooded.")], "end_turn", tokens(1, 1))
        }
      ])

    assert %{status: "completed"} = played.turn
    assert [%{outcome: "ok", child_execution_id: id}] = played.steps

    assert [
             %{
               "repeat" => 3001,
               "accepted" => @emit_budget,
               "refused" => 1,
               "first_refusal" => refusal
             },
             %{"error" => %{"type" => "resource_limit"}}
           ] = report(ctx, id)["emitted"]

    assert %{"error" => %{"type" => "resource_limit", "message" => message}} = refusal
    assert message =~ "rate limit"

    emitted = emitted(Map.fetch!(played.seen.streams, id))
    assert length(emitted) == @emit_budget
    assert [%{kind: "text", content: "Flooded."}] = agent_rows(played)
  end

  # ---------------------------------------------------------------------------
  # Driving
  # ---------------------------------------------------------------------------

  # A person sends the script of `steps` (or the line `text`) on a thread of
  # its own, or on `thread`, and the turn is followed until it leaves the
  # runner: finished, or paused on a card. Answers what is then true: the
  # turn, its steps, the thread's rows, what a viewer saw and the log.
  defp play(ctx, steps_or_text, thread \\ nil)

  defp play(ctx, steps, thread) when is_list(steps), do: play(ctx, message(steps), thread)

  defp play(ctx, text, thread) when is_binary(text) do
    thread = thread || elem({:ok, _} = Threads.create(ctx), 1)

    # The thread's runner has let its last turn go, so this line opens a
    # turn of its own and steers none.
    wait_until(
      fn -> match?(%{running: false}, Runner.state(thread.id, ctx.athanor_id)) end,
      @settle_ms,
      "the thread's runner to be idle"
    )

    observer = Fixture.observe!(ctx, thread.id)
    # One subscription, and nothing an earlier turn of the thread left.
    :ok = Runner.unsubscribe(thread.id, ctx.athanor_id)
    drain_thread()
    :ok = Runner.subscribe(thread.id, ctx.athanor_id)

    {turn_id, log} =
      with_every_log(fn ->
        assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
                 Runner.send_message(ctx, thread.id, text)

        await_turn(ctx, turn_id, :pauses)
        turn_id
      end)

    settled(ctx, %{thread: thread, observer: observer, turn_id: turn_id, log: log})
  end

  # A paused turn whose card was answered is followed to its end.
  defp finish(ctx, %{turn_id: turn_id} = played) do
    {:ok, log} = with_every_log(fn -> await_turn(ctx, turn_id, :ends) end)
    settled(ctx, %{played | log: played.log <> log})
  end

  defp settled(ctx, %{thread: thread, observer: observer, turn_id: turn_id} = played) do
    {:ok, turn} = Tape.turn(ctx, turn_id)
    {:ok, steps} = Tape.steps(ctx, turn)

    Map.merge(played, %{
      turn: turn,
      steps: steps,
      rows: Threads.messages(ctx, thread.id),
      seen: await_seen(observer, turn, steps)
    })
  end

  # The viewer hears the thread and the streams beside this process, not
  # through it: what it saw is read once it holds the turn's end and the
  # terminal event of every model step that closed.
  defp await_seen(observer, turn, steps) do
    closed =
      for %{kind: "model", dispatch_state: "closed", child_execution_id: id} <- steps, do: id

    wait_until(
      fn ->
        seen = Fixture.seen(observer)
        ended? = turn.status == "paused" or {:turn_finished} in seen.thread

        ended? and
          Enum.all?(closed, fn id ->
            seen.streams |> Map.get(id, []) |> Enum.any?(&Cyfr.Execution.Events.terminal?/1)
          end)
      end,
      @settle_ms,
      "the viewer to hear the turn's end"
    )

    Fixture.seen(observer)
  end

  # The log a turn writes at every level, debug included: the suite's level
  # is raised for the turn and put back, which a sync test may do.
  defp with_every_log(fun) do
    level = Logger.level()

    with_log(fn ->
      Logger.configure(level: :debug)

      try do
        fun.()
      after
        Logger.configure(level: level)
      end
    end)
  end

  # The entries of a captured log written at one of `levels`, whole: an
  # entry runs from its timestamp to the next entry's.
  defp logged(log, levels) do
    ~r/^(?=\d\d:\d\d:\d\d\.\d{3} )/m
    |> Regex.split(log)
    |> Enum.filter(fn entry -> Enum.any?(levels, &(entry =~ "[#{&1}]")) end)
    |> Enum.join()
  end

  # A card opens before the pause it causes lands; an answered card is
  # announced again, which a turn being followed to its end reads past.
  defp await_turn(ctx, turn_id, mode) do
    receive do
      {:thread, _thread, {:turn_finished}} ->
        :ok

      {:thread, _thread, {:message, %{kind: "approval"}}} when mode == :pauses ->
        wait_until(
          fn -> match?({:ok, %{status: "paused"}}, Tape.turn(ctx, turn_id)) end,
          @turn_ms,
          "the turn to pause on its card"
        )

      {:thread, _thread, _event} ->
        await_turn(ctx, turn_id, mode)
    after
      @turn_ms -> flunk("the turn #{turn_id} neither finished nor paused")
    end
  end

  defp drain_thread do
    receive do
      {:thread, _thread, _event} -> drain_thread()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  defp model_steps(played), do: Enum.filter(played.steps, &(&1.kind == "model"))

  # The usage an execution's row keeps in its output's envelope.
  defp execution_usage(execution_id) do
    Arca.Execution
    |> Arca.Repo.get!(execution_id)
    |> Map.fetch!(:output)
    |> Jason.decode!()
    |> Map.fetch!("usage")
  end

  defp agent_rows(played) do
    agent = Arca.Schemas.Message.agent_author()
    for %{author: ^agent, kind: kind} = row <- played.rows, kind in ["text", "tool_call"], do: row
  end

  defp turn_events(ctx, played, type, step_id) do
    {:ok, rows} = Arca.ExecutionEvents.since(ctx.athanor_id, played.turn.root_execution_id, 0)
    for %{type: ^type, step_id: ^step_id} = row <- rows, do: Arca.ExecutionEvents.data(row)
  end

  defp streamed_text(emitted),
    do: Enum.map_join(for(%{"type" => "text.delta"} = e <- emitted, do: e), & &1["text"])

  defp streamed_arguments(emitted) do
    for(%{"type" => "tool_call.delta"} = e <- emitted, do: e)
    |> Enum.group_by(& &1["index"], & &1["arguments"])
    |> Map.new(fn {index, fragments} -> {index, Enum.join(fragments)} end)
  end

  # The event types of a stream, runs of one type as one.
  defp shape(emitted), do: emitted |> Enum.map(& &1["type"]) |> Enum.dedup()

  # What a viewer of the thread keeps of the streamed answers (`Aqua.Loop.Stream`).
  defp kept_text(events) do
    events
    |> Enum.reduce(Aqua.Loop.Stream.new(), fn
      {:turn_fence, _, fence}, kept -> Aqua.Loop.Stream.advance(kept, fence)
      {:delta, delta}, kept -> Aqua.Loop.Stream.add(kept, delta)
      {:delta_abandoned, marker}, kept -> Aqua.Loop.Stream.abandoned(kept, marker)
      {:message, row}, kept -> Aqua.Loop.Stream.landed(kept, row)
      _event, kept -> kept
    end)
    |> Aqua.Loop.Stream.texts()
    |> Enum.map(& &1.text)
  end

  # A one-step script that answers "Back.".
  defp back do
    [
      %{
        "emit" => [text("Back."), stop("end_turn")],
        "answer" => answer([text_block("Back.")], "end_turn", tokens(1, 1))
      }
    ]
  end

  # The byte offset `plus` bytes into the first `pattern` of `text`.
  defp cut(text, pattern, plus) do
    {at, _length} = :binary.match(text, pattern)
    at + plus
  end

  # Every retained payload of the estate's executions, read as a person's
  # read of an execution reads them.
  defp payloads(ctx) do
    import Ecto.Query, only: [from: 2]

    ids =
      Arca.Repo.all(
        from(e in Arca.Execution, where: e.athanor_id == ^ctx.athanor_id, select: e.id)
      )

    for id <- ids,
        kind <- ["input", "result"],
        {:ok, _row, bytes} <- [Arca.ExecutionPayloads.get(ctx, id, kind)] do
      {id, kind, bytes}
    end
  end

  # Where the bound key shows: any column of any table, any file under the
  # base path, any retained payload, anything a viewer saw, the log.
  defp key_leaks(ctx, played) do
    Fixture.leaks(@canary, payloads: payloads(ctx), seen: played.seen, log: played.log)
  end
end
