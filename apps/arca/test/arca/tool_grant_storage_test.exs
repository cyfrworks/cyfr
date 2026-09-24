# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ToolGrantStorageTest do
  # The grant store's two promises at the row level: one key is one row
  # whatever was said before, and a duplicate that slips past the delete
  # is a typed refusal on whichever adapter runs — never a raise past the
  # db-error rescue, never a key left with no row.
  use ExUnit.Case, async: true

  alias Arca.ToolGrantStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    n = System.unique_integer([:positive])

    thread = %{
      athanor_id: "ath_#{n}",
      scope: "thread",
      effect: "allow",
      thread_id: "thread_#{n}",
      agent_name: "aqua",
      tool: "notes",
      action: "keep",
      granted_by: "local|idp|#{n}"
    }

    {:ok, thread: thread, agent: %{thread | scope: "agent", thread_id: nil}}
  end

  test "the same key written twice is one row carrying the newer answer", %{thread: row} do
    assert {:ok, _} = ToolGrantStorage.put(row)
    assert {:ok, stored} = ToolGrantStorage.put(%{row | effect: "deny"})
    assert stored.effect == "deny"

    assert [%{effect: "deny"}] =
             elem(
               ToolGrantStorage.list_for_thread(
                 Prima.Actor.in_athanor(row.athanor_id),
                 row.thread_id
               ),
               1
             )
  end

  test "a duplicate thread-scope row is refused, not raised", %{thread: row} do
    assert {:ok, _} = ToolGrantStorage.put(row)
    assert {:error, %Ecto.Changeset{} = changeset} = duplicate(row)
    assert unique_violation?(changeset)
  end

  test "a duplicate agent-scope row is refused, not raised", %{agent: row} do
    assert {:ok, _} = ToolGrantStorage.put(row)
    assert {:error, %Ecto.Changeset{} = changeset} = duplicate(row)
    assert unique_violation?(changeset)
  end

  test "an insert that fails inside put/1 leaves the earlier decision standing", %{
    thread: row
  } do
    # The delete and the insert are one transaction: a failed insert must
    # not leave the key with no row at all. Forced here with a primary-key
    # collision — the new row borrows an id another key already holds —
    # which raises past the rescue and rolls the delete back with it.
    assert {:ok, first} = ToolGrantStorage.put(row)
    assert {:ok, other} = ToolGrantStorage.put(%{row | action: "search"})

    assert_raise Ecto.ConstraintError, fn ->
      ToolGrantStorage.put(row |> Map.put(:id, other.id) |> Map.put(:effect, "deny"))
    end

    rows =
      elem(
        ToolGrantStorage.list_for_thread(Prima.Actor.in_athanor(row.athanor_id), row.thread_id),
        1
      )

    assert Enum.find(rows, &(&1.id == first.id)).effect == "allow"
    assert length(rows) == 2
  end

  test "a refused duplicate leaves the earlier row standing", %{thread: row} do
    assert {:ok, first} = ToolGrantStorage.put(row)
    assert {:error, _} = duplicate(row)

    assert [%{id: id}] =
             elem(
               ToolGrantStorage.list_for_thread(
                 Prima.Actor.in_athanor(row.athanor_id),
                 row.thread_id
               ),
               1
             )

    assert id == first.id
  end

  # Straight through the changeset, skipping `put/1`'s delete — the shape
  # of the race the constraint exists for.
  defp duplicate(row) do
    row
    |> Map.put(:id, Prima.UUID7.generate_id("grant"))
    |> Map.put(:granted_at, DateTime.utc_now())
    |> ToolGrantStorage.changeset()
    |> Arca.Repo.insert()
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end)
  end
end
