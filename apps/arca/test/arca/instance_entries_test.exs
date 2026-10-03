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
                 InstanceEntries.set_audience(tenant, entry.id, "everyone", [])

        assert {:error, :cross_tenant} =
                 InstanceEntries.set_component_policy(tenant, entry.id, "any", "shipped")

        assert {:error, :cross_tenant} =
                 InstanceEntries.set_caps(tenant, entry.id, %{person_daily: 1, total_daily: 1})

        assert {:error, :cross_tenant} = InstanceEntries.set_status(tenant, entry.id, "revoked")
        assert {:error, :cross_tenant} = InstanceEntries.tombstone(tenant, entry.id)

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

      assert :ok = InstanceEntries.set_audience(platform, listed.id, "listed", ["usr_carol"])

      assert {:ok, []} = InstanceEntries.offered(person("usr_alice"), [])

      assert {:error, :not_offered} =
               InstanceEntries.get_offered(person("usr_alice"), listed.id, [])

      assert {:ok, [%{id: id}]} = InstanceEntries.offered(person("usr_carol"), [])
      assert id == listed.id

      assert {:ok, [%{members: ["usr_carol"]}]} = InstanceEntries.list(platform)

      # Widening to everyone keeps no list.
      assert :ok = InstanceEntries.set_audience(platform, listed.id, "everyone", ["usr_dan"])
      assert {:ok, [%{audience: "everyone", members: []}]} = InstanceEntries.list(platform)
    end

    test "a revoked or tombstoned entry is not offered", %{platform: platform} do
      revoked = put!(platform)
      gone = put!(platform)

      :ok = InstanceEntries.set_status(platform, revoked.id, "revoked")
      :ok = InstanceEntries.tombstone(platform, gone.id)

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

        :ok =
          if ended == "tombstoned",
            do: InstanceEntries.tombstone(platform, entry.id),
            else: InstanceEntries.set_status(platform, entry.id, "revoked")

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

        :ok =
          if ended == "tombstoned",
            do: InstanceEntries.tombstone(platform, entry.id),
            else: InstanceEntries.set_status(platform, entry.id, "revoked")

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

      assert :ok = InstanceEntries.tombstone(platform, entry.id)

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

  # A profile in `athanor` whose head binds the instance entry.
  defp dependent!(athanor, entry_id) do
    profile = "prof_dep_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Arca.ProfileStorage.put(%{
        id: profile,
        athanor_id: athanor,
        source_ref: "catalyst:local.#{profile}",
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
            binding_key: "catalyst:local.#{profile}|@ingress|default",
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
