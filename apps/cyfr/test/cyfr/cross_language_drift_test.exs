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

  test "the Go ref grammar matches Prima.ComponentRef" do
    elixir = read!("apps/prima/lib/prima/component_ref.ex")
    go = read!("apps/codex/internal/ref/ref.go")

    # Grammar bodies match across languages. Whole-input anchors are
    # \A…\z in Elixir and ^…$ in Go. Name-length checks have separate tests.
    shared = [
      "[a-z0-9]+(-[a-z0-9]+)*",
      "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?",
      "(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(-(0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*)(\\.(0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\\+[0-9a-zA-Z-]+(\\.[0-9a-zA-Z-]+)*)?"
    ]

    for body <- shared do
      assert String.contains?(elixir, body),
             "expression missing from component_ref.ex: #{body}"

      assert String.contains?(go, "^" <> body <> "$"),
             "expression missing from ref.go (anchored ^..$): #{body}"
    end

    # And the Elixir side anchors them the strict way, everywhere — the
    # property the bodies above cannot show. `Prima.ComponentRefTest`
    # covers the behaviour ("alice\n" is refused); this is the spelling.
    refute elixir =~ ~r/~r\/\^/,
           "component_ref.ex anchors a grammar with `^`; PCRE's `$` also " <>
             "matches before a trailing newline — use \\A..\\z"
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
      case Prima.ComponentRef.validate(ref) do
        :ok ->
          assert case_["valid"], "#{ref} validated but the fixture says invalid"

          {:ok, parsed} = Prima.ComponentRef.parse(ref)
          assert parsed.type == case_["type"], "#{ref}: type #{parsed.type}"
          assert parsed.namespace == case_["namespace"], "#{ref}: ns #{parsed.namespace}"
          assert parsed.name == case_["name"], "#{ref}: name #{parsed.name}"
          assert parsed.version == case_["version"], "#{ref}: version #{parsed.version}"

        {:error, why} ->
          refute case_["valid"], "#{ref} refused (#{why}) but the fixture says valid"
      end
    end
  end

  test "the shared version-ordering fixture ranks the same here as in Go" do
    # Go's twin is TestVersionOrderingFixture in ref_fixture_test.go. The
    # verdict cases above cover PARSING; this covers ORDERING — the two
    # sides once disagreed on every mixed pair (Go byte-compared when
    # either side failed the grammar; the server ranks the parsable side
    # higher and byte-compares only when both fail).
    %{"version_ordering" => cases} =
      "tests/fixtures/component_refs.json"
      |> (&Path.join(@root, &1)).()
      |> File.read!()
      |> Jason.decode!()

    assert cases != []

    for %{"a" => a, "b" => b, "expect" => expect} <- cases do
      assert Compendium.Semver.compare(a, b) == String.to_existing_atom(expect),
             "compare(#{a}, #{b}) expected #{expect}"
    end
  end

  test "the Go ref constants match Prima.ComponentRef's" do
    elixir = read!("apps/prima/lib/prima/component_ref.ex")
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
    for type <- Prima.ComponentRef.valid_types() do
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

  # Authority error tags must agree across language boundaries.

  test "the consent-tag vocabulary agrees across Sanctum, the MCP boundary and the CLI" do
    # Sanctum.Consent declares the vocabulary; the tuples stay TYPED to the
    # wire router, which promotes them to protocol errors — one -335xx code
    # per tag (Emissary.MCP.Message), the payload in error.data
    # (Emissary.MCP.ConsentSignal) — and codex recovers them from the code
    # and data (mcp.ConsentError). A tag or code renamed on one side
    # silently stops being explained (Go) or stops crossing the boundary —
    # this pins every roster.
    consent = read!("apps/sanctum/lib/sanctum/consent.ex")
    execution_mcp = read!("apps/cyfr/lib/cyfr/execution/mcp.ex")
    signal = read!("apps/cyfr/lib/emissary/mcp/consent_signal.ex")
    message = read!("apps/cyfr/lib/emissary/mcp/message.ex")
    root_go = read!("apps/codex/cmd/root.go")
    client_go = read!("apps/codex/internal/mcp/client.go")

    tags = ~w(setup_required consent_required consent_conflict restart_required)

    codes = %{
      "setup_required" => "-33501",
      "consent_required" => "-33502",
      "consent_conflict" => "-33503",
      "restart_required" => "-33504"
    }

    for tag <- tags do
      assert consent =~ "{:#{tag}, #{tag}()}",
             "tag #{tag} missing from Sanctum.Consent's authority_error union"

      assert signal =~ ":#{tag}",
             "tag #{tag} missing from Emissary.MCP.ConsentSignal's roster"

      assert message =~ "#{tag}: #{codes[tag]}",
             "code #{codes[tag]} for #{tag} missing from Emissary.MCP.Message"

      assert client_go =~ ~s(#{codes[tag]}: "#{tag}"),
             "code #{codes[tag]} for #{tag} missing from client.go's consentTagByCode"

      assert root_go =~ ~s("#{tag}"),
             "tag #{tag} missing from codex root.go's explain roster"
    end

    # The error.data envelope keys, spelled the same on both ends.
    assert signal =~ ~s("tag") and signal =~ ~s("payload")
    assert client_go =~ ~s(data["tag"]) and client_go =~ ~s(data["payload"])

    # Cyfr.Execution.MCP spells the roster once, as the guard on format_root_result/1.
    assert execution_mcp =~
             "tag in [:setup_required, :consent_required, :consent_conflict, :restart_required]",
           "execution/mcp.ex guard roster must include the four consent signal tags"

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
    # Check shared metadata keys, request headers and binary sentinels across bundled clients.
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
