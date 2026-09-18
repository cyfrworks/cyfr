# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.LeaseWatchTest do
  # The runner's lease watch renews through its attempt's `renew` host
  # call. A renewal CYFR refuses stops the runner on the first answer; a
  # renewal CYFR cannot answer, or that does not arrive, is tolerated only
  # inside the lease the attempt last held.
  use ExUnit.Case, async: true

  alias Opus.Attempt
  alias Opus.Test.ScriptedHost

  setup do
    host = ScriptedHost.start!()
    {:ok, host: host, client: ScriptedHost.attempt!(host).client}
  end

  defp watch(client, until), do: %{client: client, until: until}

  defp far, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  test "a renewal pushes the watch out to the lease CYFR answered", %{host: host, client: client} do
    until = System.system_time(:millisecond) + 120_000
    ScriptedHost.script(host, "renew", {:ok, %{client.attempt => %{"lease_until" => until}}})

    assert {:ok, %{until: renewed}} = Attempt.renew_watch(watch(client, far()))
    assert DateTime.to_unix(renewed, :millisecond) == until
    assert [%{args: %{"attempts" => [attempt]}}] = ScriptedHost.requests(host, "renew")
    assert attempt == client.attempt
  end

  test "a renewal CYFR refuses lapses the watch at once, inside the lease last held", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "renew", {:ok, %{client.attempt => "lost"}})
    assert :lapsed = Attempt.renew_watch(watch(client, far()))

    ScriptedHost.script(host, "renew", {:error, :lost})
    assert :lapsed = Attempt.renew_watch(watch(client, far()))

    # An answer naming no lease for this attempt is a refusal too.
    ScriptedHost.script(host, "renew", {:ok, %{}})
    assert :lapsed = Attempt.renew_watch(watch(client, far()))
  end

  test "a store that cannot answer is tolerated only while the lease last held holds", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "renew", {:error, :unavailable})

    now = DateTime.utc_now()
    inside = watch(client, DateTime.add(now, 60, :second))
    assert {:ok, ^inside} = Attempt.renew_watch(inside, now)

    past = watch(client, DateTime.add(now, -1, :second))
    assert :lapsed = Attempt.renew_watch(past, now)
  end

  test "a host that does not answer lapses the watch, whatever the lease last held", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "renew", :drop)
    assert :lapsed = Attempt.renew_watch(watch(client, far()))
    assert length(ScriptedHost.requests(host, "renew")) == 2
  end
end
