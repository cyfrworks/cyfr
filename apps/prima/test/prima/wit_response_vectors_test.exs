# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WitResponseVectorsTest do
  @moduledoc """
  The guest error envelope and a refusal's guest sentence reproduce the
  shared vectors (`tests/fixtures/guest_error.json`, which
  `Cyfr.DocsDriftTest` checks component-guide.md against and Locus's
  formula handler test plays): every `encode_error` and `safe_encode` case
  answers its envelope, a value that cannot be encoded answers the
  fallback's exact text, every setup or consent refusal analyzes to its
  case's remediation, and every `render` case renders its sentence, or
  nothing for a term the vocabulary does not know. Every case is matched
  whole, so a case of another shape fails rather than going unread.
  """

  use ExUnit.Case, async: true

  alias Prima.{GuestError, Refusal, Remediation, WitResponse}

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

  # A section's cases, each held to its shape: a case missing a member, or
  # carrying a stray one, fails here instead of being skipped by a pattern.
  defp cases!(section, count, required, optional \\ []) do
    cases = Map.fetch!(@vectors, section)
    assert length(cases) == count, "#{section} holds #{length(cases)} cases, not #{count}"

    for vector <- cases do
      assert is_map(vector), "#{section}: #{inspect(vector)} is not a case"
      keys = Map.keys(vector)

      assert required -- keys == [] and keys -- (required ++ optional) == [],
             "#{section}: #{inspect(vector)} is not a case of #{inspect(required)}"

      vector
    end
  end

  defp expected("fallback"), do: @vectors["fallback"]["answer"]
  defp expected(%{} = answer), do: answer

  # What the guest reads: the text decoded, and the fallback as its exact text.
  defp assert_answer(json, answer, why) do
    assert {:ok, decoded} = Jason.decode(json), "#{why}: #{inspect(json)} is not JSON"
    assert decoded == expected(answer), why

    if answer == "fallback", do: assert(json == @vectors["fallback"]["json"], why)
  end

  test "the envelope and the fallback agree with each other" do
    %{"member" => member, "fields" => fields, "setup_member" => setup_member} =
      @vectors["envelope"]

    %{"json" => json, "answer" => answer} = @vectors["fallback"]

    assert Jason.decode!(json) == answer
    assert [^member] = Map.keys(answer)
    assert Enum.sort(Map.keys(answer[member])) == Enum.sort(fields)
    refute setup_member in fields
  end

  test "encode_error answers every case's envelope, for a type given as a string or an atom" do
    for vector <- cases!("encode_error", 9, ~w(why type message answer)) do
      %{"why" => why, "type" => type, "message" => message, "answer" => answer} = vector

      for type <- [type, String.to_atom(type)] do
        assert_answer(WitResponse.encode_error(type, term(message)), answer, why)
      end
    end
  end

  test "every encode_error answer is the envelope and nothing else" do
    %{"member" => member, "fields" => fields} = @vectors["envelope"]

    for vector <- cases!("encode_error", 9, ~w(why type message answer)) do
      %{"why" => why, "answer" => answer} = vector
      %{^member => error} = envelope = expected(answer)
      assert Map.keys(envelope) == [member], why
      assert Enum.sort(Map.keys(error)) == Enum.sort(fields), why
      assert Enum.all?(Map.values(error), &is_binary/1), why
    end
  end

  test "safe_encode answers every case's JSON, or the fallback when it cannot encode" do
    cases = cases!("safe_encode", 4, ~w(why data answer))
    assert Enum.any?(cases, &(&1["answer"] == "fallback"))
    assert Enum.any?(cases, &(&1["answer"] != "fallback"))

    for vector <- cases do
      %{"why" => why, "data" => data, "answer" => answer} = vector
      assert_answer(WitResponse.safe_encode(term(data)), answer, why)
    end
  end

  test "a setup or consent refusal analyzes to its case's remediation, the setup envelope's third member" do
    %{"member" => member, "fields" => fields, "setup_member" => setup_member} =
      @vectors["envelope"]

    for vector <- cases!("setup_required", 2, ~w(why reason remediation message answer)) do
      %{
        "why" => why,
        "reason" => reason,
        "remediation" => remediation,
        "message" => message,
        "answer" => answer
      } = vector

      assert Remediation.analyze(term(reason)) == {:setup_required, remediation}, why

      assert answer == %{
               member => %{
                 Enum.at(fields, 0) => "setup_required",
                 Enum.at(fields, 1) => message,
                 setup_member => remediation
               }
             },
             why
    end
  end

  test "render answers every case's sentence, and nothing for a term it does not know" do
    cases = cases!("render", 23, ~w(why reason sentence), ~w(class))
    assert Enum.any?(cases, &is_nil(&1["sentence"]))

    for vector <- cases do
      %{"why" => why, "reason" => reason, "sentence" => sentence} = vector
      assert GuestError.render(term(reason)) == sentence, why
    end
  end

  test "the sample holds one refusal of each class but confirmation_required, of that class" do
    sampled =
      for vector <- cases!("render", 23, ~w(why reason sentence), ~w(class)),
          Map.has_key?(vector, "class"),
          do: {vector["class"], vector}

    classes = Enum.map(sampled, &elem(&1, 0))

    assert classes == Enum.uniq(classes)

    # confirmation_required's sentence is tests/fixtures/confirmation.json's.
    assert Enum.sort(classes) ==
             Enum.sort(Enum.map(Refusal.classes() -- [:confirmation_required], &Atom.to_string/1))

    for {class, vector} <- sampled do
      %{"why" => why, "reason" => reason} = vector
      assert Atom.to_string(Refusal.classify(term(reason)).class) == class, why
    end
  end
end
