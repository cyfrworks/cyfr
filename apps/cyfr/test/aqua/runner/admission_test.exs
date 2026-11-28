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
    job = %{options: %{}}

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

    # A request setting other brain options is a turn of its own.
    refute Runner.steer?(turn, %{send | job: %{job | options: %{"effort" => "high"}}})

    # A turn whose row names no sender is steered by nobody.
    refute Runner.steer?(%{turn | sent_by: nil}, %{send | sent_by: nil})
  end
end

defmodule Aqua.Runner.AdmissionRoomsTest do
  @moduledoc """
  Where a send is admitted, by the kind of the thread it lands in: a
  person's rooms are daily and workspace threads, which take their
  person's line to the soul, a crew member's reply and the soul's
  requests alike; a crew member's thread takes no line of the person's;
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
  @names "@planner look into it"

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

  test "a schedule's fire is a turn of the soul in a daily or a workspace thread, and admitted in no crew thread",
       %{ctx: ctx} do
    fired = Sanctum.TestContext.via(ctx, :schedule)

    # A daily thread, or the workspace thread a turn there set it from.
    for room <- [@daily, @workspace] do
      assert {:ok, {:turn, "aqua"}, "summarise"} = check(fired, room, "summarise", @fire)

      # Whatever names its line holds: nobody present asks no crew member.
      assert {:ok, {:turn, "aqua"}, _} =
               check(fired, room, "@planner summarise", @fire)
    end

    assert {:error, :not_addressable} = check(fired, @crew, "summarise", @fire)

    # A fire is the schedule's own origin's, and a person's send is none.
    assert {:error, :not_addressable} = check(ctx, @daily, "summarise", @fire)
  end

  test "a person's line in a daily or a workspace thread is the soul's turn, whatever names it holds",
       %{ctx: ctx} do
    for room <- [@daily, @workspace] do
      assert {:ok, {:turn, "aqua"}, "hello"} = check(ctx, room, "hello", [])

      # A member's name is words to the soul, kept as they are: only the
      # soul's hand-off asks the member.
      assert {:ok, {:turn, "aqua"}, @names} = check(ctx, room, @names, [])
      assert {:ok, {:turn, "aqua"}, "plan it"} = check(ctx, room, "plan it", agent: "planner")

      assert :ok = Admission.request(room, "aqua", "planner", @roster)
    end
  end

  test "a crew member's thread admits no line of the person's", %{ctx: ctx} do
    for text <- ["go on", "@planner go on", "@aqua hello"] do
      assert {:error, :not_addressable} = check(ctx, @crew, text, [])
    end

    assert {:error, :not_addressable} = check(ctx, @crew, "go on", agent: "planner")
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

      # Every reply is the soul's turn: to a request of the soul's, and to
      # a request row the person sent a member themselves.
      assert {:ok, {:turn, "aqua"}, "done"} = check(ctx, room, "done", asked_by.("person"))
      assert {:ok, {:turn, "aqua"}, "done"} = check(ctx, room, "done", asked_by.("aqua"))
      assert {:error, :not_addressable} = check(ctx, room, "done", asked_by.("builder"))

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
