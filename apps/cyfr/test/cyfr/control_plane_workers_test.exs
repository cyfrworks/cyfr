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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
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

    Prima.Test.Env.put_app_env(:cyfr, :retention_scheduler_enabled, true)

    ControlPlane.record(:lost)
    tick!()
    # Without the slot the tick does nothing at all: it does not even ask
    # for the cycle's claim.
    assert {:error, :not_found} = Arca.JobClaims.read("retention", Arca.JobClaims.cell_key())
    assert sessions(hash) == 1

    ControlPlane.record(:unclaimed)
    tick!()
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

  # One tick of the shipped scheduler, entered by its start: its first
  # cycle runs before it answers a call, and its stop cancels the next.
  defp tick! do
    pid = start_supervised!(Cyfr.RetentionScheduler)
    _ = :sys.get_state(pid)
    :ok = stop_supervised(Cyfr.RetentionScheduler)
  end

  defp sessions(hash) do
    Arca.Repo.aggregate(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash), :count)
  end
end
