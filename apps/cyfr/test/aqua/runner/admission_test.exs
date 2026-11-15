# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Runner.AdmissionTest do
  @moduledoc """
  Who may address whom, and what steers a turn: only the soul's turn in a
  room asks a crew member, and a send joins a turn only when its user,
  sender, agent and origin are all the turn's.
  """

  use ExUnit.Case, async: true

  alias Aqua.Runner
  alias Aqua.Runner.Admission

  @roster [
    %{"name" => "aqua", "title" => "Aqua"},
    %{"name" => "planner", "title" => "Planner"},
    %{"name" => "builder", "title" => "Builder"}
  ]

  @room %{id: "thread_room", kind: "daily", parent_id: nil, agent: "aqua"}
  @child %{id: "thread_child", kind: "crew", parent_id: "thread_room", agent: "planner"}

  test "the soul's turn in a room may ask any crew member, and nobody else asks" do
    assert :ok = Admission.request(@room, "aqua", "planner", @roster)
    assert :ok = Admission.request(@room, "aqua", "builder", @roster)

    assert {:error, :not_addressable} = Admission.request(@room, "aqua", "aqua", @roster)
    assert {:error, :not_addressable} = Admission.request(@room, "aqua", "stranger", @roster)
    assert {:error, :not_addressable} = Admission.request(@room, "planner", "builder", @roster)
    assert {:error, :not_addressable} = Admission.request(@child, "planner", "builder", @roster)
    assert {:error, :not_addressable} = Admission.request(@child, "aqua", "builder", @roster)
  end

  test "a crew member is an agent of the roster that is not the soul" do
    assert Admission.member?(@roster, "planner")
    refute Admission.member?(@roster, "aqua")
    refute Admission.member?(@roster, "nobody")
    refute Admission.member?(@roster, nil)
  end

  test "a send steers a turn only with the turn's user, sender, agent, origin and job" do
    job = %{tools: nil, options: %{}}

    turn = %{
      user_id: "usr_a",
      sent_by: "person",
      agent: "planner",
      origin: "interactive",
      job: job
    }

    send = %{
      user_id: "usr_a",
      sent_by: "person",
      agent: "planner",
      origin: :interactive,
      job: job
    }

    assert Runner.steer?(turn, send)
    refute Runner.steer?(turn, %{send | user_id: "usr_b"})
    refute Runner.steer?(turn, %{send | sent_by: "aqua"})
    refute Runner.steer?(turn, %{send | agent: "builder"})
    refute Runner.steer?(turn, %{send | origin: :programmatic})
    refute Runner.steer?(turn, %{send | origin: nil})

    # One policy per turn: a request narrowed otherwise, or setting other
    # brain options, is a turn of its own.
    refute Runner.steer?(turn, %{send | job: %{job | tools: ["files.read"]}})
    refute Runner.steer?(turn, %{send | job: %{job | options: %{"effort" => "high"}}})

    # A turn whose row names no sender is steered by nobody.
    refute Runner.steer?(%{turn | sent_by: nil}, %{send | sent_by: nil})
  end
end

defmodule Aqua.Runner.AdmissionRoomsTest do
  @moduledoc """
  Where a send is admitted, by the kind of the thread it lands in: a
  person's rooms are daily and workspace threads, which take their
  person's address, a crew member's reply and the soul's requests alike;
  a schedule's fire is admitted in a daily thread and in no other kind.
  Admission reads the athanor's standing, so the sender is a person in
  their own athanor.
  """

  use ExUnit.Case, async: false

  alias Aqua.Runner.Admission

  @roster [
    %{"name" => "aqua", "title" => "Aqua"},
    %{"name" => "planner", "title" => "Planner"}
  ]

  @daily %{id: "thread_daily", kind: "daily", parent_id: nil, agent: nil}
  @workspace %{id: "thread_workspace", kind: "workspace", parent_id: nil, agent: nil}
  @crew %{id: "thread_crew", kind: "crew", parent_id: "thread_daily", agent: "planner"}
  @fire [schedule: %{schedule_id: "sched_x", occurrence_id: "occ_x"}]

  setup do
    Cyfr.Test.Sandbox.setup!()
    {ctx, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    {:ok, ctx: %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id}}
  end

  defp check(ctx, thread, text, opts),
    do: Admission.check(ctx, ctx.athanor_id, thread, text, opts)

  test "a schedule's fire is a turn of the soul in a daily thread, and admitted in no other kind",
       %{ctx: ctx} do
    fired = Sanctum.TestContext.via(ctx, :schedule)

    assert {:ok, {:turn, "aqua"}, "summarise"} = check(fired, @daily, "summarise", @fire)

    # Whatever names its line holds: nobody present asks no crew member.
    assert {:ok, {:turn, "aqua"}, _} =
             check(fired, @daily, "@planner summarise", [{:agents, @roster} | @fire])

    for thread <- [@workspace, @crew] do
      assert {:error, :not_addressable} = check(fired, thread, "summarise", @fire), thread.kind
    end

    # A fire is the schedule's own origin's, and a person's send is none.
    assert {:error, :not_addressable} = check(ctx, @daily, "summarise", @fire)
  end

  test "a person's line in a daily or a workspace thread addresses the soul, or the crew member it names",
       %{ctx: ctx} do
    for room <- [@daily, @workspace] do
      assert {:ok, {:turn, "aqua"}, "hello"} = check(ctx, room, "hello", agents: @roster)

      assert {:ok, {:request, "planner"}, _} =
               check(ctx, room, "@planner look into it", agents: @roster)

      assert :ok = Admission.request(room, "aqua", "planner", @roster)
    end

    # In a crew member's thread the person speaks to that member alone.
    assert {:ok, {:turn, "planner"}, _} = check(ctx, @crew, "go on", agents: @roster)
    assert {:error, :not_addressable} = check(ctx, @crew, "@aqua hello", agents: @roster)
  end

  test "a crew member's reply lands in the daily or workspace thread that asked it, and in no crew thread",
       %{ctx: ctx} do
    for room <- [@daily, @workspace] do
      asked_by = fn sent_by ->
        [
          sent_by: "planner",
          reply: %{request: %{thread_id: room.id, addressee: "planner", sent_by: sent_by}}
        ]
      end

      # A reply to the person is the room's content; to the soul, its turn.
      assert {:ok, :content, "done"} = check(ctx, room, "done", asked_by.("person"))
      assert {:ok, {:turn, "aqua"}, "done"} = check(ctx, room, "done", asked_by.("aqua"))

      # A reply to a request of another thread, or by another member, is
      # nowhere to land.
      assert {:error, :not_addressable} =
               check(ctx, %{room | id: "thread_elsewhere"}, "done", asked_by.("person"))

      assert {:error, :not_addressable} =
               check(ctx, room, "done", Keyword.put(asked_by.("person"), :sent_by, "builder"))
    end

    reply = %{request: %{thread_id: @crew.id, addressee: "planner", sent_by: "person"}}

    assert {:error, :not_addressable} =
             check(ctx, @crew, "done", sent_by: "planner", reply: reply)
  end
end
