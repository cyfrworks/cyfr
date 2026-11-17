# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Brain.WireTest do
  @moduledoc """
  The brain wire, the holder's side (`Opus.Brain.Wire`), against the
  vectors every driver reads too (`tests/fixtures/brain_wire.json`):
  every message's members and their types, the bounds and vocabularies,
  each example and `read` line read as it says, and each `refuse` line
  refused for its reason.
  """
  use ExUnit.Case, async: true

  alias Opus.Brain.Wire

  @vectors Path.expand("../../../../../tests/fixtures/brain_wire.json", __DIR__)
  @external_resource @vectors

  setup_all do
    {:ok, vectors: @vectors |> File.read!() |> Jason.decode!()}
  end

  test "the version, bounds and vocabularies are the vectors'", %{vectors: v} do
    assert v["version"] == Wire.version()
    assert v["max_line_bytes"] == Wire.max_line_bytes()
    assert v["max_id_bytes"] == Wire.max_id_bytes()
    assert v["max_list"] == Wire.max_list()

    assert v["config"] ==
             Map.new(Wire.config(), fn {key, type} -> {key, Atom.to_string(type)} end)

    assert v["counts"] == Wire.counts()
    assert v["phases"] == Wire.phases()
    assert v["error_types"] == Wire.error_types()
    assert v["media_types"] == Wire.media_types()
    assert v["native"] == Wire.native()
  end

  test "every message is the vectors', and its example reads", %{vectors: v} do
    for {direction, key, vectors, read} <- [
          {:commands, "commands", v["commands"], &Wire.read_command/1},
          {:events, "events", v["events"], &Wire.decode/1}
        ] do
      ours = Wire.messages(direction)
      assert Enum.sort(Map.keys(ours)) == Enum.sort(Map.keys(vectors))

      for {name, {fields, optional, types}} <- ours do
        theirs = vectors[name]
        assert fields == theirs["fields"], "#{key} #{name}"
        assert Enum.sort(optional) == Enum.sort(theirs["optional"]), "#{key} #{name}"

        assert Map.new(types, fn {field, type} -> {field, Atom.to_string(type)} end) ==
                 theirs["types"],
               "#{key} #{name}"

        assert {:ok, read_back} = read.(Jason.encode!(theirs["example"])), "#{key} #{name}"
        assert read_back == theirs["example"]
      end
    end
  end

  test "each line the vectors read reads as they say", %{vectors: v} do
    for %{"name" => name, "from" => from, "line" => line, "reads" => reads} <- v["read"] do
      reader = if from == "holder", do: &Wire.read_command/1, else: &Wire.decode/1
      assert reader.(line) == {:ok, reads}, name
    end
  end

  test "each line the vectors refuse is refused for its reason", %{vectors: v} do
    for %{"name" => name, "from" => from, "reason" => reason} = refused <- v["refuse"] do
      line =
        case refused do
          %{"line" => line} ->
            line

          %{"line_bytes" => bytes} ->
            prefix = ~s({"t":"said","gen":0,"message":"m","text":")
            line = prefix <> String.duplicate("x", bytes - byte_size(prefix) - 2) <> ~s("})
            assert byte_size(line) == bytes
            line
        end

      reader = if from == "holder", do: &Wire.read_command/1, else: &Wire.decode/1
      assert reader.(line) == {:error, String.to_existing_atom(reason)}, name
    end
  end

  test "a command is written only as one the driver reads", %{vectors: v} do
    assert {:ok, line} = Wire.encode(v["commands"]["post"]["example"])
    assert Wire.read_command(line) == {:ok, v["commands"]["post"]["example"]}

    for refused <- [
          %{"t" => "start", "gen" => 0, "config" => %{"dangerously_skip_permissions" => true}},
          %{"t" => "post", "id" => "", "work" => "w", "content" => []},
          %{"t" => "hello", "v" => 1, "driver" => "d", "boot" => "b"},
          %{"t" => "answer", "id" => "a", "ask" => "k", "content" => "c"}
        ] do
      assert {:error, _not_a_command} = Wire.encode(refused), inspect(refused)
    end

    big = String.duplicate("x", Wire.max_line_bytes())

    assert Wire.encode(%{
             "t" => "post",
             "id" => "p",
             "work" => "w",
             "content" => [%{"type" => "text", "text" => big}]
           }) == {:error, :too_large}
  end

  test "the program's own lines are the native events", %{vectors: v} do
    for {name, %{"example" => example}} <- v["events"] do
      assert Wire.native?(example) == name in v["native"], name
    end
  end
end
