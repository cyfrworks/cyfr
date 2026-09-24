# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Emit do
  @moduledoc """
  The one path a guest's event takes to an execution's event stream. An
  emitter is the state its execution's `Crucible.Attempt` holds: a
  formula's `cyfr:formula/invoke.emit` and a catalyst's
  `cyfr:emit/events.emit` both answer through `emit/3` there.

  An event is, in order: at most the node's `max_request_size` of JSON;
  within its root execution's emit budget (3000 a minute shared by every
  execution under the root, separate from the consented invocation rate
  limit, refused when it cannot be metered); a JSON object; attributed by
  the authority's emit transition, so a consumer can always tell a guest's
  event from the host's; masked with the credentials the caller passes (the
  attempt's masking set); and pushed with `Crucible.Events.push/4`,
  numbered under the stream's last durable event. A refusal is answered to
  the guest and never stops the run.

  ## Where the emit budget is counted

  In this member's memory (`Prima.RateLimiter`), and that is the right
  place for it. A root execution runs on exactly one member — every
  execution under it reports to the attempt that member holds — so its
  events are counted where they are produced and there is no second
  count anywhere to disagree with. It bounds one member's own work,
  which makes it advisory: nothing multiplies across the cell, and a
  member's restart ends the root whose budget it forgot. A root recovered
  on another member starts a fresh budget, which is looser and grants
  nothing.

  That is a different question from the consented invocation rate, which
  two members really can admit twice and which therefore lives in a row
  they share (`Arca.RateWindows`, through `Crucible.Rates`). This
  budget is a flood guard on the delta path — up to fifty events a second
  per root — and a database round trip per delta would buy a guarantee
  the topology already gives.

  Streamed text is masked across event boundaries. Each logical stream —
  the answer's `text.delta` text, and each index's `tool_call.delta`
  arguments — holds back only the tail that could begin a credential's
  masked form (`Prima.SecretMasker.pending_prefix/2`), so a credential split
  over two deltas is masked whole whatever events arrive between them, and
  text that ends in no such prefix goes out at once. A stream's held text
  goes out when that stream ends: a call's arguments ahead of its own
  `tool_call.end`, and everything still held ahead of `stop` or `error`.
  `flush/2` sends whatever is still held, masked, when the attempt closes.
  """

  require Logger

  alias Prima.Authority
  alias Crucible.{Events, StepSpans, Telemetry}
  alias Prima.SecretMasker

  @budget_max 3000
  @budget_window_ms :timer.minutes(1)

  # The held text is guest text not yet masked whole.
  @derive {Inspect, except: [:held]}
  @enforce_keys [:stream_id, :budget_id, :ctx, :authority]
  defstruct [:stream_id, :budget_id, :ctx, :authority, :step_spans, held: %{}]

  @type t :: %__MODULE__{
          stream_id: String.t(),
          budget_id: String.t(),
          ctx: Sanctum.Context.t(),
          authority: Authority.t(),
          step_spans: StepSpans.t() | nil,
          held: map()
        }

  @doc """
  An emitter for the stream of `stream_id`. `opts`: `:ctx` and `:authority`
  (required); `:budget_id`, the root execution whose emit budget the events
  count against (default `stream_id`); `:step_spans`, the execution's
  `Crucible.StepSpans` clock, marked with each event pushed.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(stream_id, opts) when is_binary(stream_id) do
    %__MODULE__{
      stream_id: stream_id,
      budget_id: Keyword.get(opts, :budget_id, stream_id),
      ctx: Keyword.fetch!(opts, :ctx),
      authority: Keyword.fetch!(opts, :authority),
      step_spans: Keyword.get(opts, :step_spans)
    }
  end

  @doc """
  Emit one event, masked with `secrets`. Answers the guest's JSON —
  `{"ok": true, "sequence": "N.n"}` naming the last event this call
  released, `{"ok": true}` when the event's text is held back whole, or
  `{"error": {"type", "message"}}` — and the emitter with what it now holds.
  """
  @spec emit(t(), String.t(), [String.t()]) :: {String.t(), t()}
  def emit(%__MODULE__{} = emitter, json_event, secrets) when is_binary(json_event) do
    limits = Authority.limits(emitter.authority)

    with :ok <- check_size(json_event, limits.max_request_size),
         :ok <- check_budget(emitter),
         {:ok, event} <- decode(json_event),
         {:allow_emit, attribution} <-
           Authority.Transition.step(emitter.authority, :emit, {:event, event}) do
      origin = origin(attribution)
      {released, held} = release(emitter.held, event, origin, secrets)
      {push(emitter, released), %{emitter | held: held}}
    else
      {:error, :event_too_large} ->
        {encode_error(:resource_limit, "emit event exceeds the node's request size limit"),
         emitter}

      {:error, :emit_rate_limited} ->
        {encode_error(:resource_limit, "emit rate limit exceeded for this run"), emitter}

      {:error, :invalid_event} ->
        {encode_error(:invalid_request, "emit event must be a JSON object"), emitter}

      refused ->
        {encode_error(:invalid_request, "emit refused: #{render(refused)}"), emitter}
    end
  end

  @doc """
  Send every tail the emitter still holds, masked with `secrets`, in stream
  order: the answer's text, then each call's arguments by index. Answers
  the emitter holding nothing.
  """
  @spec flush(t(), [String.t()]) :: t()
  def flush(%__MODULE__{} = emitter, secrets) do
    _answer = push(emitter, tails(emitter.held, secrets))
    %{emitter | held: %{}}
  end

  defp push(emitter, released) do
    Enum.reduce_while(released, safe_encode(%{"ok" => true}), fn {data, origin}, _answer ->
      case Events.push(emitter.stream_id, data, emitter.ctx, origin) do
        {:ok, seq} ->
          Telemetry.emit(emitter.stream_id, seq)
          StepSpans.pushed(emitter.step_spans, data)
          {:cont, safe_encode(%{"ok" => true, "sequence" => seq})}

        {:error, :missing_athanor} ->
          {:halt, encode_error(:dispatch_error, "emit event could not be routed")}
      end
    end)
  end

  # What an event releases, given the text held: a delta's masked text less
  # its held tail; the ending of a stream's held tail and then the event;
  # any other event alone, every stream still held. Each released event
  # carries the origin it is pushed under.
  defp release(held, %{"type" => "text.delta", "text" => text} = event, origin, secrets)
       when is_binary(text),
       do: stream(held, :text, event, origin, "text", text, secrets)

  defp release(
         held,
         %{"type" => "tool_call.delta", "index" => index, "arguments" => arguments} = event,
         origin,
         secrets
       )
       when is_integer(index) and is_binary(arguments),
       do: stream(held, {:arguments, index}, event, origin, "arguments", arguments, secrets)

  defp release(held, %{"type" => "tool_call.end", "index" => index} = event, origin, secrets) do
    {ended, held} = Map.split(held, [{:arguments, index}])
    {tails(ended, secrets) ++ [{SecretMasker.mask(event, secrets), origin}], held}
  end

  defp release(held, %{"type" => type} = event, origin, secrets)
       when type in ["stop", "error"] do
    {tails(held, secrets) ++ [{SecretMasker.mask(event, secrets), origin}], %{}}
  end

  defp release(held, event, origin, secrets),
    do: {[{SecretMasker.mask(event, secrets), origin}], held}

  defp stream(held, key, event, origin, field, text, secrets) do
    {template, pending, origin} = Map.get(held, key, {event, "", origin})
    masked = SecretMasker.mask(pending <> text, secrets)
    {out, tail} = hold_back(masked, SecretMasker.pending_prefix(masked, secrets))

    held =
      if tail == "",
        do: Map.delete(held, key),
        else: Map.put(held, key, {template, tail, origin})

    released =
      if out == "",
        do: [],
        else: [{Map.put(SecretMasker.mask(template, secrets), field, out), origin}]

    {released, held}
  end

  defp hold_back(text, hold) do
    kept = byte_size(text) - hold
    {binary_part(text, 0, kept), binary_part(text, kept, hold)}
  end

  # Held tails as the deltas they finish, in stream order: the answer's
  # text, then each call's arguments by index. A tail is masked again with
  # the set as it stands when it goes out, which may have grown since the
  # tail was held.
  defp tails(held, secrets) do
    held
    |> Enum.sort_by(fn
      {:text, _} -> {0, 0}
      {{:arguments, index}, _} -> {1, index}
    end)
    |> Enum.map(fn
      {:text, {template, tail, origin}} ->
        {Map.put(template, "text", tail), origin}

      {{:arguments, _}, {template, tail, origin}} ->
        {Map.put(template, "arguments", tail), origin}
    end)
    |> Enum.map(fn {data, origin} -> {SecretMasker.mask(data, secrets), origin} end)
  end

  defp origin({:attributed, node}), do: [origin: "guest", node: node]
  defp origin(:untrusted), do: [origin: "guest"]

  defp check_size(json_event, max_size) when byte_size(json_event) <= max_size, do: :ok
  defp check_size(_json_event, _max_size), do: {:error, :event_too_large}

  # The root's own budget, counted on this member. A producer whose
  # athanor was never resolved is refused before it is counted, as the
  # event itself would be; a counter that cannot answer denies, because
  # the budget must be enforceable.
  defp check_budget(%__MODULE__{ctx: ctx, budget_id: budget_id}) do
    case ctx.athanor_id do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        spend({:emit, athanor_id, budget_id})

      _unresolved ->
        {:error, :emit_rate_limited}
    end
  end

  defp spend(bucket) do
    case Prima.RateLimiter.check(bucket, @budget_max, @budget_window_ms) do
      :ok -> :ok
      {:deny, _retry_after_s} -> {:error, :emit_rate_limited}
    end
  end

  defp decode(json_event) do
    case Jason.decode(json_event) do
      {:ok, %{} = event} -> {:ok, event}
      _ -> {:error, :invalid_event}
    end
  end

  defp render(reason) do
    case Grimoire.Error.render(reason) do
      nil ->
        Logger.warning("[Crucible.Emit] unrenderable emit refusal: #{inspect(reason)}")
        "the event was refused"

      message ->
        message
    end
  end

  defp safe_encode(data), do: Prima.WitResponse.safe_encode(data)
  defp encode_error(type, message), do: Prima.WitResponse.encode_error(type, message)
end
