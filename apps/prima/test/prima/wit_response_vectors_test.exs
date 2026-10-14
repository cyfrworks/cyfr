# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WitResponseVectorsTest do
  @moduledoc """
  The guest error envelope and a refusal's guest sentence reproduce the
  shared vectors (`tests/fixtures/guest_error.json`, which
  `Cyfr.DocsDriftTest` checks component-guide.md against): every
  `encode_error` and `safe_encode` case answers its envelope, a value that
  cannot be encoded answers the fallback's exact text, and every `render`
  case renders its sentence, or nothing for a term the vocabulary does not
  know.
  """

  use ExUnit.Case, async: true

  alias Prima.{GuestError, Refusal, WitResponse}

  @vectors Path.expand("../../../../tests/fixtures/guest_error.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  # A vector's term, as its file's comment spells one in JSON.
  defp term(%{"atom" => name}), do: String.to_atom(name)
  defp term(%{"tuple" => items}), do: items |> Enum.map(&term/1) |> List.to_tuple()
  defp term(%{"map" => members}), do: Map.new(members, fn {k, v} -> {k, term(v)} end)
  defp term(%{"bytes_base64" => bytes}), do: Base.decode64!(bytes)
  defp term(items) when is_list(items), do: Enum.map(items, &term/1)

  defp term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp expected("fallback"), do: @vectors["fallback"]["answer"]
  defp expected(answer) when is_map(answer), do: answer

  # What the guest reads: the text decoded, and the fallback as its exact text.
  defp assert_answer(json, answer, why) do
    assert {:ok, decoded} = Jason.decode(json), "#{why}: #{inspect(json)} is not JSON"
    assert decoded == expected(answer), why

    if answer == "fallback", do: assert(json == @vectors["fallback"]["json"], why)
  end

  test "the envelope and the fallback agree with each other" do
    %{"member" => member, "fields" => fields} = @vectors["envelope"]
    %{"json" => json, "answer" => answer} = @vectors["fallback"]

    assert Jason.decode!(json) == answer
    assert [^member] = Map.keys(answer)
    assert Enum.sort(Map.keys(answer[member])) == Enum.sort(fields)
  end

  test "encode_error answers every case's envelope, for a type given as a string or an atom" do
    cases = @vectors["encode_error"]
    assert cases != []

    for %{"why" => why, "type" => type, "message" => message, "answer" => answer} <- cases,
        type <- [type, String.to_atom(type)] do
      assert_answer(WitResponse.encode_error(type, term(message)), answer, why)
    end
  end

  test "every encode_error answer is the envelope and nothing else" do
    %{"member" => member, "fields" => fields} = @vectors["envelope"]

    for %{"why" => why, "answer" => answer} <- @vectors["encode_error"] do
      %{^member => error} = envelope = expected(answer)
      assert Map.keys(envelope) == [member], why
      assert Enum.sort(Map.keys(error)) == Enum.sort(fields), why
      assert Enum.all?(Map.values(error), &is_binary/1), why
    end
  end

  test "safe_encode answers every case's JSON, or the fallback when it cannot encode" do
    cases = @vectors["safe_encode"]
    assert Enum.any?(cases, &(&1["answer"] == "fallback"))
    assert Enum.any?(cases, &(&1["answer"] != "fallback"))

    for %{"why" => why, "data" => data, "answer" => answer} <- cases do
      assert_answer(WitResponse.safe_encode(term(data)), answer, why)
    end
  end

  test "render answers every case's sentence, and nothing for a term it does not know" do
    cases = @vectors["render"]
    assert Enum.any?(cases, &is_nil(&1["sentence"]))

    for %{"why" => why, "reason" => reason, "sentence" => sentence} <- cases do
      assert GuestError.render(term(reason)) == sentence, why
    end
  end

  test "the sample holds one refusal of each class but confirmation_required, of that class" do
    sampled = for %{"class" => class} = refusal <- @vectors["render"], do: {class, refusal}
    classes = Enum.map(sampled, &elem(&1, 0))

    assert classes == Enum.uniq(classes)

    # confirmation_required's sentence is tests/fixtures/confirmation.json's.
    assert Enum.sort(classes) ==
             Enum.sort(Enum.map(Refusal.classes() -- [:confirmation_required], &Atom.to_string/1))

    for {class, %{"why" => why, "reason" => reason}} <- sampled do
      assert Atom.to_string(Refusal.classify(term(reason)).class) == class, why
    end
  end
end
