# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.WritersTest do
  @moduledoc """
  `Arca.Test.Writers` writes the rows the lib writers it replaces write:
  a row written by a copy reads back field for field as the lib function's
  row does, and a refusal is the same refusal.
  """

  use ExUnit.Case, async: false

  alias Arca.Execution
  alias Arca.ProfileStorage
  alias Arca.Test.Writers

  @athanor Arca.Test.Actor.athanor_id()

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  # Every field a reader answers, but the ones each write makes its own.
  defp shape(row, own), do: Map.drop(row, [:id, :inserted_at, :updated_at | own])

  defp profile_attrs(source_ref, over \\ %{}) do
    Map.merge(
      %{
        athanor_id: @athanor,
        source_ref: source_ref,
        kind: "owner",
        label: "default",
        status: "active"
      },
      over
    )
  end

  test "put_profile/1 writes the row put/1 writes, and refuses as it does" do
    suffix = System.unique_integer([:positive])
    actor = Prima.Actor.in_athanor(@athanor)

    {:ok, lib} = ProfileStorage.put(profile_attrs("reagent:local.lib-#{suffix}"))
    {:ok, copy} = Writers.put_profile(profile_attrs("reagent:local.copy-#{suffix}"))

    assert "prof_" <> _ = copy.id
    assert {:ok, lib_read} = ProfileStorage.get(actor, lib.id)
    assert {:ok, copy_read} = ProfileStorage.get(actor, copy.id)
    assert copy_read.source_ref == "reagent:local.copy-#{suffix}"
    assert shape(copy_read, [:source_ref]) == shape(lib_read, [:source_ref])

    for over <- [%{label: "prof_sneaky"}, %{label: ""}, %{kind: "guest"}, %{status: "sleeping"}] do
      attrs = profile_attrs("reagent:local.refused-#{suffix}", over)
      assert Writers.put_profile(attrs) == ProfileStorage.put(attrs)
    end

    assert_raise KeyError, fn ->
      Writers.put_profile(Map.delete(profile_attrs("x"), :athanor_id))
    end
  end

  defp execution_attrs(id, over \\ %{}) do
    Map.merge(
      %{
        id: id,
        reference: "formula:local.writers:1.0.0",
        user_id: "user_writers",
        athanor_id: @athanor,
        started_at: ~U[2026-10-13 00:00:00.000000Z],
        status: "running",
        component_type: "formula"
      },
      over
    )
  end

  test "record_start/1 and record_complete/4 write the rows the lib's write, and refuse as they do" do
    suffix = System.unique_integer([:positive])
    lib_id = "exec_writers_lib_#{suffix}"
    copy_id = "exec_writers_copy_#{suffix}"
    actor = Prima.Actor.in_athanor(@athanor)

    {:ok, _} = Execution.record_start(execution_attrs(lib_id))
    {:ok, _} = Writers.record_start(execution_attrs(copy_id))

    assert shape(Execution.get_tenant(actor, copy_id), []) ==
             shape(Execution.get_tenant(actor, lib_id), [])

    assert Writers.record_start(execution_attrs("exec_attempt", %{current_attempt: "att_x"})) ==
             {:error, :illegal_transition}

    end_attrs = %{
      completed_at: ~U[2026-10-13 00:00:01.000000Z],
      duration_ms: 1_000,
      status: "completed"
    }

    standing = Arca.Test.Actor.standing(@athanor)

    {:ok, _} = Execution.record_complete(actor, lib_id, end_attrs, standing)
    {:ok, copy_end} = Writers.record_complete(actor, copy_id, end_attrs, standing)
    assert copy_end.status == "completed"

    assert shape(Execution.get_tenant(actor, copy_id), []) ==
             shape(Execution.get_tenant(actor, lib_id), [])

    # A row that already left `running`, an outcome its status does not
    # allow, a row that is not there and a missing standing, each refused
    # as the lib refuses it.
    for {id, attrs, opts} <- [
          {copy_id, end_attrs, standing},
          {copy_id, Map.put(end_attrs, :outcome, "cancelled"), standing},
          {"exec_writers_missing_#{suffix}", end_attrs, standing},
          {copy_id, end_attrs, []}
        ] do
      lib_id_for = if id == copy_id, do: lib_id, else: id

      assert Writers.record_complete(actor, id, attrs, opts) ==
               Execution.record_complete(actor, lib_id_for, attrs, opts)
    end
  end
end
