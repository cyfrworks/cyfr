defmodule Sanctum.ComponentRefTest do
  use ExUnit.Case, async: true

  alias Sanctum.ComponentRef

  # ============================================================================
  # parse/1 — untyped (backward compat)
  # ============================================================================

  describe "parse/1 untyped" do
    test "parses canonical format namespace.name:version" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("local.my-tool:1.0.0")
    end

    test "parses canonical with different namespace" do
      assert {:ok, %ComponentRef{type: nil, namespace: "cyfr", name: "stripe", version: "2.0.0"}} =
               ComponentRef.parse("cyfr.stripe:2.0.0")
    end

    test "parses legacy name:version format, defaults namespace to local" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("my-tool:1.0.0")
    end

    test "parses bare name, defaults to local namespace and latest version" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "latest"}} =
               ComponentRef.parse("my-tool")
    end

    test "parses legacy colon-separated local:name:version" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("local:my-tool:1.0.0")
    end

    test "parses canonical without version, defaults to latest" do
      assert {:ok, %ComponentRef{type: nil, namespace: "cyfr", name: "stripe", version: "latest"}} =
               ComponentRef.parse("cyfr.stripe")
    end

    test "parses semver with prerelease" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0-beta.1"}} =
               ComponentRef.parse("local.my-tool:1.0.0-beta.1")
    end

    test "parses semver with build metadata" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0+build.123"}} =
               ComponentRef.parse("local.my-tool:1.0.0+build.123")
    end

    test "trims whitespace" do
      assert {:ok, %ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("  local.my-tool:1.0.0  ")
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
      assert {:ok, %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}} =
               ComponentRef.parse("catalyst:local.claude:0.1.0")
    end

    test "parses typed canonical: reagent:namespace.name:version" do
      assert {:ok, %ComponentRef{type: "reagent", namespace: "cyfr", name: "sentiment", version: "1.0.0"}} =
               ComponentRef.parse("reagent:cyfr.sentiment:1.0.0")
    end

    test "parses typed canonical: formula:namespace.name:version" do
      assert {:ok, %ComponentRef{type: "formula", namespace: "local", name: "list-models", version: "0.1.0"}} =
               ComponentRef.parse("formula:local.list-models:0.1.0")
    end

    test "parses shorthand c: as catalyst" do
      assert {:ok, %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}} =
               ComponentRef.parse("c:local.claude:0.1.0")
    end

    test "parses shorthand r: as reagent" do
      assert {:ok, %ComponentRef{type: "reagent", namespace: "local", name: "parser", version: "1.0.0"}} =
               ComponentRef.parse("r:local.parser:1.0.0")
    end

    test "parses shorthand f: as formula" do
      assert {:ok, %ComponentRef{type: "formula", namespace: "local", name: "list-models", version: "0.1.0"}} =
               ComponentRef.parse("f:local.list-models:0.1.0")
    end

    test "typed ref with legacy name:version remainder" do
      assert {:ok, %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}} =
               ComponentRef.parse("catalyst:claude:0.1.0")
    end

    test "typed ref with bare name remainder" do
      assert {:ok, %ComponentRef{type: "reagent", namespace: "local", name: "parser", version: "latest"}} =
               ComponentRef.parse("r:parser")
    end

    test "trims whitespace on typed ref" do
      assert {:ok, %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}} =
               ComponentRef.parse("  c:local.claude:0.1.0  ")
    end
  end

  # ============================================================================
  # to_string/1
  # ============================================================================

  describe "to_string/1" do
    test "formats untyped canonical string" do
      ref = %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}
      assert "local.my-tool:1.0.0" = ComponentRef.to_string(ref)
    end

    test "formats typed canonical string" do
      ref = %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}
      assert "catalyst:local.claude:0.1.0" = ComponentRef.to_string(ref)
    end

    test "String.Chars protocol works untyped" do
      ref = %ComponentRef{namespace: "cyfr", name: "stripe", version: "2.0.0"}
      assert "cyfr.stripe:2.0.0" = "#{ref}"
    end

    test "String.Chars protocol works typed" do
      ref = %ComponentRef{type: "reagent", namespace: "cyfr", name: "sentiment", version: "1.0.0"}
      assert "reagent:cyfr.sentiment:1.0.0" = "#{ref}"
    end
  end

  # ============================================================================
  # normalize/1
  # ============================================================================

  describe "normalize/1" do
    test "rejects untyped legacy name:version" do
      assert {:error, msg} = ComponentRef.normalize("my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects untyped canonical" do
      assert {:error, msg} = ComponentRef.normalize("local.my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects untyped legacy colon-separated" do
      assert {:error, msg} = ComponentRef.normalize("local:my-tool:1.0.0")
      assert msg =~ "type prefix"
    end

    test "rejects bare name without type" do
      assert {:error, msg} = ComponentRef.normalize("my-tool")
      assert msg =~ "type prefix"
    end

    test "normalizes typed ref preserving type" do
      assert {:ok, "catalyst:local.claude:0.1.0"} = ComponentRef.normalize("c:local.claude:0.1.0")
    end

    test "normalizes typed shorthand to full type" do
      assert {:ok, "reagent:local.parser:1.0.0"} = ComponentRef.normalize("r:parser:1.0.0")
    end

    test "normalizes full type name" do
      assert {:ok, "catalyst:local.claude:0.1.0"} = ComponentRef.normalize("catalyst:local.claude:0.1.0")
    end

    test "normalizes formula shorthand" do
      assert {:ok, "formula:local.list-models:latest"} = ComponentRef.normalize("f:list-models")
    end

    test "returns error for empty" do
      assert {:error, _} = ComponentRef.normalize("")
    end

    test "error message suggests typed format" do
      {:error, msg} = ComponentRef.normalize("local.my-tool:1.0.0")
      assert msg =~ "catalyst:local.my-tool:1.0.0"
      assert msg =~ "catalyst (c), reagent (r), formula (f)"
    end
  end

  # ============================================================================
  # from_path/1
  # ============================================================================

  describe "from_path/1" do
    test "extracts ref with type from catalyst path" do
      assert {:ok, %ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}} =
               ComponentRef.from_path("components/catalysts/local/claude/0.1.0/catalyst.wasm")
    end

    test "extracts ref with type from reagent path" do
      assert {:ok, %ComponentRef{type: "reagent", namespace: "local", name: "parser", version: "1.0.0"}} =
               ComponentRef.from_path("components/reagents/local/parser/1.0.0/reagent.wasm")
    end

    test "extracts ref with type from formula path" do
      assert {:ok, %ComponentRef{type: "formula", namespace: "cyfr", name: "pipeline", version: "2.0.0"}} =
               ComponentRef.from_path("components/formulas/cyfr/pipeline/2.0.0/formula.wasm")
    end

    test "extracts ref from absolute path" do
      assert {:ok, %ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: "0.1.0"}} =
               ComponentRef.from_path("/home/user/project/components/catalysts/local/my-tool/0.1.0/catalyst.wasm")
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
    test "rejects untyped canonical ref" do
      assert {:error, msg} = ComponentRef.validate("local.my-tool:1.0.0")
      assert msg =~ "component type is required"
    end

    test "valid typed ref" do
      assert :ok = ComponentRef.validate("catalyst:local.my-tool:1.0.0")
    end

    test "valid typed shorthand ref" do
      assert :ok = ComponentRef.validate("c:local.my-tool:1.0.0")
    end

    test "rejects untyped legacy ref" do
      assert {:error, _} = ComponentRef.validate("my-tool:1.0.0")
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

    test "accepts latest as version" do
      assert :ok = ComponentRef.validate("c:local.my-tool:latest")
    end

    test "rejects non-string input" do
      assert {:error, _} = ComponentRef.validate(nil)
    end

    test "rejects invalid type" do
      # Manually create an invalid typed ref won't parse, but validate_type can be called directly
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
  # Round-trip
  # ============================================================================

  describe "round-trip" do
    test "parse -> to_string -> parse is idempotent for canonical" do
      original = "local.my-tool:1.0.0"
      {:ok, parsed} = ComponentRef.parse(original)
      canonical = ComponentRef.to_string(parsed)
      assert canonical == original
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end

    test "legacy normalizes through round-trip" do
      {:ok, parsed} = ComponentRef.parse("my-tool:1.0.0")
      canonical = ComponentRef.to_string(parsed)
      assert canonical == "local.my-tool:1.0.0"
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end

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
      {:ok, parsed} = ComponentRef.from_path("components/catalysts/local/claude/0.1.0/catalyst.wasm")
      canonical = ComponentRef.to_string(parsed)
      assert canonical == "catalyst:local.claude:0.1.0"
      {:ok, reparsed} = ComponentRef.parse(canonical)
      assert reparsed == parsed
    end
  end
end
