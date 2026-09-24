# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageUnitsTest do
  @moduledoc """
  A unit is published by its row: one writer holds its draft, a commit
  moves the pointer and appends one journal row in the same transaction
  or does neither, of two writers with one expected revision exactly one
  commits, and every row is the actor's athanor's alone.
  """

  use ExUnit.Case, async: false

  alias Arca.Schemas.StorageUnit
  alias Arca.StorageUnits

  @root "components"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    key = "catalysts/local/unit-#{System.unique_integer([:positive])}/1.0.0"
    {:ok, actor: actor("ath_a"), other: actor("ath_b"), key: key}
  end

  defp actor(athanor_id), do: %Cyfr.Actor{athanor_id: athanor_id, user_id: "usr_writer"}

  defp identity(revision, attrs \\ %{}) do
    Map.merge(
      %{
        new_revision: revision,
        content_identity: Cyfr.Digest.sha256(revision),
        commit_identity: "usr_writer"
      },
      attrs
    )
  end

  # Register, then commit `revision` against what the draft answered.
  defp commit!(actor, key, revision, attrs \\ %{}) do
    token = StorageUnits.new_writer_token()
    {:ok, draft} = StorageUnits.register_draft(actor, @root, key, token)

    assert :committed =
             StorageUnits.commit(
               actor,
               draft,
               draft.current_revision,
               token,
               identity(revision, attrs)
             )

    draft
  end

  defp row(id), do: Arca.Repo.get!(StorageUnit, id)

  defp age_draft!(id) do
    import Ecto.Query, only: [from: 2]

    long_ago = DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(u in StorageUnit, where: u.id == ^id),
        set: [updated_at: long_ago]
      )
  end

  describe "register_draft/4" do
    test "a unit never seen gets a draft row holding the writer's token", %{
      actor: actor,
      key: key
    } do
      assert {:ok, %StorageUnit{} = draft} =
               StorageUnits.register_draft(actor, @root, key, "wrt_1")

      assert %{
               athanor_id: "ath_a",
               root: @root,
               unit_key: ^key,
               state: "draft",
               current_revision: nil,
               draft_writer_token: "wrt_1"
             } = draft

      # A draft publishes nothing.
      assert {:error, :not_found} = StorageUnits.current(actor, @root, key)
      assert {:ok, []} = StorageUnits.journal(actor, @root, key)
    end

    test "registering again with the same token holds; another writer's live draft refuses", %{
      actor: actor,
      key: key
    } do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")

      assert {:ok, %{id: id}} = StorageUnits.register_draft(actor, @root, key, "wrt_1")
      assert id == draft.id

      assert {:error, :stale_writer} = StorageUnits.register_draft(actor, @root, key, "wrt_2")
      assert row(draft.id).draft_writer_token == "wrt_1"
    end

    test "a draft that outlived its lifetime is another writer's to take", %{
      actor: actor,
      key: key
    } do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_dead")
      age_draft!(draft.id)

      assert {:ok, %{draft_writer_token: "wrt_2"}} =
               StorageUnits.register_draft(actor, @root, key, "wrt_2")

      # The writer that lost the draft cannot commit what it staged.
      assert {:error, :stale_writer} =
               StorageUnits.commit(actor, draft, nil, "wrt_dead", identity("rev_dead"))

      assert {:error, :not_found} = StorageUnits.current(actor, @root, key)
    end

    test "a committed unit's next draft keeps its state and its pointer", %{
      actor: actor,
      key: key
    } do
      commit!(actor, key, "rev_1")

      assert {:ok, %{state: "committed", current_revision: "rev_1", draft_writer_token: "wrt_2"}} =
               StorageUnits.register_draft(actor, @root, key, "wrt_2")

      # Readers keep the committed revision while the next is staged.
      assert {:ok, %{current_revision: "rev_1"}} = StorageUnits.current(actor, @root, key)
    end

    test "a retired unit becomes a draft again, the row reused and the journal kept", %{
      actor: actor,
      key: key
    } do
      first = commit!(actor, key, "rev_1")
      assert :ok = StorageUnits.retire(actor, @root, key)

      assert {:ok, %{id: id, state: "draft", current_revision: nil}} =
               StorageUnits.register_draft(actor, @root, key, "wrt_2")

      assert id == first.id
      assert {:ok, [%{new_revision: "rev_1"}]} = StorageUnits.journal(actor, @root, key)
    end
  end

  describe "commit/5" do
    test "moves the pointer, clears the token and appends exactly one journal row", %{
      actor: actor,
      key: key
    } do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")

      assert :committed = StorageUnits.commit(actor, draft, nil, "wrt_1", identity("rev_1"))

      assert {:ok, %{state: "committed", current_revision: "rev_1", draft_writer_token: nil}} =
               StorageUnits.current(actor, @root, key)

      assert {:ok, [%{id: _} = commit]} = StorageUnits.journal(actor, @root, key)

      assert %{
               athanor_id: "ath_a",
               storage_unit_id: unit_id,
               prior_revision: nil,
               new_revision: "rev_1",
               commit_identity: "usr_writer"
             } = commit

      assert unit_id == draft.id
      assert commit.content_identity == Cyfr.Digest.sha256("rev_1")
    end

    test "a second commit appends a second journal row naming the first as its prior", %{
      actor: actor,
      key: key
    } do
      commit!(actor, key, "rev_1")
      commit!(actor, key, "rev_2")

      assert {:ok, %{current_revision: "rev_2"}} = StorageUnits.current(actor, @root, key)

      assert {:ok,
              [
                %{prior_revision: nil, new_revision: "rev_1"},
                %{prior_revision: "rev_1", new_revision: "rev_2"}
              ]} = StorageUnits.journal(actor, @root, key)
    end

    test "of two writers with one expected revision, the second is a stale revision", %{
      actor: actor,
      key: key
    } do
      commit!(actor, key, "rev_1")

      # Both staged against rev_1: the first writer's draft, then — once it
      # has outlived its lifetime — the second's.
      {:ok, first} = StorageUnits.register_draft(actor, @root, key, "wrt_first")
      age_draft!(first.id)
      {:ok, second} = StorageUnits.register_draft(actor, @root, key, "wrt_second")
      assert first.current_revision == "rev_1" and second.current_revision == "rev_1"

      assert :committed =
               StorageUnits.commit(actor, second, "rev_1", "wrt_second", identity("rev_second"))

      assert {:error, :stale_revision} =
               StorageUnits.commit(actor, first, "rev_1", "wrt_first", identity("rev_first"))

      assert {:ok, %{current_revision: "rev_second"}} = StorageUnits.current(actor, @root, key)

      assert {:ok, [_rev_1, %{new_revision: "rev_second"}]} =
               StorageUnits.journal(actor, @root, key)
    end

    test "racing commits with one expected revision: exactly one commits", %{
      actor: actor,
      key: key
    } do
      commit!(actor, key, "rev_1")
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_shared")

      # One token, so nothing but the pointer compare decides the race.
      results =
        1..6
        |> Enum.map(fn i ->
          Task.async(fn ->
            StorageUnits.commit(actor, draft, "rev_1", "wrt_shared", identity("rev_race_#{i}"))
          end)
        end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &(&1 == :committed)) == 1, inspect(results)
      assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 5, inspect(results)
      assert {:ok, [_rev_1, _the_winner]} = StorageUnits.journal(actor, @root, key)
    end

    test "a stale draft token commits nothing", %{actor: actor, key: key} do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")

      assert {:error, :stale_writer} =
               StorageUnits.commit(actor, draft, nil, "wrt_forged", identity("rev_1"))

      assert {:error, :not_found} = StorageUnits.current(actor, @root, key)
      assert {:ok, []} = StorageUnits.journal(actor, @root, key)
      assert row(draft.id).draft_writer_token == "wrt_1"
    end

    test "a retired unit, and a unit with no row, are missing", %{actor: actor, key: key} do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")
      assert :ok = StorageUnits.retire(actor, @root, key)

      assert {:error, :missing_unit} =
               StorageUnits.commit(actor, draft, nil, "wrt_1", identity("rev_1"))

      ghost = %StorageUnit{draft | id: "unit_ghost"}

      assert {:error, :missing_unit} =
               StorageUnits.commit(actor, ghost, nil, "wrt_1", identity("rev_1"))

      assert {:ok, []} = StorageUnits.journal(actor, @root, key)
    end

    test "a journal row that cannot be written takes the pointer move back with it", %{
      actor: actor,
      key: key
    } do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")

      # A content identity the journal's insert refuses, inside the
      # transaction, after the pointer has moved.
      assert_raise Ecto.InvalidChangesetError, fn ->
        StorageUnits.commit(
          actor,
          draft,
          nil,
          "wrt_1",
          identity("rev_1", %{content_identity: ""})
        )
      end

      assert %{state: "draft", current_revision: nil, draft_writer_token: "wrt_1"} = row(draft.id)
      assert {:ok, []} = StorageUnits.journal(actor, @root, key)
    end
  end

  describe "the projection generation" do
    defp change(actor, key) do
      {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, @root, units: [key])
      Enum.find(token.units, &(&1.unit_key == key))
    end

    test "a commit stamps its unit at a new generation, not ready, naming its revision", %{
      actor: actor,
      key: key
    } do
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, token)
      assert %{generation: 0} = change(actor, key)

      assert {:committed, generation} =
               StorageUnits.stamped_commit(actor, draft, nil, token, identity("rev_1"))

      assert %{generation: ^generation, ready: false, source_revision: "rev_1", pending: true} =
               change(actor, key)

      assert {:ok, %{epoch: ^generation}} = Arca.StorageProjectionRoots.epoch(actor, @root)
    end

    test "a refused commit stamps nothing", %{actor: actor, key: key} do
      commit!(actor, key, "rev_1")
      stamped = change(actor, key)
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_2")

      assert {:error, :stale_revision} =
               StorageUnits.stamped_commit(actor, draft, "rev_0", "wrt_2", identity("rev_2"))

      assert change(actor, key) == stamped
    end

    test "a retirement stamps a tombstone, whether or not a row named the unit", %{
      actor: actor,
      other: other,
      key: key
    } do
      commit!(actor, key, "rev_1")

      assert {:retired, retired} = StorageUnits.stamped_retire(actor, @root, key)
      assert %{generation: ^retired, tombstone: true, ready: false, source_revision: nil} =
               change(actor, key)

      assert {:not_found, absent} = StorageUnits.stamped_retire(other, @root, key)
      assert %{generation: ^absent, tombstone: true} = change(other, key)
      assert {:error, :not_found} = StorageUnits.current(other, @root, key)
    end
  end

  describe "abandon_draft/3, retire/3, current_under/2, stage_prefix/3" do
    test "an abandoned first draft is retired; an abandoned next draft leaves the unit committed",
         %{actor: actor, key: key} do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")
      assert :ok = StorageUnits.abandon_draft(actor, draft, "wrt_1")
      assert %{state: "retired", draft_writer_token: nil} = row(draft.id)

      # Given back, so the next writer does not wait out the draft's lifetime.
      commit!(actor, key, "rev_1")
      {:ok, next} = StorageUnits.register_draft(actor, @root, key, "wrt_2")
      assert :ok = StorageUnits.abandon_draft(actor, next, "wrt_2")

      assert %{state: "committed", current_revision: "rev_1", draft_writer_token: nil} =
               row(draft.id)

      # Another writer's draft is left alone.
      {:ok, held} = StorageUnits.register_draft(actor, @root, key, "wrt_3")
      assert :ok = StorageUnits.abandon_draft(actor, held, "wrt_not_mine")
      assert row(draft.id).draft_writer_token == "wrt_3"
    end

    test "retire/3 hides the unit, keeps its last revision and clears the draft", %{
      actor: actor,
      key: key
    } do
      draft = commit!(actor, key, "rev_1")
      {:ok, _next} = StorageUnits.register_draft(actor, @root, key, "wrt_2")

      assert :ok = StorageUnits.retire(actor, @root, key)
      assert {:error, :not_found} = StorageUnits.current(actor, @root, key)

      assert %{state: "retired", current_revision: "rev_1", draft_writer_token: nil} =
               row(draft.id)

      assert {:error, :not_found} = StorageUnits.retire(actor, @root, key)

      assert {:error, :not_found} =
               StorageUnits.retire(actor, @root, "catalysts/local/none/9.9.9")
    end

    test "current_under/2 answers the committed pointers of one root, by key", %{
      actor: actor,
      key: key
    } do
      commit!(actor, key, "rev_1")
      {:ok, _draft} = StorageUnits.register_draft(actor, @root, key <> "-draft", "wrt_d")
      commit!(actor, key <> "-gone", "rev_g")
      :ok = StorageUnits.retire(actor, @root, key <> "-gone")

      {:ok, _} = StorageUnits.register_draft(actor, "aqua", "roles/scribe.md", "wrt_a")

      assert {:ok, pointers} = StorageUnits.current_under(actor, @root)
      assert %{^key => %{current_revision: "rev_1"}} = pointers
      refute Map.has_key?(pointers, key <> "-draft")
      refute Map.has_key?(pointers, key <> "-gone")
      refute Map.has_key?(pointers, "roles/scribe.md")
    end

    test "stage_prefix/3 is the locator's revision prefix of the unit", %{actor: actor, key: key} do
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, "wrt_1")

      assert {:ok, prefix} = StorageUnits.stage_prefix(actor, draft, "rev_1")
      assert prefix == [@root, ".staging" | String.split(key, "/")] ++ ["rev_1"]
      assert Arca.Storage.locate(prefix ++ ["cyfr-manifest.json"]) == :above_unit
    end
  end

  describe "tenancy" do
    test "another athanor sees no row, takes no draft and commits nothing", %{
      actor: actor,
      other: other,
      key: key
    } do
      draft = commit!(actor, key, "rev_1")

      assert {:error, :not_found} = StorageUnits.current(other, @root, key)
      assert {:error, :not_found} = StorageUnits.journal(other, @root, key)
      assert {:error, :not_found} = StorageUnits.retire(other, @root, key)
      assert {:ok, pointers} = StorageUnits.current_under(other, @root)
      refute Map.has_key?(pointers, key)

      # A row handed across is still the other athanor's.
      {:ok, held} = StorageUnits.register_draft(actor, @root, key, "wrt_2")

      assert {:error, :missing_unit} =
               StorageUnits.commit(other, held, "rev_1", "wrt_2", identity("rev_theirs"))

      assert {:error, :missing_unit} = StorageUnits.stage_prefix(other, held, "rev_theirs")
      assert :ok = StorageUnits.abandon_draft(other, held, "wrt_2")
      assert row(draft.id).draft_writer_token == "wrt_2"

      # The same key is its own unit in the other athanor.
      assert {:ok, %{id: theirs}} = StorageUnits.register_draft(other, @root, key, "wrt_b")
      refute theirs == draft.id
      assert {:ok, %{current_revision: "rev_1"}} = StorageUnits.current(actor, @root, key)
    end

    test "an actor with no athanor is refused, and registers nothing", %{key: key} do
      nobody = %Cyfr.Actor{athanor_id: nil, user_id: "usr_x"}
      unit = %StorageUnit{id: "unit_x", athanor_id: "ath_a", root: @root, unit_key: key}

      assert {:error, :no_athanor} = StorageUnits.register_draft(nobody, @root, key, "wrt_1")
      assert {:error, :no_athanor} = StorageUnits.abandon_draft(nobody, unit, "wrt_1")
      assert {:error, :no_athanor} = StorageUnits.stage_prefix(nobody, unit, "rev_1")
      assert {:error, :no_athanor} = StorageUnits.current(nobody, @root, key)
      assert {:error, :no_athanor} = StorageUnits.current_under(nobody, @root)
      assert {:error, :no_athanor} = StorageUnits.retire(nobody, @root, key)
      assert {:error, :no_athanor} = StorageUnits.journal(nobody, @root, key)

      assert {:error, :no_athanor} =
               StorageUnits.commit(nobody, unit, nil, "wrt_1", identity("rev_1"))

      # And an empty athanor is no athanor.
      blank = %Cyfr.Actor{athanor_id: ""}
      assert {:error, :no_athanor} = StorageUnits.register_draft(blank, @root, key, "wrt_1")

      assert {:error, :not_found} = StorageUnits.current(actor("ath_a"), @root, key)
    end
  end
end
