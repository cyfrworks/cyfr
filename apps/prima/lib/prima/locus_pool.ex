# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusPool do
  @moduledoc """
  The pool's fixed numbers: the one memory bound all of a machine's Locus
  work shares, what it keeps for the warm floor, and what each kind of work
  is charged and bounded at. Data only: no process, no file and no
  environment.

  The keeper (`cyfr-locus serve`) holds every spawn of every role under one
  group, `work`, bounded at W: the machine's memory less the reserve for
  CYFR itself (`LOCUS_CORE_RESERVE_BYTES`), or the container's own limit
  where that is less, less the services' share (`LOCUS_SERVICE_BYTES`),
  never below 0. Inside it every role's spawns but the runtime's are held
  under `rest`, at W less F, the floor's memory (`floor_bytes/0`), so
  builds and programs alone never reach the floor's runner.

  The keeper is the one admission of that work. Each place's kind has a
  class (`kinds/0`): a runner, a build or a session. A start is admitted
  when its class's allowance (`allowance_bytes/1`) fits what W leaves, in
  arrival order; it is charged at least that allowance until
  `allowance_ms/0` after its spawn, then its reading, and a place with no
  reading for `stale_ms/0` no less than its last charge. One that finds no
  room within `room_wait_ms/0`, the close's own wait, is refused. The
  keeper sets every spawn's bounds by its class, and no client names one: a
  build's memory is `build_cap_bytes/0`, a runner's and a session's half of
  W, never under `least_cap_bytes/1`, and each class's processors are
  `processors/1`.

  A runner's least is its allowance and the components' hard ceiling
  together (`Prima.Limits.Ceiling`'s compiled `max_memory_bytes`), so one
  component at any cap an administrator may allow fits beside its runner on
  every machine, and on a machine with room a chain of several fits too.
  A limit: a chain that runs several large components at once on a small
  machine ends at the runner's cap.

  The keeper's Go reads this module's values from
  `tests/fixtures/locus_pool.json`, which `Prima.LocusPoolTest` holds to
  them.
  """

  @mib 1024 * 1024
  @floor_bytes 164 * @mib
  @kinds %{
    "warm" => :runner,
    "run" => :runner,
    "build" => :build,
    "program" => :session,
    "terminal" => :session
  }
  @allowance_bytes %{runner: @floor_bytes, build: 800 * @mib, session: 384 * @mib}
  @build_cap_bytes 1024 * @mib
  @least_cap_bytes %{
    runner: @floor_bytes + Prima.Limits.Ceiling.lowered(%{}).max_memory_bytes,
    session: 384 * @mib
  }
  @processors %{runner: 1, build: 1, session: 2}

  @typedoc "What a place's kind is charged and bounded as."
  @type class :: :runner | :build | :session

  @doc "F, the memory the warm floor keeps from builds and programs: its one runner's allowance, 164 MiB."
  @spec floor_bytes() :: pos_integer()
  def floor_bytes, do: @floor_bytes

  @doc "How many fresh runners the warm floor keeps: one."
  @spec floor_runners() :: pos_integer()
  def floor_runners, do: 1

  @doc """
  How long a start waits for room before it is refused: the close's own
  wait (`Prima.LocusBackends.close_wait_ms/0`), so every client that waits
  for a start waits past it.
  """
  @spec room_wait_ms() :: pos_integer()
  def room_wait_ms, do: Prima.LocusBackends.close_wait_ms()

  @doc "How long after its spawn a place is charged at least its allowance."
  @spec allowance_ms() :: pos_integer()
  def allowance_ms, do: 10_000

  @doc "How long a place may go unread before it is charged no less than its last charge."
  @spec stale_ms() :: pos_integer()
  def stale_ms, do: 3_000

  @doc "Each place's kind and its class."
  @spec kinds() :: %{String.t() => class()}
  def kinds, do: @kinds

  @doc "What a start of the class needs and is charged at least for its first `allowance_ms/0`."
  @spec allowance_bytes(class()) :: pos_integer()
  def allowance_bytes(class), do: Map.fetch!(@allowance_bytes, class)

  @doc "A build's memory bound, 1 GiB."
  @spec build_cap_bytes() :: pos_integer()
  def build_cap_bytes, do: @build_cap_bytes

  @doc """
  The least memory bound of a runner and of a session, whose bound is half
  of W, never under it: a runner's its allowance and the components' hard
  ceiling together, a session's its allowance.
  """
  @spec least_cap_bytes(:runner | :session) :: pos_integer()
  def least_cap_bytes(class), do: Map.fetch!(@least_cap_bytes, class)

  @doc "The memory bound of a spawn of the class on a pool of work `work` bytes."
  @spec cap_bytes(class(), non_neg_integer()) :: pos_integer()
  def cap_bytes(:build, _work), do: @build_cap_bytes
  def cap_bytes(class, work), do: max(div(work, 2), least_cap_bytes(class))

  @doc "The processors of each spawn of the class."
  @spec processors(class()) :: pos_integer()
  def processors(class), do: Map.fetch!(@processors, class)
end
