# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorageTest do
  use ExUnit.Case, async: false

  alias Arca.VaultStorage
  alias Cyfr.Test.QueryCounter

  @blocked "needs_consent"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    actor = Sanctum.Context.actor(ctx)

    {:ok, ctx: ctx, actor: actor, other: %Cyfr.Actor{athanor_id: "ath_other"}}
  end

  defp put!(actor, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "entry-#{System.unique_integer([:positive])}",
          kind: "api_key",
          sealed_payload: "sealed-bytes"
        },
        over
      )

    {:ok, entry} = VaultStorage.put(actor, attrs)
    entry
  end

  # A profile whose head consent references `entry_id` — the dependent a
  # binding move has to block.
  defp dependent_profile!(actor, entry_id) do
    athanor = actor.athanor_id

    {:ok, profile} =
      Arca.ProfileStorage.put(%{
        athanor_id: athanor,
        source_ref: "formula:local.consumer-#{System.unique_integer([:positive])}",
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _consent} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: athanor,
          profile_id: profile.id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Cyfr.JCS.hash_binary("{}"),
          resolved_policy: "{}",
          activation: "{}",
          granted_by: "test",
          granted_via: "bootstrap"
        },
        [%{vault_entry_id: entry_id, binding_digest: "sha256:d0"}],
        nil
      )

    profile
  end

  defp status_of(actor, id) do
    {:ok, entry} = VaultStorage.get(actor, id)
    entry
  end

  defp profile_status(actor, profile_id) do
    {:ok, profile} = Arca.ProfileStorage.get(actor.athanor_id, profile_id)
    profile.status
  end

  describe "the first argument is the actor" do
    test "a context, a bare athanor id and a nil athanor are all refused before any query",
         %{ctx: ctx, actor: actor} do
      QueryCounter.assert_queries(0, fn ->
        assert_raise FunctionClauseError, fn -> VaultStorage.get(ctx, "vlt_x") end
        assert_raise FunctionClauseError, fn -> VaultStorage.get(actor.athanor_id, "vlt_x") end
        assert_raise FunctionClauseError, fn -> VaultStorage.list(ctx) end
        assert_raise FunctionClauseError, fn -> VaultStorage.list(actor.athanor_id) end

        assert_raise FunctionClauseError, fn ->
          VaultStorage.rotate_payload(actor.athanor_id, "vlt_x", 0, "sealed")
        end

        nil_athanor = %Cyfr.Actor{athanor_id: nil}

        assert {:error, :no_athanor} = VaultStorage.get(nil_athanor, "vlt_x")
        assert {:error, :no_athanor} = VaultStorage.get_by_name(nil_athanor, "n")
        assert {:error, :no_athanor} = VaultStorage.list(nil_athanor)

        assert {:error, :no_athanor} =
                 VaultStorage.put(nil_athanor, %{name: "n", kind: "api_key"})

        assert {:error, :no_athanor} =
                 VaultStorage.update_meta(nil_athanor, "vlt_x", %{name: "n"})

        assert {:error, :no_athanor} = VaultStorage.set_status(nil_athanor, "vlt_x", "revoked")
        assert {:error, :no_athanor} = VaultStorage.tombstone(nil_athanor, "vlt_x")
        assert {:error, :no_athanor} = VaultStorage.touch_last_used(nil_athanor, "vlt_x")

        assert {:error, :no_athanor} =
                 VaultStorage.rotate_payload(nil_athanor, "vlt_x", 0, "sealed")

        assert {:error, :no_athanor} =
                 VaultStorage.move_binding(nil_athanor, "vlt_x", nil, %{}, @blocked)

        assert {:error, :no_athanor} =
                 VaultStorage.commit_payload(nil_athanor, "vlt_x", %{
                   expected_rev: 0,
                   sealed_payload: "sealed",
                   status: nil,
                   rebind: nil
                 })
      end)
    end

    test "an empty athanor is refused, not read as a tenant with nothing in it",
         %{actor: actor} do
      entry = put!(actor, %{name: "resolved-only"})
      empty = %Cyfr.Actor{athanor_id: ""}

      # `""` filters as a tenant and matches nothing, so a facade that let
      # it through would answer an ordinary empty result and make "no
      # tenant was resolved" indistinguishable from "no such credential".
      # On a credential store those must stay apart, so it is refused
      # before any query, like `nil`.
      QueryCounter.assert_queries(0, fn ->
        assert {:error, :no_athanor} = VaultStorage.get(empty, entry.id)
        assert {:error, :no_athanor} = VaultStorage.get_by_name(empty, "resolved-only")
        assert {:error, :no_athanor} = VaultStorage.list(empty)
        assert {:error, :no_athanor} = VaultStorage.put(empty, %{name: "n", kind: "api_key"})
        assert {:error, :no_athanor} = VaultStorage.update_meta(empty, entry.id, %{name: "n"})
        assert {:error, :no_athanor} = VaultStorage.set_status(empty, entry.id, "revoked")
        assert {:error, :no_athanor} = VaultStorage.tombstone(empty, entry.id)
        assert {:error, :no_athanor} = VaultStorage.touch_last_used(empty, entry.id)

        assert {:error, :no_athanor} =
                 VaultStorage.rotate_payload(empty, entry.id, 0, "sealed")

        assert {:error, :no_athanor} =
                 VaultStorage.move_binding(empty, entry.id, nil, %{}, @blocked)

        assert {:error, :no_athanor} =
                 VaultStorage.commit_payload(empty, entry.id, %{
                   expected_rev: 0,
                   sealed_payload: "sealed",
                   status: nil,
                   rebind: nil
                 })
      end)

      # The refusal is a different word from the miss a resolved tenant
      # gets, so the two never blur.
      assert {:error, :not_found} = VaultStorage.get(actor, "vlt_nonexistent")
    end

    test "the tenant is never an argument: put refuses an athanor_id in its attrs",
         %{actor: actor, other: other} do
      assert_raise ArgumentError, ~r/the tenant comes from the actor/, fn ->
        VaultStorage.put(actor, %{
          athanor_id: other.athanor_id,
          name: "smuggled",
          kind: "api_key"
        })
      end

      assert {:error, :not_found} = VaultStorage.get_by_name(other, "smuggled")
    end

    test "the row that comes back cannot name a tenant", %{actor: actor} do
      entry = put!(actor)

      refute Map.has_key?(entry, :athanor_id)
      refute Map.has_key?(entry, :__struct__)

      {:ok, fetched} = VaultStorage.get(actor, entry.id)
      refute Map.has_key?(fetched, :athanor_id)

      {:ok, [listed | _]} = VaultStorage.list(actor)
      refute Map.has_key?(listed, :athanor_id)
    end
  end

  describe "tenant isolation" do
    test "another athanor's entry is indistinguishable from one that does not exist",
         %{actor: actor, other: other} do
      entry = put!(actor, %{name: "a-only"})

      # Byte-identical answers: a different error here would tell the
      # caller that an id it guessed exists in some other athanor.
      assert VaultStorage.get(other, entry.id) == VaultStorage.get(other, "vlt_nonexistent")
      assert {:error, :not_found} = VaultStorage.get(other, entry.id)
      assert {:error, :not_found} = VaultStorage.get_by_name(other, "a-only")

      assert VaultStorage.update_meta(other, entry.id, %{name: "x"}) ==
               VaultStorage.update_meta(other, "vlt_nonexistent", %{name: "x"})

      assert {:error, :not_found} = VaultStorage.set_status(other, entry.id, "revoked")
      assert {:error, :not_found} = VaultStorage.tombstone(other, entry.id)

      assert {:error, :payload_conflict} =
               VaultStorage.rotate_payload(other, entry.id, 0, "sealed-x")

      assert {:error, :binding_moved} =
               VaultStorage.move_binding(
                 other,
                 entry.id,
                 nil,
                 %{oauth_scopes: ~s(["x"])},
                 @blocked
               )

      plan = %{expected_rev: 0, sealed_payload: "sealed-x", status: "revoked", rebind: nil}

      assert VaultStorage.commit_payload(other, entry.id, plan) ==
               VaultStorage.commit_payload(other, "vlt_nonexistent", plan)

      assert {:error, :not_found} = VaultStorage.commit_payload(other, entry.id, plan)

      # Nothing the foreign actor asked for landed.
      row = status_of(actor, entry.id)
      assert row.name == "a-only"
      assert row.status == "active"
      assert row.payload_rev == 0
      assert row.sealed_payload == "sealed-bytes"
    end

    test "two athanors may hold the same living name", %{actor: actor, other: other} do
      _a = put!(actor, %{name: "shared"})
      _b = put!(other, %{name: "shared"})

      {:ok, a_rows} = VaultStorage.list(actor)
      {:ok, b_rows} = VaultStorage.list(other)

      assert length(Enum.filter(a_rows, &(&1.name == "shared"))) == 1
      assert length(Enum.filter(b_rows, &(&1.name == "shared"))) == 1
    end
  end

  describe "put/2" do
    test "a living name is taken, and the refusal is a word rather than a changeset",
         %{actor: actor} do
      _entry = put!(actor, %{name: "taken"})

      assert {:error, :name_taken} =
               VaultStorage.put(actor, %{name: "taken", kind: "api_key"})
    end
  end

  describe "list/2" do
    test "excludes tombstoned rows unless widened", %{actor: actor} do
      live = put!(actor)
      dead = put!(actor)
      :ok = VaultStorage.tombstone(actor, dead.id)

      {:ok, rows} = VaultStorage.list(actor)
      ids = Enum.map(rows, & &1.id)
      assert live.id in ids
      refute dead.id in ids

      {:ok, all} = VaultStorage.list(actor, include_tombstoned: true)
      assert dead.id in Enum.map(all, & &1.id)
    end
  end

  describe "update_meta/3" do
    test "renames; unknown rows are not_found", %{actor: actor} do
      entry = put!(actor)

      assert :ok = VaultStorage.update_meta(actor, entry.id, %{name: "renamed"})
      assert status_of(actor, entry.id).name == "renamed"

      assert {:error, :not_found} = VaultStorage.update_meta(actor, "vlt_missing", %{name: "x"})
    end
  end

  describe "tombstone/2" do
    test "flips status and erases the sealed payload in one update", %{actor: actor} do
      entry = put!(actor)

      assert :ok = VaultStorage.tombstone(actor, entry.id)

      row = status_of(actor, entry.id)
      assert row.status == "tombstoned"
      assert row.sealed_payload == nil
    end

    test "frees the living-name slot", %{actor: actor} do
      entry = put!(actor, %{name: "unique-name"})
      :ok = VaultStorage.tombstone(actor, entry.id)

      assert {:ok, _} = VaultStorage.put(actor, %{name: "unique-name", kind: "api_key"})
      assert {:error, :not_found} = VaultStorage.get_by_name(actor, "missing")
    end
  end

  describe "move_binding/5 — the compare-and-set and its invalidation are one transaction" do
    test "the binding moves and every dependent profile is blocked with it", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})
      profile = dependent_profile!(actor, entry.id)

      assert {:ok, [affected]} =
               VaultStorage.move_binding(
                 actor,
                 entry.id,
                 "sha256:d0",
                 %{oauth_scopes: ~s(["a"]), binding_digest: "sha256:d1"},
                 @blocked
               )

      assert affected == profile.id

      row = status_of(actor, entry.id)
      assert row.binding_digest == "sha256:d1"
      assert row.oauth_scopes == ~s(["a"])
      assert profile_status(actor, profile.id) == @blocked
      # provider_hint is not an accepted key — it lives in the AAD.
      assert row.provider_hint == ""
    end

    test "two rebinds read the same digest: one wins, the loser is refused and blocks nothing",
         %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})
      profile = dependent_profile!(actor, entry.id)

      # Both readers hold "sha256:d0" — what a concurrent pair would.
      read_by_both = entry.binding_digest

      assert {:ok, [_]} =
               VaultStorage.move_binding(
                 actor,
                 entry.id,
                 read_by_both,
                 %{oauth_scopes: ~s(["winner"]), binding_digest: "sha256:winner"},
                 @blocked
               )

      # The winner blocked the dependent; put it back so the loser's own
      # effect on it, if any, is the only thing the assertion can see.
      :ok = Arca.ProfileStorage.set_status(actor.athanor_id, profile.id, "active")

      assert {:error, :binding_moved} =
               VaultStorage.move_binding(
                 actor,
                 entry.id,
                 read_by_both,
                 %{oauth_scopes: ~s(["loser"]), binding_digest: "sha256:loser"},
                 @blocked
               )

      row = status_of(actor, entry.id)
      assert row.binding_digest == "sha256:winner"
      assert row.oauth_scopes == ~s(["winner"])
      # No profile points at the losing binding: the loser wrote nothing at
      # all, so the invalidation it would have done never escaped either.
      assert profile_status(actor, profile.id) == "active"
    end

    test "a tombstoned entry has no binding to move", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})
      :ok = VaultStorage.tombstone(actor, entry.id)

      assert {:error, :binding_moved} =
               VaultStorage.move_binding(actor, entry.id, "sha256:d0", %{}, @blocked)
    end
  end

  describe "commit_payload/3 — a material write and everything that belongs to it" do
    test "the payload, the status and the binding move land together", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0", status: "needs_reauth"})
      profile = dependent_profile!(actor, entry.id)

      assert {:ok, %{payload_rev: 1, affected: [affected]}} =
               VaultStorage.commit_payload(actor, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-next",
                 status: "active",
                 rebind: %{
                   from_digest: "sha256:d0",
                   changes: %{oauth_scopes: ~s(["b"]), binding_digest: "sha256:d1"},
                   blocked_status: @blocked
                 }
               })

      assert affected == profile.id

      row = status_of(actor, entry.id)
      assert row.payload_rev == 1
      assert row.sealed_payload == "sealed-next"
      assert row.status == "active"
      assert row.binding_digest == "sha256:d1"
      assert profile_status(actor, profile.id) == @blocked
    end

    test "with no rebind it is a plain rotate that still carries its status flip",
         %{actor: actor} do
      entry = put!(actor, %{status: "needs_reauth"})

      assert {:ok, %{payload_rev: 1, affected: []}} =
               VaultStorage.commit_payload(actor, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-next",
                 status: "active",
                 rebind: nil
               })

      row = status_of(actor, entry.id)
      assert row.status == "active"
      assert row.payload_rev == 1
    end

    test "a rotate that fails on its last step leaves the entry at its previous version",
         %{actor: actor} do
      entry =
        put!(actor, %{
          binding_digest: "sha256:d0",
          status: "needs_reauth",
          oauth_scopes: ~s(["before"])
        })

      profile = dependent_profile!(actor, entry.id)

      # The payload compare-and-set is the last statement in the
      # transaction, so a lost race has the status flip, the binding move
      # and the invalidation of every dependent profile behind it. All of
      # it must come back.
      assert {:error, :payload_conflict} =
               VaultStorage.commit_payload(actor, entry.id, %{
                 expected_rev: 7,
                 sealed_payload: "sealed-next",
                 status: "active",
                 rebind: %{
                   from_digest: "sha256:d0",
                   changes: %{oauth_scopes: ~s(["after"]), binding_digest: "sha256:d1"},
                   blocked_status: @blocked
                 }
               })

      row = status_of(actor, entry.id)
      assert row.payload_rev == 0
      assert row.sealed_payload == "sealed-bytes"
      assert row.status == "needs_reauth"
      assert row.binding_digest == "sha256:d0"
      assert row.oauth_scopes == ~s(["before"])
      assert profile_status(actor, profile.id) == "active"
    end

    test "a binding that cannot move leaves the material where it was", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})

      assert {:error, :binding_moved} =
               VaultStorage.commit_payload(actor, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-next",
                 status: nil,
                 rebind: %{
                   from_digest: "sha256:stale",
                   changes: %{binding_digest: "sha256:d1"},
                   blocked_status: @blocked
                 }
               })

      row = status_of(actor, entry.id)
      assert row.payload_rev == 0
      assert row.sealed_payload == "sealed-bytes"
      assert row.binding_digest == "sha256:d0"
    end

    test "a crash between the writes leaves no half-granted state", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0", status: "needs_reauth"})
      profile = dependent_profile!(actor, entry.id)

      # An unstorable binding column: the status flip has already been
      # written when the adapter refuses the next statement, and the
      # process dies mid-transaction rather than answering.
      assert_raise Ecto.Query.CastError, fn ->
        VaultStorage.commit_payload(actor, entry.id, %{
          expected_rev: 0,
          sealed_payload: "sealed-next",
          status: "active",
          rebind: %{
            from_digest: "sha256:d0",
            changes: %{oauth_scopes: 12_345},
            blocked_status: @blocked
          }
        })
      end

      row = status_of(actor, entry.id)
      assert row.status == "needs_reauth"
      assert row.payload_rev == 0
      assert row.sealed_payload == "sealed-bytes"
      assert row.binding_digest == "sha256:d0"
      assert profile_status(actor, profile.id) == "active"
    end
  end

  describe "rotate_payload/4 — the bare compare-and-set" do
    test "the loser of a revision race gets payload_conflict", %{actor: actor} do
      entry = put!(actor)

      assert :ok = VaultStorage.rotate_payload(actor, entry.id, 0, "sealed-a")
      assert {:error, :payload_conflict} = VaultStorage.rotate_payload(actor, entry.id, 0, "b")

      row = status_of(actor, entry.id)
      assert row.payload_rev == 1
      assert row.sealed_payload == "sealed-a"
    end
  end
end
