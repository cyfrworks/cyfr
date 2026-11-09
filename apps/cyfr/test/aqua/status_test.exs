# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.StatusTest do
  @moduledoc """
  The status watch: a refresh of `system.changes` has it keep the
  athanor, and it tells the athanor's system topic a status only when it
  moved — on its tick, a settled burst of vault entries or components, or
  a later refresh that read a newer one — and drops an athanor whose
  opening expired. The status is moved by the storage reserve's latch,
  which every read sees at once.
  """

  # The latch is the node's and the watch is the named one.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Aqua.Providers.Status, as: Provider
  alias Cyfr.Bus
  alias Cyfr.Bus.{Components, SystemStatus, VaultEntry}
  alias Sanctum.Context

  setup tags do
    on_exit(fn -> Arca.StorageReserve.put(:ok) end)
    Cyfr.Test.Sandbox.setup!(tags)
    ctx = person!()
    actor = Context.actor(ctx)
    :ok = Bus.subscribe(actor, Bus.system(actor))
    {:ok, ctx: ctx, actor: actor}
  end

  # A person with their own athanor, filled, so no fill moves what a read
  # sees between two reads.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|status-#{n}",
        provider: "github",
        email: "status-#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)
    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "passkey",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    ctx
  end

  test "a tick tells the status only when it moved", %{ctx: ctx} do
    watch = start_supervised!(Aqua.Status)
    {:ok, [opened]} = Provider.status(ctx, nil)
    assert opened.health != "low_storage"

    tick(watch)
    refute_received %SystemStatus{}

    Arca.StorageReserve.put(:depleted)
    tick(watch)
    assert_received %SystemStatus{kind: :changed, health: "low_storage"} = told
    assert said(told) == said(%{opened | health: "low_storage"})
    assert told.revision > opened.revision

    tick(watch)
    refute_received %SystemStatus{}

    Arca.StorageReserve.put(:ok)
    tick(watch)
    assert_received %SystemStatus{} = back
    assert said(back) == said(opened)
    assert back.revision > told.revision
  end

  test "a burst of vault entries or components is read once, a second after it began", %{
    ctx: ctx,
    actor: actor
  } do
    watch = start_supervised!(Aqua.Status)
    {:ok, [opened]} = Provider.status(ctx, nil)

    Arca.StorageReserve.put(:depleted)

    for name <- ~w(a b c) do
      :ok =
        Bus.broadcast(
          actor,
          Bus.vault_entries(actor),
          VaultEntry.new(actor, :changed, name: name, type: "api_key", status: "fine")
        )
    end

    assert_receive %SystemStatus{health: "low_storage"}, 5_000
    settled(watch)
    refute_received %SystemStatus{}

    # An entry whose read finds nothing moved tells nothing.
    :ok =
      Bus.broadcast(actor, Bus.vault_entries(actor), VaultEntry.new(actor, :removed, name: "a"))

    wait_until(fn -> :sys.get_state(watch).settling == MapSet.new() end, 5_000, "the burst")
    settled(watch)
    refute_received %SystemStatus{}

    Arca.StorageReserve.put(:ok)
    :ok = Bus.broadcast(actor, Bus.components(actor), Components.new(actor, :changed))
    assert_receive %SystemStatus{} = back, 5_000
    assert said(back) == said(opened)
  end

  # What a status says, its delivery stamp aside: every read stamps the
  # time it began.
  defp said(status), do: Map.drop(status, [:revision, :at])

  test "a later refresh that read a newer status tells the earlier subscribers", %{ctx: ctx} do
    start_supervised!(Aqua.Status)
    {:ok, [_opened]} = Provider.status(ctx, nil)
    refute_receive %SystemStatus{}, 100

    Arca.StorageReserve.put(:depleted)
    {:ok, [newer]} = Provider.status(ctx, nil)
    assert_receive ^newer, 5_000
    assert newer.health == "low_storage"
  end

  test "an athanor whose opening expired is dropped at the tick, and heard no more", %{
    ctx: ctx,
    actor: actor
  } do
    watch = start_supervised!({Aqua.Status, bound_ms: 0})
    {:ok, [_opened]} = Provider.status(ctx, nil)

    tick(watch)
    assert :sys.get_state(watch).watched == %{}

    Arca.StorageReserve.put(:depleted)
    :ok = Bus.broadcast(actor, Bus.components(actor), Components.new(actor, :changed))
    tick(watch)
    refute_receive %SystemStatus{}, 1_500
    assert :sys.get_state(watch).settling == MapSet.new()
  end

  test "an unexpected message is logged by its shape, and the watch goes on" do
    watch = start_supervised!(Aqua.Status)

    log =
      capture_log(fn ->
        send(watch, {:random, "payload"})
        :sys.get_state(watch)
      end)

    assert log =~ "unexpected message"
    refute log =~ "payload\""
    assert Process.alive?(watch)
  end

  test "a suite's watch that is not enabled starts nothing" do
    assert Aqua.Status.start_link(enabled: false) == :ignore
  end

  # A tick, and every read it started taken in.
  defp tick(watch) do
    send(watch, :tick)
    settled(watch)
  end

  defp settled(watch),
    do: wait_until(fn -> :sys.get_state(watch).reading == %{} end, 10_000, "the watch's reads")
end
