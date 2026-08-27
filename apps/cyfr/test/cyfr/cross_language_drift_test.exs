# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.CrossLanguageDriftTest do
  @moduledoc """
  Mechanical drift guards for logic implemented more than once across
  languages. The suites (mix / go test / node) run in mutually exclusive
  path-filtered CI workflows, so nothing else can notice when a port and
  its original stop agreeing. Companion to
  `Emissary.MCP.ClientProtocolDriftTest`, which pins the protocol revision.

  Style follows `Cyfr.IngressInventoryTest`: read the sources, compare
  literals. Coarse on purpose — a failure here means "the port drifted, go
  look", never a behavioural assertion.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  test "the Go ref grammar matches Sanctum.ComponentRef" do
    elixir = read!("apps/cyfr/lib/sanctum/component_ref.ex")
    go = read!("apps/codex/internal/ref/ref.go")

    # These three are byte-identical expressions on both sides; the name
    # rule is structured differently per language (Go folds the length cap
    # into the regex) and is covered by each side's own tests.
    shared = [
      "^[a-z0-9]+(-[a-z0-9]+)*$",
      "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$",
      "^\\d+\\.\\d+\\.\\d+(-[a-zA-Z0-9.-]+)?(\\+[a-zA-Z0-9.-]+)?$"
    ]

    for expr <- shared do
      assert String.contains?(elixir, expr),
             "expression missing from component_ref.ex: #{expr}"

      assert String.contains?(go, expr),
             "expression missing from ref.go: #{expr}"
    end
  end
  # ==========================================================================
  # ComponentRef: verdict-level binding + the constants the regex test skips
  # ==========================================================================

  test "the shared ref fixture reaches the same verdicts here as in Go" do
    # Go's twin is apps/codex/internal/ref/ref_fixture_test.go, reading the
    # same file. The regex-literal test above proves the sources SPELL the
    # same rules; this proves they REACH the same verdicts — a divergence in
    # how a rule is applied fails one side's run.
    %{"cases" => cases} =
      "tests/fixtures/component_refs.json"
      |> (&Path.join(@root, &1)).()
      |> File.read!()
      |> Jason.decode!()

    for case_ <- cases do
      ref = case_["ref"]

      # validate/1 is the strict verdict (parse is shape-only); parse/1
      # supplies the fields the fixture pins on valid cases.
      case Sanctum.ComponentRef.validate(ref) do
        :ok ->
          assert case_["valid"], "#{ref} validated but the fixture says invalid"

          {:ok, parsed} = Sanctum.ComponentRef.parse(ref)
          assert parsed.type == case_["type"], "#{ref}: type #{parsed.type}"
          assert parsed.namespace == case_["namespace"], "#{ref}: ns #{parsed.namespace}"
          assert parsed.name == case_["name"], "#{ref}: name #{parsed.name}"
          assert parsed.version == case_["version"], "#{ref}: version #{parsed.version}"

        {:error, why} ->
          refute case_["valid"], "#{ref} refused (#{why}) but the fixture says valid"
      end
    end
  end

  test "the Go ref constants match Sanctum.ComponentRef's" do
    elixir = read!("apps/cyfr/lib/sanctum/component_ref.ex")
    go = read!("apps/codex/internal/ref/ref.go")

    # The length caps and rosters the regex test cannot see. Elixir spells
    # the caps as module attributes / guards; Go as named constants.
    assert elixir =~ "39", "personal slug cap missing from Elixir source"
    assert go =~ "personalSlugMaxLen  = 39"
    assert elixir =~ "253"
    assert go =~ "publisherSlugMaxLen = 253"
    assert elixir =~ "64"
    assert go =~ "nameMaxLen          = 64"

    for type <- ~w(catalyst reagent formula tincture) do
      assert elixir =~ ~s("#{type}"), "type #{type} missing from Elixir roster"
      assert go =~ ~s("#{type}":), "type #{type} missing from Go roster"
    end

    for {short, full} <- [{"c", "catalyst"}, {"r", "reagent"}, {"f", "formula"}, {"t", "tincture"}] do
      assert go =~ ~s("#{short}": "#{full}")
    end

    assert elixir =~ "localhost"
    assert go =~ ~s(ns == "localhost")
  end
end
