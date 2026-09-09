# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningReadinessTest do
  @moduledoc """
  What an estate answers while it is being filled.

  The agent tree reads through the seed overlay from the moment the row
  exists, so a roster is real straight away. A component listing is
  database rows and answers what is registered, which on a bare estate is
  nothing until its scan lands. What provisioning adds is the baseline
  consent a turn pins, so a turn is what waits — and it says so, rather
  than failing later as a missing profile.
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

  test "a sign-in's own fill is claimed like any other", %{ctx: ctx, group: group} do
    # Every filler asks for the claim, not only the readers: a sign-in fills
    # the estate it just minted, and a reader arriving mid-fill must join
    # that attempt rather than queue a second one behind the same lock.
    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Sanctum.ProvisioningRegistry, group.id, :filling)
        send(parent, :claimed)
        receive do: (:release -> :ok)
      end)

    assert_receive :claimed

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|claimed-#{System.unique_integer([:positive])}",
        provider: "github",
        email: "claimed#{System.unique_integer([:positive])}@example.com",
        verified: true
      })

    # Its own estate is a different athanor, so this one is untouched: what
    # is pinned here is that the claim, not the lock, is what a fill asks
    # for first.
    assert {:ok, _} = Sanctum.Provisioning.ensure_personal_athanor(user)
    assert {:ok, %{provisioned_at: nil}} = Athanors.get(group.id)
    assert :ok = Sanctum.Provisioning.start_provisioning(ctx)
    assert {:ok, %{provisioned_at: nil}} = Athanors.get(group.id)

    send(holder, :release)
  end

  test "a fill that failed is not started again by the notice it caused",
       %{ctx: ctx, group: group} do
    # Recording a failure writes the row, and writing the row announces it —
    # which is what a console page reloads on. Its reads must not start
    # another attempt, or one failure becomes an endless retry.
    assert {:error, :not_provisioned} = Sanctum.Provisioning.ready(ctx)

    {:ok, failed} = Athanors.get(group.id)
    refute failed.provisioned_at
    assert %{"at" => first_at} = Athanors.settings(failed)["provisioning_error"]

    # Everything the reload would do, several times over.
    for _ <- 1..5, do: assert({:error, :not_provisioned} = Sanctum.Provisioning.ready(ctx))

    {:ok, again} = Athanors.get(group.id)
    assert Athanors.settings(again)["provisioning_error"]["at"] == first_at

    # A person who asks is never told to wait: the explicit verb fills now.
    assert {:error, {:provisioning_failed, _, _}} = Sanctum.Provisioning.provision(again, ctx)
    {:ok, retried} = Athanors.get(group.id)
    assert Athanors.settings(retried)["provisioning_error"]["at"] != first_at
  end

  test "a context with no athanor is never ready" do
    assert Provisioning.provisioned?(%Sanctum.Context{}) == false
    assert :ok = Provisioning.start_provisioning(%Sanctum.Context{})
  end
end
