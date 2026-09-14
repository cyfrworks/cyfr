# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Stream do
  @moduledoc """
  A chat step's answer as it streams: the visible text a model catalyst
  emits while its `chat` runs, forwarded to the thread's viewers.

  `open/3` subscribes a forwarder to the catalyst's execution before the
  call starts; each `text.delta` the execution streams is announced on
  the thread as `{:delta, %{turn_id, step_id, seq, text, role}}` — `seq`
  the event's `{durable, n}` position, a delta at or before the last one
  forwarded dropped, `turn_id` the soul's turn, `role` the clone's role
  or nil for the soul. Nothing
  else a catalyst streams is forwarded: tool-call fragments, usage and
  stop reach the thread as the rows the whole response writes.

  `close/1` returns once every event the execution published before it
  was forwarded. A forwarder never stops the turn: one that dies takes
  only its deltas with it.

  A viewer keeps the partial answers with `add/2` and `landed/2`: one
  entry per streaming step, in the order they began, until the step's
  text row lands.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @subscribe_timeout_ms 5_000
  @close_timeout_ms 5_000

  @typedoc "A streaming step's text so far, and the last delta that grew it."
  @type partial :: %{
          step_id: String.t(),
          role: String.t() | nil,
          seq: {non_neg_integer(), non_neg_integer()},
          text: String.t()
        }

  @type attrs :: %{
          thread_id: String.t(),
          turn_id: String.t(),
          step_id: String.t(),
          role: String.t() | nil
        }

  @doc "Start forwarding the text `execution_id` streams, subscribed before it answers."
  @spec open(Context.t(), String.t(), attrs()) :: pid() | nil
  def open(%Context{} = ctx, execution_id, attrs) do
    owner = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_monitor = Process.monitor(owner)

        case Cyfr.Execution.subscribe_events(execution_id, ctx) do
          :ok ->
            send(owner, {ref, :subscribed})
            forward(ctx, attrs, owner_monitor, {-1, -1})

          {:error, _} ->
            send(owner, {ref, :unsubscribed})
        end
      end)

    receive do
      {^ref, :subscribed} ->
        Process.demonitor(monitor, [:flush])
        pid

      {^ref, :unsubscribed} ->
        Process.demonitor(monitor, [:flush])
        nil

      {:DOWN, ^monitor, :process, _, _} ->
        nil
    after
      @subscribe_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        nil
    end
  end

  @doc "Stop forwarding, after every event already published was forwarded."
  @spec close(pid() | nil) :: :ok
  def close(nil), do: :ok

  def close(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)
    send(pid, {:close, self(), monitor})

    receive do
      {:closed, ^monitor} -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      @close_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
    end

    :ok
  end

  @doc """
  The partial answers with one delta added: appended to its step's text
  when it is newer than the last delta there, dropped when it is not. A
  step seen for the first time starts a new entry and supersedes any
  earlier entry of the same role, whose step ended without a text row.
  """
  @spec add([partial()], map()) :: [partial()]
  def add(partials, %{step_id: step_id, seq: seq, text: text, role: role}) do
    case Enum.find_index(partials, &(&1.step_id == step_id)) do
      nil ->
        Enum.reject(partials, &(&1.role == role)) ++
          [%{step_id: step_id, role: role, seq: seq, text: text}]

      index ->
        List.update_at(partials, index, fn
          %{seq: last} = partial when seq > last ->
            %{partial | seq: seq, text: partial.text <> text}

          partial ->
            partial
        end)
    end
  end

  @doc "The partial answers once `row` landed: without its step's entry when it is a step's text row."
  @spec landed([partial()], Arca.Schemas.Message.t()) :: [partial()]
  def landed([_ | _] = partials, %{kind: "text"} = row) do
    step_id = Tape.payload(row)["step_id"]
    Enum.reject(partials, &(&1.step_id == step_id))
  end

  def landed(partials, _row), do: partials

  defp forward(ctx, attrs, owner_monitor, last) do
    receive do
      {:execution_event, %{type: "emit", durable: durable, delta: n, data: data}}
      when {durable, n} > last ->
        case data do
          %{"type" => "text.delta", "text" => text} when is_binary(text) and text != "" ->
            Tape.announce(ctx, attrs.thread_id, {:delta, delta(attrs, {durable, n}, text)})

          _ ->
            :ok
        end

        forward(ctx, attrs, owner_monitor, {durable, n})

      {:execution_event, _event} ->
        forward(ctx, attrs, owner_monitor, last)

      {:close, from, ref} ->
        send(from, {:closed, ref})

      {:DOWN, ^owner_monitor, :process, _, _} ->
        :ok
    end
  end

  defp delta(attrs, seq, text) do
    %{turn_id: attrs.turn_id, step_id: attrs.step_id, seq: seq, text: text, role: attrs.role}
  end
end
