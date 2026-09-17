# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RunnerControlTest do
  @moduledoc """
  The runner control codec reproduces the shared vectors
  (`tests/fixtures/runner_control.json`, which the keeper's suite reads
  too): every valid frame encodes to exactly its line and decodes back to
  its message, with or without its newline, and every invalid line is
  refused with its reason. An `assign` carries what `start` was given.
  The bounds are the fixture's: a line of exactly the maximum is within
  the bound, an input of exactly the maximum and an `exit` of exactly the
  most open attempts round-trip, and the line bound leaves room for the
  largest input in base64. The encoder refuses, by raising, what the
  decoder would refuse.
  """

  use ExUnit.Case, async: true

  alias Cyfr.{Assignment, HostAPI, RunnerControl}

  @vectors Path.expand("../../../../tests/fixtures/runner_control.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @token "eyJ2IjoxfQ.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @sealed "eyJhIjoxfQ.AAAAAAAAAAAAAAAA"
  @exec "exec_01a09fee-07cc-791f-a598-e7f90608c9e2"
  @runner "run_01a09fee-1c2d-7e3f-8a4b-5c6d7e8f9a0b"

  defp line(%{"line" => line}), do: line

  defp line(%{"repeated_line" => %{"prefix" => p, "repeat" => r, "times" => n, "suffix" => s}}),
    do: p <> String.duplicate(r, n) <> s

  defp message(%{"type" => type} = fields) do
    fields
    |> Map.new(fn {name, value} -> {String.to_existing_atom(name), value} end)
    |> Map.put(:type, String.to_existing_atom(type))
  end

  defp reason(%{"reason" => reason, "field" => field}),
    do: {String.to_existing_atom(reason), field}

  defp reason(%{"reason" => reason}), do: String.to_existing_atom(reason)

  defp encoded(message), do: message |> RunnerControl.encode() |> IO.iodata_to_binary()

  describe "the shared vectors" do
    test "the bounds and version are the fixture's" do
      assert RunnerControl.version() == @vectors["version"]
      assert RunnerControl.max_line_bytes() == @vectors["max_line_bytes"]
      assert RunnerControl.max_input_bytes() == @vectors["max_input_bytes"]
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

    test "every invalid line is refused with its reason" do
      for vector <- @vectors["invalid"] do
        line = line(vector)
        if bytes = vector["line_bytes"], do: assert(byte_size(line) == bytes, vector["why"])
        assert RunnerControl.decode(line) == {:error, reason(vector)}, vector["why"]
        assert RunnerControl.decode(line <> "\n") == {:error, reason(vector)}, vector["why"]
      end
    end

    test "every message type has a valid vector and every reason an invalid one" do
      valid_types = Enum.map(@vectors["valid"], &String.to_existing_atom(&1["message"]["type"]))
      assert Enum.sort(Enum.uniq(valid_types)) == Enum.sort(RunnerControl.types())
      assert RunnerControl.types() == [:assign, :cancel_child, :complete, :exit]

      reasons = @vectors["invalid"] |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.sort()

      assert reasons ==
               Enum.sort(~w(
                 oversize_line malformed bad_version unknown_type unknown_field
                 missing_field wrong_type invalid_field oversize
               ))

      fields = for %{"field" => field} <- @vectors["invalid"], uniq: true, do: field
      assert "input" in fields and "open" in fields and "clean" in fields
    end

    test "an assign carries what start was given: a readable token and the input its digest binds" do
      vector = Enum.find(@vectors["valid"], &(&1["message"]["type"] == "assign"))
      {:ok, %{type: :assign} = assign} = RunnerControl.decode(line(vector))

      assert {:ok, %Assignment{input_digest: digest}} = Assignment.read(assign.assignment)
      assert Cyfr.Digest.sha256(assign.input) == digest
      assert String.contains?(line(vector), Base.encode64(assign.input))
    end

    test "the service sends assign and cancel_child, the runner complete and exit" do
      assert RunnerControl.sender(:assign) == :service
      assert RunnerControl.sender(:cancel_child) == :service
      assert RunnerControl.sender(:complete) == :runner
      assert RunnerControl.sender(:exit) == :runner
      assert_raise FunctionClauseError, fn -> RunnerControl.sender(:start) end
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
  end

  describe "bounds" do
    test "a line of exactly max_line_bytes is within the bound; one byte more is not" do
      prefix = ~s({"v":1,"type":"assign","assignment":"#{@token}","input":")
      suffix = ~s(","sealed_keys":"#{@sealed}"})
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
      message = %{type: :assign, assignment: @token, input: input, sealed_keys: @sealed}
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
      assert RunnerControl.max_input_bytes() == Cyfr.Limits.Ceiling.lowered(%{}).max_request_size
      assert RunnerControl.max_open() * (256 + 4) < HostAPI.max_body_bytes()
    end
  end

  describe "encode" do
    test "the same message encodes to the same line, in field order" do
      message = %{type: :complete, clean: true, execution_id: @exec}
      line = ~s({"v":1,"type":"complete","execution_id":"#{@exec}","clean":true}\n)

      assert encoded(message) == line
      assert encoded(%{type: :complete, execution_id: @exec, clean: true}) == line
    end

    test "raises for what decode would refuse, since the message is the caller's own" do
      leaving = %{type: :exit, runner: @runner, open: ["att_1"]}

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
            %{type: :assign, assignment: "", input: "{}", sealed_keys: @sealed},
            %{type: :assign, assignment: @token, input: "{}", sealed_keys: "a b"},
            %{type: :assign, assignment: @token, input: ~c"{}", sealed_keys: @sealed},
            nil,
            "exit"
          ] do
        assert_raise ArgumentError, fn -> RunnerControl.encode(bad) end
      end
    end
  end
end
