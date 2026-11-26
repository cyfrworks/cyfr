# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusPool do
  @moduledoc """
  The pool's fixed numbers: the one memory bound all of a machine's Locus
  work shares, and what it keeps for the warm floor. Data only: no process,
  no file and no environment.

  The keeper (`cyfr-locus serve`) holds every spawn of every role under one
  group, `work`, bounded at W: the machine's memory less the reserve for
  core (`LOCUS_CORE_RESERVE_BYTES`), or the container's own limit where
  that is less, less the services' share (`LOCUS_SERVICE_BYTES`), never
  below 0. Inside it every role's spawns but the runtime's are held under
  `rest`, at W less F, the floor's memory (`floor_bytes/0`), so builds and
  programs alone never reach the floor's runner. The keeper's Go reads this
  module's values from `tests/fixtures/locus_pool.json`, which
  `Prima.LocusPoolTest` holds to them.
  """

  @floor_bytes 164 * 1024 * 1024

  @doc "F, the memory the warm floor keeps from builds and programs: its one runner's allowance, 164 MiB."
  @spec floor_bytes() :: pos_integer()
  def floor_bytes, do: @floor_bytes
end
