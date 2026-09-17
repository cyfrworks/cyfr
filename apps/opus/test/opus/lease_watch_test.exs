# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.LeaseWatchTest do
  # The runner's lease watch renews through its attempt's `renew` host
  # call. A renewal CYFR refuses stops the runner on the first answer; a
  # renewal CYFR cannot answer is tolerated only inside the lease the
  # attempt last held.
  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Opus.{HostClient, Runner}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    attempt = AttemptFixtures.attached!()
    {:ok, attempt: attempt, client: HostClient.new(attempt.keys, attempt.runner, attempt.boot)}
  end

  defp watch(client, until), do: %{client: client, until: until}

  defp far, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  test "a renewal CYFR refuses lapses the watch at once, inside the lease last held", %{
    attempt: attempt,
    client: client
  } do
    assert {:ok, %{until: renewed}} = Runner.renew_watch(watch(client, far()))
    assert DateTime.compare(renewed, DateTime.utc_now()) == :gt

    {:ok, _} =
      Arca.Execution.record_end(
        attempt.ctx,
        attempt.execution_id,
        "completed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        attempt.attempt
      )

    assert {:ok, %{} = renewals} = HostClient.renew(client, [client.attempt])
    assert renewals[client.attempt] == :lost
    assert :lapsed = Runner.renew_watch(watch(client, far()))
  end

  test "a cancel asked of the attempt reaches the watch at its next tick", %{client: client} do
    {:ok, 1} = Arca.ExecutionAttempts.request_cancel(client.athanor_id, client.execution_id)
    assert :cancelled = Runner.renew_watch(watch(client, far()))
  end

  test "a renewal presented by a runner that does not hold the attempt is refused, not tolerated",
       %{client: client} do
    assert :lapsed = Runner.renew_watch(watch(%{client | runner: "runner_other"}, far()))
    assert :lapsed = Runner.renew_watch(watch(%{client | fence: client.fence + 1}, far()))
  end

  @tag :capture_log
  # An outage, simulated: the attempts table is gone.
  test "a store that cannot answer is tolerated only while the lease last held holds", %{
    client: client
  } do
    Arca.Repo.query!("DROP TABLE execution_attempts")

    assert {:error, :unavailable} = HostClient.renew(client, [client.attempt])

    now = DateTime.utc_now()
    inside = watch(client, DateTime.add(now, 60, :second))
    assert {:ok, ^inside} = Runner.renew_watch(inside, now)

    past = watch(client, DateTime.add(now, -1, :second))
    assert :lapsed = Runner.renew_watch(past, now)
  end
end
