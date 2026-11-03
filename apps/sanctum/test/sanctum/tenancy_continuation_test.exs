# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenancyContinuationTest do
  @moduledoc """
  A recovered turn continues as the person, with the person's surface,
  under the origin its row stores, or not at all: a missing or unknown
  origin is refused before anything is read, and a denied user with a
  surviving membership, a person not seated and an archived athanor are
  refused, never degraded.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|cont#{n}",
        provider: "github",
        email: "cont#{n}@example.com",
        verified: true,
        name: "Cont #{n}"
      })

    {:ok, user: user, athanor: Sanctum.Test.People.athanor!(user)}
  end

  test "a seated person continues with the person's surface, under the stored origin", %{
    user: user,
    athanor: athanor
  } do
    assert {:ok, ctx} = Tenancy.continuation(user.id, athanor.id, "interactive")
    assert ctx.user_id == user.id and ctx.athanor_id == athanor.id
    assert ctx.auth_method == :oidc and ctx.authenticated
    assert ctx.scope == :athanor
    assert ctx.origin == :interactive
    assert MapSet.equal?(ctx.permissions, MapSet.new(Sanctum.Atoms.person_permissions()))
    assert {:ok, :interactive} = Sanctum.Consent.Authz.authorize_interactive(ctx)
  end

  test "the origin is the stored one, as the row spells it, never the person's", %{
    user: user,
    athanor: athanor
  } do
    # A programmatic turn a person continues — a launch they approved, a
    # turn recovered after a restart — stays programmatic.
    for origin <- Prima.Origin.values() do
      assert {:ok, %{origin: ^origin}} =
               Tenancy.continuation(user.id, athanor.id, Prima.Origin.to_wire(origin))
    end
  end

  test "a missing or unknown origin is refused before anything is read", %{
    user: user,
    athanor: athanor
  } do
    for origin <- [nil, "batch", :batch, :interactive, "", "Interactive", 1] do
      assert {:error, :no_origin} = Tenancy.continuation(user.id, athanor.id, origin)
    end

    # Nothing was read: a person and an athanor that do not exist would
    # otherwise answer `:denied`.
    assert {:error, :no_origin} = Tenancy.continuation("usr_nobody", "ath_nowhere", nil)
    assert {:error, :denied} = Tenancy.continuation("usr_nobody", "ath_nowhere", "interactive")
  end

  test "a person not seated in the turn's athanor, and an unknown person, are refused", %{
    user: user
  } do
    n = System.unique_integer([:positive])

    {:ok, other} =
      Athanors.create(%{
        name: "Elsewhere #{n}",
        slug: "elsewhere-#{n}",
        owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
        created_by: "system"
      })

    refute Members.member?(user.id, other.id)
    assert {:error, :not_member} = Tenancy.continuation(user.id, other.id, "programmatic")
    assert {:error, :denied} = Tenancy.continuation("usr_nobody", other.id, "programmatic")
  end

  test "a denied person is refused even while a membership row survives", %{
    user: user,
    athanor: athanor
  } do
    # The denial archives the person's athanor and takes their seat; both
    # put back by hand, the surviving row lands in an athanor that stands.
    {:ok, _} = Users.deny(user)

    Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor.id),
      set: [status: "active"]
    )

    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)
    assert Members.member?(user.id, athanor.id)
    assert {:error, :denied} = Tenancy.continuation(user.id, athanor.id, "schedule")
  end

  test "a person whose athanor was archived is refused", %{user: user, athanor: athanor} do
    {:ok, _} = Athanors.archive(athanor, force: true)
    # Archiving deletes nothing: the seat stands, and the athanor refuses.
    assert Members.member?(user.id, athanor.id)
    assert {:error, :archived} = Tenancy.continuation(user.id, athanor.id, "webhook")
  end
end
