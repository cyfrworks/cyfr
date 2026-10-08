# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ToolGrantStorageTest do
  # The grant store's two promises at the row level: one key is one row
  # whatever was said before, and a duplicate that slips past the delete
  # is a typed refusal on whichever adapter runs — never a raise past the
  # db-error rescue, never a key left with no row.
  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Arca.ToolGrantStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
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

  describe "bounded allows" do
    defp listed(row) do
      {:ok, rows} =
        ToolGrantStorage.list_for_thread(Prima.Actor.in_athanor(row.athanor_id), row.thread_id)

      rows
    end

    test "a deny written with a lifecycle, a deadline or a constraint is refused", %{thread: row} do
      deny = %{row | effect: "deny"}

      for {field, value} <- [
            lifecycle_kind: "execution",
            expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
            constraint: %{kind: "storage_path", patterns: ["data/notes/"]}
          ] do
        assert {:error, {:invalid, errors}} = ToolGrantStorage.put(Map.put(deny, field, value))
        assert Map.has_key?(errors, field)
      end

      assert {:error, {:invalid, %{lifecycle_id: _}}} =
               ToolGrantStorage.put(Map.merge(deny, %{lifecycle_kind: "turn", lifecycle_id: nil}))

      assert listed(row) == []
    end

    test "a constraint is a resource kind and its patterns in that kind's grammar", %{thread: row} do
      for constraint <- [
            %{kind: "email", patterns: ["a"]},
            %{kind: "storage_path", patterns: []},
            %{kind: "storage_path", patterns: ["../escape"]},
            %{kind: "egress_domain", patterns: ["http://api.example.com/path"]},
            %{kind: "storage_path", patterns: ["a/", "a/"]},
            "storage_path:data/"
          ] do
        assert {:error, {:invalid, %{constraint: _}}} =
                 ToolGrantStorage.put(Map.put(row, :constraint, constraint))
      end

      assert {:ok, stored} =
               ToolGrantStorage.put(
                 Map.put(row, :constraint, %{kind: :egress_domain, patterns: ["*.example.com"]})
               )

      assert stored.constraint == %{kind: "egress_domain", patterns: ["*.example.com"]}
      assert [%{constraint: %{kind: "egress_domain"}}] = listed(row)
    end

    test "a vault_entry constraint's patterns are entry ids, and a deny carries none",
         %{thread: row} do
      assert ToolGrantStorage.constraint_errors("vault_entry", ["vlt_x"]) == []
      assert "vault_entry" in Arca.Schemas.ToolGrant.constraint_kinds()

      for patterns <- [["*"], ["vlt_*"], ["Supabase 1"], ["vlt_a/b"], [""], ["vlt_a", "vlt_a"]] do
        assert {:error, {:invalid, %{constraint: _}}} =
                 ToolGrantStorage.put(
                   Map.put(row, :constraint, %{kind: "vault_entry", patterns: patterns})
                 )
      end

      entry_id = "vlt_01a10337-1f70-7297-b4ba-7812de692b02"

      # A standing deny never takes a bound, a vault entry included.
      assert {:error, {:invalid, %{constraint: _}}} =
               ToolGrantStorage.put(
                 Map.merge(row, %{
                   effect: "deny",
                   constraint: %{kind: "vault_entry", patterns: [entry_id]}
                 })
               )

      assert {:ok, stored} =
               ToolGrantStorage.put(
                 Map.put(row, :constraint, %{
                   kind: :vault_entry,
                   patterns: [entry_id, "ine_01a10337-0000-7000-8000-000000000000"]
                 })
               )

      assert stored.constraint.kind == "vault_entry"
      assert entry_id in stored.constraint.patterns
    end

    test "an allow past its deadline is not answered; a deny always is", %{thread: row} do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, _} = ToolGrantStorage.put(Map.put(row, :expires_at, past))
      assert listed(row) == []

      {:ok, _} =
        ToolGrantStorage.put(Map.put(row, :expires_at, DateTime.add(past, 3600, :second)))

      assert [%{effect: "allow"}] = listed(row)

      {:ok, _} = ToolGrantStorage.put(%{row | effect: "deny"})
      assert [%{effect: "deny"}] = listed(row)
    end

    test "an allow bound to an execution is answered while it runs and not after", %{thread: row} do
      id = "exec_tg_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Arca.Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.test:1.0.0",
            user_id: "user_tg",
            athanor_id: row.athanor_id,
            component_type: "catalyst",
            origin: :interactive
          },
          grant: Arca.Test.Actor.grant(row.athanor_id),
          verify: &Arca.Test.Actor.admits/1
        )

      {:ok, _} =
        ToolGrantStorage.put(Map.merge(row, %{lifecycle_kind: "execution", lifecycle_id: id}))

      assert [%{lifecycle_id: ^id}] = listed(row)

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^id),
          set: [status: "completed", completed_at: DateTime.utc_now(), duration_ms: 1]
        )

      assert listed(row) == []
    end

    test "an allow bound to a lifecycle row that does not exist is not answered", %{thread: row} do
      for kind <- ["execution", "turn", "schedule"] do
        {:ok, _} =
          ToolGrantStorage.put(
            Map.merge(row, %{lifecycle_kind: kind, lifecycle_id: "#{kind}_gone"})
          )

        assert listed(row) == []
      end
    end

    test "an allow bound to a turn is answered while the turn is open", %{thread: row} do
      actor = Prima.Actor.in_athanor(row.athanor_id) |> Map.put(:user_id, "user_tg")
      {:ok, thread} = Arca.ThreadStorage.create(actor)

      {:ok, %{turn: turn}} =
        Arca.TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: "user_tg", content: "go"},
          turn: %{agent: "aqua", requested_by: "user_tg", origin: :interactive}
        })

      bound = Map.merge(row, %{lifecycle_kind: "turn", lifecycle_id: turn.id})
      {:ok, _} = ToolGrantStorage.put(bound)
      assert [%{lifecycle_kind: "turn"}] = listed(row)

      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [status: "completed", ended_at: DateTime.utc_now()]
        )

      assert listed(row) == []
    end
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
