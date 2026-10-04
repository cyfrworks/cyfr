# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstanceEntriesTest do
  use ExUnit.Case, async: false

  require Arca.Repo.Errors
  require Ecto.Query

  alias Arca.InstanceEntries
  alias Arca.Test.QueryCounter

  @destination ~s({"hosts":["api.openai.com"],"methods":["GET","POST"],"paths":["/v1/"],"scheme":"https"})
  @narrowed ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/chat/"],"scheme":"https"})

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    {:ok, platform: Arca.Test.Actor.platform()}
  end

  defp attrs(over \\ %{}) do
    Map.merge(
      %{
        name: "openai-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "openai.com",
        field_names: ~s(["API_KEY"]),
        destination: @destination,
        sealed_payload: "sealed",
        binding_digest: "sha256:i0",
        audience: "everyone",
        created_by: "usr_admin"
      },
      over
    )
  end

  defp put!(platform, over \\ %{}, members \\ []) do
    {:ok, entry} = InstanceEntries.put(platform, attrs(over), members)
    entry
  end

  defp person(user_id), do: %Prima.Actor{athanor_id: "ath_test", user_id: user_id}

  describe "who may ask" do
    test "every verb but the offer reads refuses an actor without platform scope",
         %{platform: platform} do
      entry = put!(platform)
      tenant = Arca.Test.Actor.local()

      QueryCounter.assert_queries(0, fn ->
        assert {:error, :cross_tenant} = InstanceEntries.put(tenant, attrs())
        assert {:error, :cross_tenant} = InstanceEntries.get(tenant, entry.id)
        assert {:error, :cross_tenant} = InstanceEntries.list(tenant)

        assert {:error, :cross_tenant} =
                 InstanceEntries.set_audience(
                   tenant,
                   entry.id,
                   %{audience: "everyone", members: []},
                   %{audience: "listed", members: ["usr_alice"]}
                 )

        assert {:error, :cross_tenant} =
                 InstanceEntries.set_component_policy(tenant, entry.id, "any", "shipped")

        assert {:error, :cross_tenant} =
                 InstanceEntries.set_caps(tenant, entry.id, %{person_daily: 1, total_daily: 1})

        assert {:error, :cross_tenant} = InstanceEntries.set_status(tenant, entry.id, "revoked")

        assert {:error, :cross_tenant} =
                 InstanceEntries.revoke(tenant, entry.id, "needs_consent")

        assert {:error, :cross_tenant} =
                 InstanceEntries.tombstone(tenant, entry.id, "needs_consent")

        assert {:error, :cross_tenant} =
                 InstanceEntries.move_binding(tenant, entry.id, "sha256:i0", %{}, "needs_consent")

        assert {:error, :cross_tenant} =
                 InstanceEntries.commit_payload(tenant, entry.id, %{
                   expected_rev: 0,
                   sealed_payload: "x",
                   status: nil
                 })

        assert {:error, :cross_tenant} = InstanceEntries.touch_last_used(tenant, entry.id)
      end)

      assert {:ok, %{status: "active"}} = InstanceEntries.get(platform, entry.id)
    end
  end

  describe "put/3" do
    test "an entry omitting the policy stores any, and is attach-only", %{platform: platform} do
      entry = put!(platform)
      assert entry.component_policy == "any"
      assert entry.attach_only == true
      assert entry.destination == @destination

      shipped = put!(platform, %{component_policy: "shipped"})
      assert shipped.component_policy == "shipped"

      # Asking for a disclosed instance entry is not a way to get one.
      forced = put!(platform, %{attach_only: false})
      assert forced.attach_only == true
    end

    test "explicit null, empty, unknown or collection-valued policy input is refused",
         %{platform: platform} do
      for bad <- [nil, "", "custom", "ANY", ["any"], %{"any" => true}, :any] do
        assert {:error, {:invalid, %{component_policy: _}}} =
                 InstanceEntries.put(platform, attrs(%{component_policy: bad}))
      end

      assert {:ok, []} = InstanceEntries.list(platform)
    end

    test "raw SQL outside the two-value enum is refused by the database", %{platform: platform} do
      entry = put!(platform)
      now = DateTime.utc_now()

      row = %{
        id: "ine_raw_#{System.unique_integer([:positive])}",
        name: "raw-#{System.unique_integer([:positive])}",
        kind: "api_key",
        destination: @destination,
        audience: "everyone",
        component_policy: "custom",
        created_by: "usr_admin",
        inserted_at: now,
        updated_at: now
      }

      assert :refused = raw_insert(row)
      assert :refused = raw_insert(%{row | component_policy: ""})
      assert :refused = raw_insert(%{row | component_policy: "shipped", audience: "some"})
      assert :refused = raw_insert(Map.merge(row, %{component_policy: "any", attach_only: false}))
      assert :ok = raw_insert(%{row | component_policy: "shipped"})

      assert :refused =
               raw_update(entry.id, component_policy: "everything")

      assert {:ok, %{component_policy: "any"}} = InstanceEntries.get(platform, entry.id)
    end

    test "an instance destination without methods or paths is refused", %{platform: platform} do
      for destination <- [
            ~s({"hosts":["api.openai.com"],"scheme":"https"}),
            ~s({"hosts":["api.openai.com"],"methods":["POST"],"scheme":"https"}),
            ~s({"hosts":["api.openai.com"],"paths":["/v1/"],"scheme":"https"})
          ] do
        assert {:error, {:invalid_destination, {:required, _}}} =
                 InstanceEntries.put(platform, attrs(%{destination: destination}))
      end

      assert {:error, :destination_required} =
               InstanceEntries.put(platform, Map.delete(attrs(), :destination))

      assert {:error, {:invalid_destination, :not_canonical}} =
               InstanceEntries.put(
                 platform,
                 attrs(%{
                   destination:
                     ~s({"scheme":"https","hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"]})
                 })
               )
    end

    test "a living name is taken", %{platform: platform} do
      _ = put!(platform, %{name: "shared-openai"})

      assert {:error, :name_taken} =
               InstanceEntries.put(platform, attrs(%{name: "shared-openai"}))
    end
  end

  describe "the offer" do
    test "everyone covers every person; listed covers its members alone", %{platform: platform} do
      everyone = put!(platform, %{name: "for-everyone"})
      listed = put!(platform, %{name: "for-alice", audience: "listed"}, ["usr_alice"])

      assert {:ok, alice} = InstanceEntries.offered(person("usr_alice"), [])
      assert Enum.map(alice, & &1.id) |> Enum.sort() == Enum.sort([everyone.id, listed.id])

      assert {:ok, bob} = InstanceEntries.offered(person("usr_bob"), [])
      assert Enum.map(bob, & &1.id) == [everyone.id]

      assert {:error, :not_offered} =
               InstanceEntries.get_offered(person("usr_bob"), listed.id, [])

      assert {:ok, %{id: id}} = InstanceEntries.get_offered(person("usr_alice"), listed.id, [])
      assert id == listed.id

      assert {:error, :no_person} =
               InstanceEntries.offered(%Prima.Actor{athanor_id: "ath_test"}, [])
    end

    test "offered/2 never answers a listed entry whose audience lacks the person",
         %{platform: platform} do
      listed = put!(platform, %{audience: "listed"}, ["usr_alice"])

      assert :ok =
               InstanceEntries.set_audience(
                 platform,
                 listed.id,
                 %{audience: "listed", members: ["usr_alice"]},
                 %{audience: "listed", members: ["usr_carol"]}
               )

      assert {:ok, []} = InstanceEntries.offered(person("usr_alice"), [])

      assert {:error, :not_offered} =
               InstanceEntries.get_offered(person("usr_alice"), listed.id, [])

      assert {:ok, [%{id: id}]} = InstanceEntries.offered(person("usr_carol"), [])
      assert id == listed.id

      assert {:ok, [%{members: ["usr_carol"]}]} = InstanceEntries.list(platform)

      # Widening to everyone keeps no list.
      assert :ok =
               InstanceEntries.set_audience(
                 platform,
                 listed.id,
                 %{audience: "listed", members: ["usr_carol"]},
                 %{audience: "everyone", members: ["usr_dan"]}
               )

      assert {:ok, [%{audience: "everyone", members: []}]} = InstanceEntries.list(platform)
    end

    test "a revoked or tombstoned entry is not offered", %{platform: platform} do
      revoked = put!(platform)
      gone = put!(platform)

      :ok = InstanceEntries.set_status(platform, revoked.id, "revoked")
      {:ok, []} = InstanceEntries.tombstone(platform, gone.id, "needs_consent")

      assert {:ok, []} = InstanceEntries.offered(person("usr_alice"), [])

      assert {:error, :not_offered} =
               InstanceEntries.get_offered(person("usr_alice"), revoked.id, [])

      # A caller that says why it cannot be used reads a revoked one.
      assert {:ok, %{status: "revoked"}} =
               InstanceEntries.get_offered(person("usr_alice"), revoked.id, active_only: false)

      assert {:error, :not_offered} =
               InstanceEntries.get_offered(person("usr_alice"), gone.id, active_only: false)
    end

    test "provider_hint narrows the offer", %{platform: platform} do
      openai = put!(platform)
      _other = put!(platform, %{provider_hint: "anthropic.com"})

      assert {:ok, [%{id: id}]} =
               InstanceEntries.offered(person("usr_alice"), provider_hint: "openai.com")

      assert id == openai.id
    end
  end

  describe "set_component_policy/4" do
    test "writes only from the expected policy, including an unchanged value",
         %{platform: platform} do
      entry = put!(platform)

      assert :ok = InstanceEntries.set_component_policy(platform, entry.id, "any", "any")
      assert :ok = InstanceEntries.set_component_policy(platform, entry.id, "any", "shipped")

      # A writer that read `any` before that landed: refused, nothing written.
      assert {:error, :conflict} =
               InstanceEntries.set_component_policy(platform, entry.id, "any", "any")

      assert {:ok, %{component_policy: "shipped"}} = InstanceEntries.get(platform, entry.id)

      assert {:error, :not_found} =
               InstanceEntries.set_component_policy(platform, "ine_missing", "any", "shipped")

      for bad <- [nil, "", "custom", ["shipped"]] do
        assert {:error, {:invalid, %{component_policy: _}}} =
                 InstanceEntries.set_component_policy(platform, entry.id, "shipped", bad)

        assert {:error, {:invalid, %{component_policy: _}}} =
                 InstanceEntries.set_component_policy(platform, entry.id, bad, "any")
      end
    end
  end

  describe "caps, status and material" do
    test "caps are integers or nil, 0 admitting none", %{platform: platform} do
      entry = put!(platform)

      assert :ok =
               InstanceEntries.set_caps(platform, entry.id, %{person_daily: 0, total_daily: nil})

      assert {:ok, %{person_daily: 0, total_daily: nil}} = InstanceEntries.get(platform, entry.id)

      assert {:error, {:invalid, _}} =
               InstanceEntries.set_caps(platform, entry.id, %{person_daily: -1, total_daily: 3})
    end

    # The cap columns are 32-bit on PostgreSQL: a larger cap is refused the
    # same way on both adapters, never by one driver alone.
    test "a cap above the column's range is refused on both adapters", %{platform: platform} do
      max = Arca.Schemas.InstanceEntry.max_cap()
      entry = put!(platform)

      assert :ok =
               InstanceEntries.set_caps(platform, entry.id, %{person_daily: max, total_daily: max})

      for caps <- [
            %{person_daily: max + 1, total_daily: nil},
            %{person_daily: nil, total_daily: max + 1}
          ] do
        assert {:error, {:invalid, _}} = InstanceEntries.set_caps(platform, entry.id, caps)
      end

      assert {:ok, %{person_daily: ^max, total_daily: ^max}} =
               InstanceEntries.get(platform, entry.id)

      for cap <- [:person_daily, :total_daily] do
        assert {:error, {:invalid, %{^cap => _}}} =
                 InstanceEntries.put(platform, attrs(%{cap => max + 1}), [])
      end
    end

    test "a rotation lands at the revision read, on an active entry alone", %{platform: platform} do
      entry = put!(platform)

      assert {:ok, %{payload_rev: 1}} =
               InstanceEntries.commit_payload(platform, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-2",
                 status: nil
               })

      assert {:error, :payload_conflict} =
               InstanceEntries.commit_payload(platform, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-3",
                 status: nil
               })

      :ok = InstanceEntries.set_status(platform, entry.id, "revoked")

      assert {:error, {:entry_unavailable, "revoked"}} =
               InstanceEntries.commit_payload(platform, entry.id, %{
                 expected_rev: 1,
                 sealed_payload: "sealed-3",
                 status: nil
               })

      assert {:ok, %{sealed_payload: "sealed-2", payload_rev: 1}} =
               InstanceEntries.get(platform, entry.id)
    end

    # A rotation read the entry at `needs_reauth`, and the platform
    # deleted or revoked it before the commit: the reactivation does not
    # undo that, and no material lands.
    test "a reactivation never undoes a delete or a revoke that landed after the read",
         %{platform: platform} do
      for {ended, material} <- [{"tombstoned", nil}, {"revoked", "sealed-1"}] do
        entry = put!(platform, %{sealed_payload: "sealed-1"})
        :ok = InstanceEntries.set_status(platform, entry.id, "needs_reauth")
        :ok = end!(platform, entry.id, ended)

        assert {:error, {:entry_unavailable, ^ended}} =
                 InstanceEntries.commit_payload(platform, entry.id, %{
                   expected_rev: 0,
                   sealed_payload: "sealed-late",
                   status: "active"
                 })

        assert {:ok, %{status: ^ended, sealed_payload: ^material, payload_rev: 0}} =
                 InstanceEntries.get(platform, entry.id)
      end
    end

    test "a status write never brings back a tombstoned or revoked entry", %{platform: platform} do
      for {ended, targets} <- [
            {"tombstoned", ~w(active needs_reauth revoked)},
            {"revoked", ~w(active needs_reauth)}
          ],
          target <- targets do
        entry = put!(platform, %{sealed_payload: "sealed-1"})
        :ok = end!(platform, entry.id, ended)

        assert {:error, {:entry_unavailable, ^ended}} =
                 InstanceEntries.set_status(platform, entry.id, target)

        assert {:ok, %{status: ^ended}} = InstanceEntries.get(platform, entry.id)
      end

      entry = put!(platform)
      assert :ok = InstanceEntries.set_status(platform, entry.id, "needs_reauth")
      assert :ok = InstanceEntries.set_status(platform, entry.id, "active")
      assert :ok = InstanceEntries.set_status(platform, entry.id, "revoked")

      assert {:error, :not_found} =
               InstanceEntries.set_status(platform, "ient_missing", "revoked")
    end

    test "a plan's status only reactivates: needs_reauth turns active, any other is refused",
         %{platform: platform} do
      entry = put!(platform, %{sealed_payload: "sealed-1"})
      :ok = InstanceEntries.set_status(platform, entry.id, "needs_reauth")

      for status <- ["needs_reauth", "revoked", "tombstoned"] do
        assert {:error, {:invalid_status, ^status}} =
                 InstanceEntries.commit_payload(platform, entry.id, %{
                   expected_rev: 0,
                   sealed_payload: "sealed-other",
                   status: status
                 })
      end

      assert {:ok, %{payload_rev: 1}} =
               InstanceEntries.commit_payload(platform, entry.id, %{
                 expected_rev: 0,
                 sealed_payload: "sealed-2",
                 status: "active"
               })

      # An active row stays active.
      assert {:ok, %{payload_rev: 2}} =
               InstanceEntries.commit_payload(platform, entry.id, %{
                 expected_rev: 1,
                 sealed_payload: "sealed-3",
                 status: "active"
               })

      assert {:ok, %{status: "active", sealed_payload: "sealed-3", payload_rev: 2}} =
               InstanceEntries.get(platform, entry.id)
    end

    test "tombstone erases the material and every athanor's default naming it",
         %{platform: platform} do
      entry = put!(platform)

      for athanor <- ["ath_a", "ath_b"] do
        assert {:ok, _} =
                 Arca.VaultDefaults.set(Prima.Actor.in_athanor(athanor), "openai.com", %{
                   instance_entry_id: entry.id
                 })
      end

      assert {:ok, []} = InstanceEntries.tombstone(platform, entry.id, "needs_consent")

      assert {:ok, %{status: "tombstoned", sealed_payload: nil}} =
               InstanceEntries.get(platform, entry.id)

      for athanor <- ["ath_a", "ath_b"] do
        assert {:error, :not_found} =
                 Arca.VaultDefaults.get(Prima.Actor.in_athanor(athanor), "openai.com")
      end
    end

    test "touch_last_used stamps the entry", %{platform: platform} do
      entry = put!(platform)
      assert :ok = InstanceEntries.touch_last_used(platform, entry.id)
      assert {:ok, %{last_used_at: %DateTime{}}} = InstanceEntries.get(platform, entry.id)
    end
  end

  describe "move_binding/5" do
    test "moves the destination and blocks every athanor's dependent profile",
         %{platform: platform} do
      entry = put!(platform)
      a = dependent!("ath_a", entry.id)
      b = dependent!("ath_b", entry.id)

      assert {:ok, affected} =
               InstanceEntries.move_binding(
                 platform,
                 entry.id,
                 "sha256:i0",
                 %{destination: @narrowed, binding_digest: "sha256:i1"},
                 "needs_consent"
               )

      assert Enum.sort(affected) == Enum.sort([{"ath_a", a}, {"ath_b", b}])

      assert {:ok, %{destination: @narrowed, binding_digest: "sha256:i1"}} =
               InstanceEntries.get(platform, entry.id)

      for {athanor, profile} <- [{"ath_a", a}, {"ath_b", b}] do
        {:ok, row} = Arca.ProfileStorage.get(Prima.Actor.in_athanor(athanor), profile)
        assert row.status == "needs_consent"
      end

      assert {:error, :binding_moved} =
               InstanceEntries.move_binding(
                 platform,
                 entry.id,
                 "sha256:i0",
                 %{destination: @destination, binding_digest: "sha256:i2"},
                 "needs_consent"
               )
    end

    test "endpoints, other columns and a destination without methods are refused",
         %{platform: platform} do
      entry = put!(platform)

      QueryCounter.assert_queries(0, fn ->
        assert {:error, :endpoints_immutable} =
                 InstanceEntries.move_binding(
                   platform,
                   entry.id,
                   "sha256:i0",
                   %{oauth_endpoints: "{}", binding_digest: "sha256:i1"},
                   "needs_consent"
                 )

        assert {:error, {:invalid, _}} =
                 InstanceEntries.move_binding(
                   platform,
                   entry.id,
                   "sha256:i0",
                   %{field_names: "[]", binding_digest: "sha256:i1"},
                   "needs_consent"
                 )

        assert {:error, {:invalid_destination, {:required, "methods"}}} =
                 InstanceEntries.move_binding(
                   platform,
                   entry.id,
                   "sha256:i0",
                   %{
                     destination:
                       ~s({"hosts":["api.openai.com"],"paths":["/v1/"],"scheme":"https"}),
                     binding_digest: "sha256:i1"
                   },
                   "needs_consent"
                 )
      end)
    end
  end

  describe "revoke/3 and tombstone/3" do
    test "each ends the entry and blocks every athanor's dependent profile with it",
         %{platform: platform} do
      for verb <- [:revoke, :tombstone] do
        entry = put!(platform)
        a = dependent!("ath_a", entry.id)
        b = dependent!("ath_b", entry.id)
        unrelated = dependent!("ath_a", put!(platform).id)

        assert {:ok, affected} =
                 apply(InstanceEntries, verb, [platform, entry.id, "needs_consent"])

        assert Enum.sort(affected) == Enum.sort([{"ath_a", a}, {"ath_b", b}])

        ended = if verb == :revoke, do: "revoked", else: "tombstoned"
        assert {:ok, %{status: ^ended}} = InstanceEntries.get(platform, entry.id)

        for {athanor, profile} <- affected do
          assert profile_status(athanor, profile) == "needs_consent"
        end

        assert profile_status("ath_a", unrelated) == "active"
      end
    end

    # A revoked profile is not blocked: blocking it would revive it beside
    # the live profile of the same component, label and kind, which the
    # active-identity index refuses, and the whole write would roll back.
    # It stays revoked, and nothing attaches through it.
    test "a revoked profile beside a live one of its identity stays revoked; the live one is blocked",
         %{platform: platform} do
      for verb <- [:revoke, :tombstone, :move_binding] do
        entry = put!(platform)
        source = "catalyst:local.shared-#{System.unique_integer([:positive])}"
        old = dependent!("ath_a", entry.id, source)
        :ok = Arca.ProfileStorage.set_status(Prima.Actor.in_athanor("ath_a"), old, "revoked")
        live = dependent!("ath_a", entry.id, source)

        args =
          if verb == :move_binding,
            do: [
              platform,
              entry.id,
              "sha256:i0",
              %{destination: @narrowed, binding_digest: "sha256:i1"},
              "needs_consent"
            ],
            else: [platform, entry.id, "needs_consent"]

        assert {:ok, [{"ath_a", ^live}]} = apply(InstanceEntries, verb, args), inspect(verb)

        assert profile_status("ath_a", live) == "needs_consent"
        assert profile_status("ath_a", old) == "revoked"

        ended =
          case verb do
            :revoke -> "revoked"
            :tombstone -> "tombstoned"
            :move_binding -> "active"
          end

        assert {:ok, %{status: ^ended}} = InstanceEntries.get(platform, entry.id)
      end
    end

    test "a repeat blocks again and answers the pairs, so a retry finishes the job",
         %{platform: platform} do
      for verb <- [:revoke, :tombstone] do
        entry = put!(platform)
        a = dependent!("ath_a", entry.id)

        assert {:ok, [{"ath_a", ^a}]} =
                 apply(InstanceEntries, verb, [platform, entry.id, "needs_consent"])

        # What an attempt that ended the entry and was stopped before its
        # dependents were blocked would have left behind.
        :ok = Arca.ProfileStorage.set_status(Prima.Actor.in_athanor("ath_a"), a, "active")

        assert {:ok, [{"ath_a", ^a}]} =
                 apply(InstanceEntries, verb, [platform, entry.id, "needs_consent"])

        assert profile_status("ath_a", a) == "needs_consent"
      end
    end

    test "a revoke never brings back a tombstoned entry, and a missing one is not found",
         %{platform: platform} do
      entry = put!(platform)
      a = dependent!("ath_a", entry.id)
      {:ok, [_]} = InstanceEntries.tombstone(platform, entry.id, "needs_consent")
      :ok = Arca.ProfileStorage.set_status(Prima.Actor.in_athanor("ath_a"), a, "active")

      assert {:error, {:entry_unavailable, "tombstoned"}} =
               InstanceEntries.revoke(platform, entry.id, "needs_consent")

      assert {:ok, %{status: "tombstoned"}} = InstanceEntries.get(platform, entry.id)
      assert profile_status("ath_a", a) == "active"

      assert {:error, :not_found} = InstanceEntries.revoke(platform, "ine_missing", "x")
      assert {:error, :not_found} = InstanceEntries.tombstone(platform, "ine_missing", "x")
    end

    # The block is the same transaction as the write it follows: a block the
    # database refuses leaves the entry, its material, its defaults and
    # every profile as they were.
    @tag :capture_log
    test "a block that fails rolls the status write back", %{platform: platform} do
      revoked = put!(platform, %{sealed_payload: "sealed-r"})
      gone = put!(platform, %{sealed_payload: "sealed-t"})
      r = dependent!("ath_a", revoked.id)
      t = dependent!("ath_b", gone.id)

      {:ok, _} =
        Arca.VaultDefaults.set(Prima.Actor.in_athanor("ath_b"), "openai.com", %{
          instance_entry_id: gone.id
        })

      refuse_profile_updates!()

      assert {:error, :database_error} =
               InstanceEntries.revoke(platform, revoked.id, "needs_consent")

      assert {:error, :database_error} =
               InstanceEntries.tombstone(platform, gone.id, "needs_consent")

      assert {:ok, %{status: "active", sealed_payload: "sealed-r"}} =
               InstanceEntries.get(platform, revoked.id)

      assert {:ok, %{status: "active", sealed_payload: "sealed-t"}} =
               InstanceEntries.get(platform, gone.id)

      assert {:ok, %{instance_entry_id: gone_id}} =
               Arca.VaultDefaults.get(Prima.Actor.in_athanor("ath_b"), "openai.com")

      assert gone_id == gone.id
      assert profile_status("ath_a", r) == "active"
      assert profile_status("ath_b", t) == "active"
    end
  end

  describe "set_audience/4" do
    test "writes only from the audience and members it was decided against",
         %{platform: platform} do
      entry = put!(platform, %{audience: "listed"}, ["usr_alice", "usr_bob"])
      read = %{audience: "listed", members: ["usr_alice", "usr_bob"]}

      # Members compare as a set: the order a caller read them in is not a
      # difference.
      assert :ok =
               InstanceEntries.set_audience(
                 platform,
                 entry.id,
                 %{read | members: ["usr_bob", "usr_alice"]},
                 %{audience: "listed", members: ["usr_alice"]}
               )

      # A second writer that read the same list: refused, nothing written,
      # so the person the first removed is never put back.
      assert {:error, :conflict} =
               InstanceEntries.set_audience(platform, entry.id, read, %{
                 audience: "listed",
                 members: ["usr_alice", "usr_bob", "usr_carol"]
               })

      assert {:error, :conflict} =
               InstanceEntries.set_audience(
                 platform,
                 entry.id,
                 %{audience: "everyone", members: []},
                 %{audience: "everyone", members: []}
               )

      assert {:ok, [%{audience: "listed", members: ["usr_alice"]}]} =
               InstanceEntries.list(platform)

      assert {:error, :not_found} =
               InstanceEntries.set_audience(platform, "ine_missing", read, read)

      {:ok, []} = InstanceEntries.tombstone(platform, entry.id, "needs_consent")
      held = %{audience: "listed", members: ["usr_alice"]}

      assert {:error, :not_found} =
               InstanceEntries.set_audience(platform, entry.id, held, %{
                 audience: "everyone",
                 members: []
               })
    end

    test "an audience or a member outside the vocabulary is refused before a query",
         %{platform: platform} do
      entry = put!(platform)
      held = %{audience: "everyone", members: []}

      QueryCounter.assert_queries(0, fn ->
        for {expected, change} <- [
              {held, %{audience: "some", members: []}},
              {%{audience: "nobody", members: []}, held},
              {held, %{audience: "listed", members: [""]}},
              {%{audience: "listed", members: [:usr_alice]}, held}
            ] do
          assert {:error, {:invalid, _}} =
                   InstanceEntries.set_audience(platform, entry.id, expected, change)
        end
      end)
    end
  end

  describe "set_caps/3" do
    test "writes only the caps it names, in one statement", %{platform: platform} do
      entry = put!(platform, %{person_daily: 5, total_daily: 50})

      assert :ok = InstanceEntries.set_caps(platform, entry.id, %{person_daily: 7})
      assert {:ok, %{person_daily: 7, total_daily: 50}} = InstanceEntries.get(platform, entry.id)

      assert :ok = InstanceEntries.set_caps(platform, entry.id, %{total_daily: nil})
      assert {:ok, %{person_daily: 7, total_daily: nil}} = InstanceEntries.get(platform, entry.id)

      QueryCounter.assert_queries(0, fn ->
        for caps <- [%{}, %{person_daily: 1, other: 2}, %{total_daily: -1}] do
          assert {:error, {:invalid, %{caps: _}}} =
                   InstanceEntries.set_caps(platform, entry.id, caps),
                 inspect(caps)
        end
      end)

      assert {:error, :not_found} =
               InstanceEntries.set_caps(platform, "ine_missing", %{person_daily: 1})
    end
  end

  # A denial removes the person from every listed audience under the
  # person's lock; an audience write takes the same lock first, so a
  # denied person is never listed again.
  describe "a denied person" do
    test "is refused from a listed audience at create and at set_audience, nothing written",
         %{platform: platform} do
      alice = person!()
      bob = person!()
      denied = bob.id

      {:ok, _} =
        Arca.SecurityTransitions.deny_user(Prima.Actor.system(), denied,
          verify: fn _rows -> :ok end
        )

      assert {:error, {:person_denied, ^denied}} =
               InstanceEntries.put(platform, attrs(%{audience: "listed"}), [alice.id, denied])

      assert {:ok, []} = InstanceEntries.list(platform)

      entry = put!(platform, %{audience: "listed"}, [alice.id])

      assert {:error, {:person_denied, ^denied}} =
               InstanceEntries.set_audience(
                 platform,
                 entry.id,
                 %{audience: "listed", members: [alice.id]},
                 %{audience: "listed", members: [alice.id, denied]}
               )

      assert {:ok, [%{audience: "listed", members: members}]} = InstanceEntries.list(platform)
      assert members == [alice.id]

      # An everyone audience lists no one, and is not refused for anyone.
      assert :ok =
               InstanceEntries.set_audience(
                 platform,
                 entry.id,
                 %{audience: "listed", members: [alice.id]},
                 %{audience: "everyone", members: [denied]}
               )
    end
  end

  defp person! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Users.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          email: "ie#{n}@example.com",
          email_verified: true,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|ie#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "ie#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    user
  end

  defp end!(platform, id, "tombstoned") do
    {:ok, _pairs} = InstanceEntries.tombstone(platform, id, "needs_consent")
    :ok
  end

  defp end!(platform, id, "revoked"), do: InstanceEntries.set_status(platform, id, "revoked")

  defp profile_status(athanor, profile) do
    {:ok, row} = Arca.ProfileStorage.get(Prima.Actor.in_athanor(athanor), profile)
    row.status
  end

  # Every update of a profile refused by the database for the rest of the
  # case. The trigger is created inside the case's sandbox transaction,
  # which takes it away again.
  defp refuse_profile_updates! do
    case Arca.Repo.adapter() do
      Ecto.Adapters.Postgres ->
        Arca.Repo.query!(
          "CREATE FUNCTION arca_test_refuse_block() RETURNS trigger LANGUAGE plpgsql " <>
            "AS $$ BEGIN RAISE EXCEPTION 'block refused'; END $$"
        )

        Arca.Repo.query!(
          "CREATE TRIGGER arca_test_refuse_block BEFORE UPDATE ON profiles " <>
            "FOR EACH ROW EXECUTE FUNCTION arca_test_refuse_block()"
        )

      _sqlite ->
        Arca.Repo.query!(
          "CREATE TRIGGER arca_test_refuse_block BEFORE UPDATE ON profiles " <>
            "BEGIN SELECT RAISE(ABORT, 'block refused'); END"
        )
    end

    :ok
  end

  # A profile in `athanor` whose head binds the instance entry; `source_ref`
  # names the component it consents for, its own by default.
  defp dependent!(athanor, entry_id, source_ref \\ nil) do
    profile = "prof_dep_#{System.unique_integer([:positive])}"
    source_ref = source_ref || "catalyst:local.#{profile}"

    {:ok, _} =
      Arca.ProfileStorage.put(%{
        id: profile,
        athanor_id: athanor,
        source_ref: source_ref,
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: athanor,
          profile_id: profile,
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
          granted_via: "interactive"
        },
        [
          %{
            binding_key: "#{source_ref}|@ingress|default",
            scope: "instance",
            instance_entry_id: entry_id,
            binding_digest: "sha256:i0"
          }
        ],
        nil
      )

    profile
  end

  defp raw_insert(row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(Arca.Schemas.InstanceEntry, [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end

  defp raw_update(id, set) do
    Arca.Repo.transaction(fn ->
      Arca.Repo.update_all(
        Ecto.Query.from(i in Arca.Schemas.InstanceEntry, where: i.id == ^id),
        set: set
      )
    end)

    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end
end

defmodule Arca.InstanceEntriesAudienceRaceTest do
  @moduledoc """
  Two audience writes on connections of their own, each decided against
  the same read: inside the sandbox one shared connection would serialize
  the writers the case is about.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.InstanceEntries
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    platform = Arca.Test.Actor.platform()

    entry =
      unboxed(fn ->
        {:ok, entry} =
          InstanceEntries.put(
            platform,
            %{
              name: "audience-race-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: "openai.com",
              destination:
                ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
              sealed_payload: "sealed",
              binding_digest: "sha256:i0",
              audience: "listed",
              created_by: "usr_admin"
            },
            ["usr_alice", "usr_bob"]
          )

        entry
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          Ecto.Query.from(m in Arca.Schemas.InstanceEntryMember,
            where: m.instance_entry_id == ^entry.id
          )
        )

        Arca.Repo.delete_all(
          Ecto.Query.from(i in Arca.Schemas.InstanceEntry, where: i.id == ^entry.id)
        )
      end)
    end)

    {:ok, platform: platform, entry: entry}
  end

  test "two writers decided against one audience: one lands, the other writes nothing", %{
    platform: platform,
    entry: entry
  } do
    read = %{audience: "listed", members: ["usr_alice", "usr_bob"]}

    # One narrows Bob out; the other, decided against the same read, adds
    # Carol. Landing both would put Bob back without anyone deciding it.
    changes = [
      %{audience: "listed", members: ["usr_alice"]},
      %{audience: "listed", members: ["usr_alice", "usr_bob", "usr_carol"]}
    ]

    results =
      for change <- changes do
        Task.async(fn ->
          {change,
           unboxed(fn -> InstanceEntries.set_audience(platform, entry.id, read, change) end)}
        end)
      end
      |> Task.await_many(30_000)

    assert [{_lost, {:error, :conflict}}, {won, :ok}] =
             Enum.sort_by(results, fn {_change, result} -> result == :ok end)

    assert {:ok, entries} = unboxed(fn -> InstanceEntries.list(platform) end)
    stored = Enum.find(entries, &(&1.id == entry.id))
    assert stored.audience == won.audience
    assert Enum.sort(stored.members) == Enum.sort(won.members)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end

defmodule Arca.InstanceEntriesDenyRaceTest do
  @moduledoc """
  A denial and an audience write naming the person being denied, each on
  a connection of its own: the denial lands while the audience write is
  inside its transaction, past its own first read of the entry. The
  person's lock serializes the two, so the final audience never lists a
  denied person, and a write that loses answers its refusal.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.InstanceEntries
  alias Arca.Schemas.{ExternalIdentity, InstanceEntry, InstanceEntryMember, User}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    platform = Arca.Test.Actor.platform()
    alice = unboxed(fn -> person!() end)
    bob = unboxed(fn -> person!() end)

    entry =
      unboxed(fn ->
        {:ok, entry} =
          InstanceEntries.put(
            platform,
            %{
              name: "deny-race-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: "openai.com",
              destination:
                ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"}),
              sealed_payload: "sealed",
              binding_digest: "sha256:i0",
              audience: "listed",
              created_by: "usr_admin"
            },
            [alice.id]
          )

        entry
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(
          from(m in InstanceEntryMember, where: m.instance_entry_id == ^entry.id)
        )

        Arca.Repo.delete_all(from(i in InstanceEntry, where: i.id == ^entry.id))

        for id <- [alice.id, bob.id] do
          Arca.Repo.delete_all(from(e in ExternalIdentity, where: e.user_id == ^id))
          Arca.Repo.delete_all(from(u in User, where: u.id == ^id))
        end
      end)
    end)

    {:ok, platform: platform, entry: entry, alice: alice.id, bob: bob.id}
  end

  test "a denial landing inside an audience write that adds the person never leaves them listed",
       %{platform: platform, entry: entry, alice: alice, bob: bob} do
    writer = self()
    handler = "deny-race-#{System.unique_integer([:positive])}"

    # The first read of the entry inside the audience write's transaction:
    # the denial starts there, on its own connection, and is given a
    # bounded moment to land before the write goes on. A denial held at a
    # lock the write took finishes after the write commits.
    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == writer and meta[:source] == "instance_entries" and
             Process.get(:denial) == nil do
          denial =
            Task.async(fn ->
              unboxed(fn ->
                Arca.SecurityTransitions.deny_user(Prima.Actor.system(), bob,
                  verify: fn _rows -> :ok end
                )
              end)
            end)

          Process.put(:denial, denial)
          Process.put(:denied_early, Task.yield(denial, 500))
        end
      end,
      nil
    )

    written =
      try do
        unboxed(fn ->
          InstanceEntries.set_audience(
            platform,
            entry.id,
            %{audience: "listed", members: [alice]},
            %{audience: "listed", members: [alice, bob]}
          )
        end)
      after
        :telemetry.detach(handler)
      end

    denial = Process.get(:denial)
    assert denial, "the audience write never read its entry"

    # A denial that landed inside the bounded moment answered there.
    denied =
      case Process.get(:denied_early) do
        {:ok, result} -> result
        nil -> Task.await(denial, 30_000)
      end

    assert {:ok, _change} = denied

    # Either the write landed first and the denial removed the person, or
    # the denial landed first and the write was refused naming them.
    assert written in [:ok, {:error, {:person_denied, bob}}]

    {:ok, entries} = unboxed(fn -> InstanceEntries.list(platform) end)
    stored = Enum.find(entries, &(&1.id == entry.id))
    refute bob in stored.members
    assert alice in stored.members
  end

  defp person! do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {:ok, user} =
      Arca.Users.mint(
        Prima.Actor.system(),
        %{
          id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
          provider: "github",
          email: "ier#{n}@example.com",
          email_verified: true,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|ier#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "ier#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    user
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
