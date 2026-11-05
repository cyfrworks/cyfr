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
    %{"name" => "aqua", "title" => "AQUA"},
    %{"name" => "planner", "title" => "Planner"},
    %{"name" => "builder", "title" => "Builder"}
  ]

  @room %{id: "thread_room", kind: "own", parent_id: nil, agent: "aqua"}
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
