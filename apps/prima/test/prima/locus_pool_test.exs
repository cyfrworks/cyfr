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
             ~w(allowance_bytes allowance_ms cap_bytes comment counters floor_bytes floor_runners kinds least_cap_bytes processors room_wait_ms stale_ms wire)

    assert @vectors["counters"] == %{
             "max_counters" => LocusPool.max_counters(),
             "report_counters" => LocusPool.report_counters(),
             "keep_ms" => LocusPool.keep_ms(),
             "reading_gap_ms" => LocusPool.reading_gap_ms()
           }

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

  test "the counters' numbers are the plan's" do
    assert {LocusPool.max_counters(), LocusPool.report_counters()} == {16_384, 256}
    assert LocusPool.keep_ms() == 48 * 60 * 60 * 1000
    assert LocusPool.reading_gap_ms() == 2_000
  end

  describe "the pool wire" do
    @wire @vectors["wire"]
    @key @wire["key_hex"] |> Base.decode16!(case: :lower)

    test "its vectors are the module's: the route, the body, each service's pool key and header" do
      assert Map.keys(@wire) |> Enum.sort() ==
               ~w(answer auth_header body key_hex max_request_bytes route services ts version window_ms)

      assert {@wire["version"], @wire["route"], @wire["auth_header"]} ==
               {LocusPool.version(), LocusPool.route(), Prima.MacEnvelope.auth_header()}

      assert {@wire["window_ms"], @wire["max_request_bytes"]} ==
               {LocusPool.window_ms(), LocusPool.max_request_bytes()}

      assert LocusPool.window_ms() == Prima.BuilderProtocol.window_ms()
      assert @wire["body"] == LocusPool.request_body(512)
      assert LocusPool.read_request_body(@wire["body"]) == {:ok, 512}
      assert Map.keys(@wire["services"]) |> Enum.sort() == ~w(backends builds runtime)

      for service <- LocusPool.services(), vector = @wire["services"][Atom.to_string(service)] do
        pool_key = LocusPool.pool_key(service, @key)
        assert vector["label"] == "cyfr-locus/v1/#{service}/pool"
        assert vector["label"] == LocusPool.label(service)
        assert vector["pool_key_hex"] == Base.encode16(pool_key, case: :lower)

        # What the service holds of its key, and its pool key's one definition from it.
        held = if service == :builds, do: Prima.BuilderProtocol.request_key(@key), else: @key

        assert Map.get(vector, "request_key_hex", Base.encode16(@key, case: :lower)) ==
                 Base.encode16(held, case: :lower)

        assert LocusPool.held_pool_key(service, held) == pool_key
        assert pool_key == Prima.MacEnvelope.derive(held, vector["label"])
        assert vector["header"] == LocusPool.header(service, pool_key, @wire["ts"], @wire["body"])
      end

      assert {:ok, report} = LocusPool.read_answer(@wire["answer"])
      assert Jason.decode!(LocusPool.answer(report)) == Jason.decode!(@wire["answer"])
    end

    test "a pool header of one service is refused by the two others, all three given the same key" do
      body = @wire["body"]
      ts = @wire["ts"]

      for service <- LocusPool.services() do
        header = LocusPool.header(service, LocusPool.pool_key(service, @key), ts, body)

        assert {:ok, hash} =
                 LocusPool.verify_header(service, LocusPool.pool_key(service, @key), header, ts)

        assert LocusPool.verify_body(hash, body) == :ok

        for other <- LocusPool.services() -- [service] do
          assert LocusPool.verify_header(other, LocusPool.pool_key(other, @key), header, ts) ==
                   {:error, :bad_mac}
        end

        # The service's own key is not its pool key: what it signs is no pool request.
        assert LocusPool.verify_header(service, @key, header, ts) == {:error, :bad_mac}

        own = Prima.MacEnvelope.derive(@key, Prima.MacEnvelope.label(service))
        assert LocusPool.verify_header(service, own, header, ts) == {:error, :bad_mac}
      end
    end

    test "a header is refused outside its window, at another version, malformed, or over another body" do
      key = LocusPool.pool_key(:builds, @key)
      ts = @wire["ts"]
      header = LocusPool.header(:builds, key, ts, @wire["body"])
      window = LocusPool.window_ms()

      for now <- [ts - window, ts + window],
          do: assert({:ok, _hash} = LocusPool.verify_header(:builds, key, header, now))

      for now <- [ts - window - 1, ts + window + 1],
          do:
            assert(
              LocusPool.verify_header(:builds, key, header, now) == {:error, :outside_window}
            )

      assert LocusPool.verify_header(:builds, key, String.replace(header, "v1 ", "v2 "), ts) ==
               {:error, :unknown_version}

      for bad <- ["", "Bearer x", nil, String.replace(header, "kind=pool", "kind=request")],
          do: assert(LocusPool.verify_header(:builds, key, bad, ts) == {:error, :malformed})

      {:ok, hash} = LocusPool.verify_header(:builds, key, header, ts)
      assert LocusPool.verify_body(hash, LocusPool.request_body(0)) == {:error, :bad_mac}
    end

    test "a body is exactly v and after, a whole number to 2^53 - 1, its version read first" do
      max = 9_007_199_254_740_991
      assert LocusPool.read_request_body(LocusPool.request_body(max)) == {:ok, max}
      assert LocusPool.read_request_body(~s({"after":0,"v":1})) == {:ok, 0}

      for body <- [~s({"v":2,"after":0}), ~s({"after":0}), ~s({"v":"1","after":0})],
          do: assert(LocusPool.read_request_body(body) == {:error, :version})

      for body <- [
            ~s({"v":1}),
            ~s({"v":1,"after":-1}),
            ~s({"v":1,"after":"0"}),
            ~s({"v":1,"after":1.5}),
            ~s({"v":1,"after":#{max + 1}}),
            ~s({"v":1,"after":0,"role":"builds"}),
            "[]",
            "not json"
          ],
          do: assert(LocusPool.read_request_body(body) == {:error, :malformed})
    end
  end

  describe "a report" do
    @counter %{
      "rev" => 3,
      "day" => "2026-11-27",
      "athanor" => "ath_one",
      "kind" => "program",
      "subject" => "mcp_one",
      "bytes" => 0,
      "mib_ms" => 0,
      "measured_ms" => 0,
      "peak_bytes" => 0,
      "cap" => 0,
      "machine" => 0,
      "either" => 1
    }
    @report %{
      "boot" => String.duplicate("a", 32),
      "budget" => 0,
      "work" => 0,
      "floor" => 0,
      "used" => 0,
      "counters" => [@counter]
    }

    test "reads exactly its members and writes them back, its optional ones absent" do
      assert {:ok, read} = LocusPool.read_report(@report)
      assert read.next == nil

      assert [%{day: ~D[2026-11-27], athanor: "ath_one", subject: "mcp_one", either: 1}] =
               read.counters

      assert LocusPool.encode_report(read) == @report

      bare = Map.drop(@counter, ["athanor", "subject"])

      assert {:ok, %{counters: [%{athanor: nil, subject: nil}], next: 9}} =
               LocusPool.read_report(%{@report | "counters" => [bare]} |> Map.put("next", 9))

      assert {:ok, read} =
               LocusPool.read_report(%{@report | "counters" => [bare]} |> Map.put("next", 9))

      assert LocusPool.encode_report(read) ==
               %{@report | "counters" => [bare]} |> Map.put("next", 9)
    end

    test "refuses what is not one" do
      page = for rev <- 1..257, do: %{@counter | "rev" => rev}

      for bad <- [
            Map.delete(@report, "used"),
            Map.put(@report, "role", "builds"),
            Map.put(@report, "next", 0),
            Map.put(@report, "next", nil),
            %{@report | "boot" => "boot_1"},
            %{@report | "budget" => -1},
            %{@report | "counters" => page},
            %{@report | "counters" => [@counter, @counter]},
            %{@report | "counters" => [%{@counter | "rev" => 4}, @counter]},
            %{@report | "counters" => [%{@counter | "rev" => 0}]},
            %{@report | "counters" => [%{@counter | "day" => "2026-02-30"}]},
            %{@report | "counters" => [%{@counter | "day" => "27-11-2026"}]},
            %{@report | "counters" => [%{@counter | "kind" => "browser"}]},
            %{@report | "counters" => [%{@counter | "athanor" => nil}]},
            %{@report | "counters" => [%{@counter | "subject" => "../x"}]},
            %{@report | "counters" => [Map.delete(@counter, "either")]},
            %{@report | "counters" => [Map.put(@counter, "role", "backends")]},
            %{@report | "counters" => [%{@counter | "mib_ms" => 9_007_199_254_740_992}]},
            "report"
          ],
          do: assert(LocusPool.read_report(bad) == :error, inspect(bad))

      assert {:ok, %{counters: counters}} =
               LocusPool.read_report(%{@report | "counters" => Enum.take(page, 256)})

      assert length(counters) == LocusPool.report_counters()
    end
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

    test "names each holding whose subject CYFR read a name for, and counts the rest by kind" do
      held = %{
        need: 384 * @mib,
        free: 0,
        mine: [
          %{kind: "program", subject: "mcp_codex", bytes: 300 * @mib},
          %{kind: "program", subject: "mcp_claude", bytes: 600 * @mib},
          %{kind: "terminal", subject: "mcp_claude", bytes: 100 * @mib},
          # A row the person can no longer read: counted, never named.
          %{kind: "program", subject: "mcp_deleted", bytes: 200 * @mib},
          %{kind: "build", subject: nil, bytes: 900 * @mib}
        ],
        others_bytes: @gib
      }

      names = %{"mcp_claude" => "claude-code", "mcp_codex" => "codex"}
      sentence = plain!(LocusPool.refusal_sentence(held, names))

      assert sentence ==
               "This CYFR has not enough memory free. Of yours, claude-code uses 700.0 MB, " <>
                 "codex uses 300.0 MB, a program uses 200.0 MB and a build uses 900.0 MB. " <>
                 "Others use 1.0 GB. Stop one on the Programs page, or wait."

      refute sentence =~ "mcp_"
      # A name is only ever one of the names handed: none comes from held.
      assert LocusPool.refusal_sentence(held) == LocusPool.refusal_sentence(held, %{})
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
               "This CYFR has not enough memory for it: it needs 800.0 MB, and has 444.0 MB for all its work."
    end

    test "when nothing anyone stops makes room, says only that this CYFR has not enough memory for it" do
      # A 4 GB machine at the default reserves: work's memory less the
      # floor's is 623 MiB, less than a build needs, whoever's program holds
      # 384 MiB of it.
      program = %{kind: "program", subject: nil, bytes: 384 * @mib}

      sentence =
        "This CYFR has not enough memory for it: it needs 800.0 MB, and has 623.0 MB for all its work."

      for held <- [
            %{need: 800 * @mib, free: 239 * @mib, mine: [program], others_bytes: 0},
            %{need: 800 * @mib, free: 239 * @mib, mine: [], others_bytes: 384 * @mib}
          ] do
        assert plain!(LocusPool.refusal_sentence(held)) == sentence, inspect(held)
      end
    end

    test "when stopping work would make room, the advice stands" do
      held = %{
        need: 800 * @mib,
        free: 239 * @mib,
        mine: [%{kind: "program", subject: nil, bytes: 600 * @mib}],
        others_bytes: 0
      }

      assert plain!(LocusPool.refusal_sentence(held)) ==
               "This CYFR has not enough memory free. Of yours, a program uses 600.0 MB. " <>
                 "Stop one on the Programs page, or wait."
    end
  end

  test "a withheld refusal says only that there is not enough memory free" do
    assert LocusPool.refusal_sentence(:withheld) ==
             "This CYFR has not enough memory free. Stop one on the Programs page, or wait."
  end
end
