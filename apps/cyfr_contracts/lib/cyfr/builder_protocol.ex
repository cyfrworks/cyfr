# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BuilderProtocol do
  @moduledoc """
  The wire between CYFR's build client (`Compendium.Builds.Client`, reached
  through `CYFR_LOCUS_BUILDS_URL` and `CYFR_LOCUS_BUILDS_KEY`) and the
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
  | `:build` | `/locus/v1/builds/build` | a request | lines: progress, then one result or refusal |
  | `:health` | `/locus/v1/builds/health` | `{"version": 1}` | one health line, or a refusal |

  A build's answer is a stream of newline-delimited JSON lines
  (`encode_progress/2`, `read_line/1`): zero or more progress lines as the
  build runs, then exactly one terminal line, a result or a refusal. A
  refusal the builder can make before the build starts — malformed,
  unauthorized, protocol mismatch, capacity, unavailable — is answered at
  its class's HTTP status (`status/1`) as the one line of the body; a
  refusal reached once the stream began travels as its terminal line under
  the 200 the stream opened with. A client reads lines whatever the status
  and lets the terminal line decide. `health` answers without
  authentication, so a liveness probe needs no key; every other answer
  follows a verified request.

  ## The request (`encode_request/1`, `read_request/1`)

  `{version, athanor_id, language, target_type, resolve, deadline,
  sources}`. `athanor_id` is the tenant the build is for, which the builder
  keys its per-athanor slot on and keeps nothing else about. `language` is
  `rust` or `javascript` and `target_type` a component type, paired as
  `language_for/1` says. `resolve` asks a Rust build to resolve its crate
  graph afresh. `deadline` is the absolute instant, in Unix milliseconds,
  by which the build must have finished: the builder's budget is the time
  to it or its own ceiling, whichever is less, and a deadline already
  passed is refused as `timeout`. `sources` is a list of
  `{path, base64}`, at most `max_source_files/0` files and
  `max_source_bytes/0` decoded bytes in all, every path relative and safe
  (`Cyfr.PathSafety`) and named once.

  ## The result

  `{version, type: "result", language, target_type, outputs, diagnostics}`.
  `outputs` is a list of `{path, base64, digest}`, each file's digest the
  `Cyfr.Digest.sha256/1` of its bytes, at most `max_output_files/0` files
  and `max_output_bytes/0` bytes in all. A component build's outputs are
  `component_wasm/0` and, when the build left one, `component_lockfile/0`;
  a tincture's are its files. `diagnostics` are the build's log lines,
  bounded as `max_line_bytes/0` and `max_log_bytes/0` say. The builder is
  another trust domain: the reader checks every digest against the bytes
  it decoded and every path, and the client still validates a component's
  bytes and derives the digest it registers under itself.

  ## Refusals

  `{version, type: "refusal", class, reason, diagnostics}`, one class per
  way a build does not happen, each with a reason of its own shape:

  | Class | Reason | When |
  |---|---|---|
  | `malformed` | a sentence | the body does not read (`describe/1`) |
  | `unauthorized` | `malformed`, `outside_window`, `bad_mac` or `replayed` | the header does not verify, or its nonce was seen |
  | `capacity` | `{max}` | every slot of the cap is taken |
  | `timeout` | `{budget_ms}` | the build passed its budget |
  | `memory` | `{limit_bytes}` | the build reached its memory bound and was ended there |
  | `unavailable` | a sentence naming what | a toolchain or the spawner is missing |
  | `failed` | `{status}` or `{signal}` | the build ran and did not produce its output |
  | `protocol_mismatch` | `{builder, client}` | the request's version is not `version/0` |

  `memory` is the builder's report that the build's sandbox reached the
  bound the builder runs every build under, `limit_bytes`: its processes,
  what it wrote to its home and the kernel memory charged to it, together.
  The builder answers it only when its spawner read that end from the
  kernel's counters for the sandbox; a build killed for any other reason,
  the container's own memory limit among them, is `failed` with its signal.

  ## Authentication

  One 32-byte key per Locus service (`LOCUS_BUILDS_KEY`, `decode_key/1`)
  is shared by CYFR and the builder. The key a request is signed with is
  derived from it over the service's label, `cyfr-locus/v1/builds`
  (`request_key/1`), and the signature is `Cyfr.MacEnvelope`'s over that
  label as its prefix, the kind `request`, a timestamp in Unix
  milliseconds, a nonce and the body's hash, carried in the `x-cyfr-auth`
  header (`auth_header/0`). The domain `cyfr-locus/v1` is shared with
  every Locus service; the label names one, so neither the key nor a
  header of another service (`backends`) verifies a build request. A
  listener verifies the header before it reads the body
  (`verify_request_header/3`, then `verify_body/2`), bounded by
  `max_request_bytes/0`, and refuses, in order, `:malformed`,
  `:outside_window` (`ts` further than `window_ms/0` from its clock) and
  `:bad_mac`. Replay is the listener's, against state this module does not
  hold: a nonce seen within the window is refused as `replayed`. Answers
  are not signed: they travel on the connection the verified request
  opened, and the client believes nothing in them it can check itself.
  """

  alias Cyfr.MacEnvelope

  @version 1
  @domain "cyfr-locus/v1"
  @service "builds"
  @label "cyfr-locus/v1/builds"
  @auth_header "x-cyfr-auth"
  @window_ms 30_000
  @routes %{build: "/locus/v1/builds/build", health: "/locus/v1/builds/health"}

  @max_source_bytes 1_048_576
  @max_source_files 512
  @max_request_bytes 2_000_000
  @max_output_bytes 64 * 1_048_576
  @max_output_files 500
  @max_response_bytes 100_000_000
  @max_line_bytes 65_536
  @max_log_bytes 2_000_000
  @max_text_bytes 256

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
    :unavailable,
    :failed,
    :protocol_mismatch
  ]
  @unauthorized_reasons [:malformed, :outside_window, :bad_mac, :replayed]
  @line_types [:progress, :result, :refusal, :health]

  @statuses %{
    malformed: 400,
    unauthorized: 401,
    protocol_mismatch: 409,
    failed: 422,
    capacity: 429,
    unavailable: 503,
    timeout: 504,
    memory: 507
  }

  # The pairing is declared here once; a component type the roster gains
  # without a language is a compile error, not a request refused at runtime.
  if Enum.sort(@target_types) != Enum.sort(Cyfr.ComponentRef.valid_type_atoms()) do
    raise "Cyfr.BuilderProtocol pairs #{inspect(@target_types)} with a language, " <>
            "but Cyfr.ComponentRef's types are #{inspect(Cyfr.ComponentRef.valid_type_atoms())}"
  end

  @request_fields ~w(version athanor_id language target_type resolve deadline sources)
  @health_request_fields ~w(version)
  @progress_fields ~w(version type stage message)
  @result_fields ~w(version type language target_type outputs diagnostics)
  @refusal_fields ~w(version type class reason diagnostics)
  @health_fields ~w(version type release toolchains)
  @source_fields ~w(path base64)
  @output_fields ~w(path base64 digest)
  @toolchain_fields ~w(available command description)

  @request %MacEnvelope{
    prefix: @label,
    kind: "request",
    fields: [ts: :integer, nonce: :string],
    body_hash_in_header: true
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

  @typedoc "A finished build: its output files by path and the build's log lines."
  @type result :: %{
          language: language(),
          target_type: target_type(),
          outputs: %{String.t() => binary()},
          diagnostics: [String.t()]
        }

  @typedoc "What one toolchain reports on a health answer."
  @type toolchain :: %{available: boolean(), command: String.t(), description: String.t()}

  @typedoc "A health answer: the builder's release and its toolchains by language."
  @type health :: %{release: String.t(), toolchains: %{language() => toolchain()}}

  @typedoc "A refusal by class, each with its typed reason."
  @type refusal ::
          {:malformed, String.t()}
          | {:unauthorized, :malformed | :outside_window | :bad_mac | :replayed}
          | {:capacity, pos_integer()}
          | {:timeout, non_neg_integer()}
          | {:memory, pos_integer()}
          | {:unavailable, String.t()}
          | {:failed, {:status, integer()} | {:signal, String.t()}}
          | {:protocol_mismatch, pos_integer(), pos_integer() | nil}

  @typedoc "One line of an answer."
  @type line ::
          {:progress, stage(), String.t()}
          | {:result, result()}
          | {:refusal, refusal(), [String.t()]}
          | {:health, health()}

  @typedoc """
  Why a body does not read: not a JSON object; another protocol version
  (or none); a field the shape does not have, lacks or does not accept
  (named by its path, `sources[2].path`); a language and type not built
  together; a bound passed (what, the size seen, the bound); a path named
  twice or unsafe; an output whose digest is not its bytes'.
  """
  @type read_error ::
          :not_json
          | {:version, term()}
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unpaired, language(), target_type()}
          | {:too_large, :request | :sources | :outputs | :diagnostics | :line, non_neg_integer(),
             pos_integer()}
          | {:too_many, :sources | :outputs, non_neg_integer(), pos_integer()}
          | {:duplicate_path, String.t()}
          | {:unsafe_path, String.t()}
          | {:digest_mismatch, String.t()}

  @typedoc "A request header's fields: the timestamp in Unix milliseconds and a nonce."
  @type auth :: %{ts: non_neg_integer(), nonce: String.t()}

  @type auth_refusal :: :malformed | :outside_window | :bad_mac

  @typedoc "The hex SHA-256 a verified header names as its body's."
  @type body_hash :: String.t()

  # ————— the protocol as data —————

  @doc "The protocol this release speaks, carried in every body."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "This release's version, as a health answer reports it."
  @spec release() :: String.t()
  def release, do: :cyfr_contracts |> Application.spec(:vsn) |> to_string()

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

  @doc "The bytes a build's whole answer stream may be, as the client collects it."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "The bytes one progress message, diagnostic line or refusal sentence may be."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The bytes a result's or refusal's diagnostics may total, each line counted with its newline."
  @spec max_log_bytes() :: pos_integer()
  def max_log_bytes, do: @max_log_bytes

  # ————— authentication —————

  @doc "The service key `LOCUS_BUILDS_KEY` or `CYFR_LOCUS_BUILDS_KEY` spells: 64 hexadecimal digits."
  @spec decode_key(term()) :: {:ok, binary()} | :error
  defdelegate decode_key(text), to: MacEnvelope, as: :decode_root

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
  refusal: `:malformed`, `:outside_window`, `:bad_mac`. `now` is in Unix
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
      "sources" => files(sources, false)
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
         {:ok, athanor_id} <- text_field(wire, "athanor_id", @max_text_bytes),
         {:ok, language, target_type} <- pairing(wire),
         {:ok, resolve} <- boolean_field(wire, "resolve"),
         {:ok, deadline} <- integer_field(wire, "deadline"),
         {:ok, sources} <-
           files_field(wire, "sources", :sources, @max_source_files, @max_source_bytes, false) do
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

  @doc "The terminal line of a finished build, checked as `read_line/1` will check it."
  @spec encode_result(result()) :: {:ok, binary()} | {:error, read_error()}
  def encode_result(%{
        language: language,
        target_type: target_type,
        outputs: outputs,
        diagnostics: diagnostics
      })
      when is_atom(language) and is_atom(target_type) and is_map(outputs) do
    encode_line(%{
      "version" => @version,
      "type" => "result",
      "language" => Atom.to_string(language),
      "target_type" => Atom.to_string(target_type),
      "outputs" => files(outputs, true),
      "diagnostics" => diagnostics
    })
  end

  @doc "The one line of a refusal, with the build's log lines so far."
  @spec encode_refusal(refusal(), [String.t()]) :: {:ok, binary()} | {:error, read_error()}
  def encode_refusal(refusal, diagnostics) when is_tuple(refusal) and is_list(diagnostics) do
    encode_line(%{
      "version" => @version,
      "type" => "refusal",
      "class" => Atom.to_string(elem(refusal, 0)),
      "reason" => reason_wire(refusal),
      "diagnostics" => diagnostics
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

  @doc "One line of an answer, read strictly by its `type`."
  @spec read_line(binary()) :: {:ok, line()} | {:error, read_error()}
  def read_line(line) when is_binary(line) do
    with {:ok, wire} <- object(line), do: read_line_wire(wire)
  end

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

  defp read_typed(:result, wire) do
    with :ok <- exact(wire, @result_fields, ""),
         {:ok, language, target_type} <- pairing(wire),
         {:ok, outputs} <-
           files_field(wire, "outputs", :outputs, @max_output_files, @max_output_bytes, true),
         :ok <- component_outputs(language, outputs),
         {:ok, diagnostics} <- log_field(wire, "diagnostics") do
      {:ok,
       {:result,
        %{
          language: language,
          target_type: target_type,
          outputs: outputs,
          diagnostics: diagnostics
        }}}
    end
  end

  defp read_typed(:refusal, wire) do
    with :ok <- exact(wire, @refusal_fields, ""),
         {:ok, class} <- roster_field(wire, "class", @classes),
         {:ok, refusal} <- reason(class, wire["reason"]),
         {:ok, diagnostics} <- log_field(wire, "diagnostics") do
      {:ok, {:refusal, refusal, diagnostics}}
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
  defp component_outputs(:rust, outputs) do
    if is_map_key(outputs, @component_wasm) and
         Map.keys(outputs) -- [@component_wasm, @component_lockfile] == [],
       do: :ok,
       else: {:error, {:invalid_field, "outputs"}}
  end

  defp component_outputs(:javascript, _outputs), do: :ok

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
  defp reason_wire({:memory, limit_bytes}), do: %{"limit_bytes" => limit_bytes}
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

  def describe_refusal({:memory, limit_bytes}),
    do: "the build reached its memory bound of #{limit_bytes} bytes and was ended there"

  def describe_refusal({:unavailable, what}), do: "the builder cannot build this: #{what}"
  def describe_refusal({:failed, {:status, status}}), do: "the build failed (exit #{status})"
  def describe_refusal({:failed, {:signal, signal}}), do: "the build was killed (#{signal})"

  def describe_refusal({:protocol_mismatch, builder, client}) do
    "the builder speaks builder protocol #{builder} and this server speaks " <>
      "#{describe_version(client)}; run the builder image of the same release as this server"
  end

  defp describe_version(nil), do: "no builder protocol (a release older than this one)"
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

  # The log's lines, each within the line bound and all within the log
  # bound, a line counted with the newline that ends it.
  defp log_field(wire, name) do
    case wire[name] do
      lines when is_list(lines) ->
        Enum.reduce_while(lines, {:ok, 0}, fn line, {:ok, bytes} ->
          case line_field(%{name => line}, name) do
            {:ok, line} when bytes + byte_size(line) + 1 > @max_log_bytes ->
              {:halt,
               {:error, {:too_large, :diagnostics, bytes + byte_size(line) + 1, @max_log_bytes}}}

            {:ok, line} ->
              {:cont, {:ok, bytes + byte_size(line) + 1}}

            {:error, _} = error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, _bytes} -> {:ok, lines}
          {:error, _} = error -> error
        end

      _ ->
        {:error, {:invalid_field, name}}
    end
  end

  # ————— files —————

  defp files(files, digests?) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, bytes} ->
      file = %{"path" => path, "base64" => Base.encode64(bytes)}
      if digests?, do: Map.put(file, "digest", Cyfr.Digest.sha256(bytes)), else: file
    end)
  end

  # A file list is read in two passes: paths and the encoded bound first,
  # so an oversized or ill-named list is refused before any of it is
  # decoded, then the bytes, held to the decoded bound and their digests.
  defp files_field(wire, name, what, max_files, max_bytes, digests?) do
    with {:ok, list} <- file_list(wire[name], name, what, max_files),
         :ok <- file_shapes(list, name, digests?),
         :ok <- encoded_bound(list, what, max_files, max_bytes),
         {:ok, files} <- decode_files(list, name, what, max_bytes, digests?) do
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

  defp file_shapes(list, name, digests?) do
    fields = if digests?, do: @output_fields, else: @source_fields

    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {file, index}, {:ok, seen} ->
      at = "#{name}[#{index}]."

      with true <- is_map(file) || {:error, {:invalid_field, "#{name}[#{index}]"}},
           :ok <- exact(file, fields, at),
           {:ok, path} <- safe_path(file["path"], at),
           false <- MapSet.member?(seen, path) && {:error, {:duplicate_path, path}},
           true <- is_binary(file["base64"]) || {:error, {:invalid_field, at <> "base64"}},
           :ok <- digest_shape(file, at, digests?) do
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

  defp safe_path(path, _at) when is_binary(path) and path != "" do
    case Cyfr.PathSafety.validate_relative_path(path) do
      :ok -> {:ok, path}
      {:error, _} -> {:error, {:unsafe_path, path}}
    end
  end

  defp safe_path(path, _at) when is_binary(path), do: {:error, {:unsafe_path, path}}

  defp safe_path(_path, at), do: {:error, {:invalid_field, at <> "path"}}

  defp digest_shape(_file, _at, false), do: :ok

  defp digest_shape(file, at, true) do
    case file["digest"] do
      "sha256:" <> hex when byte_size(hex) == 64 -> :ok
      _ -> {:error, {:invalid_field, at <> "digest"}}
    end
  end

  # Base64 spells n bytes in at most 4n/3 + 4 characters, so a list whose
  # encoded total passes this ceiling cannot decode within the bound.
  defp encoded_bound(list, what, max_files, max_bytes) do
    encoded = Enum.reduce(list, 0, &(byte_size(&1["base64"]) + &2))

    if encoded > div(max_bytes * 4, 3) + 4 * max_files,
      do: {:error, {:too_large, what, div(encoded * 3, 4), max_bytes}},
      else: :ok
  end

  defp decode_files(list, name, what, max_bytes, digests?) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, 0}, fn {file, index}, {:ok, files, total} ->
      at = "#{name}[#{index}]."

      with {:ok, bytes} <- decode64(file["base64"], at),
           total = total + byte_size(bytes),
           true <- total <= max_bytes || {:error, {:too_large, what, total, max_bytes}},
           :ok <- digest_matches(file, bytes, digests?) do
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

  defp digest_matches(_file, _bytes, false), do: :ok

  defp digest_matches(file, bytes, true) do
    if file["digest"] == Cyfr.Digest.sha256(bytes),
      do: :ok,
      else: {:error, {:digest_mismatch, file["path"]}}
  end
end
