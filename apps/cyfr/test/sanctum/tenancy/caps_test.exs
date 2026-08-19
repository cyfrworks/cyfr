# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.CapsTest do
  @moduledoc """
  The public-door caps: off unless set, and when set, enforced where each
  applies — athanors per server, groups per person, members per group,
  mints per hour, bytes per athanor.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Athanors, Caps, Members}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Application.get_env(:cyfr, :caps)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :caps, prev),
        else: Application.delete_env(:cyfr, :caps)
    end)

    :ok
  end

  test "an unset cap is off; a set cap is a ceiling" do
    Application.delete_env(:cyfr, :caps)
    assert Caps.get(:max_athanors) == nil
    assert :ok = Caps.check(:max_athanors, 1_000_000)

    Application.put_env(:cyfr, :caps, max_athanors: 3, max_groups_per_person: 0)
    assert :ok = Caps.check(:max_athanors, 2)
    assert {:error, {:limit_reached, :max_athanors, 3}} = Caps.check(:max_athanors, 3)
    # zero and negatives read as off, never as "nothing allowed"
    assert Caps.get(:max_groups_per_person) == nil
  end

  test "max_athanors stops Athanors.create; max_groups_per_person stops create_group" do
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count())

    assert {:error, {:limit_reached, :max_athanors, _}} =
             Athanors.create(%{
               kind: "group",
               name: "One more",
               slug: "onemore-#{System.unique_integer([:positive])}",
               created_by: "system"
             })

    # An archived athanor frees its place: the cap counts active furnaces.
    uid0 = "github|https://github.com|freed-#{System.unique_integer([:positive])}"
    Application.delete_env(:cyfr, :caps)
    {:ok, doomed} = Athanors.create_group(uid0, "Doomed")
    {:ok, _} = Athanors.archive(doomed)
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count() + 1)
    assert {:ok, _} = Athanors.create_group(uid0, "Fits")

    # ...and taking the place back has to ask for it, or archive-then-reopen
    # would be the way past the cap.
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count())
    assert {:error, {:limit_reached, :max_athanors, _}} = Athanors.unarchive(doomed)
    Application.put_env(:cyfr, :caps, max_athanors: Athanors.count() + 1)
    assert {:ok, %{status: "active"}} = Athanors.unarchive(doomed)

    Application.put_env(:cyfr, :caps, max_groups_per_person: 1)
    uid = "github|https://github.com|capped-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Athanors.create_group(uid, "First")

    assert {:error, {:limit_reached, :max_groups_per_person, 1}} =
             Athanors.create_group(uid, "Second")
  end

  test "mint_per_hour bounds personal athanors minted per hour" do
    Application.put_env(:cyfr, :caps, mint_per_hour: 0)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|mint-#{n}",
        provider: "github",
        email: "mint#{n}@example.com",
        verified: true
      })

    {:ok, user} = Sanctum.Tenancy.Users.set_namespace(user, "mint#{n}")
    # a cap of 0 reads as off (nil), so the mint goes through
    assert {:ok, _} = Sanctum.Provisioning.ensure_personal_athanor(user)

    Application.put_env(:cyfr, :caps, mint_per_hour: 1)
    n2 = n + 1

    {:ok, user2} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|mint-#{n2}",
        provider: "github",
        email: "mint#{n2}@example.com",
        verified: true
      })

    {:ok, user2} = Sanctum.Tenancy.Users.set_namespace(user2, "mint#{n2}")
    # one was minted this hour already (above)
    assert {:error, {:limit_reached, :mint_per_hour, 1}} =
             Sanctum.Provisioning.ensure_personal_athanor(user2)

    # Groups people create do not draw on the mint budget: the cap measures
    # person athanors, so a member's `athanor.create` cannot starve sign-ins.
    Application.put_env(:cyfr, :caps, mint_per_hour: 2)
    {:ok, _} = Athanors.create_group(user.id, "Not a mint")
    assert {:ok, _} = Sanctum.Provisioning.ensure_personal_athanor(user2)
  end

  test "athanor_storage_bytes is one check for every writer" do
    # An athanor nothing else has written under, so the usage walk starts
    # at zero regardless of what ran before.
    ctx =
      Sanctum.Context.build(
        user_id: "local|local|caps",
        athanor_id: "ath_caps_#{System.unique_integer([:positive])}",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    Application.put_env(:cyfr, :caps, athanor_storage_bytes: 100)
    assert :ok = Caps.check_storage(ctx, 50)

    assert {:error, {:limit_reached, :athanor_storage_bytes, 100}} =
             Caps.check_storage(ctx, 1_000)

    Application.delete_env(:cyfr, :caps)
    assert :ok = Caps.check_storage(ctx, 1_000_000_000)
  end

  test "max_members_per_group counts seats — active and invited" do
    Application.put_env(:cyfr, :caps, max_members_per_group: 2)
    uid = "github|https://github.com|seat-#{System.unique_integer([:positive])}"
    {:ok, group} = Athanors.create_group(uid, "Seats")
    # creator holds one seat; one invitation fills the second
    assert {:ok, :invited} = Members.add(group, [email: "a-#{uid}@example.com"], uid)

    assert {:error, {:limit_reached, :max_members_per_group, 2}} =
             Members.add(group, [email: "b@example.com"], uid)
  end
end
