# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusBackends do
  @moduledoc """
  The wire between CYFR's backends controller (`Emissary.External.Backends`
  and the servers it runs, `Emissary.External.Server`) and the backends
  service Locus serves: the stdio MCP servers CYFR registers, one owner per
  athanor and server row. The second service of the `cyfr-locus/v1` domain
  beside `Prima.BuilderProtocol`. Data and codec only — no process and no
  HTTP live here. `tests/fixtures/locus_backends.json` holds the vectors
  every end reproduces.

  ## Routes

  | Operation | Route | Body | Answer |
  |---|---|---|---|
  | `:health` | `/locus/v1/backends/health` | none | unauthenticated |
  | `:control` | `/locus/v1/backends/control` | a control message | its answer, or a refusal |
  | `:mcp` | `/locus/v1/backends/mcp` | one JSON-RPC message | a JSON-RPC answer, or a refusal |

  Every answer carries `x-cyfr-boot` (`boot_header/0`), the service's
  lifetime, which a control message names back.

  ## Control messages (`encode_control/1`, `read_control/1`)

  Every control body and every control answer carries `"version"`
  (`version/0`); a body at another version, or without one, is read as
  `{:error, {:version, presented}}` before its `type` is, and refused
  `version` (`refusal_for/1`). Each type has exactly its members:

  | Type | Members | Answer (`encode_answer/2`, `read_answer/2`) |
  |---|---|---|
  | `hello` | `g`, `cyfr_boot` | `boot`, `pool{size, free}` |
  | `reconcile` | `keep[{athanor, server, e}]` | `released[{athanor, server, g, e}]` |
  | `sync` | `owner{athanor, server}`, `e`, `lease_ms`, `idle_ms`, `backends[{name, command, env_names}]`, `sealed` | `status`, `rev`, `backends[{name, status, tools}]` |
  | `renew` | `lease_ms`, `owners[{athanor, server, e}]` | `renewed[{athanor, server, e, state, rev}]`, `unknown[{athanor, server, e}]` |
  | `release` | `owners[{athanor, server, e}]` | `released[{athanor, server, g, e}]` |
  | `status` | `owners[{athanor, server}]` | `owners[{athanor, server, g, e, state, rev, lease_ms_left, backends[{name, status, restarts, tools, error, stderr_tail}]}]` |

  An owner's `athanor` and `server` are signed field text
  (`Prima.MacEnvelope`); a generation `g` and an epoch `e` are positive
  integers. `lease_ms` is at most `max_lease_ms/0` and `idle_ms` at most
  `max_idle_ms/0`, each at least 1. A sync names 1 to `max_backends/0`
  backends, each a `name` of lowercase letters, digits and hyphens, a
  `command` of at most `max_command_bytes/0` bytes that names no `vault:`
  reference, and the `env_names` its sealed environment carries: each an
  uppercase variable name, none reserved (`reserved_env_names/0`,
  `reserved_env_prefixes/0`). `sealed` is the environment `seal/5` sealed
  to the owner and the service's lifetime. A status names at most
  `max_status_owners/0` owners, and its answer is at most
  `max_status_answer_bytes/0` bytes, refused whole past either bound.

  ## MCP

  The MCP body is not this module's: it is one JSON-RPC message versioned
  by its own `mcp-protocol-version` header and `_meta` keys, as
  `Prima.MCP.Protocol` defines them. This module names the conformance
  headers and `_meta` keys an invoke carries through (`mcp_headers/0`,
  `mcp_meta_keys/0`) and the body's bound, `max_mcp_bytes/0`.

  ## Refusals

  A refusal is answered at its code's HTTP status (`status/1`) as
  `{"version": 1, "error": <code>}` (`encode_refusal/1`).

  ## Authentication

  One 32-byte service key (`decode_key/1`) is shared by CYFR and the
  service. From it, over the label `cyfr-locus/v1/backends`, derive the
  **control key** (`<label>/control`), which signs control messages; the
  **seal key** (`<label>/seal`), which seals a sync's environment; and one
  **owner key** per athanor, server row, generation and epoch
  (`<label>/owner` and those four fields), which signs that owner's MCP
  requests and is the only key the owner holds. A signature is
  `Prima.MacEnvelope`'s with the label as its prefix, carried in the
  `x-cyfr-auth` header (`auth_header/0`); the header names the body's hash,
  so it verifies before the body is read (`verify_header/4`, then
  `verify_body/3`). The kinds are `control` (`generation`, `seq`,
  `cyfr_boot`, `boot`, `ts`) and `invoke` (`athanor`, `server`,
  `generation`, `epoch`, `boot`, `ts`, `nonce`), in that order, with
  `generation` written `gen` in the header. A listener refuses, in order,
  `:unknown_version` (a version token other than `v1`, such as `v2`), `:malformed`,
  `:outside_window` (`ts` further than `window_ms/0` from its clock) and
  `:bad_mac`. Neither the builds key nor a header of the builds
  service verifies here. The fences — lifetime, sequence, owner version and
  nonce — are the service's, against state this module does not hold.

  ## Masking

  Everything an owner's backends produce that leaves the service passes
  through `mask/2`, which replaces each of the owner's credential values of
  at least eight bytes, whole and after a scheme prefix (`Bearer <token>`),
  with `[REDACTED]`. Only the variables `literal_env_names/0` names hold a
  literal value rather than a credential.
  """

  alias Prima.{KeeperProtocol, MacEnvelope}
  alias Prima.MCP.Protocol, as: MCPProtocol

  @version 1
  @domain MacEnvelope.domain(:locus)
  @service MacEnvelope.service(:backends)
  @label MacEnvelope.label(:backends)
  @auth_header MacEnvelope.auth_header()
  @boot_header "x-cyfr-boot"
  @window_ms Prima.BuilderProtocol.window_ms()
  @routes %{
    health: "/locus/v1/backends/health",
    control: "/locus/v1/backends/control",
    mcp: "/locus/v1/backends/mcp"
  }

  # A control message is at most a sync of sixteen backends
  # and its sealed environment; an MCP request is one call's arguments, at
  # most the platform's request ceiling, and its JSON-RPC envelope.
  @max_control_bytes 1_048_576
  @max_mcp_bytes Prima.Limits.Ceiling.lowered([]).max_request_size + 65_536
  @max_status_owners 64
  @max_status_answer_bytes @max_control_bytes
  @max_backends 16
  @max_in_flight 32
  @max_command_bytes 4_096
  @max_nonces 8_192
  @nonce_window_ms @window_ms
  @max_frame_bytes 10_485_760
  @stderr_tail_bytes 65_536
  @stderr_tail_slack_bytes 4_096
  @restart_backoff_ms [1_000, 2_000, 4_000, 8_000, 16_000]
  @crash_window_ms 600_000
  @max_crashes 5
  @max_lease_ms 60_000
  @max_idle_ms 86_400_000
  @literal_env_names ~w(NODE_ENV LOG_LEVEL TZ LANG LC_ALL NO_COLOR DEBUG)

  @bounds %{
    max_control_bytes: @max_control_bytes,
    max_mcp_bytes: @max_mcp_bytes,
    max_status_owners: @max_status_owners,
    max_status_answer_bytes: @max_status_answer_bytes,
    max_backends: @max_backends,
    max_in_flight: @max_in_flight,
    max_command_bytes: @max_command_bytes,
    max_nonces: @max_nonces,
    nonce_window_ms: @nonce_window_ms,
    max_frame_bytes: @max_frame_bytes,
    stderr_tail_bytes: @stderr_tail_bytes,
    stderr_tail_slack_bytes: @stderr_tail_slack_bytes,
    restart_backoff_ms: @restart_backoff_ms,
    crash_window_ms: @crash_window_ms,
    max_crashes: @max_crashes,
    max_lease_ms: @max_lease_ms,
    max_idle_ms: @max_idle_ms,
    literal_env_names: @literal_env_names
  }

  @statuses %{
    unauthorized: 401,
    stale_boot: 409,
    stale_control: 409,
    stale_epoch: 409,
    conflict: 409,
    lapsed: 409,
    epoch_ahead: 409,
    unknown_owner: 409,
    replay: 409,
    capacity: 409,
    status_too_large: 409,
    version: 409,
    bad_request: 400,
    too_many_owners: 400,
    too_large: 413,
    unavailable: 503,
    nonce_cache_full: 503,
    internal: 500
  }
  @classes Map.keys(@statuses) |> Enum.sort()

  @control_types [:hello, :reconcile, :sync, :renew, :release, :status]
  @owner_states [:starting, :running, :draining]
  @backend_statuses [:spawning, :initializing, :ready, :crashed, :failed, :idle]

  @control_fields %{
    hello: ~w(version type g cyfr_boot),
    reconcile: ~w(version type keep),
    sync: ~w(version type owner e lease_ms idle_ms backends sealed),
    renew: ~w(version type lease_ms owners),
    release: ~w(version type owners),
    status: ~w(version type owners)
  }
  @answer_fields %{
    hello: ~w(version boot pool),
    reconcile: ~w(version released),
    sync: ~w(version status rev backends),
    renew: ~w(version renewed unknown),
    release: ~w(version released),
    status: ~w(version owners)
  }
  @backend_fields ~w(name command env_names)
  @backend_name ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/
  @vault_reference "vault:"

  @min_masked_bytes 8
  @mask_marker "[REDACTED]"

  @owner_fields [athanor: :string, server: :string, generation: :integer, epoch: :integer]
  @seal_fields @owner_fields ++ [boot: :string]
  @header_names %{generation: "gen"}

  @envelopes %{
    invoke: %MacEnvelope{
      prefix: @label,
      kind: "invoke",
      fields: @owner_fields ++ [boot: :string, ts: :integer, nonce: :string],
      header_names: @header_names,
      body_hash_in_header: true
    },
    control: %MacEnvelope{
      prefix: @label,
      kind: "control",
      fields: [
        generation: :integer,
        seq: :integer,
        cyfr_boot: :string,
        boot: :string,
        ts: :integer
      ],
      header_names: @header_names,
      body_hash_in_header: true
    }
  }

  @type operation :: :health | :control | :mcp
  @type kind :: :invoke | :control
  @type control_type :: :hello | :reconcile | :sync | :renew | :release | :status
  @type owner_state :: :starting | :running | :draining
  @type backend_status :: :spawning | :initializing | :ready | :crashed | :failed | :idle

  @typedoc "The owner a key or a sealed environment is bound to."
  @type owner :: %{
          athanor: String.t(),
          server: String.t(),
          generation: pos_integer(),
          epoch: pos_integer()
        }

  @typedoc "An invoke header's fields: the owner's, the service lifetime, the timestamp in ms and a nonce."
  @type invoke :: %{
          athanor: String.t(),
          server: String.t(),
          generation: pos_integer(),
          epoch: pos_integer(),
          boot: String.t(),
          ts: non_neg_integer(),
          nonce: String.t()
        }

  @typedoc "A control header's fields: generation, sequence, both lifetimes and the timestamp in ms."
  @type control :: %{
          generation: pos_integer(),
          seq: non_neg_integer(),
          cyfr_boot: String.t(),
          boot: String.t(),
          ts: non_neg_integer()
        }

  @typedoc "An owner as a message names it."
  @type owner_ref :: %{athanor: String.t(), server: String.t()}

  @typedoc "An owner at one epoch, as a message names it."
  @type owner_epoch :: %{athanor: String.t(), server: String.t(), e: pos_integer()}

  @typedoc "An owner at one generation and epoch, as an answer names it."
  @type owner_version :: %{
          athanor: String.t(),
          server: String.t(),
          g: pos_integer(),
          e: pos_integer()
        }

  @typedoc "One backend a sync defines."
  @type backend :: %{name: String.t(), command: String.t(), env_names: [String.t()]}

  @typedoc "A control message by its `type`."
  @type control_message ::
          %{type: :hello, g: pos_integer(), cyfr_boot: String.t()}
          | %{type: :reconcile, keep: [owner_epoch()]}
          | %{
              type: :sync,
              owner: owner_ref(),
              e: pos_integer(),
              lease_ms: pos_integer(),
              idle_ms: pos_integer(),
              backends: [backend()],
              sealed: String.t()
            }
          | %{type: :renew, lease_ms: pos_integer(), owners: [owner_epoch()]}
          | %{type: :release, owners: [owner_epoch()]}
          | %{type: :status, owners: [owner_ref()]}

  @typedoc "A backend as a status answer reports it."
  @type backend_report :: %{
          name: String.t(),
          status: backend_status(),
          restarts: non_neg_integer(),
          tools: non_neg_integer(),
          error: String.t() | nil,
          stderr_tail: String.t()
        }

  @typedoc "An owner as a status answer reports it."
  @type owner_report :: %{
          athanor: String.t(),
          server: String.t(),
          g: pos_integer(),
          e: pos_integer(),
          state: owner_state(),
          rev: non_neg_integer(),
          lease_ms_left: non_neg_integer(),
          backends: [backend_report()]
        }

  @typedoc "A control answer, by the type of the message it answers."
  @type answer ::
          %{boot: String.t(), pool: %{size: non_neg_integer(), free: non_neg_integer()}}
          | %{released: [owner_version()]}
          | %{
              status: owner_state(),
              rev: non_neg_integer(),
              backends: [%{name: String.t(), status: backend_status(), tools: non_neg_integer()}]
            }
          | %{
              renewed: [
                %{
                  athanor: String.t(),
                  server: String.t(),
                  e: pos_integer(),
                  state: owner_state(),
                  rev: non_neg_integer()
                }
              ],
              unknown: [owner_epoch()]
            }
          | %{owners: [owner_report()]}

  @type code ::
          :unauthorized
          | :stale_boot
          | :stale_control
          | :stale_epoch
          | :conflict
          | :lapsed
          | :epoch_ahead
          | :unknown_owner
          | :replay
          | :capacity
          | :status_too_large
          | :version
          | :bad_request
          | :too_many_owners
          | :too_large
          | :unavailable
          | :nonce_cache_full
          | :internal

  @typedoc """
  A refusal: its code, or, for a body at another protocol version, the
  version this end speaks and the one presented (`nil` for none), answered
  as `version`.
  """
  @type refusal :: code() | {:protocol_mismatch, pos_integer(), pos_integer() | nil}

  @typedoc """
  Why a body does not read: not a JSON object; another protocol version (or
  none); a type that is none; a member the shape does not have, lacks or
  does not accept (named by its path, `backends[1].command`); a bound passed
  (what, the size seen, the bound); a lease or idle period past its bound; a
  backend or variable named twice; a command naming a vault reference; a
  reserved variable.
  """
  @type read_error ::
          :not_json
          | {:version, term()}
          | {:unknown_type, term()}
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:too_large, :control | :answer | :status_answer | :command, non_neg_integer(),
             pos_integer()}
          | {:too_many, :owners | :backends, non_neg_integer(), pos_integer()}
          | {:out_of_range, String.t(), integer(), pos_integer()}
          | {:duplicate, String.t()}
          | {:vault_reference, String.t()}
          | {:reserved_env_name, String.t()}

  @type auth_refusal :: :unknown_version | :malformed | :outside_window | :bad_mac

  @typedoc "The hex SHA-256 a verified header names as its body's."
  @type body_hash :: String.t()

  # ————— the protocol as data —————

  @doc "The protocol this release speaks, carried in every control body and answer."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The MAC domain every Locus service signs under."
  @spec domain() :: String.t()
  def domain, do: @domain

  @doc "This service's name within the domain."
  @spec service() :: String.t()
  def service, do: @service

  @doc "This service's label: the domain and the service."
  @spec label() :: String.t()
  def label, do: @label

  @doc "The HTTP header a request's signature travels in, lowercase."
  @spec auth_header() :: String.t()
  def auth_header, do: @auth_header

  @doc "The HTTP header every answer names the service's lifetime in, lowercase."
  @spec boot_header() :: String.t()
  def boot_header, do: @boot_header

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

  @doc "The HTTP status a refusal is answered at."
  @spec status(refusal()) :: pos_integer()
  def status(refusal), do: Map.fetch!(@statuses, code(refusal))

  @doc "The code a refusal travels as."
  @spec code(refusal()) :: code()
  def code({:protocol_mismatch, _ours, _presented}), do: :version
  def code(code) when is_map_key(@statuses, code), do: code

  @doc "Every refusal code, sorted."
  @spec classes() :: [code()]
  def classes, do: @classes

  @doc "The control message types."
  @spec control_types() :: [control_type()]
  def control_types, do: @control_types

  @doc "Every bound of the wire by name."
  @spec bounds() :: %{atom() => pos_integer() | [pos_integer()] | [String.t()]}
  def bounds, do: @bounds

  @doc "The bytes a control body or a control answer may be."
  @spec max_control_bytes() :: pos_integer()
  def max_control_bytes, do: @max_control_bytes

  @doc "The bytes an MCP body may be: the platform's request ceiling and 64 KiB of envelope."
  @spec max_mcp_bytes() :: pos_integer()
  def max_mcp_bytes, do: @max_mcp_bytes

  @doc "The owners one status may name."
  @spec max_status_owners() :: pos_integer()
  def max_status_owners, do: @max_status_owners

  @doc "The bytes a status answer may be, measured as it is sent."
  @spec max_status_answer_bytes() :: pos_integer()
  def max_status_answer_bytes, do: @max_status_answer_bytes

  @doc "The backends one sync may define."
  @spec max_backends() :: pos_integer()
  def max_backends, do: @max_backends

  @doc "The calls awaiting one backend at a time."
  @spec max_in_flight() :: pos_integer()
  def max_in_flight, do: @max_in_flight

  @doc "The bytes a backend's command may be."
  @spec max_command_bytes() :: pos_integer()
  def max_command_bytes, do: @max_command_bytes

  @doc "The nonces one owner's replay cache holds."
  @spec max_nonces() :: pos_integer()
  def max_nonces, do: @max_nonces

  @doc "How long a nonce is held after its timestamp, in milliseconds: the header window."
  @spec nonce_window_ms() :: pos_integer()
  def nonce_window_ms, do: @nonce_window_ms

  @doc "The bytes one stdout frame of a backend may be, its newline excluded."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "The bytes of a backend's stderr a status reports: its tail."
  @spec stderr_tail_bytes() :: pos_integer()
  def stderr_tail_bytes, do: @stderr_tail_bytes

  @doc "The raw stderr kept beyond the tail, so a credential split by the cut is masked before it is taken."
  @spec stderr_tail_slack_bytes() :: pos_integer()
  def stderr_tail_slack_bytes, do: @stderr_tail_slack_bytes

  @doc "The waits before each restart of a crashed backend, in milliseconds."
  @spec restart_backoff_ms() :: [pos_integer()]
  def restart_backoff_ms, do: @restart_backoff_ms

  @doc "The period, in milliseconds, within which `max_crashes/0` exits mark a backend failed."
  @spec crash_window_ms() :: pos_integer()
  def crash_window_ms, do: @crash_window_ms

  @doc "The exits within `crash_window_ms/0` that mark a backend failed."
  @spec max_crashes() :: pos_integer()
  def max_crashes, do: @max_crashes

  @doc "The longest lease a sync or renew may grant, in milliseconds."
  @spec max_lease_ms() :: pos_integer()
  def max_lease_ms, do: @max_lease_ms

  @doc "The longest idle period a sync may set, in milliseconds."
  @spec max_idle_ms() :: pos_integer()
  def max_idle_ms, do: @max_idle_ms

  @doc """
  The variables whose values are literal rather than credentials: a
  backend's value for one of these is not masked. Every other value is a
  credential from the vault.
  """
  @spec literal_env_names() :: [String.t()]
  def literal_env_names, do: @literal_env_names

  @doc "The variable names no backend may define: the keeper's (`Prima.KeeperProtocol`)."
  @spec reserved_env_names() :: [String.t()]
  def reserved_env_names, do: KeeperProtocol.reserved_env_names()

  @doc "The variable name prefixes no backend may define: the keeper's (`Prima.KeeperProtocol`)."
  @spec reserved_env_prefixes() :: [String.t()]
  def reserved_env_prefixes, do: KeeperProtocol.reserved_env_prefixes()

  @doc "The MCP conformance headers an invoke carries through, as `Prima.MCP.Protocol` names them."
  @spec mcp_headers() :: [String.t()]
  def mcp_headers do
    [
      MCPProtocol.protocol_version_header(),
      MCPProtocol.method_header(),
      MCPProtocol.name_header()
    ]
  end

  @doc "The `_meta` keys an invoke's body carries through, as `Prima.MCP.Protocol` names them."
  @spec mcp_meta_keys() :: [String.t()]
  def mcp_meta_keys,
    do: [MCPProtocol.meta_protocol_version_key(), MCPProtocol.meta_client_capabilities_key()]

  # ————— authentication —————

  @doc "The service key `LOCUS_BACKENDS_KEY` or `CYFR_LOCUS_BACKENDS_KEY` spells: 64 hexadecimal digits."
  @spec decode_key(term()) :: {:ok, binary()} | :error
  defdelegate decode_key(text), to: MacEnvelope, as: :decode_root

  @doc "The key control messages are signed with."
  @spec control_key(binary()) :: binary()
  def control_key(key) when byte_size(key) == 32,
    do: MacEnvelope.derive(key, @label <> "/control")

  @doc "The key a sync's environment is sealed with."
  @spec seal_key(binary()) :: binary()
  def seal_key(key) when byte_size(key) == 32, do: MacEnvelope.derive(key, @label <> "/seal")

  @doc "The key one owner, at one generation and epoch, signs its requests with."
  @spec owner_key(binary(), owner()) :: {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def owner_key(key, owner) when byte_size(key) == 32 and is_map(owner),
    do: MacEnvelope.derive(key, @label <> "/owner", @owner_fields, owner)

  @doc "The `x-cyfr-auth` header for an invoke of `body`, signed with the owner's key."
  @spec invoke_header(binary(), invoke(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def invoke_header(owner_key, invoke, body)
      when byte_size(owner_key) == 32 and is_map(invoke) and is_binary(body),
      do: MacEnvelope.header(@envelopes.invoke, owner_key, invoke, body)

  @doc "The `x-cyfr-auth` header for a control message of `body`, signed with the control key."
  @spec control_header(binary(), control(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def control_header(control_key, control, body)
      when byte_size(control_key) == 32 and is_map(control) and is_binary(body),
      do: MacEnvelope.header(@envelopes.control, control_key, control, body)

  @doc "The canonical string a signature of `kind` covers."
  @spec canonical(kind(), map(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def canonical(kind, message, body)
      when is_map_key(@envelopes, kind) and is_map(message) and is_binary(body),
      do: MacEnvelope.canonical(Map.fetch!(@envelopes, kind), message, body)

  @doc """
  A header's fields, with the body hash it names as `:body_hash`, and its
  MAC; `{:error, :unknown_version}` for a version token other than `v1`,
  and `{:error, :malformed}` for anything else but exactly one well-formed
  header of `kind`.
  """
  @spec parse_header(kind(), term()) ::
          {:ok, map(), String.t()} | {:error, :unknown_version | :malformed}
  def parse_header(kind, header) when is_map_key(@envelopes, kind),
    do: MacEnvelope.parse(Map.fetch!(@envelopes, kind), header)

  @doc """
  A request's authenticated fields under the service `key`, or the first
  refusal: `:unknown_version`, `:malformed`, `:outside_window`, `:bad_mac`. A control message
  verifies under the control key, an invoke under the key of the owner its
  header names. `now` is in Unix milliseconds.
  """
  @spec verify(kind(), binary(), term(), binary(), integer()) ::
          {:ok, map()} | {:error, auth_refusal()}
  def verify(kind, key, header, body, now)
      when is_map_key(@envelopes, kind) and byte_size(key) == 32 and is_binary(body) and
             is_integer(now) do
    envelope = Map.fetch!(@envelopes, kind)

    with {:ok, fields, mac, signing_key} <- parsed(kind, key, header, now),
         :ok <- authentic(MacEnvelope.verify(envelope, signing_key, fields, mac, body)) do
      {:ok, Map.delete(fields, :body_hash)}
    end
  end

  @doc """
  A request's authenticated fields and the body hash its header names,
  verified before the body is read: the same refusals as `verify/5`, in the
  same order, over the header alone. `verify_body/3` then checks the body
  read afterwards, and the pair refuses exactly what `verify/5` refuses.
  """
  @spec verify_header(kind(), binary(), term(), integer()) ::
          {:ok, map(), body_hash()} | {:error, auth_refusal()}
  def verify_header(kind, key, header, now)
      when is_map_key(@envelopes, kind) and byte_size(key) == 32 and is_integer(now) do
    envelope = Map.fetch!(@envelopes, kind)

    with {:ok, fields, mac, signing_key} <- parsed(kind, key, header, now),
         :ok <- authentic(MacEnvelope.verify_header(envelope, signing_key, fields, mac)) do
      {:ok, Map.delete(fields, :body_hash), fields.body_hash}
    end
  end

  @doc "Whether `body` is the one a verified header of `kind` named; another is `{:error, :bad_mac}`."
  @spec verify_body(kind(), body_hash(), binary()) :: :ok | {:error, :bad_mac}
  def verify_body(kind, body_hash, body)
      when is_map_key(@envelopes, kind) and is_binary(body_hash) and is_binary(body) do
    envelope = Map.fetch!(@envelopes, kind)

    if MacEnvelope.verify_body(envelope, %{body_hash: body_hash}, body),
      do: :ok,
      else: {:error, :bad_mac}
  end

  defp parsed(kind, key, header, now) do
    with {:ok, fields, mac} <- MacEnvelope.parse(Map.fetch!(@envelopes, kind), header),
         :ok <- within_window(fields.ts, now),
         {:ok, signing_key} <- signing_key(kind, key, fields) do
      {:ok, fields, mac, signing_key}
    end
  end

  defp signing_key(:control, key, _fields), do: {:ok, control_key(key)}

  # A parsed header's fields are valid field values, so its owner derives.
  defp signing_key(:invoke, key, fields) do
    case owner_key(key, Map.take(fields, Keyword.keys(@owner_fields))) do
      {:ok, owner_key} -> {:ok, owner_key}
      {:error, _invalid} -> {:error, :malformed}
    end
  end

  defp within_window(ts, now) when abs(ts - now) <= @window_ms, do: :ok
  defp within_window(_ts, _now), do: {:error, :outside_window}

  defp authentic(true), do: :ok
  defp authentic(false), do: {:error, :bad_mac}

  @doc """
  Seal a sync's environment JSON for one owner in one service lifetime.
  `iv` is 12 random bytes unless given.
  """
  @spec seal(binary(), owner(), String.t(), binary(), binary()) ::
          {:ok, String.t()} | {:error, MacEnvelope.invalid_field()}
  def seal(seal_key, owner, boot, plaintext, iv \\ :crypto.strong_rand_bytes(12))
      when byte_size(seal_key) == 32 and is_map(owner) and is_binary(plaintext) and
             byte_size(iv) == 12 do
    MacEnvelope.seal(
      seal_key,
      @label <> "/seal",
      @seal_fields,
      Map.put(owner, :boot, boot),
      plaintext,
      iv
    )
  end

  @doc "Open what `seal/5` sealed for the same owner and service lifetime."
  @spec open(binary(), owner(), String.t(), term()) ::
          {:ok, binary()} | {:error, :unsealable | MacEnvelope.invalid_field()}
  def open(seal_key, owner, boot, sealed) when byte_size(seal_key) == 32 and is_map(owner),
    do:
      MacEnvelope.open(
        seal_key,
        @label <> "/seal",
        @seal_fields,
        Map.put(owner, :boot, boot),
        sealed
      )

  # ————— control messages —————

  @doc "The body of a control message, checked as `read_control/1` will check it."
  @spec encode_control(control_message()) :: {:ok, binary()} | {:error, read_error()}
  def encode_control(%{type: type} = message) when type in @control_types do
    wire = message |> wire() |> Map.put("version", @version)

    with {:ok, _message} <- read_control_wire(wire),
         body = Jason.encode!(wire),
         :ok <- admit(byte_size(body), :control, @max_control_bytes) do
      {:ok, body}
    end
  end

  @doc "A control message's body, read strictly: its size, its version, its type, then every member."
  @spec read_control(binary()) :: {:ok, control_message()} | {:error, read_error()}
  def read_control(body) when is_binary(body) do
    with :ok <- admit(byte_size(body), :control, @max_control_bytes),
         {:ok, wire} <- object(body) do
      read_control_wire(wire)
    end
  end

  defp read_control_wire(wire) do
    with :ok <- current_version(wire),
         {:ok, type} <- control_type(wire),
         :ok <- exact(wire, Map.fetch!(@control_fields, type), "") do
      read_control_typed(type, wire)
    end
  end

  defp control_type(wire) do
    case Map.fetch(wire, "type") do
      {:ok, value} ->
        case Enum.find(@control_types, &(is_binary(value) and Atom.to_string(&1) == value)) do
          nil -> {:error, {:unknown_type, value}}
          type -> {:ok, type}
        end

      :error ->
        {:error, {:missing_field, "type"}}
    end
  end

  defp read_control_typed(:hello, wire) do
    with {:ok, g} <- positive(wire, "g", ""),
         {:ok, cyfr_boot} <- field_text(wire, "cyfr_boot", "") do
      {:ok, %{type: :hello, g: g, cyfr_boot: cyfr_boot}}
    end
  end

  defp read_control_typed(:reconcile, wire) do
    with {:ok, keep} <- owners(wire, "keep", [:e], nil),
         do: {:ok, %{type: :reconcile, keep: keep}}
  end

  defp read_control_typed(:sync, wire) do
    with {:ok, owner} <- owner(wire["owner"], "owner", []),
         {:ok, e} <- positive(wire, "e", ""),
         {:ok, lease_ms} <- period(wire, "lease_ms", @max_lease_ms),
         {:ok, idle_ms} <- period(wire, "idle_ms", @max_idle_ms),
         {:ok, backends} <- backends(wire["backends"]),
         {:ok, sealed} <- sealed(wire["sealed"]) do
      {:ok,
       %{
         type: :sync,
         owner: owner,
         e: e,
         lease_ms: lease_ms,
         idle_ms: idle_ms,
         backends: backends,
         sealed: sealed
       }}
    end
  end

  defp read_control_typed(:renew, wire) do
    with {:ok, lease_ms} <- period(wire, "lease_ms", @max_lease_ms),
         {:ok, owners} <- owners(wire, "owners", [:e], nil) do
      {:ok, %{type: :renew, lease_ms: lease_ms, owners: owners}}
    end
  end

  defp read_control_typed(:release, wire) do
    with {:ok, owners} <- owners(wire, "owners", [:e], nil),
         do: {:ok, %{type: :release, owners: owners}}
  end

  defp read_control_typed(:status, wire) do
    with {:ok, owners} <- owners(wire, "owners", [], @max_status_owners),
         do: {:ok, %{type: :status, owners: owners}}
  end

  defp period(wire, name, max) do
    case wire[name] do
      value when is_integer(value) and value > max -> {:error, {:out_of_range, name, value, max}}
      value when is_integer(value) and value >= 1 -> {:ok, value}
      _ -> {:error, {:invalid_field, name}}
    end
  end

  defp sealed(value) when is_binary(value) and value != "" do
    case Base.url_decode64(value, padding: false) do
      {:ok, _bytes} -> {:ok, value}
      :error -> {:error, {:invalid_field, "sealed"}}
    end
  end

  defp sealed(_value), do: {:error, {:invalid_field, "sealed"}}

  # A sync's backends: the count first, then each definition in order.
  defp backends(list) when is_list(list) and list != [] do
    if length(list) > @max_backends do
      {:error, {:too_many, :backends, length(list), @max_backends}}
    else
      list
      |> Enum.with_index()
      |> reduce_ok(MapSet.new(), fn {backend, index}, seen ->
        at = "backends[#{index}]"

        with {:ok, backend} <- backend(backend, at),
             false <- MapSet.member?(seen, backend.name) && {:error, {:duplicate, at <> ".name"}} do
          {:ok, backend, MapSet.put(seen, backend.name)}
        end
      end)
    end
  end

  defp backends(_list), do: {:error, {:invalid_field, "backends"}}

  defp backend(%{} = wire, at) do
    with :ok <- exact(wire, @backend_fields, at <> "."),
         {:ok, name} <- backend_name(wire["name"], at <> ".name"),
         {:ok, command} <- command(wire["command"], at <> ".command"),
         {:ok, env_names} <- env_names(wire["env_names"], at <> ".env_names") do
      {:ok, %{name: name, command: command, env_names: env_names}}
    end
  end

  defp backend(_wire, at), do: {:error, {:invalid_field, at}}

  defp backend_name(name, at) do
    if is_binary(name) and Regex.match?(@backend_name, name),
      do: {:ok, name},
      else: {:error, {:invalid_field, at}}
  end

  defp command(command, at) when is_binary(command) and command != "" do
    cond do
      byte_size(command) > @max_command_bytes ->
        {:error, {:too_large, :command, byte_size(command), @max_command_bytes}}

      String.contains?(command, <<0>>) ->
        {:error, {:invalid_field, at}}

      String.contains?(command, @vault_reference) ->
        {:error, {:vault_reference, at}}

      true ->
        {:ok, command}
    end
  end

  defp command(_command, at), do: {:error, {:invalid_field, at}}

  defp env_names(names, at) when is_list(names) do
    names
    |> Enum.with_index()
    |> reduce_ok(MapSet.new(), fn {name, index}, seen ->
      path = "#{at}[#{index}]"

      cond do
        not is_binary(name) or not Regex.match?(@env_name, name) ->
          {:error, {:invalid_field, path}}

        MapSet.member?(seen, name) ->
          {:error, {:duplicate, path}}

        name in reserved_env_names() or String.starts_with?(name, reserved_env_prefixes()) ->
          {:error, {:reserved_env_name, name}}

        true ->
          {:ok, name, MapSet.put(seen, name)}
      end
    end)
  end

  defp env_names(_names, at), do: {:error, {:invalid_field, at}}

  # ————— answers —————

  @doc "The body of the answer to a control message of `type`, checked as `read_answer/2` will check it."
  @spec encode_answer(control_type(), answer()) :: {:ok, binary()} | {:error, read_error()}
  def encode_answer(type, answer) when type in @control_types and is_map(answer) do
    wire = answer |> wire() |> Map.put("version", @version)

    with :ok <- exact(wire, Map.fetch!(@answer_fields, type), ""),
         {:ok, _answer} <- read_answer_typed(type, wire),
         body = Jason.encode!(wire),
         :ok <- admit_answer(type, byte_size(body)) do
      {:ok, body}
    end
  end

  @doc "The answer to a control message of `type`, read strictly: its size, its version, then every member."
  @spec read_answer(control_type(), binary()) :: {:ok, answer()} | {:error, read_error()}
  def read_answer(type, body) when type in @control_types and is_binary(body) do
    with :ok <- admit_answer(type, byte_size(body)),
         {:ok, wire} <- object(body),
         :ok <- current_version(wire),
         :ok <- exact(wire, Map.fetch!(@answer_fields, type), "") do
      read_answer_typed(type, wire)
    end
  end

  defp admit_answer(:status, bytes), do: admit(bytes, :status_answer, @max_status_answer_bytes)
  defp admit_answer(_type, bytes), do: admit(bytes, :answer, @max_control_bytes)

  defp read_answer_typed(:hello, wire) do
    with {:ok, boot} <- field_text(wire, "boot", ""),
         {:ok, pool} <- pool(wire["pool"]) do
      {:ok, %{boot: boot, pool: pool}}
    end
  end

  defp read_answer_typed(type, wire) when type in [:reconcile, :release] do
    with {:ok, released} <- owners(wire, "released", [:g, :e], nil),
         do: {:ok, %{released: released}}
  end

  defp read_answer_typed(:sync, wire) do
    with {:ok, status} <- roster(wire, "status", @owner_states, ""),
         {:ok, rev} <- count(wire, "rev", ""),
         {:ok, backends} <- list(wire, "backends", :backends, @max_backends, &backend_summary/2) do
      {:ok, %{status: status, rev: rev, backends: backends}}
    end
  end

  defp read_answer_typed(:renew, wire) do
    with {:ok, renewed} <- owners(wire, "renewed", [:e, :state, :rev], nil),
         {:ok, unknown} <- owners(wire, "unknown", [:e], nil) do
      {:ok, %{renewed: renewed, unknown: unknown}}
    end
  end

  defp read_answer_typed(:status, wire) do
    with {:ok, owners} <-
           owners(
             wire,
             "owners",
             [:g, :e, :state, :rev, :lease_ms_left, :backends],
             @max_status_owners
           ),
         do: {:ok, %{owners: owners}}
  end

  defp pool(%{} = wire) do
    with :ok <- exact(wire, ~w(size free), "pool."),
         {:ok, size} <- count(wire, "size", "pool."),
         {:ok, free} <- count(wire, "free", "pool.") do
      {:ok, %{size: size, free: free}}
    end
  end

  defp pool(_wire), do: {:error, {:invalid_field, "pool"}}

  defp backend_summary(%{} = wire, at) do
    with :ok <- exact(wire, ~w(name status tools), at <> "."),
         {:ok, name} <- backend_name(wire["name"], at <> ".name"),
         {:ok, status} <- roster(wire, "status", @backend_statuses, at <> "."),
         {:ok, tools} <- count(wire, "tools", at <> ".") do
      {:ok, %{name: name, status: status, tools: tools}}
    end
  end

  defp backend_summary(_wire, at), do: {:error, {:invalid_field, at}}

  defp backend_report(%{} = wire, at) do
    with :ok <- exact(wire, ~w(name status restarts tools error stderr_tail), at <> "."),
         {:ok, name} <- backend_name(wire["name"], at <> ".name"),
         {:ok, status} <- roster(wire, "status", @backend_statuses, at <> "."),
         {:ok, restarts} <- count(wire, "restarts", at <> "."),
         {:ok, tools} <- count(wire, "tools", at <> "."),
         {:ok, error} <- nullable_text(wire, "error", at <> "."),
         {:ok, stderr_tail} <- text(wire, "stderr_tail", at <> ".") do
      {:ok,
       %{
         name: name,
         status: status,
         restarts: restarts,
         tools: tools,
         error: error,
         stderr_tail: stderr_tail
       }}
    end
  end

  defp backend_report(_wire, at), do: {:error, {:invalid_field, at}}

  # ————— owners —————

  # A list of owners, each `athanor` and `server` and the members `extra`
  # names; a list past `max` is refused before any entry is read.
  defp owners(wire, name, extra, max) do
    case wire[name] do
      list when is_list(list) and is_integer(max) and length(list) > max ->
        {:error, {:too_many, :owners, length(list), max}}

      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> reduce_ok(nil, fn {entry, index}, nil ->
          with {:ok, owner} <- owner(entry, "#{name}[#{index}]", extra),
               do: {:ok, owner, nil}
        end)

      _ ->
        {:error, {:invalid_field, name}}
    end
  end

  defp owner(%{} = wire, at, extra) do
    names = ["athanor", "server" | Enum.map(extra, &Atom.to_string/1)]

    with :ok <- exact(wire, names, at <> "."),
         {:ok, athanor} <- field_text(wire, "athanor", at <> "."),
         {:ok, server} <- field_text(wire, "server", at <> ".") do
      Enum.reduce_while(extra, {:ok, %{athanor: athanor, server: server}}, fn member,
                                                                              {:ok, owner} ->
        case owner_member(member, wire, at <> ".") do
          {:ok, value} -> {:cont, {:ok, Map.put(owner, member, value)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp owner(_wire, at, _extra), do: {:error, {:invalid_field, at}}

  defp owner_member(member, wire, at) when member in [:g, :e],
    do: positive(wire, Atom.to_string(member), at)

  defp owner_member(member, wire, at) when member in [:rev, :lease_ms_left],
    do: count(wire, Atom.to_string(member), at)

  defp owner_member(:state, wire, at), do: roster(wire, "state", @owner_states, at)

  defp owner_member(:backends, wire, at) do
    case wire["backends"] do
      list when is_list(list) and length(list) <= @max_backends ->
        list
        |> Enum.with_index()
        |> reduce_ok(nil, fn {entry, index}, nil ->
          with {:ok, report} <- backend_report(entry, "#{at}backends[#{index}]"),
               do: {:ok, report, nil}
        end)

      list when is_list(list) ->
        {:error, {:too_many, :backends, length(list), @max_backends}}

      _ ->
        {:error, {:invalid_field, at <> "backends"}}
    end
  end

  # ————— refusals —————

  @doc "The body a refusal is answered with: `{\"version\": 1, \"error\": <code>}`."
  @spec encode_refusal(refusal()) :: binary()
  def encode_refusal(refusal),
    do: Jason.encode!(%{"version" => @version, "error" => Atom.to_string(code(refusal))})

  @doc "A refusal's body, read strictly to its code."
  @spec read_refusal(binary()) :: {:ok, code()} | {:error, read_error()}
  def read_refusal(body) when is_binary(body) do
    with :ok <- admit(byte_size(body), :answer, @max_control_bytes),
         {:ok, wire} <- object(body),
         :ok <- current_version(wire),
         :ok <- exact(wire, ~w(version error), "") do
      roster(wire, "error", @classes, "")
    end
  end

  @doc """
  The refusal a body that does not read is answered with: `version` naming
  both versions for a body at another version, `too_large` for a control
  body past its bound, `too_many_owners` and `status_too_large` for a status
  past its bounds, and `bad_request` for anything else.
  """
  @spec refusal_for(read_error()) :: refusal()
  def refusal_for({:version, presented}) when is_integer(presented) and presented > 0,
    do: {:protocol_mismatch, @version, presented}

  def refusal_for({:version, _presented}), do: {:protocol_mismatch, @version, nil}
  def refusal_for({:too_large, :control, _bytes, _max}), do: :too_large
  def refusal_for({:too_large, :status_answer, _bytes, _max}), do: :status_too_large
  def refusal_for({:too_many, :owners, _count, _max}), do: :too_many_owners
  def refusal_for(_error), do: :bad_request

  @doc "Why a body did not read, as a sentence."
  @spec describe(read_error()) :: String.t()
  def describe(:not_json), do: "the body is not a JSON object"
  def describe({:version, nil}), do: "the body names no protocol version"

  def describe({:version, presented}),
    do: "the body speaks protocol #{inspect(presented)}, not #{@version}"

  def describe({:unknown_type, type}), do: "#{inspect(type)} is not a control message type"
  def describe({:unknown_field, name}), do: "#{name} is not a field of this message"
  def describe({:missing_field, name}), do: "#{name} is required"
  def describe({:invalid_field, name}), do: "#{name} is not of the form this message takes"

  def describe({:too_large, :command, bytes, max}),
    do: "a command is #{bytes} bytes; at most #{max} are accepted"

  def describe({:too_large, what, bytes, max}),
    do: "the #{what} body is #{bytes} bytes; at most #{max} are read"

  def describe({:too_many, what, count, max}),
    do: "the message names #{count} #{what}; at most #{max} are accepted"

  def describe({:out_of_range, name, value, max}),
    do: "#{name} is #{value}; at most #{max} is accepted"

  def describe({:duplicate, name}), do: "#{name} is named twice"
  def describe({:vault_reference, name}), do: "#{name} names a vault reference"

  def describe({:reserved_env_name, name}),
    do: "#{name} is a variable name no backend may define"

  # ————— masking —————

  @doc """
  `value` with every one of `secrets` replaced, in every string of it and
  every map key, recursively. Each secret is replaced whole and, for a
  scheme-prefixed value (`Bearer <token>`), as its last space-separated
  part; a value or part under eight bytes is not replaced. Longer values
  are replaced first, so one containing another is replaced whole.
  """
  @spec mask(term(), [String.t()]) :: term()
  def mask(value, secrets) when is_list(secrets), do: replace(value, masked_values(secrets))

  defp masked_values(secrets) do
    secrets
    |> Enum.flat_map(fn secret when is_binary(secret) ->
      [secret, secret |> String.split(" ") |> List.last()]
    end)
    |> Enum.filter(&(byte_size(&1) >= @min_masked_bytes))
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp replace(value, []), do: value

  defp replace(text, secrets) when is_binary(text),
    do: Enum.reduce(secrets, text, &String.replace(&2, &1, @mask_marker))

  defp replace(list, secrets) when is_list(list), do: Enum.map(list, &replace(&1, secrets))

  defp replace(%{} = map, secrets) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {replace(key, secrets), replace(value, secrets)} end)

  defp replace(value, _secrets), do: value

  # ————— reading —————

  defp admit(bytes, _what, max) when bytes <= max, do: :ok
  defp admit(bytes, what, max), do: {:error, {:too_large, what, bytes, max}}

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
      extra = Enum.find(Map.keys(wire) |> Enum.sort(), &(&1 not in names)) ->
        {:error, {:unknown_field, at <> extra}}

      missing = Enum.find(names, &(not is_map_key(wire, &1))) ->
        {:error, {:missing_field, at <> missing}}

      true ->
        :ok
    end
  end

  # Signed field text: the rule a header holds an owner's names to.
  defp field_text(wire, name, at) do
    value = wire[name]

    if MacEnvelope.valid_value?(:string, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, at <> name}}
  end

  defp positive(wire, name, at) do
    value = wire[name]

    if is_integer(value) and value > 0 and MacEnvelope.valid_value?(:integer, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, at <> name}}
  end

  defp count(wire, name, at) do
    value = wire[name]

    if MacEnvelope.valid_value?(:integer, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, at <> name}}
  end

  defp roster(wire, name, roster, at) do
    value = wire[name]

    case Enum.find(roster, &(is_binary(value) and Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_field, at <> name}}
      atom -> {:ok, atom}
    end
  end

  defp text(wire, name, at) do
    case wire[name] do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, at <> name}}
    end
  end

  defp nullable_text(wire, name, at) do
    case wire[name] do
      nil -> {:ok, nil}
      _value -> text(wire, name, at)
    end
  end

  defp list(wire, name, what, max, read) do
    case wire[name] do
      list when is_list(list) and length(list) <= max ->
        list
        |> Enum.with_index()
        |> reduce_ok(nil, fn {entry, index}, nil ->
          with {:ok, item} <- read.(entry, "#{name}[#{index}]"), do: {:ok, item, nil}
        end)

      list when is_list(list) ->
        {:error, {:too_many, what, length(list), max}}

      _ ->
        {:error, {:invalid_field, name}}
    end
  end

  # Reads each entry with `fun`, which answers `{:ok, item, acc}` or an
  # error; the items in order, or the first error.
  defp reduce_ok(entries, acc, fun) do
    Enum.reduce_while(entries, {:ok, [], acc}, fn entry, {:ok, items, acc} ->
      case fun.(entry, acc) do
        {:ok, item, acc} -> {:cont, {:ok, [item | items], acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, _acc} -> {:ok, Enum.reverse(items)}
      {:error, _} = error -> error
    end
  end

  # A typed message or answer as its wire map: atom keys and atom values as
  # strings, `nil` and booleans as they are.
  defp wire(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), wire(value)} end)

  defp wire(list) when is_list(list), do: Enum.map(list, &wire/1)

  defp wire(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp wire(value), do: value
end
