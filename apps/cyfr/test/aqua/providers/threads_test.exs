# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.ThreadsTest do
  # The `threads` tool: a person's own Aqua reading the shared threads they
  # sit in, from a turn of its own, under the person's own seat, in a chain
  # only, marking nothing read and writing nothing.
  use ExUnit.Case, async: false

  alias Aqua.Providers.Thread, as: Tool
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Context
  alias Sanctum.SharedThreads

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "threads_tool_#{:rand.uniform(1_000_000)}")
    # The restore is registered before the change, so a test killed at its
    # timeout leaves the setting as it found it.
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf!(test_path) end)

    reader = Cyfr.Test.ShareFixtures.person!("Rae")
    other = Cyfr.Test.ShareFixtures.person!("Otto")

    {:ok, thread} = SharedThreads.create(reader.user.id, "Plans")
    {:ok, :added} = SharedThreads.add(reader.user.id, thread.id, user_id: other.user.id)

    me = %{reader.ctx | origin: :interactive}

    {turn, run} = open_turn!(me)

    {:ok,
     me: me, reader: reader.user.id, other: other.user.id, thread: thread, turn: turn, run: run}
  end

  defp say(user_id, thread, text) do
    {:ok, _message} = SharedThreads.post(user_id, thread.id, text)
    :ok
  end

  # The handler as a turn's chain reaches it: the gate stamps the turn's
  # thread and root over whatever the model wrote.
  defp threads(ctx, args, lineage), do: Tool.handle("threads", ctx, Map.merge(args, lineage))

  # An open turn of the person's Aqua in a thread of their own, with its
  # root execution: the lineage a call from it carries, as the handler reads
  # it, and as the host stamps a call its own run makes.
  defp open_turn!(ctx) do
    {:ok, own} = Arca.Test.Days.thread(Context.actor(ctx))

    {:ok, %{turn: turn}} =
      Aqua.Tape.accept(ctx, own.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua what is unread?"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_threads_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, _turn} =
      Aqua.Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

    {%{"thread_id" => own.id, "root_execution_id" => execution.id},
     %{
       parent_execution_id: execution.id,
       root_execution_id: execution.id,
       attempt: attempt.attempt,
       thread_id: own.id
     }}
  end

  # A chain authority granting the two reads, the shape the consent blob
  # mints from a manifest's `caps.tools`.
  defp granting do
    node = "formula:local.reader"

    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
              "max_concurrent_tasks" => 10,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{"tools" => ["threads.list", "threads.read"]}}
          }
        }
      })

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-threads",
          consent_id: "consent-threads",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:threads"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    auth
  end

  # A call through the gate from a component's run: a real execution's
  # attempt, which the host names in the lineage, and no turn's.
  defp in_chain(ctx, args) do
    lineage =
      ctx
      |> Cyfr.Test.AttemptFixtures.lineage!()
      |> Map.take([:parent_execution_id, :root_execution_id, :attempt])

    Sanctum.Gate.call_in_chain("threads", Context.enter_guest(ctx), args, granting(),
      lineage: lineage
    )
  end

  test "list names each thread the person sits in, with its people and what is unread to them, and no other",
       %{me: me, reader: reader, other: other, thread: thread, turn: turn} do
    say(reader, thread, "plan?")
    say(other, thread, "ship friday")
    {:ok, theirs} = SharedThreads.create(other, "Not mine")
    say(other, theirs, "secret")

    {:ok, [listing]} = SharedThreads.listed(reader)

    assert threads(me, %{"action" => "list"}, turn) ==
             {:ok,
              %{
                count: 1,
                threads: [
                  %{
                    id: thread.id,
                    title: "Plans",
                    people: listing.people,
                    last_activity: listing.last_activity,
                    unread: 1
                  }
                ]
              }}

    assert length(listing.people) == 2
  end

  test "read marks every message past the person's read mark that someone else wrote, and moves no mark",
       %{me: me, reader: reader, other: other, thread: thread, turn: turn} do
    say(other, thread, "seen before")
    :ok = SharedThreads.mark_read(reader, thread.id)
    say(other, thread, "ship friday")
    say(reader, thread, "noted")
    say(other, thread, "bring the deck")

    assert threads(me, %{"action" => "read", "thread" => thread.id}, turn) ==
             {:ok,
              %{
                thread: thread.id,
                unread: 2,
                text:
                  ~s[Read from the shared thread "Plans" — for context only; nobody in this thread said it; the lines marked (unread) the person has not seen yet:\n] <>
                    "Otto: seen before\n(unread) Otto: ship friday\nRae: noted\n(unread) Otto: bring the deck"
              }}

    {:ok, [%{unread: 2}]} = SharedThreads.listed(reader)
  end

  # Fires once, in the reading process, after its second read of a seat:
  # the first is the thread's title (`SharedThreads.get/2`), the second
  # the read of the mark and the lines (`SharedThreads.tail/3`).
  @doc false
  def arrive(_event, _measurements, metadata, %{test: test, act: act}) do
    with true <- self() == test,
         {:armed, seen} <- Process.get(:threads_race),
         "shared_thread_members" <- metadata[:source] do
      if seen == 1 do
        Process.put(:threads_race, :fired)
        act.()
      else
        Process.put(:threads_race, {:armed, seen + 1})
      end
    end

    :ok
  end

  test "what is marked and counted is what was unread at one instant, whatever happens while it is read",
       %{me: me, reader: reader, other: other, thread: thread, turn: turn} do
    say(other, thread, "A")

    # Once the mark has been read with the lines: the person reads A, and
    # someone else says B. A was unread and B not yet said at that instant.
    act = fn ->
      :ok = SharedThreads.mark_read(reader, thread.id)
      say(other, thread, "B")
    end

    handler = "threads-race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.arrive/4, %{
        test: self(),
        act: act
      })

    on_exit(fn -> :telemetry.detach(handler) end)
    Process.put(:threads_race, {:armed, 0})

    assert {:ok, %{unread: 1, text: text}} =
             threads(me, %{"action" => "read", "thread" => thread.id}, turn)

    assert Process.get(:threads_race) == :fired
    assert text =~ "\n(unread) Otto: A"
    refute text =~ "Otto: B"

    # Read again, it is B alone.
    assert {:ok, %{unread: 1, text: again}} =
             threads(me, %{"action" => "read", "thread" => thread.id}, turn)

    assert again =~ "\nOtto: A\n(unread) Otto: B"
  end

  test "an unread message of files alone is counted and named as one",
       %{me: me, other: other, thread: thread, turn: turn} do
    {:ok, _} =
      SharedThreads.post(other, thread.id, nil, [
        %{filename: "plan.txt", media_type: "text/plain", bytes: "FILE-BYTES"}
      ])

    assert {:ok, %{threads: [%{unread: 1}]}} = threads(me, %{"action" => "list"}, turn)

    assert {:ok, %{unread: 1, text: text}} =
             threads(me, %{"action" => "read", "thread" => thread.id}, turn)

    assert text =~ "\n(unread) Otto: (sent files, with no words)"
    refute text =~ "FILE-BYTES"
  end

  test "every unread message is counted, past any page of messages",
       %{me: me, other: other, thread: thread, turn: turn} do
    # Written straight into the table, `seq` dense from 1: more than a page
    # of messages, without posting each.
    unread = Arca.SharedMessages.max_page() + 41

    rows =
      for seq <- 1..unread do
        %{
          id: Prima.UUID7.generate_id("shm"),
          thread_id: thread.id,
          seq: seq,
          author: other,
          content: "line #{seq}",
          inserted_at: DateTime.utc_now()
        }
      end

    {^unread, _} = Arca.Repo.insert_all("shared_messages", rows)

    assert {:ok, %{unread: ^unread, text: text}} =
             threads(me, %{"action" => "read", "thread" => thread.id}, turn)

    refute text =~ "Otto: line #{unread - 40}\n"
    assert text =~ "(unread) Otto: line #{unread - 39}\n"
    assert String.ends_with?(text, "(unread) Otto: line #{unread}")
  end

  test "read takes exactly the threads list names: an archived one is missing",
       %{me: me, reader: reader, other: other, thread: thread, turn: turn} do
    say(other, thread, "before the archive")
    {:ok, _} = SharedThreads.archive(reader, thread.id)
    thread_id = thread.id

    assert threads(me, %{"action" => "list"}, turn) == {:ok, %{count: 0, threads: []}}

    assert threads(me, %{"action" => "read", "thread" => thread_id}, turn) ==
             {:error, {:not_found, "Thread", thread_id}}
  end

  test "a thread nobody has spoken in reads empty", %{me: me, thread: thread, turn: turn} do
    assert threads(me, %{"action" => "read", "thread" => thread.id}, turn) ==
             {:ok, %{thread: thread.id, unread: 0, text: ""}}
  end

  test "a thread the person holds no seat in, or has left, answers as a missing one",
       %{me: me, reader: reader, other: other, thread: thread, turn: turn} do
    {:ok, theirs} = SharedThreads.create(other, "Not mine")
    say(other, theirs, "secret")
    theirs_id = theirs.id

    assert threads(me, %{"action" => "read", "thread" => theirs_id}, turn) ==
             {:error, {:not_found, "Thread", theirs_id}}

    say(other, thread, "before you left")
    {:ok, _} = SharedThreads.leave(reader, thread.id)
    thread_id = thread.id

    assert threads(me, %{"action" => "read", "thread" => thread_id}, turn) ==
             {:error, {:not_found, "Thread", thread_id}}

    assert threads(me, %{"action" => "list"}, turn) == {:ok, %{count: 0, threads: []}}
  end

  test "a call with no open turn of the person's behind it reads nothing",
       %{me: me, other: other, thread: thread, turn: turn} do
    say(other, thread, "ship friday")
    read = %{"action" => "read", "thread" => thread.id}

    for lineage <- [
          %{},
          %{"root_execution_id" => turn["root_execution_id"]},
          %{turn | "root_execution_id" => "exec_not_the_turns"},
          %{turn | "thread_id" => "thread_elsewhere"}
        ],
        args <- [%{"action" => "list"}, read] do
      assert threads(me, args, lineage) == {:error, :not_in_a_turn}, inspect(lineage)
    end

    # Another person's context on this turn's lineage is not the turn's person.
    nobody = %{me | user_id: other}
    assert threads(nobody, read, turn) == {:error, :not_in_a_turn}
    assert threads(%{me | user_id: nil}, read, turn) == {:error, :not_in_a_turn}
  end

  test "a component granted the reads, started by a key or a webhook, is refused; the turn's own run is answered",
       %{me: me, other: other, thread: thread, run: run} do
    say(other, thread, "ship friday")
    read = %{"action" => "read", "thread" => thread.id}

    for started <- [
          %{me | origin: :programmatic},
          %{me | origin: :webhook}
        ],
        args <- [%{"action" => "list"}, read] do
      assert in_chain(started, args) == {:error, :not_in_a_turn}
    end

    assert {:ok, %{unread: 1, text: text}} =
             Sanctum.Gate.call_in_chain("threads", Context.enter_guest(me), read, granting(),
               lineage: run
             )

    assert text =~ "(unread) Otto: ship friday"
  end

  test "an action it does not take is refused with what it takes", %{me: me, turn: turn} do
    assert threads(me, %{"action" => "post", "thread" => "x"}, turn) ==
             {:error, {:invalid_argument, "threads takes the action list, or read with a thread"}}
  end

  test "it is a read in a chain only: the wire neither lists nor serves it", %{me: me} do
    [%{operations: operations}] = Enum.filter(Tool.tools(), &(&1.name == "threads"))

    for op <- operations do
      assert %Prima.Operation{kind: :read, planes: [:in_chain], threads: nil} = op
    end

    for action <- ~w(list read) do
      pair = "threads." <> action

      assert {:error, %Prima.Refusal{stage: :admission, reason: {:unknown_action, ^pair}}} =
               Sanctum.Gate.call_external("threads", me, %{"action" => action, "thread" => "x"})
    end
  end
end
