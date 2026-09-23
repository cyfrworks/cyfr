# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SeedOfferTest do
  @moduledoc """
  The boot's seed offer is optional work: it runs under a claim of its
  own, a peer holding that claim is not waited for, and nothing that goes
  wrong in it stops the boot — `init/1` answers `:ignore` whatever
  happened.
  """
  use ExUnit.Case, async: false

  alias Arca.JobClaims
  alias Cyfr.SeedOffer

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # `job_claims` is shared, cross-node state; each case claims under a
    # key of its own.
    {:ok, key: "cell-seed-#{System.unique_integer([:positive])}"}
  end

  test "the offer runs under its own claim and gives it up for the next boot", %{key: key} do
    test = self()

    assert :ok =
             SeedOffer.run(key: key, owner: "member-a", sync: fn -> send(test, :synced) end)

    assert_received :synced
    assert {:ok, row} = JobClaims.read("seed_release", key)
    assert row.owner == "member-a"
    refute JobClaims.live?(row), "seed_release was left claimed"
  end

  test "the seed offer is the cell's: a member that loses it does not wait", %{key: key} do
    {:ok, _peer} = JobClaims.claim("seed_release", key, "member-b", 60_000)

    began = System.monotonic_time(:millisecond)

    assert :skipped =
             SeedOffer.run(
               key: key,
               owner: "member-a",
               sync: fn -> flunk("synced a peer's offer") end
             )

    waited = System.monotonic_time(:millisecond) - began

    assert waited < 1_000
    assert {:ok, %{owner: "member-b"}} = JobClaims.read("seed_release", key)
  end

  test "a failed offer is logged and never stops the boot", %{key: key} do
    for {failure, class} <- [
          {fn -> raise "registry unreachable" end, :exception},
          {fn -> raise DBConnection.ConnectionError, "connection lost" end, :exception},
          {fn -> exit(:boom) end, :exception}
        ] do
      assert {:error, ^class} = SeedOffer.run(key: key, sync: failure)

      # The claim is given back even though the work failed.
      assert {:ok, row} = JobClaims.read("seed_release", key)
      refute JobClaims.live?(row)

      assert :ignore = SeedOffer.start_link(key: key, sync: failure)
    end
  end

  test "after a successful security reconcile, a failing offer still leaves the boot standing",
       %{key: key} do
    prev = Application.get_env(:sanctum, :platform_admin_emails, [])
    Application.put_env(:sanctum, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:sanctum, :platform_admin_emails, prev) end)

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Cyfr.Bootstrap, key: key}, restart: :temporary),
          Supervisor.child_spec({SeedOffer, key: key, sync: fn -> raise "boom" end},
            restart: :temporary
          ),
          {Agent, fn -> :after_the_offer end}
        ],
        strategy: :one_for_one
      )

    assert [{Agent, pid, :worker, _}] = Supervisor.which_children(supervisor)
    assert Agent.get(pid, & &1) == :after_the_offer
    Supervisor.stop(supervisor)
  end
end
