# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlaneTest do
  # Starts the ownership server against the sandbox and flips the
  # process-wide ownership record, so it owns both for its run.
  use ExUnit.Case, async: false

  alias Cyfr.ControlPlane
  alias Cyfr.ControlPlane.Claim

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Process.flag(:trap_exit, true)
    on_exit(fn -> ControlPlane.mark(:unclaimed) end)
    :ok
  end

  defp me, do: Cyfr.Boot.id()

  test "a boot claims the plane at start and releases it at stop" do
    {:ok, pid} = ControlPlane.start_link(name: nil, lease_ms: 60_000, renew_ms: 60_000)
    assert ControlPlane.owner?()
    assert {:ok, owner, _until} = Claim.holder()
    assert owner == me()

    :ok = GenServer.stop(pid)
    refute ControlPlane.owner?()

    # The row is left expired: the next boot claims without waiting.
    assert {:ok, _} = Claim.claim("boot-next", 60_000)
  end

  test "ownership is the lease deadline: it lapses on the clock and is regained by renewal" do
    {:ok, pid} = ControlPlane.start_link(name: nil, lease_ms: 150, renew_ms: 400)
    assert ControlPlane.owner?()

    # No renewal tick has run yet, and the lease is over: not the owner.
    Process.sleep(200)
    refute ControlPlane.owner?()
    assert {:error, :control_plane_lost} = ControlPlane.assert_owner()

    # The tick renews the row this boot still holds and ownership returns.
    Process.sleep(300)
    assert ControlPlane.owner?()

    :ok = GenServer.stop(pid)
  end

  test "a successor takes an expired row and the old holder stays out" do
    {:ok, pid} = ControlPlane.start_link(name: nil, lease_ms: 150, renew_ms: 300)
    Process.sleep(200)
    refute ControlPlane.owner?()

    assert {:ok, _} = Claim.claim("boot-successor", 60_000)

    # The old holder's tick finds the row another's, records the loss and
    # cannot reclaim a live lease.
    Process.sleep(250)
    refute ControlPlane.owner?()
    assert {:ok, "boot-successor", _} = Claim.holder()

    :ok = GenServer.stop(pid)
    # Stopping does not touch a row that is no longer this boot's.
    assert {:ok, "boot-successor", _} = Claim.holder()
  end

  test "a holder that stopped without releasing is waited out and replaced" do
    assert {:ok, _} = Claim.claim("boot-killed", 300)

    started = System.monotonic_time(:millisecond)
    {:ok, pid} = ControlPlane.start_link(name: nil, lease_ms: 60_000, renew_ms: 60_000)
    waited = System.monotonic_time(:millisecond) - started

    assert waited >= 250
    assert ControlPlane.owner?()
    assert {:ok, owner, _} = Claim.holder()
    assert owner == me()

    :ok = GenServer.stop(pid)
  end

  test "a holder that keeps renewing is live, and the second boot refuses" do
    assert {:ok, _} = Claim.claim("boot-live", 400)
    test = self()

    renewer =
      spawn_link(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, test, self())

        Stream.repeatedly(fn ->
          {:ok, _} = Claim.renew("boot-live", 400)
          Process.sleep(100)
        end)
        |> Stream.run()
      end)

    # A refused boot marks nothing: whatever the record said before, it
    # says after.
    ControlPlane.mark(:lost)

    assert {:error, {%RuntimeError{message: message}, _stack}} =
             ControlPlane.start_link(name: nil, lease_ms: 500, renew_ms: 60_000)

    assert message =~ "another control plane (boot-live)"
    refute ControlPlane.owner?()

    Process.exit(renewer, :kill)
    assert {:ok, "boot-live", _} = Claim.holder()
  end

  test "the ownership record is fail-closed once a claim is configured" do
    ControlPlane.mark(:unclaimed)
    previous = Application.get_env(:cyfr, :control_plane_claim_enabled)

    try do
      Application.put_env(:cyfr, :control_plane_claim_enabled, true)
      refute ControlPlane.owner?()
      Application.put_env(:cyfr, :control_plane_claim_enabled, false)
      assert ControlPlane.owner?()
    after
      Application.put_env(:cyfr, :control_plane_claim_enabled, previous)
    end
  end
end
