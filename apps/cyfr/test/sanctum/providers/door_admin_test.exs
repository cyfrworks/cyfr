# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.DoorAdminTest do
  @moduledoc """
  `door.mark_admin` and `door.clear_admin`: a platform administrator makes
  another person of this CYFR an administrator, writing their account's
  allow, and takes the mark away, each only under a fresh confirmation
  naming the person; the last mark is never taken away, and a denied
  person is never marked.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Providers.Door
  alias Sanctum.Tenancy
  alias Sanctum.Tenancy.Users

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)

    n = System.unique_integer([:positive])

    [ops, mira] =
      for name <- ["ops", "mira"] do
        {:ok, user} =
          Sanctum.Test.People.linked(%{
            id: "github|https://github.com|#{name}-#{n}",
            provider: "github",
            email: "#{name}#{n}@example.com",
            verified: true
          })

        user
      end

    {:ok, _} = Tenancy.Users.set_namespace(mira, "mira-#{n}")
    {:ok, _} = Sanctum.TestContext.ensure_platform(ops.id)
    admin = Sanctum.TestContext.session!(ops.id) |> Map.put(:platform_admin, true)
    %{ops: ops, mira: mira, admin: admin, n: n}
  end

  defp door(ctx, action, person),
    do: Door.handle(ctx, %{"action" => action, "person" => person})

  test "both are the platform administrator's, and taking the mark away reduces authority" do
    %{operations: operations} = Door.definition()

    for action <- ["mark_admin", "clear_admin"] do
      operation = Enum.find(operations, &(&1.action == action))
      assert operation.scope == :platform, action
      assert [%{name: "person", required: true}] = operation.args
    end

    assert Enum.find(operations, &(&1.action == "clear_admin")).reduces_authority
  end

  test "marking asks a fresh confirmation and changes nothing without it", %{
    admin: admin,
    mira: mira
  } do
    assert {:error, {:confirmation_required, %{operation: "door.mark_admin"}}} =
             door(admin, "mark_admin", mira.id)

    refute Tenancy.platform_admin?(mira.id)
  end

  test "under its confirmation another person is marked by their name here and allowed, and the mark comes off again",
       %{admin: admin, ops: ops, mira: mira, n: n} do
    {:ok, identifier} = Users.identifier(mira.id)

    assert {:ok, %{user_id: user_id, platform_admin: true}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "mark_admin", "@mira-#{n}"))

    assert user_id == mira.id
    assert Tenancy.platform_admin?(mira.id)

    assert {:ok, true} = Sanctum.Door.Store.allowed("identifier", identifier)
    assert Enum.map(Users.platform_admins(), & &1.id) == [ops.id, mira.id]

    # The person marked may now take the first administrator's mark away.
    mira_admin = Sanctum.TestContext.session!(mira.id) |> Map.put(:platform_admin, true)

    assert {:ok, %{user_id: cleared, platform_admin: false}} =
             Sanctum.TestContext.confirming(mira_admin, &door(&1, "clear_admin", ops.id))

    assert cleared == ops.id
    refute Tenancy.platform_admin?(ops.id)

    # Their allow stays, as every administrator's does.
    assert {:ok, true} = Sanctum.Door.Store.allowed("identifier", identifier)
  end

  test "the last mark is never taken away", %{admin: admin, ops: ops} do
    assert {:error, {:invalid_argument, sentence}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "clear_admin", ops.id))

    assert sentence =~ "last platform administrator"
    assert Tenancy.platform_admin?(ops.id)
    assert [%{id: id}] = Users.platform_admins()
    assert id == ops.id
  end

  test "an administrator whose mark was cleared marks and clears nothing, though their session still reads the mark",
       %{admin: admin, ops: ops, mira: mira} do
    assert {:ok, %{platform_admin: true}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "mark_admin", mira.id))

    # Mira's session read her mark; ops then takes it away.
    mira_admin = Sanctum.TestContext.session!(mira.id) |> Map.put(:platform_admin, true)

    assert {:ok, %{platform_admin: false}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "clear_admin", mira.id))

    assert {:error, :platform_admin_required} =
             Sanctum.TestContext.confirming(mira_admin, &door(&1, "clear_admin", ops.id))

    assert {:error, :platform_admin_required} =
             Sanctum.TestContext.confirming(mira_admin, &door(&1, "mark_admin", mira.id))

    assert Tenancy.platform_admin?(ops.id)
    refute Tenancy.platform_admin?(mira.id)
  end

  test "a deny of the person by their id refuses their marking", %{admin: admin, mira: mira} do
    {:ok, _} = Sanctum.Door.Store.deny("person", mira.id, admin.user_id)

    assert {:error,
            {:invalid_argument, "A deny names that person's account; remove the deny first"}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "mark_admin", mira.id))

    refute Tenancy.platform_admin?(mira.id)
  end

  test "a denied person, a deny of their account and a person no one here is are refused", %{
    admin: admin,
    mira: mira
  } do
    {:ok, identifier} = Users.identifier(mira.id)
    {:ok, _} = Sanctum.Door.Store.deny("identifier", identifier, admin.user_id)

    assert {:error,
            {:invalid_argument, "A deny names that person's account; remove the deny first"}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "mark_admin", mira.id))

    {:ok, _} = Users.deny(mira)

    assert {:error, {:invalid_argument, "That person is denied here; allow them first"}} =
             Sanctum.TestContext.confirming(admin, &door(&1, "mark_admin", mira.id))

    refute Tenancy.platform_admin?(mira.id)

    assert {:error, {:not_found, "Person", "@nobody-here"}} =
             door(admin, "mark_admin", "@nobody-here")

    assert {:error, {:invalid_argument, _}} = door(admin, "mark_admin", "mira")
  end
end
