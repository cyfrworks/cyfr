# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.WritersTest do
  @moduledoc """
  `Arca.Test.Writers` writes the rows its fixtures stand on and refuses
  what its contract refuses: each written row reads back whole, field for
  field, and each refusal is its exact answer and leaves the table as it
  was.
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

  # Every column of the row, nil where the writer was given nothing.
  defp blank(schema), do: Map.new(schema.__schema__(:fields), &{&1, nil})

  defp no_profiles?(actor, source_ref),
    do: ProfileStorage.list_for_source(actor, source_ref) == {:ok, []}

  describe "put_profile/1" do
    test "writes the row its attrs name under a fresh prof_ id, or the id given" do
      suffix = System.unique_integer([:positive])
      actor = Prima.Actor.in_athanor(@athanor)
      before = DateTime.utc_now()
      source_ref = "reagent:local.writers-#{suffix}"

      assert {:ok, written} = Writers.put_profile(profile_attrs(source_ref))
      assert "prof_" <> _ = written.id
      assert {:ok, read} = ProfileStorage.get(actor, written.id)
      assert read == written

      assert read ==
               Map.merge(blank(Arca.Schemas.Profile), %{
                 id: written.id,
                 athanor_id: @athanor,
                 source_ref: source_ref,
                 kind: "owner",
                 label: "default",
                 status: "active",
                 inserted_at: read.inserted_at,
                 updated_at: read.inserted_at
               })

      assert DateTime.compare(read.inserted_at, before) != :lt
      assert DateTime.compare(read.inserted_at, DateTime.utc_now()) != :gt

      given = "prof_writers_given_#{suffix}"
      public_ref = "reagent:local.writers-given-#{suffix}"

      assert {:ok, %{id: ^given}} =
               Writers.put_profile(profile_attrs(public_ref, %{id: given, kind: "public"}))

      assert {:ok, given_read} = ProfileStorage.get(actor, given)

      assert given_read ==
               Map.merge(blank(Arca.Schemas.Profile), %{
                 id: given,
                 athanor_id: @athanor,
                 source_ref: public_ref,
                 kind: "public",
                 label: "default",
                 status: "active",
                 inserted_at: given_read.inserted_at,
                 updated_at: given_read.inserted_at
               })
    end

    test "refuses a label shaped like an id or empty, and a kind or status outside the vocabulary, writing nothing" do
      suffix = System.unique_integer([:positive])
      actor = Prima.Actor.in_athanor(@athanor)

      for {over, refusal} <- [
            {%{label: "prof_sneaky"}, {:invalid_label, "prof_sneaky"}},
            {%{label: ""}, {:invalid_label, ""}},
            {%{kind: "guest"}, {:invalid, %{kind: ["is invalid"]}}},
            {%{status: "sleeping"}, {:invalid, %{status: ["is invalid"]}}}
          ] do
        source_ref = "reagent:local.refused-#{suffix}"
        assert Writers.put_profile(profile_attrs(source_ref, over)) == {:error, refusal}
        assert no_profiles?(actor, source_ref)
      end

      missing = "reagent:local.no-athanor-#{suffix}"

      assert_raise KeyError, fn ->
        Writers.put_profile(Map.delete(profile_attrs(missing), :athanor_id))
      end

      assert no_profiles?(actor, missing)
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

  # The row `record_start/1` writes from `execution_attrs(id)`: its attrs,
  # the schema's defaults for kind and event counter, and no attempt.
  defp started(id),
    do:
      Map.merge(
        blank(Arca.Schemas.Execution),
        Map.merge(execution_attrs(id), %{kind: "component", event_seq: 0})
      )

  describe "record_start/1" do
    test "writes a running row with no attempt, and refuses an attempt or an invalid row, writing nothing" do
      suffix = System.unique_integer([:positive])
      id = "exec_writers_#{suffix}"
      actor = Prima.Actor.in_athanor(@athanor)

      assert {:ok, written} = Writers.record_start(execution_attrs(id))
      assert written == started(id)
      assert Execution.get_tenant(actor, id) == started(id)

      attempt_id = "exec_writers_attempt_#{suffix}"

      assert Writers.record_start(execution_attrs(attempt_id, %{current_attempt: "att_x"})) ==
               {:error, :illegal_transition}

      assert Execution.get_tenant(actor, attempt_id) == nil

      invalid_id = "exec_writers_invalid_#{suffix}"

      assert Writers.record_start(execution_attrs(invalid_id, %{status: "sleeping"})) ==
               {:error, {:invalid, %{status: ["is invalid"]}}}

      assert Execution.get_tenant(actor, invalid_id) == nil
    end
  end

  describe "record_complete/4" do
    setup do
      suffix = System.unique_integer([:positive])
      id = "exec_writers_end_#{suffix}"
      {:ok, _} = Writers.record_start(execution_attrs(id))

      %{
        id: id,
        suffix: suffix,
        actor: Prima.Actor.in_athanor(@athanor),
        standing: Arca.Test.Actor.standing(@athanor),
        end_attrs: %{
          completed_at: ~U[2026-10-13 00:00:01.000000Z],
          duration_ms: 1_000,
          status: "completed"
        }
      }
    end

    test "ends a running row in the status its attrs name", ctx do
      ended = Map.merge(started(ctx.id), ctx.end_attrs)

      assert Writers.record_complete(ctx.actor, ctx.id, ctx.end_attrs, ctx.standing) ==
               {:ok, ended}

      assert Execution.get_tenant(ctx.actor, ctx.id) == ended
    end

    test "refuses an outcome its status disallows, a status that ends nothing, another attempt, a missing standing and a missing row, writing nothing",
         ctx do
      for {id, attrs, opts, refusal} <- [
            {ctx.id, Map.put(ctx.end_attrs, :outcome, "cancelled"), ctx.standing,
             :illegal_transition},
            {ctx.id, %{ctx.end_attrs | status: "paused"}, ctx.standing,
             {:invalid, %{status: ["is invalid"]}}},
            {ctx.id, ctx.end_attrs, [{:attempt, "att_other"} | ctx.standing], :not_running},
            {ctx.id, ctx.end_attrs, [], :missing_grant},
            {"exec_writers_missing_#{ctx.suffix}", ctx.end_attrs, ctx.standing, :not_found}
          ] do
        assert Writers.record_complete(ctx.actor, id, attrs, opts) == {:error, refusal}
        assert Execution.get_tenant(ctx.actor, ctx.id) == started(ctx.id)
      end

      assert Execution.get_tenant(ctx.actor, "exec_writers_missing_#{ctx.suffix}") == nil
    end

    test "refuses a row that already left running, leaving it as it ended", ctx do
      {:ok, ended} = Writers.record_complete(ctx.actor, ctx.id, ctx.end_attrs, ctx.standing)
      failed = %{ctx.end_attrs | status: "failed"}

      assert Writers.record_complete(ctx.actor, ctx.id, failed, ctx.standing) ==
               {:error, :not_running}

      assert Execution.get_tenant(ctx.actor, ctx.id) == ended
    end
  end
end
