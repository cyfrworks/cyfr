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

    * `turn_id` — the soul's turn; `fence` — that turn's fence, which rises
      whenever a host transition takes the turn from its holder;
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
  turn.

  The loop announces `{:turn_fence, turn_id, fence}` (`announce_fence/2`)
  before its first model step, and `{:delta_abandoned, marker}`
  (`abandon/2`) for a step that streamed but lands no text row — a failed
  or retried request, or an answer of tool calls alone.

  **Keeping.** A viewer holds a `t()` for the running turn: `advance/2` for
  each fence announced, `add/2` for each delta, `landed/2` for each row,
  `abandoned/2` for each abandoned step, `texts/1` to show. It keeps one
  answer per source and never lets a stale delta in: one under another
  fence, one older than the highest step its source has streamed, and one
  for a step that landed or was abandoned are all dropped.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @subscribe_timeout_ms 5_000
  @close_timeout_ms 5_000

  defstruct fence: nil, entries: %{}, ordinals: %{}, landed: %{}

  @typedoc "What a viewer keeps of the running turn's streamed answers."
  @type t :: %__MODULE__{
          fence: pos_integer() | nil,
          entries: %{String.t() => entry()},
          ordinals: %{String.t() => non_neg_integer()},
          landed: %{String.t() => true}
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
          fence: pos_integer(),
          source: String.t(),
          step_id: String.t(),
          ordinal: non_neg_integer(),
          role: String.t() | nil
        }

  @doc "Announce the fence `turn`'s streamed answers are kept under."
  @spec announce_fence(Context.t(), Tape.turn()) :: :ok
  def announce_fence(%Context{} = ctx, turn),
    do: Tape.announce(ctx, turn.thread_id, {:turn_fence, turn.id, turn.fence})

  @doc "Announce that the step `attrs` names lands no text row: what it streamed is withdrawn."
  @spec abandon(Context.t(), attrs()) :: :ok
  def abandon(%Context{} = ctx, attrs),
    do: Tape.announce(ctx, attrs.thread_id, {:delta_abandoned, marker(attrs)})

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

  @doc "Nothing kept yet, under the fence named (nil until one is announced)."
  @spec new(pos_integer() | nil) :: t()
  def new(fence \\ nil), do: %__MODULE__{fence: fence}

  @doc """
  What is kept once `fence` is announced: a higher fence starts over, the
  same one changes nothing, and a lower one is obsolete and ignored.
  """
  @spec advance(t(), pos_integer()) :: t()
  def advance(%__MODULE__{fence: current} = kept, fence) when is_integer(fence) do
    if is_nil(current) or fence > current, do: new(fence), else: kept
  end

  @doc """
  One delta kept, or dropped as stale: appended to its step's text when it
  is newer than the last delta there; a source's later step replaces its
  earlier one. A source's highest step is remembered after its answer
  leaves, so an earlier step's delayed delta never returns.
  """
  @spec add(t(), map()) :: t()
  def add(%__MODULE__{fence: fence} = kept, %{fence: fence} = delta) when is_integer(fence) do
    %{source: source, step_id: step_id, ordinal: ordinal, seq: seq, text: text} = delta
    highest = Map.get(kept.ordinals, source, -1)

    case Map.fetch(kept.entries, source) do
      _ when ordinal < highest ->
        kept

      _ when is_map_key(kept.landed, step_id) ->
        kept

      {:ok, %{step_id: ^step_id, seq: last} = entry} when seq > last ->
        put_entry(kept, source, %{entry | seq: seq, text: entry.text <> text})

      {:ok, %{step_id: ^step_id}} ->
        kept

      _none_or_earlier ->
        kept
        |> raise_ordinal(source, ordinal)
        |> put_entry(source, %{
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
  @spec landed(t(), Aqua.Tape.row()) :: t()
  def landed(%__MODULE__{} = kept, %{kind: "text"} = row) do
    case Tape.payload(row)["step_id"] do
      step_id when is_binary(step_id) -> settle(kept, step_id)
      _ -> kept
    end
  end

  def landed(%__MODULE__{} = kept, _row), do: kept

  @doc "What is kept once a step of the kept fence is abandoned: its answer is withdrawn."
  @spec abandoned(t(), map()) :: t()
  def abandoned(%__MODULE__{fence: fence} = kept, %{fence: fence} = marker)
      when is_integer(fence) do
    kept
    |> raise_ordinal(marker.source, marker.ordinal)
    |> settle(marker.step_id)
  end

  def abandoned(%__MODULE__{} = kept, _stale), do: kept

  @doc "The answers streaming now, in the order they began, as `%{step_id, role, text}`."
  @spec texts(t()) :: [%{step_id: String.t(), role: String.t() | nil, text: String.t()}]
  def texts(%__MODULE__{entries: entries}) do
    entries
    |> Map.values()
    |> Enum.sort_by(& &1.began)
    |> Enum.map(&Map.take(&1, [:step_id, :role, :text]))
  end

  defp put_entry(kept, source, entry), do: %{kept | entries: Map.put(kept.entries, source, entry)}

  defp raise_ordinal(kept, source, ordinal),
    do: %{kept | ordinals: Map.update(kept.ordinals, source, ordinal, &max(&1, ordinal))}

  defp settle(kept, step_id) do
    %{
      kept
      | landed: Map.put(kept.landed, step_id, true),
        entries: Map.reject(kept.entries, fn {_source, entry} -> entry.step_id == step_id end)
    }
  end

  defp marker(attrs), do: Map.take(attrs, [:turn_id, :fence, :source, :step_id, :ordinal])

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
    |> Map.take([:turn_id, :fence, :source, :step_id, :ordinal, :role])
    |> Map.merge(%{seq: seq, text: text})
  end
end
