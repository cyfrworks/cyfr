# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WorkerAuth do
  @moduledoc """
  How CYFR and its execution workers authenticate each other, spelled with
  `Prima.MacEnvelope`. `tests/fixtures/worker_auth.json` holds the vectors
  every derivation, MAC and seal here must reproduce.

  One root secret of 32 bytes (`CYFR_OPUS_KEY`, `decode_root/1`) is
  CYFR's. Every key is derived from it, so nothing but the root is
  configured and nothing is stored:

  | Key | Derived from, over | Held by | Use |
  |---|---|---|---|
  | `assign_key/1` | the root, `cyfr-opus/v1/assign` | CYFR | MACs assignments (`Prima.Assignment`) |
  | `worker_key/2` | the root, `cyfr-opus/v1/worker` and the worker service's id | CYFR and that worker service | derives the two keys below, and nothing else |
  | `dispatch_key/1` | a worker key, `cyfr-opus/v1/dispatch` | CYFR and that worker service | signs WorkerAPI requests to it and its reports |
  | `dispatch_seal_key/1` | a worker key, `cyfr-opus/v1/dseal` | CYFR and that worker service | seals the keys of an attempt started on it (`seal_attempt_keys/3`) |
  | `attempt_call_key/2` | the root, `cyfr-opus/v1/call` and the attempt | CYFR and the attempt's runner | signs the attempt's host calls |
  | `attempt_seal_key/2` | the root, `cyfr-opus/v1/seal` and the attempt | CYFR and the attempt's runner | seals the attempt's host call bodies and answers (`seal_call/4`) and its attached answers' frames (`seal_frame/7`) |

  A key derived over fields is HMAC-SHA256 over its label followed by the
  field values, one per line (`Prima.MacEnvelope.derive/4`).

  ## Identities

  Three identities name the worker side, and only the first is a key
  input:

    * the **service** id — a worker service's stable, configured identity
      (`OPUS_SERVICE_ID` on the service, the same id in CYFR's
      `CYFR_OPUS_WORKERS`), which `worker_key/2` derives its keys over and
      which an attempt's keys are bound to; two worker services never share
      one;
    * the **boot** id — the incarnation a worker service mints on every
      start, carried on every header beside the service id so CYFR can
      refuse a delayed call or report from an incarnation that no longer
      holds the attempt; it is compared, never derived over;
    * the **runner** id — the runner presenting a host call, which claimed
      the attempt; a formula's children present their parent's.

  One identity names the control-plane side: the **member** id, the boot
  of the member that issued the attempt's assignment (`Prima.Boot.id/0`,
  `"<node>#boot_<uuid7>"`). A host call names it, so the one member that
  holds the attempt's process is the one member that answers its calls;
  every other member refuses it, whether the call needs that process or
  could have been answered from the rows. It is compared, never derived
  over: a member that has restarted holds a new boot id and a higher
  generation, and either refuses the calls of the attempts its
  predecessor issued.

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
  `Prima.MacEnvelope`'s AES-256-GCM seal of the call key followed by the
  seal key under the worker service's dispatch seal key, its additional
  data `cyfr-opus/v1/attempt-keys` followed by those fields one per line.
  `open_attempt_keys/2` answers the attempt and its keys only when the seal
  opens as the attempt it names.

  ## Sealed host calls

  A host call's body is sealed with the attempt's seal key
  (`seal_call/4`), its additional data `cyfr-opus/v1/call-body` followed
  by the call's header fields, one per line; its answer is sealed the same
  way under `cyfr-opus/v1/call-answer`. Each opens (`open_call/4`) only
  as the direction and the call it was sealed for.

  ## Sealed answer frames

  An attached request's answer (`c:Prima.HostAPI.attached_fetch/3`) is a
  stream of frames rather than one sealed answer. A frame is a 4-byte
  big-endian length, one kind byte in clear (`h` head, `c` chunk, `e` end,
  `x` error) and the sealed value (`seal_frame/7`): `Prima.MacEnvelope`'s
  seal under the attempt's seal key, its additional data
  `cyfr-opus/v1/frame-answer` followed by the call id the runner chose
  for the request, the frame's sequence number and its kind, one per line.
  The length counts the kind byte and the sealed value, at most
  `max_frame_bytes/0`; a `chunk` carries at most `max_chunk_bytes/0` of
  the body. So a frame opens (`open_frame/6`) only as the call, place and
  kind it was sealed for, and a changed kind byte does not open.

  Sequence numbers count from 0 per call. Seq 0 is a `head` (the answer's
  status and headers, `head_plaintext/2`) or an `error` (a type and a
  sentence, `error_plaintext/2`); after a `head` come zero or more
  `chunk`s and then exactly one `end` (empty) or `error`, and nothing
  follows. `read_frames/2` holds a stream to that and ends it as an error
  on a frame out of sequence, under another call, with a bad tag, over the
  bound or of an unknown kind, never as a shorter body. The seal binds
  each frame's integrity, order and call; the worker service that relays
  the frames holds the attempt's keys, and what it can read is the masked
  answer the runner may read.

  ## Headers

  A host call's header (`host_call_header/3`) is signed with the attempt's
  call key over the attempt's fields, the boot and the runner presenting
  it, the member it is addressed to, the timestamp (Unix milliseconds), a
  nonce and the body. A WorkerAPI request's header (`request_header/3`)
  and a worker service's report header (`report_header/3`) are signed with
  that worker service's dispatch key over its service id, its boot, the
  timestamp, a nonce and the body; the two kinds never verify as each
  other. Every header names
  its body's hex SHA-256 (`body=`), which is what the MAC covers in the
  body's place, so a listener verifies the header before it reads the body
  and refuses an unauthenticated caller without reading what it sent.

  ## Verifying

  `verify_host_call/5` answers the authenticated fields or the first
  refusal, in this order:

    1. `:unknown_version` — the header's first token is a version token
       other than `v1`, such as `v2` (`Prima.MacEnvelope.parse/2`): a peer
       at another version of the wire, told so before anything else is
       read;
    2. `:malformed` — the header is not exactly one well-formed host-call
       header;
    3. `:outside_window` — `ts` is more than 30 seconds from `now`, on
       either side;
    4. `:bad_mac` — the MAC is not the call key's of the attempt the header
       names, over the header's fields and the body;
    5. `:generation_mismatch` — the header's generation is not the verifying
       member's current one;
    6. `:member_mismatch` — the header names another member. The call
       belongs to the member that issued its attempt's assignment, and no
       other answers it: an operation that needs the attempt's process
       would be lost on a peer, and one a peer could answer from the rows
       — a lease renewal — would be answered for work it does not hold.

  `verify_report/4` checks the first four with the dispatch key of the
  worker service the report names, derived from the root, and
  `verify_request/4` with the dispatch key a worker service holds.

  A worker service holds the opened keys of every attempt it started, and
  verifies a host call its runner hands it before it posts the call
  (`verify_host_call_header_under/3`): the first four refusals, under the
  call key it holds rather than one derived from the root. The fields it
  answers are the service's to compare with the attempt, the runner, the
  boot and the member it holds; the member's standing is CYFR's.

  ## Refusing before the body

  A listener refuses what the header alone decides before it reads the
  body, and in this order, which `tests/fixtures/host_api.json`'s
  `pre_body_refusals` pin:

    1. the route: a path that is no route of the listener's, or a method
       that is not `POST`;
    2. plane ownership: a control-plane member that does not hold the
       control plane answers for no attempt;
    3. the header count: exactly one `x-cyfr-auth` header
       (`Prima.WorkerWire.auth_header/0`);
    4. `unknown_version`, then `malformed`, `outside_window`, `bad_mac`,
       `generation_mismatch` and `member_mismatch`, as the header-first
       verifiers answer them (a WorkerAPI request and a report stop after
       `bad_mac`);
    5. the nonce: one presented before within the window, on a call that
       is not idempotent (`Prima.HostAPI.retry/1`), is `replayed`.

  Only then is the body read, bounded, checked against the hash the header
  named (`verify_body/2`), opened when sealed, and read as the route's
  callback at this version (`Prima.WorkerWire.read_request_body/2`).

  `verify_host_call_header/4`, `verify_request_header/3` and
  `verify_report_header/3` answer the same, over the header alone, with
  the body hash the header names; `verify_body/2` then checks the body
  read afterwards against that hash. The pair refuses exactly what the
  one-step verifier refuses.

  Replay and staleness beyond that are the caller's, against state this
  module does not hold: a nonce seen before for the same attempt (or, for
  the dispatch kinds, the same worker service) within the window is
  refused on every call that is not idempotent, and a host call's attempt
  row must be current, running, at the header's fence, on the header's
  boot and claimed by the header's runner.
  """

  alias Prima.MacEnvelope

  @window_ms 30_000

  @attempt_fields [
    athanor_id: :string,
    execution_id: :string,
    attempt: :string,
    fence: :integer,
    generation: :integer,
    service: :string
  ]

  @attempt_names Enum.map(@attempt_fields, fn {name, _type} -> Atom.to_string(name) end)

  # Every worker header names its body's hash, so a listener verifies the
  # header before it reads the body it covers (`verify_host_call_header/4`,
  # `verify_request_header/3`, `verify_report_header/3`, then `verify_body/2`).
  @call %MacEnvelope{
    prefix: Prima.MacEnvelope.domain(:opus),
    kind: "call",
    fields:
      @attempt_fields ++
        [
          boot: :string,
          runner: :string,
          member: :string,
          ts: :integer,
          nonce: :string
        ],
    body_hash_in_header: true
  }

  # A header's longest spelling: its version and kind, then each field as
  # ` name=value` at the value's longest (a string of 256 bytes, an integer
  # up to 2^53 − 1 in 16 digits), the 64-digit body hash and the 43
  # characters of an unpadded base64url HMAC-SHA256.
  @max_call_header_bytes byte_size("v1 kind=call") +
                           Enum.sum(
                             Enum.map(@call.fields, fn
                               {name, :string} -> byte_size(" #{name}=") + 256
                               {name, :integer} -> byte_size(" #{name}=") + 16
                             end)
                           ) + byte_size(" body=") + 64 + byte_size(" mac=") + 43

  @dispatch_fields [service: :string, boot: :string, ts: :integer, nonce: :string]
  @request %MacEnvelope{
    prefix: Prima.MacEnvelope.domain(:opus),
    kind: "request",
    fields: @dispatch_fields,
    body_hash_in_header: true
  }
  @report %MacEnvelope{
    prefix: Prima.MacEnvelope.domain(:opus),
    kind: "report",
    fields: @dispatch_fields,
    body_hash_in_header: true
  }

  @sealed_directions %{body: "cyfr-opus/v1/call-body", answer: "cyfr-opus/v1/call-answer"}

  @frame_directions %{answer: "cyfr-opus/v1/frame-answer"}
  @frame_fields [call_id: :string, seq: :integer, kind: :string]
  @frame_kinds [:head, :chunk, :end, :error]
  @kind_bytes %{head: ?h, chunk: ?c, end: ?e, error: ?x}
  @max_frame_bytes 65_536
  @max_chunk_bytes 32_768
  @max_frame_message_bytes 512
  # A sealed value's IV and tag beside its ciphertext (`Prima.MacEnvelope.seal/6`).
  @sealed_overhead_bytes 12 + 16

  @typedoc "The attempt an attempt's keys are bound to."
  @type attempt :: %{
          required(:athanor_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:attempt) => String.t(),
          required(:fence) => pos_integer(),
          required(:generation) => pos_integer(),
          required(:service) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "An attempt, the key its runner signs host calls with and the key it seals them with."
  @type attempt_keys :: %{attempt: attempt(), call: binary(), seal: binary()}

  @typedoc """
  A host call's header fields: the attempt's, the boot and the runner
  presenting it, the member it is addressed to, `ts` in Unix ms and a
  nonce.
  """
  @type host_call :: %{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          generation: pos_integer(),
          service: String.t(),
          boot: String.t(),
          runner: String.t(),
          member: String.t(),
          ts: non_neg_integer(),
          nonce: String.t()
        }

  @typedoc """
  What the member verifying a host call holds: the generation it issues
  and checks under, and its own boot id (`Prima.Boot.id/0`). A call is
  answered only by the member it names, at that member's current
  generation.
  """
  @type standing :: %{generation: pos_integer(), member: String.t()}

  @typedoc """
  A WorkerAPI request's or report's header fields: the worker service's id
  and boot, `ts` in Unix ms and a nonce.
  """
  @type dispatch :: %{
          service: String.t(),
          boot: String.t(),
          ts: non_neg_integer(),
          nonce: String.t()
        }

  @typedoc "Which half of a host call a sealed value is: the runner's body or CYFR's answer."
  @type direction :: :body | :answer

  @typedoc "The kind of an attached request's answer frame."
  @type frame_kind :: :head | :chunk | :end | :error

  @typedoc "Where a reader of one call's answer frames stands (`frame_reader/2`)."
  @type frame_reader :: %{
          seal_key: binary(),
          call_id: String.t(),
          seq: non_neg_integer(),
          state: :head | :body | :done
        }

  @typedoc "Why a stream of answer frames ends as an error (`read_frames/2`)."
  @type frame_refusal ::
          :frame_too_large | :malformed | :unknown_kind | :out_of_sequence | :unsealable

  @type dispatch_refusal :: :unknown_version | :malformed | :outside_window | :bad_mac
  @type call_refusal :: dispatch_refusal() | :generation_mismatch | :member_mismatch

  @typedoc """
  The hex SHA-256 a verified header names as its body's, which
  `verify_body/2` checks the body against.
  """
  @type body_hash :: String.t()

  @doc """
  The root secret `CYFR_OPUS_KEY` spells: exactly 64 hexadecimal digits,
  in either case. Anything else is `:error`.
  """
  @spec decode_root(term()) :: {:ok, binary()} | :error
  defdelegate decode_root(text), to: MacEnvelope

  @doc """
  How far a header's `ts` may be from the verifier's clock, in
  milliseconds, on either side. A call answered later than this is treated
  as lost by its client (`Prima.HostAPI.request_timeout_ms/1`).
  """
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "The key assignments are MAC'd with. Only CYFR holds it."
  @spec assign_key(binary()) :: binary()
  def assign_key(root) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-opus/v1/assign")

  @doc """
  The key of the worker service `service`: the one secret that worker
  service holds, from which its dispatch and dispatch seal keys derive. It
  is derived over the service's stable id, never its boot.
  """
  @spec worker_key(binary(), String.t()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def worker_key(root, service) when byte_size(root) == 32,
    do: MacEnvelope.derive(root, "cyfr-opus/v1/worker", [service: :string], %{service: service})

  @doc "The key WorkerAPI requests to a worker service and its reports are signed with."
  @spec dispatch_key(binary()) :: binary()
  def dispatch_key(worker_key) when byte_size(worker_key) == 32,
    do: MacEnvelope.derive(worker_key, "cyfr-opus/v1/dispatch")

  @doc "The key the attempt keys a worker service is started with are sealed with."
  @spec dispatch_seal_key(binary()) :: binary()
  def dispatch_seal_key(worker_key) when byte_size(worker_key) == 32,
    do: MacEnvelope.derive(worker_key, "cyfr-opus/v1/dseal")

  @doc "The key an attempt's runner signs its host calls with."
  @spec attempt_call_key(binary(), attempt()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def attempt_call_key(root, attempt) when byte_size(root) == 32 and is_map(attempt),
    do: MacEnvelope.derive(root, "cyfr-opus/v1/call", @attempt_fields, attempt)

  @doc "The key an attempt's host call bodies and answers are sealed with."
  @spec attempt_seal_key(binary(), attempt()) ::
          {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def attempt_seal_key(root, attempt) when byte_size(root) == 32 and is_map(attempt),
    do: MacEnvelope.derive(root, "cyfr-opus/v1/seal", @attempt_fields, attempt)

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
             "cyfr-opus/v1/attempt-keys",
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
             "cyfr-opus/v1/attempt-keys",
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

  # ============================================================================
  # Answer frames
  # ============================================================================

  @doc "The frame kinds of an attached request's answer, in their order."
  @spec frame_kinds() :: [frame_kind()]
  def frame_kinds, do: @frame_kinds

  @doc """
  The most bytes one answer frame spans after its length prefix: its kind
  byte and its sealed value.
  """
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "The most body bytes one `chunk` frame carries."
  @spec max_chunk_bytes() :: pos_integer()
  def max_chunk_bytes, do: @max_chunk_bytes

  @doc "The most bytes an `error` frame's sentence spans."
  @spec max_frame_message_bytes() :: pos_integer()
  def max_frame_message_bytes, do: @max_frame_message_bytes

  @doc """
  Seal one frame of an attached request's answer, `seq` of the call
  `call_id`, as the bytes it crosses in: a 4-byte big-endian length, the
  kind byte in clear and `sealed`, `Prima.MacEnvelope`'s seal of
  `plaintext` under the attempt's seal key with `call_id`, `seq` and the
  kind as its additional data, so a frame opens only as the call, place
  and kind it was sealed for. `direction` is `:answer`, the one direction
  frames flow. A `chunk` past `max_chunk_bytes/0`, or a frame past
  `max_frame_bytes/0`, is `{:error, :frame_too_large}`. `iv` is the 12
  bytes the sealer draws, fresh for every frame: a frame takes no entropy
  of its own.
  """
  @spec seal_frame(
          binary(),
          :answer,
          String.t(),
          non_neg_integer(),
          frame_kind(),
          binary(),
          binary()
        ) ::
          {:ok, binary()} | {:error, :frame_too_large | MacEnvelope.invalid_field()}
  def seal_frame(seal_key, direction, call_id, seq, kind, plaintext, iv)
      when byte_size(seal_key) == 32 and is_map_key(@frame_directions, direction) and
             is_map_key(@kind_bytes, kind) and is_binary(plaintext) and byte_size(iv) == 12 do
    with :ok <- chunk_within(kind, plaintext),
         {:ok, sealed} <-
           MacEnvelope.seal(
             seal_key,
             Map.fetch!(@frame_directions, direction),
             @frame_fields,
             frame_message(call_id, seq, kind),
             plaintext,
             iv
           ) do
      framed(kind, sealed)
    end
  end

  defp framed(kind, sealed) do
    length = 1 + byte_size(sealed)

    if length <= @max_frame_bytes,
      do: {:ok, <<length::32, Map.fetch!(@kind_bytes, kind), sealed::binary>>},
      else: {:error, :frame_too_large}
  end

  @doc """
  Open the `sealed` value of a frame read as `kind`, at `seq` of the call
  `call_id`. Anything that was not sealed for exactly that call, place and
  kind is `{:error, :unsealable}`.
  """
  @spec open_frame(binary(), :answer, String.t(), non_neg_integer(), frame_kind(), term()) ::
          {:ok, binary()} | {:error, :unsealable}
  def open_frame(seal_key, direction, call_id, seq, kind, sealed)
      when byte_size(seal_key) == 32 and is_map_key(@frame_directions, direction) and
             is_map_key(@kind_bytes, kind) do
    case MacEnvelope.open(
           seal_key,
           Map.fetch!(@frame_directions, direction),
           @frame_fields,
           frame_message(call_id, seq, kind),
           sealed
         ) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> {:error, :unsealable}
    end
  end

  @doc "A `head` frame's plaintext: the answer's status and its headers, in order."
  @spec head_plaintext(100..599, [{String.t(), String.t()}]) :: binary()
  def head_plaintext(status, headers) when status in 100..599 and is_list(headers) do
    Jason.OrderedObject.new([
      {"status", status},
      {"headers", Enum.map(headers, fn {name, value} -> [name, value] end)}
    ])
    |> Jason.encode!()
  end

  @doc """
  An `error` frame's plaintext: a guest error's type and its sentence, at
  most `max_frame_message_bytes/0`, which carries no material.
  """
  @spec error_plaintext(String.t(), String.t()) :: binary()
  def error_plaintext(type, message)
      when is_binary(type) and is_binary(message) and
             byte_size(message) <= @max_frame_message_bytes do
    Jason.OrderedObject.new([{"type", type}, {"message", message}]) |> Jason.encode!()
  end

  @doc """
  A reader of one attached request's answer frames, for the call `call_id`
  under the attempt's seal key, before its first frame.
  """
  @spec frame_reader(binary(), String.t()) :: frame_reader()
  def frame_reader(seal_key, call_id) when byte_size(seal_key) == 32 and is_binary(call_id),
    do: %{seal_key: seal_key, call_id: call_id, seq: 0, state: :head}

  @doc """
  The complete frames at the head of a stream of answer frames, each its
  kind byte and sealed value without the length prefix, and the bytes
  after them, which wait for more; or `{:error, :frame_too_large}` for a
  length above `max_frame_bytes/0`, as soon as the length is in, and
  `{:error, :malformed}` for one below two bytes. Nothing is opened: this
  is how a relay that carries the frames unopened splits the stream.
  """
  @spec split_frames(binary()) :: {:ok, [binary()], binary()} | {:error, frame_refusal()}
  def split_frames(buffer) when is_binary(buffer), do: split_frames(buffer, [])

  defp split_frames(<<length::32, _rest::binary>>, _frames) when length > @max_frame_bytes,
    do: {:error, :frame_too_large}

  defp split_frames(<<length::32, _rest::binary>>, _frames) when length < 2,
    do: {:error, :malformed}

  defp split_frames(<<length::32, frame::binary-size(length), rest::binary>>, frames),
    do: split_frames(rest, [frame | frames])

  defp split_frames(rest, frames), do: {:ok, Enum.reverse(frames), rest}

  @doc """
  The body bytes one answer frame carries, its kind byte and sealed value
  as `split_frames/1` answers it, read from the sealed value's length
  without opening it: a `chunk`'s plaintext length under
  `Prima.MacEnvelope`'s layout (unpadded base64url of the 12-byte IV, the
  16-byte tag and the ciphertext, as long as its plaintext). Every other
  kind carries none, and neither does a value no seal produces: 0. This is
  how a relay that carries the frames unopened counts an answer's body
  against its bound.
  """
  @spec frame_body_bytes(binary()) :: non_neg_integer()
  def frame_body_bytes(<<?c, sealed::binary>>), do: sealed_plaintext_bytes(byte_size(sealed))
  def frame_body_bytes(frame) when is_binary(frame), do: 0

  # Unpadded base64 spells 3 bytes in 4 characters, a last 1 byte in 2
  # and a last 2 in 3; a length leaving 1 character over spells nothing.
  defp sealed_plaintext_bytes(length) do
    decoded =
      case rem(length, 4) do
        0 -> div(length, 4) * 3
        2 -> div(length, 4) * 3 + 1
        3 -> div(length, 4) * 3 + 2
        1 -> 0
      end

    max(decoded - @sealed_overhead_bytes, 0)
  end

  @doc """
  One answer frame, its kind byte and sealed value, opened and read as the
  next frame of the reader's call, and the reader after it; or the first
  reason the answer ends as an error, never as a shorter body:

    1. `:malformed` — a frame of no kind byte and sealed value;
    2. `:unknown_kind` — a kind byte other than `h`, `c`, `e` and `x`;
    3. `:out_of_sequence` — a kind out of the answer's order: seq 0 is a
       `head` or an `error`, after a `head` come `chunk`s and then one
       `end` or `error`, and nothing follows an `end` or an `error`;
    4. `:unsealable` — a sealed value that does not open as this call's
       frame at this place of this kind: another call's, one out of its
       place, or one whose tag or kind byte was changed;
    5. `:malformed` or `:frame_too_large` — a plaintext its kind does not
       carry: a `head` that is not a status and its header pairs, a
       `chunk` past `max_chunk_bytes/0`, an `end` that is not empty, an
       `error` that is not a type and a sentence within its bound.

  A frame read is `%{kind: :head, status:, headers:}`, `%{kind: :chunk,
  body:}`, `%{kind: :end}` or `%{kind: :error, type:, message:}`.
  """
  @spec read_frame(frame_reader(), binary()) ::
          {:ok, map(), frame_reader()} | {:error, frame_refusal()}
  def read_frame(%{} = reader, <<byte, sealed::binary>>) when sealed != "" do
    with {:ok, kind} <- kind_of_byte(byte),
         :ok <- in_sequence(reader.state, kind),
         {:ok, plaintext} <-
           open_frame(reader.seal_key, :answer, reader.call_id, reader.seq, kind, sealed),
         {:ok, read} <- read_plaintext(kind, plaintext) do
      {:ok, read, %{reader | seq: reader.seq + 1, state: next_state(kind)}}
    end
  end

  def read_frame(%{}, frame) when is_binary(frame), do: {:error, :malformed}

  @doc """
  The complete frames at the head of a length-prefixed stream
  (`split_frames/1`), each read as `read_frame/2` reads it, the bytes after
  them and the reader after them; or the first refusal of either, at which
  the answer ends as an error.
  """
  @spec read_frames(frame_reader(), binary()) ::
          {:ok, [map()], binary(), frame_reader()} | {:error, frame_refusal()}
  def read_frames(%{} = reader, buffer) when is_binary(buffer) do
    with {:ok, frames, rest} <- split_frames(buffer) do
      frames
      |> Enum.reduce_while({:ok, [], reader}, fn frame, {:ok, read, reader} ->
        case read_frame(reader, frame) do
          {:ok, one, reader} -> {:cont, {:ok, [one | read], reader}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, read, reader} -> {:ok, Enum.reverse(read), rest, reader}
        {:error, _reason} = error -> error
      end
    end
  end

  defp kind_of_byte(byte) do
    case Enum.find(@kind_bytes, fn {_kind, kind_byte} -> kind_byte == byte end) do
      {kind, _byte} -> {:ok, kind}
      nil -> {:error, :unknown_kind}
    end
  end

  defp in_sequence(:head, kind) when kind in [:head, :error], do: :ok
  defp in_sequence(:body, kind) when kind in [:chunk, :end, :error], do: :ok
  defp in_sequence(_state, _kind), do: {:error, :out_of_sequence}

  defp next_state(kind) when kind in [:head, :chunk], do: :body
  defp next_state(kind) when kind in [:end, :error], do: :done

  defp read_plaintext(:head, plaintext) do
    case Jason.decode(plaintext) do
      {:ok, %{"status" => status, "headers" => headers} = head}
      when map_size(head) == 2 and is_integer(status) and status in 100..599 and
             is_list(headers) ->
        if Enum.all?(headers, &header_pair?/1),
          do: {:ok, %{kind: :head, status: status, headers: Enum.map(headers, &List.to_tuple/1)}},
          else: {:error, :malformed}

      _other ->
        {:error, :malformed}
    end
  end

  defp read_plaintext(:chunk, body) when byte_size(body) > @max_chunk_bytes,
    do: {:error, :frame_too_large}

  defp read_plaintext(:chunk, body), do: {:ok, %{kind: :chunk, body: body}}
  defp read_plaintext(:end, ""), do: {:ok, %{kind: :end}}
  defp read_plaintext(:end, _plaintext), do: {:error, :malformed}

  defp read_plaintext(:error, plaintext) do
    case Jason.decode(plaintext) do
      {:ok, %{"type" => type, "message" => message} = error}
      when map_size(error) == 2 and is_binary(type) and type != "" and is_binary(message) and
             byte_size(message) <= @max_frame_message_bytes ->
        {:ok, %{kind: :error, type: type, message: message}}

      _other ->
        {:error, :malformed}
    end
  end

  defp header_pair?([name, value]) when is_binary(name) and is_binary(value), do: true
  defp header_pair?(_pair), do: false

  defp chunk_within(:chunk, plaintext) when byte_size(plaintext) > @max_chunk_bytes,
    do: {:error, :frame_too_large}

  defp chunk_within(_kind, _plaintext), do: :ok

  defp frame_message(call_id, seq, kind),
    do: %{call_id: call_id, seq: seq, kind: Atom.to_string(kind)}

  @doc "The header for a host call of `body`, signed with the attempt's call key."
  @spec host_call_header(binary(), host_call(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def host_call_header(call_key, call, body) when is_binary(body),
    do: MacEnvelope.header(@call, call_key, call, body)

  @doc """
  A host call's authenticated fields, re-deriving its attempt's call key
  from `root`. `now` is the current time in Unix milliseconds and
  `standing` what the verifying member holds (`t:standing/0`).
  """
  @spec verify_host_call(binary(), term(), binary(), integer(), standing()) ::
          {:ok, host_call()} | {:error, call_refusal()}
  def verify_host_call(root, header, body, now, %{} = standing)
      when byte_size(root) == 32 and is_binary(body) and is_integer(now) do
    with {:ok, call, mac} <- MacEnvelope.parse(@call, header),
         :ok <- within_window(call.ts, now),
         :ok <- authentic(@call, derived(&attempt_call_key(root, &1), call), call, mac, body),
         :ok <- addressed_here(call, standing) do
      {:ok, fields(call)}
    end
  end

  @doc """
  A host call's authenticated fields and the body hash its header names,
  verified before the body is read: the same refusals as
  `verify_host_call/5`, in the same order, over the header alone. The
  caller then reads the body, bounded, and checks it with `verify_body/2`;
  together the two answer exactly what `verify_host_call/5` does.
  """
  @spec verify_host_call_header(binary(), term(), integer(), standing()) ::
          {:ok, host_call(), body_hash()} | {:error, call_refusal()}
  def verify_host_call_header(root, header, now, %{} = standing)
      when byte_size(root) == 32 and is_integer(now) do
    with {:ok, call, mac} <- MacEnvelope.parse(@call, header),
         :ok <- within_window(call.ts, now),
         :ok <- authentic_header(@call, derived(&attempt_call_key(root, &1), call), call, mac),
         :ok <- addressed_here(call, standing) do
      {:ok, fields(call), call.body_hash}
    end
  end

  @doc """
  A host call's fields and the body hash its header names, verified under
  `call_key`, the attempt's call key as its holder has it, before the body
  is read: `:unknown_version`, `:malformed`, `:outside_window` and
  `:bad_mac`, in `verify_host_call_header/4`'s order. The generation and
  the member are not checked here: they are the verifying member's
  standing, which only CYFR holds. `verify_body/2` completes it.
  """
  @spec verify_host_call_header_under(binary(), term(), integer()) ::
          {:ok, host_call(), body_hash()} | {:error, dispatch_refusal()}
  def verify_host_call_header_under(call_key, header, now)
      when byte_size(call_key) == 32 and is_integer(now) do
    with {:ok, call, mac} <- MacEnvelope.parse(@call, header),
         :ok <- within_window(call.ts, now),
         :ok <- authentic_header(@call, call_key, call, mac) do
      {:ok, fields(call), call.body_hash}
    end
  end

  @doc """
  The most bytes a host call's header spans: `v1 kind=call`, every field
  at its longest (a string field's 256 bytes, an integer field's 16
  decimal digits), the body hash and the MAC.
  """
  @spec max_host_call_header_bytes() :: pos_integer()
  def max_host_call_header_bytes, do: @max_call_header_bytes

  @doc """
  Whether `body` is the one a verified header named by `body_hash`. A
  body that is not is `{:error, :bad_mac}`: the header authenticated a
  different body, which is what `verify_host_call/5`, `verify_request/4`
  and `verify_report/4` answer for it.
  """
  @spec verify_body(body_hash(), binary()) :: :ok | {:error, :bad_mac}
  def verify_body(body_hash, body) when is_binary(body_hash) and is_binary(body) do
    if MacEnvelope.verify_body(@call, %{body_hash: body_hash}, body),
      do: :ok,
      else: {:error, :bad_mac}
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
      {:ok, fields(fields)}
    end
  end

  @doc """
  A WorkerAPI request's authenticated fields and the body hash its header
  names, verified before the body is read (`verify_body/2` completes it).
  """
  @spec verify_request_header(binary(), term(), integer()) ::
          {:ok, dispatch(), body_hash()} | {:error, dispatch_refusal()}
  def verify_request_header(dispatch_key, header, now) when byte_size(dispatch_key) == 32 do
    with {:ok, fields, mac} <- dispatch_fields(@request, header, now),
         :ok <- authentic_header(@request, dispatch_key, fields, mac) do
      {:ok, fields(fields), fields.body_hash}
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
         worker_key = derived(&worker_key(root, &1.service), fields),
         :ok <- authentic(@report, dispatch_key(worker_key), fields, mac, body) do
      {:ok, fields(fields)}
    end
  end

  @doc """
  A worker service report's authenticated fields and the body hash its
  header names, verified before the body is read (`verify_body/2`
  completes it).
  """
  @spec verify_report_header(binary(), term(), integer()) ::
          {:ok, dispatch(), body_hash()} | {:error, dispatch_refusal()}
  def verify_report_header(root, header, now) when byte_size(root) == 32 do
    with {:ok, fields, mac} <- dispatch_fields(@report, header, now),
         worker_key = derived(&worker_key(root, &1.service), fields),
         :ok <- authentic_header(@report, dispatch_key(worker_key), fields, mac) do
      {:ok, fields(fields), fields.body_hash}
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
    |> Prima.JCS.encode()
  end

  # The attempt sealed keys name: exactly its six fields, each of its type.
  # `Prima.MacEnvelope.open/5` checks their values.
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

  defp authentic_header(envelope, key, fields, mac) do
    if MacEnvelope.verify_header(envelope, key, fields, mac), do: :ok, else: {:error, :bad_mac}
  end

  # A header's authenticated fields are its message fields; the body hash
  # it names is framing, answered beside them by the header-first verifiers.
  defp fields(parsed), do: Map.delete(parsed, :body_hash)

  # The generation before the member, so a call from a retired generation
  # of this member reads as the stale call it is rather than as a
  # misrouted one.
  defp addressed_here(call, %{generation: generation, member: member})
       when is_integer(generation) and is_binary(member) do
    cond do
      call.generation != generation -> {:error, :generation_mismatch}
      call.member != member -> {:error, :member_mismatch}
      true -> :ok
    end
  end
end
