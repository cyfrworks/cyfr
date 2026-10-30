# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.HandleAnswerTest do
  @moduledoc """
  The registry's handle answer as data (`tests/fixtures/registry_wire.json`,
  which the registry at cyfr.run reads too): each answer's bytes parse, for
  the handle and registry asked, to their result, which encodes back to
  those bytes, or to `:malformed_answer`; an answer for another handle or
  registry, with any key beside its five (an address among them), or with
  a value outside its grammar, is refused; a registry
  error envelope reads back to its refusal; and every
  handle spelling the slug grammar refuses is refused in an answer too.
  """

  use ExUnit.Case, async: true

  alias Prima.HandleAnswer

  @vectors Path.expand("../../../../tests/fixtures/registry_wire.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp fields(%HandleAnswer{} = answer) do
    answer
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "the protocol string" do
    assert HandleAnswer.protocol() == "cyfr-handle/v1"
  end

  test "every answer parses to its result, which encodes back to its bytes, or is refused" do
    for %{"name" => name, "bytes" => bytes, "handle" => handle, "registry" => registry} = vector <-
          vectors()["answers"] do
      result = HandleAnswer.parse(bytes, handle, registry)

      case vector do
        %{"result" => expected} ->
          assert {:ok, answer} = result, name
          assert fields(answer) == expected, name
          assert HandleAnswer.encode(answer) == bytes, name
          assert HandleAnswer.parse(Jason.decode!(bytes), handle, registry) == result, name

        %{"error" => error} ->
          assert result == {:error, String.to_existing_atom(error)}, name

          with {:ok, map} when is_map(map) <- Jason.decode(bytes) do
            assert HandleAnswer.parse(map, handle, registry) == result, name
          end
      end
    end
  end

  test "an answer carrying an address is refused, and no answer the vectors accept has one" do
    answers = vectors()["answers"]

    assert %{"bytes" => bytes, "error" => "malformed_answer"} =
             Enum.find(answers, &(&1["name"] == "an answer carrying an address"))

    assert %{"address" => _} = Jason.decode!(bytes)

    assert %{"result" => result} = Enum.find(answers, &(&1["name"] == "an answer"))
    refute Map.has_key?(result, "address")
    refute Enum.any?(answers, &match?(%{"result" => %{"address" => _}}, &1))
  end

  test "an answer names exactly the handle asked, in the handle grammar" do
    v = vectors()
    genesis = v["identity"]["heads"]["genesis"]

    for {verdict, handles} <- v["slugs"]["handles"], handle <- handles do
      answer = %{
        "protocol" => HandleAnswer.protocol(),
        "registry" => "cyfr.run",
        "handle" => handle,
        "identifier" => genesis["identifier"],
        "directory" => genesis["directory"]
      }

      case verdict do
        "valid" ->
          assert {:ok, %HandleAnswer{handle: ^handle}} =
                   HandleAnswer.parse(answer, handle, "cyfr.run")

          assert HandleAnswer.parse(answer, handle <> "x", "cyfr.run") ==
                   {:error, :malformed_answer}

        "invalid" ->
          assert HandleAnswer.parse(answer, handle, "cyfr.run") == {:error, :malformed_answer},
                 handle
      end
    end
  end

  test "an input that is no answer is refused" do
    assert HandleAnswer.parse(nil, "alice", "cyfr.run") == {:error, :malformed_answer}
    assert HandleAnswer.parse(42, "alice", "cyfr.run") == {:error, :malformed_answer}
  end
end
