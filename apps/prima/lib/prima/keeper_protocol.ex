# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.KeeperProtocol do
  @moduledoc """
  The wire between `cyfr-locus` (`apps/locus/keeper`) and its one client,
  `Locus.Keeper`, which every role of a Locus node spawns through: the
  request and reply lines on the inherited channel (fd 3) and the frames
  on a spawn's attach connection. `tests/fixtures/keeper_protocol.json`
  holds the vectors the keeper and its client reproduce. Pure: the attach
  token's entropy is the client's.

  ## Lines

  A request or a reply is one JSON object on one line, ending in `\\n`,
  carrying `"v": 9` and a `type`, at most `max_line_bytes/0` bytes before
  its newline. A client sends `place`, `drop`, `assign`, `spawn`,
  `signal`, `resize`, `release`, `measure`, `pool`, `home_make`,
  `home_measure`, `home_reset`, `home_retire`, `home_list`, `packs_hold`,
  `packs_put` and `report`; the keeper answers `placed`, `assigned`,
  `spawned`, `error`, `exited`, `released`, `measured`, `pool`,
  `home_made`, `home_measured`, `home_retired`, `homes`, `packs` and
  `reported`, and sends `give_way` of its own.

  `encode/1` writes a request's members in name order, `v` and `type`
  among them, and refuses by raising `ArgumentError` what the keeper
  refuses as `bad_request`: a member the type does not carry, a required
  one absent, and a value outside its bound, as the keeper's
  `ParseRequest` reads them (a kept home's members follow the rules under
  Homes). A refusal names the
  member at fault by its path (`argv`, `attach.token`, `rlimits.nofile`)
  and never quotes a value, since an environment value may be a
  credential.

  A spawn names no bound of its own: the keeper runs every spawn in a
  cgroup of its own holding the memory and processors of its place's kind
  (`Prima.LocusPool`), the memory its `placed` named. The reply code
  `memory_unavailable` means that the keeper cannot enforce a spawn's
  bounds where it runs, whichever of them it lacks the means for; it
  refuses every spawn so, and none runs unbounded.

  An `exited` comes at most once and before its spawn's `released`, never
  after. Where retirement's bounded wait for the leader's reaping ran out,
  a spawn killed for memory has one with `SIGKILL` and the cause, and any
  other has none.

  An `exited`'s `memory` says what the kernel killed processes of the
  spawn for, as its group's own counters say: `"cap"` for its own bound;
  `"machine"` for a limit above it, the container's or the machine's,
  whatever its own bound counted before; `"either"` for a kill the
  counters cannot lay to one of the two, which is never called `"cap"`;
  and null for no kill or for counters that could not be read.

  ## Places

  A place follows one piece of work from before its preparation to its
  release. The client mints its `id` and names its `kind` (`kinds/0`)
  and, where it has them, the `athanor` it is for, of the grammar every
  Locus wire gives an athanor's id
  (`Prima.RunnerControl.athanor_id_pattern/0`), and its `subject` (a
  program's or a terminal's row), of the id grammar, and the keeper
  answers `placed`, or refuses a place of an id it already holds
  `bad_request`. A `drop` frees a place no spawn has named and is not
  answered: a place the keeper no longer holds leaves it nothing to do.
  An `assign` carries an `id` of its own beside the `place` it names and
  gives that place another kind, athanor and subject, as a runner given
  work or back at rest; it is answered under that `id` alone, `assigned`
  once the keeper applied it, or refused `bad_request` where the keeper
  holds no such place, or where a spawn naming `packs` claimed it and the
  assign names another athanor. Every `spawn` names its `place`, which
  no other spawn may name: a spawn naming a place the keeper does not hold,
  or one another spawn named, is refused `bad_request`, and a place a spawn
  named is free at that spawn's `released`, which is the keeper's word
  alone. A spawn refused before the keeper made anything of it is refused
  under its `id` alone and frees its place at once; one refused after the
  keeper made it (its command could not be run, say) is refused under its
  `id` and the `spawn_id` the keeper gave it, and gets one `released`
  under that `spawn_id` once its cleanup is done and its place freed.

  The keeper reads every spawn's group once a second, whatever its kind. A
  `measure` carries exactly `id` and `place` and is answered under that
  `id` alone, as a home request is, so a reply settles only the request it
  answers, and from the last reading, never by a read of its own:
  `measured` with the place's `kind`, `athanor` and `subject` of the
  moment, the reading and its `age_ms`, or an `error` `unmeasured` where
  the keeper holds no such place or has no reading of it yet. A reading's
  `bytes` are what the spawn's group uses that cannot be given back, `anon
  + shmem + kernel - slab_reclaimable` from one read of its `memory.stat`:
  file cache is none of it and a tmpfs's pages are. Its `lesser` is true
  where that kernel's `memory.stat` has no `kernel` line (before 5.18), and
  `bytes` then the lesser sum, of the parts of it that it names. A reading
  not made is unknown, and zero is no reading: a `measured` of no `bytes`
  is refused, where a `home_measured` of none is an empty home.

  `decode_reply/1` answers the reply or the first refusal, in this order:
  `:oversize_line`; `:malformed` (not one JSON object); `:bad_version`;
  `:unknown_type`; `{:unknown_field, name}` (the first by name); then per
  member, in the order the type lists them (an absent optional one read as
  nil), `{:missing_field, name}`,
  `{:wrong_type, name}` or `{:invalid_field, name}`; and last, for an
  `exited`, `:ambiguous_exit` when it carries both a `code` and a
  `signal`, or neither. The `bytes` of a `measured` is a whole number from
  1 and that of a `home_measured` from 0, each up to 2^53 - 1, the largest
  every JSON reader carries exactly.

  ## Reports

  The keeper counts who used what (`Prima.LocusPool`, "Who used what").
  A `report` carries exactly `id` and `after`, a rev, a whole number from
  0 to 2^53 - 1, and is answered under that `id` alone `reported` with
  `report`, the asking role's counters after that rev
  (`Prima.LocusPool.read_report/1`): a role is told only of the places it
  made, and none of another role's.

  ## Packs

  The keeper holds a read-only copy of each person's packs, one generation
  for each set digest (its `internal/packview`). `packs_hold` carries
  exactly `id`, `athanor`, `lifetime` (a start's, opaque to the keeper)
  and `digest` (`sha256:` and 64 lowercase hex digits), and is answered
  `packs` with `state` `:held`, the generation complete and now held for
  the lifetime, or `:missing`. `packs_put` carries those and `seq`, from 0
  by one up to `max_pack_seq`, `last` and `data`, one part of the
  generation's stream of at most `max_pack_part_bytes` (`request_bounds/0`),
  which `encode/1` writes in base64; each part is answered `:taken`, the
  last `:held`, or refused `packs_refused`; a first part while another put
  of the athanor is under way is refused `packs_busy`, and one while the
  most at once are under way `unavailable`. A spawn's optional `packs`,
  `%{athanor: athanor, digest: digest}`, names the generation its space
  binds read only at `/run/cyfr/scrolls`, of its place's athanor. A keeper or a role that keeps no
  homes refuses every packs request `unavailable`.

  ## Homes

  A spawn's `home_mode` is `"scratch"`, today's home scrubbed at
  retirement and the reading of its absence, or `"kept"`, a home that
  outlives the spawn. A kept spawn requires `home`, the kept home's id
  (`home_id?/1`), and may carry `home_max_bytes`, from 1 to 2^50; both are
  refused without `"kept"`. A spawn's `pty` is the size of
  a pseudo-terminal, `{"rows": r, "cols": c}`, each from 1 to
  `max_pty_size` (`request_bounds/0`); absent, the spawn has none. A
  `resize` request carries exactly `spawn_id`, `rows` and `cols` and sets
  the size of that spawn's terminal, which signals its foreground
  processes (`SIGWINCH`); like `signal` it is answered only by an `error`,
  `bad_request` for a spawn with no terminal.

  The keeper alone knows its kept homes: each person, an athanor, has one
  disk under its `--kept-homes` root, owned by a uid of the range that is
  the disk's for its life, holding a home of each of the person's program
  rows and a work folder every program of the person shares at `/work`;
  no request names a path or a uid. `home_make` carries exactly `id`,
  `home` and `athanor`, whose disk the home is on; `home_measure`,
  `home_reset` and `home_retire` carry exactly `id` and `home`, which the
  keeper finds on its disk by its id. `home_make` is answered `home_made`
  with the disk's `uid` once the home is made on the disk, which is made
  first under a uid the keeper draws if it is not (refused `capacity` with
  every uid of the range taken, and `bad_request` for a home another
  athanor's disk holds); `home_measure` `home_measured` with the home's
  `bytes`, zero for an empty home, or refused `home_absent` for a home no
  disk holds; `home_reset`, which ends every session of the home and makes
  it again empty, `home_made` with the disk's uid; and `home_retire`, which
  ends them and removes the home from its disk, `home_retired`, as each of
  the two answers a home no disk holds, neither touching the disk's other
  homes, its work folder or its uid. `home_list`
  carries `id` and an optional `after`, a home's id, and is answered
  `homes`: the `ids` of the homes the disks hold after it in byte order,
  one page, with `next`, its last id, when more follow, for the next
  `home_list` to name as its `after`. A keeper with no kept homes refuses
  every home request and kept spawn `unavailable`. The keeper runs a kept
  spawn under its disk's uid in its home, with the disk's work folder at
  `/work` and no other home in sight, refuses one naming a home no disk
  holds `home_absent`, one whose place is another athanor's than its
  disk's `bad_request`, and one whose home already holds `home_max_bytes`
  `home_over_cap`; a `pty` spawn's stdin, stdout and stderr are a
  pseudo-terminal, which its stdout frames carry. Each home request acts as
  a helper running as the disk's uid.

  ## Hosts

  A spawn's `hosts` names the only hosts its command may reach beyond the
  resolver and the deployment's private hosts (`valid_hosts?/1`); absent
  keeps the island's public-hosts rule. A relay pool's spawn, which
  reaches nothing, is refused one as `bad_request`, a decision of the pool
  the keeper makes. The keeper resolves the names at the spawn, and only
  then, and has the island's guard make the spawn's space its own route
  with exactly those addresses and no other public one, or of the island's
  rule for a spawn without `hosts`, before the command starts: each space
  has its own route, so one session's hosts never change another's. A name
  that resolves to no address refuses the spawn as `hosts_unresolved`, and
  a route the guard does not confirm as `guard_unavailable`.

  ## Frames

  A frame is a stream byte (`streams/0`), a 4-byte big-endian length and
  at most `max_frame_bytes/0` bytes of payload; a zero-length frame ends
  its stream. A relay's first frame is the attach frame, stream 3, whose
  payload is the spawn's token of `token_hex_bytes/0` lowercase hex
  digits. Which streams a client accepts past the attach frame is the
  client's own: a stream it never asked for is a relay fault there.

  The relay stream, 5, is the exception to that rule's premise: every
  spawn of a relay pool has one, the socket on its command's file
  descriptor 4 carrying `Prima.RunnerRelay` frames verbatim, asked for or
  not. The keeper sends nothing on it, its end frame included, until the
  client has sent on it first, so a client that never uses the stream
  never receives a frame on it. The client's first frame opens it, and a
  zero-length first frame opens it and ends nothing, since the service
  speaks second on a runner's relay; after that a zero-length frame ends
  it in either direction, as on any other stream. An opening frame the
  keeper had not read when every other stream of the spawn ended opens
  nothing: the attach connection ends.

  ## Spaces

  Every spawn runs in a space of its own, a user, network and IPC
  namespace that maps its uid and gid to themselves, so the command keeps
  its uid, its home and its cgroup, holds no capability in any set, runs
  with `no_new_privs` and shares no abstract socket or System V object
  with anything else. What a space reaches is its pool's, which the keeper
  declares on its command line (`--pool runner:30101-30108:relay`,
  `--pool backends:20001-20032:routed`), never a spawn's member: a relay
  pool's space has its loopback down and no route, so its relay on file
  descriptor 4, carried as stream 5, is its only way to anything beyond
  its control channel; a routed pool's space has its own loopback and the
  one route its island's guard makes for it, its names answered at
  127.0.0.11:53 in the space itself.
  """

  alias Prima.RunnerControl

  @version 9
  # The keeper spells these as frame.MaxPayload and protocol.MaxLineBytes;
  # the vectors' `bounds` pin both sides to the same numbers.
  @max_frame_bytes 65_536
  @max_line_bytes 1_048_576
  @token_hex_bytes 64

  @streams [stdin: 0, stdout: 1, stderr: 2, attach: 3, control: 4, relay: 5]
  @stream_byte Map.new(@streams)
  @stream_name Map.new(@streams, fn {name, byte} -> {byte, name} end)
  @attach_stream Keyword.fetch!(@streams, :attach)

  # The keeper's request bounds, signals and reserved names
  # (`apps/locus/keeper/internal/protocol`); the vectors' `request_bounds`,
  # `rlimits`, `signals` and `reserved_env` pin both sides to the same ones.
  @max_args 256
  @max_env 256
  @max_value_bytes 32 * 1024
  @max_spec_bytes 256 * 1024
  @max_grace_ms 60_000
  @max_socket_path 107
  @max_home_bytes 1024 * 1024 * 1024 * 1024 * 1024
  @max_athanor_bytes 1024 * 1024 * 1024 * 1024 * 1024
  @max_hosts 32
  @max_pty_size 1000
  @max_pack_part_bytes 524_288
  @max_pack_seq 65_536
  @home_modes ~w(scratch kept)
  @kinds ~w(warm run build program terminal)
  @signals ~w(SIGTERM SIGKILL SIGINT SIGHUP SIGQUIT SIGUSR1 SIGUSR2)
  @reserved_env ~w(PATH HOME USER LOGNAME SHELL TMPDIR PWD)
  @reserved_env_prefixes ~w(CYFR_ LOCUS_ KEEPER_)
  # Each limit's least and most, the most being the keeper's ceiling.
  @rlimits [
    core: {0, 0},
    fsize: {1, 256 * 1024 * 1024},
    nofile: {16, 1024},
    nproc: {1, 1024}
  ]

  # The integers a reply carries: uids, pids and pool counts.
  @max_count 4_294_967_295
  # A measured spawn's or home's bytes: the largest integer JSON carries exactly.
  @max_measured_bytes 9_007_199_254_740_991
  @memory_ends %{"cap" => :cap, "machine" => :machine, "either" => :either}

  @id ~r/\A[A-Za-z0-9._:-]{1,64}\z/
  @pool ~r/\A[a-z][a-z0-9-]{0,31}\z/
  @spawn_id ~r/\A[0-9a-f]{32}\z/
  @token ~r/\A[0-9a-f]{64}\z/
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # A kept home's id: its program row's, a plain file name (the keeper's
  # home.ValidID).
  @home_id ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @signal ~r/\A[\x20-\x7E]{1,64}\z/
  # A start's lifetime as the keeper keeps it, opaque, and a set digest.
  @lifetime ~r/\A[A-Za-z0-9._:-]{1,128}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @packs_states %{"held" => :held, "missing" => :missing, "taken" => :taken}

  # Every request type, its wire name and its members: required or not.
  @requests %{
    place:
      {"place",
       [
         id: :required,
         kind: :required,
         athanor: :optional,
         subject: :optional,
         athanor_max_bytes: :optional
       ]},
    drop: {"drop", [place: :required]},
    assign:
      {"assign",
       [id: :required, place: :required, kind: :required, athanor: :optional, subject: :optional]},
    spawn:
      {"spawn",
       [
         id: :required,
         place: :required,
         pool: :required,
         argv: :required,
         env: :optional,
         rlimits: :optional,
         control: :optional,
         attach: :required,
         home_mode: :optional,
         home: :optional,
         home_max_bytes: :optional,
         pty: :optional,
         hosts: :optional,
         packs: :optional
       ]},
    signal: {"signal", [spawn_id: :required, sig: :required]},
    resize: {"resize", [spawn_id: :required, rows: :required, cols: :required]},
    release: {"release", [spawn_id: :required, grace_ms: :required]},
    pool: {"pool", [id: :required, pool: :required]},
    measure: {"measure", [id: :required, place: :required]},
    home_make: {"home_make", [id: :required, home: :required, athanor: :required]},
    home_measure: {"home_measure", [id: :required, home: :required]},
    home_reset: {"home_reset", [id: :required, home: :required]},
    home_retire: {"home_retire", [id: :required, home: :required]},
    home_list: {"home_list", [id: :required, after: :optional]},
    report: {"report", [id: :required, after: :required]},
    packs_hold:
      {"packs_hold", [id: :required, athanor: :required, lifetime: :required, digest: :required]},
    packs_put:
      {"packs_put",
       [
         id: :required,
         athanor: :required,
         lifetime: :required,
         digest: :required,
         seq: :required,
         last: :required,
         data: :required
       ]}
  }
  @packs_requests [:packs_hold, :packs_put]
  @home_requests [:home_make, :home_measure, :home_reset, :home_retire]

  # Every reply type and its members in the order they are read.
  @replies %{
    "placed" => {:placed, [id: :id, memory_bytes: :used_bytes]},
    "assigned" => {:assigned, [id: :id]},
    "spawned" => {:spawned, [id: :id, spawn_id: :spawn_id, uid: :count, pid: :count]},
    "error" =>
      {:error, [id: {:nullable, :id}, spawn_id: {:nullable, :spawn_id}, code: :code, held: :held]},
    "give_way" => {:give_way, [place: :id]},
    "exited" =>
      {:exited,
       [
         spawn_id: :spawn_id,
         code: {:nullable, :integer},
         signal: {:nullable, :signal},
         memory: {:nullable, :memory_end}
       ]},
    "released" => {:released, [spawn_id: :spawn_id]},
    "measured" =>
      {:measured,
       [
         id: :id,
         kind: :kind,
         athanor: :athanor,
         subject: :id,
         bytes: :used_bytes,
         lesser: :boolean,
         age_ms: :measured_bytes
       ]},
    "pool" => {:pool, [id: :id, pool: :pool, size: :count, free: :count, quarantined: :count]},
    "home_made" => {:home_made, [id: :id, uid: :count]},
    "home_measured" => {:home_measured, [id: :id, bytes: :measured_bytes]},
    "home_retired" => {:home_retired, [id: :id]},
    "homes" => {:homes, [id: :id, ids: :home_ids, next: :home_id]},
    "packs" => {:packs, [id: :id, state: :packs_state]},
    "reported" => {:reported, [id: :id, report: :report]}
  }

  # An `error` names its request by `id` or `spawn_id`, and a request the
  # keeper could not read by neither; a place's athanor and subject are
  # carried where it has them.
  @optional_reply_members %{
    error: [:id, :spawn_id, :held],
    measured: [:athanor, :subject],
    homes: [:next]
  }

  @typedoc "A stream of an attach connection."
  @type stream :: :stdin | :stdout | :stderr | :attach | :control | :relay

  @typedoc "A signal a `signal` request may name."
  @type signal :: String.t()

  @typedoc """
  A request, as `encode/1` takes it: its `type` and its members, with atom
  keys but for `env`'s names. A `place` requires `id` and `kind` and may
  carry `athanor` and `subject`, and a session's (`program` or
  `terminal`) that names its athanor `athanor_max_bytes`, the ceiling of
  that athanor's sessions there; an `assign` the same but that ceiling,
  and `place`; a `drop` carries `place` alone. `spawn` requires `id`,
  `place`, `pool`, `argv` and `attach` (`%{path: path, token: token}`); `env`
  (names to values), `rlimits` (`nofile`, `nproc`, `core`, `fsize`),
  `control`, `home_mode` (`"scratch"` or
  `"kept"`), `home`, `home_max_bytes`, `pty` and `hosts` are optional,
  `home` carried exactly when `home_mode` is `"kept"`, and `home_max_bytes`
  only then. A home request carries `id` and `home`, and a `home_make`
  its `athanor` too; a `home_list`, `id`
  and an optional `after`; a `report`, `id` and `after`, a rev.
  """
  @type request ::
          %{
            required(:type) => :place,
            required(:id) => String.t(),
            required(:kind) => kind(),
            optional(:athanor) => String.t(),
            optional(:subject) => String.t(),
            optional(:athanor_max_bytes) => pos_integer()
          }
          | %{
              required(:type) => :assign,
              required(:id) => String.t(),
              required(:place) => String.t(),
              required(:kind) => kind(),
              optional(:athanor) => String.t(),
              optional(:subject) => String.t()
            }
          | %{type: :drop, place: String.t()}
          | %{
              required(:type) => :spawn,
              required(:id) => String.t(),
              required(:place) => String.t(),
              required(:pool) => String.t(),
              required(:argv) => [String.t(), ...],
              optional(:env) => %{optional(String.t()) => String.t()},
              optional(:rlimits) => %{optional(atom()) => non_neg_integer()},
              optional(:control) => boolean(),
              required(:attach) => %{path: String.t(), token: String.t()},
              optional(:home_mode) => String.t(),
              optional(:home) => String.t(),
              optional(:home_max_bytes) => pos_integer(),
              optional(:pty) => %{rows: pos_integer(), cols: pos_integer()},
              optional(:hosts) => [String.t(), ...],
              optional(:packs) => %{athanor: String.t(), digest: String.t()}
            }
          | %{type: :signal, spawn_id: String.t(), sig: signal()}
          | %{type: :resize, spawn_id: String.t(), rows: pos_integer(), cols: pos_integer()}
          | %{type: :release, spawn_id: String.t(), grace_ms: non_neg_integer()}
          | %{type: :pool, id: String.t(), pool: String.t()}
          | %{type: :measure, id: String.t(), place: String.t()}
          | %{type: :home_make, id: String.t(), home: String.t(), athanor: String.t()}
          | %{
              type: :home_measure | :home_reset | :home_retire,
              id: String.t(),
              home: String.t()
            }
          | %{
              required(:type) => :home_list,
              required(:id) => String.t(),
              optional(:after) => String.t()
            }
          | %{type: :report, id: String.t(), after: non_neg_integer()}
          | %{
              type: :packs_hold,
              id: String.t(),
              athanor: String.t(),
              lifetime: String.t(),
              digest: String.t()
            }
          | %{
              type: :packs_put,
              id: String.t(),
              athanor: String.t(),
              lifetime: String.t(),
              digest: String.t(),
              seq: non_neg_integer(),
              last: boolean(),
              data: binary()
            }

  @typedoc "How a spawn's leader ended: its exit status or the signal that ended it."
  @type exit_status :: {:status, integer()} | {:signal, String.t()}

  @typedoc """
  What the kernel killed processes of a spawn for: its own memory bound
  (`:cap`), a limit above it (`:machine`), one of the two where which is
  not known (`:either`), or none that is known.
  """
  @type memory_end :: :cap | :machine | :either | nil

  @typedoc "A place's kind: a runner at rest or given a run, a build, a program's or a terminal's session."
  @type kind :: String.t()

  @typedoc """
  A place's last reading: whose it is of the moment (its `kind`, and its
  `athanor` and `subject` or nil), what its spawn uses that cannot be
  given back, whether that is the lesser sum of a kernel that counts no
  `kernel` memory, and how old the reading is.
  """
  @type reading :: %{
          kind: kind(),
          athanor: String.t() | nil,
          subject: String.t() | nil,
          bytes: pos_integer(),
          lesser: boolean(),
          age_ms: non_neg_integer()
        }

  @typedoc "What holds a pool that refused a place for room (`Prima.LocusPool`)."
  @type held :: Prima.LocusPool.held()

  @typedoc """
  A reply. An `error` names the request it refuses by `id` (a place, an
  assign, a spawn, a pool, a home request, a measure or a report) or `spawn_id` (a
  signal or a release), and by both a spawn the keeper refused after it
  made it; a request the keeper could not read is named by neither. A
  place refused for room is `{:no_memory, id, held}`, never an `:error`.
  A `placed` carries the memory bound its spawn will have; a `give_way`
  asks the floor's role to release the idle runner of the place it names.
  """
  @type reply ::
          {:placed, id :: String.t(), memory_bytes :: pos_integer()}
          | {:no_memory, id :: String.t(), held()}
          | {:give_way, place :: String.t()}
          | {:assigned, id :: String.t()}
          | {:spawned, id :: String.t(), spawn_id :: String.t(), uid :: non_neg_integer(),
             pid :: non_neg_integer()}
          | {:error, id :: String.t() | nil, spawn_id :: String.t() | nil, code :: String.t()}
          | {:exited, spawn_id :: String.t(), exit_status(), memory_end()}
          | {:measured, id :: String.t(), reading()}
          | {:released, spawn_id :: String.t()}
          | {:pool, id :: String.t(), pool :: String.t(), size :: non_neg_integer(),
             free :: non_neg_integer(), quarantined :: non_neg_integer()}
          | {:home_made, id :: String.t(), uid :: non_neg_integer()}
          | {:home_measured, id :: String.t(), bytes :: non_neg_integer()}
          | {:home_retired, id :: String.t()}
          | {:homes, id :: String.t(), ids :: [String.t()], next :: String.t() | nil}
          | {:packs, id :: String.t(), :held | :missing | :taken}
          | {:reported, id :: String.t(), Prima.LocusPool.report()}

  @typedoc "Why a line is not a reply (see the module's decoding order)."
  @type reason ::
          :oversize_line
          | :malformed
          | :bad_version
          | :unknown_type
          | {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:wrong_type, String.t()}
          | {:invalid_field, String.t()}
          | :ambiguous_exit

  @doc "The protocol version every line carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The most payload bytes a frame carries."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "The most bytes a line may span, its newline excluded."
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @doc "The length of a spawn's attach token: lowercase hex digits."
  @spec token_hex_bytes() :: pos_integer()
  def token_hex_bytes, do: @token_hex_bytes

  @doc "The streams of an attach connection and their bytes, in byte order."
  @spec streams() :: [{stream(), 0..5}]
  def streams, do: @streams

  @doc "The kinds a place may be."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Whether `value` is of the id grammar a place, a request and a subject take."
  @spec id?(term()) :: boolean()
  def id?(value), do: is_binary(value) and Regex.match?(@id, value)

  @doc "The largest count of bytes a reading carries, the largest integer JSON holds exactly."
  @spec max_measured_bytes() :: pos_integer()
  def max_measured_bytes, do: @max_measured_bytes

  @doc "The signals a `signal` request may name."
  @spec signals() :: [String.t()]
  def signals, do: @signals

  @doc """
  A request's ceilings: the most argv and env entries, the most bytes of
  one value, of argv and env together and of an attach path, the longest
  grace a release may ask for, the most a kept home's `home_max_bytes` and
  a session's place's `athanor_max_bytes` may be, the most hosts a spawn
  may name and the most rows or columns a terminal may have.
  """
  @spec request_bounds() :: %{atom() => non_neg_integer()}
  def request_bounds do
    %{
      max_args: @max_args,
      max_env: @max_env,
      max_value_bytes: @max_value_bytes,
      max_spec_bytes: @max_spec_bytes,
      max_grace_ms: @max_grace_ms,
      max_socket_path_bytes: @max_socket_path,
      max_home_bytes: @max_home_bytes,
      max_athanor_bytes: @max_athanor_bytes,
      max_hosts: @max_hosts,
      max_pty_size: @max_pty_size,
      max_pack_part_bytes: @max_pack_part_bytes,
      max_pack_seq: @max_pack_seq
    }
  end

  @doc """
  Whether `hosts` is a spawn's network list as the keeper takes it: 1 to
  `max_hosts` (`request_bounds/0`) distinct exact hostnames
  (`Prima.Destination.exact_host?/1`). A program's row and the backends
  wire hold their `hosts` to this rule.
  """
  @spec valid_hosts?(term()) :: boolean()
  def valid_hosts?(hosts) do
    is_list(hosts) and hosts != [] and length(hosts) <= @max_hosts and
      Enum.all?(hosts, &Prima.Destination.exact_host?/1) and Enum.uniq(hosts) == hosts
  end

  @doc "Each resource limit a spawn may lower, with its least and its most, the keeper's ceiling."
  @spec rlimits() :: [{atom(), {non_neg_integer(), non_neg_integer()}}]
  def rlimits, do: @rlimits

  @doc """
  The limits a kept spawn takes no default for: its file size, since its
  disk is held by its `home_max_bytes` and the kept homes' volume. Every
  other spawn's default is the ceiling `rlimits/0` names, and a kept spawn
  may still lower these within it.
  """
  @spec kept_unbounded_rlimits() :: [atom()]
  def kept_unbounded_rlimits, do: [:fsize]

  @doc "Whether `id` is a kept home's id, as a kept spawn and a home request name it."
  @spec home_id?(term()) :: boolean()
  def home_id?(id), do: is_binary(id) and Regex.match?(@home_id, id)

  @doc "The variable names no spawn's `env` may carry."
  @spec reserved_env_names() :: [String.t()]
  def reserved_env_names, do: @reserved_env

  @doc "The variable name prefixes no spawn's `env` may carry."
  @spec reserved_env_prefixes() :: [String.t()]
  def reserved_env_prefixes, do: @reserved_env_prefixes

  @doc "The most rows or columns a spawn's terminal may have."
  @spec max_pty_size() :: pos_integer()
  def max_pty_size, do: @max_pty_size

  # ============================================================================
  # Frames
  # ============================================================================

  @doc """
  One frame of `payload` on `stream`, as iodata. A payload above
  `max_frame_bytes/0` or a stream that is not one raises `ArgumentError`.
  """
  @spec frame(stream(), binary()) :: iolist()
  def frame(stream, payload)
      when is_map_key(@stream_byte, stream) and is_binary(payload) and
             byte_size(payload) <= @max_frame_bytes,
      do: [<<Map.fetch!(@stream_byte, stream), byte_size(payload)::32>>, payload]

  def frame(_stream, _payload),
    do: raise(ArgumentError, "a frame is a stream and at most #{@max_frame_bytes} bytes")

  @doc """
  `data` on `stream` as frames of at most `max_frame_bytes/0` each, none
  for no data. The stream's end is `end_frame/1`'s, sent apart.
  """
  @spec frames(stream(), binary()) :: [iolist()]
  def frames(stream, <<chunk::binary-size(@max_frame_bytes), rest::binary>>),
    do: [frame(stream, chunk) | frames(stream, rest)]

  def frames(stream, <<>>) when is_map_key(@stream_byte, stream), do: []
  def frames(stream, data) when is_binary(data), do: [frame(stream, data)]

  @doc "The zero-length frame that ends `stream`."
  @spec end_frame(stream()) :: iolist()
  def end_frame(stream), do: frame(stream, "")

  @doc """
  The complete frames at the head of `buffer`, in order, and the bytes
  after them, which wait for more. A header announcing more than
  `max_frame_bytes/0` is `:oversized` and a stream byte outside
  `streams/0` is `:unknown_stream`, each as soon as its header is in: a
  relay that sends either is at fault, and nothing it sent is trusted.
  """
  @spec parse_frames(binary()) ::
          {:ok, [{stream(), binary()}], binary()} | {:error, :oversized | :unknown_stream}
  def parse_frames(buffer) when is_binary(buffer), do: parse_frames(buffer, [])

  defp parse_frames(<<_stream, length::32, _rest::binary>>, _frames)
       when length > @max_frame_bytes,
       do: {:error, :oversized}

  defp parse_frames(<<stream, _length::32, _rest::binary>>, _frames)
       when not is_map_key(@stream_name, stream),
       do: {:error, :unknown_stream}

  defp parse_frames(<<stream, length::32, payload::binary-size(length), rest::binary>>, frames),
    do: parse_frames(rest, [{Map.fetch!(@stream_name, stream), payload} | frames])

  defp parse_frames(rest, frames), do: {:ok, Enum.reverse(frames), rest}

  @doc """
  The attach frame presenting `token`. A token that is not
  `token_hex_bytes/0` lowercase hex digits raises `ArgumentError`.
  """
  @spec attach_frame(String.t()) :: iolist()
  def attach_frame(token) when is_binary(token) do
    if Regex.match?(@token, token),
      do: frame(:attach, token),
      else: raise(ArgumentError, "attach.token is not #{@token_hex_bytes} lowercase hex digits")
  end

  @doc """
  The token an attach frame presents: `bytes` is the frame whole, its
  header and its `token_hex_bytes/0` of payload. Anything else, a token
  of another length or with a byte that is not a lowercase hex digit
  among them, is `:malformed`.
  """
  @spec decode_attach(binary()) :: {:ok, String.t()} | {:error, :malformed}
  def decode_attach(
        <<@attach_stream, @token_hex_bytes::32, token::binary-size(@token_hex_bytes)>>
      ) do
    if Regex.match?(@token, token), do: {:ok, token}, else: {:error, :malformed}
  end

  def decode_attach(_bytes), do: {:error, :malformed}

  # ============================================================================
  # Lines
  # ============================================================================

  @doc """
  The complete lines of `buffer` followed by `data`, without their
  newlines, and the partial line after them. A line longer than
  `max_line_bytes/0`, complete or not, is `:line_too_long`: the channel
  is at fault.
  """
  @spec split_lines(binary(), binary()) :: {[binary()], binary()} | {:error, :line_too_long}
  def split_lines(buffer, data) when is_binary(buffer) and is_binary(data) do
    {lines, [rest]} = (buffer <> data) |> :binary.split("\n", [:global]) |> Enum.split(-1)

    if Enum.all?([rest | lines], &(byte_size(&1) <= @max_line_bytes)),
      do: {lines, rest},
      else: {:error, :line_too_long}
  end

  @doc """
  The line for `request` (`t:request/0`), as iodata ending in a newline.
  A request the keeper would refuse as `bad_request` raises
  `ArgumentError` naming the member at fault, since it is the caller's
  own data.
  """
  @spec encode(request()) :: iolist()
  def encode(%{type: type} = request) when is_map_key(@requests, type) do
    {name, members} = Map.fetch!(@requests, type)
    fields = Map.delete(request, :type)

    check_members(fields, members, name)
    written = fields |> Enum.sort_by(&to_string(elem(&1, 0))) |> Enum.map(&write(type, &1))

    if type == :spawn do
      check_spec(fields)
      check_home(fields)
    end

    if type == :place, do: check_ceiling(fields)

    line =
      [{"type", name}, {"v", @version} | written]
      |> Enum.sort_by(&elem(&1, 0))
      |> Jason.OrderedObject.new()
      |> Jason.encode_to_iodata!()

    if IO.iodata_length(line) > @max_line_bytes,
      do: raise(ArgumentError, "the request is longer than #{@max_line_bytes} bytes")

    [line, ?\n]
  end

  def encode(%{type: _type}), do: raise(ArgumentError, "type is not a request type")
  def encode(_request), do: raise(ArgumentError, "type is missing")

  @doc """
  The reply one line carries, with or without the newline that ends it,
  or the first reason it is not one (`t:reason/0`).
  """
  @spec decode_reply(term()) :: {:ok, reply()} | {:error, reason()}
  def decode_reply(line) when is_binary(line) do
    line = trim_newline(line)

    with :ok <- within_line(line),
         {:ok, object} <- json_object(line),
         :ok <- known_version(object),
         {:ok, type, members} <- known_reply(object),
         {:ok, read} <- read_members(members, Map.drop(object, ["v", "type"]), type) do
      reply(type, read)
    end
  end

  def decode_reply(_line), do: {:error, :malformed}

  # ============================================================================
  # Writing a request
  # ============================================================================

  defp check_members(fields, members, type_name) do
    case Enum.sort(Map.keys(fields) -- Keyword.keys(members)) do
      [] -> :ok
      [extra | _rest] -> raise ArgumentError, "#{extra} is not a member of a #{type_name} request"
    end

    for {member, :required} <- members,
        not Map.has_key?(fields, member),
        do: raise(ArgumentError, "#{member} is missing")

    :ok
  end

  # An athanor's ceiling is a session's place's, of the athanor it names.
  defp check_ceiling(%{athanor_max_bytes: _} = fields) do
    unless fields.kind in ~w(program terminal) and Map.has_key?(fields, :athanor),
      do: raise(ArgumentError, "athanor_max_bytes is a session's place's, of its athanor")

    :ok
  end

  defp check_ceiling(_fields), do: :ok

  defp member_names(members), do: Enum.map(members, fn {member, _} -> Atom.to_string(member) end)

  defp write(_type, {:id, id}), do: {"id", matching!(@id, "id", id)}
  defp write(_type, {:pool, pool}), do: {"pool", matching!(@pool, "pool", pool)}
  defp write(_type, {:spawn_id, id}), do: {"spawn_id", matching!(@spawn_id, "spawn_id", id)}
  defp write(_type, {:place, place}), do: {"place", matching!(@id, "place", place)}

  defp write(type, {:kind, kind}) when type in [:place, :assign] and kind in @kinds,
    do: {"kind", kind}

  defp write(type, {:athanor, athanor})
       when type in [:place, :assign, :home_make | @packs_requests],
       do: {"athanor", matching!(RunnerControl.athanor_id_pattern(), "athanor", athanor)}

  defp write(type, {:subject, subject}) when type in [:place, :assign],
    do: {"subject", matching!(@id, "subject", subject)}

  defp write(:spawn, {:argv, argv}), do: {"argv", argv!(argv)}
  defp write(:spawn, {:env, env}), do: {"env", env!(env)}
  defp write(:spawn, {:rlimits, rlimits}), do: {"rlimits", rlimits!(rlimits)}
  defp write(:spawn, {:attach, attach}), do: {"attach", attach!(attach)}

  defp write(:place, {:athanor_max_bytes, bytes}) when bytes in 1..@max_athanor_bytes//1,
    do: {"athanor_max_bytes", bytes}

  defp write(:spawn, {:control, control}) when is_boolean(control), do: {"control", control}

  defp write(:spawn, {:home_mode, mode}) when mode in @home_modes, do: {"home_mode", mode}

  defp write(:spawn, {:home_max_bytes, bytes}) when bytes in 1..@max_home_bytes//1,
    do: {"home_max_bytes", bytes}

  defp write(:spawn, {:pty, %{rows: rows, cols: cols} = pty})
       when map_size(pty) == 2 and rows in 1..@max_pty_size//1 and cols in 1..@max_pty_size//1,
       do: {"pty", Jason.OrderedObject.new([{"cols", cols}, {"rows", rows}])}

  defp write(:spawn, {:hosts, hosts}), do: {"hosts", hosts!(hosts)}

  defp write(type, {:home, id}) when type in [:spawn | @home_requests],
    do: {"home", matching!(@home_id, "home", id)}

  defp write(:home_list, {:after, id}), do: {"after", matching!(@home_id, "after", id)}

  defp write(:report, {:after, rev}) when rev in 0..@max_measured_bytes//1, do: {"after", rev}

  defp write(type, {:lifetime, lifetime}) when type in @packs_requests,
    do: {"lifetime", matching!(@lifetime, "lifetime", lifetime)}

  defp write(type, {:digest, digest}) when type in @packs_requests,
    do: {"digest", matching!(@digest, "digest", digest)}

  defp write(:packs_put, {:seq, seq}) when seq in 0..@max_pack_seq//1, do: {"seq", seq}
  defp write(:packs_put, {:last, last}) when is_boolean(last), do: {"last", last}

  defp write(:packs_put, {:data, data})
       when is_binary(data) and byte_size(data) <= @max_pack_part_bytes,
       do: {"data", Base.encode64(data)}

  defp write(:spawn, {:packs, %{athanor: athanor, digest: digest} = packs})
       when map_size(packs) == 2 do
    {"packs",
     Jason.OrderedObject.new([
       {"athanor", matching!(RunnerControl.athanor_id_pattern(), "packs.athanor", athanor)},
       {"digest", matching!(@digest, "packs.digest", digest)}
     ])}
  end

  defp write(:signal, {:sig, sig}) when sig in @signals, do: {"sig", sig}
  defp write(:resize, {:rows, rows}) when rows in 1..@max_pty_size//1, do: {"rows", rows}
  defp write(:resize, {:cols, cols}) when cols in 1..@max_pty_size//1, do: {"cols", cols}

  defp write(:release, {:grace_ms, grace})
       when is_integer(grace) and grace >= 0 and grace <= @max_grace_ms,
       do: {"grace_ms", grace}

  defp write(_type, {member, _value}), do: invalid!(member)

  defp argv!(argv) when is_list(argv) and argv != [] and length(argv) <= @max_args do
    valid? = fn arg -> text?(arg) and not String.contains?(arg, <<0>>) end
    if Enum.all?(argv, valid?) and hd(argv) != "", do: argv, else: invalid!("argv")
  end

  defp argv!(_argv), do: invalid!("argv")

  defp hosts!(hosts), do: if(valid_hosts?(hosts), do: hosts, else: invalid!("hosts"))

  # An environment's names and values are checked without quoting either.
  defp env!(env) when is_map(env) and not is_struct(env) and map_size(env) <= @max_env do
    if Enum.all?(env, fn {name, value} -> env_name?(name) and env_value?(value) end),
      do: env |> Enum.sort() |> Jason.OrderedObject.new(),
      else: invalid!("env")
  end

  defp env!(_env), do: invalid!("env")

  defp env_name?(name) do
    is_binary(name) and Regex.match?(@env_name, name) and name not in @reserved_env and
      not String.starts_with?(name, @reserved_env_prefixes)
  end

  defp env_value?(value) do
    text?(value) and byte_size(value) <= @max_value_bytes and not String.contains?(value, <<0>>)
  end

  defp rlimits!(rlimits) when is_map(rlimits) and not is_struct(rlimits) do
    case Enum.sort(Map.keys(rlimits) -- Keyword.keys(@rlimits)) do
      [] -> :ok
      [extra | _rest] -> invalid!("rlimits.#{extra}")
    end

    @rlimits
    |> Enum.filter(fn {limit, _bounds} -> Map.has_key?(rlimits, limit) end)
    |> Enum.map(fn {limit, {least, most}} ->
      case Map.fetch!(rlimits, limit) do
        value when is_integer(value) and value >= least and value <= most -> {limit, value}
        _value -> invalid!("rlimits.#{limit}")
      end
    end)
    |> Jason.OrderedObject.new()
  end

  defp rlimits!(_rlimits), do: invalid!("rlimits")

  defp attach!(%{path: path, token: token} = attach) when map_size(attach) == 2 do
    unless clean_socket_path?(path), do: invalid!("attach.path")
    Jason.OrderedObject.new(path: path, token: matching!(@token, "attach.token", token))
  end

  defp attach!(_attach), do: invalid!("attach")

  defp clean_socket_path?(path), do: clean_path?(path, @max_socket_path)

  # An absolute path as the keeper's `filepath.Clean` leaves it: no empty,
  # `.` or `..` segment and no trailing slash, of at most `max` bytes.
  defp clean_path?(path, max) do
    text?(path) and byte_size(path) <= max and not String.contains?(path, <<0>>) and
      String.starts_with?(path, "/") and
      (path == "/" or
         path |> String.split("/") |> tl() |> Enum.all?(&(&1 not in ["", ".", ".."])))
  end

  # A kept spawn names its home; any other carries none, nor a home bound.
  defp check_home(%{home_mode: "kept"} = fields) do
    unless Map.has_key?(fields, :home),
      do: raise(ArgumentError, "home is missing from a kept spawn")

    :ok
  end

  defp check_home(fields) do
    for member <- [:home, :home_max_bytes],
        Map.has_key?(fields, member),
        do: raise(ArgumentError, "#{member} is carried only by a kept spawn")

    :ok
  end

  # The keeper's bound on a spawn's argv and env together, as it counts it.
  defp check_spec(fields) do
    argv = Enum.reduce(Map.fetch!(fields, :argv), 0, &(&2 + byte_size(&1) + 1))

    env =
      fields
      |> Map.get(:env, %{})
      |> Enum.reduce(0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value) + 2
      end)

    if argv + env > @max_spec_bytes, do: invalid!("argv")
    :ok
  end

  defp matching!(regex, member, value) do
    if text?(value) and Regex.match?(regex, value), do: value, else: invalid!(member)
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  @spec invalid!(atom() | String.t()) :: no_return()
  defp invalid!(member), do: raise(ArgumentError, "#{member} is not of its type or bound")

  # ============================================================================
  # Reading a reply
  # ============================================================================

  defp trim_newline(line)
       when byte_size(line) > 0 and binary_part(line, byte_size(line) - 1, 1) == "\n",
       do: binary_part(line, 0, byte_size(line) - 1)

  defp trim_newline(line), do: line

  defp within_line(line) when byte_size(line) <= @max_line_bytes, do: :ok
  defp within_line(_line), do: {:error, :oversize_line}

  defp json_object(line) do
    case Jason.decode(line) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> {:error, :malformed}
    end
  end

  defp known_version(%{"v" => @version}), do: :ok
  defp known_version(_object), do: {:error, :bad_version}

  defp known_reply(%{"type" => name}) when is_map_key(@replies, name) do
    {type, members} = Map.fetch!(@replies, name)
    {:ok, type, members}
  end

  defp known_reply(_object), do: {:error, :unknown_type}

  defp read_members(members, object, type) do
    optional = Map.get(@optional_reply_members, type, [])

    case Enum.sort(Map.keys(object) -- member_names(members)) do
      [] ->
        Enum.reduce_while(members, {:ok, %{}}, fn {member, kind}, {:ok, read} ->
          case read_member(object, member, kind, member in optional) do
            {:ok, value} -> {:cont, {:ok, Map.put(read, member, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      [unknown | _rest] ->
        {:error, {:unknown_field, unknown}}
    end
  end

  defp read_member(object, member, kind, optional?) do
    name = Atom.to_string(member)

    case Map.fetch(object, name) do
      {:ok, value} -> read(kind, name, value)
      :error when optional? -> {:ok, nil}
      :error -> {:error, {:missing_field, name}}
    end
  end

  defp read({:nullable, _kind}, _name, nil), do: {:ok, nil}
  defp read({:nullable, kind}, name, value), do: read(kind, name, value)
  defp read(:id, name, value) when is_binary(value), do: reading(@id, name, value)

  defp read(:athanor, name, value) when is_binary(value),
    do: reading(RunnerControl.athanor_id_pattern(), name, value)

  defp read(:pool, name, value) when is_binary(value), do: reading(@pool, name, value)
  defp read(:spawn_id, name, value) when is_binary(value), do: reading(@spawn_id, name, value)
  defp read(:code, name, value) when is_binary(value), do: reading(@code, name, value)
  defp read(:signal, name, value) when is_binary(value), do: reading(@signal, name, value)
  defp read(:integer, _name, value) when is_integer(value), do: {:ok, value}

  defp read(:count, _name, value) when is_integer(value) and value >= 0 and value <= @max_count,
    do: {:ok, value}

  defp read(:count, name, value) when is_integer(value), do: {:error, {:invalid_field, name}}

  defp read(:measured_bytes, _name, value)
       when is_integer(value) and value >= 0 and value <= @max_measured_bytes,
       do: {:ok, value}

  defp read(:measured_bytes, name, value) when is_integer(value),
    do: {:error, {:invalid_field, name}}

  # A spawn that is held uses memory, so none is no reading.
  defp read(:used_bytes, name, 0), do: {:error, {:invalid_field, name}}
  defp read(:used_bytes, name, value), do: read(:measured_bytes, name, value)

  defp read(:home_id, name, value) when is_binary(value), do: reading(@home_id, name, value)

  defp read(:home_ids, name, ids) when is_list(ids) do
    if Enum.all?(ids, &home_id?/1), do: {:ok, ids}, else: {:error, {:invalid_field, name}}
  end

  defp read(:boolean, _name, value) when is_boolean(value), do: {:ok, value}

  defp read(:report, name, %{} = report) do
    case Prima.LocusPool.read_report(report) do
      {:ok, report} -> {:ok, report}
      :error -> {:error, {:invalid_field, name}}
    end
  end

  defp read(:held, name, %{} = held) do
    case Prima.LocusPool.read_held(held) do
      {:ok, held} -> {:ok, held}
      :error -> {:error, {:invalid_field, name}}
    end
  end

  defp read(:packs_state, _name, value) when is_map_key(@packs_states, value),
    do: {:ok, Map.fetch!(@packs_states, value)}

  defp read(:packs_state, name, value) when is_binary(value),
    do: {:error, {:invalid_field, name}}

  defp read(:kind, _name, value) when value in @kinds, do: {:ok, value}
  defp read(:kind, name, value) when is_binary(value), do: {:error, {:invalid_field, name}}

  defp read(:memory_end, _name, value) when is_map_key(@memory_ends, value),
    do: {:ok, Map.fetch!(@memory_ends, value)}

  defp read(:memory_end, name, value) when is_binary(value), do: {:error, {:invalid_field, name}}
  defp read(_kind, name, _value), do: {:error, {:wrong_type, name}}

  defp reading(regex, name, value) do
    if Regex.match?(regex, value), do: {:ok, value}, else: {:error, {:invalid_field, name}}
  end

  defp reply(:spawned, %{id: id, spawn_id: spawn_id, uid: uid, pid: pid}),
    do: {:ok, {:spawned, id, spawn_id, uid, pid}}

  # A refusal for room, and only it, says what holds the pool.
  defp reply(:error, %{id: id, spawn_id: nil, code: "no_memory", held: held})
       when is_binary(id) and held != nil,
       do: {:ok, {:no_memory, id, held}}

  defp reply(:error, %{code: "no_memory"}), do: {:error, {:missing_field, "held"}}

  defp reply(:error, %{id: id, spawn_id: spawn_id, code: code, held: nil}),
    do: {:ok, {:error, id, spawn_id, code}}

  defp reply(:error, _read), do: {:error, {:unknown_field, "held"}}

  defp reply(:give_way, %{place: place}), do: {:ok, {:give_way, place}}

  defp reply(:exited, %{spawn_id: spawn_id, code: code, signal: nil, memory: memory})
       when code != nil,
       do: {:ok, {:exited, spawn_id, {:status, code}, memory}}

  defp reply(:exited, %{spawn_id: spawn_id, code: nil, signal: signal, memory: memory})
       when signal != nil,
       do: {:ok, {:exited, spawn_id, {:signal, signal}, memory}}

  defp reply(:exited, _read), do: {:error, :ambiguous_exit}

  defp reply(:released, %{spawn_id: spawn_id}), do: {:ok, {:released, spawn_id}}

  defp reply(:placed, %{id: id, memory_bytes: bytes}), do: {:ok, {:placed, id, bytes}}
  defp reply(:assigned, %{id: id}), do: {:ok, {:assigned, id}}

  defp reply(:measured, %{id: id} = read),
    do: {:ok, {:measured, id, Map.delete(read, :id)}}

  defp reply(:pool, %{id: id, pool: pool, size: size, free: free, quarantined: quarantined}),
    do: {:ok, {:pool, id, pool, size, free, quarantined}}

  defp reply(:home_made, %{id: id, uid: uid}), do: {:ok, {:home_made, id, uid}}
  defp reply(:home_measured, %{id: id, bytes: bytes}), do: {:ok, {:home_measured, id, bytes}}
  defp reply(:home_retired, %{id: id}), do: {:ok, {:home_retired, id}}

  defp reply(:homes, %{id: id, ids: ids, next: next}), do: {:ok, {:homes, id, ids, next}}
  defp reply(:packs, %{id: id, state: state}), do: {:ok, {:packs, id, state}}
  defp reply(:reported, %{id: id, report: report}), do: {:ok, {:reported, id, report}}
end
