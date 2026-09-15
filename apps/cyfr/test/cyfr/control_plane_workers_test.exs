# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlaneWorkersTest do
  @moduledoc """
  Background work runs only while this boot owns the control plane, and is
  asked on every tick: once ownership lapses under a running worker, its
  next tick writes nothing, and once ownership is regained the work goes
  on.
  """

  # Flips the process-wide ownership record.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.ControlPlane

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    on_exit(fn -> ControlPlane.mark(:unclaimed) end)
    :ok
  end

  test "work runs for the owner alone" do
    assert ControlPlane.when_owner(fn -> :ran end) == :ran
    ControlPlane.mark(:lost)
    assert ControlPlane.when_owner(fn -> :ran end) == :not_owner
    ControlPlane.mark({:held, DateTime.add(DateTime.utc_now(), -1, :second)})
    assert ControlPlane.when_owner(fn -> :ran end) == :not_owner
  end

  test "the retention tick deletes nothing without ownership, and sweeps once it is regained" do
    hash = :crypto.hash(:sha256, "expired-#{System.unique_integer([:positive])}")

    :ok =
      Arca.SessionStorage.create_session(hash, %{
        user_id: "user_1",
        email: "user@example.com",
        provider: "github",
        permissions: "[]",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        token_prefix: "cyfr_"
      })

    state = %{interval: :timer.hours(999)}

    ControlPlane.mark(:lost)
    assert {:noreply, ^state} = Cyfr.RetentionScheduler.handle_info(:run_cleanup, state)
    assert sessions(hash) == 1

    ControlPlane.mark(:unclaimed)
    assert {:noreply, ^state} = Cyfr.RetentionScheduler.handle_info(:run_cleanup, state)
    assert sessions(hash) == 0
  end

  test "no runner starts on a boot that does not own the control plane" do
    ControlPlane.mark(:lost)
    thread_id = "thr_#{System.unique_integer([:positive])}"

    assert {:error, :control_plane_lost} = Aqua.Runner.ensure(thread_id, "ath_test")
    assert Aqua.Runner.whereis(thread_id) == nil
  end

  defp sessions(hash) do
    Arca.Repo.aggregate(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash), :count)
  end
end
