# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlaneWorkersTest do
  @moduledoc """
  Background work runs only while this member holds its cell slot, and is
  asked on every tick: once the slot lapses under a running worker, its
  next tick writes nothing, and once the slot is won back the work goes
  on.
  """

  # Flips the process-wide standing record.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    on_exit(fn -> ControlPlane.record(:unclaimed) end)
    :ok
  end

  test "the retention tick deletes nothing without the slot, and sweeps once it is regained" do
    hash = :crypto.hash(:sha256, "expired-#{System.unique_integer([:positive])}")

    :ok =
      Arca.SessionStorage.create_session(
        hash,
        %{
          user_id: "user_1",
          email: "user@example.com",
          provider: "github",
          permissions: "[]",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
          token_prefix: "cyfr_"
        },
        Arca.Test.Actor.issuance("user_1")
      )

    state = %{interval: :timer.hours(999)}

    ControlPlane.record(:lost)
    assert {:noreply, ^state} = Cyfr.RetentionScheduler.handle_info(:run_cleanup, state)
    assert sessions(hash) == 1

    ControlPlane.record(:unclaimed)
    assert {:noreply, ^state} = Cyfr.RetentionScheduler.handle_info(:run_cleanup, state)
    assert sessions(hash) == 0
  end

  for loss <- [:lost, :expired] do
    test "no runner starts when the slot is #{loss}" do
      standing =
        case unquote(loss) do
          :lost -> :lost
          :expired -> {:held, 0}
        end

      ControlPlane.record(standing)
      thread_id = "thr_#{System.unique_integer([:positive])}"

      assert {:error, :control_plane_lost} = Aqua.Runner.ensure(thread_id, "ath_test")
      assert :ignore = Aqua.Runner.start_link({thread_id, "ath_test"})
      assert Aqua.Runner.whereis(thread_id) == nil
    end
  end

  defp sessions(hash) do
    Arca.Repo.aggregate(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash), :count)
  end
end
