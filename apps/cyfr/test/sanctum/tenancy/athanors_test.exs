# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.AthanorsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Athanors

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  defp slug, do: "ath-#{System.unique_integer([:positive])}"

  defp owner, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())

  defp athanor!(overrides \\ %{}) do
    {:ok, athanor} =
      Athanors.create(
        Map.merge(
          %{name: "Athanor", slug: slug(), owner_user_id: owner(), created_by: "system"},
          overrides
        )
      )

    athanor
  end

  describe "put_settings/2" do
    test "merges over the row as it is now, not the caller's copy" do
      athanor = athanor!()

      # The shape `Sanctum.Provisioning` takes: read the athanor, do a dozen
      # steps, write the outcome. A merge based on the struct read first
      # would drop anything written to settings in between.
      stale = athanor

      {:ok, _} = Athanors.put_settings(athanor, %{"written_during" => "yes"})
      {:ok, _} = Athanors.put_settings(stale, %{"approvals" => %{"expiry_hours" => 2}})

      assert {:ok, fresh} = Athanors.get(athanor.id)
      settings = Athanors.settings(fresh)

      assert settings["approvals"]["expiry_hours"] == 2

      assert settings["written_during"] == "yes",
             "a concurrent settings write was clobbered by a merge over a stale struct"
    end
  end

  describe "create/1" do
    test "mints an ath_ id and defaults to active" do
      athanor = athanor!()
      assert String.starts_with?(athanor.id, "ath_")
      assert athanor.status == "active"
      assert athanor.provisioned_at == nil
    end

    test "an athanor names its owner" do
      assert {:ok, athanor} =
               Athanors.create(%{
                 name: "Alice",
                 slug: "alice-#{System.unique_integer([:positive])}",
                 owner_user_id: "github|https://github.com|1",
                 created_by: "system"
               })

      assert athanor.owner_user_id == "github|https://github.com|1"
    end

    test "an athanor without an owner is rejected" do
      assert {:error, {:invalid, %{owner_user_id: [_ | _]}}} =
               Athanors.create(%{name: "X", slug: slug(), created_by: "system"})
    end

    test "slugs are unique" do
      s = slug()

      assert {:ok, _} =
               Athanors.create(%{
                 name: "A",
                 slug: s,
                 owner_user_id: owner(),
                 created_by: "system"
               })

      # The unique index on the slug is the one refusal a caller acts on
      # rather than reports: a derived slug asks again with the next name.
      assert {:error, :slug_taken} =
               Athanors.create(%{
                 name: "B",
                 slug: s,
                 owner_user_id: owner(),
                 created_by: "system"
               })
    end

    test "a long name whose truncation lands on a hyphen still takes the next free slug" do
      # Truncating a long slug at a hyphen must still produce a valid
      # collision suffix without doubled hyphens.
      n = System.unique_integer([:positive])
      name = "alice-#{n}@example.com & bob-#{n}@example.com"
      {:ok, slugs} = Athanors.person_slugs(nil, name)

      personal = fn ->
        id = owner()
        Athanors.create_personal(%{name: name, owner_user_id: id, created_by: id}, slugs)
      end

      assert {:ok, first} = personal.()
      assert {:ok, second} = personal.()

      assert second.slug != first.slug
      refute second.slug =~ "--"
      assert second.slug =~ Prima.ComponentRef.personal_slug_regex()
    end

    test "one person, one athanor" do
      owner = "github|https://github.com|#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Athanors.create(%{
                 name: "A",
                 slug: slug(),
                 owner_user_id: owner,
                 created_by: "system"
               })

      assert {:error, {:invalid, %{owner_user_id: [_ | _]}}} =
               Athanors.create(%{
                 name: "A again",
                 slug: slug(),
                 owner_user_id: owner,
                 created_by: "system"
               })
    end

    test "rejects a slug outside the namespace grammar" do
      assert {:error, {:invalid, %{slug: [_ | _]}}} =
               Athanors.create(%{
                 name: "X",
                 slug: "Bad Slug",
                 owner_user_id: owner(),
                 created_by: "system"
               })
    end
  end

  describe "get/1, get_by_owner/1 and get_by_slug/1" do
    test "finds by id, by owner and by slug" do
      athanor = athanor!()
      assert {:ok, ^athanor} = Athanors.get(athanor.id)
      assert {:ok, found} = Athanors.get_by_slug(athanor.slug)
      assert found.id == athanor.id
      assert {:ok, %{id: by_owner}} = Athanors.get_by_owner(athanor.owner_user_id)
      assert by_owner == athanor.id
      assert {:error, :not_found} = Athanors.get_by_slug("no-such-#{athanor.slug}")
      assert {:error, :not_found} = Athanors.get_by_owner(owner())
      assert {:error, :not_found} = Athanors.get("ath_nope")
    end
  end

  describe "active?/1" do
    test "follows the athanor's standing; an archived athanor is still read" do
      athanor = athanor!()
      assert Athanors.active?(athanor.id)

      Sanctum.TestContext.archive!(athanor.id)
      refute Athanors.active?(athanor.id)
      assert {:ok, %{status: "archived"}} = Athanors.get(athanor.id)

      Sanctum.TestContext.reopen!(athanor.id)
      assert Athanors.active?(athanor.id)
    end

    test "active?/1 is false for unknown or empty ids" do
      refute Athanors.active?("ath_nope")
      refute Athanors.active?(nil)
      refute Athanors.active?("")
    end
  end

  describe "settings" do
    test "settings default to an empty map and merge on put" do
      athanor = athanor!()
      assert Athanors.settings(athanor) == %{}

      {:ok, athanor} = Athanors.put_settings(athanor, %{"aqua" => %{"name" => "Home"}})
      {:ok, athanor} = Athanors.put_settings(athanor, %{"theme" => "dark"})

      assert Athanors.settings(athanor) == %{"aqua" => %{"name" => "Home"}, "theme" => "dark"}
    end

    test "a nested patch merges into the map already there; nil deletes a key" do
      athanor = athanor!()
      {:ok, athanor} = Athanors.put_settings(athanor, %{"aqua" => %{"name" => "Home"}})
      {:ok, athanor} = Athanors.put_settings(athanor, %{"aqua" => %{"answer_mode" => "all"}})

      assert Athanors.settings(athanor)["aqua"] == %{"name" => "Home", "answer_mode" => "all"}

      {:ok, athanor} = Athanors.put_settings(athanor, %{"aqua" => %{"answer_mode" => nil}})
      assert Athanors.settings(athanor)["aqua"] == %{"name" => "Home"}

      {:ok, athanor} = Athanors.put_settings(athanor, %{"aqua" => nil})
      refute Map.has_key?(Athanors.settings(athanor), "aqua")
    end

    test "a settings change is broadcast on the athanor's notify topic" do
      athanor = athanor!()

      Cyfr.Bus.subscribe(
        Prima.Actor.in_athanor(athanor.id),
        Cyfr.Bus.notify(Prima.Actor.in_athanor(athanor.id))
      )

      {:ok, _} = Athanors.put_settings(athanor, %{"theme" => "dark"})
      assert_receive %Cyfr.Bus.Notify{athanor_id: id, kind: :athanor_changed}
      assert id == athanor.id
    end
  end

  describe "provisioning_failure/1 and list_by_ids/1" do
    test "reads the failure a fill recorded, and lists by ids" do
      a = athanor!()
      b = athanor!()

      :ok =
        Arca.Athanors.set(Prima.Actor.in_athanor(a.id),
          provisioning_failed_at: DateTime.utc_now(),
          provisioning_failure: Jason.encode!(%{"step" => "closure", "detail" => "unreachable"})
        )

      {:ok, a} = Athanors.get(a.id)

      assert %{step: "closure", detail: "unreachable", at: %DateTime{}} =
               Athanors.provisioning_failure(a)

      {:ok, a} = Sanctum.TestContext.mark_provisioned(a)
      assert a.provisioned_at != nil
      # a successful run forgets the earlier failure
      refute Athanors.provisioning_failure(a)

      ids = Athanors.list_by_ids([a.id, b.id, "ath_missing"]) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      assert Athanors.list_by_ids([]) == []
    end
  end

  describe "by_route_slug/1 and list_for_user/1" do
    test "@namespace names an athanor, a bare slug nothing; archived athanors do not resolve" do
      n = System.unique_integer([:positive])

      {:ok, person} =
        Athanors.create(%{
          name: "Alice",
          slug: "alice#{n}",
          owner_user_id: "u-#{n}",
          created_by: "u-#{n}"
        })

      assert {:ok, %{id: pid}} = Athanors.by_route_slug("@alice#{n}")
      assert pid == person.id
      assert {:error, :not_found} = Athanors.by_route_slug("alice#{n}")
      assert Athanors.route_slug(person) == "@alice#{n}"

      Sanctum.TestContext.archive!(person.id)
      assert {:error, :not_found} = Athanors.by_route_slug("@alice#{n}")
    end

    test "list_for_user lists the person's own athanor while it is active" do
      n = System.unique_integer([:positive])
      uid = "u-list-#{n}"

      {:ok, person} =
        Athanors.create(%{
          name: "Me",
          slug: "me#{n}",
          owner_user_id: uid,
          created_by: uid
        })

      assert [%{id: id}] = Athanors.list_for_user(uid)
      assert id == person.id
      assert [] = Athanors.list_for_user("u-nobody-#{n}")

      Sanctum.TestContext.archive!(person.id)
      assert [] = Athanors.list_for_user(uid)
    end
  end
end
