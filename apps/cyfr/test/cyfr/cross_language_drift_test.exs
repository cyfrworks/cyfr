# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.CrossLanguageDriftTest do
  @moduledoc """
  Mechanical drift guards for logic implemented more than once across
  languages. The suites (mix / go test) run in mutually exclusive
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

  defp fixture!(name), do: "tests/fixtures/#{name}" |> read!() |> Jason.decode!()

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

  test "the component path grammar is the ref grammar the Go side reads, through one parser" do
    # A version directory's segments are validated by the same rules a ref
    # is (`Prima.ComponentRef`), which ref_fixture_test.go holds the Go CLI
    # to: every valid ref of the shared fixture names a directory the one
    # parser reads back to the same parts.
    valid = for %{"valid" => true} = case_ <- fixture!("component_refs.json")["cases"], do: case_
    assert valid != []

    for %{"type" => type, "namespace" => ns, "name" => name, "version" => version} <- valid do
      segments = Compendium.ComponentPath.version_dir(type, ns, name, version)

      assert {:ok, %{type: ^type, publisher: ^ns, name: ^name, version: ^version, rest: []}} =
               Compendium.ComponentPath.parse(segments),
             "#{Enum.join(segments, "/")} does not parse back to its ref's parts"
    end

    # The source tool reads a path through that parser and restates no
    # shape of its own.
    source = read!("apps/cyfr/lib/compendium/providers/source.ex")
    assert source =~ "Compendium.ComponentPath.parse("
    refute source =~ ~s(["components", ), "source.ex matches the component layout by hand"
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
    # per tag (Prima.MCP.Message), the payload in error.data
    # (Prima.ConsentSignal) — and codex recovers them from the code
    # and data (mcp.ConsentError). A tag or code renamed on one side
    # silently stops being explained (Go) or stops crossing the boundary —
    # this pins every roster.
    consent = read!("apps/sanctum/lib/sanctum/consent.ex")
    execution_mcp = read!("apps/cyfr/lib/crucible/provider.ex")
    profile = read!("apps/sanctum/lib/sanctum/providers/profile.ex")
    signal = read!("apps/prima/lib/prima/consent_signal.ex")
    message = read!("apps/prima/lib/prima/mcp/message.ex")
    root_go = read!("apps/codex/cmd/root.go")
    client_go = read!("apps/codex/internal/mcp/client.go")

    # The roster is Prima.Refusal's, read from Prima.ConsentSignal; every
    # other side is held to it, so a sixth tag fails here until each side
    # names it.
    assert Prima.Refusal.signal_tags() == Prima.ConsentSignal.tags()
    tags = Enum.map(Prima.Refusal.signal_tags(), &Atom.to_string/1)
    assert length(tags) == 5

    go_tags = Regex.scan(~r/-335\d\d: "(\w+)"/, client_go, capture: :all_but_first)

    assert Enum.sort(List.flatten(go_tags)) == Enum.sort(tags),
           "client.go's consentTagByCode is not the roster"

    # The profile tool keeps a signal typed through the roster's guard and
    # spells no tag list of its own.
    assert profile =~ "Prima.Refusal.is_consent_signal(tag, payload)"
    refute profile =~ "tag in [:setup_required", "profile.ex spells the consent tags itself"

    codes = %{
      "setup_required" => "-33501",
      "consent_required" => "-33502",
      "consent_conflict" => "-33503",
      "restart_required" => "-33504",
      "confirmation_required" => "-33505"
    }

    for tag <- tags do
      assert consent =~ "{:#{tag}, #{tag}()}",
             "tag #{tag} missing from Sanctum.Consent's authority_error union"

      assert signal =~ ":#{tag}",
             "tag #{tag} missing from Prima.ConsentSignal's roster"

      assert message =~ "#{tag}: #{codes[tag]}",
             "code #{codes[tag]} for #{tag} missing from Prima.MCP.Message"

      assert client_go =~ ~s(#{codes[tag]}: "#{tag}"),
             "code #{codes[tag]} for #{tag} missing from client.go's consentTagByCode"

      assert root_go =~ ~s("#{tag}"),
             "tag #{tag} missing from codex root.go's explain roster"
    end

    # The error.data envelope keys, spelled the same on both ends.
    assert signal =~ ~s("tag") and signal =~ ~s("payload")
    assert client_go =~ ~s(data["tag"]) and client_go =~ ~s(data["payload"])

    # Crucible.Provider spells the roster once, as the guard on format_root_result/1.
    [guard] =
      Regex.run(
        ~r/defp format_root_result\(\{:error, \{tag, payload\}\}\)\s+when tag in \[([^\]]*)\]/,
        execution_mcp,
        capture: :all_but_first
      )

    guard_tags =
      guard |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> trim_colon()))

    assert Enum.sort(guard_tags) == Enum.sort(tags),
           "crucible/provider.ex guard roster must be the five consent signal tags"

    # The payload keys Consent documents as normative are the ones the CLI
    # formatter reads — a renamed key degrades every explanation to the
    # payload's zero values without failing anything.
    for key <- ~w(node_ref need current_revision cause actual_revision new_revision) do
      assert consent =~ key, "payload key #{key} missing from Sanctum.Consent"
      assert root_go =~ ~s(payload["#{key}"]), "payload key #{key} not read by root.go"
    end

    # A pending confirmation's payload is its id, operation and expiry; the
    # CLI names the record by the id's ref, never the id, and sends the
    # person to Prism to confirm it before repeating the change.
    [confirmation_go] =
      Regex.run(~r/case "confirmation_required":(.*?)\n\t(?:case |\})/s, root_go,
        capture: :all_but_first
      )

    # The keys are read inside the type itself: `profile_id: ` elsewhere in
    # the module must not stand in for a missing `id: `.
    [confirmation_type] =
      Regex.run(~r/@type confirmation_required :: %\{(.*?)\}/s, consent, capture: :all_but_first)

    type_keys =
      ~r/^\s*(\w+):/m
      |> Regex.scan(confirmation_type, capture: :all_but_first)
      |> List.flatten()

    assert type_keys == ~w(id operation expires_at),
           "Sanctum.Consent's confirmation_required type must be exactly id, operation, expires_at"

    for key <- ~w(id operation expires_at) do
      assert confirmation_go =~ ~s(payload["#{key}"]),
             "payload key #{key} not read by root.go's confirmation_required case"
    end

    assert confirmation_go =~ "Prism", "root.go does not send the person to Prism to confirm"
  end

  defp trim_colon(":" <> tag), do: tag

  # ==========================================================================
  # The MAC names: domains, service labels and the auth header
  # ==========================================================================

  test "the MAC names are Prima.MacEnvelope's in every vector file and on every side" do
    alias Prima.MacEnvelope

    # The Locus services, as the vector files the builds and backends image
    # harnesses read them from, and as the protocol modules answer them.
    for {file, service, protocol} <- [
          {"locus_builds.json", :builds, Prima.BuilderProtocol},
          {"locus_backends.json", :backends, Prima.LocusBackends}
        ] do
      wire = fixture!(file)
      assert wire["domain"] == MacEnvelope.domain(:locus), file
      assert wire["service"] == MacEnvelope.service(service), file
      assert wire["label"] == MacEnvelope.label(service), file
      assert wire["auth_header"] == MacEnvelope.auth_header(), file
      assert protocol.domain() == MacEnvelope.domain(:locus)
      assert protocol.service() == MacEnvelope.service(service)
      assert protocol.auth_header() == MacEnvelope.auth_header()
    end

    assert Prima.LocusBackends.label() == MacEnvelope.label(:backends)

    # The worker wire's header, as its vector file and the worker image's
    # harness and control plane spell it.
    assert fixture!("host_api.json")["auth_header"] == MacEnvelope.auth_header()
    assert Prima.WorkerWire.auth_header() == MacEnvelope.auth_header()

    worker_auth_py = read!("tests/worker-image/worker_auth.py")
    control_plane_py = read!("tests/worker-image/control_plane.py")
    assert worker_auth_py =~ ~s(["auth_header"] == "#{MacEnvelope.auth_header()}")
    assert control_plane_py =~ ~s("#{MacEnvelope.auth_header()}")

    # Opus: every canonical string of the worker vector file is under the
    # domain, and the worker key the Go CLI mints reproduces the file's
    # over the worker label.
    vectors = fixture!("worker_auth.json")

    canonicals =
      for {_section, %{"canonical" => canonical}} <- vectors, do: canonical

    assert canonicals != []

    for canonical <- canonicals do
      assert String.starts_with?(canonical, MacEnvelope.domain(:opus) <> "/"), canonical
    end

    assert worker_auth_py =~ ~s(PREFIX = "#{MacEnvelope.domain(:opus)}")

    {:ok, root} = MacEnvelope.decode_root(vectors["root_hex"])

    {:ok, worker_key} =
      MacEnvelope.derive(root, MacEnvelope.label(:worker), [service: :string], %{
        service: vectors["service"]
      })

    assert Base.encode16(worker_key, case: :lower) == vectors["keys"]["worker_hex"]
    assert Prima.WorkerAuth.worker_key(root, vectors["service"]) == {:ok, worker_key}

    for side <- ["apps/codex/cmd/lifecycle.go", "config/test.exs"] do
      assert read!(side) =~ ~s("#{MacEnvelope.label(:worker)}\\n),
             "#{side} derives the worker key over another label"
    end

    # The protocol modules hold no spelling of their own.
    for module <- ~w(builder_protocol locus_backends worker_wire) do
      source = read!("apps/prima/lib/prima/#{module}.ex")

      for literal <- [
            ~s(@domain "),
            ~s(@service "),
            ~s(@label "),
            ~s(@auth_header ")
          ] do
        refute source =~ literal, "#{module}.ex spells #{literal}… itself"
      end
    end
  end

  # ==========================================================================
  # MCP conformance vocabulary — the literals beyond the protocol revision
  # ==========================================================================

  test "the MCP conformance vocabulary is spelled the same in every client" do
    # Check shared metadata keys, request headers and binary sentinels across
    # bundled clients: the Go CLI's literals, the backends wire's vector file
    # (which the image suite's harness speaks from) and the codes the Locus
    # backends service answers with, its numeric literals read without their
    # digit separators.
    protocol = read!("apps/prima/lib/prima/mcp/protocol.ex")
    message = read!("apps/prima/lib/prima/mcp/message.ex")
    fixture = read!("tests/fixtures/locus_backends.json")

    service =
      "apps/locus/lib/locus/backends/service.ex"
      |> read!()
      |> String.replace(~r/(\d)_(\d)/, "\\1\\2")

    client_go = read!("apps/codex/internal/mcp/client.go")
    types_go = read!("apps/codex/internal/mcp/types.go")
    go = client_go <> types_go
    request_metadata = read!("apps/cyfr/lib/emissary/web/plugs/mcp_request_metadata.ex")

    # {literal, [sources that must carry it]} — a source is listed only
    # where it genuinely speaks that part of the vocabulary (the backends
    # service names its `_meta` keys through Prima.MCP.Protocol, so the
    # vector file carries them for it).
    vocabulary = [
      {"io.modelcontextprotocol/protocolVersion", [protocol, fixture, go]},
      {"io.modelcontextprotocol/clientCapabilities", [protocol, fixture, go]},
      {"io.modelcontextprotocol/clientInfo", [protocol, go]},
      {"io.modelcontextprotocol/serverInfo", [protocol, go]},
      # The key a repeated change carries its confirmation's secret under:
      # spelled apart, the server would ignore it and every repeat would
      # open a new record.
      {"cyfr/confirmationId", [request_metadata, go]},
      {"=?base64?", [protocol, go]},
      {"-32020", [message, service]},
      {"-32022", [message, service]},
      # The auth sentinel: the Go CLI keys `errors.Is(err, ErrAuthRequired)`
      # on this number and the backends service answers with it, but all
      # three define it independently and nothing else holds them together.
      {"-33001", [message, service, go]}
    ]

    for {literal, sources} <- vocabulary,
        {source, index} <- Enum.with_index(sources) do
      assert String.contains?(source, literal),
             "conformance literal #{inspect(literal)} missing from source ##{index} " <>
               "(order: as listed in the vocabulary table)"
    end

    # The three request headers, case-insensitively — Go title-cases them.
    for header <- ["mcp-protocol-version", "mcp-method", "mcp-name"] do
      for {name, source} <- [{"protocol.ex", protocol}, {"go", go}] do
        assert String.contains?(String.downcase(source), header),
               "request header #{header} missing from #{name}"
      end
    end

    # The two every signed invoke of the vector file carries.
    for header <- ["mcp-protocol-version", "mcp-method"] do
      assert String.contains?(fixture, header),
             "request header #{header} missing from tests/fixtures/locus_backends.json"
    end
  end
end
