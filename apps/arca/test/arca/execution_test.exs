# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionTest do
  use ExUnit.Case, async: false

  alias Arca.Execution
  alias Arca.Schemas.Execution, as: Row

  @athanor Arca.Test.Actor.athanor_id()

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  describe "start_changeset/1" do
    test "creates valid changeset with required fields" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "reagent"
      }

      changeset = Row.start_changeset(attrs)
      assert changeset.valid?
    end

    test "requires an explicit component_type and rejects non-executable types" do
      base = %{
        id: "exec_type_check",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running"
      }

      # No silent "reagent" default — the writer must state the type.
      refute Row.start_changeset(base).valid?

      # Tinctures are browser-side and never execute through Opus.
      refute Row.start_changeset(Map.put(base, :component_type, "tincture")).valid?

      for type <- Cyfr.ComponentRef.executable_types() do
        assert Row.start_changeset(Map.put(base, :component_type, type)).valid?
      end
    end

    test "requires id" do
      attrs = %{
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Row.start_changeset(attrs)
      refute changeset.valid?
      assert {:id, _} = hd(changeset.errors)
    end

    test "requires reference" do
      attrs = %{
        id: "exec_test123",
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Row.start_changeset(attrs)
      refute changeset.valid?
      assert {:reference, _} = hd(changeset.errors)
    end

    test "validates status inclusion" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "invalid_status"
      }

      changeset = Row.start_changeset(attrs)
      refute changeset.valid?
      assert {:status, _} = hd(changeset.errors)
    end

    test "validates component_type inclusion" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "invalid_type"
      }

      changeset = Row.start_changeset(attrs)
      refute changeset.valid?
      assert {:component_type, _} = hd(changeset.errors)
    end

    test "accepts optional fields" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "catalyst",
        component_digest: "sha256:abc123",
        input_hash: "def456"
      }

      changeset = Row.start_changeset(attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :component_type) == "catalyst"
      assert Ecto.Changeset.get_field(changeset, :component_digest) == "sha256:abc123"
    end
  end

  describe "complete_changeset/2" do
    test "creates valid changeset for completion" do
      execution = %Row{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running"
      }

      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 150,
        status: "completed"
      }

      changeset = Row.complete_changeset(execution, attrs)
      assert changeset.valid?
    end

    test "accepts error_message for failed status" do
      execution = %Row{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running"
      }

      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 50,
        status: "failed",
        error_message: "Component crashed"
      }

      changeset = Row.complete_changeset(execution, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :error_message) == "Component crashed"
    end

    test "validates status for completion" do
      execution = %Row{id: "exec_test123", status: "running"}

      # Invalid status for completion
      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 100,
        status: "invalid_status"
      }

      changeset = Row.complete_changeset(execution, attrs)
      refute changeset.valid?
      assert {:status, _} = hd(changeset.errors)
    end
  end

  describe "child_by_key/3" do
    defp start!(attrs) do
      {:ok, row} =
        Execution.record_start(
          Map.merge(
            %{
              reference: "catalyst:local.child:1.0.0",
              user_id: "user_test",
              athanor_id: @athanor,
              started_at: DateTime.utc_now(),
              status: "running",
              component_type: "catalyst"
            },
            attrs
          )
        )

      row
    end

    test "answers the child admitted under a key for its parent, in the caller's athanor" do
      Arca.Test.Actor.athanor!()
      actor = Arca.Test.Actor.local()
      parent = start!(%{id: "exec_p_#{System.unique_integer([:positive])}"})

      child =
        start!(%{
          id: "exec_c_#{System.unique_integer([:positive])}",
          parent_execution_id: parent.id,
          child_key: "ck_one"
        })

      assert {:ok, %{id: id}} =
               Execution.child_by_key(actor, parent.id, "ck_one")

      assert id == child.id
      assert :none = Execution.child_by_key(actor, parent.id, "ck_two")
      assert :none = Execution.child_by_key(actor, child.id, "ck_one")

      other = %{actor | athanor_id: "ath_other"}
      assert :none = Execution.child_by_key(other, parent.id, "ck_one")
    end

    test "one key admits one child per parent; the same key elsewhere is another child" do
      parent = start!(%{id: "exec_p_#{System.unique_integer([:positive])}"})
      sibling = start!(%{id: "exec_p_#{System.unique_integer([:positive])}"})

      _first =
        start!(%{
          id: "exec_c_#{System.unique_integer([:positive])}",
          parent_execution_id: parent.id,
          child_key: "ck_dup"
        })

      assert {:error, :duplicate_child_key} =
               Execution.record_start(%{
                 id: "exec_c_#{System.unique_integer([:positive])}",
                 reference: "catalyst:local.child:1.0.0",
                 user_id: "user_test",
                 athanor_id: @athanor,
                 started_at: DateTime.utc_now(),
                 status: "running",
                 component_type: "catalyst",
                 parent_execution_id: parent.id,
                 child_key: "ck_dup"
               })

      assert %{id: _} =
               start!(%{
                 id: "exec_c_#{System.unique_integer([:positive])}",
                 parent_execution_id: sibling.id,
                 child_key: "ck_dup"
               })

      # Roots carry no key, and two of them never collide.
      assert %{child_key: nil} =
               start!(%{id: "exec_r_#{System.unique_integer([:positive])}"})

      assert %{child_key: nil} =
               start!(%{id: "exec_r_#{System.unique_integer([:positive])}"})
    end

    test "a malformed key, or a key without a parent, is refused before any write" do
      base = %{
        id: "exec_c_#{System.unique_integer([:positive])}",
        reference: "catalyst:local.child:1.0.0",
        user_id: "user_test",
        athanor_id: @athanor,
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "catalyst"
      }

      assert {:error, {:invalid, errors}} =
               Execution.record_start(
                 Map.merge(base, %{parent_execution_id: "exec_p", child_key: "no key"})
               )

      assert Map.has_key?(errors, :child_key)

      assert {:error, {:invalid, errors}} =
               Execution.record_start(Map.put(base, :child_key, "ck_orphan"))

      assert Map.has_key?(errors, :parent_execution_id)
    end
  end

  describe "list_running_children/1" do
    test "returns children with running status" do
      parent_id = "exec_parent_#{System.unique_integer([:positive])}"
      child_id = "exec_child_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: parent_id,
          reference: "formula:local.test:1.0.0",
          user_id: "user_test",
          athanor_id: @athanor,
          started_at: now,
          status: "running",
          component_type: "formula"
        })

      {:ok, _} =
        Execution.record_start(%{
          id: child_id,
          reference: "catalyst:local.child:1.0.0",
          user_id: "user_test",
          athanor_id: @athanor,
          started_at: now,
          status: "running",
          component_type: "catalyst",
          parent_execution_id: parent_id
        })

      children = Execution.list_running_children(parent_id)
      assert length(children) == 1
      assert hd(children).id == child_id
    end

    test "does not return completed children" do
      parent_id = "exec_parent_#{System.unique_integer([:positive])}"
      child_id = "exec_child_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: parent_id,
          reference: "formula:local.test:1.0.0",
          user_id: "user_test",
          athanor_id: @athanor,
          started_at: now,
          status: "running",
          component_type: "formula"
        })

      {:ok, _} =
        Execution.record_start(%{
          id: child_id,
          reference: "catalyst:local.child:1.0.0",
          user_id: "user_test",
          athanor_id: @athanor,
          started_at: now,
          status: "running",
          component_type: "catalyst",
          parent_execution_id: parent_id
        })

      # Complete the child
      actor = %Cyfr.Actor{
        athanor_id: @athanor,
        user_id: "user_test",
        authenticated: true,
        scope: :athanor,
        system: false
      }

      {:ok, _} =
        Execution.record_complete(
          actor,
          child_id,
          %{completed_at: now, duration_ms: 100, status: "completed"},
          Arca.Test.Actor.standing(@athanor)
        )

      children = Execution.list_running_children(parent_id)
      assert children == []
    end

    test "returns empty list when no children exist" do
      children = Execution.list_running_children("exec_nonexistent")
      assert children == []
    end
  end

  describe "mark_failed_if_running/2" do
    test "marks running execution as failed" do
      id = "exec_mark_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.test:1.0.0",
            user_id: "user_test",
            athanor_id: @athanor,
            started_at: now,
            component_type: "catalyst"
          },
          Arca.Test.Actor.standing(@athanor)
        )

      failure = %{completed_at: now, duration_ms: 500, error_message: "Parent terminated"}

      # A failure names the stamp it retires under; one that names none
      # fails nothing.
      assert {0, nil} = Execution.mark_failed_if_running(id, failure)

      {count, _} = Execution.mark_failed_if_running(id, failure, Arca.Test.Actor.stored())

      assert count == 1

      actor = Arca.Test.Actor.platform(user_id: "user_test", athanor_id: @athanor)

      updated = Execution.get_tenant(actor, id)
      assert updated.status == "failed"
      assert updated.error_message == "Parent terminated"
    end

    test "does not overwrite already-completed execution" do
      id = "exec_mark_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, _} =
        Execution.record_start(%{
          id: id,
          reference: "catalyst:local.test:1.0.0",
          user_id: "user_test",
          athanor_id: @athanor,
          started_at: now,
          status: "running",
          component_type: "catalyst"
        })

      # Complete it first
      actor = %Cyfr.Actor{
        athanor_id: @athanor,
        user_id: "user_test",
        authenticated: true,
        scope: :athanor,
        system: false
      }

      {:ok, _} =
        Execution.record_complete(
          actor,
          id,
          %{completed_at: now, duration_ms: 100, status: "completed"},
          Arca.Test.Actor.standing(@athanor)
        )

      # Try to mark as failed — should be a no-op
      {count, _} =
        Execution.mark_failed_if_running(
          id,
          %{
            completed_at: now,
            duration_ms: 500,
            error_message: "Parent terminated"
          },
          Arca.Test.Actor.stored()
        )

      assert count == 0

      updated = Execution.get_tenant(actor, id)
      assert updated.status == "completed"
    end
  end

  describe "list_stale_running/2 over attempts" do
    defp running!(lease_until, opts \\ []) do
      id = "exec_lease_#{System.unique_integer([:positive])}"

      {:ok, %{attempt: attempt}} =
        Execution.admit(
          %{
            id: id,
            reference: "catalyst:local.test:1.0.0",
            user_id: "user_test",
            athanor_id: @athanor,
            component_type: "catalyst"
          },
          attempt: Keyword.get(opts, :attempt),
          boot_id: "node@test",
          lease_until: lease_until,
          grant: Arca.Test.Actor.grant(@athanor),
          verify: &Arca.Test.Actor.admits/1
        )

      {id, attempt.attempt}
    end

    test "returns running executions whose lease has lapsed, with the attempt beside the row" do
      {id, attempt} = running!(DateTime.add(DateTime.utc_now(), -60, :second))
      [stale] = Enum.filter(Execution.list_stale_running(DateTime.utc_now()), &(&1.id == id))
      assert stale.attempt == attempt
      assert stale.boot_id == "node@test"
      assert %DateTime{} = stale.lease_until
    end

    test "leaves a running execution whose lease still holds" do
      {id, _} = running!(DateTime.add(DateTime.utc_now(), 120, :second))
      stale_ids = Execution.list_stale_running(DateTime.utc_now()) |> Enum.map(& &1.id)
      refute id in stale_ids
    end

    test "the sweep is fenced on what it observed: a renewal in between wins" do
      lapsed = DateTime.add(DateTime.utc_now(), -60, :second)
      {id, live} = running!(lapsed, attempt: "att_live")

      [observed] = Enum.filter(Execution.list_stale_running(DateTime.utc_now()), &(&1.id == id))
      assert observed.attempt == live

      renewed_until = DateTime.add(DateTime.utc_now(), 180, :second)

      assert {:ok, ^renewed_until} =
               Arca.ExecutionAttempts.renew(live, renewed_until, Arca.Test.Actor.stored())

      assert {0, _} =
               Execution.mark_failed_if_running(
                 id,
                 %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "stale"},
                 attempt: observed.attempt,
                 lease_until: observed.lease_until,
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1
               )

      # A stale attempt can neither renew nor finish the row…
      assert :lost =
               Arca.ExecutionAttempts.renew("att_stale", renewed_until, Arca.Test.Actor.stored())

      assert {:error, :not_running} =
               Execution.record_end(
                 Arca.Test.Actor.local(),
                 id,
                 "completed",
                 %{completed_at: DateTime.utc_now(), duration_ms: 1},
                 "att_stale",
                 Arca.Test.Actor.stored()
               )

      # …and the live one still can, closing its attempt with the row.
      assert {:ok, _} =
               Execution.record_end(
                 Arca.Test.Actor.local(),
                 id,
                 "completed",
                 %{completed_at: DateTime.utc_now(), duration_ms: 1},
                 live,
                 Arca.Test.Actor.stored()
               )

      assert %{state: "completed", outcome: "ok"} =
               Arca.ExecutionAttempts.get(Cyfr.Actor.in_athanor(@athanor), live)
    end

    test "a renewed lease takes an execution out of the sweep" do
      {id, attempt} = running!(DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:ok, _} =
               Arca.ExecutionAttempts.renew(
                 attempt,
                 DateTime.add(DateTime.utc_now(), 180, :second),
                 Arca.Test.Actor.stored()
               )

      stale_ids = Execution.list_stale_running(DateTime.utc_now()) |> Enum.map(& &1.id)
      refute id in stale_ids

      # A finished execution is not renewed.
      {:ok, _} =
        Execution.record_end(
          Arca.Test.Actor.local(),
          id,
          "completed",
          %{completed_at: DateTime.utc_now(), duration_ms: 1},
          nil,
          Arca.Test.Actor.stored()
        )

      assert :lost =
               Arca.ExecutionAttempts.renew(
                 attempt,
                 DateTime.add(DateTime.utc_now(), 180, :second),
                 Arca.Test.Actor.stored()
               )
    end

    test "a sweep fails the lapsed attempt's row and retires the attempt" do
      lapsed = DateTime.add(DateTime.utc_now(), -60, :second)
      {id, attempt} = running!(lapsed)
      [observed] = Enum.filter(Execution.list_stale_running(DateTime.utc_now()), &(&1.id == id))

      assert {1, _} =
               Execution.mark_failed_if_running(
                 id,
                 %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "stale"},
                 attempt: observed.attempt,
                 lease_until: observed.lease_until,
                 grant: :stored,
                 verify: &Arca.Test.Actor.admits/1
               )

      assert %{state: "lapsed", outcome: "uncertain"} =
               Arca.ExecutionAttempts.get(Cyfr.Actor.in_athanor(@athanor), attempt)

      assert Arca.Repo.get!(Row, id).status == "failed"
    end

    test "respects limit parameter" do
      for _ <- 1..3, do: running!(DateTime.add(DateTime.utc_now(), -60, :second))
      assert length(Execution.list_stale_running(DateTime.utc_now(), 1)) == 1
    end
  end

  describe "hash_input/1" do
    test "returns consistent hash for same input" do
      input = %{"method" => "GET", "url" => "https://example.com"}

      hash1 = Execution.hash_input(input)
      hash2 = Execution.hash_input(input)

      assert hash1 == hash2
      assert is_binary(hash1)
      # SHA256 hex is 64 chars
      assert String.length(hash1) == 64
    end

    test "returns different hash for different input" do
      input1 = %{"method" => "GET"}
      input2 = %{"method" => "POST"}

      hash1 = Execution.hash_input(input1)
      hash2 = Execution.hash_input(input2)

      refute hash1 == hash2
    end

    test "returns nil for non-map input" do
      assert Execution.hash_input(nil) == nil
      assert Execution.hash_input("string") == nil
      assert Execution.hash_input(123) == nil
    end

    test "returns nil for non-encodable map input" do
      # A map with a PID value cannot be JSON-encoded
      assert Execution.hash_input(%{"pid" => self()}) == nil
    end
  end
end
