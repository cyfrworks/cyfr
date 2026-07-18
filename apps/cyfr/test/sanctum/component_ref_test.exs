# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ComponentRefTest do
  use ExUnit.Case, async: true

  alias Sanctum.ComponentRef

  # ============================================================================
  # parse/1 — requires type prefix
  # ============================================================================

  describe "parse/1 rejects untyped refs" do
    test "rejects bare name" do
      assert {:error, msg} = ComponentRef.parse("my-tool")
      assert msg =~ "type prefix"
    end

    test "rejects namespace.name:version without type" do
      assert {:error, msg} = ComponentRef.parse("local.my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects legacy name:version format" do
      assert {:error, msg} = ComponentRef.parse("my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects legacy colon-separated local:name:version" do
      assert {:error, msg} = ComponentRef.parse("local:my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects namespace.name without type" do
      assert {:error, msg} = ComponentRef.parse("cyfr.stripe")
      assert msg =~ "type prefix"
    end

    test "returns error for empty string" do
      assert {:error, "component ref cannot be empty"} = ComponentRef.parse("")
    end

    test "returns error for whitespace-only" do
      assert {:error, "component ref cannot be empty"} = ComponentRef.parse("   ")
    end

    test "returns error for non-string input" do
      assert {:error, "component ref must be a string"} = ComponentRef.parse(123)
    end
  end

  # ============================================================================
  # parse/1 — typed refs
  # ============================================================================

  describe "parse/1 typed" do
    test "parses typed canonical: catalyst:namespace.name:version" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "claude",
                version: "0.1.0"
              }} =
               ComponentRef.parse("catalyst:local.claude:0.1.0")
    end

    test "parses typed canonical: reagent:namespace.name:version" do
      assert {:ok,
              %ComponentRef{
                type: "reagent",
                namespace: "cyfr",
                name: "sentiment",
                version: "1.0.0"
              }} =
               ComponentRef.parse("reagent:cyfr.sentiment:1.0.0")
    end

    test "parses typed canonical: formula:namespace.name:version" do
      assert {:ok,
              %ComponentRef{
                type: "formula",
                namespace: "local",
                name: "list-models",
                version: "0.1.0"
              }} =
               ComponentRef.parse("formula:local.list-models:0.1.0")
    end

    test "parses shorthand c: as catalyst" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "claude",
                version: "0.1.0"
              }} =
               ComponentRef.parse("c:local.claude:0.1.0")
    end

    test "parses shorthand r: as reagent" do
      assert {:ok,
              %ComponentRef{type: "reagent", namespace: "local", name: "parser", version: "1.0.0"}} =
               ComponentRef.parse("r:local.parser:1.0.0")
    end

    test "parses shorthand f: as formula" do
      assert {:ok,
              %ComponentRef{
                type: "formula",
                namespace: "local",
                name: "list-models",
                version: "0.1.0"
              }} =
               ComponentRef.parse("f:local.list-models:0.1.0")
    end

    test "parses typed versionless ref" do
      assert {:ok,
              %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: nil}} =
               ComponentRef.parse("c:local.claude")
    end

    test "parses semver with prerelease" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "my-tool",
                version: "1.0.0-beta.1"
              }} =
               ComponentRef.parse("c:local.my-tool:1.0.0-beta.1")
    end

    test "parses semver with build metadata" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "my-tool",
                version: "1.0.0+build.123"
              }} =
               ComponentRef.parse("c:local.my-tool:1.0.0+build.123")
    end

    test "trims whitespace on typed ref" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "claude",
                version: "0.1.0"
              }} =
               ComponentRef.parse("  c:local.claude:0.1.0  ")
    end
  end

  # ============================================================================
  # to_string/1
  # ============================================================================

  describe "to_string/1" do
    test "formats typed canonical string" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}
      assert "catalyst:local.claude:0.1.0" = ComponentRef.to_string(ref)
    end

    test "String.Chars protocol works typed" do
      ref = %ComponentRef{type: "reagent", namespace: "cyfr", name: "sentiment", version: "1.0.0"}
      assert "reagent:cyfr.sentiment:1.0.0" = "#{ref}"
    end

    test "typed ref with nil version omits version" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: nil}
      assert "catalyst:local.claude" = ComponentRef.to_string(ref)
    end

    test "String.Chars protocol with nil version" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: nil}
      assert "catalyst:local.claude" = "#{ref}"
    end
  end

  # ============================================================================
  # normalize/1
  # ============================================================================

  describe "normalize/1" do
    test "rejects untyped refs" do
      assert {:error, msg} = ComponentRef.normalize("local.my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects bare name without type" do
      assert {:error, msg} = ComponentRef.normalize("my-tool")
      assert msg =~ "type prefix"
    end

    test "normalizes typed ref preserving type" do
      assert {:ok, "catalyst:local.claude:0.1.0"} = ComponentRef.normalize("c:local.claude:0.1.0")
    end

    test "normalizes full type name" do
      assert {:ok, "catalyst:local.claude:0.1.0"} =
               ComponentRef.normalize("catalyst:local.claude:0.1.0")
    end

    test "rejects formula shorthand without version" do
      assert {:error, msg} = ComponentRef.normalize("f:local.list-models")
      assert msg =~ "version must be explicit"
    end

    test "normalizes typed ref with explicit version" do
      assert {:ok, "catalyst:local.my-tool:0.1.0"} =
               ComponentRef.normalize("c:local.my-tool:0.1.0")
    end

    test "rejects typed ref with latest version (normalized to nil)" do
      assert {:error, msg} = ComponentRef.normalize("c:local.my-tool:latest")
      assert msg =~ "version must be explicit"
    end

    test "returns error for empty" do
      assert {:error, _} = ComponentRef.normalize("")
    end
  end

  # ============================================================================
  # from_path/1
  # ============================================================================

  describe "from_path/1" do
    test "extracts ref with type from catalyst path" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "claude",
                version: "0.1.0"
              }} =
               ComponentRef.from_path("components/catalysts/local/claude/0.1.0/catalyst.wasm")
    end

    test "extracts ref with type from reagent path" do
      assert {:ok,
              %ComponentRef{type: "reagent", namespace: "local", name: "parser", version: "1.0.0"}} =
               ComponentRef.from_path("components/reagents/local/parser/1.0.0/reagent.wasm")
    end

    test "extracts ref with type from formula path" do
      assert {:ok,
              %ComponentRef{
                type: "formula",
                namespace: "cyfr",
                name: "pipeline",
                version: "2.0.0"
              }} =
               ComponentRef.from_path("components/formulas/cyfr/pipeline/2.0.0/formula.wasm")
    end

    test "extracts ref from absolute path" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "my-tool",
                version: "0.1.0"
              }} =
               ComponentRef.from_path(
                 "/home/user/project/components/catalysts/local/my-tool/0.1.0/catalyst.wasm"
               )
    end

    test "returns error for non-canonical path" do
      assert {:error, msg} = ComponentRef.from_path("/tmp/random/file.wasm")
      assert msg =~ "Cannot derive component ref"
    end
  end

  # ============================================================================
  # validate/1
  # ============================================================================

  describe "validate/1" do
    test "rejects untyped refs" do
      assert {:error, msg} = ComponentRef.validate("local.my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "valid typed ref" do
      assert :ok = ComponentRef.validate("catalyst:local.my-tool:1.0.0")
    end

    test "valid typed shorthand ref" do
      assert :ok = ComponentRef.validate("c:local.my-tool:1.0.0")
    end

    test "rejects bare name" do
      assert {:error, _} = ComponentRef.validate("my-tool")
    end

    test "rejects empty" do
      assert {:error, _} = ComponentRef.validate("")
    end

    test "rejects invalid name starting with hyphen" do
      assert {:error, _} = ComponentRef.validate("c:local.-invalid:1.0.0")
    end

    test "rejects name that is too long" do
      long_name = String.duplicate("a", 65)
      assert {:error, msg} = ComponentRef.validate("c:local.#{long_name}:1.0.0")
      assert msg =~ "name must be at most 64 characters"
    end

    test "rejects invalid version" do
      assert {:error, msg} = ComponentRef.validate("c:local.my-tool:not-semver")
      assert msg =~ "version must be valid semver"
    end

    test "rejects version-less ref (latest normalized to nil)" do
      assert {:error, msg} = ComponentRef.validate("c:local.my-tool:latest")
      assert msg =~ "version is required"
    end

    test "rejects non-string input" do
      assert {:error, _} = ComponentRef.validate(nil)
    end

    test "rejects invalid type" do
      assert {:error, msg} = ComponentRef.validate_type("invalid")
      assert msg =~ "invalid component type"
    end
  end

  # ============================================================================
  # validate_type/1
  # ============================================================================

  describe "validate_type/1" do
    test "rejects nil" do
      assert {:error, msg} = ComponentRef.validate_type(nil)
      assert msg =~ "component type is required"
    end

    test "accepts catalyst" do
      assert :ok = ComponentRef.validate_type("catalyst")
    end

    test "accepts reagent" do
      assert :ok = ComponentRef.validate_type("reagent")
    end

    test "accepts formula" do
      assert :ok = ComponentRef.validate_type("formula")
    end

    test "rejects unknown type" do
      assert {:error, _} = ComponentRef.validate_type("widget")
    end
  end

  # ============================================================================
  # type_prefix?/1 and expand_type_shorthand/1
  # ============================================================================

  describe "type helpers" do
    test "type_prefix? recognizes full names" do
      assert ComponentRef.type_prefix?("catalyst")
      assert ComponentRef.type_prefix?("reagent")
      assert ComponentRef.type_prefix?("formula")
    end

    test "type_prefix? recognizes shorthands" do
      assert ComponentRef.type_prefix?("c")
      assert ComponentRef.type_prefix?("r")
      assert ComponentRef.type_prefix?("f")
    end

    test "type_prefix? rejects non-types" do
      refute ComponentRef.type_prefix?("local")
      refute ComponentRef.type_prefix?("my-tool")
    end

    test "expand_type_shorthand expands shorthands" do
      assert "catalyst" = ComponentRef.expand_type_shorthand("c")
      assert "reagent" = ComponentRef.expand_type_shorthand("r")
      assert "formula" = ComponentRef.expand_type_shorthand("f")
    end

    test "expand_type_shorthand passes through full names" do
      assert "catalyst" = ComponentRef.expand_type_shorthand("catalyst")
      assert "reagent" = ComponentRef.expand_type_shorthand("reagent")
    end
  end

  # ============================================================================
  # validate_name/1
  # ============================================================================

  describe "validate_name/1" do
    test "accepts valid names" do
      assert :ok = ComponentRef.validate_name("my-tool")
      assert :ok = ComponentRef.validate_name("ab")
      assert :ok = ComponentRef.validate_name("a1")
    end

    test "accepts single alphanumeric char" do
      assert :ok = ComponentRef.validate_name("a")
      assert :ok = ComponentRef.validate_name("1")
    end

    test "rejects uppercase" do
      assert {:error, _} = ComponentRef.validate_name("MY_CAPS")
    end

    test "rejects name starting with hyphen" do
      assert {:error, _} = ComponentRef.validate_name("-invalid")
    end

    test "rejects name ending with hyphen" do
      assert {:error, _} = ComponentRef.validate_name("invalid-")
    end

    test "rejects name over 64 chars" do
      assert {:error, _} = ComponentRef.validate_name(String.duplicate("a", 65))
    end
  end

  # ============================================================================
  # validate_version/1
  # ============================================================================

  describe "validate_version/1" do
    test "accepts valid semver" do
      assert :ok = ComponentRef.validate_version("1.0.0")
      assert :ok = ComponentRef.validate_version("0.1.0")
      assert :ok = ComponentRef.validate_version("1.0.0-beta.1")
      assert :ok = ComponentRef.validate_version("1.0.0+build.123")
    end

    test "rejects nil" do
      assert {:error, _} = ComponentRef.validate_version(nil)
    end

    test "rejects non-semver" do
      assert {:error, _} = ComponentRef.validate_version("not-a-version")
      assert {:error, _} = ComponentRef.validate_version("1.0")
    end
  end

  # ============================================================================
  # validate_namespace/1
  # ============================================================================

  describe "validate_namespace/1" do
    test "accepts valid namespaces" do
      assert :ok = ComponentRef.validate_namespace("local")
      assert :ok = ComponentRef.validate_namespace("cyfr")
      assert :ok = ComponentRef.validate_namespace("my-org")
    end

    test "accepts single alphanumeric char" do
      assert :ok = ComponentRef.validate_namespace("a")
    end

    test "rejects uppercase" do
      assert {:error, _} = ComponentRef.validate_namespace("UPPER")
    end

    test "rejects namespace over 64 chars" do
      assert {:error, _} = ComponentRef.validate_namespace(String.duplicate("a", 65))
    end

    test "rejects namespace starting with hyphen" do
      assert {:error, _} = ComponentRef.validate_namespace("-bad")
    end
  end

  # ============================================================================
  # validate_publisher/1
  # ============================================================================

  describe "validate_publisher/1" do
    test "delegates to validate_namespace" do
      assert :ok = ComponentRef.validate_publisher("local")
      assert {:error, _} = ComponentRef.validate_publisher("UPPER")
    end
  end

  # ============================================================================
  # Round-trip
  # ============================================================================

  describe "round-trip" do
    test "typed ref round-trip" do
      original = "catalyst:local.claude:0.1.0"
      {:ok, parsed} = ComponentRef.parse(original)
      canonical = ComponentRef.to_string(parsed)
      assert canonical == original
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end

    test "typed shorthand normalizes through round-trip" do
      {:ok, parsed} = ComponentRef.parse("c:local.claude:0.1.0")
      canonical = ComponentRef.to_string(parsed)
      assert canonical == "catalyst:local.claude:0.1.0"
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end

    test "from_path round-trip includes type" do
      {:ok, parsed} =
        ComponentRef.from_path("components/catalysts/local/claude/0.1.0/catalyst.wasm")

      canonical = ComponentRef.to_string(parsed)
      assert canonical == "catalyst:local.claude:0.1.0"
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end

    test "version-less round-trip" do
      {:ok, parsed} = ComponentRef.parse("catalyst:local.claude")
      assert parsed.version == nil
      canonical = ComponentRef.to_string(parsed)
      assert canonical == "catalyst:local.claude"
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end
  end

  # ============================================================================
  # normalize_flexible/1
  # ============================================================================

  describe "normalize_flexible/1" do
    test "allows typed ref with version" do
      assert {:ok,
              %ComponentRef{
                type: "catalyst",
                namespace: "local",
                name: "claude",
                version: "0.1.0"
              }} =
               ComponentRef.normalize_flexible("c:local.claude:0.1.0")
    end

    test "allows typed ref without version (nil)" do
      assert {:ok,
              %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: nil}} =
               ComponentRef.normalize_flexible("c:local.claude")
    end

    test "expands type shorthand" do
      assert {:ok, %ComponentRef{type: "reagent"}} =
               ComponentRef.normalize_flexible("r:local.sentiment")

      assert {:ok, %ComponentRef{type: "formula"}} =
               ComponentRef.normalize_flexible("f:local.pipeline")
    end

    test "rejects untyped refs" do
      assert {:error, msg} = ComponentRef.normalize_flexible("local.claude:0.1.0")
      assert msg =~ "type prefix"
    end

    test "rejects bare names" do
      assert {:error, msg} = ComponentRef.normalize_flexible("claude")
      assert msg =~ "type prefix"
    end

    test "validates name and namespace" do
      assert {:error, _} = ComponentRef.normalize_flexible("c:AB.claude")
      assert {:error, _} = ComponentRef.normalize_flexible("c:local.AB-CAPS")
    end
  end

  # ============================================================================
  # pinned?/1
  # ============================================================================

  describe "pinned?/1" do
    test "returns false for nil version" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: nil}
      refute ComponentRef.pinned?(ref)
    end

    test "returns true for explicit version" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}
      assert ComponentRef.pinned?(ref)
    end
  end

  # ============================================================================
  # backward compat: "latest" string normalizes to nil
  # ============================================================================

  describe "backward compat: latest string" do
    test "parse normalizes 'latest' to nil in typed ref" do
      assert {:ok, %ComponentRef{version: nil}} = ComponentRef.parse("c:local.claude:latest")
    end
  end

  # ============================================================================
  # normalize_or_name_ref/1
  # ============================================================================

  describe "normalize_or_name_ref/1" do
    test "normalizes typed ref with version" do
      assert {:ok, "catalyst:local.claude:0.1.0"} =
               ComponentRef.normalize_or_name_ref("c:local.claude:0.1.0")
    end

    test "normalizes typed ref without version to name ref" do
      assert {:ok, "catalyst:local.claude"} = ComponentRef.normalize_or_name_ref("c:local.claude")
    end

    test "expands shorthand types" do
      assert {:ok, "reagent:local.parser"} = ComponentRef.normalize_or_name_ref("r:local.parser")

      assert {:ok, "formula:local.pipeline"} =
               ComponentRef.normalize_or_name_ref("f:local.pipeline")
    end

    test "passes through already-normalized refs" do
      assert {:ok, "catalyst:local.claude:0.1.0"} =
               ComponentRef.normalize_or_name_ref("catalyst:local.claude:0.1.0")
    end

    test "rejects untyped refs" do
      assert {:error, msg} = ComponentRef.normalize_or_name_ref("local.claude:0.1.0")
      assert msg =~ "type prefix"
    end

    test "rejects bare names without type" do
      assert {:error, msg} = ComponentRef.normalize_or_name_ref("claude")
      assert msg =~ "type prefix"
    end

    test "rejects empty string" do
      assert {:error, _} = ComponentRef.normalize_or_name_ref("")
    end

    test "rejects invalid name" do
      assert {:error, _} = ComponentRef.normalize_or_name_ref("c:local.AB-CAPS")
    end
  end

  # ============================================================================
  # to_name_ref/1
  # ============================================================================

  describe "to_name_ref/1" do
    test "strips version from struct" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}
      assert "catalyst:local.claude" = ComponentRef.to_name_ref(ref)
    end

    test "strips version from string" do
      assert {:ok, "catalyst:local.claude"} =
               ComponentRef.to_name_ref("catalyst:local.claude:0.1.0")
    end

    test "strips version from shorthand string" do
      assert {:ok, "catalyst:local.claude"} = ComponentRef.to_name_ref("c:local.claude:0.1.0")
    end

    test "returns error for invalid ref" do
      assert {:error, _} = ComponentRef.to_name_ref("")
    end
  end

  describe "validate_namespace/1 — personal shape" do
    test "accepts GitHub-style bare slugs" do
      assert :ok = ComponentRef.validate_namespace("alice")
      assert :ok = ComponentRef.validate_namespace("alice-bob")
      assert :ok = ComponentRef.validate_namespace("alice-123-bob")
      assert :ok = ComponentRef.validate_namespace("a")
      assert :ok = ComponentRef.validate_namespace("0")
    end

    test "rejects leading/trailing hyphen" do
      assert {:error, _} = ComponentRef.validate_namespace("-alice")
      assert {:error, _} = ComponentRef.validate_namespace("alice-")
    end

    test "rejects consecutive hyphens" do
      assert {:error, _} = ComponentRef.validate_namespace("alice--bob")
    end

    test "rejects uppercase" do
      assert {:error, _} = ComponentRef.validate_namespace("Alice")
    end

    test "rejects over 39 chars" do
      too_long = String.duplicate("a", 40)
      assert {:error, msg} = ComponentRef.validate_namespace(too_long)
      assert msg =~ "39"
    end
  end

  describe "validate_namespace/1 — publisher shape (RFC 1035)" do
    test "accepts valid hostnames" do
      assert :ok = ComponentRef.validate_namespace("stripe.com")
      assert :ok = ComponentRef.validate_namespace("api.stripe.com")
      assert :ok = ComponentRef.validate_namespace("a.b")
    end

    test "rejects leading dot" do
      assert {:error, msg} = ComponentRef.validate_namespace(".stripe.com")
      assert msg =~ "leading dot"
    end

    test "rejects trailing dot" do
      assert {:error, msg} = ComponentRef.validate_namespace("stripe.com.")
      assert msg =~ "trailing dot"
    end

    test "rejects empty label (consecutive dots)" do
      assert {:error, msg} = ComponentRef.validate_namespace("stripe..com")
      assert msg =~ "empty labels"
    end

    test "bare 'localhost' is syntactically a personal slug (server-side reserves it if needed)" do
      # Client-side syntactic validation only. `localhost` has no dot so it
      # doesn't hit the publisher validator; the publisher-specific rejection
      # for `localhost` applies only if it shows up in a dotted context.
      assert :ok = ComponentRef.validate_namespace("localhost")
    end

    test "rejects IPv4 literal" do
      assert {:error, msg} = ComponentRef.validate_namespace("192.168.1.1")
      assert msg =~ "IP address"
    end

    test "rejects port suffix" do
      assert {:error, msg} = ComponentRef.validate_namespace("stripe.com:8080")
      assert msg =~ "port"
    end

    test "rejects labels exceeding 63 chars" do
      too_long_label = String.duplicate("a", 64)
      assert {:error, _} = ComponentRef.validate_namespace("#{too_long_label}.com")
    end

    test "rejects uppercase (IDN must be punycode)" do
      assert {:error, _} = ComponentRef.validate_namespace("Stripe.com")
    end

    test "accepts punycode IDN labels (xn--)" do
      # Internationalized domain names claim ownership via their ASCII-encoded
      # (punycode) form. The label regex is ASCII-only by construction, so
      # `xn--nxasmq6b` (punycode for a real Chinese domain) passes; DNS TXT
      # verification on the wire enforces real ownership regardless.
      assert :ok = ComponentRef.validate_namespace("xn--nxasmq6b.com")
    end

    test "rejects non-ASCII Unicode labels" do
      # Raw Unicode must not slip through — owners of IDN domains use punycode.
      # The ASCII-only publisher label regex makes this regex-safe by
      # construction; this test pins the behavior.
      assert {:error, _} = ComponentRef.validate_namespace("stripe.中国")
    end

    test "rejects Cyrillic homograph labels" do
      # Visual-confusable attack: Cyrillic `с` (U+0441) vs ASCII `c`. The
      # ASCII-only regex rejects Cyrillic outright, which is the right
      # boundary — homograph defense lives in the validator, not in the UI.
      assert {:error, _} = ComponentRef.validate_namespace("stripe.сom")
    end
  end

  describe "validate_namespace/1 — @ always rejected" do
    test "rejects leading @" do
      assert {:error, msg} = ComponentRef.validate_namespace("@alice")
      assert msg =~ "@"
    end

    test "rejects @ in middle" do
      assert {:error, msg} = ComponentRef.validate_namespace("alice@domain")
      assert msg =~ "@"
    end
  end

  describe "parse/1 — three-shape namespaces round-trip" do
    test "personal: c:alice.foo:0.1.0" do
      assert {:ok, %ComponentRef{namespace: "alice", name: "foo", version: "0.1.0"}} =
               ComponentRef.parse("c:alice.foo:0.1.0")
    end

    test "publisher: c:stripe.com.api:0.1.0 — last-dot split separates namespace and name" do
      assert {:ok, %ComponentRef{namespace: "stripe.com", name: "api", version: "0.1.0"}} =
               ComponentRef.parse("c:stripe.com.api:0.1.0")
    end

    test "publisher multi-label: c:api.stripe.com.widget:1.0.0" do
      assert {:ok, %ComponentRef{namespace: "api.stripe.com", name: "widget", version: "1.0.0"}} =
               ComponentRef.parse("c:api.stripe.com.widget:1.0.0")
    end

    test "reserved: c:local.foo:0.1.0" do
      assert {:ok, %ComponentRef{namespace: "local", name: "foo", version: "0.1.0"}} =
               ComponentRef.parse("c:local.foo:0.1.0")
    end

    test "rejects @ in ref" do
      # `@alice.foo` is a personal namespace `@alice` which is invalid.
      # After parse, namespace="@alice" fails validate_namespace.
      assert {:ok, parsed} = ComponentRef.parse("c:@alice.foo:0.1.0")
      assert {:error, msg} = ComponentRef.validate(ComponentRef.to_string(parsed))
      assert msg =~ "@"
    end

    test "version-first-colon does not leak — publisher.name:version parses correctly" do
      # Regression against an earlier bug where first-colon split mangled
      # the version. Last-colon split fixes it.
      assert {:ok, %ComponentRef{version: "0.1.0-beta.1"}} =
               ComponentRef.parse("c:stripe.com.api:0.1.0-beta.1")
    end
  end

  describe "valid_personal_slug?/1 — the canonical slug rule" do
    test "accepts GitHub-style slugs" do
      assert ComponentRef.valid_personal_slug?("alice")
      assert ComponentRef.valid_personal_slug?("bob-123")
      assert ComponentRef.valid_personal_slug?(String.duplicate("a", 39))
    end

    test "rejects bad shapes, overlength, and non-binaries" do
      refute ComponentRef.valid_personal_slug?("")
      refute ComponentRef.valid_personal_slug?("-alice")
      refute ComponentRef.valid_personal_slug?("alice-")
      refute ComponentRef.valid_personal_slug?("al--ice")
      refute ComponentRef.valid_personal_slug?("Alice")
      refute ComponentRef.valid_personal_slug?(String.duplicate("a", 40))
      refute ComponentRef.valid_personal_slug?(nil)
      refute ComponentRef.valid_personal_slug?(42)
    end

    test "personal_slug_regex/0 keeps its anchored source (HTML pattern consumers)" do
      assert Regex.source(ComponentRef.personal_slug_regex()) == "^[a-z0-9]+(-[a-z0-9]+)*$"
    end
  end
end
