# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.BuilderProtocol do
  @moduledoc """
  The wire between CYFR's build client (`Compendium.Builds.Client`, reached
  through `CYFR_LOCUS_BUILDS_KEY` beside `CYFR_LOCUS_BACKENDS_URL`) and the
  builder Locus serves (`LOCUS_BUILDS_*`, `Locus.Config`): the shapes each
  end writes and reads, the bounds each holds the other to, and how a
  request is authenticated. Data and codec only — no process and no HTTP
  live here. `tests/fixtures/locus_builds.json` holds the vectors every
  consumer must reproduce.

  ## Operations

  Every operation is a `POST` to its route (`route/1`) with a JSON body,
  and every body — request, answer and refusal alike — carries
  `"version"` (`version/0`). A body at another version, or without one,
  is read as `{:error, {:version, presented}}` and answered with a
  `protocol_mismatch` refusal naming both versions (`refusal_for/1`).

  | Operation | Route | Body | Answer |
  |---|---|---|---|
  | `:build` | `/locus/v1/builds/build` | a request | lines: progress and output, then one result or refusal |
  | `:health` | `/locus/v1/builds/health` | `{"version": 3}` | one health line, or a refusal |

  A build's answer is a stream of newline-delimited JSON lines
  (`encode_progress/2`, `encode_output/3`, `read_line/1`): progress lines
  as the build runs and output lines as its files leave it, then exactly
  one terminal line, a result or a refusal. The terminal line ends the
  answer: a reader reads nothing after it and closes the connection there.
  Every line, with its newline, is at most `max_line_size/0`, and each
  type is held to its own bound besides. The builder charges its progress
  lines, as encoded with their newlines, to `max_log_bytes/0`; a reader
  that keeps them as the build's log keeps at most that. No terminal line
  carries the log: the progress
  lines are the build's diagnostics, each `stage: message`
  (`diagnostic/2`). A refusal the builder can make before the build starts
  — malformed, unauthorized, protocol mismatch, capacity, unavailable — is
  answered at its class's HTTP status (`status/1`) as the one line of the
  body; a refusal reached once the stream began travels as its terminal
  line under the 200 the stream opened with, after whatever output lines
  went before it, which a reader then keeps nothing of. A client reads
  lines whatever the status and lets the terminal line decide. `health`
  answers without authentication, so a liveness probe needs no key; every
  other answer follows a verified request.

  ## The request (`encode_request/1`, `read_request/1`)

  `{version, athanor_id, language, target_type, resolve, deadline,
  sources}`. `athanor_id` is the tenant the build is for, of the grammar
  every Locus wire gives an athanor's id
  (`Prima.RunnerControl.athanor_id_pattern/0`), which the builder keys its
  per-athanor slot and the build's place on and keeps nothing else about.
  `language` is `rust` or `javascript` and `target_type` a component type,
  paired as `language_for/1` says. `resolve` asks a Rust build to resolve its crate
  graph afresh. `deadline` is the absolute instant, in Unix milliseconds,
  by which the build must have finished: the builder's budget is the time
  to it or its own ceiling, whichever is less, and a deadline already
  passed is refused as `timeout`. `sources` is a list of
  `{path, base64}`, at most `max_source_files/0` files and
  `max_source_bytes/0` decoded bytes in all, every path relative and safe
  (`Prima.PathSafety`) and named once.

  ## The outputs and the result

  A build's files leave it as output lines, `{version, type: "output",
  path, seq, bytes}`: `bytes` is base64 of a chunk of the file at `path`
  of at least one byte and at most `max_chunk_bytes/0`, and the line with
  its newline is at most `max_output_line_bytes/0`. `seq` numbers the
  answer's output lines 1, 2, 3 in order; a file's lines are consecutive
  and a path once left never comes back; a file of no bytes sends no line.
  At most `max_output_files/0` paths and `max_output_bytes/0` bytes in
  all, each path at most `max_output_path_bytes/0` bytes, safe
  (`Prima.PathSafety`) and with no control character.

  `{version, type: "result", language, target_type, outputs}` ends a
  build that made its files: `outputs` names each of its files once, with
  its `size` and its `digest`, the `Prima.Digest.sha256/1` of its bytes in
  order. It names every path the output lines sent, at the size and digest
  of the bytes they carried, and any other only as a file of no bytes, of
  size 0 and the digest of no bytes, which is how such a file is carried;
  a path of more bytes that no line sent is `unsent`. `outputs` is read as
  a set: its order is not the lines' and means nothing. The line is at
  most `max_result_line_bytes/0`. A component build's outputs are
  `component_wasm/0` and, when the build left one, `component_lockfile/0`;
  a tincture's are its files. The builder is another trust domain: the
  reader holds the lines to these rules as they arrive (`outputs/0`,
  `output/2`, `outputs/2`) and keeps what they carried only once a result
  names them, and the client still validates a component's bytes and
  derives the digest it registers under itself.

  ## Refusals

  `{version, type: "refusal", class, reason}`, one class per way a build
  does not happen, each with a reason of its own shape:

  | Class | Reason | When |
  |---|---|---|
  | `malformed` | a sentence | the body does not read (`describe/1`) |
  | `unauthorized` | `unknown_version`, `malformed`, `outside_window`, `bad_mac` or `replayed` | the header does not verify, or its nonce was seen |
  | `capacity` | `{max}` | every slot of the cap is taken |
  | `timeout` | `{budget_ms}` | the build passed its budget |
  | `memory` | `{limit_bytes}` or `{cause}` | the build was ended for memory: at its bound, or by `cause` (`machine` or `either`) |
  | `no_memory` | `held` (`Prima.LocusPool.read_held/1`) | the keeper found no room for the build within its wait, and says what holds the memory |
  | `unavailable` | a sentence naming what | a toolchain or the keeper is missing |
  | `failed` | `{status}` or `{signal}` | the build ran and did not produce its output |
  | `protocol_mismatch` | `{builder, client}` | the request's version is not `version/0` |

  `memory` is the builder's report that the kernel ended the build's
  sandbox for memory. `{limit_bytes}` says it reached the bound the builder
  runs every build under: its processes, what it wrote to its home and the
  kernel memory charged to it, together. `{cause}` is an end that is not
  known to be at that bound and names no bytes: `machine` is a limit above
  it, the container's or the machine's, and `either` is one of the two
  where the kernel's counters do not say which. The builder answers the
  class only when its keeper read that end from those counters; a build
  killed for any other reason is `failed` with its signal.

  `no_memory` is the keeper's refusal of the build's place for room, its
  `held` as the keeper gave it: the charges of the build's own athanor by
  kind and everyone else's as one sum, which `describe_refusal/1` says in
  `Prima.LocusPool.refusal_sentence/1`'s one sentence. Nothing of it ran.

  ## Authentication

  One 32-byte key per Locus service (`LOCUS_BUILDS_KEY`, 64 hexadecimal
  digits, `Prima.MacEnvelope.decode_root/1`) is shared by CYFR and the
  builder. The key a request is signed with is derived from it over the
  service's label, `cyfr-locus/v1/builds` (`request_key/1`), and the
  signature is `Prima.MacEnvelope`'s over that label as its prefix, the
  kind `request`, a timestamp in Unix milliseconds, a nonce and the body's hash, carried in the `x-cyfr-auth`
  header (`auth_header/0`). The domain `cyfr-locus/v1` is shared with
  every Locus service; the label names one, so neither the key nor a
  header of another service (`backends`) verifies a build request. A
  listener verifies the header before it reads the body
  (`verify_request_header/3`, then `verify_body/2`), bounded by
  `max_request_bytes/0`, and refuses, in order, `:unknown_version` (a
  version token other than `v1`, such as `v2`), `:malformed`, `:outside_window` (`ts`
  further than `window_ms/0` from its clock) and `:bad_mac`. Replay is the listener's, against state this module does not
  hold: a nonce seen within the window is refused as `replayed`. Answers
  are not signed: they travel on the connection the verified request
  opened, and the client believes nothing in them it can check itself.
  """

  alias Prima.{MacEnvelope, RunnerControl}

  @version 3
  @domain MacEnvelope.domain()
  @service MacEnvelope.service(:builds)
  @label MacEnvelope.label(:builds)
  @auth_header MacEnvelope.auth_header()
  @window_ms 30_000
  @routes %{build: "/locus/v1/builds/build", health: "/locus/v1/builds/health"}

  @max_source_bytes 1_048_576
  @max_source_files 512
  @max_request_bytes 2_000_000
  @max_output_bytes 64 * 1_048_576
  @max_output_files 500
  @max_output_path_bytes 1024
  @max_output_line_bytes 1_048_576
  @max_line_bytes 65_536
  @max_log_bytes 2_000_000
  @max_text_bytes 256
  # A path's control characters: C0 and DEL, each six bytes once escaped.
  @control_bytes Enum.map(Enum.concat(0x00..0x1F, [0x7F]), &<<&1>>)

  @no_bytes_digest Prima.Digest.sha256("")

  @component_wasm "component.wasm"
  @component_lockfile "Cargo.lock"

  @languages [:rust, :javascript]
  @languages_by_type %{reagent: :rust, catalyst: :rust, formula: :rust, tincture: :javascript}
  @target_types Map.keys(@languages_by_type)
  @stages [:preparing, :compiling, :validating, :output]
  @classes [
    :malformed,
    :unauthorized,
    :capacity,
    :timeout,
    :memory,
    :no_memory,
    :unavailable,
    :failed,
    :protocol_mismatch
  ]
  @unauthorized_reasons [:unknown_version, :malformed, :outside_window, :bad_mac, :replayed]
  @line_types [:progress, :output, :result, :refusal, :health]

  @statuses %{
    malformed: 400,
    unauthorized: 401,
    protocol_mismatch: 409,
    failed: 422,
    capacity: 429,
    unavailable: 503,
    no_memory: 423,
    timeout: 504,
    memory: 507
  }

  # The pairing is declared here once; a component type the roster gains
  # without a language is a compile error, not a request refused at runtime.
  if Enum.sort(@target_types) != Enum.sort(Prima.ComponentRef.valid_type_atoms()) do
    raise "Prima.BuilderProtocol pairs #{inspect(@target_types)} with a language, " <>
            "but Prima.ComponentRef's types are #{inspect(Prima.ComponentRef.valid_type_atoms())}"
  end

  @request_fields ~w(version athanor_id language target_type resolve deadline sources)
  @health_request_fields ~w(version)
  @progress_fields ~w(version type stage message)
  @output_line_fields ~w(version type path seq bytes)
  @result_fields ~w(version type language target_type outputs)
  @refusal_fields ~w(version type class reason)
  @health_fields ~w(version type release toolchains)
  @source_fields ~w(path base64)
  @output_fields ~w(path size digest)
  @toolchain_fields ~w(available command description)

  # The bounds of a line, derived from the encoder itself (see
  # `max_chunk_bytes/0` and `max_result_line_bytes/0`). The most output
  # lines an answer can hold: one a byte.
  @max_seq @max_output_bytes
  # An output line with an empty path and no bytes, at the largest seq,
  # with its newline; its path escapes to at most two bytes a byte, since
  # it holds no control character.
  @output_envelope_bytes %{
                           "version" => @version,
                           "type" => "output",
                           "path" => "",
                           "seq" => @max_seq,
                           "bytes" => ""
                         }
                         |> Jason.encode!()
                         |> byte_size()
                         |> Kernel.+(1 + 2 * @max_output_path_bytes)
  @max_chunk_bytes 3 * div(@max_output_line_bytes - @output_envelope_bytes, 4)
  # One result entry with an empty path at the largest size, and the comma
  # after it, its path escaped as an output line's is.
  @result_entry_bytes %{
                        "path" => "",
                        "size" => @max_output_bytes,
                        "digest" => @no_bytes_digest
                      }
                      |> Jason.encode!()
                      |> byte_size()
                      |> Kernel.+(1 + 2 * @max_output_path_bytes)
  # The result with no output, at its longest language and type, with its
  # newline.
  @result_envelope_bytes @languages_by_type
                         |> Enum.map(fn {type, language} ->
                           %{
                             "version" => @version,
                             "type" => "result",
                             "language" => Atom.to_string(language),
                             "target_type" => Atom.to_string(type),
                             "outputs" => []
                           }
                           |> Jason.encode!()
                           |> byte_size()
                           |> Kernel.+(1)
                         end)
                         |> Enum.max()
  @max_result_line_bytes @result_envelope_bytes + @max_output_files * @result_entry_bytes
  # A progress line's message and a refusal's sentence escape to at most
  # six bytes a byte; health is far smaller. Every line is within the
  # larger of an output line and a result.
  @max_line_size max(@max_output_line_bytes, @max_result_line_bytes)

  @request %MacEnvelope{
    prefix: @label,
    kind: "request",
    fields: [ts: :integer, nonce: :string]
  }

  @type language :: :rust | :javascript
  @type target_type :: :reagent | :catalyst | :formula | :tincture
  @type stage :: :preparing | :compiling | :validating | :output
  @type operation :: :build | :health

  @typedoc "A build request as the client writes it and the builder reads it."
  @type request :: %{
          athanor_id: String.t(),
          language: language(),
          target_type: target_type(),
          resolve: boolean(),
          deadline: non_neg_integer(),
          sources: %{String.t() => binary()}
        }

  @typedoc "One file a result names: its path, its size and the digest of its bytes."
  @type output :: %{path: String.t(), size: non_neg_integer(), digest: String.t()}

  @typedoc "A finished build: its files, each named once, in no order a reader reads."
  @type result :: %{language: language(), target_type: target_type(), outputs: [output()]}

  @typedoc "One chunk of a file, of at least one byte, the `seq`th output line of its answer."
  @type chunk :: %{path: String.t(), seq: pos_integer(), bytes: binary()}

  @typedoc """
  The output lines read so far, held to the stream's rules (`output/2`):
  the files whole, their sizes and running digests, by path, and the path
  the last line named.
  """
  @opaque outputs :: %{
            seq: non_neg_integer(),
            bytes: non_neg_integer(),
            current: String.t() | nil,
            files: %{
              String.t() => %{
                chunks: iodata(),
                size: non_neg_integer(),
                hash: Prima.Digest.sha256_state()
              }
            }
          }

  @typedoc "What one toolchain reports on a health answer."
  @type toolchain :: %{available: boolean(), command: String.t(), description: String.t()}

  @typedoc "A health answer: the builder's release and its toolchains by language."
  @type health :: %{release: String.t(), toolchains: %{language() => toolchain()}}

  @typedoc "A refusal by class, each with its typed reason."
  @type refusal ::
          {:malformed, String.t()}
          | {:unauthorized,
             :unknown_version | :malformed | :outside_window | :bad_mac | :replayed}
          | {:capacity, pos_integer()}
          | {:timeout, non_neg_integer()}
          | {:memory, pos_integer() | :machine | :either}
          | {:no_memory, Prima.LocusPool.held()}
          | {:unavailable, String.t()}
          | {:failed, {:status, integer()} | {:signal, String.t()}}
          | {:protocol_mismatch, pos_integer(), pos_integer() | nil}

  @typedoc "One line of an answer."
  @type line ::
          {:progress, stage(), String.t()}
          | {:output, chunk()}
          | {:result, result()}
          | {:refusal, refusal()}
          | {:health, health()}

  @typedoc """
  Why a body does not read: not a JSON object; another protocol version
  (or none); a field the shape does not have, lacks or does not accept
  (named by its path, `sources[2].path`); a language and type not built
  together; a bound passed (what, the size seen, the bound); a path named
  twice or unsafe; an output line of no bytes (`:empty_chunk`, by its
  path); a stream of output lines that breaks its rules: a line out of its
  order, a path come back to, a result that names other paths than those
  sent (`:unsent` for one of more bytes never sent, `:unnamed` for one sent
  and not named) or another size or digest than theirs.
  """
  @type read_error ::
          :not_json
          | {:version, term()}
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unpaired, language(), target_type()}
          | {:too_large, :request | :sources | :outputs | :chunk | :log | :line,
             non_neg_integer(), pos_integer()}
          | {:too_many, :sources | :outputs, non_neg_integer(), pos_integer()}
          | {:duplicate_path, String.t()}
          | {:unsafe_path, String.t()}
          | {:empty_chunk, String.t()}
          | {:out_of_order, pos_integer(), pos_integer()}
          | {:path_revisited, String.t()}
          | {:unsent, String.t()}
          | {:unnamed, String.t()}
          | {:size_mismatch, String.t()}
          | {:digest_mismatch, String.t()}

  @typedoc "A request header's fields: the timestamp in Unix milliseconds and a nonce."
  @type auth :: %{ts: non_neg_integer(), nonce: String.t()}

  @type auth_refusal :: :unknown_version | :malformed | :outside_window | :bad_mac

  @typedoc "The hex SHA-256 a verified header names as its body's."
  @type body_hash :: String.t()

  # ————— the protocol as data —————

  @doc "The protocol this release speaks, carried in every body."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "This release's version, as a health answer reports it."
  @spec release() :: String.t()
  def release, do: Prima.Version.current()

  @doc "The MAC domain every Locus service signs under."
  @spec domain() :: String.t()
  def domain, do: @domain

  @doc "This service's label within the domain."
  @spec service() :: String.t()
  def service, do: @service

  @doc "The HTTP header a request's signature travels in, lowercase."
  @spec auth_header() :: String.t()
  def auth_header, do: @auth_header

  @doc "How far a header's `ts` may be from the verifier's clock, in milliseconds, either side."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "The route an operation is posted to."
  @spec route(operation()) :: String.t()
  def route(operation) when is_map_key(@routes, operation), do: Map.fetch!(@routes, operation)

  @doc "Every route by operation."
  @spec routes() :: %{operation() => String.t()}
  def routes, do: @routes

  @doc "The operation a path names, or `:error` for a path that is no route."
  @spec operation(String.t()) :: {:ok, operation()} | :error
  def operation(path) when is_binary(path) do
    case Enum.find(@routes, fn {_operation, route} -> route == path end) do
      {operation, _route} -> {:ok, operation}
      nil -> :error
    end
  end

  @doc "The HTTP status a refusal made before the stream began is answered at."
  @spec status(refusal() | atom()) :: pos_integer()
  def status(refusal) when is_tuple(refusal), do: status(elem(refusal, 0))
  def status(class) when is_map_key(@statuses, class), do: Map.fetch!(@statuses, class)

  @doc "Every refusal class."
  @spec classes() :: [atom()]
  def classes, do: @classes

  @doc "The toolchain languages a builder speaks."
  @spec languages() :: [language()]
  def languages, do: @languages

  @doc "The stages a progress line names."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc "The language a component type is built from: Rust, and JavaScript for a tincture."
  @spec language_for(target_type()) :: language()
  def language_for(type) when is_map_key(@languages_by_type, type),
    do: Map.fetch!(@languages_by_type, type)

  @doc "The path a component build's WASM output takes among a result's outputs."
  @spec component_wasm() :: String.t()
  def component_wasm, do: @component_wasm

  @doc "The path a component build's lockfile takes among a result's outputs, when it left one."
  @spec component_lockfile() :: String.t()
  def component_lockfile, do: @component_lockfile

  @doc "The decoded bytes one request's sources may total."
  @spec max_source_bytes() :: pos_integer()
  def max_source_bytes, do: @max_source_bytes

  @doc "The files one request may carry."
  @spec max_source_files() :: pos_integer()
  def max_source_files, do: @max_source_files

  @doc "The bytes a request body may be, checked on the declared size before anything else."
  @spec max_request_bytes() :: pos_integer()
  def max_request_bytes, do: @max_request_bytes

  @doc "The decoded bytes one result's outputs may total."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc "The files one result may carry."
  @spec max_output_files() :: pos_integer()
  def max_output_files, do: @max_output_files

  @doc "The bytes one output's path may be, counted before it is split into segments."
  @spec max_output_path_bytes() :: pos_integer()
  def max_output_path_bytes, do: @max_output_path_bytes

  @doc """
  The bytes one output line may be, its newline included. Its chunk is at
  most `max_chunk_bytes/0`.
  """
  @spec max_output_line_bytes() :: pos_integer()
  def max_output_line_bytes, do: @max_output_line_bytes

  @doc """
  The bytes one output line's chunk may be: the largest chunk whose base64
  fits an output line at its longest, which is the line with its newline,
  its path escaped to two bytes a byte (a path holds no control character,
  and `"` or `\\` is the most any byte of it grows), and the largest `seq`
  an answer can reach, one line a byte.
  """
  @spec max_chunk_bytes() :: pos_integer()
  def max_chunk_bytes, do: @max_chunk_bytes

  @doc """
  The bytes a result line may be, its newline included: the result with no
  output at its longest language and type, and for each of
  `max_output_files/0` entries its keys, its path escaped as an output
  line's is, the largest size, the digest's `sha256:` and 64 hexadecimal
  digits, and a comma.
  """
  @spec max_result_line_bytes() :: pos_integer()
  def max_result_line_bytes, do: @max_result_line_bytes

  @doc """
  The bytes any line of an answer may be, its newline included: the larger
  of an output line and a result line. A progress line's message, a
  refusal's sentence and a health line are bounded far below it.
  """
  @spec max_line_size() :: pos_integer()
  def max_line_size, do: @max_line_size

  @doc "The bytes one progress message, diagnostic line or refusal sentence may be."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc """
  The bytes a build's log may be: its progress lines, each counted as its
  encoded line with its newline, as the builder charges them and a reader
  keeping them holds them to.
  """
  @spec max_log_bytes() :: pos_integer()
  def max_log_bytes, do: @max_log_bytes

  # ————— authentication —————

  @doc "The key build requests are signed with, derived from the service key over this service's label."
  @spec request_key(binary()) :: binary()
  def request_key(key) when byte_size(key) == 32, do: MacEnvelope.derive(key, @label)

  @doc "The `x-cyfr-auth` header for a request of `body`, signed with the request key."
  @spec request_header(binary(), auth(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def request_header(request_key, auth, body)
      when byte_size(request_key) == 32 and is_map(auth) and is_binary(body),
      do: MacEnvelope.header(@request, request_key, auth, body)

  @doc "The canonical string a request's signature covers."
  @spec canonical(auth(), binary()) :: {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def canonical(auth, body) when is_map(auth) and is_binary(body),
    do: MacEnvelope.canonical(@request, auth, body)

  @doc """
  A request's authenticated fields under the request key, or the first
  refusal: `:unknown_version`, `:malformed`, `:outside_window`, `:bad_mac`. `now` is in Unix
  milliseconds.
  """
  @spec verify_request(binary(), term(), binary(), integer()) ::
          {:ok, auth()} | {:error, auth_refusal()}
  def verify_request(request_key, header, body, now)
      when byte_size(request_key) == 32 and is_binary(body) and is_integer(now) do
    with {:ok, fields, mac} <- parsed(header, now),
         :ok <- authentic(MacEnvelope.verify(@request, request_key, fields, mac, body)) do
      {:ok, Map.delete(fields, :body_hash)}
    end
  end

  @doc """
  A request's authenticated fields and the body hash its header names,
  verified before the body is read: the same refusals as
  `verify_request/4`, in the same order, over the header alone.
  `verify_body/2` then checks the body read afterwards, and the pair
  refuses exactly what the one-step verifier refuses.
  """
  @spec verify_request_header(binary(), term(), integer()) ::
          {:ok, auth(), body_hash()} | {:error, auth_refusal()}
  def verify_request_header(request_key, header, now)
      when byte_size(request_key) == 32 and is_integer(now) do
    with {:ok, fields, mac} <- parsed(header, now),
         :ok <- authentic(MacEnvelope.verify_header(@request, request_key, fields, mac)) do
      {:ok, Map.delete(fields, :body_hash), fields.body_hash}
    end
  end

  @doc "Whether `body` is the one a verified header named; another is `{:error, :bad_mac}`."
  @spec verify_body(body_hash(), binary()) :: :ok | {:error, :bad_mac}
  def verify_body(body_hash, body) when is_binary(body_hash) and is_binary(body) do
    if MacEnvelope.verify_body(@request, %{body_hash: body_hash}, body),
      do: :ok,
      else: {:error, :bad_mac}
  end

  defp parsed(header, now) do
    with {:ok, fields, mac} <- MacEnvelope.parse(@request, header),
         :ok <- within_window(fields.ts, now) do
      {:ok, fields, mac}
    end
  end

  defp within_window(ts, now) when abs(ts - now) <= @window_ms, do: :ok
  defp within_window(_ts, _now), do: {:error, :outside_window}

  defp authentic(true), do: :ok
  defp authentic(false), do: {:error, :bad_mac}

  # ————— the request —————

  @doc "Whether a request body of `bytes` may be read at all, before any of it is."
  @spec admit_request_bytes(non_neg_integer()) ::
          :ok | {:error, {:too_large, :request, non_neg_integer(), pos_integer()}}
  def admit_request_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    if bytes <= @max_request_bytes,
      do: :ok,
      else: {:error, {:too_large, :request, bytes, @max_request_bytes}}
  end

  @doc "The body of a build request, checked as `read_request/1` will check it."
  @spec encode_request(request()) :: {:ok, binary()} | {:error, read_error()}
  def encode_request(%{
        athanor_id: athanor_id,
        language: language,
        target_type: target_type,
        resolve: resolve,
        deadline: deadline,
        sources: sources
      })
      when is_atom(language) and is_atom(target_type) and is_map(sources) do
    wire = %{
      "version" => @version,
      "athanor_id" => athanor_id,
      "language" => Atom.to_string(language),
      "target_type" => Atom.to_string(target_type),
      "resolve" => resolve,
      "deadline" => deadline,
      "sources" => files(sources)
    }

    with {:ok, _request} <- read_request_wire(wire),
         body = Jason.encode!(wire),
         :ok <- admit_request_bytes(byte_size(body)) do
      {:ok, body}
    end
  end

  @doc "A build request's body, read strictly: the declared size, then every field and bound."
  @spec read_request(binary()) :: {:ok, request()} | {:error, read_error()}
  def read_request(body) when is_binary(body) do
    with :ok <- admit_request_bytes(byte_size(body)),
         {:ok, wire} <- object(body) do
      read_request_wire(wire)
    end
  end

  defp read_request_wire(wire) do
    with :ok <- current_version(wire),
         :ok <- exact(wire, @request_fields, ""),
         {:ok, athanor_id} <- athanor_field(wire),
         {:ok, language, target_type} <- pairing(wire),
         {:ok, resolve} <- boolean_field(wire, "resolve"),
         {:ok, deadline} <- integer_field(wire, "deadline"),
         {:ok, sources} <-
           files_field(wire, "sources", :sources, @max_source_files, @max_source_bytes) do
      {:ok,
       %{
         athanor_id: athanor_id,
         language: language,
         target_type: target_type,
         resolve: resolve,
         deadline: deadline,
         sources: sources
       }}
    end
  end

  @doc "The body of a health request."
  @spec encode_health_request() :: binary()
  def encode_health_request, do: Jason.encode!(%{"version" => @version})

  @doc "A health request's body, read strictly."
  @spec read_health_request(binary()) :: :ok | {:error, read_error()}
  def read_health_request(body) when is_binary(body) do
    with :ok <- admit_request_bytes(byte_size(body)),
         {:ok, wire} <- object(body),
         :ok <- current_version(wire),
         :ok <- exact(wire, @health_request_fields, "") do
      :ok
    end
  end

  # ————— the answer —————

  @doc "One progress line of a build's answer."
  @spec encode_progress(stage(), String.t()) :: {:ok, binary()} | {:error, read_error()}
  def encode_progress(stage, message) when is_atom(stage) and is_binary(message) do
    encode_line(%{
      "version" => @version,
      "type" => "progress",
      "stage" => Atom.to_string(stage),
      "message" => message
    })
  end

  @doc """
  A progress line as the build's log keeps it, `stage: message`: what a
  person reads of the build, in the order its lines came.
  """
  @spec diagnostic(stage(), String.t()) :: String.t()
  def diagnostic(stage, message) when is_atom(stage) and is_binary(message),
    do: "#{stage}: #{message}"

  @doc """
  The `seq`th output line of an answer: a chunk of the file at `path`,
  checked as `read_line/1` will check it, without decoding it back.
  """
  @spec encode_output(String.t(), pos_integer(), binary()) ::
          {:ok, binary()} | {:error, read_error()}
  def encode_output(path, seq, bytes)
      when is_binary(path) and is_integer(seq) and is_binary(bytes) do
    with :ok <- output_path(path, ""),
         {:ok, path} <- safe_path(path, ""),
         :ok <- seq_bound(seq),
         :ok <- chunk_bound(byte_size(bytes)),
         :ok <- some_bytes(path, bytes) do
      {:ok,
       Jason.encode!(%{
         "version" => @version,
         "type" => "output",
         "path" => path,
         "seq" => seq,
         "bytes" => Base.encode64(bytes)
       })}
    end
  end

  @doc "The terminal line of a finished build, checked as `read_line/1` will check it."
  @spec encode_result(result()) :: {:ok, binary()} | {:error, read_error()}
  def encode_result(%{language: language, target_type: target_type, outputs: outputs})
      when is_atom(language) and is_atom(target_type) and is_list(outputs) do
    encode_line(%{
      "version" => @version,
      "type" => "result",
      "language" => Atom.to_string(language),
      "target_type" => Atom.to_string(target_type),
      "outputs" =>
        Enum.map(outputs, fn %{path: path, size: size, digest: digest} ->
          %{"path" => path, "size" => size, "digest" => digest}
        end)
    })
  end

  @doc "The one line of a refusal."
  @spec encode_refusal(refusal()) :: {:ok, binary()} | {:error, read_error()}
  def encode_refusal(refusal) when is_tuple(refusal) do
    encode_line(%{
      "version" => @version,
      "type" => "refusal",
      "class" => Atom.to_string(elem(refusal, 0)),
      "reason" => reason_wire(refusal)
    })
  end

  @doc "The one line of a health answer."
  @spec encode_health(health()) :: {:ok, binary()} | {:error, read_error()}
  def encode_health(%{release: release, toolchains: toolchains}) when is_map(toolchains) do
    encode_line(%{
      "version" => @version,
      "type" => "health",
      "release" => release,
      "toolchains" =>
        Map.new(toolchains, fn {language, toolchain} ->
          {Atom.to_string(language),
           %{
             "available" => toolchain.available,
             "command" => toolchain.command,
             "description" => toolchain.description
           }}
        end)
    })
  end

  @doc """
  One line of an answer, without its newline, read strictly by its
  `type`: first within `max_line_size/0`, then within its type's bound.
  """
  @spec read_line(binary()) :: {:ok, line()} | {:error, read_error()}
  def read_line(line) when is_binary(line) do
    bytes = byte_size(line) + 1

    with :ok <- line_bound(bytes, @max_line_size),
         {:ok, wire} <- object(line),
         {:ok, read} <- read_line_wire(wire),
         :ok <- typed_bound(read, bytes) do
      {:ok, read}
    end
  end

  defp typed_bound({:output, _chunk}, bytes), do: line_bound(bytes, @max_output_line_bytes)
  defp typed_bound({:result, _result}, bytes), do: line_bound(bytes, @max_result_line_bytes)
  defp typed_bound(_line, _bytes), do: :ok

  defp line_bound(bytes, max) when bytes > max, do: {:error, {:too_large, :line, bytes, max}}
  defp line_bound(_bytes, _max), do: :ok

  defp encode_line(wire) do
    with {:ok, _line} <- read_line_wire(wire), do: {:ok, Jason.encode!(wire)}
  end

  defp read_line_wire(wire) do
    with :ok <- current_version(wire),
         {:ok, type} <- roster_field(wire, "type", @line_types) do
      read_typed(type, wire)
    end
  end

  defp read_typed(:progress, wire) do
    with :ok <- exact(wire, @progress_fields, ""),
         {:ok, stage} <- roster_field(wire, "stage", @stages),
         {:ok, message} <- line_field(wire, "message") do
      {:ok, {:progress, stage, message}}
    end
  end

  defp read_typed(:output, wire) do
    with :ok <- exact(wire, @output_line_fields, ""),
         :ok <- output_path(wire["path"], ""),
         {:ok, path} <- safe_path(wire["path"], ""),
         {:ok, seq} <- seq_field(wire),
         {:ok, bytes} <- chunk_field(wire),
         :ok <- some_bytes(path, bytes) do
      {:ok, {:output, %{path: path, seq: seq, bytes: bytes}}}
    end
  end

  defp read_typed(:result, wire) do
    with :ok <- exact(wire, @result_fields, ""),
         {:ok, language, target_type} <- pairing(wire),
         {:ok, outputs} <- outputs_field(wire["outputs"]),
         :ok <- component_outputs(language, Enum.map(outputs, & &1.path)) do
      {:ok, {:result, %{language: language, target_type: target_type, outputs: outputs}}}
    end
  end

  defp read_typed(:refusal, wire) do
    with :ok <- exact(wire, @refusal_fields, ""),
         {:ok, class} <- roster_field(wire, "class", @classes),
         {:ok, refusal} <- reason(class, wire["reason"]) do
      {:ok, {:refusal, refusal}}
    end
  end

  defp read_typed(:health, wire) do
    with :ok <- exact(wire, @health_fields, ""),
         {:ok, release} <- text_field(wire, "release", @max_text_bytes),
         {:ok, toolchains} <- toolchains_field(wire["toolchains"]) do
      {:ok, {:health, %{release: release, toolchains: toolchains}}}
    end
  end

  # A component's outputs are its WASM and, at most, its lockfile; a
  # tincture's are whatever it built.
  defp component_outputs(:rust, paths) do
    if @component_wasm in paths and paths -- [@component_wasm, @component_lockfile] == [],
      do: :ok,
      else: {:error, {:invalid_field, "outputs"}}
  end

  defp component_outputs(:javascript, _paths), do: :ok

  # ————— the stream of outputs —————

  @doc "No output line read yet."
  @spec outputs() :: outputs()
  def outputs, do: %{seq: 0, bytes: 0, current: nil, files: %{}}

  @doc """
  An output line read after those before it: the next `seq`, of the path
  the last line named or of one not named before, at most
  `max_output_files/0` paths and `max_output_bytes/0` bytes in all. The
  chunk is kept, and its file's size and running digest move on.
  """
  @spec output(outputs(), chunk()) :: {:ok, outputs()} | {:error, read_error()}
  def output(%{} = state, %{path: path, seq: seq, bytes: bytes}) do
    count = map_size(state.files)
    total = state.bytes + byte_size(bytes)

    cond do
      seq != state.seq + 1 ->
        {:error, {:out_of_order, seq, state.seq + 1}}

      path != state.current and is_map_key(state.files, path) ->
        {:error, {:path_revisited, path}}

      path != state.current and count >= @max_output_files ->
        {:error, {:too_many, :outputs, count + 1, @max_output_files}}

      total > @max_output_bytes ->
        {:error, {:too_large, :outputs, total, @max_output_bytes}}

      true ->
        file =
          Map.get(state.files, path, %{chunks: [], size: 0, hash: Prima.Digest.sha256_init()})

        file = %{
          file
          | chunks: [file.chunks, bytes],
            size: file.size + byte_size(bytes),
            hash: Prima.Digest.sha256_update(file.hash, bytes)
        }

        {:ok,
         %{state | seq: seq, bytes: total, current: path, files: Map.put(state.files, path, file)}}
    end
  end

  @doc """
  The files a result names, whole, by path: only when it names every path
  the output lines sent, each at the size and digest of the bytes they
  carried, and any other as a file of no bytes, which it answers empty.
  """
  @spec outputs(outputs(), result()) :: {:ok, %{String.t() => binary()}} | {:error, read_error()}
  def outputs(%{} = state, %{outputs: named}) when is_list(named) do
    with :ok <- all_sent(named, state.files),
         :ok <- all_named(state.files, Enum.map(named, & &1.path)),
         :ok <- each_matches(named, state.files) do
      {:ok, Map.new(named, fn %{path: path} -> {path, kept(state.files, path)} end)}
    end
  end

  # A path no line sent is a file of no bytes, so a size above 0 is a file
  # whose lines never came.
  defp all_sent(named, files) do
    case Enum.find(named, &(&1.size > 0 and not is_map_key(files, &1.path))) do
      nil -> :ok
      %{path: path} -> {:error, {:unsent, path}}
    end
  end

  defp all_named(files, names) do
    case Enum.find(Map.keys(files), &(&1 not in names)) do
      nil -> :ok
      path -> {:error, {:unnamed, path}}
    end
  end

  defp each_matches(named, files) do
    Enum.reduce_while(named, :ok, fn %{path: path, size: size, digest: digest}, :ok ->
      {sent_size, sent_digest} =
        case files do
          %{^path => file} -> {file.size, Prima.Digest.sha256_final(file.hash)}
          %{} -> {0, @no_bytes_digest}
        end

      cond do
        sent_size != size -> {:halt, {:error, {:size_mismatch, path}}}
        sent_digest != digest -> {:halt, {:error, {:digest_mismatch, path}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp kept(files, path) do
    case files do
      %{^path => file} -> IO.iodata_to_binary(file.chunks)
      %{} -> ""
    end
  end

  defp toolchains_field(%{} = wire) do
    with :ok <- exact(wire, Enum.map(@languages, &Atom.to_string/1), "toolchains.") do
      Enum.reduce_while(@languages, {:ok, %{}}, fn language, {:ok, acc} ->
        case toolchain(wire[Atom.to_string(language)], "toolchains.#{language}") do
          {:ok, toolchain} -> {:cont, {:ok, Map.put(acc, language, toolchain)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp toolchains_field(_wire), do: {:error, {:invalid_field, "toolchains"}}

  defp toolchain(%{} = wire, at) do
    with :ok <- exact(wire, @toolchain_fields, at <> "."),
         {:ok, available} <- boolean_field(wire, "available", at <> "."),
         {:ok, command} <- text_field(wire, "command", @max_text_bytes, at <> "."),
         {:ok, description} <- text_field(wire, "description", @max_text_bytes, at <> ".") do
      {:ok, %{available: available, command: command, description: description}}
    end
  end

  defp toolchain(_wire, at), do: {:error, {:invalid_field, at}}

  # ————— refusals —————

  defp reason_wire({:malformed, sentence}), do: sentence
  defp reason_wire({:unauthorized, why}) when is_atom(why), do: Atom.to_string(why)
  defp reason_wire({:capacity, max}), do: %{"max" => max}
  defp reason_wire({:timeout, budget_ms}), do: %{"budget_ms" => budget_ms}

  defp reason_wire({:memory, cause}) when cause in [:machine, :either],
    do: %{"cause" => Atom.to_string(cause)}

  defp reason_wire({:memory, limit_bytes}), do: %{"limit_bytes" => limit_bytes}
  defp reason_wire({:no_memory, held}), do: Prima.LocusPool.encode_held(held)
  defp reason_wire({:unavailable, what}), do: what
  defp reason_wire({:failed, {:status, status}}), do: %{"status" => status}
  defp reason_wire({:failed, {:signal, signal}}), do: %{"signal" => signal}

  defp reason_wire({:protocol_mismatch, builder, client}),
    do: %{"builder" => builder, "client" => client}

  defp reason(:malformed, sentence), do: sentence(:malformed, sentence)
  defp reason(:unavailable, what), do: sentence(:unavailable, what)

  defp reason(:unauthorized, why) when is_binary(why) do
    case Enum.find(@unauthorized_reasons, &(Atom.to_string(&1) == why)) do
      nil -> {:error, {:invalid_field, "reason"}}
      why -> {:ok, {:unauthorized, why}}
    end
  end

  defp reason(:capacity, %{"max" => max} = wire)
       when map_size(wire) == 1 and is_integer(max) and max > 0,
       do: {:ok, {:capacity, max}}

  defp reason(:timeout, %{"budget_ms" => budget} = wire)
       when map_size(wire) == 1 and is_integer(budget) and budget >= 0,
       do: {:ok, {:timeout, budget}}

  defp reason(:memory, %{"limit_bytes" => limit} = wire)
       when map_size(wire) == 1 and is_integer(limit) and limit > 0,
       do: {:ok, {:memory, limit}}

  defp reason(:memory, %{"cause" => "machine"} = wire) when map_size(wire) == 1,
    do: {:ok, {:memory, :machine}}

  defp reason(:memory, %{"cause" => "either"} = wire) when map_size(wire) == 1,
    do: {:ok, {:memory, :either}}

  defp reason(:no_memory, wire) do
    case Prima.LocusPool.read_held(wire) do
      {:ok, held} -> {:ok, {:no_memory, held}}
      :error -> {:error, {:invalid_field, "reason"}}
    end
  end

  defp reason(:failed, %{"status" => status} = wire)
       when map_size(wire) == 1 and is_integer(status),
       do: {:ok, {:failed, {:status, status}}}

  defp reason(:failed, %{"signal" => signal} = wire)
       when map_size(wire) == 1 and is_binary(signal) and signal != "" and
              byte_size(signal) <= @max_text_bytes,
       do: {:ok, {:failed, {:signal, signal}}}

  defp reason(:protocol_mismatch, %{"builder" => builder, "client" => client} = wire)
       when map_size(wire) == 2 and is_integer(builder) and builder > 0 and
              (is_nil(client) or (is_integer(client) and client > 0)),
       do: {:ok, {:protocol_mismatch, builder, client}}

  defp reason(_class, _wire), do: {:error, {:invalid_field, "reason"}}

  defp sentence(class, text)
       when is_binary(text) and text != "" and byte_size(text) <= @max_line_bytes do
    if String.valid?(text), do: {:ok, {class, text}}, else: {:error, {:invalid_field, "reason"}}
  end

  defp sentence(_class, _text), do: {:error, {:invalid_field, "reason"}}

  @doc """
  The refusal a body that does not read is answered with: `protocol_mismatch`
  naming both versions for a body at another version, `malformed` with
  `describe/1` for anything else.
  """
  @spec refusal_for(read_error()) :: refusal()
  def refusal_for({:version, presented}) when is_integer(presented) and presented > 0,
    do: {:protocol_mismatch, @version, presented}

  def refusal_for({:version, _presented}), do: {:protocol_mismatch, @version, nil}
  def refusal_for(error), do: {:malformed, describe(error)}

  @doc "Why a body did not read, as a sentence for the other end."
  @spec describe(read_error()) :: String.t()
  def describe(:not_json), do: "the body is not a JSON object"
  def describe({:version, nil}), do: "the body names no protocol version"

  def describe({:version, presented}),
    do: "the body speaks protocol #{inspect(presented)}, not #{@version}"

  def describe({:unknown_field, name}), do: "#{name} is not a field of this message"
  def describe({:missing_field, name}), do: "#{name} is required"
  def describe({:invalid_field, name}), do: "#{name} is not of the form this message takes"

  def describe({:unpaired, language, target_type}),
    do: "a #{target_type} is not built from #{language}"

  def describe({:too_large, :request, bytes, max}),
    do: "the request is #{bytes} bytes; at most #{max} are read"

  def describe({:too_large, :line, bytes, max}),
    do: "a line is #{bytes} bytes; at most #{max} are read"

  def describe({:too_large, what, bytes, max}),
    do: "#{what} total #{bytes} bytes; at most #{max} are read"

  def describe({:too_many, what, count, max}),
    do: "#{what} name #{count} files; at most #{max} are read"

  def describe({:duplicate_path, path}), do: "#{path} is named twice"
  def describe({:unsafe_path, path}), do: "#{path} is not a safe relative path"
  def describe({:empty_chunk, path}), do: "an output line of #{path} carries no bytes"

  def describe({:out_of_order, seq, expected}),
    do: "output line #{seq} came where line #{expected} was due"

  def describe({:path_revisited, path}), do: "#{path} was sent again after another file"
  def describe({:unsent, path}), do: "the result names #{path}, which no output line sent"
  def describe({:unnamed, path}), do: "#{path} was sent and the result does not name it"
  def describe({:size_mismatch, path}), do: "the size of #{path} is not its bytes'"
  def describe({:digest_mismatch, path}), do: "the digest of #{path} is not its bytes'"

  @doc "A refusal as a sentence for a person."
  @spec describe_refusal(refusal()) :: String.t()
  def describe_refusal({:malformed, sentence}),
    do: "the builder could not read the request: #{sentence}"

  def describe_refusal({:unauthorized, why}),
    do: "the builder refused this server's key (#{why}); check the builds key on both ends"

  def describe_refusal({:capacity, max}),
    do: "the builder is at capacity (#{max} concurrent builds)"

  def describe_refusal({:timeout, budget_ms}),
    do: "the build passed its budget of #{budget_ms} ms"

  def describe_refusal({:memory, :machine}),
    do: "CYFR ran out of memory for builds and the build was ended"

  def describe_refusal({:memory, :either}), do: "the build ran out of memory and was ended"

  def describe_refusal({:memory, limit_bytes}),
    do: "the build reached its memory bound of #{limit_bytes} bytes and was ended there"

  def describe_refusal({:no_memory, held}), do: Prima.LocusPool.refusal_sentence(held)
  def describe_refusal({:unavailable, what}), do: "the builder cannot build this: #{what}"
  def describe_refusal({:failed, {:status, status}}), do: "the build failed (exit #{status})"
  def describe_refusal({:failed, {:signal, signal}}), do: "the build was killed (#{signal})"

  def describe_refusal({:protocol_mismatch, builder, client}) do
    "the builder speaks builder protocol #{builder} and this server speaks " <>
      "#{describe_version(client)}; run the builder image of the same release as this server"
  end

  defp describe_version(nil), do: "no builder protocol"
  defp describe_version(version), do: "builder protocol #{version}"

  # ————— reading —————

  defp object(text) do
    case Jason.decode(text) do
      {:ok, %{} = wire} -> {:ok, wire}
      _ -> {:error, :not_json}
    end
  end

  defp current_version(%{"version" => @version}), do: :ok
  defp current_version(wire), do: {:error, {:version, wire["version"]}}

  # Exactly the named fields: anything else is refused before a value is read.
  defp exact(wire, names, at) do
    cond do
      extra = Enum.find(Map.keys(wire), &(&1 not in names)) ->
        {:error, {:unknown_field, at <> extra}}

      missing = Enum.find(names, &(not is_map_key(wire, &1))) ->
        {:error, {:missing_field, at <> missing}}

      true ->
        :ok
    end
  end

  defp pairing(wire) do
    with {:ok, language} <- roster_field(wire, "language", @languages),
         {:ok, target_type} <- roster_field(wire, "target_type", @target_types) do
      if language_for(target_type) == language,
        do: {:ok, language, target_type},
        else: {:error, {:unpaired, language, target_type}}
    end
  end

  defp roster_field(wire, name, roster) do
    case Map.fetch(wire, name) do
      {:ok, value} when is_binary(value) ->
        case Enum.find(roster, &(Atom.to_string(&1) == value)) do
          nil -> {:error, {:invalid_field, name}}
          atom -> {:ok, atom}
        end

      {:ok, _value} ->
        {:error, {:invalid_field, name}}

      :error ->
        {:error, {:missing_field, name}}
    end
  end

  defp boolean_field(wire, name, at \\ "") do
    case wire[name] do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, at <> name}}
    end
  end

  defp integer_field(wire, name) do
    case wire[name] do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, name}}
    end
  end

  defp athanor_field(wire) do
    case wire["athanor_id"] do
      value when is_binary(value) ->
        if Regex.match?(RunnerControl.athanor_id_pattern(), value),
          do: {:ok, value},
          else: {:error, {:invalid_field, "athanor_id"}}

      _ ->
        {:error, {:invalid_field, "athanor_id"}}
    end
  end

  defp text_field(wire, name, max, at \\ "") do
    case wire[name] do
      value when is_binary(value) and value != "" and byte_size(value) <= max ->
        if String.valid?(value), do: {:ok, value}, else: {:error, {:invalid_field, at <> name}}

      _ ->
        {:error, {:invalid_field, at <> name}}
    end
  end

  defp line_field(wire, name) do
    case wire[name] do
      value when is_binary(value) and byte_size(value) > @max_line_bytes ->
        {:error, {:too_large, :line, byte_size(value), @max_line_bytes}}

      value when is_binary(value) ->
        if String.valid?(value), do: {:ok, value}, else: {:error, {:invalid_field, name}}

      _ ->
        {:error, {:invalid_field, name}}
    end
  end

  # ————— files —————

  defp files(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, bytes} -> %{"path" => path, "base64" => Base.encode64(bytes)} end)
  end

  # A source list is read in two passes: paths and the encoded bound first,
  # so an oversized or ill-named list is refused before any of it is
  # decoded, then the bytes, held to the decoded bound.
  defp files_field(wire, name, what, max_files, max_bytes) do
    with {:ok, list} <- file_list(wire[name], name, what, max_files),
         :ok <- file_shapes(list, name),
         :ok <- encoded_bound(list, what, max_files, max_bytes),
         {:ok, files} <- decode_files(list, name, what, max_bytes) do
      {:ok, files}
    end
  end

  defp file_list(list, name, what, max_files) do
    cond do
      not is_list(list) or list == [] -> {:error, {:invalid_field, name}}
      length(list) > max_files -> {:error, {:too_many, what, length(list), max_files}}
      true -> {:ok, list}
    end
  end

  defp file_shapes(list, name) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {file, index}, {:ok, seen} ->
      at = "#{name}[#{index}]."

      with true <- is_map(file) || {:error, {:invalid_field, "#{name}[#{index}]"}},
           :ok <- exact(file, @source_fields, at),
           {:ok, path} <- safe_path(file["path"], at),
           false <- MapSet.member?(seen, path) && {:error, {:duplicate_path, path}},
           true <- is_binary(file["base64"]) || {:error, {:invalid_field, at <> "base64"}} do
        {:cont, {:ok, MapSet.put(seen, path)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = error -> error
    end
  end

  # An output's path is bounded on its own bytes, before PathSafety splits
  # it, and holds no control character: a line's bound counts each of its
  # bytes as at most two once escaped.
  defp output_path(path, at) when is_binary(path) do
    if byte_size(path) > @max_output_path_bytes or String.contains?(path, @control_bytes),
      do: {:error, {:invalid_field, at <> "path"}},
      else: :ok
  end

  defp output_path(_path, at), do: {:error, {:invalid_field, at <> "path"}}

  defp safe_path(path, _at) when is_binary(path) and path != "" do
    case Prima.PathSafety.validate_relative_path(path) do
      :ok -> {:ok, path}
      {:error, _} -> {:error, {:unsafe_path, path}}
    end
  end

  defp safe_path(path, _at) when is_binary(path), do: {:error, {:unsafe_path, path}}

  defp safe_path(_path, at), do: {:error, {:invalid_field, at <> "path"}}

  # Base64 spells n bytes in at most 4n/3 + 4 characters, so a list whose
  # encoded total passes this ceiling cannot decode within the bound.
  defp encoded_bound(list, what, max_files, max_bytes) do
    encoded = Enum.reduce(list, 0, &(byte_size(&1["base64"]) + &2))

    if encoded > div(max_bytes * 4, 3) + 4 * max_files,
      do: {:error, {:too_large, what, div(encoded * 3, 4), max_bytes}},
      else: :ok
  end

  defp decode_files(list, name, what, max_bytes) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, 0}, fn {file, index}, {:ok, files, total} ->
      at = "#{name}[#{index}]."

      with {:ok, bytes} <- decode64(file["base64"], at),
           total = total + byte_size(bytes),
           true <- total <= max_bytes || {:error, {:too_large, what, total, max_bytes}} do
        {:cont, {:ok, Map.put(files, file["path"], bytes), total}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _total} -> {:ok, files}
      {:error, _} = error -> error
    end
  end

  defp decode64(text, at) do
    case Base.decode64(text) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_field, at <> "base64"}}
    end
  end

  # ————— outputs —————

  defp seq_field(%{"seq" => seq}) when is_integer(seq) and seq >= 1 and seq <= @max_seq,
    do: {:ok, seq}

  defp seq_field(_wire), do: {:error, {:invalid_field, "seq"}}

  defp seq_bound(seq) when is_integer(seq) and seq >= 1 and seq <= @max_seq, do: :ok
  defp seq_bound(_seq), do: {:error, {:invalid_field, "seq"}}

  defp chunk_bound(bytes) when bytes <= @max_chunk_bytes, do: :ok
  defp chunk_bound(bytes), do: {:error, {:too_large, :chunk, bytes, @max_chunk_bytes}}

  # The chunk's encoded size is checked before it is decoded.
  defp chunk_field(%{"bytes" => text}) when is_binary(text) do
    if byte_size(text) > 4 * div(@max_chunk_bytes + 2, 3) do
      {:error, {:too_large, :chunk, div(byte_size(text) * 3, 4), @max_chunk_bytes}}
    else
      with {:ok, bytes} <- decode64(text, ""),
           :ok <- chunk_bound(byte_size(bytes)),
           do: {:ok, bytes}
    end
  end

  defp chunk_field(_wire), do: {:error, {:invalid_field, "bytes"}}

  # A file of no bytes sends no line: its result names it alone.
  defp some_bytes(path, ""), do: {:error, {:empty_chunk, path}}
  defp some_bytes(_path, _bytes), do: :ok

  # A result's outputs: one to `max_output_files` entries, each path once,
  # their sizes within `max_output_bytes` together.
  defp outputs_field(list) when is_list(list) and list != [] do
    if length(list) > @max_output_files do
      {:error, {:too_many, :outputs, length(list), @max_output_files}}
    else
      list
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], MapSet.new(), 0}, fn {entry, index},
                                                          {:ok, outputs, seen, total} ->
        case output_entry(entry, "outputs[#{index}].") do
          {:ok, %{path: path, size: size} = output} ->
            cond do
              MapSet.member?(seen, path) ->
                {:halt, {:error, {:duplicate_path, path}}}

              total + size > @max_output_bytes ->
                {:halt, {:error, {:too_large, :outputs, total + size, @max_output_bytes}}}

              true ->
                {:cont, {:ok, [output | outputs], MapSet.put(seen, path), total + size}}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, outputs, _seen, _total} -> {:ok, Enum.reverse(outputs)}
        {:error, _} = error -> error
      end
    end
  end

  defp outputs_field(_list), do: {:error, {:invalid_field, "outputs"}}

  defp output_entry(%{} = entry, at) do
    with :ok <- exact(entry, @output_fields, at),
         :ok <- output_path(entry["path"], at),
         {:ok, path} <- safe_path(entry["path"], at),
         {:ok, size} <- size_field(entry["size"], at),
         {:ok, digest} <- digest_field(entry["digest"], at) do
      {:ok, %{path: path, size: size, digest: digest}}
    end
  end

  defp output_entry(_entry, at), do: {:error, {:invalid_field, String.trim_trailing(at, ".")}}

  defp size_field(size, _at) when is_integer(size) and size >= 0 and size <= @max_output_bytes,
    do: {:ok, size}

  defp size_field(_size, at), do: {:error, {:invalid_field, at <> "size"}}

  defp digest_field("sha256:" <> hex = digest, at) when byte_size(hex) == 64 do
    if hex =~ ~r/\A[0-9a-f]{64}\z/,
      do: {:ok, digest},
      else: {:error, {:invalid_field, at <> "digest"}}
  end

  defp digest_field(_digest, at), do: {:error, {:invalid_field, at <> "digest"}}
end
