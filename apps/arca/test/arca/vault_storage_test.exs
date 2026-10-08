# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorageTest do
  use ExUnit.Case, async: false

  alias Arca.VaultStorage
  alias Arca.Test.QueryCounter

  @blocked "needs_consent"

  # Where an entry's material may go, as the canonical text a row holds.
  @destination ~s({"hosts":["api.example.com"],"scheme":"https"})
  @moved ~s({"hosts":["api.example.com"],"paths":["/v1/"],"scheme":"https"})

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    actor = Arca.Test.Actor.local()

    {:ok, actor: actor, other: %Prima.Actor{athanor_id: "ath_other"}}
  end

  defp put!(actor, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "entry-#{System.unique_integer([:positive])}",
          kind: "api_key",
          sealed_payload: "sealed-bytes",
          destination: @destination
        },
        over
      )

    {:ok, entry} = VaultStorage.put(actor, attrs)
    entry
  end

  # A profile whose head consent references `entry_id` — the dependent a
  # binding move has to block. `source_ref` names the component it
  # consents for, a fresh one by default. A revision binds an entry only
  # while it is active, so an entry at `needs_reauth` is bound first and
  # then falls to `needs_reauth`, the order production reaches that state.
  defp dependent_profile!(actor, entry_id, source_ref \\ nil) do
    athanor = actor.athanor_id
    reauth? = status_of(actor, entry_id).status == "needs_reauth"
    if reauth?, do: :ok = VaultStorage.set_status(actor, entry_id, "active")

    {:ok, profile} =
      Arca.ProfileStorage.put(%{
        athanor_id: athanor,
        source_ref: source_ref || "formula:local.consumer-#{System.unique_integer([:positive])}",
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
          blob_digest: Prima.JCS.hash_binary("{}"),
          resolved_policy: "{}",
          activation: "{}",
          admitted_origins: [:interactive],
          granted_by: "test",
          granted_via: "bootstrap"
        },
        [
          %{
            binding_key: "formula:local.consumer|@ingress|default",
            scope: "athanor",
            vault_entry_id: entry_id,
            binding_digest: "sha256:d0"
          }
        ],
        nil
      )

    if reauth?, do: :ok = VaultStorage.set_status(actor, entry_id, "needs_reauth")
    profile
  end

  defp status_of(actor, id) do
    {:ok, entry} = VaultStorage.get(actor, id)
    entry
  end

  defp profile_status(actor, profile_id) do
    {:ok, profile} = Arca.ProfileStorage.get(actor, profile_id)
    profile.status
  end

  describe "the first argument is the actor" do
    test "a plain map, a bare athanor id and a nil athanor are all refused before any query",
         %{actor: actor} do
      QueryCounter.assert_queries(0, fn ->
        # A map carrying the actor's own fields is not a `%Prima.Actor{}`, and
        # neither is the athanor id on its own: both miss every head.
        not_an_actor = %{athanor_id: actor.athanor_id}

        assert_raise FunctionClauseError, fn ->
          apply(VaultStorage, :get, [not_an_actor, "vlt_x"])
        end

        assert_raise FunctionClauseError, fn ->
          apply(VaultStorage, :get, [actor.athanor_id, "vlt_x"])
        end

        assert_raise FunctionClauseError, fn -> apply(VaultStorage, :list, [not_an_actor]) end
        assert_raise FunctionClauseError, fn -> apply(VaultStorage, :list, [actor.athanor_id]) end

        assert_raise FunctionClauseError, fn ->
          apply(VaultStorage, :rotate_payload, [actor.athanor_id, "vlt_x", 0, "sealed"])
        end

        nil_athanor = %Prima.Actor{athanor_id: nil}

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
      empty = %Prima.Actor{athanor_id: ""}

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

      plan = %{expected_rev: 0, sealed_payload: "sealed-x", status: "active", rebind: nil}

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
               VaultStorage.put(actor, %{
                 name: "taken",
                 kind: "api_key",
                 destination: @destination
               })
    end

    test "an entry written without a destination is refused before anything is written",
         %{actor: actor} do
      QueryCounter.assert_queries(0, fn ->
        assert {:error, :destination_required} =
                 VaultStorage.put(actor, %{name: "nowhere", kind: "api_key"})

        assert {:error, :destination_required} =
                 VaultStorage.put(actor, %{name: "nowhere", kind: "api_key", destination: nil})

        # A near spelling of a destination is not one: the binding digest
        # covers the canonical bytes.
        assert {:error, {:invalid_destination, :not_canonical}} =
                 VaultStorage.put(actor, %{
                   name: "nowhere",
                   kind: "api_key",
                   destination: ~s({"scheme":"https","hosts":["API.example.com"]})
                 })

        assert {:error, {:invalid_destination, _}} =
                 VaultStorage.put(actor, %{
                   name: "nowhere",
                   kind: "api_key",
                   destination: ~s({"hosts":["*"]})
                 })
      end)

      assert {:error, :not_found} = VaultStorage.get_by_name(actor, "nowhere")
    end

    test "the destination and disclosure are answered by get and list, attach-only by default",
         %{actor: actor} do
      attached = put!(actor)
      disclosed = put!(actor, %{attach_only: false})

      assert attached.destination == @destination
      assert attached.attach_only == true

      {:ok, fetched} = VaultStorage.get(actor, disclosed.id)
      assert fetched.destination == @destination
      assert fetched.attach_only == false

      {:ok, rows} = VaultStorage.list(actor)
      listed = Map.new(rows, &{&1.id, {&1.destination, &1.attach_only}})
      assert listed[attached.id] == {@destination, true}
      assert listed[disclosed.id] == {@destination, false}
    end

    test "an athanor's first entry of a provider becomes its default, and a second leaves it",
         %{actor: actor} do
      first = put!(actor, %{provider_hint: "openai.com"})
      _second = put!(actor, %{provider_hint: "openai.com"})
      _unnamed = put!(actor, %{provider_hint: ""})

      assert {:ok, %{vault_entry_id: id, instance_entry_id: nil}} =
               Arca.VaultDefaults.get(actor, "openai.com")

      assert id == first.id
      assert {:ok, [%{provider_hint: "openai.com"}]} = Arca.VaultDefaults.list(actor)
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

    test "removes the default naming the entry in the same transaction", %{actor: actor} do
      entry = put!(actor, %{provider_hint: "anthropic.com"})
      assert {:ok, %{vault_entry_id: id}} = Arca.VaultDefaults.get(actor, "anthropic.com")
      assert id == entry.id

      assert :ok = VaultStorage.tombstone(actor, entry.id)
      assert {:error, :not_found} = Arca.VaultDefaults.get(actor, "anthropic.com")
    end

    test "frees the living-name slot", %{actor: actor} do
      entry = put!(actor, %{name: "unique-name"})
      :ok = VaultStorage.tombstone(actor, entry.id)

      assert {:ok, _} =
               VaultStorage.put(actor, %{
                 name: "unique-name",
                 kind: "api_key",
                 destination: @destination
               })

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
      :ok =
        Arca.ProfileStorage.set_status(
          Prima.Actor.in_athanor(actor.athanor_id),
          profile.id,
          "active"
        )

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

    test "the destination and the disclosure move as binding columns", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})
      profile = dependent_profile!(actor, entry.id)

      assert {:ok, [_]} =
               VaultStorage.move_binding(
                 actor,
                 entry.id,
                 "sha256:d0",
                 %{destination: @moved, attach_only: false, binding_digest: "sha256:d1"},
                 @blocked
               )

      row = status_of(actor, entry.id)
      assert row.destination == @moved
      assert row.attach_only == false
      assert row.binding_digest == "sha256:d1"
      assert profile_status(actor, profile.id) == @blocked
    end

    test "a move naming the OAuth endpoints, or a destination off the grammar, writes nothing",
         %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0", oauth_endpoints: ~s({"a":"b"})})
      profile = dependent_profile!(actor, entry.id)

      QueryCounter.assert_queries(0, fn ->
        assert {:error, :endpoints_immutable} =
                 VaultStorage.move_binding(
                   actor,
                   entry.id,
                   "sha256:d0",
                   %{oauth_endpoints: ~s({"token_url":"https://elsewhere.test/t"})},
                   @blocked
                 )

        assert {:error, :endpoints_immutable} =
                 VaultStorage.commit_payload(actor, entry.id, %{
                   expected_rev: 0,
                   sealed_payload: "sealed-next",
                   status: nil,
                   rebind: %{
                     from_digest: "sha256:d0",
                     changes: %{oauth_endpoints: ~s({"a":"c"}), binding_digest: "sha256:d1"},
                     blocked_status: @blocked
                   }
                 })

        assert {:error, {:invalid_destination, _}} =
                 VaultStorage.move_binding(
                   actor,
                   entry.id,
                   "sha256:d0",
                   %{destination: ~s({"hosts":[]}), binding_digest: "sha256:d1"},
                   @blocked
                 )
      end)

      row = status_of(actor, entry.id)
      assert row.oauth_endpoints == ~s({"a":"b"})
      assert row.binding_digest == "sha256:d0"
      assert row.payload_rev == 0
      assert profile_status(actor, profile.id) == "active"
    end

    # A revoked profile is not blocked: blocking it would revive it beside
    # the live profile of the same component, label and kind, which the
    # active-identity index refuses, and the whole rebind would roll back.
    # It stays revoked, and nothing runs through it.
    test "a revoked profile beside a live one of its identity stays revoked; the live one is blocked",
         %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})
      source = "formula:local.shared-#{System.unique_integer([:positive])}"
      old = dependent_profile!(actor, entry.id, source)
      :ok = Arca.ProfileStorage.set_status(actor, old.id, "revoked")
      live = dependent_profile!(actor, entry.id, source)

      assert {:ok, [affected]} =
               VaultStorage.move_binding(
                 actor,
                 entry.id,
                 "sha256:d0",
                 %{destination: @moved, binding_digest: "sha256:d1"},
                 @blocked
               )

      assert affected == live.id
      assert profile_status(actor, live.id) == @blocked
      assert profile_status(actor, old.id) == "revoked"

      row = status_of(actor, entry.id)
      assert {row.destination, row.binding_digest} == {@moved, "sha256:d1"}
    end

    test "a tombstoned entry has no binding to move", %{actor: actor} do
      entry = put!(actor, %{binding_digest: "sha256:d0"})
      :ok = VaultStorage.tombstone(actor, entry.id)

      assert {:error, :binding_moved} =
               VaultStorage.move_binding(actor, entry.id, "sha256:d0", %{}, @blocked)
    end
  end

  describe "set_status/3 — a status write never undoes a delete or a revoke" do
    test "a tombstoned or revoked entry is never marked again", %{actor: actor} do
      for {ended, targets} <- [
            {"tombstoned", ~w(active needs_reauth revoked)},
            {"revoked", ~w(active needs_reauth)}
          ],
          target <- targets do
        entry = put!(actor)

        :ok =
          if ended == "tombstoned",
            do: VaultStorage.tombstone(actor, entry.id),
            else: VaultStorage.set_status(actor, entry.id, "revoked")

        assert {:error, {:entry_unavailable, ^ended}} =
                 VaultStorage.set_status(actor, entry.id, target)

        assert status_of(actor, entry.id).status == ended
      end
    end

    test "the transitions it admits, a status it does not know and a missing row",
         %{actor: actor} do
      entry = put!(actor)
      assert :ok = VaultStorage.set_status(actor, entry.id, "needs_reauth")
      assert :ok = VaultStorage.set_status(actor, entry.id, "active")
      assert :ok = VaultStorage.set_status(actor, entry.id, "revoked")
      assert :ok = VaultStorage.set_status(actor, entry.id, "revoked")

      for status <- ["tombstoned", "whatever"] do
        assert {:error, {:invalid_status, ^status}} =
                 VaultStorage.set_status(actor, put!(actor).id, status)
      end

      assert {:error, :not_found} = VaultStorage.set_status(actor, "vlt_missing", "revoked")
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

    # A rotate or a grant read the entry at `needs_reauth`, and the owner
    # deleted or revoked it before the commit: the reactivation does not
    # undo that, no binding moves and no material lands.
    test "a reactivation never undoes a delete or a revoke that landed after the read",
         %{actor: actor} do
      for {ended, material} <- [{"tombstoned", nil}, {"revoked", "sealed-bytes"}] do
        entry = put!(actor, %{status: "needs_reauth", binding_digest: "sha256:d0"})
        profile = dependent_profile!(actor, entry.id)

        :ok =
          if ended == "tombstoned",
            do: VaultStorage.tombstone(actor, entry.id),
            else: VaultStorage.set_status(actor, entry.id, "revoked")

        moves = %{
          from_digest: "sha256:d0",
          changes: %{oauth_scopes: ~s(["b"]), binding_digest: "sha256:d1"},
          blocked_status: @blocked
        }

        for rebind <- [nil, moves] do
          assert {:error, {:entry_unavailable, ^ended}} =
                   VaultStorage.commit_payload(actor, entry.id, %{
                     expected_rev: 0,
                     sealed_payload: "sealed-late",
                     status: "active",
                     rebind: rebind
                   })
        end

        row = status_of(actor, entry.id)
        assert row.status == ended
        assert row.sealed_payload == material
        assert row.payload_rev == 0
        assert row.binding_digest == "sha256:d0"
        assert profile_status(actor, profile.id) == "active"
      end
    end

    test "a plan's status only reactivates: an active row stays active, any other is refused",
         %{actor: actor} do
      entry = put!(actor)

      assert {:ok, %{payload_rev: 1}} =
               VaultStorage.commit_payload(actor, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-next",
                 status: "active",
                 rebind: nil
               })

      for status <- ["needs_reauth", "revoked", "tombstoned"] do
        assert {:error, {:invalid_status, ^status}} =
                 VaultStorage.commit_payload(actor, entry.id, %{
                   expected_rev: 1,
                   sealed_payload: "sealed-other",
                   status: status,
                   rebind: nil
                 })
      end

      row = status_of(actor, entry.id)
      assert row.status == "active"
      assert row.sealed_payload == "sealed-next"
      assert row.payload_rev == 1
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

    # A refresh read the entry at revision 0 and is waiting on its provider
    # when the owner deletes the entry: its write-back lands on nothing.
    test "a write-back after tombstone/2 leaves sealed_payload nil", %{actor: actor} do
      entry = put!(actor)
      :ok = VaultStorage.tombstone(actor, entry.id)

      assert {:error, {:entry_unavailable, "tombstoned"}} =
               VaultStorage.rotate_payload(actor, entry.id, 0, "sealed-late")

      row = status_of(actor, entry.id)
      assert row.sealed_payload == nil
      assert row.payload_rev == 0
    end

    test "a write-back after a revoke writes nothing either", %{actor: actor} do
      entry = put!(actor)
      :ok = VaultStorage.set_status(actor, entry.id, "revoked")

      assert {:error, {:entry_unavailable, "revoked"}} =
               VaultStorage.rotate_payload(actor, entry.id, 0, "sealed-late")

      assert {:error, {:entry_unavailable, "revoked"}} =
               VaultStorage.commit_payload(actor, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-late",
                 status: nil,
                 rebind: nil
               })

      row = status_of(actor, entry.id)
      assert row.sealed_payload == "sealed-bytes"
      assert row.payload_rev == 0
    end
  end
end
