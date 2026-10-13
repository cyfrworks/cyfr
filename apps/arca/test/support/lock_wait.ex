# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.LockWait do
  @moduledoc """
  The one wait for a PostgreSQL backend to block on a lock: a test that
  holds a lock on one connection and starts a statement on another waits
  here until the second is seen waiting, on an observable event, rather
  than for a fixed time.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @poll_ms 20

  @doc """
  Answer `:ok` once the backend `backend_pid` (`pg_backend_pid()` on the
  waiting connection) waits on a lock (`wait_event_type = 'Lock'`) in a
  statement whose text contains every one of `fragments`.

  It polls `pg_stat_activity` every #{@poll_ms} ms on a connection outside
  the sandbox. At `opts[:timeout_ms]` (default 5_000) it fails the test,
  naming the backend, the fragments, the wait type and event, and the
  query it last saw. Only PostgreSQL waits this way: on SQLite it raises
  `ArgumentError`.
  """
  @spec await_lock_wait!(pos_integer(), [String.t()], keyword()) :: :ok
  def await_lock_wait!(backend_pid, fragments \\ [], opts \\ [])
      when is_integer(backend_pid) and is_list(fragments) and is_list(opts) do
    unless Arca.Test.Adapter.postgres?() do
      raise ArgumentError, "only PostgreSQL waits on a lock this way; this build runs on SQLite"
    end

    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 5_000)
    poll(backend_pid, fragments, deadline)
  end

  defp poll(backend_pid, fragments, deadline) do
    activity = activity(backend_pid)

    cond do
      waiting?(activity, fragments) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {type, event, query} = activity || {nil, nil, nil}

        flunk("""
        backend #{backend_pid} never waited on a lock in a statement containing #{inspect(fragments)}
        last seen: wait_event_type=#{inspect(type)} wait_event=#{inspect(event)}
        query: #{inspect(query)}
        """)

      true ->
        Process.sleep(@poll_ms)
        poll(backend_pid, fragments, deadline)
    end
  end

  defp activity(backend_pid) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fn ->
      case Arca.Repo.query!(
             "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
             [backend_pid]
           ) do
        %{rows: [[type, event, query]]} -> {type, event, query}
        %{rows: []} -> nil
      end
    end)
  end

  defp waiting?({"Lock", _event, query}, fragments) when is_binary(query),
    do: Enum.all?(fragments, &String.contains?(query, &1))

  defp waiting?(_activity, _fragments), do: false
end
