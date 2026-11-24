# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Launcher do
  @moduledoc """
  A long-lived process started for an owner and held until the owner
  releases it: the shape a program of the backends service runs in,
  beside the one-round `Locus.Executor` a build runs in.

  `c:spawn/2` starts `argv` with `env` as its whole environment beyond the
  launcher's own `HOME`, `TMPDIR`, `USER`, `LOGNAME` and `PATH`, in the uid
  pool `pool`, under `memory_bytes` and `cpu_quota` (microseconds of CPU
  time in every 100000), and answers
  the process's `t:handle/0`. A spec naming a kept `home` runs the process
  in that home, under the home's own uid, and takes no uid of the pool;
  `pty: %{rows: r, cols: c}` gives the process a pseudo-terminal of that
  size as its stdin, stdout and stderr, so its stdout carries what it
  writes to the terminal and no stderr is heard, and `c:resize/3` sets the
  terminal's size later.

  ## Kept homes

  A kept home is one folder per id under the launcher's kept-homes root,
  owned by a uid of its own drawn from the launcher's kept-home range: no
  other home and no pool is ever given that uid while the home lives.
  `c:home_ensure/2` makes the home when it is absent, drawing its uid, and
  answers the uid; `c:home_measure/2` answers the bytes it holds;
  `c:home_reset/2` ends every process of its uid and empties it, keeping
  its uid; `c:home_retire/2` ends every process of its uid, removes it and
  frees its uid; `c:home_list/1` answers the id of every home it holds.
  Each of the four acts as a helper under the home's uid, since nothing
  else can read a home. A launcher with no kept-homes root refuses each,
  and a spawn naming a home, `{:refused, "unavailable"}`. The process that called it is the process's
  owner: every event of the process reaches it as
  `{launcher_module, handle.ref, event}` (`t:event/0`), in order, until
  `:released`, the last, or until `{:error, :channel_lost}`, after which
  the launcher says nothing more of it and nothing here knows it gone. An
  owner that dies has its process released with no grace. The owner
  answers each event carrying the process's bytes (its stdout, stderr,
  control or relay bytes) with `c:taken/1` once it has taken them: a
  launcher that holds the process's output tells it no more bytes until
  the owner has taken every one it was told, so the process's writes wait
  behind its owner rather than in memory.

  A spec may name an `heir`, `{pid, tag}`: a process told
  `{launcher_module, {:heir, tag}, :released}` once nothing of the process
  is left, whoever owns it then, and once it is known that none was
  started, as for a spawn refused before the launcher made anything of it.
  A spawn refused after it made something, `{:refused, code, handle}`, is
  followed on that handle as a started process is: its owner hears
  `:released`, and its heir is told, once nothing of it is left, and its
  refusal is not a release. So a process the owner's death leaves
  to the launcher's own release is still followed to its end by another
  process: the owner's `:released` dies with the owner, the heir's does
  not. `c:fence/2` asks after a tag whose owner died: `:pending` while the
  launcher holds a process of it (its heir is told of its end), or `:none`,
  with every later spawn naming that tag refused, so none can start after
  the answer. `c:adopt/3` makes the caller the heir of every process the
  launcher holds whose tag names `ledger` (`%{ledger: ledger}`), and
  answers their tags: an heir that restarts takes back what it followed.

  `c:send/2` writes to the process's stdin; `c:signal/2` signals it;
  `c:resize/3` sets its terminal's size;
  `c:release/3` ends it, a term signal first and the kill of everything it
  started once `grace_ms` pass, and answers at once, the `:released` event
  following once nothing of it is left.

  Every process runs in a place (`Prima.KeeperProtocol`, "Places") made
  before its work is prepared: `c:place/4` makes one under an id its
  caller minted, of a kind, and an athanor and a subject where it has
  them, for an owner, whose death before a spawn names the place drops
  it, as does the end, for any reason but `:normal`, of a caller that
  asked for it for another owner; `c:drop/2` frees one no spawn
  named, after a preparation that failed or a waiter that left;
  `c:assign/4` gives one another kind, athanor and subject, answering once
  the keeper has applied it, or `{:launcher_unavailable, :timeout}` once
  the instant its caller waits until passes, after which its answer, however
  late, is no one's and whose the place is cannot be known. A spec names
  its place, which its spawn takes: the place is free once nothing of
  the process is left. `c:measure/2` answers a place's last reading, whose
  the place is and how old the reading is, or an error where none is
  known: no reading is ever a zero, and no caller waits for a read.
  `c:pool_stats/2` answers the pool's size, its free uids and its
  quarantined ones.

  A spec with `control: true` asks for a process whose control channel is
  carried beside its stdio, as a runner of the runtime has one, whose
  space, its pool's, has its relay as its only way out. Such a process is
  answered as soon as it is
  asked for, its spawn id, uid and pid following as the first event, and
  its owner hears `t:control_event/0` in place of `t:event/0`.
  `c:send_control/2` writes to its control channel, holding what it is
  sent until the process attaches; `c:send_relay/2` writes to its relay
  from any process, and `c:close_relay/1` ends the relay.

  `Locus.Executor.executor/0` names the implementation a node uses:
  `Locus.Keeper` where cyfr-locus runs, and the test environment's
  direct launcher, which makes no space, alone otherwise.
  """

  @typedoc "Whose a place is: its kind, and its athanor and subject where it has them."
  @type whose :: %{
          required(:kind) => Prima.KeeperProtocol.kind(),
          optional(:athanor) => String.t(),
          optional(:subject) => String.t()
        }

  @typedoc """
  What a process is started with: its place, the memory and the CPU it is bounded
  by, which every process has, `control` where it has a control channel, a
  program's kept `home` with its bound and
  `pty`, and `hosts`, the only hosts it may reach where its row names them.
  """
  @type spec :: %{
          required(:argv) => [String.t(), ...],
          required(:env) => %{optional(String.t()) => String.t()},
          required(:place) => String.t(),
          required(:pool) => String.t(),
          required(:memory_bytes) => pos_integer(),
          required(:cpu_quota) => pos_integer(),
          optional(:control) => boolean(),
          optional(:home) => String.t(),
          optional(:home_max_bytes) => pos_integer(),
          optional(:pty) => %{rows: pos_integer(), cols: pos_integer()},
          optional(:hosts) => [String.t(), ...],
          optional(:heir) => {pid(), term()}
        }

  @typedoc """
  The owner's hold on one process: the ref its events carry, the spawn id
  and uid the launcher gave it (nil where it gives none), and the OS pid of
  its leader. The rest is the implementation's.
  """
  @type handle :: %{
          required(:ref) => reference(),
          required(:spawn_id) => String.t() | nil,
          required(:uid) => non_neg_integer() | nil,
          required(:pid) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  What an owner hears of its process: its stdio attached, bytes of its
  stdout and stderr as they arrive, its leader's end (a status or the name
  of the signal that ended it, and what memory limit killed it:
  `t:Prima.KeeperProtocol.memory_end/0`), and its release, the last event,
  or the launcher's channel lost, which releases nothing;
  its stdout, its stderr and its leader's end arrive in no defined order.
  """
  @type event ::
          :attached
          | {:stdout, binary()}
          | {:stderr, binary()}
          | {:exited, integer() | nil, String.t() | nil, Prima.KeeperProtocol.memory_end()}
          | {:error, :channel_lost}
          | :released

  @typedoc """
  What the owner of a process with a control channel hears of it: its
  spawn id, uid and pid (nil where the launcher gives none), or the
  launcher's refusal, no process of it having run, with the spawn id its
  `:released` follows under where the launcher made something of it
  first; its relay attached;
  bytes of its control channel, of its relay and of its stdout and
  stderr as they arrive; the control channel's and the relay's end, each
  once; its leader's end and what memory limit killed it; a
  relay that broke the frame codec or a channel lost; and its release,
  the last. The bytes of its control channel, its relay, its stdout and
  its stderr and its leader's end arrive in no defined order.
  """
  @type control_event ::
          {:spawned, String.t() | nil, non_neg_integer() | nil, non_neg_integer() | nil}
          | {:refused, String.t()}
          | {:refused, String.t(), String.t()}
          | :attached
          | {:control, binary()}
          | :control_closed
          | {:relay, binary()}
          | :relay_closed
          | {:stdout, binary()}
          | {:stderr, binary()}
          | {:exited, {:status, integer()} | {:signal, String.t()},
             Prima.KeeperProtocol.memory_end()}
          | {:error, :relay_protocol | :channel_lost}
          | :released

  @typedoc "A pool's uids: all of them, the free ones and the quarantined ones."
  @type pool_stats :: %{
          size: non_neg_integer(),
          free: non_neg_integer(),
          quarantined: non_neg_integer()
        }

  @typedoc """
  Why a spawn or a request did not happen: the launcher's refusal code,
  with the handle its `:released` follows on where the launcher refused a
  spawn after making something of it, a request it would refuse as
  malformed, the launcher unreachable, a process it no longer follows.
  """
  @type error ::
          {:refused, String.t()}
          | {:refused, String.t(), handle()}
          | {:spawn_failed, term()}
          | {:launcher_unavailable, term()}
          | :unknown_spawn
          | :unencodable

  @doc "Start `spec` for the calling process, its owner."
  @callback spawn(GenServer.server() | keyword(), spec()) :: {:ok, handle()} | {:error, error()}

  @doc """
  Write `data` to the process's stdin, from any process: answered once
  the bytes are written, so a process that does not read its stdin holds
  its caller and no other.
  """
  @callback send(handle(), iodata()) :: :ok | {:error, error()}

  @doc "The owner's word that it took the last bytes of the process it was told of."
  @callback taken(handle()) :: :ok

  @doc "Send the process the signal `sig` (`SIGTERM`, `SIGKILL`, …)."
  @callback signal(handle(), String.t()) :: :ok | {:error, error()}

  @doc "Set the size of the process's pseudo-terminal, which signals it `SIGWINCH`."
  @callback resize(handle(), pos_integer(), pos_integer()) :: :ok | {:error, error()}

  @doc "End the process: a term signal, `grace_ms`, then the kill; `:released` follows."
  @callback release(GenServer.server() | keyword(), handle(), non_neg_integer()) :: :ok

  @doc "A new place `id` of `whose` for the process `owner`."
  @callback place(GenServer.server() | keyword(), String.t(), whose(), pid()) ::
              :ok | {:error, error() | :dropped | :unencodable}

  @doc "Free the place no spawn named."
  @callback drop(GenServer.server() | keyword(), String.t()) :: :ok

  @doc """
  Give the place another kind, athanor and subject: `:ok` once the keeper
  has applied it, an error once `until` (monotonic milliseconds) passes.
  """
  @callback assign(GenServer.server() | keyword(), String.t(), whose(), until :: integer()) ::
              :ok | {:error, error()}

  @doc "The place's last reading and whose it is; an error where none is known, never a zero."
  @callback measure(GenServer.server() | keyword(), String.t()) ::
              {:ok, Prima.KeeperProtocol.reading()} | {:error, error()}

  @doc "The uids of `pool`."
  @callback pool_stats(GenServer.server() | keyword(), String.t()) ::
              {:ok, pool_stats()} | {:error, error()}

  @doc "Make the kept home `id` if it is absent, drawing its uid; answer its uid."
  @callback home_ensure(GenServer.server() | keyword(), String.t()) ::
              {:ok, non_neg_integer()} | {:error, error()}

  @doc "The bytes the kept home `id` holds; `:absent` for a home not made."
  @callback home_measure(GenServer.server() | keyword(), String.t()) ::
              {:ok, non_neg_integer()} | :absent | {:error, error()}

  @doc "The id of every kept home the launcher holds."
  @callback home_list(GenServer.server() | keyword()) :: {:ok, [String.t()]} | {:error, error()}

  @doc "End every process of the kept home `id`'s uid and empty the home, keeping its uid."
  @callback home_reset(GenServer.server() | keyword(), String.t()) :: :ok | {:error, error()}

  @doc "End every process of the kept home `id`'s uid, remove the home and free its uid."
  @callback home_retire(GenServer.server() | keyword(), String.t()) :: :ok | {:error, error()}

  @doc "Write `data` to the control channel of a process started with `control: true`."
  @callback send_control(handle(), iodata()) :: :ok | {:error, term()}

  @doc "Write `data` to the relay of a process started with `control: true`."
  @callback send_relay(handle(), iodata()) :: :ok | {:error, term()}

  @doc "End the relay of a process started with `control: true`: nothing more is written to it."
  @callback close_relay(handle()) :: :ok

  @doc "Whether a process of `tag` is held (`:pending`), or none is and none will start (`:none`)."
  @callback fence(GenServer.server() | keyword(), term()) :: :none | :pending | {:error, error()}

  @doc "Become the heir of every process held whose tag's `ledger` is `ledger`; answers their tags."
  @callback adopt(GenServer.server() | keyword(), term(), pid()) ::
              {:ok, [term()]} | {:error, error()}

  @optional_callbacks send_control: 2,
                      send_relay: 2,
                      close_relay: 1,
                      home_ensure: 2,
                      home_measure: 2,
                      home_reset: 2,
                      home_retire: 2,
                      home_list: 1
end
