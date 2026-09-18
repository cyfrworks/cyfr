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
    Cyfr.Test.Sandbox.setup!()

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
    assert group.provisioned_at || Athanors.provisioning_failure(group)
  end

  test "a filled estate is ready", %{ctx: ctx, group: group} do
    {:ok, _} = Athanors.mark_provisioned(group)
    assert Provisioning.provisioned?(ctx)
    assert :ok = Provisioning.ready(ctx)
  end

  test "a turn on an estate still being filled says so", %{ctx: ctx, group: group} do
    {:ok, _} = Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: group.id)
    {:ok, thread} = Arca.ThreadStorage.create(ctx)

    # The roster is handed in: reading it would itself start the fill.
    assert {:error, :not_provisioned} =
             Aqua.Runner.send_message(ctx, thread.id, "@aqua hello",
               agents: [%{"name" => "aqua", "title" => "AQUA"}]
             )

    assert [] = Arca.ThreadStorage.messages(ctx, thread.id)

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

  test "a sign-in's own fill asks for the claim like any other" do
    # Every filler asks for the claim, not only the readers. Pinned on the
    # estate the sign-in actually fills: mint it first, hold ITS claim, then
    # sign in again. A sign-in that filled unclaimed would fill it anyway.
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|claimed-#{n}",
        provider: "github",
        email: "claimed#{n}@example.com",
        verified: true
      })

    assert {:ok, own} = Sanctum.Provisioning.ensure_personal_athanor(user)

    # The fill that just ran failed (this suite ships no bundle), so clear
    # the record: what is under test is the claim, not the backoff.
    {:ok, own} = Athanors.mark_provisioned(own)
    {:ok, own} = Athanors.update(own, %{provisioned_at: nil})

    refute own.provisioned_at

    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Sanctum.ProvisioningRegistry, own.id, :filling)
        send(parent, :claimed)
        receive do: (:release -> :ok)
      end)

    assert_receive :claimed

    assert {:ok, _} = Sanctum.Provisioning.ensure_personal_athanor(user)
    assert {:ok, %{provisioned_at: nil}} = Athanors.get(own.id)
    assert Athanors.provisioning_failure(Athanors.get(own.id) |> elem(1)) == nil

    send(holder, :release)
  end

  test "a claim is released when its attempt ends, not when its task does" do
    # One task fills several estates in turn — a sign-in retries a person's
    # groups — so a key held for the life of the task would keep the next
    # caller out of an estate nobody is filling.
    n = System.unique_integer([:positive])
    creator = "github|https://github.com|serial-#{n}"
    {:ok, first} = Athanors.create_group(creator, "Serial one #{n}")
    {:ok, second} = Athanors.create_group(creator, "Serial two #{n}")

    ctx = fn id -> %{Sanctum.TestContext.local() | user_id: creator, athanor_id: id} end

    # Fill both from one process, as the group retry does.
    assert :ok = Sanctum.Provisioning.start_provisioning(ctx.(first.id))
    assert :ok = Sanctum.Provisioning.start_provisioning(ctx.(second.id))

    # Neither key outlives its own attempt.
    assert Registry.lookup(Sanctum.ProvisioningRegistry, first.id) == []
    assert Registry.lookup(Sanctum.ProvisioningRegistry, second.id) == []
  end

  test "a fill that failed is not started again by the notice it caused",
       %{ctx: ctx, group: group} do
    # Recording a failure writes the row, and writing the row announces it —
    # which is what a console page reloads on. Its reads must not start
    # another attempt, or one failure becomes an endless retry.
    assert {:error, :not_provisioned} = Sanctum.Provisioning.ready(ctx)

    {:ok, failed} = Athanors.get(group.id)
    refute failed.provisioned_at
    assert %{at: first_at} = Athanors.provisioning_failure(failed)

    # Everything the reload would do, several times over.
    for _ <- 1..5, do: assert({:error, :not_provisioned} = Sanctum.Provisioning.ready(ctx))

    {:ok, again} = Athanors.get(group.id)
    assert Athanors.provisioning_failure(again).at == first_at

    # A person who asks is never told to wait: the explicit verb fills now.
    assert {:error, {:provisioning_failed, _, _}} = Sanctum.Provisioning.provision(again, ctx)
    {:ok, retried} = Athanors.get(group.id)
    assert Athanors.provisioning_failure(retried).at != first_at
  end

  test "the failure record is the server's: settings neither forge nor clear it",
       %{ctx: ctx, group: group} do
    assert {:error, :not_provisioned} = Sanctum.Provisioning.ready(ctx)
    {:ok, failed} = Athanors.get(group.id)
    assert %{at: failed_at} = Athanors.provisioning_failure(failed)

    # A member's settings patch naming the old document key reaches nothing
    # the backoff reads.
    future = DateTime.utc_now() |> DateTime.add(365, :day) |> DateTime.to_iso8601()

    for patch <- [%{"provisioning_error" => %{"at" => future}}, %{"provisioning_error" => nil}] do
      {:ok, patched} = Athanors.put_settings(failed, patch)
      assert Athanors.provisioning_failure(patched).at == failed_at
    end
  end

  test "a boot that does not own the control plane starts no fill", %{ctx: ctx, group: group} do
    on_exit(fn -> Cyfr.ControlPlane.mark(:unclaimed) end)

    Cyfr.ControlPlane.mark(:lost)
    assert {:error, :not_provisioned} = Provisioning.ready(ctx)
    {:ok, untouched} = Athanors.get(group.id)
    refute untouched.provisioned_at || Athanors.provisioning_failure(untouched)

    Cyfr.ControlPlane.mark(:unclaimed)
    assert {:error, :not_provisioned} = Provisioning.ready(ctx)
    {:ok, attempted} = Athanors.get(group.id)
    assert attempted.provisioned_at || Athanors.provisioning_failure(attempted)
  end

  test "a context with no athanor is never ready" do
    assert Provisioning.provisioned?(%Sanctum.Context{}) == false
    assert :ok = Provisioning.start_provisioning(%Sanctum.Context{})
  end
end
