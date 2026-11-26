# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusPoolTest do
  @moduledoc """
  The pool's numbers and their vector file (`tests/fixtures/locus_pool.json`)
  are one definition: the file holds the module's values under exactly its
  keys, which the keeper's own test reads.
  """
  use ExUnit.Case, async: true

  alias Prima.LocusPool

  @vectors Path.expand("../../../../tests/fixtures/locus_pool.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @classes [:runner, :build, :session]

  test "the vector file holds the module's numbers and nothing else" do
    assert Map.keys(@vectors) |> Enum.sort() ==
             ~w(allowance_bytes allowance_ms cap_bytes comment floor_bytes floor_runners kinds least_cap_bytes processors room_wait_ms stale_ms)

    assert @vectors["floor_bytes"] == LocusPool.floor_bytes()
    assert @vectors["floor_runners"] == LocusPool.floor_runners()
    assert @vectors["room_wait_ms"] == LocusPool.room_wait_ms()
    assert @vectors["allowance_ms"] == LocusPool.allowance_ms()
    assert @vectors["stale_ms"] == LocusPool.stale_ms()

    assert @vectors["kinds"] ==
             Map.new(LocusPool.kinds(), fn {k, c} -> {k, Atom.to_string(c)} end)

    assert @vectors["allowance_bytes"] ==
             Map.new(@classes, &{Atom.to_string(&1), LocusPool.allowance_bytes(&1)})

    assert @vectors["processors"] ==
             Map.new(@classes, &{Atom.to_string(&1), LocusPool.processors(&1)})

    assert @vectors["cap_bytes"] == %{"build" => LocusPool.build_cap_bytes()}

    assert @vectors["least_cap_bytes"] ==
             Map.new([:runner, :session], &{Atom.to_string(&1), LocusPool.least_cap_bytes(&1)})
  end

  test "the pool's numbers are the plan's" do
    mib = 1024 * 1024
    assert LocusPool.floor_bytes() == 164 * mib
    assert LocusPool.allowance_bytes(:runner) == LocusPool.floor_bytes()

    assert {LocusPool.allowance_bytes(:build), LocusPool.allowance_bytes(:session)} ==
             {800 * mib, 384 * mib}

    assert LocusPool.build_cap_bytes() == 1024 * mib
    # A runner's least holds a component at the hard ceiling beside its own allowance.
    assert LocusPool.least_cap_bytes(:runner) ==
             LocusPool.allowance_bytes(:runner) +
               Prima.Limits.Ceiling.lowered(%{}).max_memory_bytes

    assert LocusPool.least_cap_bytes(:runner) == 420 * mib
    assert LocusPool.least_cap_bytes(:session) == LocusPool.allowance_bytes(:session)

    assert {LocusPool.cap_bytes(:runner, 608 * mib), LocusPool.cap_bytes(:runner, 4832 * mib)} ==
             {420 * mib, 2416 * mib}

    assert {LocusPool.cap_bytes(:session, 608 * mib), LocusPool.cap_bytes(:build, 4832 * mib)} ==
             {384 * mib, 1024 * mib}

    assert LocusPool.room_wait_ms() == Prima.LocusBackends.close_wait_ms()
    assert Enum.sort(Map.keys(LocusPool.kinds())) == Enum.sort(Prima.KeeperProtocol.kinds())
  end
end
