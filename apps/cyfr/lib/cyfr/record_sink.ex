# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RecordSink do
  @moduledoc """
  The write-behind for the hot path's bookkeeping rows.

  Every tool call and every allowed policy check used to cost its own
  round trip (and, on SQLite, its own fsync) in the request's process.
  Now the request enqueues and moves on; this process writes the batch —
  every 250 ms or every 200 items, whichever comes first — inside one
  transaction. What goes through here is *bookkeeping*: an allowed
  policy-log line, the completion of an MCP log row that was started
  synchronously, a vault entry's `last_used_at`. Denials and starts stay
  synchronous — a denial must be on disk before the refusal returns, and a
  started row must exist before its completion is queued.

  `flush/0` drains synchronously (the retention scheduler and tests use
  it); `terminate/2` flushes what is left. With `config :cyfr,
  record_sink_inline: true` (the test env) every enqueue writes at once in
  the caller — the sandbox never sees another process's writes.
  """

  use GenServer

  require Logger
  import Ecto.Query

  @flush_ms 250
  @batch 200

  @type item ::
          {:policy_log, map()}
          | {:mcp_log_update, Sanctum.Context.t(), String.t(), map()}
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
          GenServer.cast(pid, {:enqueue, item})
      end
    end
  end

  @doc "Write everything queued so far, synchronously."
  @spec flush() :: :ok
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, 30_000)
    end
  end

  defp inline?, do: Application.get_env(:cyfr, :record_sink_inline, false)

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
  def handle_info(_msg, state), do: {:noreply, state}

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
      write_mcp_updates(Map.get(grouped, :mcp_log_update, []))
      write_vault_touches(Map.get(grouped, :vault_touch, []))
    end)

    :ok
  rescue
    e ->
      Logger.error("[Cyfr.RecordSink] batch write failed: #{Exception.message(e)}")

      # One bad row must not take the batch with it: write the rest singly.
      if length(items) > 1, do: Enum.each(items, &write_single/1)
      :ok
  end

  defp write_single(item) do
    write([item])
  rescue
    e -> Logger.error("[Cyfr.RecordSink] row write failed: #{Exception.message(e)}")
  end

  # Every row still passes the schema's changeset — a batch bypasses
  # `Repo.insert/1`, not validation.
  defp write_policy_logs([]), do: :ok

  defp write_policy_logs(items) do
    rows =
      items
      |> Enum.flat_map(fn {:policy_log, attrs} ->
        case Arca.PolicyLog.create_changeset(attrs) do
          %{valid?: true} = changeset ->
            [
              Ecto.Changeset.apply_changes(changeset)
              |> Map.from_struct()
              |> Map.drop([:__meta__])
            ]

          changeset ->
            Logger.warning(
              "[Cyfr.RecordSink] dropping invalid policy log: #{inspect(changeset.errors)}"
            )

            []
        end
      end)

    if rows != [], do: Arca.Repo.insert_all(Arca.PolicyLog, rows)
    :ok
  end

  defp write_mcp_updates([]), do: :ok

  defp write_mcp_updates(items) do
    Enum.each(items, fn {:mcp_log_update, ctx, call_id, attrs} ->
      case Arca.McpLog.record_update(ctx, call_id, attrs) do
        {:ok, _} ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Cyfr.RecordSink] mcp log update failed: #{inspect(reason)}")
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
