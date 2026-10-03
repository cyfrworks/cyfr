# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ContextFreshnessTest do
  @moduledoc """
  A context held on one member against a revocation made on the other.

  A console socket keeps the context it was mounted with, and a standing
  announcement is what normally ends it at once. With the control channel
  cut no announcement arrives; what bounds the exposure then is the
  guard's freshness rule (`CyfrWeb.ContextGuard.check/1`): the held
  context is acted on as it is only while its last validation is younger
  than the caller bound (`Sanctum.Caller.fresh?/1`, 2 s in production),
  and revalidated from the rows after that — which refuse.
  """

  use Cyfr.Cluster.Case, async: false

  # The production bound. The cell runs its members with a longer one so a
  # memo stays warm across a case (`Cyfr.Cluster.Cell`); the holding member
  # is put back on this one for the case that measures it.
  @bound_ms 2_000

  test "a session revoked on one member is refused by a context held on the other within the bound, with the announcement lost" do
    previous = Cell.call(:b, Application, :get_env, [:sanctum, :caller_memo_ttl_ms])
    :ok = Cell.call(:b, Application, :put_env, [:sanctum, :caller_memo_ttl_ms, @bound_ms])

    try do
      person = Cell.call(:a, Cyfr.Cluster.Fixtures, :person!, [])
      held = Cell.call(:b, Cyfr.Cluster.Fixtures, :hold_context, [person.token])
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :act, [held]) == :ok

      # Nothing about the revocation reaches the other member.
      Cell.partition(:a, :b)
      assert Cell.call(:b, Node, :list, []) == []

      assert {:ok, _} = Cell.call(:a, Sanctum.Session, :revoke_all_for_user, [person.user_id])

      {refused_ms, _} =
        Wait.measure!(
          fn ->
            Cell.call(:b, Cyfr.Cluster.Fixtures, :act, [held]) == {:error, :unauthenticated}
          end,
          "the held context was never refused",
          10_000
        )

      Wait.report(
        "a held context refused with its announcement lost",
        refused_ms,
        @bound_ms + 1_000
      )

      assert refused_ms <= @bound_ms + 1_000

      # The refusal stands: the rows say so on every later action.
      assert Cell.call(:b, Cyfr.Cluster.Fixtures, :act, [held]) == {:error, :unauthenticated}
    after
      Cell.heal(:a, :b)
      :ok = Cell.call(:b, Application, :put_env, [:sanctum, :caller_memo_ttl_ms, previous])
    end
  end

  test "with the channel up, the announcement ends a held context before its bound" do
    person = Cell.call(:a, Cyfr.Cluster.Fixtures, :person!, [])
    held = Cell.call(:b, Cyfr.Cluster.Fixtures, :hold_context, [person.token])
    assert Cell.call(:b, Cyfr.Cluster.Fixtures, :act, [held]) == :ok

    assert {:ok, _} = Cell.call(:a, Sanctum.Session, :revoke_all_for_user, [person.user_id])

    # The held context heard, and revalidated: the very next action is
    # refused however young its last validation was.
    {heard_ms, _} =
      Wait.measure!(
        fn ->
          Cell.call(:b, Cyfr.Cluster.Fixtures, :act, [held]) == {:error, :unauthenticated}
        end,
        "the held context never heard the revocation",
        10_000
      )

    assert heard_ms < @bound_ms
  end
end
