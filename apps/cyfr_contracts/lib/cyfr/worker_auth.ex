# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerAuth do
  @moduledoc """
  How CYFR and its execution workers authenticate each other, spelled with
  `Cyfr.MacEnvelope`. `tests/fixtures/worker_auth.json` holds the vectors
  every derivation, MAC and seal here must reproduce.

  One root secret of 32 bytes (`CYFR_WORKER_KEY`, `decode_root/1`) is
  CYFR's. Every key is derived from it, so nothing but the root is
  configured and nothing is stored:

  | Key | Derived from, over | Held by | Use |
  |---|---|---|---|
  | `assign_key/1` | the root, `cyfr-worker/v1/assign` | CYFR | MACs assignments (`Cyfr.Assignment`) |
  | `worker_key/2` | the root, `cyfr-worker/v1/worker` and the worker service's id | CYFR and that worker service | derives the two keys below, and nothing else |
  | `dispatch_key/1` | a worker key, `cyfr-worker/v1/dispatch` | CYFR and that worker service | signs WorkerAPI requests to it and its reports |
  | `dispatch_seal_key/1` | a worker key, `cyfr-worker/v1/dseal` | CYFR and that worker service | seals the keys of an attempt started on it (`seal_attempt_keys/3`) |
  | `attempt_call_key/2` | the root, `cyfr-worker/v1/call` and the attempt | CYFR and the attempt's runner | signs the attempt's host calls |
  | `attempt_seal_key/2` | the root, `cyfr-worker/v1/seal` and the attempt | CYFR and the attempt's runner | seals the attempt's host call bodies and answers (`seal_call/4`) |

  A key derived over fields is HMAC-SHA256 over its label followed by the
  field values, one per line (`Cyfr.MacEnvelope.derive/4`).

  A worker service's keys are its own: holding them signs nothing another
  worker service would accept, reports no other worker service's runners
  and opens no attempt started on another worker service. An attempt is its
  athanor, execution, attempt id, fence, control-plane generation and the
  worker service it was dispatched to, so an attempt's keys sign and open
  for that attempt, at that fence and generation, on that worker service
  only. A new generation retires every attempt key, and CYFR re-derives an
  attempt's keys from a host call's header without storing anything.

  ## Sealed attempt keys

  CYFR hands a worker service the keys of the attempt it starts sealed
  (`seal_attempt_keys/3`): `base64url(attempt) <> "." <> sealed`, where
  `attempt` is the JCS of the attempt's six fields and `sealed` is
  `Cyfr.MacEnvelope`'s AES-256-GCM seal of the call key followed by the
  seal key under the worker service's dispatch seal key, its additional
  data `cyfr-worker/v1/attempt-keys` followed by those fields one per line.
  `open_attempt_keys/2` answers the attempt and its keys only when the seal
  opens as the attempt it names.

  ## Sealed host calls

  A host call's body is sealed with the attempt's seal key
  (`seal_call/4`), its additional data `cyfr-worker/v1/call-body` followed
  by the call's header fields, one per line; its answer is sealed the same
  way under `cyfr-worker/v1/call-answer`. Each opens (`open_call/4`) only
  as the direction and the call it was sealed for.

  ## Headers

  A host call's header (`host_call_header/3`) is signed with the attempt's
  call key over the attempt's fields, the runner presenting it, the
  timestamp (Unix milliseconds), a nonce and the body. A WorkerAPI
  request's header (`request_header/3`) and a worker service's report
  header (`report_header/3`) are signed with that worker service's
  dispatch key over its id, the timestamp, a nonce and the body; the two
  kinds never verify as each other.

  ## Verifying

  `verify_host_call/5` answers the authenticated fields or the first
  refusal, in this order:

    1. `:malformed` — the header is not exactly one well-formed host-call
       header;
    2. `:outside_window` — `ts` is more than 30 seconds from `now`, on
       either side;
    3. `:bad_mac` — the MAC is not the call key's of the attempt the header
       names, over the header's fields and the body;
    4. `:generation_mismatch` — the header's generation is not the current
       one.

  `verify_report/4` checks the first three with the dispatch key of the
  worker service the report names, derived from the root, and
  `verify_request/4` with the dispatch key a worker service holds.

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
    generation: :integer,
    worker: :string
  ]

  @attempt_names Enum.map(@attempt_fields, fn {name, _type} -> Atom.to_string(name) end)

  @call %MacEnvelope{
    prefix: "cyfr-worker/v1",
    kind: "call",
    fields: @attempt_fields ++ [runner: :string, ts: :integer, nonce: :string]
  }

  @dispatch_fields [worker: :string, ts: :integer, nonce: :string]
  @request %MacEnvelope{prefix: "cyfr-worker/v1", kind: "request", fields: @dispatch_fields}
  @report %MacEnvelope{prefix: "cyfr-worker/v1", kind: "report", fields: @dispatch_fields}

  @sealed_directions %{body: "cyfr-worker/v1/call-body", answer: "cyfr-worker/v1/call-answer"}

  @typedoc "The attempt an attempt's keys are bound to."
  @type attempt :: %{
          required(:athanor_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:attempt) => String.t(),
          required(:fence) => pos_integer(),
          required(:generation) => pos_integer(),
          required(:worker) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "An attempt, the key its runner signs host calls with and the key it seals them with."
  @type attempt_keys :: %{attempt: attempt(), call: binary(), seal: binary()}

  @typedoc """
  A host call's header fields: the attempt's, the presenting runner, `ts`
  in Unix ms and a nonce.
  """
  @type host_call :: %{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          worker: String.t(),
          runner: String.t(),
          ts: non_neg_integer(),
          nonce: String.t()
        }

  @typedoc "A WorkerAPI request's or report's header fields: the worker service, `ts` in Unix ms and a nonce."
  @type dispatch :: %{worker: String.t(), ts: non_neg_integer(), nonce: String.t()}

  @typedoc "Which half of a host call a sealed value is: the runner's body or CYFR's answer."
  @type direction :: :body | :answer

  @type dispatch_refusal :: :malformed | :outside_window | :bad_mac
  @type call_refusal :: dispatch_refusal() | :generation_mismatch

  @doc """
  The root secret `CYFR_WORKER_KEY` spells: exactly 64 hexadecimal digits,
  in either case. Anything else is `:error`.
  """
  @spec decode_root(term()) :: {:ok, binary()} | :error
  defdelegate decode_root(text), to: MacEnvelope

  @doc "The key assignments are MAC'd with. Only CYFR holds it."
  @spec assign_key(binary()) :: binary()
  def assign_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-worker/v1/assign")

  @doc """
  The key of the worker service `worker`: the one secret that worker
  service holds, from which its dispatch and dispatch seal keys derive.
  """
  @spec worker_key(binary(), String.t()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def worker_key(root, worker) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-worker/v1/worker", [worker: :string], %{worker: worker})

  @doc "The key WorkerAPI requests to a worker service and its reports are signed with."
  @spec dispatch_key(binary()) :: binary()
  def dispatch_key(worker_key) when byte_size(worker_key) == 32,
    do: MacEnvelope.derive(worker_key, "cyfr-worker/v1/dispatch")

  @doc "The key the attempt keys a worker service is started with are sealed with."
  @spec dispatch_seal_key(binary()) :: binary()
  def dispatch_seal_key(worker_key) when byte_size(worker_key) == 32,
    do: MacEnvelope.derive(worker_key, "cyfr-worker/v1/dseal")

  @doc "The key an attempt's runner signs its host calls with."
  @spec attempt_call_key(binary(), attempt()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def attempt_call_key(root, attempt) when byte_size(root) == 32 and is_map(attempt),
    do: MacEnvelope.derive(root, "cyfr-worker/v1/call", @attempt_fields, attempt)

  @doc "The key an attempt's host call bodies and answers are sealed with."
  @spec attempt_seal_key(binary(), attempt()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def attempt_seal_key(root, attempt) when byte_size(root) == 32 and is_map(attempt),
    do: MacEnvelope.derive(root, "cyfr-worker/v1/seal", @attempt_fields, attempt)

  @doc "The attempt's keys, both derived from `root` (`t:attempt_keys/0`)."
  @spec attempt_keys(binary(), attempt()) ::
          {:ok, attempt_keys()} | {:error, MacEnvelope.invalid_field()}
  def attempt_keys(root, attempt) when byte_size(root) == 32 and is_map(attempt) do
    with {:ok, call} <- attempt_call_key(root, attempt),
         {:ok, seal} <- attempt_seal_key(root, attempt) do
      {:ok, %{attempt: Map.take(attempt, Keyword.keys(@attempt_fields)), call: call, seal: seal}}
    end
  end

  @doc """
  Seal an attempt's keys with the dispatch seal key of the worker service
  it is started on, naming the attempt. `iv` is 12 random bytes unless
  given.
  """
  @spec seal_attempt_keys(binary(), attempt_keys(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def seal_attempt_keys(seal_key, attempt_keys, iv \\ :crypto.strong_rand_bytes(12))

  def seal_attempt_keys(seal_key, %{attempt: attempt, call: call, seal: seal}, iv)
      when byte_size(seal_key) == 32 and is_map(attempt) and byte_size(call) == 32 and
             byte_size(seal) == 32 and byte_size(iv) == 12 do
    with {:ok, sealed} <-
           MacEnvelope.seal(
             seal_key,
             "cyfr-worker/v1/attempt-keys",
             @attempt_fields,
             attempt,
             call <> seal,
             iv
           ),
         {:ok, named} <- attempt_json(attempt) do
      {:ok, Base.url_encode64(named, padding: false) <> "." <> sealed}
    end
  end

  @doc """
  The attempt and keys `seal_attempt_keys/3` sealed, opened with a worker
  service's dispatch seal key. Anything that does not open as the attempt
  it names, or whose keys are not two of 32 bytes, is
  `{:error, :unsealable}`.
  """
  @spec open_attempt_keys(binary(), term()) :: {:ok, attempt_keys()} | {:error, :unsealable}
  def open_attempt_keys(seal_key, sealed) when byte_size(seal_key) == 32 do
    with true <- is_binary(sealed),
         [named, box] <- String.split(sealed, "."),
         {:ok, attempt} <- read_attempt(named),
         {:ok, <<call::binary-size(32), seal::binary-size(32)>>} <-
           MacEnvelope.open(
             seal_key,
             "cyfr-worker/v1/attempt-keys",
             @attempt_fields,
             attempt,
             box
           ) do
      {:ok, %{attempt: attempt, call: call, seal: seal}}
    else
      _ -> {:error, :unsealable}
    end
  end

  @doc """
  Seal one half of a host call — the runner's `:body` or CYFR's `:answer`
  — with the attempt's seal key, bound to the call's header fields. `iv`
  is 12 random bytes unless given.
  """
  @spec seal_call(binary(), direction(), host_call(), binary(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def seal_call(seal_key, direction, call, plaintext, iv \\ :crypto.strong_rand_bytes(12))
      when byte_size(seal_key) == 32 and is_map_key(@sealed_directions, direction) and
             is_map(call) and is_binary(plaintext) and byte_size(iv) == 12 do
    MacEnvelope.seal(
      seal_key,
      Map.fetch!(@sealed_directions, direction),
      @call.fields,
      call,
      plaintext,
      iv
    )
  end

  @doc """
  Open what `seal_call/5` sealed, as the same direction of the same call.
  Anything else is `{:error, :unsealable}`.
  """
  @spec open_call(binary(), direction(), host_call(), term()) ::
          {:ok, binary()} | {:error, :unsealable}
  def open_call(seal_key, direction, call, sealed)
      when byte_size(seal_key) == 32 and is_map_key(@sealed_directions, direction) and
             is_map(call) do
    case MacEnvelope.open(
           seal_key,
           Map.fetch!(@sealed_directions, direction),
           @call.fields,
           call,
           sealed
         ) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> {:error, :unsealable}
    end
  end

  @doc "The header for a host call of `body`, signed with the attempt's call key."
  @spec host_call_header(binary(), host_call(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def host_call_header(call_key, call, body) when is_binary(body),
    do: MacEnvelope.header(@call, call_key, call, body)

  @doc """
  A host call's authenticated fields, re-deriving its attempt's call key
  from `root`. `now` is the current time in Unix milliseconds and
  `generation` the current control-plane generation.
  """
  @spec verify_host_call(binary(), term(), binary(), integer(), pos_integer()) ::
          {:ok, host_call()} | {:error, call_refusal()}
  def verify_host_call(root, header, body, now, generation)
      when byte_size(root) == 32 and is_binary(body) and is_integer(now) and
             is_integer(generation) do
    with {:ok, call, mac} <- MacEnvelope.parse(@call, header),
         :ok <- within_window(call.ts, now),
         :ok <- authentic(@call, derived(&attempt_call_key(root, &1), call), call, mac, body),
         :ok <- same_generation(call.generation, generation) do
      {:ok, call}
    end
  end

  @doc "The header for a WorkerAPI request of `body` to one worker service, signed with its dispatch key."
  @spec request_header(binary(), dispatch(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def request_header(dispatch_key, request, body) when is_binary(body),
    do: MacEnvelope.header(@request, dispatch_key, request, body)

  @doc """
  A WorkerAPI request's authenticated fields, under the dispatch key of the
  worker service verifying it. `now` is in Unix milliseconds.
  """
  @spec verify_request(binary(), term(), binary(), integer()) ::
          {:ok, dispatch()} | {:error, dispatch_refusal()}
  def verify_request(dispatch_key, header, body, now) when byte_size(dispatch_key) == 32 do
    with {:ok, fields, mac} <- dispatch_fields(@request, header, now),
         :ok <- authentic(@request, dispatch_key, fields, mac, body) do
      {:ok, fields}
    end
  end

  @doc "The header for a worker service's report of `body` to CYFR, signed with its dispatch key."
  @spec report_header(binary(), dispatch(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def report_header(dispatch_key, report, body) when is_binary(body),
    do: MacEnvelope.header(@report, dispatch_key, report, body)

  @doc """
  A worker service report's authenticated fields, under the dispatch key of
  the worker service the report names, derived from `root`. `now` is in
  Unix milliseconds.
  """
  @spec verify_report(binary(), term(), binary(), integer()) ::
          {:ok, dispatch()} | {:error, dispatch_refusal()}
  def verify_report(root, header, body, now) when byte_size(root) == 32 do
    with {:ok, fields, mac} <- dispatch_fields(@report, header, now),
         worker_key = derived(&worker_key(root, &1.worker), fields),
         :ok <- authentic(@report, dispatch_key(worker_key), fields, mac, body) do
      {:ok, fields}
    end
  end

  defp dispatch_fields(envelope, header, now) when is_integer(now) do
    with {:ok, fields, mac} <- MacEnvelope.parse(envelope, header),
         :ok <- within_window(fields.ts, now) do
      {:ok, fields, mac}
    end
  end

  defp attempt_json(attempt) do
    @attempt_fields
    |> Map.new(fn {name, _type} -> {Atom.to_string(name), Map.get(attempt, name)} end)
    |> Cyfr.JCS.encode()
  end

  # The attempt sealed keys name: exactly its six fields, each of its type.
  # `Cyfr.MacEnvelope.open/5` checks their values.
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

  # A parsed header's fields are always valid key derivation fields.
  defp derived(derive, fields) do
    {:ok, key} = derive.(fields)
    key
  end

  defp within_window(ts, now) when abs(ts - now) <= @window_ms, do: :ok
  defp within_window(_ts, _now), do: {:error, :outside_window}

  defp authentic(envelope, key, fields, mac, body) when is_binary(body) do
    if MacEnvelope.verify(envelope, key, fields, mac, body), do: :ok, else: {:error, :bad_mac}
  end

  defp same_generation(generation, generation), do: :ok
  defp same_generation(_presented, _current), do: {:error, :generation_mismatch}
end
