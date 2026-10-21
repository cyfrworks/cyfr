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

  test "the access engine's builds URL grammar is Cyfr.RuntimeConfig's" do
    # Spelled the same on both sides, each anchored its own way; the
    # vectors' builds_urls hold the two to the same verdicts.
    [_, elixir] =
      Regex.run(~r/@builds_url ~r\/\\A(.+)\\z\//, read!("apps/cyfr/lib/cyfr/runtime_config.ex"))

    [_, go] =
      Regex.run(
        ~r/buildsURLGrammar = regexp\.MustCompile\(`\^(.+)\$`\)/,
        read!("apps/codex/internal/access/head.go")
      )

    assert String.replace(elixir, "\\/", "/") == go
  end

  test "the access engine's refusal sentences are Prima.Refusal's, as rendered" do
    # The section and refusals_gen.go are rendered from Prima.Refusal
    # (`mix cyfr.gen.access_refusals`), so a row that changes without the
    # render fails here; Go renders every example back to its sentence.
    alias Mix.Tasks.Cyfr.Gen.AccessRefusals
    {vectors, go} = AccessRefusals.targets()
    json = read!(vectors)

    assert json == AccessRefusals.render_fixture(json),
           "#{vectors}'s refusals section is stale: run `mix cyfr.gen.access_refusals`"

    assert Mix.Tasks.Ops.Gen.Cli.current?({:ok, read!(go)}, AccessRefusals.render_go()),
           "#{go} is stale: run `mix cyfr.gen.access_refusals`"

    for %{"code" => code, "class" => class, "variants" => variants} <-
          fixture!("access_modes.json")["refusals"],
        %{"example" => %{"payload" => payload, "sentence" => sentence}} <- variants do
      reason =
        {String.to_existing_atom(code),
         Map.new(payload, fn
           {"why", why} -> {:why, String.to_existing_atom(why)}
           {key, value} -> {String.to_existing_atom(key), value}
         end)}

      assert %Prima.Refusal{class: refused, message: ^sentence} = Prima.Refusal.classify(reason)
      assert Atom.to_string(refused) == class, code
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

    # The length caps the regex test cannot see: Go's named constants, and
    # Prima's verdict at each one and one past it, so either side's cap
    # moving alone fails here.
    cap = fn const ->
      [_, n] = Regex.run(~r/\b#{const}\s*=\s*(\d+)/, go)
      String.to_integer(n)
    end

    slug = &String.duplicate("a", &1)

    # A dotted publisher namespace of exactly `len` bytes, in labels of at
    # most 63.
    host = fn len ->
      len
      |> Stream.unfold(fn
        0 -> nil
        rest when rest <= 63 -> {slug.(rest), 0}
        rest -> {slug.(min(63, rest - 2)), rest - min(63, rest - 2) - 1}
      end)
      |> Enum.join(".")
    end

    personal = cap.("personalSlugMaxLen")
    assert Prima.ComponentRef.valid_personal_slug?(slug.(personal))
    refute Prima.ComponentRef.valid_personal_slug?(slug.(personal + 1))

    publisher = cap.("publisherSlugMaxLen")
    assert :ok = Prima.ComponentRef.validate("c:#{host.(publisher)}.widget:1.0.0")
    assert {:error, _} = Prima.ComponentRef.validate("c:#{host.(publisher + 1)}.widget:1.0.0")

    name = cap.("nameMaxLen")
    assert :ok = Prima.ComponentRef.validate("c:alice.#{slug.(name)}:1.0.0")
    assert {:error, _} = Prima.ComponentRef.validate("c:alice.#{slug.(name + 1)}:1.0.0")

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
    execution_mcp = read!("apps/cyfr/lib/opus/provider.ex")
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

    # Opus.Provider spells the roster once, as the guard on format_root_result/1.
    [guard] =
      Regex.run(
        ~r/defp format_root_result\(\{:error, \{tag, payload\}\}\)\s+when tag in \[([^\]]*)\]/,
        execution_mcp,
        capture: :all_but_first
      )

    guard_tags =
      guard |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> trim_colon()))

    assert Enum.sort(guard_tags) == Enum.sort(tags),
           "opus/provider.ex guard roster must be the five consent signal tags"

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
  # The readers of the shared vector files
  # ==========================================================================

  # One vector file consumed by a test on every side: every vector file
  # under tests/fixtures, each with every file that reads it, on any side
  # (a suite, a test support module, an image harness, a proof), and every
  # section that reader holds its side to. The values are each reader's own
  # assertions; this roster fails when a vector file has no row, a row
  # names a file that is gone, or a reader stops reading its file or a
  # section of it. A section is a top-level key, read as the reader's
  # language spells a read of it (`sections_read/3`); `a.b` is the nested
  # path `.a.b` a JavaScript reader names.
  @vector_readers %{
    "account_names.json" => [
      {"apps/codex/cmd/profile_test.go", ~w(unicode keys same different)},
      {"apps/prima/test/prima/authority/blob_test.exs", ~w(unicode keys same different)}
    ],
    "canvas_shape.json" => [
      {"apps/cyfr/assets/test/toolkit/tree.test.mjs", ~w(times)},
      {"apps/prima/test/prima/canvas/shape_test.exs",
       ~w(types max_depth reasons shapes canonical spellings times values results)},
      {"apps/prima/test/prima/manifest/results_test.exs", ~w(values results)}
    ],
    "canvas_wire.json" => [
      {"apps/cyfr/assets/test/toolkit/support.mjs", ~w()},
      {"apps/cyfr/assets/test/toolkit/wire.test.mjs",
       ~w(version to_prism_verbs to_toolkit_verbs messages paths)},
      {"apps/prima/test/prima/canvas_wire_test.exs",
       ~w(version to_prism_verbs to_toolkit_verbs messages paths)}
    ],
    "carry.json" => [
      {"apps/cyfr/assets/test/carrier/carry.test.mjs",
       ~w(fragments.parse fragments.valid max_fragment_bytes payload returns)},
      {"apps/prima/test/prima/carry_test.exs",
       ~w(envelopes fragments identity keys max_fragment_bytes max_payload_bytes operations outcomes payload payload_digest protocol replay returns verify)}
    ],
    "component_refs.json" => [
      {"apps/codex/internal/ref/ref_fixture_test.go", ~w(cases version_ordering)},
      {"apps/cyfr/assets/test/sdk/wire.test.mjs", ~w(tincture_urls)},
      {"apps/prima/test/prima/tincture_wire_test.exs", ~w(tincture_urls)}
    ],
    "confirmation.json" => [
      {"apps/codex/cmd/consent_error_test.go", ~w(ref signal)},
      {"apps/codex/internal/confirmation/confirmation_test.go", ~w(protocol ref)},
      {"apps/cyfr/test/cyfr_web/controllers/api_error_test.exs", ~w(signal)},
      {"apps/prima/test/prima/confirmation_test.exs",
       ~w(digest protocol record ref refusals variations)},
      {"apps/prima/test/prima/consent_signal_test.exs", ~w(record ref signal)},
      {"apps/prima/test/prima/mcp/message_test.exs", ~w(signal)}
    ],
    "consent_preview.json" => [
      {"apps/codex/cmd/profile_test.go", ~w(kinds preview)},
      {"apps/cyfr/test/cyfr/consent_preview_render_test.exs", ~w(origins preview)},
      {"apps/prima/test/prima/consent_preview_test.exs",
       ~w(kinds narrowable_kinds origins preview refusals version)},
      {"apps/prima/test/prima/origin_test.exs", ~w(origins)}
    ],
    "device.json" => [
      {"apps/cyfr/assets/test/system_layer/device_key.test.mjs",
       ~w(continuous_fields key_digest messages protocol refusals types)},
      {"apps/cyfr/test/emissary/web/device_channel_test.exs", ~w(messages refusals)},
      {"apps/prima/test/prima/device_test.exs",
       ~w(continuous_fields key_digest messages protocol refusals types)}
    ],
    "device_cert.json" => [
      {"apps/cyfr/assets/test/system_layer/device_key.test.mjs",
       ~w(certificates challenge_refusals challenges keys proof_cases proof_protocol proofs purposes refusals verify)},
      {"apps/prima/test/prima/device_cert_test.exs",
       ~w(certificate_protocol certificates challenge_refusals challenges homes issued_at keys lifetime_ms proof_cases proof_protocol proofs purposes refusals reserved_client_ids verify)}
    ],
    "feed.json" => [
      {"apps/cyfr/assets/test/toolkit/support.mjs", ~w(results envelopes)},
      {"apps/cyfr/test/opus/feeds_test.exs", ~w(bindings outputs)},
      {"apps/prima/test/prima/canvas/shape_test.exs", ~w(reasons bindings results)},
      {"apps/prima/test/prima/feed_test.exs",
       ~w(intervals args_max_bytes result_max_bytes reasons bindings binding_ids inputs crons results envelopes bounds)}
    ],
    "guest_error.json" => [
      {"apps/cyfr/test/cyfr/docs_drift_test.exs", ~w(envelope fallback)},
      {"apps/locus/test/locus/runtime/formula_handler_vectors_test.exs",
       ~w(encode_error setup_required)},
      {"apps/prima/test/prima/wit_response_vectors_test.exs", ~w(envelope fallback)}
    ],
    "host_api.json" => [
      {"apps/cyfr/test/opus/host/attached_fetch_test.exs", ~w(version calls)},
      {"apps/cyfr/test/opus/host_egress_test.exs", ~w(egress_pin_cases egress_policy_cases)},
      {"apps/cyfr/test/opus/host_listener_test.exs", ~w(calls pre_body_refusals body_refusals)},
      {"apps/cyfr/test/opus/host_test.exs", ~w(version calls report connection_cases)},
      {"apps/locus/test/locus/runtime/formula_handler_runner_test.exs", ~w(connection_cases)},
      {"apps/locus/test/locus/runtime/host_client_test.exs",
       ~w(connection_cases egress_pin_cases egress_policy_cases)},
      {"apps/prima/test/prima/host_api_test.exs",
       ~w(routes retries timeouts_ms max_body_bytes max_answer_bytes window_ms standing keys calls pre_body_refusals report retry_identity connection_cases egress_pin_cases egress_policy_cases egress_pin_internal_purposes frame_cases)},
      {"apps/prima/test/prima/network_test.exs",
       ~w(framing_headers override_headers override_prefixes credential_headers)},
      {"apps/prima/test/prima/runner_relay_test.exs", ~w(version max_body_bytes keys calls)},
      {"apps/prima/test/prima/worker_auth_test.exs", ~w(keys report)},
      {"apps/prima/test/prima/worker_wire_test.exs",
       ~w(version auth_header routes calls body_refusals report egress_pin_cases egress_pin_internal_purposes)},
      {"tests/locus-runtime-image/control_plane.py", ~w()},
      {"tests/locus-runtime-image/runners.py", ~w(report)},
      {"tests/locus-runtime-image/worker_auth.py",
       ~w(version auth_header routes retries timeouts_ms window_ms standing keys calls pre_body_refusals body_refusals report retry_identity connection_cases egress_pin_cases egress_policy_cases egress_pin_internal_purposes frame_cases framing_headers override_headers override_prefixes credential_headers)}
    ],
    "identity.json" => [
      {"apps/codex/cmd/member_test.go", ~w(identifiers)},
      {"apps/prima/test/prima/identity_test.exs",
       ~w(chains directory entries identifiers keys kinds kits locate max_entry_bytes prefix protocol requests)}
    ],
    "keeper_protocol.json" => [
      {"apps/cyfr/test/emissary/external/backend_definition_test.exs", ~w(reserved_env_prefixes)},
      {"apps/locus/keeper/internal/protocol/protocol_test.go",
       ~w(reserved_env_prefixes reserved_env signals bounds request_bounds rlimits frames control_frames relay_frames valid_requests invalid_requests replies)},
      {"apps/locus/keeper/internal/relay/relay_test.go", ~w(relay_streams)},
      {"apps/locus/test/locus/config_test.exs", ~w(valid_requests invalid_requests)},
      {"apps/locus/test/locus/keeper_test.exs", ~w(valid_requests)},
      {"apps/locus/test/locus/keeper_vectors_test.exs",
       ~w(control_frames relay_frames valid_requests replies)},
      {"apps/locus/test/locus/runtime/keeper_channel_test.exs",
       ~w(control_frames valid_requests replies)},
      {"apps/locus/test/locus/runtime/keeper_memory_test.exs", ~w(valid_requests replies)},
      {"apps/prima/test/prima/keeper_protocol_test.exs",
       ~w(reserved_env_prefixes reserved_env signals bounds request_bounds rlimits frames control_frames relay_frames relay_streams valid_requests invalid_requests replies)}
    ],
    "layout.json" => [
      {"apps/prima/test/prima/layout_test.exs", ~w(valid canonical digest invalid)}
    ],
    "locus_backends.json" => [
      {"apps/cyfr/test/emissary/external/backend_definition_test.exs",
       ~w(reserved_env_prefixes literal_env_names)},
      {"apps/cyfr/test/emissary/external/backends_test.exs",
       ~w(version bounds owner sync status)},
      {"apps/locus/test/locus/backends/auth_test.exs",
       ~w(auth_header routes key_hex builds_key_hex sync status invoke auth_rejected)},
      {"apps/locus/test/locus/backends/service_test.exs",
       ~w(version routes key_hex owner hello sync release status invoke invalid_messages fence_rejected refusals)},
      {"apps/locus/test/locus/listener_test.exs", ~w(version service key_hex owner hello sync)},
      {"apps/prima/test/prima/locus_backends_test.exs",
       ~w(version domain service label auth_header boot_header window_ms routes statuses bounds reserved_env_prefixes literal_env_names key_hex control_key_hex seal_key_hex owner owner_key_hex builds_key_hex key_text hello sync release status invoke seal header_parse valid_fields invalid_fields invalid_messages auth_rejected fence_rejected refusals masking)},
      {"tests/locus-backends-image/harness.py",
       ~w(version service label auth_header boot_header window_ms routes statuses bounds key_hex control_key_hex seal_key_hex owner owner_key_hex release status invoke seal refusals)}
    ],
    "locus_builds.json" => [
      {"apps/cyfr/test/support/scripted_builder.ex", ~w(key_hex request_key_hex lines)},
      {"apps/locus/test/locus/backends/auth_test.exs",
       ~w(auth_header routes key_hex backends_key_hex request auth_rejected)},
      {"apps/locus/test/locus/builds_vectors_test.exs",
       ~w(auth_header routes statuses bounds key_hex request_key_hex request health_request lines invalid_requests auth_rejected)},
      {"apps/prima/test/prima/builder_protocol_test.exs",
       ~w(version domain service label auth_header window_ms routes statuses bounds languages language_for stages component_wasm component_lockfile key_hex request_key_hex backends_key_hex backends_request_key_hex key_text request health_request lines invalid_requests invalid_lines auth_rejected)},
      {"tests/builder-image/stack.py",
       ~w(version service label auth_header routes statuses key_hex request_key_hex request)}
    ],
    "locus_roles.json" => [
      {"apps/prima/test/prima/locus_roles_test.exs", ~w(release roles)},
      {"tests/builder-image/stack.py", ~w(release roles)},
      {"tests/compose-proof/run.sh", ~w(release)},
      {"tests/locus-backends-image/harness.py", ~w(release roles)},
      {"tests/locus-runtime-image/stack.py", ~w(release roles)}
    ],
    "mcp_wire.json" => [
      {"apps/codex/internal/mcp/wire_vectors_test.go",
       ~w(protocol_version supported meta header_values named_subject error_codes consent_tags consent_errors)},
      {"apps/prima/test/prima/mcp/wire_vectors_test.exs",
       ~w(protocol_version supported meta error_codes consent_tags)}
    ],
    "person_assertion.json" => [
      {"apps/prima/test/prima/person_assertion_test.exs",
       ~w(assertions identity keys protocol refusals transport verify)}
    ],
    "access_modes.json" => [
      {"apps/codex/internal/access/head_test.go", ~w(derive boot profiles names words)},
      {"apps/codex/internal/access/refusals_test.go", ~w(refusals)},
      {"apps/cyfr/test/cyfr/cross_language_drift_test.exs", ~w(refusals)},
      {"apps/cyfr/test/cyfr/runtime_config_test.exs", ~w(derive boot profiles names words)},
      {"tests/compose-proof/run.sh", ~w(refusals boot)},
      {"tests/release-boot/boot.sh", ~w(boot)}
    ],
    "release_manifest.json" => [
      {"apps/codex/cmd/lifecycle_test.go", ~w(valid signature)},
      {"apps/codex/internal/release/manifest_test.go",
       ~w(valid valid_prerelease refused versions signature)},
      {"apps/codex/internal/scaffold/scaffold_test.go", ~w(signature)},
      {"tests/ci-release-graph.py", ~w(valid valid_prerelease refused versions signature)}
    ],
    "restore_barrier.json" => [
      {"apps/codex/cmd/restore_test.go", ~w(barred_exit declare_expr declared_prefix name)},
      {"apps/cyfr/test/cyfr/platform_settings_roster_test.exs", ~w(name)},
      {"tests/compose-proof/run.sh", ~w()}
    ],
    "restore_kit.json" => [
      {"apps/cyfr/assets/test/system_layer/recovery.test.mjs",
       ~w(challenge_bytes kit other_kit protocol refused valid)},
      {"apps/cyfr/test/sanctum/restore_kit_proof_test.exs", ~w(kit refused valid)},
      {"apps/prima/test/prima/identity_restore_kit_test.exs",
       ~w(challenge_bytes kit other_kit protocol refused valid)}
    ],
    "runner_control.json" => [
      {"apps/locus/test/locus/runtime/runner_control_vectors_test.exs",
       ~w(max_line_bytes valid invalid)},
      {"apps/prima/test/prima/runner_control_test.exs",
       ~w(version max_line_bytes max_input_bytes max_open valid invalid)}
    ],
    "runner_relay.json" => [
      {"apps/locus/test/locus/runtime/relay_vectors_test.exs",
       ~w(attempt initial_credit exchange refusals)},
      {"apps/prima/test/prima/runner_relay_test.exs",
       ~w(version attempt max_body_bytes max_frame_bytes initial_credit exchange refusals)}
    ],
    "tincture_wire.json" => [
      {"apps/cyfr/assets/test/sdk/support.mjs", ~w()},
      {"apps/prima/test/prima/tincture_wire_test.exs",
       ~w(version bearer_header routes requests public_request answers refusal stream shell)}
    ],
    "worker_api.json" => [
      {"apps/cyfr/test/opus/worker_client_test.exs", ~w(requests status)},
      {"apps/locus/test/locus/runtime/worker_listener_test.exs", ~w(requests status)},
      {"apps/prima/test/prima/worker_api_test.exs",
       ~w(version routes retries timeouts_ms requests status)},
      {"apps/prima/test/prima/worker_auth_test.exs", ~w(status)},
      {"apps/prima/test/prima/worker_protocol_test.exs", ~w(retries timeouts_ms status)},
      {"apps/prima/test/prima/worker_wire_test.exs", ~w(version routes requests)},
      {"tests/locus-runtime-image/runners.py", ~w(status)},
      {"tests/locus-runtime-image/worker_auth.py",
       ~w(version routes retries timeouts_ms requests status)}
    ],
    "worker_auth.json" => [
      {"apps/codex/cmd/lifecycle_test.go", ~w(keys root_hex root_text service)},
      {"apps/cyfr/test/cyfr/locus_runtime_key_task_test.exs",
       ~w(keys root_hex root_text service)},
      {"apps/locus/test/locus/runtime/relay_vectors_test.exs",
       ~w(assignment attempt call host_url keys)},
      {"apps/prima/test/prima/runner_control_test.exs",
       ~w(attempt call keys root_hex sealed_attempt_keys service)},
      {"apps/prima/test/prima/runner_relay_test.exs", ~w(attempt call keys service)},
      {"apps/prima/test/prima/worker_api_test.exs", ~w(keys root_hex service)},
      {"apps/prima/test/prima/worker_auth_test.exs",
       ~w(assignment attempt boot call host_url keys member report request root_hex root_text sealed_attempt_keys sealed_call sealed_frames service)},
      {"tests/locus-runtime-image/runners.py", ~w(attempt boot report service)},
      {"tests/locus-runtime-image/worker_auth.py",
       ~w(assignment attempt boot call host_url keys member report root_hex root_text sealed_attempt_keys sealed_call sealed_frames service)}
    ]
  }

  # The files under tests/fixtures that are no vector file.
  @not_vectors %{
    "residue-canary.go" =>
      "the residue probe the image suites build and run inside the image " <>
        "(tests/locus-backends-image/residue.py, tests/builder-image/stack.py): a program, " <>
        "not data two sides read"
  }

  # The spellings of a read of `section` in a reader of `path`'s language.
  defp section_reads(path, section) do
    key = Regex.escape(section)

    case Path.extname(path) do
      ".go" -> [~r/json:"#{key}"/]
      ext when ext in [".py", ".sh"] -> [~r/\["#{key}"\]/, ~r/\.get\("#{key}"/]
      ".mjs" -> [~r/\.#{key}\b/, ~r/\["#{key}"\]/]
      _elixir -> [~r/\["#{key}"\]/, ~r/"#{key}" =>/, ~r/"#{key}"\)/]
    end
  end

  # Every row of `readers` whose file does not read its vector file or a
  # section it names, as `file what`.
  defp unread(readers) do
    for {vectors, files} <- readers,
        {file, sections} <- files,
        missing <- unread(file, vectors, sections),
        do: "#{file} #{missing}"
  end

  defp unread(file, vectors, sections) do
    if File.exists?(Path.join(@root, file)) do
      source = read!(file)

      if(String.contains?(source, vectors), do: [], else: ["does not read #{vectors}"]) ++
        for section <- sections,
            not Enum.any?(section_reads(file, section), &Regex.match?(&1, source)),
            do: "does not read #{vectors}'s #{section}"
    else
      ["is gone"]
    end
  end

  test "every file under tests/fixtures is a vector file with its readers, or says what it is" do
    files = File.ls!(Path.join(@root, "tests/fixtures")) |> Enum.sort()
    named = Enum.sort(Map.keys(@vector_readers) ++ Map.keys(@not_vectors))

    assert files -- named == [], "no row for: #{inspect(files -- named)}"
    assert named -- files == [], "rows for files that are gone: #{inspect(named -- files)}"

    for {vectors, readers} <- @vector_readers do
      assert String.ends_with?(vectors, ".json"), "#{vectors} is not a vector file"
      assert readers != [], "#{vectors} names no reader"
    end
  end

  test "each side's test reads the shared vectors it is held to" do
    assert unread(@vector_readers) == []

    # Planted: a reader of another file, a section it does not read, and a
    # file that is gone are each reported.
    planted = %{
      "carry.json" => [
        {"apps/prima/test/prima/layout_test.exs", ~w(fragments)},
        {"apps/prima/test/prima/carry_test.exs", ~w(no_such_section)},
        {"apps/prima/test/prima/planted_test.exs", ~w(fragments)}
      ]
    }

    assert unread(planted) == [
             "apps/prima/test/prima/layout_test.exs does not read carry.json",
             "apps/prima/test/prima/layout_test.exs does not read carry.json's fragments",
             "apps/prima/test/prima/carry_test.exs does not read carry.json's no_such_section",
             "apps/prima/test/prima/planted_test.exs is gone"
           ]
  end

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
      assert wire["domain"] == MacEnvelope.domain(), file
      assert wire["service"] == MacEnvelope.service(service), file
      assert wire["label"] == MacEnvelope.label(service), file
      assert wire["auth_header"] == MacEnvelope.auth_header(), file
      assert protocol.domain() == MacEnvelope.domain()
      assert protocol.service() == MacEnvelope.service(service)
      assert protocol.auth_header() == MacEnvelope.auth_header()
    end

    assert Prima.LocusBackends.label() == MacEnvelope.label(:backends)

    # The worker wire's header, as its vector file and the worker image's
    # harness and control plane spell it.
    assert fixture!("host_api.json")["auth_header"] == MacEnvelope.auth_header()
    assert Prima.WorkerWire.auth_header() == MacEnvelope.auth_header()

    worker_auth_py = read!("tests/locus-runtime-image/worker_auth.py")
    control_plane_py = read!("tests/locus-runtime-image/control_plane.py")
    assert worker_auth_py =~ ~s(["auth_header"] == "#{MacEnvelope.auth_header()}")
    assert control_plane_py =~ ~s("#{MacEnvelope.auth_header()}")

    # The runtime: every canonical string of the worker vector file is under
    # its label, and the worker key the Go CLI mints reproduces the file's
    # over that label.
    vectors = fixture!("worker_auth.json")

    canonicals =
      for {_section, %{"canonical" => canonical}} <- vectors, do: canonical

    assert canonicals != []

    for canonical <- canonicals do
      assert String.starts_with?(canonical, MacEnvelope.label(:runtime) <> "/"), canonical
    end

    assert worker_auth_py =~ ~s(PREFIX = "#{MacEnvelope.label(:runtime)}")

    {:ok, root} = MacEnvelope.decode_root(vectors["root_hex"])

    {:ok, worker_key} =
      MacEnvelope.derive(root, MacEnvelope.label(:runtime), [service: :string], %{
        service: vectors["service"]
      })

    assert Base.encode16(worker_key, case: :lower) == vectors["keys"]["worker_hex"]
    assert Prima.WorkerAuth.worker_key(root, vectors["service"]) == {:ok, worker_key}

    for side <- ["apps/codex/cmd/lifecycle.go", "config/test.exs"] do
      assert read!(side) =~ ~s("#{MacEnvelope.label(:runtime)}\\n),
             "#{side} derives the runtime's worker key over another label"
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
