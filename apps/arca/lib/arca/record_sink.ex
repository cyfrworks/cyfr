# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RecordSink do
  @moduledoc """
  The write-behind for the hot path's bookkeeping rows.

  Batches bookkeeping writes every 250 ms or 200 items in one transaction:
  allowed policy checks, MCP log completions and vault last-used timestamps.
  Denials and a transport's or a chain's request starts remain synchronous;
  their completion updates the row that exists. An in-process call's start
  rides here too, with a close that carries the whole row: whichever lands
  first, and whether the start was shed, one complete row results.

  `flush/0` drains synchronously (the retention scheduler runs it before a
  sweep; tests use it for ordering); `terminate/2` drains the buffered
  items — casts still in the mailbox at shutdown are lost, which is the
  write-behind's honest cost. With `config :arca, record_sink_inline:
  true` (the test env) every enqueue writes at once in the caller — the
  sandbox never sees another process's writes.

  ## Where it starts

  Directly after `Arca.Repo` in the supervision tree, and that order is a
  data-integrity constraint rather than a convenience: a supervisor stops
  its children in reverse start order, so starting after the repo is what
  makes the sink stop **before** it. The buffered rows `terminate/2`
  drains are written through a repo that is still up; started before the
  repo, the same drain would meet a closed pool and every row held at
  shutdown would be lost silently. Anything that starts later and
  enqueues on its way down (the retention scheduler, the MCP request log)
  is likewise still above the sink when it flushes.
  """

  use GenServer

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

  @flush_ms 250
  @batch 200

  # The buffer this process holds is bounded by @batch — every 200th enqueue
  # drains before returning. Its MAILBOX is not: a drain runs inside
  # `handle_cast/2`, so while the database is slow (a SQLite `busy_timeout`,
  # a Postgres failover) casts keep arriving and queue up behind it, and
  # nothing in a fire-and-forget path ever pushes back. Under sustained
  # request volume that grows until the node runs out of memory — and it is
  # bookkeeping that would take the node down, not the work itself.
  #
  # So the sink sheds instead. A dropped row is a missing audit line, which
  # is a real cost and is why the ceiling is high enough that only a genuine
  # stall reaches it; losing the node loses every subsequent row anyway.
  @max_queue 10_000

  @type item ::
          {:policy_log, map()}
          | {:mcp_log_update, Cyfr.Actor.t(), String.t(), map()}
          | {:mcp_log_started, map()}
          | {:mcp_log_close, map(), map()}
          | {:vault_touch, String.t(), String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue one row write. Never raises; never blocks on the database."
  @spec enqueue(item()) :: :ok
  def enqueue(item) do
    if inline?() do
      write([item])
      :ok
    else
      case Process.whereis(__MODULE__) do
        nil ->
          # Not started (a bare script, an early boot): write now rather than
          # lose the row.
          write([item])
          :ok

        pid ->
          if backlogged?(pid), do: shed(item), else: GenServer.cast(pid, {:enqueue, item})
          :ok
      end
    end
  end

  defp backlogged?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len > @max_queue
      nil -> false
    end
  end

  # Loud in telemetry, quiet in the log: a stall drops many rows, and a line
  # each would be its own flood. Operators watch the counter.
  defp shed(item) do
    :telemetry.execute([:cyfr, :record_sink, :dropped], %{count: 1}, %{kind: elem(item, 0)})
    :ok
  end

  @doc "Write everything queued so far, synchronously."
  @spec flush() :: :ok
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, 30_000)
    end
  end

  defp inline?, do: Application.get_env(:arca, :record_sink_inline, false)

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{items: [], count: 0, timer: nil}}
  end

  @impl true
  def handle_cast({:enqueue, item}, state) do
    state = %{state | items: [item | state.items], count: state.count + 1}

    cond do
      state.count >= @batch ->
        {:noreply, drain(state)}

      state.timer == nil ->
        {:noreply, %{state | timer: Process.send_after(self(), :tick, @flush_ms)}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, drain(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, drain(%{state | timer: nil})}

  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    drain(state)
    :ok
  end

  defp drain(%{items: []} = state), do: cancel_timer(state)

  defp drain(state) do
    state.items |> Enum.reverse() |> write()
    cancel_timer(%{state | items: [], count: 0})
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  @doc false
  def write([]), do: :ok

  def write(items) when is_list(items) do
    grouped = Enum.group_by(items, &elem(&1, 0))

    Arca.Repo.transaction(fn ->
      write_policy_logs(Map.get(grouped, :policy_log, []))
      write_mcp_starts(Map.get(grouped, :mcp_log_started, []))
      write_mcp_closes(Map.get(grouped, :mcp_log_close, []))
      write_mcp_updates(Map.get(grouped, :mcp_log_update, []))
      write_vault_touches(Map.get(grouped, :vault_touch, []))
    end)
    |> case do
      {:ok, _} ->
        :ok

      # A rescued write error can still abort a Postgres transaction.
      # Retry each row separately after a batch rollback and count
      # persistent failures as shed records.
      {:error, reason} ->
        Logger.error("[Arca.RecordSink] batch rolled back: #{inspect(reason)}")

        if length(items) > 1 do
          Enum.each(items, &write_single/1)
        else
          Enum.each(items, &shed/1)
        end

        :ok
    end
  rescue
    # Database errors only: bookkeeping is best-effort during an outage,
    # but a structurally-bad queued item is a bug and must crash loudly —
    # never be dropped twice with :ok.
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.RecordSink] batch write failed: #{Exception.message(e)}")

      # One bad row must not take the batch with it: write the rest
      # singly. A lone row that raised is already its own retry, so it is
      # shed — counted, like the rollback path, rather than dropped
      # silently.
      if length(items) > 1,
        do: Enum.each(items, &write_single/1),
        else: Enum.each(items, &shed/1)

      :ok
  end

  defp write_single(item) do
    write([item])
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.RecordSink] row write failed: #{Exception.message(e)}")
  end

  # Every row still passes the schema's changeset — a batch bypasses
  # `Repo.insert/1`, not validation.
  defp write_policy_logs([]), do: :ok

  # arca:unscoped-ok each batched row passed PolicyLog's changeset, athanor required, before enqueue.
  defp write_policy_logs(items) do
    rows =
      items
      |> Enum.flat_map(fn {:policy_log, attrs} ->
        case Arca.Schemas.PolicyLog.create_changeset(attrs) do
          %{valid?: true} = changeset ->
            [
              Ecto.Changeset.apply_changes(changeset)
              |> Map.from_struct()
              |> Map.drop([:__meta__])
            ]

          changeset ->
            Logger.warning(
              "[Arca.RecordSink] dropping invalid policy log: #{inspect(changeset.errors)}"
            )

            []
        end
      end)

    if rows != [], do: Arca.Repo.insert_all(Arca.Schemas.PolicyLog, rows)
    :ok
  end

  # A start inserts only where no row exists, a close writes the whole row
  # and replaces the fields it closes: order between the two, within a
  # batch or across batches, changes nothing.
  defp write_mcp_starts(items) do
    Enum.each(items, fn {:mcp_log_started, row} ->
      case Arca.McpLog.record_started(row) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Arca.RecordSink] mcp log start failed: #{inspect(reason)}")
      end
    end)
  end

  defp write_mcp_closes(items) do
    Enum.each(items, fn {:mcp_log_close, row, close} ->
      case Arca.McpLog.record_close(row, close) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Arca.RecordSink] mcp log close failed: #{inspect(reason)}")
      end
    end)
  end

  defp write_mcp_updates([]), do: :ok

  defp write_mcp_updates(items) do
    Enum.each(items, fn {:mcp_log_update, actor, call_id, attrs} ->
      case Arca.McpLog.record_update(actor, call_id, attrs) do
        {:ok, _} ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Arca.RecordSink] mcp log update failed: #{inspect(reason)}")
      end
    end)
  end

  # One update per entry however many times it was read in the window.
  defp write_vault_touches([]), do: :ok

  defp write_vault_touches(items) do
    now = DateTime.utc_now()

    items
    |> Enum.map(fn {:vault_touch, athanor_id, id} -> {athanor_id, id} end)
    |> Enum.uniq()
    |> Enum.each(fn {athanor_id, id} ->
      Arca.Repo.update_all(
        from(v in Arca.Schemas.VaultEntry, where: v.id == ^id and v.athanor_id == ^athanor_id),
        set: [last_used_at: now]
      )
    end)
  end
end
