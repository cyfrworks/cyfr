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
      "^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(-(0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*)(\\.(0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\\+[0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)?$"
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

    # Derived, not spelled: a literal roster here goes green for a fifth
    # component kind while checking nothing about it.
    for type <- Sanctum.ComponentRef.valid_types() do
      assert elixir =~ ~s("#{type}"), "type #{type} missing from Elixir roster"
      assert go =~ ~s("#{type}":), "type #{type} missing from Go roster"
    end

    for {short, full} <- [
          {"c", "catalyst"},
          {"r", "reagent"},
          {"f", "formula"},
          {"t", "tincture"}
        ] do
      assert go =~ ~s("#{short}": "#{full}")
    end

    assert elixir =~ "localhost"
    assert go =~ ~s(ns == "localhost")
  end

  # ==========================================================================
  # §4.3 authority-error vocabulary: one tag set across three boundaries
  # ==========================================================================

  test "the consent-tag vocabulary agrees across Sanctum, the MCP boundary and the CLI" do
    # Sanctum.Consent declares the vocabulary; Opus.MCP flattens the tuples
    # to "tag: {json}" strings for the wire; codex parses that prefix back.
    # A tag added or renamed on one side silently stops being explained (Go)
    # or stops crossing the boundary (opus) — this pins all three rosters.
    consent = read!("apps/cyfr/lib/sanctum/consent.ex")
    opus_mcp = read!("apps/opus/lib/opus/mcp.ex")
    root_go = read!("apps/codex/cmd/root.go")

    tags = ~w(setup_required consent_required consent_conflict restart_required)

    for tag <- tags do
      assert consent =~ "{:#{tag}, #{tag}()}",
             "tag #{tag} missing from Sanctum.Consent's authority_error union"

      assert root_go =~ ~s("#{tag}"),
             "tag #{tag} missing from codex root.go's explain roster"
    end

    # Opus.MCP spells the roster once, as the guard on format_root_result/1.
    assert opus_mcp =~
             "tag in [:setup_required, :consent_required, :consent_conflict, :restart_required]",
           "opus/mcp.ex guard roster no longer spells the four §4.3 tags"

    # The payload keys Consent documents as normative are the ones the CLI
    # formatter reads — a renamed key degrades every explanation to the
    # payload's zero values without failing anything.
    for key <- ~w(node_ref need current_revision cause actual_revision new_revision) do
      assert consent =~ key, "payload key #{key} missing from Sanctum.Consent"
      assert root_go =~ ~s(payload["#{key}"]), "payload key #{key} not read by root.go"
    end
  end

  # ==========================================================================
  # MCP conformance vocabulary — the literals beyond the protocol revision
  # ==========================================================================

  test "the MCP conformance vocabulary is spelled the same in every client" do
    # `Emissary.MCP.ClientProtocolDriftTest` pins the protocol REVISION;
    # this pins the vocabulary AROUND it. Renaming a `_meta` key, a request
    # header or the base64 sentinel on the Elixir side used to compile
    # cleanly, pass the whole suite, and lock out both bundled clients at
    # runtime with a -32602.
    protocol = read!("apps/cyfr/lib/emissary/mcp/protocol.ex")
    message = read!("apps/cyfr/lib/emissary/mcp/message.ex")
    mjs = read!("apps/mcp-bridge/server.mjs")
    client_go = read!("apps/codex/internal/mcp/client.go")
    types_go = read!("apps/codex/internal/mcp/types.go")
    go = client_go <> types_go

    # {literal, [sources that must carry it]} — a source is listed only
    # where it genuinely speaks that part of the vocabulary (the bridge
    # never reads clientInfo, so it is not held to it).
    vocabulary = [
      {"io.modelcontextprotocol/protocolVersion", [protocol, mjs, go]},
      {"io.modelcontextprotocol/clientCapabilities", [protocol, mjs, go]},
      {"io.modelcontextprotocol/clientInfo", [protocol, go]},
      {"io.modelcontextprotocol/serverInfo", [protocol, mjs, go]},
      {"=?base64?", [protocol, mjs, go]},
      {"-32020", [message, mjs]},
      {"-32022", [message, mjs]},
      # The auth sentinel: the Go CLI keys `errors.Is(err, ErrAuthRequired)`
      # on this number and the bridge answers with it, but all three defined
      # it independently and nothing held them together.
      {"-33001", [message, mjs, go]}
    ]

    for {literal, sources} <- vocabulary,
        {source, index} <- Enum.with_index(sources) do
      assert String.contains?(source, literal),
             "conformance literal #{inspect(literal)} missing from source ##{index} " <>
               "(order: as listed in the vocabulary table)"
    end

    # The three request headers, case-insensitively — Go title-cases them.
    for header <- ["mcp-protocol-version", "mcp-method", "mcp-name"] do
      for {name, source} <- [{"protocol.ex", protocol}, {"server.mjs", mjs}, {"go", go}] do
        assert String.contains?(String.downcase(source), header),
               "request header #{header} missing from #{name}"
      end
    end
  end
end
