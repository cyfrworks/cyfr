# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BootstrapTest do
  @moduledoc """
  What boot puts right: the server always has an active Home, and the
  operators are the ones `CYFR_PLATFORM_ADMIN_EMAILS` names.

  A sign-in reconciles a platform row against that list, but only for
  someone the door still admits — drop an operator from the env list *and*
  from the allowlist and nothing else would ever revoke the row, or the
  session holding its capability.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Application.get_env(:cyfr, :platform_admin_emails, [])

    # The suite disables the boot task (a write before any sandbox checkout);
    # these tests are about what it does, so they turn it back on.
    Application.put_env(:cyfr, :provisioning_boot_enabled, true)

    on_exit(fn ->
      Application.put_env(:cyfr, :platform_admin_emails, prev)
      Application.put_env(:cyfr, :provisioning_boot_enabled, false)
    end)

    :ok
  end

  defp operator(n, email) do
    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|ops-#{n}",
        provider: "github",
        email: email,
        verified: true
      })

    {:ok, _} = Members.ensure_platform(user.id)
    user
  end

  test "a platform row the env list no longer names loses its scope and its sessions" do
    n = System.unique_integer([:positive])
    kept = operator(n, "kept#{n}@example.com")
    dropped = operator(n + 1, "dropped#{n}@example.com")

    {:ok, session} =
      Sanctum.Session.create(
        Sanctum.Context.build(
          user_id: dropped.id,
          athanor_id: Sanctum.TestContext.athanor_id(),
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    Application.put_env(:cyfr, :platform_admin_emails, ["kept#{n}@example.com"])
    :ok = Cyfr.Bootstrap.run()

    assert Enum.any?(Members.list_by_user(kept.id), &(&1.scope == "platform"))
    refute Enum.any?(Members.list_by_user(dropped.id), &(&1.scope == "platform"))
    assert {:error, _} = Sanctum.Session.load(session.token, surface: :console)
  end

  test "boot mints a Home when the last one was retired by its final member" do
    home = Athanors.home!()

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|home-#{n}",
        provider: "github",
        email: "home#{n}@example.com",
        verified: true
      })

    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: home.id)
    :ok = Members.remove_member(home, user_id: user.id)
    assert {:error, :not_found} = Athanors.home()

    Application.put_env(:cyfr, :platform_admin_emails, [])
    :ok = Cyfr.Bootstrap.run()

    assert {:ok, successor} = Athanors.home()
    assert successor.id != home.id
    assert successor.slug == "home"
    assert {:ok, %{status: "archived", home: true}} = Athanors.get(home.id)
  end
end
