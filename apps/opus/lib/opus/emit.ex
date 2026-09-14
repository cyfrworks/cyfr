# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Emit do
  @moduledoc """
  The one path a guest's event takes to an execution's event stream: a
  formula's `cyfr:formula/invoke.emit` and a catalyst's
  `cyfr:emit/events.emit` both answer through `emit/2`.

  An event is, in order: at most the node's `max_request_size` of JSON;
  within its root execution's emit budget (3000 a minute shared by every
  execution under the root, separate from the consented invocation rate
  limit, refused when it cannot be metered); a
  JSON object; attributed by the authority's emit transition, so a
  consumer can always tell a guest's event from the host's; masked of
  every credential the execution was handed (its preloaded vault fields
  and the OAuth tokens dispensed to it so far); and pushed with
  `Opus.ExecutionEventBuffer.push/4`, numbered under the stream's last
  durable event. A refusal is answered to the guest and never stops the
  run.

  Streamed text is masked across event boundaries. Each logical stream —
  the answer's `text.delta` text, and each index's `tool_call.delta`
  arguments — holds back only the tail that could begin a credential's
  masked form (`Cyfr.SecretMasker.pending_prefix/2`), so a credential split
  over two deltas is masked whole whatever events arrive between them, and
  text that ends in no such prefix goes out at once. A
  stream's held text goes out when that stream ends: a call's arguments
  ahead of its own `tool_call.end`, and everything still held ahead of
  `stop` or `error`. An emitter closed before then drops it (the
  execution's output is masked whole when it finalizes).

  An emitter holds that text in a process linked to the one that opens
  it; `close/1` stops it.
  """

  require Logger

  alias Cyfr.Authority
  alias Cyfr.SecretMasker
  alias Opus.{ExecutionEventBuffer, OAuthTokenTracker}

  @budget %{requests: 3000, window: "1m"}

  @enforce_keys [:stream_id, :budget_id, :ctx, :authority, :held]
  defstruct [:stream_id, :budget_id, :ctx, :authority, :held, :tracked_id, secrets: []]

  @type t :: %__MODULE__{
          stream_id: String.t(),
          budget_id: String.t(),
          ctx: Sanctum.Context.t(),
          authority: Authority.t(),
          held: pid(),
          tracked_id: String.t() | nil,
          secrets: [String.t()]
        }

  @doc """
  Open an emitter for the stream of `stream_id`. `opts`: `:ctx` and
  `:authority` (required); `:budget_id`, the root execution whose emit
  budget the events count against (default `stream_id`); `:secrets`, the
  credential values preloaded for the execution; `:tracked_id`, the
  execution whose dispensed OAuth tokens are masked too.
  """
  @spec open(String.t(), keyword()) :: t()
  def open(stream_id, opts) when is_binary(stream_id) do
    held =
      case Agent.start_link(fn -> %{} end) do
        {:ok, pid} -> pid
        {:error, reason} -> raise "emitter could not start: #{inspect(reason)}"
      end

    %__MODULE__{
      stream_id: stream_id,
      budget_id: Keyword.get(opts, :budget_id, stream_id),
      ctx: Keyword.fetch!(opts, :ctx),
      authority: Keyword.fetch!(opts, :authority),
      held: held,
      tracked_id: Keyword.get(opts, :tracked_id),
      secrets: Keyword.get(opts, :secrets, [])
    }
  end

  @doc "Stop the emitter, dropping any text still held."
  @spec close(t()) :: :ok
  def close(%__MODULE__{held: held}) do
    Agent.stop(held, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc "The `cyfr:emit/events@0.1.0` import a catalyst links, answered by `emit/2`."
  @spec imports(t()) :: map()
  def imports(%__MODULE__{} = emitter) do
    %{
      "cyfr:emit/events@0.1.0" => %{
        "emit" => {:fn, fn json_event -> guarded(emitter, json_event) end}
      }
    }
  end

  @doc """
  Emit one event. Answers the guest: `{"ok": true, "sequence": "N.n"}`
  naming the last event this call released, `{"ok": true}` when the
  event's text is held back whole, or `{"error": {"type", "message"}}`.
  """
  @spec emit(t(), String.t()) :: String.t()
  def emit(%__MODULE__{} = emitter, json_event) when is_binary(json_event) do
    limits = Authority.limits(emitter.authority)

    with :ok <- check_size(json_event, limits.max_request_size),
         :ok <- check_budget(emitter),
         {:ok, event} <- decode(json_event),
         {:allow_emit, attribution} <-
           Authority.Transition.step(emitter.authority, :emit, {:event, event}) do
      push(emitter, event, origin(attribution))
    else
      {:error, :event_too_large} ->
        encode_error(:resource_limit, "emit event exceeds the node's request size limit")

      {:error, :emit_rate_limited} ->
        encode_error(:resource_limit, "emit rate limit exceeded for this run")

      {:error, :invalid_event} ->
        encode_error(:invalid_request, "emit event must be a JSON object")

      refused ->
        encode_error(:invalid_request, "emit refused: #{render(refused)}")
    end
  end

  defp guarded(emitter, json_event) do
    emit(emitter, json_event)
  rescue
    exception ->
      Logger.error(
        "[Opus.Emit] #{emitter.stream_id} emit raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      encode_error(:dispatch_error, "The emit call failed.")
  catch
    :exit, reason ->
      Logger.error("[Opus.Emit] #{emitter.stream_id} emit exited: #{inspect(reason)}")
      encode_error(:dispatch_error, "The emit call failed.")
  end

  defp push(emitter, event, origin_opts) do
    secrets = emitter.secrets ++ OAuthTokenTracker.peek(emitter.tracked_id)
    released = Agent.get_and_update(emitter.held, &release(&1, event, secrets))

    Enum.reduce_while(released, safe_encode(%{"ok" => true}), fn data, _answer ->
      case ExecutionEventBuffer.push(emitter.stream_id, data, emitter.ctx, origin_opts) do
        {:ok, seq} ->
          Opus.Telemetry.emit(emitter.stream_id, seq)
          {:cont, safe_encode(%{"ok" => true, "sequence" => seq})}

        {:error, :missing_athanor} ->
          {:halt, encode_error(:dispatch_error, "emit event could not be routed")}
      end
    end)
  end

  # What an event releases, given the text held: a delta's masked text less
  # its held tail; the ending of a stream's held tail and then the event;
  # any other event alone, every stream still held.
  defp release(held, %{"type" => "text.delta", "text" => text} = event, secrets)
       when is_binary(text),
       do: stream(held, :text, event, "text", text, secrets)

  defp release(
         held,
         %{"type" => "tool_call.delta", "index" => index, "arguments" => arguments} = event,
         secrets
       )
       when is_integer(index) and is_binary(arguments),
       do: stream(held, {:arguments, index}, event, "arguments", arguments, secrets)

  defp release(held, %{"type" => "tool_call.end", "index" => index} = event, secrets) do
    {ended, held} = Map.split(held, [{:arguments, index}])
    {tails(ended, secrets) ++ [SecretMasker.mask(event, secrets)], held}
  end

  defp release(held, %{"type" => type} = event, secrets) when type in ["stop", "error"] do
    {tails(held, secrets) ++ [SecretMasker.mask(event, secrets)], %{}}
  end

  defp release(held, event, secrets), do: {[SecretMasker.mask(event, secrets)], held}

  defp stream(held, key, event, field, text, secrets) do
    {template, pending} = Map.get(held, key, {event, ""})
    masked = SecretMasker.mask(pending <> text, secrets)
    {out, tail} = hold_back(masked, SecretMasker.pending_prefix(masked, secrets))
    held = if tail == "", do: Map.delete(held, key), else: Map.put(held, key, {template, tail})

    released =
      if out == "", do: [], else: [Map.put(SecretMasker.mask(template, secrets), field, out)]

    {released, held}
  end

  defp hold_back(text, hold) do
    kept = byte_size(text) - hold
    {binary_part(text, 0, kept), binary_part(text, kept, hold)}
  end

  # Held tails as the deltas they finish, in stream order: the answer's
  # text, then each call's arguments by index.
  defp tails(held, secrets) do
    held
    |> Enum.sort_by(fn
      {:text, _} -> {0, 0}
      {{:arguments, index}, _} -> {1, index}
    end)
    |> Enum.map(fn
      {:text, {template, tail}} -> Map.put(template, "text", tail)
      {{:arguments, _}, {template, tail}} -> Map.put(template, "arguments", tail)
    end)
    |> Enum.map(&SecretMasker.mask(&1, secrets))
  end

  defp origin({:attributed, node}), do: [origin: "guest", node: node]
  defp origin(:untrusted), do: [origin: "guest"]

  defp check_size(json_event, max_size) when byte_size(json_event) <= max_size, do: :ok
  defp check_size(_json_event, _max_size), do: {:error, :event_too_large}

  defp check_budget(%__MODULE__{ctx: ctx, budget_id: budget_id}) do
    case Opus.RateLimiter.check(ctx.athanor_id, "emit:" <> budget_id, %{rate_limit: @budget}) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited, _retry_after} -> {:error, :emit_rate_limited}
      {:error, :missing_tenant} -> {:error, :emit_rate_limited}
    end
  catch
    # An unreachable limiter denies: the budget must be enforceable.
    :exit, _reason -> {:error, :emit_rate_limited}
  end

  defp decode(json_event) do
    case Jason.decode(json_event) do
      {:ok, %{} = event} -> {:ok, event}
      _ -> {:error, :invalid_event}
    end
  end

  defp render(reason) do
    case Cyfr.Ops.Error.render(reason) do
      nil ->
        Logger.warning("[Opus.Emit] unrenderable emit refusal: #{inspect(reason)}")
        "the event was refused"

      message ->
        message
    end
  end

  defp safe_encode(data), do: Cyfr.WitResponse.safe_encode(data)
  defp encode_error(type, message), do: Cyfr.WitResponse.encode_error(type, message)
end
