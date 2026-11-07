# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.LockWait do
  @moduledoc """
  The waits on a lock another holds, on an observable event rather than
  for a fixed time: a PostgreSQL backend seen blocking on a lock
  (`await_lock_wait!/3`), and a unit's node-local lock seen free after
  its holder died (`await_unit_lock_free!/3`).
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @poll_ms 20

  @doc """
  Answer `:ok` once the backend `backend_pid` (`pg_backend_pid()` on the
  waiting connection) waits on a lock (`wait_event_type = 'Lock'`) in a
  statement whose text contains every one of `fragments`, and, when
  `opts[:event]` is given, on that lock event (`wait_event`).

  The statement is the client's own: a lock a trigger waits on, such as
  a `pg_advisory_lock` a test gate takes, shows as the outer `INSERT` or
  `UPDATE` that fired it. So a wait at such a gate names the outer
  statement's fragments and `event: "advisory"`, which an earlier row
  or table wait in the same statement does not satisfy.

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
    poll(backend_pid, fragments, Keyword.get(opts, :event), deadline)
  end

  @doc """
  Answer `:ok` once no process holds `unit`'s node-local lock, the half
  of `Arca.Overlay`'s fence a publication, repair or removal holds on
  this node, so that the next take of the unit is answered by its row
  alone.

  A test that kills a writer inside its publication waits here before
  its next step. `:global` releases a dead holder's lock when the name
  server's own monitor of the holder fires, which can come after the
  test's `:DOWN`, and until then a take of the unit answers
  `{:error, :stale_writer}` at once. The probe takes the lock under the
  name `Arca.Overlay` gives it and gives it straight back. At
  `timeout_ms` it fails the test, naming the unit.
  """
  @spec await_unit_lock_free!(Prima.Actor.t(), Arca.Storage.path(), non_neg_integer()) :: :ok
  def await_unit_lock_free!(%Prima.Actor{athanor_id: athanor}, unit, timeout_ms \\ 5_000)
      when is_list(unit) do
    id = {{Arca.Overlay, athanor, unit}, self()}

    Prima.Test.Wait.wait_until(
      fn -> :global.set_lock(id, [node()], 0) and :global.del_lock(id, [node()]) end,
      timeout_ms,
      "the node-local lock on #{Enum.join(unit, "/")} to be free"
    )
  end

  defp poll(backend_pid, fragments, expected, deadline) do
    activity = activity(backend_pid)

    cond do
      waiting?(activity, fragments, expected) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {type, event, query} = activity || {nil, nil, nil}

        flunk("""
        backend #{backend_pid} never waited on a lock#{on_event(expected)} in a statement containing #{inspect(fragments)}
        last seen: wait_event_type=#{inspect(type)} wait_event=#{inspect(event)}
        query: #{inspect(query)}
        """)

      true ->
        Process.sleep(@poll_ms)
        poll(backend_pid, fragments, expected, deadline)
    end
  end

  defp on_event(nil), do: ""
  defp on_event(expected), do: " (wait_event=#{inspect(expected)})"

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

  defp waiting?({"Lock", event, query}, fragments, expected) when is_binary(query),
    do: expected in [nil, event] and Enum.all?(fragments, &String.contains?(query, &1))

  defp waiting?(_activity, _fragments, _expected), do: false
end
