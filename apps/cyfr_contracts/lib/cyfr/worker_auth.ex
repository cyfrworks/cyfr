# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerAuth do
  @moduledoc """
  How CYFR and its execution workers authenticate each other, spelled with
  `Cyfr.MacEnvelope`.

  One root secret of 32 bytes (`CYFR_WORKER_KEY`) lives on CYFR only. Every
  key is derived from it:

  | Key | Derived over | Held by | Use |
  |---|---|---|---|
  | `dispatch_key/1` | `cyfr-worker/v1/dispatch` | CYFR and worker services | signs WorkerAPI requests and the worker service's reports |
  | `dispatch_seal_key/1` | `cyfr-worker/v1/dseal` | CYFR and worker services | seals the attempt key a start carries (`seal_attempt_key/2`) |
  | `assign_key/1` | `cyfr-worker/v1/assign` | CYFR only | MACs assignments (`Cyfr.Assignment`) |
  | `attempt_key/2` | `cyfr-worker/v1/attempt`, then the athanor, execution, attempt, fence and generation, one per line | the runner of that attempt | signs and seals its host calls |

  An attempt key is bound to one control-plane generation, so a new
  generation retires every attempt key, and CYFR re-derives it from a host
  call's header without storing anything.

  ## Sealed attempt keys

  CYFR hands a worker service the key of the attempt it starts sealed
  (`seal_attempt_key/2`): `base64url(attempt) <> "." <> sealed`, where
  `attempt` is the JCS of the attempt's five fields and `sealed` is
  `Cyfr.MacEnvelope`'s AES-256-GCM seal of the key under the dispatch seal
  key, its additional data `cyfr-worker/v1/attempt-key` followed by those
  fields one per line. `open_attempt_key/2` answers the attempt and its key
  only when the seal opens as the attempt it names.

  ## Headers

  A host call's header (`host_call_header/3`) is signed with the attempt
  key over the attempt's fields, the runner presenting it, the timestamp
  (Unix milliseconds), a nonce and the body. A WorkerAPI request's header
  (`request_header/3`) and a worker service's report header
  (`report_header/3`) are signed with the dispatch key over the worker
  service's id, the timestamp, a nonce and the body; the two kinds never
  verify as each other.

  ## Verifying

  `verify_host_call/5` answers the authenticated fields or the first
  refusal, in this order:

    1. `:malformed` — the header is not exactly one well-formed host-call
       header;
    2. `:outside_window` — `ts` is more than 30 seconds from `now`, on
       either side;
    3. `:bad_mac` — the MAC is not the attempt key's over the header's
       fields and the body;
    4. `:generation_mismatch` — the header's generation is not the current
       one.

  `verify_request/4` and `verify_report/4` check the first three against
  the dispatch key.

  Replay and staleness beyond that are the caller's, against state this
  module does not hold: a nonce seen before for the same attempt (or, for
  the dispatch kinds, the same worker service) within the window is
  refused on every call that is not idempotent, and a host call's attempt
  row must be current, running, at the header's fence and claimed by the
  header's runner.
  """

  alias Cyfr.MacEnvelope

  @window_ms 30_000

  @attempt_fields [
    athanor_id: :string,
    execution_id: :string,
    attempt: :string,
    fence: :integer,
    generation: :integer
  ]

  @attempt_names Enum.map(@attempt_fields, fn {name, _type} -> Atom.to_string(name) end)
  @attempt_key_label "cyfr-worker/v1/attempt-key"

  @call %MacEnvelope{
    prefix: "cyfr-worker/v1",
    kind: "call",
    fields: @attempt_fields ++ [runner: :string, ts: :integer, nonce: :string]
  }

  @dispatch_fields [worker: :string, ts: :integer, nonce: :string]
  @request %MacEnvelope{prefix: "cyfr-worker/v1", kind: "request", fields: @dispatch_fields}
  @report %MacEnvelope{prefix: "cyfr-worker/v1", kind: "report", fields: @dispatch_fields}

  @typedoc "The attempt an attempt key is bound to."
  @type attempt :: %{
          required(:athanor_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:attempt) => String.t(),
          required(:fence) => pos_integer(),
          required(:generation) => pos_integer(),
          optional(atom()) => term()
        }

  @typedoc "An attempt and the key its runner signs host calls with."
  @type attempt_key :: %{attempt: attempt(), key: binary()}

  @typedoc "A host call's header fields: the attempt's, the presenting runner, `ts` in Unix ms and a nonce."
  @type host_call :: %{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          runner: String.t(),
          ts: non_neg_integer(),
          nonce: String.t()
        }

  @typedoc "A WorkerAPI request's or report's header fields: the worker service, `ts` in Unix ms and a nonce."
  @type dispatch :: %{worker: String.t(), ts: non_neg_integer(), nonce: String.t()}

  @type dispatch_refusal :: :malformed | :outside_window | :bad_mac
  @type call_refusal :: dispatch_refusal() | :generation_mismatch

  @doc "The key WorkerAPI requests and worker service reports are signed with."
  @spec dispatch_key(binary()) :: binary()
  def dispatch_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-worker/v1/dispatch")

  @doc "The key start bodies are sealed with."
  @spec dispatch_seal_key(binary()) :: binary()
  def dispatch_seal_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-worker/v1/dseal")

  @doc "The key assignments are MAC'd with. Only CYFR holds it."
  @spec assign_key(binary()) :: binary()
  def assign_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-worker/v1/assign")

  @doc "The key one attempt, at one fence and generation, signs and seals its host calls with."
  @spec attempt_key(binary(), attempt()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def attempt_key(root, attempt) when byte_size(root) == 32 and is_map(attempt),
    do: MacEnvelope.derive(root, "cyfr-worker/v1/attempt", @attempt_fields, attempt)

  @doc """
  Seal an attempt's key with the dispatch seal key, naming the attempt.
  `iv` is 12 random bytes unless given.
  """
  @spec seal_attempt_key(binary(), attempt_key(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def seal_attempt_key(seal_key, attempt_key, iv \\ :crypto.strong_rand_bytes(12))

  def seal_attempt_key(seal_key, %{attempt: attempt, key: key}, iv)
      when byte_size(seal_key) == 32 and is_map(attempt) and byte_size(key) == 32 and
             byte_size(iv) == 12 do
    with {:ok, sealed} <-
           MacEnvelope.seal(seal_key, @attempt_key_label, @attempt_fields, attempt, key, iv),
         {:ok, named} <- attempt_json(attempt) do
      {:ok, Base.url_encode64(named, padding: false) <> "." <> sealed}
    end
  end

  @doc """
  The attempt and key `seal_attempt_key/2` sealed, opened with the dispatch
  seal key. Anything that does not open as the attempt it names, or whose
  key is not 32 bytes, is `{:error, :unsealable}`.
  """
  @spec open_attempt_key(binary(), term()) :: {:ok, attempt_key()} | {:error, :unsealable}
  def open_attempt_key(seal_key, sealed) when byte_size(seal_key) == 32 do
    with true <- is_binary(sealed),
         [named, box] <- String.split(sealed, "."),
         {:ok, attempt} <- read_attempt(named),
         {:ok, <<_::binary-size(32)>> = key} <-
           MacEnvelope.open(seal_key, @attempt_key_label, @attempt_fields, attempt, box) do
      {:ok, %{attempt: attempt, key: key}}
    else
      _ -> {:error, :unsealable}
    end
  end

  @doc "The header for a host call of `body`, signed with the attempt's key."
  @spec host_call_header(binary(), host_call(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def host_call_header(attempt_key, call, body) when is_binary(body),
    do: MacEnvelope.header(@call, attempt_key, call, body)

  @doc """
  A host call's authenticated fields, re-deriving its attempt key from
  `root`. `now` is the current time in Unix milliseconds and `generation`
  the current control-plane generation.
  """
  @spec verify_host_call(binary(), term(), binary(), integer(), pos_integer()) ::
          {:ok, host_call()} | {:error, call_refusal()}
  def verify_host_call(root, header, body, now, generation)
      when byte_size(root) == 32 and is_binary(body) and is_integer(now) and
             is_integer(generation) do
    with {:ok, call, mac} <- MacEnvelope.parse(@call, header),
         :ok <- within_window(call.ts, now),
         :ok <- authentic(@call, derived_attempt_key(root, call), call, mac, body),
         :ok <- same_generation(call.generation, generation) do
      {:ok, call}
    end
  end

  @doc "The header for a WorkerAPI request of `body` to one worker service."
  @spec request_header(binary(), dispatch(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def request_header(dispatch_key, request, body) when is_binary(body),
    do: MacEnvelope.header(@request, dispatch_key, request, body)

  @doc "A WorkerAPI request's authenticated fields. `now` is in Unix milliseconds."
  @spec verify_request(binary(), term(), binary(), integer()) ::
          {:ok, dispatch()} | {:error, dispatch_refusal()}
  def verify_request(dispatch_key, header, body, now),
    do: verify_dispatch(@request, dispatch_key, header, body, now)

  @doc "The header for a worker service's report of `body` to CYFR."
  @spec report_header(binary(), dispatch(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def report_header(dispatch_key, report, body) when is_binary(body),
    do: MacEnvelope.header(@report, dispatch_key, report, body)

  @doc "A worker service report's authenticated fields. `now` is in Unix milliseconds."
  @spec verify_report(binary(), term(), binary(), integer()) ::
          {:ok, dispatch()} | {:error, dispatch_refusal()}
  def verify_report(dispatch_key, header, body, now),
    do: verify_dispatch(@report, dispatch_key, header, body, now)

  defp verify_dispatch(envelope, dispatch_key, header, body, now)
       when is_binary(dispatch_key) and is_binary(body) and is_integer(now) do
    with {:ok, fields, mac} <- MacEnvelope.parse(envelope, header),
         :ok <- within_window(fields.ts, now),
         :ok <- authentic(envelope, dispatch_key, fields, mac, body) do
      {:ok, fields}
    end
  end

  defp attempt_json(attempt) do
    @attempt_fields
    |> Map.new(fn {name, _type} -> {Atom.to_string(name), Map.get(attempt, name)} end)
    |> Cyfr.JCS.encode()
  end

  # The attempt a sealed key names: exactly its five fields, each of its
  # type. `Cyfr.MacEnvelope.open/5` checks their values.
  defp read_attempt(named) do
    with {:ok, json} <- Base.url_decode64(named, padding: false),
         {:ok, %{} = wire} <- Jason.decode(json),
         true <- Enum.sort(Map.keys(wire)) == Enum.sort(@attempt_names),
         true <- Enum.all?(@attempt_fields, &typed?(&1, wire)) do
      {:ok, Map.new(@attempt_fields, fn {name, _type} -> {name, wire[Atom.to_string(name)]} end)}
    else
      _ -> :error
    end
  end

  defp typed?({name, :string}, wire), do: is_binary(wire[Atom.to_string(name)])
  defp typed?({name, :integer}, wire), do: is_integer(wire[Atom.to_string(name)])

  defp within_window(ts, now) when abs(ts - now) <= @window_ms, do: :ok
  defp within_window(_ts, _now), do: {:error, :outside_window}

  # A parsed host call always carries valid attempt fields.
  defp derived_attempt_key(root, call) do
    {:ok, key} = attempt_key(root, call)
    key
  end

  defp authentic(envelope, key, fields, mac, body) do
    if MacEnvelope.verify(envelope, key, fields, mac, body), do: :ok, else: {:error, :bad_mac}
  end

  defp same_generation(generation, generation), do: :ok
  defp same_generation(_presented, _current), do: {:error, :generation_mismatch}
end
