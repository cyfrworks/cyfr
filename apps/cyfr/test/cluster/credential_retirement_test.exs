# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.CredentialRetirementTest do
  @moduledoc """
  A denial on one member against the other, with the control channel up
  and with it cut, for the sessions it retires and the tincture tokens
  derived from them.

  The denial retires the person's sessions and keys in one transaction on
  the member that ran it. What the other member learns by announcement is
  only that its memo is stale; what keeps a retired authority from acting
  there is the rows. A context the other member established before the
  denial, used again after an allow, issues nothing — its binding names
  the generation it read, and the issuance rereads the row — whether or
  not the announcement arrived.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.Cluster.Fixtures

  describe "a denial and an allow on one member" do
    test "retire the session and every context read before them on the other" do
      person = Cell.call(:a, Fixtures, :person!, [])

      # The peer establishes before the denial: a memo of its own, and a
      # context it will try to reuse.
      assert {:ok, before} = Cell.call(:b, Fixtures, :context, [person.token])
      assert Cell.call(:b, Fixtures, :memo?, [person.hash])

      assert Cell.call(:a, Fixtures, :deny!, [person.user_id]) == "denied"

      Wait.until!(
        fn -> not Cell.call(:b, Fixtures, :memo?, [person.hash]) end,
        "the peer never dropped the memo of the denied session",
        10_000
      )

      assert Cell.call(:a, Fixtures, :allow!, [person.user_id]) == "active"

      # The session stays retired on the peer, and a context the peer read
      # before the denial cannot issue after the allow.
      refute match?({:ok, _}, Cell.call(:b, Fixtures, :establish, [person.token]))
      assert {:error, reason} = Cell.call(:b, Fixtures, :issue_key, [before])
      assert reason in [:stale_generation, :unauthenticated]
    end

    test "a derived token minted on the peer is refused there after the denial and the allow" do
      person = Cell.call(:a, Fixtures, :person!, [])
      assert {:ok, before} = Cell.call(:b, Fixtures, :context, [person.token])
      assert {:ok, token} = Cell.call(:b, Fixtures, :mint_access, [before])
      assert {:ok, athanor} = Cell.call(:b, Fixtures, :open_access, [token])
      assert athanor == person.athanor_id

      assert Cell.call(:a, Fixtures, :deny!, [person.user_id]) == "denied"
      assert {:error, :unauthenticated} = Cell.call(:b, Fixtures, :open_access, [token])

      assert Cell.call(:a, Fixtures, :allow!, [person.user_id]) == "active"
      assert {:error, :unauthenticated} = Cell.call(:b, Fixtures, :open_access, [token])

      # Nor can the context the peer read before the denial mint a new one.
      assert {:error, :not_standing} = Cell.call(:b, Fixtures, :mint_access, [before])
    end

    test "a lost announcement leaves a memo on the peer and no authority behind it" do
      person = Cell.call(:a, Fixtures, :person!, [])
      assert {:ok, before} = Cell.call(:b, Fixtures, :context, [person.token])
      assert Cell.call(:b, Fixtures, :memo?, [person.hash])

      Cell.partition(:a, :b)
      assert Cell.call(:b, Node, :list, []) == []

      assert Cell.call(:a, Fixtures, :deny!, [person.user_id]) == "denied"
      assert Cell.call(:a, Fixtures, :allow!, [person.user_id]) == "active"

      assert Cell.call(:b, Fixtures, :memo?, [person.hash]),
             "the peer dropped the memo without hearing anything, so the cut proves nothing"

      # Nothing reached the peer, and still: the context it read before
      # the denial issues nothing there, because the issuance rereads the
      # rows the denial changed.
      assert {:error, reason} = Cell.call(:b, Fixtures, :issue_key, [before])
      assert reason in [:stale_generation, :unauthenticated]

      # A derived token needs no announcement either: its every use rereads
      # the rows.
      assert {:error, _} = Cell.call(:b, Fixtures, :mint_access, [before])

      # Once the memo runs out, the rows answer the session too.
      assert Cell.call(:b, Sanctum.Caller, :drop_memo, [person.hash]) == :ok
      refute match?({:ok, _}, Cell.call(:b, Fixtures, :establish, [person.token]))

      Cell.heal(:a, :b)
    end
  end
end
