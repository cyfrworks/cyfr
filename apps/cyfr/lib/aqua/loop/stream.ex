# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Stream do
  @moduledoc """
  A chat step's answer as it streams: the visible text a model catalyst
  emits while its `chat` runs, forwarded to the thread's viewers, and what a
  viewer keeps of it.

  **Forwarding.** `open/3` subscribes a forwarder to the catalyst's
  execution before the call starts; each `text.delta` the execution streams
  is announced on the thread as `{:delta, delta}`:

    * `turn_id` — the soul's turn; `generation` — that turn's generation
      (`generation/1`), which changes whenever the turn is taken from its
      holder;
    * `source` — the turn that streams it (the soul's, or a clone's) and
      `role` — the clone's role, nil for the soul;
    * `step_id`, and `ordinal` — the step's place among its source's model
      steps, so a retry's step outranks the one it replaced;
    * `seq` — the event's `{durable, n}` position; `text`.

  A delta at or before the last one forwarded is dropped, and a forwarder
  whose loop is gone forwards nothing more. Nothing else a catalyst streams
  is forwarded: tool-call fragments, usage and stop reach the thread as the
  rows the whole response writes. `close/1` returns once every event the
  execution published before it was forwarded; a forwarder never stops the
  turn. The loop announces `{:turn_generation, turn_id, generation}` before
  its first model step.

  **Keeping.** A viewer holds a `t()` for the running turn: `new/1` at the
  generation announced, `add/2` for each delta, `landed/2` for each row,
  `texts/1` to show. It keeps one answer per source and never lets a stale
  delta in: one of another generation, one older than its source's current
  step, and one for a step whose text row already landed are all dropped.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @subscribe_timeout_ms 5_000
  @close_timeout_ms 5_000

  defstruct generation: nil, entries: %{}, landed: MapSet.new()

  @typedoc "What a viewer keeps of the running turn's streamed answers."
  @type t :: %__MODULE__{
          generation: String.t() | nil,
          entries: %{String.t() => entry()},
          landed: MapSet.t(String.t())
        }

  @typep entry :: %{
           step_id: String.t(),
           ordinal: non_neg_integer(),
           role: String.t() | nil,
           seq: {non_neg_integer(), non_neg_integer()},
           text: String.t(),
           began: integer()
         }

  @type attrs :: %{
          thread_id: String.t(),
          turn_id: String.t(),
          generation: String.t(),
          source: String.t(),
          step_id: String.t(),
          ordinal: non_neg_integer(),
          role: String.t() | nil
        }

  @doc """
  A turn's generation as deltas carry it: derived from the turn's fence, so
  it changes whenever a host transition takes the turn from its holder, and
  names no fence.
  """
  @spec generation(Tape.turn()) :: String.t()
  def generation(turn), do: turn.fence |> Cyfr.Digest.sha256_hex() |> binary_part(0, 16)

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

  @doc "Nothing kept yet, for the generation named (nil until one is announced)."
  @spec new(String.t() | nil) :: t()
  def new(generation \\ nil), do: %__MODULE__{generation: generation}

  @doc """
  One delta kept, or dropped as stale: appended to its step's text when it
  is newer than the last delta there; a source's later step replaces its
  earlier one, which ended without a text row.
  """
  @spec add(t(), map()) :: t()
  def add(%__MODULE__{generation: generation} = kept, %{generation: generation} = delta)
      when is_binary(generation) do
    %{source: source, step_id: step_id, ordinal: ordinal, seq: seq, text: text} = delta

    case {MapSet.member?(kept.landed, step_id), Map.fetch(kept.entries, source)} do
      {true, _} ->
        kept

      {false, {:ok, %{step_id: ^step_id, seq: last} = entry}} when seq > last ->
        put_entry(kept, source, %{entry | seq: seq, text: entry.text <> text})

      {false, {:ok, %{ordinal: current}}} when ordinal <= current ->
        kept

      {false, _none_or_earlier} ->
        put_entry(kept, source, %{
          step_id: step_id,
          ordinal: ordinal,
          role: Map.get(delta, :role),
          seq: seq,
          text: text,
          began: System.unique_integer([:monotonic])
        })
    end
  end

  def add(%__MODULE__{} = kept, _stale), do: kept

  @doc "What is kept once `row` landed: a step's text row replaces the answer that streamed for it."
  @spec landed(t(), Arca.Schemas.Message.t()) :: t()
  def landed(%__MODULE__{} = kept, %{kind: "text"} = row) do
    case Tape.payload(row)["step_id"] do
      step_id when is_binary(step_id) ->
        %{
          kept
          | landed: MapSet.put(kept.landed, step_id),
            entries: Map.reject(kept.entries, fn {_source, entry} -> entry.step_id == step_id end)
        }

      _ ->
        kept
    end
  end

  def landed(%__MODULE__{} = kept, _row), do: kept

  @doc "The answers streaming now, in the order they began, as `%{step_id, role, text}`."
  @spec texts(t()) :: [%{step_id: String.t(), role: String.t() | nil, text: String.t()}]
  def texts(%__MODULE__{entries: entries}) do
    entries
    |> Map.values()
    |> Enum.sort_by(& &1.began)
    |> Enum.map(&Map.take(&1, [:step_id, :role, :text]))
  end

  defp put_entry(kept, source, entry), do: %{kept | entries: Map.put(kept.entries, source, entry)}

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
    attrs
    |> Map.take([:turn_id, :generation, :source, :step_id, :ordinal, :role])
    |> Map.merge(%{seq: seq, text: text})
  end
end
