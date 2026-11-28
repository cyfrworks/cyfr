# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RunnerControlTest do
  @moduledoc """
  The runner control codec reproduces the shared vectors
  (`tests/fixtures/runner_control.json`, which the runtime's runner and service
  suite reads too): every valid frame encodes to exactly its line and decodes back to
  its message, with or without its newline, and every invalid line is
  refused with its reason. An `assign` carries what `start` was given,
  its keys opened: the token reads, the input hashes to the token's
  digest and the keys are the ones the worker auth vectors seal. The
  bounds are the fixture's: a line of exactly the maximum is within the
  bound, an input of exactly the maximum and an `exit` of exactly the
  most open attempts round-trip, and the line bound leaves room for the
  largest input in base64. The encoder refuses, by raising, what the
  decoder would refuse.

  The `events` section is the runner's `event` frame: its roster is
  `RunnerControl.event_roster/0`, name by name and member by member in
  wire order; every valid event encodes to exactly its line and decodes
  back; every invalid line is refused with its refusal; every unwritten
  event is one the encoder refuses, no line carrying it; and every cut
  event encodes with each long metadata string cut to its bound on a
  character boundary, which the line decodes back to.
  """

  use ExUnit.Case, async: true

  alias Prima.{Assignment, HostAPI, RunnerControl, WorkerAuth}

  @vectors Path.expand("../../../../tests/fixtures/runner_control.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  # The roster again with every object's members in the file's order,
  # since the roster's order is the wire's.
  @ordered_events Path.expand("../../../../tests/fixtures/runner_control.json", __DIR__)
                  |> File.read!()
                  |> Jason.decode!(objects: :ordered_objects)
                  |> then(& &1["events"])

  @worker_auth Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
               |> File.read!()
               |> Jason.decode!()

  @token "eyJ2IjoxfQ.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @exec "exec_01a09fee-07cc-791f-a598-e7f90608c9e2"
  @runner "run_01a09fee-1c2d-7e3f-8a4b-5c6d7e8f9a0b"

  # The attempt keys are the worker auth vectors' own, so those vectors stay
  # their one copy.
  @keys %{
    attempt: %{
      athanor_id: "ath_01a09fee-045b-770b-b745-a62792bb8798",
      execution_id: @exec,
      attempt: "att_01a09fee-0a31-7a2b-8f0c-3d1e5b7c9a42",
      fence: 2,
      generation: 7,
      service: "wrk_4f3c2a1e9d8b7c6a"
    },
    call: Base.decode16!(@worker_auth["keys"]["attempt_call_hex"], case: :lower),
    seal: Base.decode16!(@worker_auth["keys"]["attempt_seal_hex"], case: :lower)
  }

  defp line(%{"line" => line}), do: line

  defp line(%{"repeated_line" => %{"prefix" => p, "repeat" => r, "times" => n, "suffix" => s}}),
    do: p <> String.duplicate(r, n) <> s

  # A vector's decoded message: atom keys throughout, and the keys' `call`
  # and `seal`, which the fixture spells in hex, as their bytes.
  defp message(%{"type" => type} = fields) do
    fields
    |> atom_keys()
    |> Map.put(:type, String.to_existing_atom(type))
    |> Map.update(:keys, nil, fn keys ->
      keys
      |> Map.update!(:call, &Base.decode16!(&1, case: :lower))
      |> Map.update!(:seal, &Base.decode16!(&1, case: :lower))
    end)
    |> Map.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp atom_keys(%{} = map),
    do: Map.new(map, fn {name, value} -> {String.to_existing_atom(name), atom_keys(value)} end)

  defp atom_keys(value), do: value

  # An event vector's message: atom keys for its type and members, its
  # values as the line carries them. The codec is loaded first, so the
  # roster's member names exist as atoms.
  defp event_message(%{"type" => "event"} = fields) do
    Code.ensure_loaded!(RunnerControl)
    atom_keys(fields) |> Map.put(:type, :event)
  end

  # A roster member's type as the fixture spells it.
  defp member_type(%{"type" => "integer"}), do: :integer
  defp member_type(%{"type" => "string"}), do: :string
  defp member_type(%{"type" => "string_or_null"}), do: :string_or_null

  defp member_type(%{"one_of" => words, "or" => "http_status"}),
    do: {:one_of, words, :http_status}

  defp member_type(%{"one_of" => words} = type) when map_size(type) == 1, do: {:one_of, words}

  defp roster_members(%Jason.OrderedObject{values: members}) do
    Enum.map(members, fn {name, %Jason.OrderedObject{values: type}} ->
      {String.to_existing_atom(name), member_type(Map.new(type))}
    end)
  end

  defp reason(%{"reason" => reason, "field" => field}),
    do: {String.to_existing_atom(reason), field}

  defp reason(%{"reason" => reason}), do: String.to_existing_atom(reason)

  defp encoded(message), do: message |> RunnerControl.encode() |> IO.iodata_to_binary()

  # The bytes before and after an assign's input text, from the encoder
  # itself, so a line of any input size can be built around them.
  defp assign_halves do
    line =
      %{type: :assign, assignment: @token, input: "", keys: @keys}
      |> encoded()
      |> String.trim_trailing("\n")

    [prefix, suffix] = String.split(line, ~s("input":""), parts: 2)
    {prefix <> ~s("input":"), ~s(") <> suffix}
  end

  describe "the shared vectors" do
    test "the bounds and version are the fixture's" do
      assert RunnerControl.version() == @vectors["version"]
      assert RunnerControl.max_line_bytes() == @vectors["max_line_bytes"]
      assert RunnerControl.max_input_bytes() == @vectors["max_input_bytes"]
      assert RunnerControl.max_input_depth() == @vectors["max_input_depth"]
      assert RunnerControl.max_open() == @vectors["max_open"]
    end

    test "every valid frame encodes to exactly its line and decodes to its message" do
      for vector <- @vectors["valid"] do
        line = line(vector)
        message = message(vector["message"])

        assert byte_size(line) <= RunnerControl.max_line_bytes()
        assert encoded(message) == line <> "\n", vector["why"]
        assert RunnerControl.decode(line) == {:ok, message}, vector["why"]
        assert RunnerControl.decode(line <> "\n") == {:ok, message}, vector["why"]
        assert RunnerControl.sender(message.type) == String.to_existing_atom(vector["sender"])
      end
    end

    test "every decode-only line decodes to its message, which encodes otherwise" do
      cases = @vectors["decode_only"]
      assert cases != []

      for vector <- cases do
        line = line(vector)
        message = message(vector["message"])

        assert RunnerControl.decode(line) == {:ok, message}, vector["why"]
        refute encoded(message) == line <> "\n", vector["why"]
      end
    end

    test "every invalid line is refused with its reason" do
      for vector <- @vectors["invalid"] do
        line = line(vector)
        if bytes = vector["line_bytes"], do: assert(byte_size(line) == bytes, vector["why"])
        assert RunnerControl.decode(line) == {:error, reason(vector)}, vector["why"]
        assert RunnerControl.decode(line <> "\n") == {:error, reason(vector)}, vector["why"]
      end
    end

    test "every message type has a valid vector and every reason an invalid one" do
      valid_types =
        Enum.map(
          @vectors["valid"] ++ @vectors["events"]["valid"],
          &String.to_existing_atom(&1["message"]["type"])
        )

      assert Enum.sort(Enum.uniq(valid_types)) == Enum.sort(RunnerControl.types())
      assert RunnerControl.types() == [:assign, :cancel_child, :child, :complete, :exit, :event]

      reasons = @vectors["invalid"] |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.sort()

      assert reasons ==
               Enum.sort(~w(
                 oversize_line malformed bad_version unknown_type unknown_field
                 missing_field wrong_type invalid_field oversize
               ))

      fields = for %{"field" => field} <- @vectors["invalid"], uniq: true, do: field
      assert "input" in fields and "open" in fields and "clean" in fields
      assert "keys" in fields and "keys.call" in fields and "keys.attempt.fence" in fields
    end

    test "an assign carries what start was given, its keys opened: the token reads, the input hashes to its digest and the keys are the sealed vector's" do
      vector = Enum.find(@vectors["valid"], &(&1["message"]["type"] == "assign"))
      {:ok, %{type: :assign} = assign} = RunnerControl.decode(line(vector))

      assert {:ok, %Assignment{input_digest: digest}} = Assignment.read(assign.assignment)
      assert Prima.Digest.sha256(assign.input) == digest
      assert String.contains?(line(vector), Base.encode64(assign.input))

      root = Base.decode16!(@worker_auth["root_hex"], case: :lower)
      {:ok, worker_key} = WorkerAuth.worker_key(root, @worker_auth["service"])
      seal_key = WorkerAuth.dispatch_seal_key(worker_key)
      sealed = @worker_auth["sealed_attempt_keys"]["sealed"]

      assert {:ok, opened} = WorkerAuth.open_attempt_keys(seal_key, sealed)
      assert assign.keys == opened
      assert assign.keys == @keys
      assert byte_size(assign.keys.call) == 32 and byte_size(assign.keys.seal) == 32
    end

    test "the service sends assign and cancel_child, the runner complete, exit and event" do
      assert RunnerControl.sender(:assign) == :service
      assert RunnerControl.sender(:cancel_child) == :service
      assert RunnerControl.sender(:complete) == :runner
      assert RunnerControl.sender(:exit) == :runner
      assert RunnerControl.sender(:event) == :runner
      assert_raise FunctionClauseError, fn -> RunnerControl.sender(:start) end
    end
  end

  describe "the events section" do
    test "the bounds are the fixture's, and the line bound is the channel's smaller one" do
      events = @vectors["events"]
      assert RunnerControl.max_event_line_bytes() == events["max_line_bytes"]
      assert RunnerControl.max_event_string_bytes() == events["max_string_bytes"]
      assert RunnerControl.max_event_line_bytes() < RunnerControl.max_line_bytes()
    end

    test "a runner's budget of events is the fixture's: a burst of at least one batch, and a " <>
           "rate a second no larger" do
      budget = @vectors["events"]["budget"]
      assert RunnerControl.event_burst() == budget["burst"]
      assert RunnerControl.events_per_second() == budget["per_second"]
      assert RunnerControl.event_burst() >= HostAPI.max_report_events()
      assert RunnerControl.events_per_second() <= RunnerControl.event_burst()
    end

    test "the roster is the codec's, event by event and member by member in wire order" do
      roster =
        Enum.map(@ordered_events["roster"], fn entry ->
          %{
            name: entry["name"],
            measurements: roster_members(entry["measurements"]),
            metadata: roster_members(entry["metadata"])
          }
        end)

      assert roster == RunnerControl.event_roster()
      assert length(roster) == 9
    end

    test "every valid event encodes to exactly its line and decodes to its message" do
      cases = @vectors["events"]["valid"]
      names = Enum.map(cases, & &1["message"]["name"]) |> Enum.uniq() |> Enum.sort()
      assert names == RunnerControl.event_roster() |> Enum.map(& &1.name) |> Enum.sort()

      for vector <- cases do
        line = vector["line"]
        message = event_message(vector["message"])

        assert String.ends_with?(line, "\n"), vector["why"]
        assert byte_size(line) - 1 <= RunnerControl.max_event_line_bytes(), vector["why"]
        assert encoded(message) == line, vector["why"]
        assert RunnerControl.decode(line) == {:ok, message}, vector["why"]
        assert RunnerControl.decode(String.trim_trailing(line, "\n")) == {:ok, message}
      end
    end

    test "system_time is microseconds since the epoch, which the integer domain holds" do
      times =
        for %{"message" => %{"measurements" => %{"system_time" => time}}} <-
              @vectors["events"]["valid"],
            do: time

      assert times != []
      max = 9_007_199_254_740_991

      # The vectors' values are a current clock's in microseconds: after
      # 2026-01-01, and within the domain, which nanoseconds now pass.
      assert Enum.all?(times, &(&1 > 1_767_225_600_000_000 and &1 <= max))
      assert System.os_time(:microsecond) <= max
      assert System.os_time(:nanosecond) > max
    end

    test "every invalid event line is refused with its refusal" do
      cases = @vectors["events"]["invalid"]

      for vector <- cases do
        line = vector["line"]
        refusal = reason(vector["refusal"])
        assert RunnerControl.decode(line) == {:error, refusal}, vector["why"]
        assert RunnerControl.decode(line <> "\n") == {:error, refusal}, vector["why"]
      end

      refusals = Enum.map(cases, &reason(&1["refusal"]))

      for expected <- [
            {:invalid_field, "name"},
            {:unknown_field, "measurements.bytes"},
            {:unknown_field, "metadata.authority"},
            {:missing_field, "measurements.system_time"},
            {:missing_field, "metadata.status"},
            {:wrong_type, "measurements.duration_ms"},
            {:wrong_type, "metadata.component_ref"},
            {:invalid_field, "measurements.duration_ms"},
            {:invalid_field, "measurements.system_time"},
            {:invalid_field, "metadata.status"},
            {:oversize, "metadata.action"},
            :oversize_line
          ] do
        assert expected in refusals, inspect(expected)
      end

      over = Enum.find(cases, &(&1["refusal"]["reason"] == "oversize_line"))
      assert byte_size(over["line"]) == RunnerControl.max_event_line_bytes() + 1
    end

    test "every cut event encodes with its long strings cut on a character boundary" do
      cases = @vectors["events"]["cut"]
      assert cases != []
      bound = RunnerControl.max_event_string_bytes()

      for vector <- cases do
        message = event_message(vector["message"])
        assert encoded(message) == vector["line"], vector["why"]
        assert {:ok, read} = RunnerControl.decode(vector["line"]), vector["why"]
        assert read.measurements == message.measurements

        for {member, value} <- message.metadata do
          held = Map.fetch!(read.metadata, member)

          if is_binary(value) and byte_size(value) > bound do
            # The longest prefix within the bound that ends on a boundary.
            rest = binary_part(value, byte_size(held), byte_size(value) - byte_size(held))
            assert String.starts_with?(value, held), vector["why"]
            assert byte_size(held) <= bound and byte_size(held) > bound - 4, vector["why"]
            assert String.valid?(held) and String.valid?(rest), vector["why"]
          else
            assert held == value, vector["why"]
          end
        end
      end

      lengths =
        for vector <- cases,
            {_member, value} <- vector["message"]["metadata"],
            is_binary(value) and byte_size(value) > bound,
            do: byte_size(value)

      assert 257 in lengths

      inside =
        for vector <- cases,
            {_member, value} <- vector["message"]["metadata"],
            is_binary(value) and byte_size(value) > bound,
            not String.valid?(binary_part(value, 0, bound)),
            do: value

      assert inside != [], "a string whose cut falls inside a character"
    end

    test "every unwritten event is refused by the encoder: no line carries it" do
      cases = @vectors["events"]["unwritten"]
      assert cases != []

      for vector <- cases do
        message = event_message(vector["message"])
        assert_raise ArgumentError, fn -> RunnerControl.encode(message) end
      end
    end
  end

  describe "decode" do
    test "refuses what is not a line" do
      assert RunnerControl.decode(nil) == {:error, :malformed}
      assert RunnerControl.decode(%{"v" => 1, "type" => "complete"}) == {:error, :malformed}
      assert RunnerControl.decode("\n") == {:error, :malformed}
    end

    test "checks the version before the type, and unknown members before missing ones" do
      assert {:error, :bad_version} = RunnerControl.decode(~s({"v":2,"type":"nope"}))
      assert {:error, :unknown_type} = RunnerControl.decode(~s({"v":1,"type":"nope","x":1}))

      assert {:error, {:unknown_field, "a"}} =
               RunnerControl.decode(~s({"v":1,"type":"exit","b":1,"a":1}))
    end

    test "an exit with a non-list open and a complete with a non-boolean clean are refused" do
      for open <- [~s("att_1"), "1", "null", "{}", "true"] do
        assert {:error, {:wrong_type, "open"}} =
                 RunnerControl.decode(
                   ~s({"v":1,"type":"exit","runner":"#{@runner}","open":#{open}})
                 )
      end

      for clean <- [~s("true"), "1", "0", "null", "[]"] do
        assert {:error, {:wrong_type, "clean"}} =
                 RunnerControl.decode(
                   ~s({"v":1,"type":"complete","execution_id":"#{@exec}","clean":#{clean}})
                 )
      end
    end

    test "the keys are checked member by member, named by path" do
      {prefix, suffix} = assign_halves()
      [keys_prefix, keys_suffix] = String.split(suffix, ~s("keys":), parts: 2)
      # The keys object, then the frame's own closing brace.
      keys = Jason.decode!(binary_part(keys_suffix, 0, byte_size(keys_suffix) - 1))

      with_keys = fn keys ->
        prefix <> "e30=" <> keys_prefix <> ~s("keys":) <> Jason.encode!(keys) <> "}"
      end

      assert {:ok, %{keys: @keys}} = RunnerControl.decode(with_keys.(keys))

      for {why, bad, reason} <- [
            {"keys as a string", "opened", {:wrong_type, "keys"}},
            {"keys as null", nil, {:wrong_type, "keys"}},
            {"an extra member", Map.put(keys, "boot", "boot_1"), {:unknown_field, "keys.boot"}},
            {"no seal", Map.delete(keys, "seal"), {:missing_field, "keys.seal"}},
            {"a short call key", Map.put(keys, "call", String.slice(keys["call"], 0, 63)),
             {:invalid_field, "keys.call"}},
            {"an uppercase seal key", Map.put(keys, "seal", String.upcase(keys["seal"])),
             {:invalid_field, "keys.seal"}},
            {"a numeric call key", Map.put(keys, "call", 1), {:wrong_type, "keys.call"}},
            {"the attempt as a list", Map.put(keys, "attempt", []),
             {:wrong_type, "keys.attempt"}},
            {"an attempt member of another shape", put_in(keys, ["attempt", "boot"], "b"),
             {:unknown_field, "keys.attempt.boot"}},
            {"an attempt without its service",
             update_in(keys, ["attempt"], &Map.delete(&1, "service")),
             {:missing_field, "keys.attempt.service"}},
            {"a fence as text", put_in(keys, ["attempt", "fence"], "2"),
             {:wrong_type, "keys.attempt.fence"}},
            {"a fence as a float", put_in(keys, ["attempt", "fence"], 2.0),
             {:wrong_type, "keys.attempt.fence"}},
            {"a negative generation", put_in(keys, ["attempt", "generation"], -1),
             {:invalid_field, "keys.attempt.generation"}},
            {"a generation past 2^53 - 1",
             put_in(keys, ["attempt", "generation"], 9_007_199_254_740_992),
             {:invalid_field, "keys.attempt.generation"}},
            {"an athanor id with a space", put_in(keys, ["attempt", "athanor_id"], "ath 1"),
             {:invalid_field, "keys.attempt.athanor_id"}}
          ] do
        assert RunnerControl.decode(with_keys.(bad)) == {:error, reason}, why
      end
    end
  end

  describe "bounds" do
    test "a line of exactly max_line_bytes is within the bound; one byte more is not" do
      {prefix, suffix} = assign_halves()
      fill = RunnerControl.max_line_bytes() - byte_size(prefix) - byte_size(suffix)

      exact = prefix <> String.duplicate("A", fill) <> suffix
      assert byte_size(exact) == RunnerControl.max_line_bytes()
      assert RunnerControl.decode(exact) == {:error, {:oversize, "input"}}
      assert RunnerControl.decode(exact <> "\n") == {:error, {:oversize, "input"}}

      over = prefix <> String.duplicate("A", fill + 1) <> suffix
      assert RunnerControl.decode(over) == {:error, :oversize_line}
    end

    test "an input of exactly max_input_bytes round-trips; one byte more does not encode" do
      input = :binary.copy(<<0>>, RunnerControl.max_input_bytes())
      message = %{type: :assign, assignment: @token, input: input, keys: @keys}
      line = encoded(message)

      assert byte_size(line) - 1 <= RunnerControl.max_line_bytes()
      assert RunnerControl.decode(line) == {:ok, message}

      assert_raise ArgumentError, fn ->
        RunnerControl.encode(%{message | input: input <> <<0>>})
      end
    end

    test "an exit of exactly max_open attempts round-trips; one more is refused" do
      open = for i <- 1..RunnerControl.max_open(), do: "att_#{i}"
      message = %{type: :exit, runner: @runner, open: open}
      assert RunnerControl.decode(encoded(message)) == {:ok, message}

      line =
        ~s({"v":1,"type":"exit","runner":"#{@runner}","open":#{Jason.encode!(["att_0" | open])}})

      assert RunnerControl.decode(line) == {:error, {:oversize, "open"}}

      assert_raise ArgumentError, fn ->
        RunnerControl.encode(%{message | open: ["att_0" | open]})
      end
    end

    test "the line bound leaves room beside the largest input, and an exit fits a report" do
      largest_input = div(RunnerControl.max_input_bytes() + 2, 3) * 4
      assert RunnerControl.max_line_bytes() >= largest_input + 1024 * 1024
      assert RunnerControl.max_input_bytes() == Prima.Limits.Ceiling.lowered(%{}).max_request_size
      assert RunnerControl.max_open() * (256 + 4) < HostAPI.max_body_bytes()
    end
  end

  describe "an event" do
    @event %{
      type: :event,
      name: "storage.call",
      measurements: %{duration_ms: 3},
      metadata: %{component_ref: "formula:local.daily-report", action: "read", status: "ok"}
    }

    test "encodes its members in the roster's order, whatever the map's" do
      assert encoded(@event) ==
               ~s({"v":1,"type":"event","name":"storage.call","measurements":{"duration_ms":3},) <>
                 ~s("metadata":{"component_ref":"formula:local.daily-report","action":"read","status":"ok"}}\n)
    end

    test "raises for what decode would refuse" do
      for bad <- [
            %{@event | name: "storage.write"},
            %{@event | name: :storage_call},
            Map.delete(@event, :metadata),
            %{@event | measurements: %{}},
            %{@event | measurements: %{duration_ms: 3, bytes: 1}},
            %{@event | measurements: %{duration_ms: -1}},
            %{@event | measurements: %{duration_ms: 9_007_199_254_740_992}},
            %{@event | metadata: Map.delete(@event.metadata, :status)},
            %{@event | metadata: %{@event.metadata | status: "timeout"}},
            %{@event | metadata: %{@event.metadata | status: :ok}},
            %{@event | metadata: %{@event.metadata | action: nil}},
            %{@event | metadata: %{@event.metadata | action: <<0xFF>>}},
            %{@event | metadata: Map.put(@event.metadata, :authority, "{}")}
          ] do
        assert_raise ArgumentError, fn -> RunnerControl.encode(bad) end
      end

      http = %{
        type: :event,
        name: "http.request",
        measurements: %{duration_ms: 1, system_time: 1},
        metadata: %{component_ref: "c", method: "GET", hostname: "h", status: 200}
      }

      assert {:ok, _} = http |> encoded() |> RunnerControl.decode()

      for status <- [99, 600, "200", "ok", 200.0] do
        assert_raise ArgumentError, fn ->
          RunnerControl.encode(put_in(http, [:metadata, :status], status))
        end
      end
    end

    test "a line still past the bound once its strings are cut is not a frame, and raises" do
      # Each string is within the bound in bytes, and JSON escapes each of
      # its control characters to six.
      escaped = :binary.copy(<<1>>, RunnerControl.max_event_string_bytes())

      message = %{
        type: :event,
        name: "http.request",
        measurements: %{duration_ms: 1, system_time: 1},
        metadata: %{component_ref: escaped, method: escaped, hostname: escaped, status: 200}
      }

      assert_raise ArgumentError, ~r/past 4096 bytes/, fn -> RunnerControl.encode(message) end

      fits = put_in(message, [:metadata, :hostname], "h")
      assert {:ok, ^fits} = fits |> encoded() |> RunnerControl.decode()
    end
  end

  describe "encode" do
    test "the same message encodes to the same line, in field order" do
      message = %{type: :complete, clean: true, execution_id: @exec}
      line = ~s({"v":1,"type":"complete","execution_id":"#{@exec}","clean":true}\n)

      assert encoded(message) == line
      assert encoded(%{type: :complete, execution_id: @exec, clean: true}) == line

      assign = %{type: :assign, assignment: @token, input: "{}", keys: @keys}
      reordered = %{assign | keys: %{seal: @keys.seal, call: @keys.call, attempt: @keys.attempt}}
      assert encoded(assign) == encoded(reordered)
      assert encoded(assign) =~ ~s("keys":{"attempt":{"athanor_id":)
    end

    test "raises for what decode would refuse, since the message is the caller's own" do
      leaving = %{type: :exit, runner: @runner, open: ["att_1"]}
      assign = %{type: :assign, assignment: @token, input: "{}", keys: @keys}

      for bad <- [
            %{type: :start},
            %{type: "exit", runner: @runner, open: []},
            %{runner: @runner, open: []},
            Map.put(leaving, :clean, true),
            Map.delete(leaving, :open),
            %{leaving | open: "att_1"},
            %{leaving | open: ["att 1"]},
            %{leaving | open: [1]},
            %{leaving | runner: ""},
            %{leaving | runner: String.duplicate("r", 257)},
            %{type: :complete, execution_id: @exec, clean: "yes"},
            %{type: :cancel_child, execution_id: 7},
            %{assign | assignment: ""},
            %{assign | assignment: "a b"},
            %{assign | input: ~c"{}"},
            %{assign | keys: "opened"},
            %{assign | keys: Map.delete(@keys, :seal)},
            %{assign | keys: Map.put(@keys, :boot, "boot_1")},
            %{assign | keys: %{@keys | call: binary_part(@keys.call, 0, 31)}},
            %{assign | keys: %{@keys | seal: Base.encode16(@keys.seal, case: :lower)}},
            %{assign | keys: %{@keys | attempt: Map.delete(@keys.attempt, :service)}},
            %{assign | keys: %{@keys | attempt: Map.put(@keys.attempt, :boot, "b")}},
            %{assign | keys: %{@keys | attempt: %{@keys.attempt | fence: "2"}}},
            %{assign | keys: %{@keys | attempt: %{@keys.attempt | generation: -1}}},
            %{assign | keys: %{@keys | attempt: %{@keys.attempt | athanor_id: "ath 1"}}},
            nil,
            "exit"
          ] do
        assert_raise ArgumentError, fn -> RunnerControl.encode(bad) end
      end
    end
  end
end
