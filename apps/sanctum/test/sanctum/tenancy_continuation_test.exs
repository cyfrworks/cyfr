# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyContinuationTest do
  @moduledoc """
  A recovered turn continues as the person, with the person's surface,
  or not at all: a denied user with a surviving membership, a removed
  member and an archived estate are refused, never degraded.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|cont#{n}",
        provider: "github",
        email: "cont#{n}@example.com",
        verified: true,
        name: "Cont #{n}"
      })

    {:ok, estate} =
      Athanors.create_group(user.id, "Continuation #{System.unique_integer([:positive])}")

    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: estate.id)
    {:ok, user: user, estate: estate}
  end

  test "a seated person continues with the person's surface", %{user: user, estate: estate} do
    assert {:ok, ctx} = Tenancy.continuation(user.id, estate.id)
    assert ctx.user_id == user.id and ctx.athanor_id == estate.id
    assert ctx.auth_method == :oidc and ctx.authenticated
    assert ctx.scope == :athanor
    assert MapSet.equal?(ctx.permissions, MapSet.new(Sanctum.Atoms.person_permissions()))
    assert {:ok, :interactive} = Sanctum.Consent.Authz.authorize_interactive(ctx)
  end

  test "a person not seated in the turn's estate, and an unknown person, are refused", %{
    user: user
  } do
    {:ok, other} =
      Athanors.create_group(
        "github|https://github.com|owner",
        "Elsewhere #{System.unique_integer([:positive])}"
      )

    refute Members.member?(user.id, other.id)
    assert {:error, :not_member} = Tenancy.continuation(user.id, other.id)
    assert {:error, :denied} = Tenancy.continuation("usr_nobody", other.id)
  end

  test "a denied person is refused even while a membership row survives", %{
    user: user,
    estate: estate
  } do
    # Another member keeps the estate open through the denial, so the
    # surviving row lands in an estate that still stands.
    {:ok, _} = Members.ensure("usr_keeper", scope: "athanor", athanor_id: estate.id)
    {:ok, _} = Users.deny(user)
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: estate.id)
    assert Members.member?(user.id, estate.id)
    assert {:error, :denied} = Tenancy.continuation(user.id, estate.id)
  end
end
