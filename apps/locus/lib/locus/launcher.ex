# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Launcher do
  @moduledoc """
  A long-lived process started for an owner and held until the owner
  releases it: the shape a stdio MCP backend runs in, beside the one-round
  `Locus.Executor` a build runs in.

  `c:spawn/2` starts `argv` with `env` as its whole environment beyond the
  launcher's own `HOME`, `TMPDIR`, `USER`, `LOGNAME` and `PATH`, in the uid
  pool `pool`, under `memory_bytes` where the spec names it, and answers
  the process's `t:handle/0`. The process that called it is the process's
  owner: every event of the process reaches it as
  `{launcher_module, handle.ref, event}` (`t:event/0`), in order, until
  `:released`, the last. An owner that dies has its process released with
  no grace.

  `c:send/2` writes to the process's stdin; `c:signal/2` signals it;
  `c:release/3` ends it, a term signal first and the kill of everything it
  started once `grace_ms` pass, and answers at once, the `:released` event
  following once nothing of it is left. `c:pool_stats/2` answers the
  pool's size, its free uids and its quarantined ones.

  `Locus.Executor.launcher/0` names the implementation a node uses:
  `Locus.Keeper` where cyfr-keeper runs, and the test environment's
  unisolated launcher alone otherwise.
  """

  @typedoc "What a process is started with: `memory_bytes` where its pool bounds it."
  @type spec :: %{
          required(:argv) => [String.t(), ...],
          required(:env) => %{optional(String.t()) => String.t()},
          required(:pool) => String.t(),
          optional(:memory_bytes) => pos_integer()
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
  of the signal that ended it), and its release, the last event.
  """
  @type event ::
          :attached
          | {:stdout, binary()}
          | {:stderr, binary()}
          | {:exited, integer() | nil, String.t() | nil}
          | :released

  @typedoc "A pool's uids: all of them, the free ones and the quarantined ones."
  @type pool_stats :: %{
          size: non_neg_integer(),
          free: non_neg_integer(),
          quarantined: non_neg_integer()
        }

  @typedoc """
  Why a spawn or a request did not happen: the launcher's refusal code,
  a request it would refuse as malformed, the launcher unreachable, a
  process it no longer follows.
  """
  @type error ::
          {:refused, String.t()}
          | {:spawn_failed, term()}
          | {:launcher_unavailable, term()}
          | :unknown_spawn
          | :unencodable

  @doc "Start `spec` for the calling process, its owner."
  @callback spawn(GenServer.server() | keyword(), spec()) :: {:ok, handle()} | {:error, error()}

  @doc "Write `data` to the process's stdin."
  @callback send(handle(), iodata()) :: :ok | {:error, error()}

  @doc "Send the process the signal `sig` (`SIGTERM`, `SIGKILL`, …)."
  @callback signal(handle(), String.t()) :: :ok | {:error, error()}

  @doc "End the process: a term signal, `grace_ms`, then the kill; `:released` follows."
  @callback release(GenServer.server() | keyword(), handle(), non_neg_integer()) :: :ok

  @doc "The uids of `pool`."
  @callback pool_stats(GenServer.server() | keyword(), String.t()) ::
              {:ok, pool_stats()} | {:error, error()}
end
