# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningReadinessTest do
  @moduledoc """
  What an estate answers while it is being filled.

  The tree reads through the seed overlay from the moment the row exists,
  so a roster and a component listing are real straight away. What
  provisioning adds is the baseline consent a turn pins, so a turn is what
  waits — and it says so, rather than failing later as a missing profile.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    n = System.unique_integer([:positive])
    creator = "github|https://github.com|ready-#{n}"
    {:ok, group} = Athanors.create_group(creator, "Ready #{n}")
    ctx = %{Sanctum.TestContext.local() | user_id: creator, athanor_id: group.id}

    {:ok, group: group, ctx: ctx}
  end

  test "an unfilled estate is not ready, and asking starts the fill", %{ctx: ctx, group: group} do
    refute Provisioning.provisioned?(ctx)
    assert {:error, :not_provisioned} = Provisioning.ready(ctx)

    # The suite fills inline, so the attempt has already happened and its
    # outcome — success or a recorded failure — is on the row.
    {:ok, group} = Athanors.get(group.id)
    settings = Athanors.settings(group)
    assert group.provisioned_at || Map.has_key?(settings, "provisioning_error")
  end

  test "a filled estate is ready", %{ctx: ctx, group: group} do
    {:ok, _} = Athanors.mark_provisioned(group)
    assert Provisioning.provisioned?(ctx)
    assert :ok = Provisioning.ready(ctx)
  end

  test "a turn on an estate still being filled says so", %{ctx: ctx} do
    pick = %Aqua.Orchestrator{name: "aqua"}

    assert {:error, :not_provisioned} =
             Aqua.Turn.begin(ctx, "conv_never", pick, "hello")

    # And the refusal has a sentence every surface renders the same way.
    assert Cyfr.Ops.Error.render(:not_provisioned) =~ "still being prepared"
  end

  test "a reader adds nothing while a fill is already running", %{ctx: ctx, group: group} do
    # A page load asks several readers, and each starts the fill. Only one
    # attempt runs: the rest find the claim taken and return, rather than
    # queueing a worker that would wait out the lock and then repeat work
    # the running attempt is already doing — or has already failed at.
    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Sanctum.ProvisioningRegistry, group.id, :filling)
        send(parent, :claimed)
        receive do: (:release -> :ok)
      end)

    assert_receive :claimed

    for _ <- 1..12, do: assert(:ok = Sanctum.Provisioning.start_provisioning(ctx))

    # None of them filled anything: the claim is what serializes attempts,
    # before the lock rather than behind it.
    assert {:ok, %{provisioned_at: nil}} = Athanors.get(group.id)

    send(holder, :release)
  end

  test "a context with no athanor is never ready" do
    assert Provisioning.provisioned?(%Sanctum.Context{}) == false
    assert :ok = Provisioning.start_provisioning(%Sanctum.Context{})
  end
end
