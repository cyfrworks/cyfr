# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusBackends do
  @moduledoc """
  The wire between CYFR's programs controller (`Opus.Programs`, and the
  owners that speak over its sessions, such as `Emissary.External.Server`)
  and the backends service Locus serves: the programs CYFR registers, one
  owner per athanor and `mcp_servers` row. The second service of the
  `cyfr-locus/v1` domain beside `Prima.BuilderProtocol`. Data and codec
  only — no process and no HTTP live here.
  `tests/fixtures/locus_backends.json` holds the vectors every end
  reproduces.

  The wire carries processes and lines, never what the lines mean: a
  program is a process whose lines go to and from one owner, and the owner
  speaks whatever protocol it speaks over them (Emissary MCP to a `stdio`
  server, a catalyst a harness's protocol to a `pipe` program).

  ## Routes

  | Operation | Route | Body | Answer |
  |---|---|---|---|
  | `:health` | `/locus/v1/backends/health` | `{"version": 2}` | unauthenticated |
  | `:control` | `/locus/v1/backends/control` | a control message | its answer, or a refusal |
  | `:session` | `/locus/v1/backends/session` | a session message | its answer, or a refusal |

  Every answer carries `x-cyfr-boot` (`boot_header/0`), the service's
  lifetime, which a control message names back.

  ## Control messages (`encode_control/1`, `read_control/1`)

  A member marked `?` is optional: absent when it has no value, and never
  `null`, the presence rule of every wire of the island; a present member
  holds a value of its form. Every body and every answer, the health
  probe's included, carries `"version"` (`version/0`); a body at another version, or without one, is
  read as `{:error, {:version, presented}}` before its `type` is, and
  refused `version` (`refusal_for/1`). Each type has exactly its members:

  | Type | Members | Answer (`encode_answer/2`, `read_answer/2`) |
  |---|---|---|
  | `hello` | `g`, `cyfr_boot` | `boot`, `pool{size, free}` |
  | `reconcile` | `keep[{athanor, server, e}]` | `released[{athanor, server, g, e}]` |
  | `sync` | `owner{athanor, server}`, `e`, `lease_ms`, `idle_ms`, `programs[]`, `sealed` | `status`, `programs[{name, status}]` |
  | `renew` | `lease_ms`, `owners[{athanor, server, e}]` | `renewed[{athanor, server, e, state}]`, `unknown[{athanor, server, e}]` |
  | `release` | `owners[{athanor, server, e}]` | `released[{athanor, server, g, e}]` |
  | `status` | `owners[{athanor, server}]` | `owners[{athanor, server, g, e, state, lease_ms_left, programs[]}]` |
  | `home` | `op`, `athanor`, `home_id` | `home_id`, `state` |

  A sync's program is `{name, command, login_command?, env_names, home,
  memory_bytes?, home_max_bytes?}`: a `name` of lowercase letters, digits
  and hyphens, a `command` and an optional `login_command` each meeting
  `check_command/1`, the `env_names` its sealed
  environment carries (each an uppercase variable name, none reserved:
  `reserved_env_names/0`, `reserved_env_prefixes/0`), its `home`
  (`"scratch"`, scrubbed at retirement, or `"kept"`, one folder per login
  entry that survives retirement), its `memory_bytes` (absent: the
  service's own bound, `LOCUS_BACKENDS_MEMORY_BYTES`, bounds each process)
  and, for a kept home only, its `home_max_bytes` (absent: the homes
  volume is the only bound). `sealed` is the environment `seal/5` sealed
  to the owner and the service's lifetime.

  A status reports each program as `{name, status, restarts, error?,
  stderr_tail, home, home_bytes?, over_cap, sessions}`: its status
  (`program_statuses/0`: `idle` with no process running, `running` with
  one, `failed` once `max_crashes/0` processes crashed within
  `crash_window_ms/0`), the processes that crashed since its sync, the
  last crash (absent before one), the masked tail of its stderr, its home
  mode, the bytes its kept homes last measured (absent for a scratch home
  or one never measured), whether one of them is over its cap, and its running
  sessions.

  A `home` message acts on one kept home of one athanor: `op` `reset` ends
  every session in the home `home_id` names and makes it again empty under
  the same uid (`state` `empty`); `op` `retire` ends them and removes the
  home, freeing its uid (`state` `absent`). The box that holds a home
  draws its uid, from the kept-home range its keeper is given, when the
  home is first made, at the first `open` that names it.

  An owner's `athanor` and `server` are signed field text
  (`Prima.MacEnvelope`); a generation `g` and an epoch `e` are positive
  integers. `lease_ms` is at most `max_lease_ms/0` and `idle_ms` at most
  `max_idle_ms/0`, each at least 1. A sync names 1 to `max_programs/0`
  programs. A status names at most `max_status_owners/0` owners, and its
  answer is at most `max_status_answer_bytes/0` bytes, refused whole past
  either bound.

  ## Session messages (`encode_session/1`, `read_session/1`)

  A session is one running process of one program, for one
  `(program, home_id, key)`, with a sequence-numbered buffer of the lines
  its stdout writes. Each message names its owner and epoch, which must be
  the ones its signature names:

  | Type | Members | Answer (`encode_session_answer/2`, `read_session_answer/2`) |
  |---|---|---|
  | `open` | `owner`, `e`, `program`, `home_id?`, `key`, `mode`, `argv[]` | `status`, `session`, `resumed`, `pty` |
  | `send` | `owner`, `e`, `session`, `lines[]` | `status` |
  | `recv` | `owner`, `e`, `session`, `after`, `max_wait_ms` | `lines[{seq, text}]`, `dropped`, `running` |
  | `close` | `owner`, `e`, `session` | `status` |

  An `open` in mode `run` attaches to the session running for its key
  (`resumed: true`) or starts the program's `command` with `argv` appended
  as its arguments (`resumed: false`): the administrator allowed the
  program, and its arguments shape only what runs inside its box. An open
  in mode `sign_in` runs the program's `login_command` on a
  pseudo-terminal (`pty: true`), takes no `argv`, and is one session per
  key. `home_id` names the kept home the process runs in (the login
  entry's id: `home_id_pattern/0`), present for a program whose home is
  kept and absent for any other. A `sign_in` open needs a kept home.

  A line is at most `max_line_bytes/0` bytes; a process that writes a
  longer one is killed. The buffer keeps every line until a later `recv`
  names an `after` at or above its sequence number, and at most
  `max_buffer_bytes/0` bytes: past that the oldest lines are dropped and
  counted, and a `recv` answers in `dropped` how many lines between its
  `after` and its first line were dropped. A `recv` waits up to
  `max_wait_ms` (at most `max_recv_wait_ms/0`) for a line past `after` or
  the process's end, and is idempotent: a lost answer is replayed by the
  same `after`. A session whose process ended answers `running: false` on
  every later `recv`, and the next `open` with its key answers `resumed:
  false`; an owner that speaks a protocol over a session starts it again
  then. A `send` to an ended session answers `status` `ended`, and one to
  a running session `running`. `close` ends the session's process and
  answers `closed`. A session's idle period is the owner's `idle_ms`: a
  session with no `send` and no `recv` within it is ended.

  ## Refusals

  A refusal is answered at its code's HTTP status (`status/1`) as
  `{"version": 2, "error": <code>}` (`encode_refusal/1`).

  ## Authentication

  One 32-byte service key (64 hexadecimal digits,
  `Prima.MacEnvelope.decode_root/1`) is shared by CYFR and the service.
  From it, over the label `cyfr-locus/v1/backends`, derive the **control
  key** (`<label>/control`), which signs control messages; the **seal
  key** (`<label>/seal`), which seals a sync's environment; and one
  **owner key** per athanor, server row, generation and epoch
  (`<label>/owner` and those four fields), which signs that owner's
  session messages and is the only key the owner holds. A signature is
  `Prima.MacEnvelope`'s with the label as its prefix, carried in the
  `x-cyfr-auth` header (`auth_header/0`); the header names the body's
  hash, so it verifies before the body is read (`verify_header/4`, then
  `verify_body/3`). The kinds are `control` (`generation`, `seq`,
  `cyfr_boot`, `boot`, `ts`) and `invoke` (`athanor`, `server`,
  `generation`, `epoch`, `boot`, `ts`, `nonce`), in that order, with
  `generation` written `gen` in the header; a session message is signed
  as an `invoke`. A listener refuses, in order, `:unknown_version` (a
  version token other than `v1`, such as `v2`), `:malformed`,
  `:outside_window` (`ts` further than `window_ms/0` from its clock) and
  `:bad_mac`. Neither the builds key nor a header of the builds service
  verifies here. The fences — lifetime, sequence, owner version and nonce
  — are the service's, against state this module does not hold.

  ## Masking

  Everything an owner's programs produce that leaves the service passes
  through `mask/2`, which replaces each of the owner's credential values
  of at least eight bytes, whole and after a scheme prefix (`Bearer
  <token>`), with `[REDACTED]`. Only the variables `literal_env_names/0`
  names hold a literal value rather than a credential.
  """

  alias Prima.{KeeperProtocol, MacEnvelope, VaultRef}

  @version 2
  @domain MacEnvelope.domain()
  @service MacEnvelope.service(:backends)
  @label MacEnvelope.label(:backends)
  @auth_header MacEnvelope.auth_header()
  @boot_header "x-cyfr-boot"
  @window_ms Prima.BuilderProtocol.window_ms()
  @routes %{
    health: "/locus/v1/backends/health",
    control: "/locus/v1/backends/control",
    session: "/locus/v1/backends/session"
  }

  # A control message is at most a sync of sixteen programs and its sealed
  # environment. A session body or answer is at most a buffer's worth of
  # lines escaped as JSON escapes them, which a line of control bytes can
  # grow up to six times; a `recv` answers as many whole lines as fit.
  @max_control_bytes 1_048_576
  @max_line_bytes 1_048_576
  @max_buffer_bytes 8_388_608
  @max_session_bytes 16_777_216
  @max_recv_wait_ms 30_000
  @max_status_owners 64
  @max_status_answer_bytes @max_control_bytes
  @max_programs 16
  @max_sessions 16
  @max_argv 64
  @max_key_bytes 128
  @max_command_bytes 4_096
  @max_nonces 8_192
  @nonce_window_ms @window_ms
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
    max_line_bytes: @max_line_bytes,
    max_buffer_bytes: @max_buffer_bytes,
    max_session_bytes: @max_session_bytes,
    max_recv_wait_ms: @max_recv_wait_ms,
    max_status_owners: @max_status_owners,
    max_status_answer_bytes: @max_status_answer_bytes,
    max_programs: @max_programs,
    max_sessions: @max_sessions,
    max_argv: @max_argv,
    max_key_bytes: @max_key_bytes,
    max_command_bytes: @max_command_bytes,
    max_nonces: @max_nonces,
    nonce_window_ms: @nonce_window_ms,
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
    unknown_program: 409,
    unknown_session: 409,
    program_failed: 409,
    home_over_cap: 409,
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

  @control_types [:hello, :reconcile, :sync, :renew, :release, :status, :home]
  @session_types [:open, :send, :recv, :close]
  @owner_states [:running, :draining]
  @program_statuses [:idle, :running, :failed]
  @homes [:scratch, :kept]
  @modes [:run, :sign_in]
  @home_ops [:reset, :retire]
  @home_states [:empty, :absent]

  @control_fields %{
    hello: ~w(version type g cyfr_boot),
    reconcile: ~w(version type keep),
    sync: ~w(version type owner e lease_ms idle_ms programs sealed),
    renew: ~w(version type lease_ms owners),
    release: ~w(version type owners),
    status: ~w(version type owners),
    home: ~w(version type op athanor home_id)
  }
  @answer_fields %{
    hello: ~w(version boot pool),
    reconcile: ~w(version released),
    sync: ~w(version status programs),
    renew: ~w(version renewed unknown),
    release: ~w(version released),
    status: ~w(version owners),
    home: ~w(version home_id state)
  }
  @session_fields %{
    open: ~w(version type owner e program key mode argv),
    send: ~w(version type owner e session lines),
    recv: ~w(version type owner e session after max_wait_ms),
    close: ~w(version type owner e session)
  }
  @session_answer_fields %{
    open: ~w(version status session resumed pty),
    send: ~w(version status),
    recv: ~w(version lines dropped running),
    close: ~w(version status)
  }
  @session_optional %{open: ~w(home_id)}
  @program_fields ~w(name command env_names home)
  @program_optional ~w(login_command memory_bytes home_max_bytes)
  @program_report_fields ~w(name status restarts stderr_tail home over_cap sessions)
  @program_report_optional ~w(error home_bytes)
  @program_name ~r/\A[a-z0-9][a-z0-9-]{0,31}\z/
  @home_id ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @session_id ~r/\Ass_[0-9a-f]{32}\z/
  @key_text ~r/\A[A-Za-z0-9][A-Za-z0-9._:@-]*\z/
  @env_name ~r/\A[A-Z_][A-Z0-9_]{0,63}\z/

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

  @type operation :: :health | :control | :session
  @type kind :: :invoke | :control
  @type control_type :: :hello | :reconcile | :sync | :renew | :release | :status | :home
  @type session_type :: :open | :send | :recv | :close
  @type owner_state :: :running | :draining
  @type program_status :: :idle | :running | :failed
  @type home :: :scratch | :kept
  @type mode :: :run | :sign_in
  @type home_op :: :reset | :retire
  @type session_status :: :running | :ended | :closed
  @type home_state :: :empty | :absent

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

  @typedoc "One program a sync defines."
  @type program :: %{
          name: String.t(),
          command: String.t(),
          login_command: String.t() | nil,
          env_names: [String.t()],
          home: home(),
          memory_bytes: pos_integer() | nil,
          home_max_bytes: pos_integer() | nil
        }

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
              programs: [program()],
              sealed: String.t()
            }
          | %{type: :renew, lease_ms: pos_integer(), owners: [owner_epoch()]}
          | %{type: :release, owners: [owner_epoch()]}
          | %{type: :status, owners: [owner_ref()]}
          | %{type: :home, op: home_op(), athanor: String.t(), home_id: String.t()}

  @typedoc "A program as a status answer reports it."
  @type program_report :: %{
          name: String.t(),
          status: program_status(),
          restarts: non_neg_integer(),
          error: String.t() | nil,
          stderr_tail: String.t(),
          home: home(),
          home_bytes: non_neg_integer() | nil,
          over_cap: boolean(),
          sessions: non_neg_integer()
        }

  @typedoc "An owner as a status answer reports it."
  @type owner_report :: %{
          athanor: String.t(),
          server: String.t(),
          g: pos_integer(),
          e: pos_integer(),
          state: owner_state(),
          lease_ms_left: non_neg_integer(),
          programs: [program_report()]
        }

  @typedoc "A control answer, by the type of the message it answers."
  @type answer ::
          %{boot: String.t(), pool: %{size: non_neg_integer(), free: non_neg_integer()}}
          | %{released: [owner_version()]}
          | %{status: owner_state(), programs: [%{name: String.t(), status: program_status()}]}
          | %{
              renewed: [
                %{athanor: String.t(), server: String.t(), e: pos_integer(), state: owner_state()}
              ],
              unknown: [owner_epoch()]
            }
          | %{owners: [owner_report()]}
          | %{home_id: String.t(), state: home_state()}

  @typedoc "A session message by its `type`."
  @type session_message ::
          %{
            type: :open,
            owner: owner_ref(),
            e: pos_integer(),
            program: String.t(),
            home_id: String.t() | nil,
            key: String.t(),
            mode: mode(),
            argv: [String.t()]
          }
          | %{
              type: :send,
              owner: owner_ref(),
              e: pos_integer(),
              session: String.t(),
              lines: [String.t()]
            }
          | %{
              type: :recv,
              owner: owner_ref(),
              e: pos_integer(),
              session: String.t(),
              after: non_neg_integer(),
              max_wait_ms: non_neg_integer()
            }
          | %{type: :close, owner: owner_ref(), e: pos_integer(), session: String.t()}

  @typedoc "One buffered line, by its sequence number."
  @type line :: %{seq: pos_integer(), text: String.t()}

  @typedoc "A session answer, by the type of the message it answers."
  @type session_answer ::
          %{status: :running, session: String.t(), resumed: boolean(), pty: boolean()}
          | %{status: session_status()}
          | %{lines: [line()], dropped: non_neg_integer(), running: boolean()}

  @type code ::
          :unauthorized
          | :stale_boot
          | :stale_control
          | :stale_epoch
          | :conflict
          | :lapsed
          | :epoch_ahead
          | :unknown_owner
          | :unknown_program
          | :unknown_session
          | :program_failed
          | :home_over_cap
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
  does not accept (named by its path, `programs[1].command`); a bound
  passed (what, the size seen, the bound); a period past its bound; a
  program or variable named twice; a command naming a vault reference; a
  reserved variable.
  """
  @type read_error ::
          :not_json
          | {:version, term()}
          | {:unknown_type, term()}
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:too_large, :control | :answer | :status_answer | :session | :command | :line,
             non_neg_integer(), pos_integer()}
          | {:too_many, :owners | :programs | :argv, non_neg_integer(), pos_integer()}
          | {:out_of_range, String.t(), integer(), pos_integer()}
          | {:duplicate, String.t()}
          | {:vault_reference, String.t()}
          | {:reserved_env_name, String.t()}

  @type auth_refusal :: :unknown_version | :malformed | :outside_window | :bad_mac

  @typedoc "The hex SHA-256 a verified header names as its body's."
  @type body_hash :: String.t()

  # ————— the protocol as data —————

  @doc "The protocol this release speaks, carried in every body and answer."
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

  @doc "The session message types."
  @spec session_types() :: [session_type()]
  def session_types, do: @session_types

  @doc "What a status reports a program as: `idle`, `running` or `failed`."
  @spec program_statuses() :: [program_status()]
  def program_statuses, do: @program_statuses

  @doc "A program's home modes: `scratch`, scrubbed at retirement, and `kept`."
  @spec homes() :: [home()]
  def homes, do: @homes

  @doc "An open's modes: `run` and `sign_in`."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The form a kept home's id takes: a login entry's id."
  @spec home_id_pattern() :: Regex.t()
  def home_id_pattern, do: @home_id

  @doc "Whether `id` is a kept home's id."
  @spec home_id?(term()) :: boolean()
  def home_id?(id), do: is_binary(id) and Regex.match?(@home_id, id)

  @doc "Every bound of the wire by name."
  @spec bounds() :: %{atom() => pos_integer() | [pos_integer()] | [String.t()]}
  def bounds, do: @bounds

  @doc "The bytes a control body or a control answer may be."
  @spec max_control_bytes() :: pos_integer()
  def max_control_bytes, do: @max_control_bytes

  @doc "The bytes one line of a session may be, its newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The bytes of lines a session's buffer holds before it drops the oldest."
  @spec max_buffer_bytes() :: pos_integer()
  def max_buffer_bytes, do: @max_buffer_bytes

  @doc "The bytes a session body or a session answer may be."
  @spec max_session_bytes() :: pos_integer()
  def max_session_bytes, do: @max_session_bytes

  @doc "The longest a `recv` may wait for a line, in milliseconds."
  @spec max_recv_wait_ms() :: pos_integer()
  def max_recv_wait_ms, do: @max_recv_wait_ms

  @doc "The owners one status may name."
  @spec max_status_owners() :: pos_integer()
  def max_status_owners, do: @max_status_owners

  @doc "The bytes a status answer may be, measured as it is sent."
  @spec max_status_answer_bytes() :: pos_integer()
  def max_status_answer_bytes, do: @max_status_answer_bytes

  @doc "The programs one sync may define."
  @spec max_programs() :: pos_integer()
  def max_programs, do: @max_programs

  @doc "The sessions one owner may hold at once, running or ended."
  @spec max_sessions() :: pos_integer()
  def max_sessions, do: @max_sessions

  @doc "The arguments one `open` may append to its program's command."
  @spec max_argv() :: pos_integer()
  def max_argv, do: @max_argv

  @doc "The bytes an `open`'s key may be."
  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @doc "The bytes a program's command, or one argument of an `open`, may be."
  @spec max_command_bytes() :: pos_integer()
  def max_command_bytes, do: @max_command_bytes

  @doc """
  Whether `command` is a command an administrator may give a program: a
  string with text beyond whitespace, of at most `max_command_bytes/0`
  bytes, with no NUL byte and no `vault:` in any case, since every process
  on the service can read a command line, so a credential never goes in
  one. Refused `:not_a_string`, `:empty`, `:too_long`, `:nul` or
  `:vault_reference`. A program's command and login command
  (`Emissary.External.BackendDefinition`) and the program a manifest's
  login need suggests (`Prima.Manifest.Needs`) are held to it.
  """
  @spec check_command(term()) ::
          :ok | {:error, :not_a_string | :empty | :too_long | :nul | :vault_reference}
  def check_command(command) when is_binary(command) do
    cond do
      String.trim(command) == "" -> {:error, :empty}
      byte_size(command) > @max_command_bytes -> {:error, :too_long}
      String.contains?(command, <<0>>) -> {:error, :nul}
      String.contains?(String.downcase(command), VaultRef.prefix()) -> {:error, :vault_reference}
      true -> :ok
    end
  end

  def check_command(_command), do: {:error, :not_a_string}

  @doc "The nonces one owner's replay cache holds."
  @spec max_nonces() :: pos_integer()
  def max_nonces, do: @max_nonces

  @doc "How long a nonce is held after its timestamp, in milliseconds: the header window."
  @spec nonce_window_ms() :: pos_integer()
  def nonce_window_ms, do: @nonce_window_ms

  @doc "The bytes of a program's stderr a status reports: its tail."
  @spec stderr_tail_bytes() :: pos_integer()
  def stderr_tail_bytes, do: @stderr_tail_bytes

  @doc "The raw stderr kept beyond the tail, so a credential split by the cut is masked before it is taken."
  @spec stderr_tail_slack_bytes() :: pos_integer()
  def stderr_tail_slack_bytes, do: @stderr_tail_slack_bytes

  @doc "The waits before each start of a program after a crash, in milliseconds."
  @spec restart_backoff_ms() :: [pos_integer()]
  def restart_backoff_ms, do: @restart_backoff_ms

  @doc "The period, in milliseconds, within which `max_crashes/0` crashes mark a program failed."
  @spec crash_window_ms() :: pos_integer()
  def crash_window_ms, do: @crash_window_ms

  @doc "The crashes within `crash_window_ms/0` that mark a program failed."
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
  program's value for one of these is not masked. Every other value is a
  credential from the vault.
  """
  @spec literal_env_names() :: [String.t()]
  def literal_env_names, do: @literal_env_names

  @doc "The variable names no program may define: the keeper's (`Prima.KeeperProtocol`)."
  @spec reserved_env_names() :: [String.t()]
  def reserved_env_names, do: KeeperProtocol.reserved_env_names()

  @doc "The variable name prefixes no program may define: the keeper's (`Prima.KeeperProtocol`)."
  @spec reserved_env_prefixes() :: [String.t()]
  def reserved_env_prefixes, do: KeeperProtocol.reserved_env_prefixes()

  # ————— authentication —————

  @doc "The key control messages are signed with."
  @spec control_key(binary()) :: binary()
  def control_key(key) when byte_size(key) == 32,
    do: MacEnvelope.derive(key, @label <> "/control")

  @doc "The key a sync's environment is sealed with."
  @spec seal_key(binary()) :: binary()
  def seal_key(key) when byte_size(key) == 32, do: MacEnvelope.derive(key, @label <> "/seal")

  @doc "The key one owner, at one generation and epoch, signs its session messages with."
  @spec owner_key(binary(), owner()) :: {:ok, binary()} | {:error, MacEnvelope.invalid_field()}
  def owner_key(key, owner) when byte_size(key) == 32 and is_map(owner),
    do: MacEnvelope.derive(key, @label <> "/owner", @owner_fields, owner)

  @doc "The `x-cyfr-auth` header for a session message of `body`, signed with the owner's key."
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
  A request's authenticated fields under the service `key`, or the first
  refusal: `:unknown_version`, `:malformed`, `:outside_window`, `:bad_mac`.
  A control message verifies under the control key, a session message (an
  invoke) under the key of the owner its header names. `now` is in Unix
  milliseconds.
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

  # ————— the health probe —————

  @doc "The health probe's body: `{\"version\": 2}`."
  @spec health_body() :: binary()
  def health_body, do: Jason.encode!(%{"version" => @version})

  @doc """
  A health probe's body, read strictly: exactly `{"version": 2}`. Another
  version, or none, is `{:error, {:version, presented}}`; anything else
  `:not_json` or `{:unknown_field, name}`.
  """
  @spec read_health(binary()) :: :ok | {:error, read_error()}
  def read_health(body) when is_binary(body) do
    with {:ok, wire} <- object(body),
         :ok <- current_version(wire),
         :ok <- exact(wire, ~w(version), "") do
      :ok
    end
  end

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
         {:ok, type} <- typed(wire, @control_types),
         :ok <- exact(wire, Map.fetch!(@control_fields, type), "") do
      read_control_typed(type, wire)
    end
  end

  defp typed(wire, types) do
    case Map.fetch(wire, "type") do
      {:ok, value} ->
        case Enum.find(types, &(is_binary(value) and Atom.to_string(&1) == value)) do
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
         {:ok, programs} <- programs(wire["programs"]),
         {:ok, sealed} <- sealed(wire["sealed"]) do
      {:ok,
       %{
         type: :sync,
         owner: owner,
         e: e,
         lease_ms: lease_ms,
         idle_ms: idle_ms,
         programs: programs,
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

  defp read_control_typed(:home, wire) do
    with {:ok, op} <- roster(wire, "op", @home_ops, ""),
         {:ok, athanor} <- field_text(wire, "athanor", ""),
         {:ok, home_id} <- home_id_member(wire, "home_id", "") do
      {:ok, %{type: :home, op: op, athanor: athanor, home_id: home_id}}
    end
  end

  defp home_id_member(wire, name, at) do
    value = wire[name]
    if home_id?(value), do: {:ok, value}, else: {:error, {:invalid_field, at <> name}}
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

  # A sync's programs: the count first, then each definition in order.
  defp programs(list) when is_list(list) and list != [] do
    if length(list) > @max_programs do
      {:error, {:too_many, :programs, length(list), @max_programs}}
    else
      list
      |> Enum.with_index()
      |> reduce_ok(MapSet.new(), fn {program, index}, seen ->
        at = "programs[#{index}]"

        with {:ok, program} <- program(program, at),
             false <- MapSet.member?(seen, program.name) && {:error, {:duplicate, at <> ".name"}} do
          {:ok, program, MapSet.put(seen, program.name)}
        end
      end)
    end
  end

  defp programs(_list), do: {:error, {:invalid_field, "programs"}}

  defp program(%{} = wire, at) do
    with :ok <- exact(wire, @program_fields, @program_optional, at <> "."),
         {:ok, name} <- program_name(wire["name"], at <> ".name"),
         {:ok, command} <- command(wire["command"], at <> ".command"),
         {:ok, login_command} <-
           optional(wire, "login_command", &command(&1, at <> ".login_command")),
         {:ok, env_names} <- env_names(wire["env_names"], at <> ".env_names"),
         {:ok, home} <- roster(wire, "home", @homes, at <> "."),
         {:ok, memory_bytes} <-
           optional(wire, "memory_bytes", &memory_bytes(&1, at <> ".memory_bytes")),
         {:ok, home_max_bytes} <-
           optional(wire, "home_max_bytes", &home_max_bytes(&1, home, at <> ".home_max_bytes")) do
      {:ok,
       %{
         name: name,
         command: command,
         login_command: login_command,
         env_names: env_names,
         home: home,
         memory_bytes: memory_bytes,
         home_max_bytes: home_max_bytes
       }}
    end
  end

  defp program(_wire, at), do: {:error, {:invalid_field, at}}

  defp memory_bytes(value, at) do
    if is_integer(value) and value >= KeeperProtocol.min_memory_bytes() and
         value <= KeeperProtocol.max_memory_bytes(),
       do: {:ok, value},
       else: {:error, {:invalid_field, at}}
  end

  # A disk bound is a kept home's alone.
  defp home_max_bytes(value, :kept, at) do
    if is_integer(value) and value >= 1 and
         value <= KeeperProtocol.request_bounds().max_home_bytes,
       do: {:ok, value},
       else: {:error, {:invalid_field, at}}
  end

  defp home_max_bytes(_value, _home, at), do: {:error, {:invalid_field, at}}

  defp program_name(name, at) do
    if is_binary(name) and Regex.match?(@program_name, name),
      do: {:ok, name},
      else: {:error, {:invalid_field, at}}
  end

  defp command(command, at) when is_binary(command) do
    case check_command(command) do
      :ok ->
        {:ok, command}

      {:error, :too_long} ->
        {:error, {:too_large, :command, byte_size(command), @max_command_bytes}}

      {:error, :vault_reference} ->
        {:error, {:vault_reference, at}}

      {:error, _invalid} ->
        {:error, {:invalid_field, at}}
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

  # ————— control answers —————

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
         {:ok, programs} <- list(wire, "programs", :programs, @max_programs, &program_summary/2) do
      {:ok, %{status: status, programs: programs}}
    end
  end

  defp read_answer_typed(:renew, wire) do
    with {:ok, renewed} <- owners(wire, "renewed", [:e, :state], nil),
         {:ok, unknown} <- owners(wire, "unknown", [:e], nil) do
      {:ok, %{renewed: renewed, unknown: unknown}}
    end
  end

  defp read_answer_typed(:status, wire) do
    with {:ok, owners} <-
           owners(
             wire,
             "owners",
             [:g, :e, :state, :lease_ms_left, :programs],
             @max_status_owners
           ),
         do: {:ok, %{owners: owners}}
  end

  defp read_answer_typed(:home, wire) do
    with {:ok, home_id} <- home_id_member(wire, "home_id", ""),
         {:ok, state} <- roster(wire, "state", @home_states, "") do
      {:ok, %{home_id: home_id, state: state}}
    end
  end

  defp pool(%{} = wire) do
    with :ok <- exact(wire, ~w(size free), "pool."),
         {:ok, size} <- count(wire, "size", "pool."),
         {:ok, free} <- count(wire, "free", "pool.") do
      {:ok, %{size: size, free: free}}
    end
  end

  defp pool(_wire), do: {:error, {:invalid_field, "pool"}}

  defp program_summary(%{} = wire, at) do
    with :ok <- exact(wire, ~w(name status), at <> "."),
         {:ok, name} <- program_name(wire["name"], at <> ".name"),
         {:ok, status} <- roster(wire, "status", @program_statuses, at <> ".") do
      {:ok, %{name: name, status: status}}
    end
  end

  defp program_summary(_wire, at), do: {:error, {:invalid_field, at}}

  defp program_report(%{} = wire, at) do
    p = at <> "."

    with :ok <- exact(wire, @program_report_fields, @program_report_optional, p),
         {:ok, name} <- program_name(wire["name"], p <> "name"),
         {:ok, status} <- roster(wire, "status", @program_statuses, p),
         {:ok, restarts} <- count(wire, "restarts", p),
         {:ok, error} <- optional(wire, "error", &text_value(&1, p <> "error")),
         {:ok, stderr_tail} <- text(wire, "stderr_tail", p),
         {:ok, home} <- roster(wire, "home", @homes, p),
         {:ok, home_bytes} <- optional(wire, "home_bytes", &count_value(&1, p <> "home_bytes")),
         {:ok, over_cap} <- boolean(wire, "over_cap", p),
         {:ok, sessions} <- count(wire, "sessions", p) do
      {:ok,
       %{
         name: name,
         status: status,
         restarts: restarts,
         error: error,
         stderr_tail: stderr_tail,
         home: home,
         home_bytes: home_bytes,
         over_cap: over_cap,
         sessions: sessions
       }}
    end
  end

  defp program_report(_wire, at), do: {:error, {:invalid_field, at}}

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

  defp owner_member(:lease_ms_left, wire, at), do: count(wire, "lease_ms_left", at)
  defp owner_member(:state, wire, at), do: roster(wire, "state", @owner_states, at)

  defp owner_member(:programs, wire, at) do
    case wire["programs"] do
      list when is_list(list) and length(list) <= @max_programs ->
        list
        |> Enum.with_index()
        |> reduce_ok(nil, fn {entry, index}, nil ->
          with {:ok, report} <- program_report(entry, "#{at}programs[#{index}]"),
               do: {:ok, report, nil}
        end)

      list when is_list(list) ->
        {:error, {:too_many, :programs, length(list), @max_programs}}

      _ ->
        {:error, {:invalid_field, at <> "programs"}}
    end
  end

  # ————— session messages —————

  @doc "The body of a session message, checked as `read_session/1` will check it."
  @spec encode_session(session_message()) :: {:ok, binary()} | {:error, read_error()}
  def encode_session(%{type: type} = message) when type in @session_types do
    wire = message |> wire() |> Map.put("version", @version)

    with {:ok, _message} <- read_session_wire(wire),
         body = Jason.encode!(wire),
         :ok <- admit(byte_size(body), :session, @max_session_bytes) do
      {:ok, body}
    end
  end

  @doc "A session message's body, read strictly: its size, its version, its type, then every member."
  @spec read_session(binary()) :: {:ok, session_message()} | {:error, read_error()}
  def read_session(body) when is_binary(body) do
    with :ok <- admit(byte_size(body), :session, @max_session_bytes),
         {:ok, wire} <- object(body) do
      read_session_wire(wire)
    end
  end

  defp read_session_wire(wire) do
    with :ok <- current_version(wire),
         {:ok, type} <- typed(wire, @session_types),
         :ok <-
           exact(
             wire,
             Map.fetch!(@session_fields, type),
             Map.get(@session_optional, type, []),
             ""
           ),
         {:ok, owner} <- owner(wire["owner"], "owner", []),
         {:ok, e} <- positive(wire, "e", "") do
      read_session_typed(type, wire, %{type: type, owner: owner, e: e})
    end
  end

  defp read_session_typed(:open, wire, message) do
    with {:ok, program} <- program_name(wire["program"], "program"),
         {:ok, home_id} <- optional(wire, "home_id", &home_id_value/1),
         {:ok, key} <- key(wire["key"]),
         {:ok, mode} <- roster(wire, "mode", @modes, ""),
         {:ok, argv} <- argv(wire["argv"], mode) do
      {:ok,
       Map.merge(message, %{program: program, home_id: home_id, key: key, mode: mode, argv: argv})}
    end
  end

  defp read_session_typed(:send, wire, message) do
    with {:ok, session} <- session_id(wire["session"]),
         {:ok, lines} <- lines(wire["lines"]) do
      {:ok, Map.merge(message, %{session: session, lines: lines})}
    end
  end

  defp read_session_typed(:recv, wire, message) do
    with {:ok, session} <- session_id(wire["session"]),
         {:ok, after_seq} <- count(wire, "after", ""),
         {:ok, max_wait_ms} <- wait(wire["max_wait_ms"]) do
      {:ok, Map.merge(message, %{session: session, after: after_seq, max_wait_ms: max_wait_ms})}
    end
  end

  defp read_session_typed(:close, wire, message) do
    with {:ok, session} <- session_id(wire["session"]),
         do: {:ok, Map.put(message, :session, session)}
  end

  defp key(key) do
    if is_binary(key) and byte_size(key) <= @max_key_bytes and Regex.match?(@key_text, key),
      do: {:ok, key},
      else: {:error, {:invalid_field, "key"}}
  end

  defp session_id(id) do
    if is_binary(id) and Regex.match?(@session_id, id),
      do: {:ok, id},
      else: {:error, {:invalid_field, "session"}}
  end

  # A sign-in runs its program's login command with no arguments of the
  # opener's.
  defp argv([], :sign_in), do: {:ok, []}
  defp argv(_argv, :sign_in), do: {:error, {:invalid_field, "argv"}}

  defp argv(argv, :run) when is_list(argv) do
    if length(argv) > @max_argv do
      {:error, {:too_many, :argv, length(argv), @max_argv}}
    else
      argv
      |> Enum.with_index()
      |> reduce_ok(nil, fn {arg, index}, nil ->
        if is_binary(arg) and byte_size(arg) <= @max_command_bytes and
             not String.contains?(arg, <<0>>),
           do: {:ok, arg, nil},
           else: {:error, {:invalid_field, "argv[#{index}]"}}
      end)
    end
  end

  defp argv(_argv, _mode), do: {:error, {:invalid_field, "argv"}}

  defp lines(lines) when is_list(lines) do
    lines
    |> Enum.with_index()
    |> reduce_ok(nil, fn {line, index}, nil ->
      cond do
        not is_binary(line) or String.contains?(line, ["\n", <<0>>]) ->
          {:error, {:invalid_field, "lines[#{index}]"}}

        byte_size(line) > @max_line_bytes ->
          {:error, {:too_large, :line, byte_size(line), @max_line_bytes}}

        true ->
          {:ok, line, nil}
      end
    end)
  end

  defp lines(_lines), do: {:error, {:invalid_field, "lines"}}

  defp wait(value) when is_integer(value) and value > @max_recv_wait_ms,
    do: {:error, {:out_of_range, "max_wait_ms", value, @max_recv_wait_ms}}

  defp wait(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp wait(_value), do: {:error, {:invalid_field, "max_wait_ms"}}

  # ————— session answers —————

  @doc "The body of the answer to a session message of `type`, checked as `read_session_answer/2` will check it."
  @spec encode_session_answer(session_type(), session_answer()) ::
          {:ok, binary()} | {:error, read_error()}
  def encode_session_answer(type, answer) when type in @session_types and is_map(answer) do
    wire = answer |> wire() |> Map.put("version", @version)

    with :ok <- exact(wire, Map.fetch!(@session_answer_fields, type), ""),
         {:ok, _answer} <- read_session_answer_typed(type, wire),
         body = Jason.encode!(wire),
         :ok <- admit(byte_size(body), :session, @max_session_bytes) do
      {:ok, body}
    end
  end

  @doc "The answer to a session message of `type`, read strictly: its size, its version, then every member."
  @spec read_session_answer(session_type(), binary()) ::
          {:ok, session_answer()} | {:error, read_error()}
  def read_session_answer(type, body) when type in @session_types and is_binary(body) do
    with :ok <- admit(byte_size(body), :session, @max_session_bytes),
         {:ok, wire} <- object(body),
         :ok <- current_version(wire),
         :ok <- exact(wire, Map.fetch!(@session_answer_fields, type), "") do
      read_session_answer_typed(type, wire)
    end
  end

  defp read_session_answer_typed(:open, wire) do
    with {:ok, status} <- roster(wire, "status", [:running], ""),
         {:ok, session} <- session_id(wire["session"]),
         {:ok, resumed} <- boolean(wire, "resumed", ""),
         {:ok, pty} <- boolean(wire, "pty", "") do
      {:ok, %{status: status, session: session, resumed: resumed, pty: pty}}
    end
  end

  defp read_session_answer_typed(:send, wire) do
    with {:ok, status} <- roster(wire, "status", [:running, :ended], ""),
         do: {:ok, %{status: status}}
  end

  defp read_session_answer_typed(:close, wire) do
    with {:ok, status} <- roster(wire, "status", [:closed], ""),
         do: {:ok, %{status: status}}
  end

  defp read_session_answer_typed(:recv, wire) do
    with {:ok, lines} <- seq_lines(wire["lines"]),
         {:ok, dropped} <- count(wire, "dropped", ""),
         {:ok, running} <- boolean(wire, "running", "") do
      {:ok, %{lines: lines, dropped: dropped, running: running}}
    end
  end

  # Lines in rising sequence, each at most a line's bound.
  defp seq_lines(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> reduce_ok(0, fn {entry, index}, last ->
      at = "lines[#{index}]"

      with %{} <- entry,
           :ok <- exact(entry, ~w(seq text), at <> "."),
           {:ok, seq} <- positive(entry, "seq", at <> "."),
           true <- seq > last || {:error, {:invalid_field, at <> ".seq"}},
           {:ok, text} <- text(entry, "text", at <> "."),
           true <- byte_size(text) <= @max_line_bytes || {:error, {:invalid_field, at <> ".text"}} do
        {:ok, %{seq: seq, text: text}, seq}
      else
        {:error, _} = error -> error
        _ -> {:error, {:invalid_field, at}}
      end
    end)
  end

  defp seq_lines(_list), do: {:error, {:invalid_field, "lines"}}

  # ————— refusals —————

  @doc "The body a refusal is answered with: `{\"version\": 2, \"error\": <code>}`."
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
  both versions for a body at another version, `too_large` for a control or
  session body past its bound, `too_many_owners` and `status_too_large`
  for a status past its bounds, and `bad_request` for anything else.
  """
  @spec refusal_for(read_error()) :: refusal()
  def refusal_for({:version, presented}) when is_integer(presented) and presented > 0,
    do: {:protocol_mismatch, @version, presented}

  def refusal_for({:version, _presented}), do: {:protocol_mismatch, @version, nil}

  def refusal_for({:too_large, what, _bytes, _max}) when what in [:control, :session],
    do: :too_large

  def refusal_for({:too_large, :status_answer, _bytes, _max}), do: :status_too_large
  def refusal_for({:too_many, :owners, _count, _max}), do: :too_many_owners
  def refusal_for(_error), do: :bad_request

  @doc "Why a body did not read, as a sentence."
  @spec describe(read_error()) :: String.t()
  def describe(:not_json), do: "the body is not a JSON object"
  def describe({:version, nil}), do: "the body names no protocol version"

  def describe({:version, presented}),
    do: "the body speaks protocol #{inspect(presented)}, not #{@version}"

  def describe({:unknown_type, type}), do: "#{inspect(type)} is not a message type"
  def describe({:unknown_field, name}), do: "#{name} is not a field of this message"
  def describe({:missing_field, name}), do: "#{name} is required"
  def describe({:invalid_field, name}), do: "#{name} is not of the form this message takes"

  def describe({:too_large, :command, bytes, max}),
    do: "a command is #{bytes} bytes; at most #{max} are accepted"

  def describe({:too_large, :line, bytes, max}),
    do: "a line is #{bytes} bytes; at most #{max} are accepted"

  def describe({:too_large, what, bytes, max}),
    do: "the #{what} body is #{bytes} bytes; at most #{max} are read"

  def describe({:too_many, what, count, max}),
    do: "the message names #{count} #{what}; at most #{max} are accepted"

  def describe({:out_of_range, name, value, max}),
    do: "#{name} is #{value}; at most #{max} is accepted"

  def describe({:duplicate, name}), do: "#{name} is named twice"
  def describe({:vault_reference, name}), do: "#{name} names a vault reference"

  def describe({:reserved_env_name, name}),
    do: "#{name} is a variable name no program may define"

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

  defp exact(wire, names, at), do: exact(wire, names, [], at)

  # Exactly the named fields, and the optional ones present or absent:
  # anything else is refused before a value is read.
  defp exact(wire, names, optional, at) do
    cond do
      extra = Enum.find(Map.keys(wire) |> Enum.sort(), &(&1 not in names and &1 not in optional)) ->
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

  # An optional member: absent is `nil`; a present one, `null` included,
  # must read as its form.
  defp optional(wire, name, read) do
    if is_map_key(wire, name), do: read.(wire[name]), else: {:ok, nil}
  end

  defp home_id_value(value),
    do: if(home_id?(value), do: {:ok, value}, else: {:error, {:invalid_field, "home_id"}})

  defp count_value(value, at),
    do:
      if(MacEnvelope.valid_value?(:integer, value),
        do: {:ok, value},
        else: {:error, {:invalid_field, at}}
      )

  defp text_value(value, _at) when is_binary(value), do: {:ok, value}
  defp text_value(_value, at), do: {:error, {:invalid_field, at}}

  defp boolean(wire, name, at) do
    case wire[name] do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, at <> name}}
    end
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
  # strings, booleans as they are, and a member whose value is `nil` absent.
  defp wire(%{} = map) when not is_struct(map),
    do: for({key, value} <- map, value != nil, into: %{}, do: {to_string(key), wire(value)})

  defp wire(list) when is_list(list), do: Enum.map(list, &wire/1)

  defp wire(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp wire(value), do: value
end
