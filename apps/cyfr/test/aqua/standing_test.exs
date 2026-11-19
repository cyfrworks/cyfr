# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.StandingTest do
  @moduledoc """
  Whether a card's answer may stand for calls nobody has seen yet: an
  external or destructive action takes no standing allow, whatever its
  own standing rule says, and answers for this call alone or a standing
  deny stay open to it. An answer for a schedule is agent-wide, names its
  schedule, and is held to the rule of an answer for one thread.
  """

  use ExUnit.Case, async: true

  alias Aqua.Standing

  # The intent a card carries, in the wire shape the decision reads.
  defp intent(kind, standing \\ nil),
    do: %{"tool" => "t", "action" => "a", "action_kind" => kind, "standing" => standing}

  test "an external card takes neither a thread nor an always answer" do
    for scope <- [:thread, :always], standing <- [nil, "thread"] do
      assert {:error, {:scope_not_permitted, "external"}} =
               Standing.check(intent("external", standing), scope)
    end
  end

  test "an external card is still answered once, or denied for good" do
    for scope <- [:once, :never] do
      assert :ok = Standing.check(intent("external"), scope)
    end
  end

  test "a destructive card takes no standing allow either" do
    for scope <- [:thread, :always] do
      assert {:error, {:scope_not_permitted, "destructive"}} =
               Standing.check(intent("destructive"), scope)
    end
  end

  test "a write with no standing rule of its own may stand for the thread or always" do
    for scope <- [:thread, :always] do
      assert :ok = Standing.check(intent("write"), scope)
    end
  end

  describe "an answer for a schedule" do
    @for_schedule %{lifecycle: :schedule, schedule: "sched_1"}

    test "is offered where an answer for one thread is, and held to that rule though agent-wide" do
      for standing <- [nil, "thread"] do
        intent = intent("write", standing)
        assert Standing.offered?(intent, :schedule)
        assert :ok = Standing.check(intent, :always, @for_schedule)
        assert Standing.offered?(intent, :schedule) == Standing.offered?(intent, :thread)
      end

      # One for one thread only is still none agent-wide without it.
      thread_only = intent("write", "thread")
      refute Standing.offered?(thread_only, :always)

      assert {:error, {:scope_not_permitted, :thread_only}} =
               Standing.check(thread_only, :always, %{})
    end

    test "is offered for no action that never stands, and for no destructive or external one" do
      for {intent, reason} <- [
            {intent("write", false), :never_standing},
            {intent("destructive"), "destructive"},
            {intent("external", "thread"), "external"}
          ] do
        refute Standing.offered?(intent, :schedule)

        assert {:error, {:scope_not_permitted, ^reason}} =
                 Standing.check(intent, :always, @for_schedule)
      end
    end

    test "is agent-wide and names its schedule; any other spelling is refused before a row is built" do
      ctx = Sanctum.TestContext.local()
      turn = %{id: "turn_1", thread_id: "thread_1", agent: "aqua", root_execution_id: "exec_1"}
      proposal = %{"tool" => "files", "action" => "write"}

      for {scope, bounds, reason} <- [
            {:thread, %{lifecycle: :schedule}, :no_schedule},
            {:thread, @for_schedule, :invalid_lifecycle},
            {:always, %{lifecycle: :schedule}, :no_schedule},
            {:always, %{lifecycle: :turn, schedule: "sched_1"}, :invalid_lifecycle},
            {:once, @for_schedule, :bounds_without_standing},
            {:never, @for_schedule, :bounded_deny}
          ] do
        assert Standing.rows(ctx, turn, proposal, scope, bounds) ==
                 {:error, {:scope_not_permitted, reason}},
               "#{scope} #{inspect(bounds)} was not refused as #{reason}"
      end
    end
  end

  describe "an HTTP post, put or patch to a destination outside the home" do
    setup do
      {:ok, ctx: Sanctum.TestContext.local()}
    end

    test "is refused at the write of its standing row, at either scope", %{ctx: ctx} do
      turn = %{thread_id: "thread_1", agent: "aqua"}

      for action <- ~w(post put patch), scope <- [:thread, :always] do
        proposal = %{"tool" => "http", "action" => action}

        assert {:error, {:scope_not_permitted, :external}} =
                 Standing.rows(ctx, turn, proposal, scope),
               "http.#{action} wrote a #{scope} standing row"
      end
    end
  end
end
