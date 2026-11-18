# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Question.CallerTest do
  @moduledoc """
  The caller's text: every caller round-trips, split at the first colon;
  `any` and malformed texts are refused; a stored null reads as unknown;
  and the nearest starter wins in its fixed order.
  """

  use ExUnit.Case, async: true

  alias Prima.Question.Caller

  @callers [
    :person,
    :unknown,
    {:device, "pcl_1"},
    {:tincture, "tincture:local.notes:1.0.0"},
    {:agent, "helper"},
    {:schedule, "sch_1"},
    {:webhook, "whk_1"},
    {:key, "key_1"}
  ]

  test "every caller round-trips through its text" do
    for caller <- @callers do
      assert Caller.caller?(caller)
      assert Caller.decode(Caller.encode(caller)) == {:ok, caller}
    end

    assert Enum.map(@callers, &Caller.encode/1) == [
             "person",
             "unknown",
             "device:pcl_1",
             "tincture:tincture:local.notes:1.0.0",
             "agent:helper",
             "schedule:sch_1",
             "webhook:whk_1",
             "key:key_1"
           ]
  end

  test "a text splits at its first colon, so an id keeps its own" do
    assert Caller.decode("tincture:a:b:c") == {:ok, {:tincture, "a:b:c"}}
  end

  test "any is reserved for a standing answer and is never a run's caller" do
    assert Caller.any() == "any"
    assert Caller.decode("any") == {:error, {:unknown_caller, "any"}}
  end

  test "a malformed text is refused" do
    for text <- ["", "device", "device:", "robot:1", "Person", ":x", "person:1", 7] do
      assert {:error, {:unknown_caller, ^text}} = Caller.decode(text)
    end

    refute Caller.caller?({:device, ""})
    refute Caller.caller?({:robot, "1"})
    refute Caller.caller?("person")
    assert_raise ArgumentError, fn -> Caller.encode({:key, ""}) end
  end

  test "a root that recorded none reads as unknown" do
    assert Caller.decode(nil) == {:ok, :unknown}
  end

  test "the nearest starter wins: tincture, agent, schedule, webhook, key, device, person" do
    order = [
      {:tincture, "t"},
      {:agent, "a"},
      {:schedule, "s"},
      {:webhook, "w"},
      {:key, "k"},
      {:device, "d"},
      :person
    ]

    for {caller, i} <- Enum.with_index(order) do
      later = Enum.drop(order, i)
      assert Caller.nearest(Enum.reverse(later)) == caller
    end

    assert Caller.nearest([:person, {:tincture, "t"}, {:key, "k"}]) == {:tincture, "t"}
    assert Caller.nearest([{:agent, "a"}, {:schedule, "s"}]) == {:agent, "a"}
    assert Caller.nearest([:unknown, :person]) == :person
    assert Caller.nearest([:unknown]) == :unknown
    assert Caller.nearest([]) == :unknown
  end
end
