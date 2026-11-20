# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ThreadLatestMessagesTest do
  @moduledoc """
  A thread's newest rows (`Arca.ThreadStorage.latest_messages/4`): the
  newest `n` of every kind, or the newest `n` of the kinds asked for,
  however many rows of other kinds stand between them; under the actor's
  own athanor only.
  """

  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!()
    actor = Arca.Test.Actor.local()
    {:ok, daily} = Arca.Test.Days.thread(actor)
    {:ok, actor: actor, daily: daily}
  end

  defp append!(actor, thread, kind, content) do
    {:ok, row} =
      Threads.append(actor, thread.id, %{
        author: "aqua",
        sent_by: "aqua",
        kind: kind,
        content: content
      })

    row
  end

  test "the newest rows of the kinds asked for, past any number of other rows, oldest first",
       %{actor: actor, daily: daily} do
    first = append!(actor, daily, "text", "first")
    second = append!(actor, daily, "system", "second")
    for n <- 1..5, do: append!(actor, daily, "tool_call", "call #{n}")
    last_call = append!(actor, daily, "tool_result", "a result")

    assert actor |> Threads.latest_messages(daily.id, 1) |> Enum.map(& &1.id) == [last_call.id]

    assert actor
           |> Threads.latest_messages(daily.id, 2, kinds: Threads.post_kinds())
           |> Enum.map(&{&1.id, &1.content}) == [
             {first.id, "first"},
             {second.id, "second"}
           ]

    assert [%{content: "second"}] =
             Threads.latest_messages(actor, daily.id, 1, kinds: Threads.post_kinds())

    assert Threads.latest_messages(actor, daily.id, 5, kinds: ["opening"]) == []
  end

  test "another athanor's actor reads none of the thread's rows", %{actor: actor, daily: daily} do
    append!(actor, daily, "text", "mine")
    Arca.Test.Actor.athanor!("ath_other")
    stranger = Arca.Test.Actor.local(athanor_id: "ath_other")

    assert Threads.latest_messages(stranger, daily.id, 5, kinds: Threads.post_kinds()) == []
    assert Threads.latest_messages(stranger, daily.id, 5) == []
  end
end
