# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.StreamsTest do
  @moduledoc """
  The assistant's two canvas streams. `threads.changes` is one person's
  list of threads, on that person's own topic: their athanor's own threads
  and the active shared threads they sit in, first as the refresh reads
  them and then each change, a shared thread with what is unread to the
  person and an own thread with no read mark. `activity.changes` is the
  athanor's crew at work: every member's open job first, then each start
  and end. Every refresh item and live payload is checked as a canvas
  reads it: projected, passed through JSON and held to the declared
  shape, and none carries a message, a task's text, a person's id or an
  address.
  """

  # The telemetry bridge, which announces a shared thread's change, is
  # attached for the whole node; the cases subscribe to topics of the
  # athanors they made and assert on what those carry.
  use ExUnit.Case, async: false

  alias Aqua.Crew.Activity
  alias Aqua.Providers.Thread, as: Provider
  alias Aqua.{Tape, ThreadList}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.{CrewActivity, SharedThreadChanged, ThreadListed}
  alias Cyfr.Test.ShareFixtures
  alias Prima.Canvas.Shape
  alias Sanctum.SharedThreads

  @task "TASK-TEXT-5e0b"
  @said "SAID-IN-ROOM-91c2"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "aqua_streams_#{System.unique_integer([:positive])}")
    # The restore is registered before the change.
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf!(test_path) end)

    {:ok, ada: ShareFixtures.person!("Ada"), bob: ShareFixtures.person!("Bob")}
  end

  describe "the declarations" do
    test "the provider declares the two streams, each shaped and refreshed", %{ada: ada} do
      assert Enum.map(Provider.streams(), & &1.name) == ["threads.changes", "activity.changes"]

      for stream <- Provider.streams() do
        assert Prima.Provider.Stream.valid?(stream), stream.name
        assert stream.deadline_bound == 86_400
        assert stream.filter == nil
        assert {:ok, stream.shape} == Shape.validate(stream.shape)
        assert Enum.sort(Map.keys(stream.shape["fields"])) == Enum.sort(stream.projection)
        assert Enum.sort(stream.shape["required"]) == Enum.sort(stream.projection)
        {module, function} = stream.refresh
        assert Code.ensure_loaded?(module) and function_exported?(module, function, 2)
        assert {:ok, {Provider, ^stream}} = Sanctum.Catalog.lookup_stream(stream.name)
      end

      [threads, activity] = Provider.streams()

      assert {threads.topic, threads.bind} == {:threads, :holder}
      assert threads.refresh == {ThreadList, :listed}
      assert threads.projection == ~w(kind id title people last_activity waits_on_you unread)
      assert threads.shape["fields"]["kind"]["values"] == ["own", "shared", "removed"]
      assert Prima.Provider.Stream.admits?(threads, ada.user.id)
      refute Prima.Provider.Stream.admits?(threads, nil)

      # A removal carries its kind and id alone, and an own thread keeps no read mark.
      for field <- ~w(title people last_activity waits_on_you unread),
          do: assert(threads.shape["fields"][field]["nullable"], field)

      assert threads.shape["fields"]["unread"] == %{"type" => "integer", "nullable" => true}

      assert {activity.topic, activity.subject, activity.bind} == {:crew_activity, nil, nil}
      assert activity.refresh == {Activity, :open}
      assert activity.projection == ~w(kind id member asked_by title since status)

      assert activity.shape["fields"]["title"] == %{
               "type" => "string",
               "max" => 64,
               "nullable" => true
             }

      assert activity.shape["fields"]["kind"]["values"] == ["started", "ended"]
      assert activity.shape["fields"]["status"]["values"] == Prima.TurnState.statuses()
    end
  end

  describe "a person's own threads" do
    test "a create, a message that titles it and a delete each reach the person's list",
         %{ada: ada} do
      listen(ada)

      {:ok, %{id: id}} = call(ada.ctx, %{"action" => "create"})

      assert %{
               "kind" => "own",
               "id" => ^id,
               "title" => "New thread",
               "people" => ["Ada"],
               "waits_on_you" => false,
               "unread" => nil,
               "last_activity" => created
             } = heard(ada, id)

      {:ok, _} = say(ada, id, "Ship the plan\n" <> @said)
      assert %{"title" => "Ship the plan", "last_activity" => moved} = said = heard(ada, id)
      assert later_or_same?(moved, created)
      refute inspect(said) =~ @said

      {:ok, %{deleted: true}} = call(ada.ctx, %{"action" => "delete", "thread" => id})
      assert_receive %ThreadListed{kind: :removed, id: ^id} = removed

      assert read_as(removed) == %{
               "kind" => "removed",
               "id" => id,
               "title" => nil,
               "people" => nil,
               "last_activity" => nil,
               "waits_on_you" => nil,
               "unread" => nil
             }

      # A later announcement reads the thread gone and says nothing.
      assert :ok = ThreadList.changed(ada.ctx, id)
      refute_receive %ThreadListed{}, 200
    end

    test "a card opened and decided moves whether the thread waits on its person", %{ada: ada} do
      {:ok, room} = Threads.create(ada.actor)
      listen(ada)

      room_id = room.id
      %{approval: approval} = card!(ada.ctx, room)
      assert_receive %ThreadListed{id: ^room_id, waits_on_you: true} = waiting
      assert %{"waits_on_you" => true} = read_as(waiting)

      assert {:ok, _} = Aqua.Approvals.resolve(ada.ctx, approval.id, %{decision: :declined})
      assert_receive %ThreadListed{id: ^room_id, waits_on_you: false}
    end

    test "a crew member's child thread is never on the list", %{ada: ada} do
      {:ok, room} = Threads.create(ada.actor)
      {:ok, child} = Threads.crew_thread(ada.actor, room.id, "planner")
      listen(ada)

      {:ok, _} = job!(ada, child, "planner")
      assert :ok = ThreadList.changed(ada.ctx, child.id)

      child_id = child.id
      refute_receive %ThreadListed{id: ^child_id}, 200
    end
  end

  describe "a shared thread" do
    test "made, joined, posted in, left and archived moves each of its people's own lists",
         %{ada: ada, bob: bob} do
      listen(ada)
      listen(bob)

      {:ok, thread} = SharedThreads.create(ada.user.id, "Trip")

      assert %{
               "kind" => "shared",
               "title" => "Trip",
               "people" => ["Ada"],
               "waits_on_you" => false
             } =
               heard(ada, thread.id)

      bobs_athanor = bob.athanor.id
      refute_receive %ThreadListed{athanor_id: ^bobs_athanor}, 200

      {:ok, :added} = SharedThreads.add(ada.user.id, thread.id, user_id: bob.user.id)
      assert %{"people" => ["Ada", "Bob"], "last_activity" => joined} = heard(ada, thread.id)
      assert %{"kind" => "shared", "people" => ["Ada", "Bob"]} = heard(bob, thread.id)

      {:ok, _} = SharedThreads.post(bob.user.id, thread.id, @said)
      assert %{"last_activity" => posted} = said = heard(ada, thread.id)
      assert later_or_same?(posted, joined)
      assert %{"last_activity" => ^posted} = heard(bob, thread.id)
      refute inspect(said) =~ @said

      {:ok, _} = SharedThreads.leave(bob.user.id, thread.id)
      assert %{"kind" => "removed", "id" => id, "title" => nil} = heard(bob, thread.id)
      assert id == thread.id
      assert %{"kind" => "shared", "people" => ["Ada"]} = heard(ada, thread.id)

      {:ok, _} = SharedThreads.archive(ada.user.id, thread.id)
      assert %{"kind" => "removed"} = heard(ada, thread.id)
      refute_receive %ThreadListed{}, 200
    end

    test "another's post is unread to a person until their own read mark moves, told to them alone",
         %{ada: ada, bob: bob} do
      {:ok, thread} = SharedThreads.create(ada.user.id, "Trip")
      {:ok, :added} = SharedThreads.add(ada.user.id, thread.id, user_id: bob.user.id)
      thread_id = thread.id
      listen(ada)
      listen(bob)
      for person <- [ada, bob], do: :ok = Cyfr.Bus.subscribe_global(changes(person))

      {:ok, _} = SharedThreads.post(bob.user.id, thread.id, @said)
      assert %{"unread" => 1} = heard(ada, thread_id)
      assert %{"unread" => 0} = heard(bob, thread_id)

      {:ok, _} = SharedThreads.post(bob.user.id, thread.id, @said)
      assert %{"unread" => 2} = heard(ada, thread_id)
      assert %{"unread" => 0} = heard(bob, thread_id)
      flush_changes()

      assert :ok = SharedThreads.mark_read(ada.user.id, thread_id)

      ada_id = ada.user.id
      assert_receive %SharedThreadChanged{kind: :read, user_id: ^ada_id, thread_id: ^thread_id}
      read = heard(ada, thread_id)

      assert %{"kind" => "shared", "id" => ^thread_id, "title" => "Trip", "unread" => 0} = read

      text = inspect(read)

      for secret <- [@said, ada.user.id, bob.user.id, ada.user.email, bob.user.email],
          do: refute(text =~ secret)

      bobs_athanor = bob.athanor.id
      refute_receive %ThreadListed{athanor_id: ^bobs_athanor}, 200
      refute_receive %SharedThreadChanged{}, 100

      # A mark that stood announces nothing.
      assert :ok = SharedThreads.mark_read(ada.user.id, thread_id)
      refute_receive %ThreadListed{}, 200
      refute_receive %SharedThreadChanged{}, 100
    end
  end

  # The canvas wire's vectors (tests/fixtures/tincture_wire.json), whose
  # `stream_events` hold this stream's events as a canvas reads them.
  @wire Path.expand("../../../../tests/fixtures/tincture_wire.json", __DIR__)

  describe "the wire's thread events" do
    test "are a shared thread's and an own thread's payloads, read back whole as a canvas reads them",
         %{ada: ada} do
      vectors = @wire |> File.read!() |> Jason.decode!()
      events = for %{"event" => event} <- vectors["stream_events"]["threads.changes"], do: event

      assert [%{"kind" => "shared", "unread" => unread}, %{"kind" => "own", "unread" => nil}] =
               events

      assert is_integer(unread) and unread > 0

      actor = Prima.Actor.in_athanor(ada.athanor.id)

      for event <- events do
        {:ok, last_activity, 0} = DateTime.from_iso8601(event["last_activity"])

        payload =
          ThreadListed.new(actor, String.to_existing_atom(event["kind"]),
            id: event["id"],
            title: event["title"],
            people: event["people"],
            last_activity: last_activity,
            unread: event["unread"],
            waits_on_you: event["waits_on_you"]
          )

        assert read_as(payload) == event
      end
    end
  end

  describe "one person's list" do
    test "a second person never hears another's list", %{ada: ada, bob: bob} do
      listen(bob)

      {:ok, %{id: own}} = call(ada.ctx, %{"action" => "create", "title" => "Mine"})
      {:ok, _} = say(ada, own, "hello")
      {:ok, alone} = SharedThreads.create(ada.user.id, "Alone")
      {:ok, _} = SharedThreads.post(ada.user.id, alone.id, "hi")
      {:ok, %{deleted: true}} = call(ada.ctx, %{"action" => "delete", "thread" => own})

      refute_receive %ThreadListed{}, 300

      assert {:ok, []} = ThreadList.listed(bob.ctx, bob.user.id)
    end
  end

  describe "the threads' refresh" do
    test "is the athanor's own threads and the active shared ones, the latest first",
         %{ada: ada, bob: bob} do
      carol = ShareFixtures.person!("Carol")

      {:ok, _} =
        Arca.Users.update(Prima.Actor.system(), carol.user.id, %{
          display_name: nil,
          namespace: "carol-#{System.unique_integer([:positive])}"
        })

      {:ok, %{id: plans}} = call(ada.ctx, %{"action" => "create", "title" => "Plans"})
      {:ok, %{id: waiting}} = call(ada.ctx, %{"action" => "create", "title" => "Waiting"})

      {:ok, _card} =
        Threads.append(ada.actor, waiting, %{
          author: Prima.Author.system(),
          sent_by: "aqua",
          kind: "approval",
          status: "pending",
          content: "Run it?"
        })

      {:ok, child} = Threads.crew_thread(ada.actor, plans, "planner")

      {:ok, trip} = SharedThreads.create(ada.user.id, "Trip")
      {:ok, :added} = SharedThreads.add(ada.user.id, trip.id, user_id: bob.user.id)
      {:ok, :added} = SharedThreads.add(ada.user.id, trip.id, user_id: carol.user.id)
      {:ok, _} = SharedThreads.post(bob.user.id, trip.id, @said)

      {:ok, old} = SharedThreads.create(ada.user.id, "Old")
      {:ok, _} = SharedThreads.archive(ada.user.id, old.id)

      {:ok, %{id: bobs}} = call(bob.ctx, %{"action" => "create", "title" => "Bob's"})

      assert {:ok, items} = ThreadList.listed(ada.ctx, ada.user.id)
      wired = Enum.map(items, &read_as/1)

      assert Enum.map(wired, & &1["id"]) == [trip.id, waiting, plans]
      ids = Enum.map(wired, & &1["id"])
      refute child.id in ids
      refute old.id in ids
      refute bobs in ids

      [shared, card, own] = wired

      assert %{"kind" => "shared", "title" => "Trip", "waits_on_you" => false} = shared
      assert ["Ada", "Bob", "@" <> _handle] = shared["people"]
      assert %{"kind" => "own", "title" => "Waiting", "waits_on_you" => true} = card
      assert %{"kind" => "own", "title" => "Plans", "people" => ["Ada"]} = own

      times = Enum.map(wired, &elem(DateTime.from_iso8601(&1["last_activity"]), 1))
      assert times == Enum.sort(times, {:desc, DateTime})

      text = inspect(items)

      for secret <-
            [@said, ada.user.email, bob.user.email, carol.user.email] ++
              Enum.map([ada, bob, carol], & &1.user.id) do
        refute text =~ secret
      end

      assert {:error, :no_athanor} = ThreadList.listed(%{ada.ctx | athanor_id: nil}, ada.user.id)
    end
  end

  describe "the crew's activity" do
    setup %{ada: ada} do
      {:ok, room} = Threads.create(ada.actor)
      {:ok, planner} = Threads.crew_thread(ada.actor, room.id, "planner")
      {:ok, scout} = Threads.crew_thread(ada.actor, room.id, "scout")
      actor = Sanctum.Context.actor(ada.ctx)
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.crew_activity(actor))
      {:ok, room: room, planner: planner, scout: scout}
    end

    test "a job accepted, started and finished is announced as it moves", %{
      ada: ada,
      planner: planner
    } do
      {:ok, %{turn: turn}} = job!(ada, planner, "planner")

      assert_receive %CrewActivity{kind: :started} = accepted

      assert %{
               "kind" => "started",
               "member" => "planner",
               "asked_by" => "Ada",
               "status" => "accepted",
               "since" => since
             } = read_as(accepted)

      assert {:ok, _, 0} = DateTime.from_iso8601(since)

      running = rooted!(ada.ctx, turn)
      assert_receive %CrewActivity{kind: :started} = started
      assert %{"status" => "running", "since" => ^since} = read_as(started)

      {:ok, _} = Tape.finish(ada.ctx, running, "failed", %{error: "it broke"})
      assert_receive %CrewActivity{kind: :ended} = ended

      assert %{"kind" => "ended", "member" => "planner", "status" => "failed", "since" => ^since} =
               read_as(ended)

      for payload <- [accepted, started, ended] do
        text = inspect(payload)
        refute text =~ @task
        refute text =~ ada.user.id
        refute text =~ ada.user.email
      end
    end

    test "the soul's turn is no job, and who asked reads as the console names them", %{
      ada: ada,
      room: room,
      planner: planner,
      scout: scout
    } do
      {:ok, %{turn: %{agent: "aqua"}}} =
        Tape.accept(ada.ctx, room.id, %{
          message: %{author: ada.user.id, sent_by: "person", content: @task},
          turn: %{agent: "aqua", requested_by: ada.user.id}
        })

      refute_receive %CrewActivity{}, 200

      {:ok, _} = job!(ada, scout, "scout", "aqua")
      assert_receive %CrewActivity{member: "scout"} = by_soul
      assert %{"asked_by" => "AQUA"} = read_as(by_soul)

      {:ok, _} = job!(ada, planner, "planner", "scout")
      assert_receive %CrewActivity{member: "planner"} = by_member
      assert %{"asked_by" => "scout"} = read_as(by_member)
    end

    test "an archive and a room's deletion end the jobs they cancelled", %{
      ada: ada,
      room: room,
      planner: planner,
      scout: scout
    } do
      {:ok, _} = job!(ada, planner, "planner")
      {:ok, _} = job!(ada, scout, "scout")
      assert_receive %CrewActivity{kind: :started, member: "planner"}
      assert_receive %CrewActivity{kind: :started, member: "scout"}

      {:ok, %{archived: true}} = call(ada.ctx, %{"action" => "archive", "thread" => planner.id})
      assert_receive %CrewActivity{kind: :ended, member: "planner"} = archived
      assert %{"status" => "cancelled", "asked_by" => "Ada"} = read_as(archived)

      {:ok, %{deleted: true}} = call(ada.ctx, %{"action" => "delete", "thread" => room.id})
      assert_receive %CrewActivity{kind: :ended, member: "scout"} = deleted
      assert %{"status" => "cancelled"} = read_as(deleted)
      refute_receive %CrewActivity{}, 200
    end

    test "a job a request opened carries the request's title as it moves, and a job no request opened carries none",
         %{ada: ada, room: room, planner: planner, scout: scout} do
      {:ok, %{turn: turn}} = requested_job!(ada, room, planner, "planner", "Risks")
      assert_receive %CrewActivity{kind: :started} = accepted
      assert %{"title" => "Risks", "status" => "accepted"} = read_as(accepted)
      assert {:ok, [listed]} = Activity.open(ada.ctx, nil)
      assert %{"title" => "Risks"} = read_as(listed)

      running = rooted!(ada.ctx, turn)
      assert_receive %CrewActivity{kind: :started} = started
      assert %{"title" => "Risks", "status" => "running"} = read_as(started)

      {:ok, _} = Tape.finish(ada.ctx, running, "failed", %{error: "it broke"})
      assert_receive %CrewActivity{kind: :ended} = ended
      assert %{"title" => "Risks", "status" => "failed"} = read_as(ended)

      {:ok, _} = requested_job!(ada, room, scout, "scout", "Scout it")
      assert_receive %CrewActivity{kind: :started, member: "scout"}
      {:ok, %{archived: true}} = call(ada.ctx, %{"action" => "archive", "thread" => scout.id})
      assert_receive %CrewActivity{kind: :ended, member: "scout"} = archived
      assert %{"title" => "Scout it", "status" => "cancelled"} = read_as(archived)

      {:ok, _} = job!(ada, planner, "planner")
      assert_receive %CrewActivity{kind: :started, member: "planner"} = untitled
      assert %{"title" => nil} = read_as(untitled)
    end

    test "the documented activity key preserves simultaneous jobs", %{ada: ada, planner: planner} do
      {:ok, other_room} = Threads.create(ada.actor)
      {:ok, other_planner} = Threads.crew_thread(ada.actor, other_room.id, "planner")
      {:ok, %{turn: first}} = job!(ada, planner, "planner")
      {:ok, %{turn: second}} = job!(ada, other_planner, "planner")

      assert {:ok, items} = Activity.open(ada.ctx, nil)
      jobs = items |> Enum.map(&read_as/1) |> Enum.filter(&(&1["member"] == "planner"))
      assert length(jobs) == 2

      # The guide keys a crew job by its `id`, which the stream carries, so
      # one member's two jobs at once stay two.
      guide = File.read!(Path.expand("../../../../integration-guide.md", __DIR__))
      assert guide =~ "a crew job's by `id`"
      assert map_size(Map.new(jobs, &{&1["id"], &1})) == 2
      assert Enum.sort(Enum.map(jobs, & &1["id"])) == Enum.sort([first.id, second.id])

      live =
        for _ <- 1..2 do
          assert_receive %CrewActivity{kind: :started} = started
          read_as(started)["id"]
        end

      assert Enum.sort(live) == Enum.sort([first.id, second.id])
    end

    test "the refresh is every open job, oldest first, and no job once it ended", %{
      ada: ada,
      room: room,
      planner: planner,
      scout: scout
    } do
      {:ok, %{turn: first}} = job!(ada, planner, "planner")
      {:ok, %{turn: _second}} = job!(ada, scout, "scout", "aqua")

      {:ok, _soul} =
        Tape.accept(ada.ctx, room.id, %{
          message: %{author: ada.user.id, sent_by: "person", content: "hi"},
          turn: %{agent: "aqua", requested_by: ada.user.id}
        })

      assert {:ok, items} = Activity.open(ada.ctx, nil)
      wired = Enum.map(items, &read_as/1)

      assert [
               %{"kind" => "started", "member" => "planner", "asked_by" => "Ada"},
               %{"kind" => "started", "member" => "scout", "asked_by" => "AQUA"}
             ] = wired

      assert Enum.all?(wired, &(&1["status"] == "accepted"))
      refute inspect(items) =~ @task

      {:ok, _} = Tape.finish(ada.ctx, first, "cancelled")
      assert {:ok, [%CrewActivity{member: "scout"}]} = Activity.open(ada.ctx, nil)

      assert {:ok, []} = Activity.open(foreign(ada.ctx), nil)
      assert {:error, :no_athanor} = Activity.open(%{ada.ctx | athanor_id: nil}, nil)
    end
  end

  # ---------------------------------------------------------------------------

  defp call(ctx, args), do: Provider.handle("thread", ctx, args)

  defp listen(person) do
    actor = Sanctum.Context.actor(person.ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.threads(actor, person.user.id))
  end

  defp changes(person), do: Cyfr.Bus.shared_threads(person.user.id)

  # The shared-thread changes already heard: a case asserts on the ones
  # its next act makes.
  defp flush_changes do
    receive do
      %SharedThreadChanged{} -> flush_changes()
    after
      0 -> :ok
    end
  end

  # A person's line into their own thread, opening no turn.
  defp say(person, thread_id, text) do
    Tape.accept(person.ctx, thread_id, %{
      message: %{author: person.user.id, sent_by: "person", content: text}
    })
  end

  # A job for `member` in its child thread, sent by `sent_by`: the person
  # or an agent.
  defp job!(person, thread, member, sent_by \\ "person") do
    author = if sent_by == "person", do: person.user.id, else: Prima.Author.agent()

    Tape.accept(person.ctx, thread.id, %{
      message: %{author: author, sent_by: sent_by, content: @task},
      turn: %{agent: member, requested_by: person.user.id}
    })
  end

  # A job for `member` in its child thread opened by the soul's request in
  # `room`, its title kept on the request as `crew.ask` keeps it.
  defp requested_job!(person, room, thread, member, title) do
    {:ok, %{message: request}} =
      Tape.accept(person.ctx, room.id, %{
        message: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          addressee: member,
          status: "pending",
          content: @task,
          payload: %{"title" => title}
        }
      })

    Tape.accept(person.ctx, thread.id, %{
      message: %{author: Prima.Author.agent(), sent_by: "aqua", content: @task},
      turn: %{agent: member, requested_by: person.user.id},
      reply_address: %{asking_thread_id: room.id, request_id: request.id}
    })
  end

  # The next announcement of `id` on `person`'s own list, as a canvas reads it.
  defp heard(person, id) do
    athanor_id = person.athanor.id
    assert_receive %ThreadListed{athanor_id: ^athanor_id, id: ^id} = payload
    read_as(payload)
  end

  # A refresh item or a live payload as a canvas reads it on the stream
  # its topic feeds: projected by the grant, passed through JSON, and held
  # to the declared shape.
  defp read_as(%module{} = payload) do
    name = if module == ThreadListed, do: "threads.changes", else: "activity.changes"
    {:ok, {Provider, stream}} = Sanctum.Catalog.lookup_stream(name)

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: nil,
      deadline: DateTime.utc_now(),
      grant_id: "sgr_aqua_streams"
    }

    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    data
  end

  defp later_or_same?(later, earlier) do
    {:ok, later, 0} = DateTime.from_iso8601(later)
    {:ok, earlier, 0} = DateTime.from_iso8601(earlier)
    DateTime.compare(later, earlier) != :lt
  end

  defp foreign(ctx),
    do: %{ctx | athanor_id: "ath_streams_foreign", user_id: "usr_streams_stranger"}

  # A turn rooted and started as the loop starts it.
  defp rooted!(ctx, turn) do
    n = System.unique_integer([:positive])

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_streams_#{n}",
          reference: "agent:local.#{turn.agent}",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: "bgt_streams_#{n}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, started} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

    started
  end

  # A card as the loop opens it: the soul's turn with its root, the model
  # step, the call, and the approval on the tape.
  defp card!(ctx, room) do
    proposal = %{"tool" => "component", "action" => "delete", "args" => %{}}

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, room.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "@aqua wipe it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn = rooted!(ctx, turn)
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "component.delete",
            tool: "component",
            action: "delete",
            arguments: %{},
            kind: "destructive"
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "Wipe it",
      "action_kind" => "destructive",
      "proposal" => proposal,
      "tool_call_id" => "c1"
    }

    {:ok, opened} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: intent["title"], payload: %{"intent" => intent}}
      })

    opened
  end
end
