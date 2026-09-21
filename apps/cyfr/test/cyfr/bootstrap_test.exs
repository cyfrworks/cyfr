# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BootstrapTest do
  @moduledoc """
  What boot puts right: the operators are the ones
  `CYFR_PLATFORM_ADMIN_EMAILS` names.

  A sign-in reconciles a platform row against that list, but only for
  someone the door still admits — drop an operator from the env list *and*
  from the allowlist and nothing else would ever revoke the row, or the
  session holding its capability.
  """
  use ExUnit.Case, async: false

  alias Arca.JobClaims
  alias Sanctum.Tenancy.{Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Application.get_env(:sanctum, :platform_admin_emails, [])

    # The suite disables the boot task (a write before any sandbox checkout);
    # these tests are about what it does, so they turn it back on.
    Application.put_env(:cyfr, :provisioning_boot_enabled, true)

    on_exit(fn ->
      Application.put_env(:sanctum, :platform_admin_emails, prev)
      Application.put_env(:cyfr, :provisioning_boot_enabled, false)
    end)

    # `job_claims` is shared, cross-node, node-global state many test
    # files write. Each case here claims under a key of its own and reads
    # back the row it wrote.
    {:ok, key: "cell-boot-#{System.unique_integer([:positive])}"}
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

  test "a platform row the env list no longer names loses its scope and its sessions", %{
    key: key
  } do
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

    Application.put_env(:sanctum, :platform_admin_emails, ["kept#{n}@example.com"])
    :ok = Cyfr.Bootstrap.run(key: key)

    assert {:ok, kept_rows} = Members.list_by_user(kept.id)
    assert Enum.any?(kept_rows, &(&1.scope == "platform"))
    assert {:ok, dropped_rows} = Members.list_by_user(dropped.id)
    refute Enum.any?(dropped_rows, &(&1.scope == "platform"))
    assert {:error, _} = Sanctum.Session.load(session.token, surface: :console)
  end

  describe "the two claimed jobs" do
    test "each half is taken under its own row and given up for the next boot", %{key: key} do
      Application.put_env(:sanctum, :platform_admin_emails, [])

      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-a")

      for kind <- ["bootstrap", "seed_release"] do
        assert {:ok, row} = JobClaims.read(kind, key)
        assert row.owner == "member-a"

        refute JobClaims.live?(row),
               "#{kind} was left claimed, so the next boot waits a lease out"
      end
    end

    test "a live peer's reconcile is waited for, not repeated beside it", %{key: key} do
      n = System.unique_integer([:positive])
      dropped = operator(n, "dropped#{n}@example.com")
      Application.put_env(:sanctum, :platform_admin_emails, [])

      {:ok, peer} = JobClaims.claim("bootstrap", key, "member-b", 60_000)

      began = System.monotonic_time(:millisecond)
      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-a", wait_ms: 400)
      waited = System.monotonic_time(:millisecond) - began

      # It waited for the holder rather than reconciling beside it, and
      # went on rather than holding its endpoint shut for ever.
      assert waited >= 400

      assert {:ok, still_held} = JobClaims.read("bootstrap", key)
      assert still_held.fence == peer.fence
      assert still_held.owner == "member-b"

      assert {:ok, rows} = Members.list_by_user(dropped.id)

      assert Enum.any?(rows, &(&1.scope == "platform")),
             "this boot reconciled under a claim a peer held"
    end

    test "the seed offer is the cell's: a member that loses it does not wait", %{key: key} do
      {:ok, _peer} = JobClaims.claim("seed_release", key, "member-b", 60_000)
      Application.put_env(:sanctum, :platform_admin_emails, [])

      began = System.monotonic_time(:millisecond)
      assert :ok = Cyfr.Bootstrap.run(key: key, owner: "member-a")
      waited = System.monotonic_time(:millisecond) - began

      assert waited < 1_000
      assert {:ok, %{owner: "member-b"}} = JobClaims.read("seed_release", key)
    end
  end

  describe "the boot child gates the web tier" do
    # Synchronous initialization must finish before the web tier starts
    # accepting requests.

    test "start_link does its work before returning, and leaves nothing behind" do
      me = self()

      Application.put_env(:sanctum, :platform_admin_emails, [])

      # `:ignore` is the one-shot answer: the work already happened inside
      # `init/1`, so there is no process for the supervisor to hold.
      assert :ignore = Cyfr.Bootstrap.start_link([])

      # Nothing was left linked to this process — a lingering child would mean
      # the work had been handed off rather than completed.
      {:links, links} = Process.info(me, :links)
      assert Enum.all?(links, &Process.alive?/1)
    end

    test "a raise inside the boot work does not take the server down with it" do
      # A bootstrap failure must not prevent the server from starting.
      Application.put_env(:sanctum, :platform_admin_emails, :not_a_list)

      assert :ignore = Cyfr.Bootstrap.start_link([])
    end
  end
end
