# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RequestsTest do
  @moduledoc """
  The registry of requests waiting on a person: the one authority on
  whether a request still waits. The first decision ends it and acts;
  every later one, and any from a process that does not hold it, is told
  it was decided and changes nothing.
  """

  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other}
  end

  test "the first decision ends a waiting request, and every later one acts on nothing",
       %{ctx: ctx} do
    id = Prima.UUID7.request_id()
    :ok = Cyfr.Requests.open(ctx, id, "schedule.update")
    assert [%{id: ^id, kind: :grant_request}] = Cyfr.Requests.waiting(ctx.athanor_id, ctx.user_id)

    assert Cyfr.Requests.decide(id, :expired) == :ok
    assert Cyfr.Requests.waiting(ctx.athanor_id, ctx.user_id) == []

    for outcome <- [:resolved, :expired, :withdrawn],
        do: assert(Cyfr.Requests.decide(id, outcome) == :decided)

    assert Cyfr.Requests.decide(Prima.UUID7.request_id(), :resolved) == :decided
  end

  test "only the process that holds a request decides it", %{ctx: ctx} do
    id = Prima.UUID7.request_id()
    :ok = Cyfr.Requests.open(ctx, id, "feed.remove")

    assert Task.await(Task.async(fn -> Cyfr.Requests.decide(id, :resolved) end)) == :decided
    assert [%{id: ^id}] = Cyfr.Requests.waiting(ctx.athanor_id, ctx.user_id)
    assert Cyfr.Requests.decide(id, :resolved) == :ok
  end

  test "a person's waiting requests are theirs alone, in their athanor", %{ctx: ctx, other: other} do
    mine = Prima.UUID7.request_id()
    theirs = Prima.UUID7.request_id()
    :ok = Cyfr.Requests.open(ctx, mine, "layout.edit")
    :ok = Cyfr.Requests.open(other, theirs, "layout.edit")

    assert [%{id: ^mine}] = Cyfr.Requests.waiting(ctx.athanor_id, ctx.user_id)
    assert [%{id: ^theirs}] = Cyfr.Requests.waiting(other.athanor_id, other.user_id)
    assert Cyfr.Requests.waiting(other.athanor_id, ctx.user_id) == []
  end
end
