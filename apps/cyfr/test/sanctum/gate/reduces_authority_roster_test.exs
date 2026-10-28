# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.ReducesAuthorityRosterTest do
  @moduledoc """
  The actions the table declares `reduces_authority` (`Prima.Operation`),
  pinned: while the storage reserve is depleted the gate admits these and
  reads alone (`ARCHITECTURE.md` §6.9), so a declaration added or dropped
  without editing this list fails here, naming it.
  """

  use ExUnit.Case, async: true

  alias Prima.Operation
  alias Sanctum.Catalog

  # Each takes authority away and gives none: signing out, a command line
  # withdrawing its sign-in, revoking (a command line's session among
  # them), withdrawing consent, leaving, removing a member, denying someone
  # at a door, unlinking a door and archiving.
  @roster ~w(
    athanor.archive
    door.deny
    instance_entry.revoke
    invitation.revoke
    key.revoke
    member.leave
    member.remove
    pairing.revoke
    passkey.revoke
    person.unlink_door
    profile.revoke
    session.cli_cancel
    session.cli_revoke
    session.logout
    vault.revoke
    webhook.revoke
  )

  test "the table declares exactly the roster reduces_authority" do
    declared = Enum.filter(Catalog.tool_actions(), &Catalog.reduces_authority?/1)

    assert Enum.sort(declared) == @roster,
           """
           the actions declared reduces_authority differ from the roster:
             declared only: #{Enum.join(declared -- @roster, ", ")}
             missing: #{Enum.join(@roster -- declared, ", ")}
           """
  end

  test "every rostered action is one the table holds, and none is a read" do
    actions = Catalog.tool_actions()

    for name <- @roster do
      assert name in actions, "#{name} is not an action of the table"
      assert Catalog.tool_kind(tool(name), action(name)) != :read, "#{name} is a read"
    end
  end

  test "a name the table does not hold, or holds unflagged, reduces no authority" do
    refute Catalog.reduces_authority?("session.whoami")
    refute Catalog.reduces_authority?("pairing.begin")
    refute Catalog.reduces_authority?("nothing.revoke")
    refute Catalog.reduces_authority?("revoke")
    refute Catalog.reduces_authority?("")
  end

  test "the declaration refuses a flag that is not a boolean, or one on a read" do
    assert_raise ArgumentError, fn ->
      Operation.new("t", "a", "A", [], kind: :write, planes: [:external], reduces_authority: :yes)
    end

    assert_raise ArgumentError, "a read takes no authority away", fn ->
      Operation.new("t", "a", "A", [], kind: :read, planes: [:external], reduces_authority: true)
    end

    refute Operation.new("t", "a", "A", [], kind: :write, planes: [:external]).reduces_authority
  end

  test "the flag is the gate's metadata, absent from the annotation view" do
    op =
      Operation.new("t", "a", "A", [],
        kind: :destructive,
        planes: [:external],
        reduces_authority: true
      )

    refute Map.has_key?(Operation.annotations(op), :reduces_authority)
  end

  defp tool(name), do: name |> String.split(".") |> hd()
  defp action(name), do: name |> String.split(".") |> List.last()
end
