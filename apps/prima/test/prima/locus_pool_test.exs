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

  # The keeper's own refusals for room, as its vector carries them.
  @keeper_held Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
               |> File.read!()
               |> Jason.decode!()
               |> Map.fetch!("replies")
               |> Enum.filter(&(&1["code"] == "no_memory"))
               |> Enum.map(& &1["held"])

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

  describe "what holds the pool" do
    test "the keeper's refusals for room read and write back to the same members" do
      assert length(@keeper_held) == 2

      for wire <- @keeper_held do
        assert {:ok, held} = LocusPool.read_held(wire)
        assert LocusPool.encode_held(held) == wire
      end

      assert {:ok, %{mine: [%{subject: "mcp_one"}, %{kind: "run", subject: nil}]}} =
               LocusPool.read_held(hd(@keeper_held))
    end

    test "a holding with no subject is written without one, never as null" do
      held = %{
        need: 1,
        free: 0,
        mine: [%{kind: "build", subject: nil, bytes: 2}],
        others_bytes: 3
      }

      assert LocusPool.encode_held(held) == %{
               "need" => 1,
               "free" => 0,
               "mine" => [%{"kind" => "build", "bytes" => 2}],
               "others_bytes" => 3
             }

      assert LocusPool.read_held(LocusPool.encode_held(held)) == {:ok, held}
    end

    test "anything but its exact members, of their forms, is refused" do
      held = %{"need" => 1, "free" => 0, "mine" => [], "others_bytes" => 0}
      holding = %{"kind" => "program", "subject" => "row_1", "bytes" => 1}
      most = Prima.KeeperProtocol.max_measured_bytes()

      assert {:ok, _} = LocusPool.read_held(%{held | "mine" => [holding], "need" => most})

      for bad <- [
            nil,
            [],
            "held",
            Map.delete(held, "free"),
            Map.put(held, "extra", 1),
            %{held | "need" => -1},
            %{held | "need" => most + 1},
            %{held | "free" => 1.5},
            %{held | "others_bytes" => "0"},
            %{held | "mine" => nil},
            %{held | "mine" => %{}},
            %{held | "mine" => [Map.delete(holding, "bytes")]},
            %{held | "mine" => [Map.delete(holding, "kind")]},
            %{held | "mine" => [%{holding | "kind" => "browser"}]},
            %{held | "mine" => [%{holding | "bytes" => -1}]},
            %{held | "mine" => [%{holding | "subject" => nil}]},
            %{held | "mine" => [%{holding | "subject" => "a b"}]},
            %{held | "mine" => [%{holding | "subject" => 7}]},
            %{held | "mine" => [Map.put(holding, "athanor", "ath_two")]},
            %{held | "mine" => [holding, "holding"]}
          ],
          do: assert(LocusPool.read_held(bad) == :error, inspect(bad))
    end
  end

  describe "the sentence of a refusal for room" do
    @mib 1024 * 1024
    @gib 1024 * @mib

    # No word of the keeper's own reaches a person.
    defp plain!(sentence) do
      refute sentence =~ ~r/pool|ledger|place|runner|warm|held|keeper/i
      sentence
    end

    test "names the person's own work by kind, with counts and sizes, and everyone else's as one sum" do
      held = %{
        need: 800 * @mib,
        free: 100 * @mib,
        mine: [
          %{kind: "program", subject: "mcp_private", bytes: 384 * @mib},
          %{kind: "run", subject: nil, bytes: 100 * @mib},
          %{kind: "warm", subject: nil, bytes: 44 * @mib},
          %{kind: "program", subject: nil, bytes: 384 * @mib},
          %{kind: "build", subject: nil, bytes: 900 * @mib}
        ],
        others_bytes: 3 * div(@gib, 2)
      }

      sentence = plain!(LocusPool.refusal_sentence(held))

      assert sentence ==
               "This CYFR has not enough memory free. Of yours, 2 programs use 768.0 MB, " <>
                 "a build uses 900.0 MB and 2 runs use 144.0 MB. Others use 1.5 GB. " <>
                 "Stop one on the Programs page, or wait."

      refute sentence =~ "mcp_private"
    end

    test "of two people, each reads only their own work and the other's as a sum" do
      # The keeper's held for a refused build of each of two athanors, each
      # holding a program: its own by kind, the other's within others_bytes.
      ours = %{kind: "program", subject: nil, bytes: 384 * @mib}

      for held <- [
            %{need: 800 * @mib, free: 0, mine: [ours], others_bytes: 512 * @mib},
            %{
              need: 800 * @mib,
              free: 0,
              mine: [%{ours | bytes: 512 * @mib}],
              others_bytes: 384 * @mib
            }
          ] do
        [own] = held.mine

        assert plain!(LocusPool.refusal_sentence(held)) ==
                 "This CYFR has not enough memory free. Of yours, a program uses " <>
                   "#{Prima.Bytes.format(own.bytes)}. Others use " <>
                   "#{Prima.Bytes.format(held.others_bytes)}. Stop one on the Programs page, or wait."
      end
    end

    test "with nothing of the person's own, says what is under way uses it and never others or yours" do
      # A refused run's held: a runner's place is no athanor's yet.
      held = %{need: 164 * @mib, free: 20 * @mib, mine: [], others_bytes: 2 * @gib}
      sentence = plain!(LocusPool.refusal_sentence(held))

      assert sentence ==
               "This CYFR has not enough memory free. Work under way uses 2.0 GB. " <>
                 "Wait, or try again later."

      refute sentence =~ ~r/others|yours/i
    end

    test "with only builds or runs of the person's own, asks them to wait" do
      held = %{
        need: 800 * @mib,
        free: 0,
        mine: [%{kind: "build", subject: nil, bytes: 1 * @gib}],
        others_bytes: 0
      }

      assert plain!(LocusPool.refusal_sentence(held)) ==
               "This CYFR has not enough memory free. Of yours, a build uses 1.0 GB. " <>
                 "Wait, or try again later."
    end

    test "with nothing held at all, says this CYFR has no room for it" do
      assert plain!(
               LocusPool.refusal_sentence(%{need: 800 * @mib, free: 0, mine: [], others_bytes: 0})
             ) == "This CYFR has no memory free for it."

      assert plain!(
               LocusPool.refusal_sentence(%{
                 need: 800 * @mib,
                 free: 444 * @mib,
                 mine: [],
                 others_bytes: 0
               })
             ) ==
               "This CYFR has not enough memory for it: it needs 800.0 MB, and 444.0 MB is free."
    end
  end
end
