# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.Execution
  alias Arca.Schemas.Execution, as: Row

  @athanor Arca.Test.Actor.athanor_id()

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
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

      # Tinctures are browser-side and never execute through the runtime.
      refute Row.start_changeset(Map.put(base, :component_type, "tincture")).valid?

      for type <- Prima.ComponentRef.executable_types() do
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

  describe "the admitting call" do
    test "a start keeps the call id of the admission it was started under" do
      Arca.Test.Actor.athanor!()
      actor = Arca.Test.Actor.local()
      id = "exec_call_#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Execution.record_start(%{
          id: id,
          reference: "catalyst:local.call:1.0.0",
          user_id: "user_test",
          athanor_id: @athanor,
          started_at: DateTime.utc_now(),
          status: "running",
          component_type: "catalyst",
          call_id: "call_admitting"
        })

      assert :call_id in Execution.start_fields()
      assert %{call_id: "call_admitting"} = Execution.get_tenant(actor, id)
    end
  end

  describe "the origin" do
    defp admit_origin(attrs) do
      Execution.admit(
        Map.merge(
          %{
            id: "exec_origin_#{System.unique_integer([:positive])}",
            reference: "catalyst:local.test:1.0.0",
            user_id: "user_test",
            athanor_id: @athanor,
            component_type: "catalyst"
          },
          attrs
        ),
        grant: Arca.Test.Actor.grant(@athanor),
        verify: &Arca.Test.Actor.admits/1
      )
    end

    test "a root records the origin its caller names, and one naming none is refused" do
      assert {:ok, %{execution: root}} = admit_origin(%{origin: :programmatic})
      assert root.origin == "programmatic"
      assert Arca.Repo.get!(Row, root.id).origin == "programmatic"

      # No default stands in for the admission path: nothing is written.
      bare = "exec_origin_bare_#{System.unique_integer([:positive])}"
      assert {:error, :no_origin} = admit_origin(%{id: bare})
      assert {:error, :no_origin} = admit_origin(%{id: bare, origin: nil})
      assert is_nil(Arca.Repo.get(Row, bare))
      refute Arca.Repo.get_by(Arca.Schemas.ExecutionAttempt, execution_id: bare)

      assert {:error, {:invalid, %{origin: _}}} = admit_origin(%{origin: "batch"})
    end

    test "a child of a parent that records no origin is refused, with nothing written" do
      {:ok, %{execution: parent}} = admit_origin(%{origin: :webhook})

      # Past every writer's guard, as a hand edit or a restored row reaches it.
      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(e in Row, where: e.id == ^parent.id),
          set: [origin: nil]
        )

      id = "exec_origin_orphan_#{System.unique_integer([:positive])}"

      for named <- [nil, :interactive] do
        assert {:error, :no_origin} =
                 admit_origin(%{
                   id: id,
                   parent_execution_id: parent.id,
                   root_execution_id: parent.id,
                   origin: named
                 })
      end

      assert is_nil(Arca.Repo.get(Row, id))
    end

    test "a child carries its parent's origin, and one naming another is refused" do
      {:ok, %{execution: parent}} = admit_origin(%{origin: "schedule"})

      assert {:ok, %{execution: child}} =
               admit_origin(%{parent_execution_id: parent.id, root_execution_id: parent.id})

      assert child.origin == "schedule"

      assert {:ok, %{execution: named}} =
               admit_origin(%{
                 parent_execution_id: parent.id,
                 root_execution_id: parent.id,
                 origin: :schedule
               })

      assert named.origin == "schedule"
      id = "exec_origin_other_#{System.unique_integer([:positive])}"

      assert {:error, :origin_mismatch} =
               admit_origin(%{
                 id: id,
                 parent_execution_id: parent.id,
                 root_execution_id: parent.id,
                 origin: :interactive
               })

      assert is_nil(Arca.Repo.get(Row, id))
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
      actor = %Prima.Actor{
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
            component_type: "catalyst",
            origin: :programmatic
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
      actor = %Prima.Actor{
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
            component_type: "catalyst",
            origin: :programmatic
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
               Arca.ExecutionAttempts.get(Prima.Actor.in_athanor(@athanor), live)
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
          attempt,
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
               Arca.ExecutionAttempts.get(Prima.Actor.in_athanor(@athanor), attempt)

      assert Arca.Repo.get!(Row, id).status == "failed"
    end

    test "respects limit parameter" do
      for _ <- 1..3, do: running!(DateTime.add(DateTime.utc_now(), -60, :second))
      assert length(Execution.list_stale_running(DateTime.utc_now(), 1)) == 1
    end
  end

  describe "list_by_profile/3" do
    defp profile_row(attrs) do
      id = "exec_by_profile_#{System.unique_integer([:positive])}"

      {:ok, row} =
        Execution.record_start(
          Map.merge(
            %{
              id: id,
              root_execution_id: id,
              reference: "catalyst:local.usage:1.0.0",
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

    test "answers the runs the profile rooted, newest first, with origin, root and time" do
      profile_id = "prof_usage_#{System.unique_integer([:positive])}"
      earlier = DateTime.add(DateTime.utc_now(), -60, :second)

      first =
        profile_row(%{profile_id: profile_id, origin: "interactive", started_at: earlier})

      second = profile_row(%{profile_id: profile_id, origin: "schedule", schedule_id: "sch_1"})

      # A child walks its root's authority and carries no profile of its own.
      _child =
        profile_row(%{
          parent_execution_id: second.id,
          root_execution_id: second.id,
          origin: "schedule"
        })

      _other_profile = profile_row(%{profile_id: profile_id <> "_other", origin: "webhook"})

      assert {:ok, [newest, oldest]} =
               Execution.list_by_profile(Arca.Test.Actor.local(), profile_id, 20)

      assert %{id: id, root_execution_id: id, origin: "schedule", schedule_id: "sch_1"} = newest
      assert id == second.id
      assert %{id: id, origin: "interactive", kind: "component", status: "running"} = oldest
      assert id == first.id
      assert DateTime.compare(oldest.started_at, earlier) == :eq
      assert is_nil(oldest.completed_at)
    end

    test "is bounded by its limit, keeping the newest" do
      profile_id = "prof_usage_#{System.unique_integer([:positive])}"

      _older =
        profile_row(%{
          profile_id: profile_id,
          origin: "programmatic",
          started_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      newer = profile_row(%{profile_id: profile_id, origin: "programmatic"})

      assert {:ok, [only]} = Execution.list_by_profile(Arca.Test.Actor.local(), profile_id, 1)
      assert only.id == newer.id
    end

    test "never crosses athanors: another athanor's rows under the same id are not read" do
      Arca.Test.Actor.athanor!("ath_other")
      profile_id = "prof_usage_#{System.unique_integer([:positive])}"
      mine = profile_row(%{profile_id: profile_id, origin: "interactive"})
      theirs = profile_row(%{profile_id: profile_id, origin: "webhook", athanor_id: "ath_other"})

      assert {:ok, [%{id: id}]} =
               Execution.list_by_profile(Arca.Test.Actor.local(), profile_id, 20)

      assert id == mine.id

      assert {:ok, [%{id: id}]} =
               Execution.list_by_profile(Arca.Test.Actor.in_athanor("ath_other"), profile_id, 20)

      assert id == theirs.id

      # A platform-scope actor reads the one athanor it carries, never all.
      assert {:ok, [%{id: id}]} =
               Execution.list_by_profile(
                 Arca.Test.Actor.platform(athanor_id: @athanor),
                 profile_id,
                 20
               )

      assert id == mine.id
    end

    test "a profile with no runs is an empty answer, and an actor with no athanor is refused" do
      assert {:ok, []} =
               Execution.list_by_profile(Arca.Test.Actor.local(), "prof_usage_none", 20)

      for athanor_id <- [nil, ""] do
        assert {:error, :no_athanor} =
                 Execution.list_by_profile(
                   Arca.Test.Actor.local(athanor_id: athanor_id),
                   "prof_usage_none",
                   20
                 )
      end

      assert {:error, :no_athanor} =
               Execution.list_by_profile(Arca.Test.Actor.platform(), "prof_usage_none", 20)
    end
  end

  describe "an admission for a schedule's occurrence" do
    test "a claimant whose claim a recoverer took over starts nothing: refused, nothing written" do
      actor = Arca.Test.Actor.local()

      {:ok, schedule} =
        Arca.CronSchedule.create(%{
          user_id: actor.user_id,
          athanor_id: @athanor,
          name: "start-claimant-#{System.unique_integer([:positive])}",
          cron_expression: "0 * * * *",
          reference: "reagent:local.test:1.0.0",
          resolved_reference: "reagent:local.test:1.0.0",
          profile_id: "prof_test"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(s in Arca.Schemas.CronSchedule, where: s.id == ^schedule.id),
          set: [next_run_at: past]
        )

      # This boot claims the occurrence; a recoverer takes it over.
      next = DateTime.add(DateTime.utc_now(), 300, :second)

      {:ok, occurrence} =
        Arca.ScheduleOccurrences.claim(%{schedule | next_run_at: past}, Prima.Boot.id(), next)

      assert :ok =
               Arca.ScheduleOccurrences.recover(
                 actor,
                 occurrence.id,
                 Prima.Boot.id(),
                 "boot-recoverer"
               )

      # The original claimant's slow admission starts nothing.
      execution_id = Prima.UUID7.execution_id()

      assert {:error, :occurrence_not_claimed} =
               Execution.admit(
                 %{
                   id: execution_id,
                   reference: "reagent:local.test:1.0.0",
                   user_id: actor.user_id,
                   athanor_id: @athanor,
                   component_type: "reagent",
                   schedule_id: schedule.id,
                   origin: :schedule
                 },
                 occurrence_id: occurrence.id,
                 grant: Arca.Test.Actor.grant(@athanor),
                 verify: &Arca.Test.Actor.admits/1
               )

      assert Arca.Repo.get(Row, execution_id) == nil

      assert [] =
               Arca.Repo.all(
                 Ecto.Query.from(a in Arca.Schemas.ExecutionAttempt,
                   where: a.execution_id == ^execution_id
                 )
               )

      assert [] =
               Arca.Repo.all(
                 Ecto.Query.from(e in "execution_events",
                   where: e.execution_id == ^execution_id,
                   select: e.id
                 )
               )

      assert {:ok,
              %{state: "claimed", claimed_by: "boot-recoverer", execution_id: nil, attempts: 0}} =
               Arca.ScheduleOccurrences.get(actor, occurrence.id)
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

defmodule Arca.ExecutionTakeoverTest do
  @moduledoc """
  A stale member's admission of a feed's run, in the sequence that makes
  one stale with no clock drift and no edit to the lease row: the member's
  cached standing passes, the admission waits on its athanor's row, the
  member's lease runs out on the cell's clock, a successor takes the slot
  through `Arca.ControlPlane.take/3`, and only then does the admission go
  on. Admission verifies the member's slot in its own transaction, after
  its last lock, so it commits nothing: no execution, no attempt, no
  started occurrence and no `execution.started` event.

  The admission runs on a connection of its own, outside the sandbox. On
  PostgreSQL it really waits, on the athanor's row, which another
  transaction holds locked across the expiry and the takeover. SQLite's
  one write lock would hold the successor's take behind that transaction
  too, so there the takeover commits first and the admission runs while
  this member's cached standing still says it holds the slot: the same
  divergence between the cache and the row. The case works in an athanor
  of its own, whose rows it deletes when it ends.
  """

  # Writes the process-wide standing record and the claimant switch, and
  # holds a row locked across connections; the case restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, CronSchedule, ScheduleOccurrences}
  alias Arca.Schemas.{CellLease, ExecutionAttempt, ScheduleOccurrence}
  alias Arca.Schemas.CronSchedule, as: ScheduleRow
  alias Arca.Schemas.Execution, as: Row
  alias Ecto.Adapters.SQL.Sandbox

  # Short enough to run out while the case waits; the setup is done under
  # a long lease, which the member then renews to this.
  @lease_ms 300

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    athanor = "ath_exec_fence_#{System.unique_integer([:positive])}"
    node = "node-exec-fence-#{System.unique_integer([:positive])}"
    unboxed(fn -> Arca.Test.Actor.ensure_athanor_row(athanor) end)

    on_exit(fn ->
      unboxed(fn ->
        ids = from(e in Row, where: e.athanor_id == ^athanor, select: e.id)

        Arca.Repo.delete_all(
          from(i in "execution_events", where: i.execution_id in subquery(ids))
        )

        Arca.Repo.delete_all(from(a in ExecutionAttempt, where: a.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(e in Row, where: e.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(o in ScheduleOccurrence, where: o.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(s in ScheduleRow, where: s.athanor_id == ^athanor))
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
      end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    # A claimant runs, as a deployment's does, and this member holds its
    # slot under a lease long enough for the case's own setup.
    Application.put_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot_a", 60_000) end)

    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor), slot: slot}
  end

  test "a feed's admission after ownership loss writes no execution, attempt, started occurrence or event",
       %{actor: actor, slot: slot} do
    athanor = actor.athanor_id
    {feed, occurrence} = unboxed(fn -> claimed_feed!(actor) end)
    grant = unboxed(fn -> Arca.Test.Actor.grant(athanor) end)
    execution_id = Prima.UUID7.execution_id()

    answer =
      stale_write(slot, lock_athanor(athanor), fn ->
        Arca.Execution.admit(
          %{
            id: execution_id,
            reference: "catalyst:local.markets:1.0.0",
            user_id: actor.user_id,
            athanor_id: athanor,
            component_type: "catalyst",
            schedule_id: feed.id,
            origin: :schedule
          },
          occurrence_id: occurrence.id,
          grant: grant,
          verify: &Arca.Test.Actor.verify/1
        )
      end)

    assert answer == {:error, :not_owner}

    unboxed(fn ->
      assert Arca.Repo.get(Row, execution_id) == nil
      assert [] = Arca.Repo.all(from(a in ExecutionAttempt, where: a.athanor_id == ^athanor))

      assert [] =
               Arca.Repo.all(
                 from(i in "execution_events", where: i.athanor_id == ^athanor, select: i.id)
               )

      assert {:ok, %{state: "claimed", execution_id: nil, attempts: 0, claimed_by: claimant}} =
               ScheduleOccurrences.get(actor, occurrence.id)

      assert claimant == Prima.Boot.id()
    end)
  end

  # A feed bound and its first occurrence claimed, each under the member's
  # live slot.
  defp claimed_feed!(actor) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => "feed-#{System.unique_integer([:positive])}",
        "label" => "A feed",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{},
        "interval_minutes" => 5,
        "result_shape" => %{"type" => "json"},
        "actions" => []
      })

    {:ok, feed} =
      CronSchedule.create_feed(actor, %{
        binding: binding,
        resolved_reference: "catalyst:local.markets:1.0.0",
        profile_id: "prof_test",
        cap: 10
      })

    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in ScheduleRow, where: s.id == ^feed.id),
        set: [next_run_at: past]
      )

    feed = %{feed | next_run_at: past}
    next = DateTime.add(DateTime.utc_now(), 300, :second)
    # Claimed as this boot, the boot admission starts an occurrence for.
    {:ok, occurrence} = ScheduleOccurrences.claim(feed, Prima.Boot.id(), next)
    {feed, occurrence}
  end

  defp lock_athanor(athanor) do
    fn ->
      from(a in Arca.Schemas.Athanor, where: a.id == ^athanor)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()
    end
  end

  # ---- the stale write ---------------------------------------------------------

  # The member's cached standing passes, `write` waits, the lease runs out
  # and a successor takes the slot, then `write` goes on: on PostgreSQL it
  # waits on `lock`, held by another transaction until the takeover has
  # committed; on SQLite the takeover commits first. Answers what `write`
  # answered.
  defp stale_write(slot, lock, write) do
    slot = expiring!(slot)
    assert ControlPlane.held?()
    test = self()

    if postgres?() do
      holder = holding(lock)

      writer =
        Task.async(fn ->
          unboxed(fn ->
            send(test, {:backend, backend_pid()})
            write.()
          end)
        end)

      assert_receive {:backend, backend}, 15_000
      await_lock_wait(backend)
      taken_over!(slot)
      release(holder)
      Task.await(writer, 30_000)
    else
      taken_over!(slot)
      unboxed(write)
    end
  end

  # The member renews to a short lease, a write of its own, and its
  # cached standing is held whatever the lease then does.
  defp expiring!(slot) do
    {:ok, renewed} = unboxed(fn -> ControlPlane.renew(@lease_ms) end)
    assert renewed.generation == slot.generation
    hold_cached(renewed)
    renewed
  end

  defp hold_cached(slot) do
    ControlPlane.record_slot(slot)
    ControlPlane.record_generation(slot.generation)
    ControlPlane.record({:held, 60_000})
  end

  # The lease runs out on the cell's clock with no edit to its row, and a
  # successor takes the slot over through `take/3`. `take/3` records what
  # it won in this VM's standing; the successor is another member, so this
  # member's own standing is put back.
  defp taken_over!(slot) do
    await_expiry(slot.node)

    assert {:ok, %{generation: generation}} =
             unboxed(fn -> ControlPlane.take(slot.node, slot.node <> "#boot_b", 60_000) end)

    assert generation == slot.generation + 1
    hold_cached(slot)
  end

  defp await_expiry(node, tries \\ 500)
  defp await_expiry(_node, 0), do: flunk("the member's lease never ran out")

  defp await_expiry(node, tries) do
    expired? =
      unboxed(fn ->
        {:ok, %{lease_until: lease_until}} = ControlPlane.slot(node)
        DateTime.compare(lease_until, Arca.ServerMetaStorage.now!()) != :gt
      end)

    unless expired? do
      Process.sleep(20)
      await_expiry(node, tries - 1)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  # Run `lock` in a transaction of its own and hold it open until
  # `release/1`.
  defp holding(lock) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.transaction(fn ->
            lock.()
            send(test, {:holding, self()})

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive {:holding, _pid}, 15_000
    task
  end

  defp release(task) do
    send(task.pid, :commit)
    assert {:ok, _} = Task.await(task, 30_000)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Holds until `pid`'s backend waits on a lock: an observed state, bounded
  # by `tries`, never a timing.
  defp await_lock_wait(pid, tries \\ 500)

  defp await_lock_wait(_pid, 0), do: flunk("the stale admission never waited on a lock")

  defp await_lock_wait(pid, tries) do
    %{rows: rows} =
      unboxed(fn ->
        Arca.Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])
      end)

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(20)
      await_lock_wait(pid, tries - 1)
    end
  end
end
