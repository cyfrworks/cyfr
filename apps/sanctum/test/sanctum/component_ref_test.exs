defmodule Sanctum.ComponentRefTest do
  use ExUnit.Case, async: true

  alias Sanctum.ComponentRef

  # ============================================================================
  # parse/1
  # ============================================================================

  describe "parse/1" do
    test "parses canonical format namespace.name:version" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("local.my-tool:1.0.0")
    end

    test "parses canonical with different namespace" do
      assert {:ok, %ComponentRef{namespace: "cyfr", name: "stripe", version: "2.0.0"}} =
               ComponentRef.parse("cyfr.stripe:2.0.0")
    end

    test "parses legacy name:version format, defaults namespace to local" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("my-tool:1.0.0")
    end

    test "parses bare name, defaults to local namespace and latest version" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "latest"}} =
               ComponentRef.parse("my-tool")
    end

    test "parses legacy colon-separated local:name:version" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}} =
               ComponentRef.parse("local:my-tool:1.0.0")
    end

    test "parses canonical without version, defaults to latest" do
      assert {:ok, %ComponentRef{namespace: "cyfr", name: "stripe", version: "latest"}} =
               ComponentRef.parse("cyfr.stripe")
    end

    test "parses semver with prerelease" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0-beta.1"}} =
               ComponentRef.parse("local.my-tool:1.0.0-beta.1")
    end

    test "parses semver with build metadata" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0+build.123"}} =
               ComponentRef.parse("local.my-tool:1.0.0+build.123")
    end

    test "trims whitespace" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}} =
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
  # to_string/1
  # ============================================================================

  describe "to_string/1" do
    test "formats canonical string" do
      ref = %ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}
      assert "local.my-tool:1.0.0" = ComponentRef.to_string(ref)
    end

    test "String.Chars protocol works" do
      ref = %ComponentRef{namespace: "cyfr", name: "stripe", version: "2.0.0"}
      assert "cyfr.stripe:2.0.0" = "#{ref}"
    end
  end

  # ============================================================================
  # normalize/1
  # ============================================================================

  describe "normalize/1" do
    test "normalizes legacy name:version to canonical" do
      assert {:ok, "local.my-tool:1.0.0"} = ComponentRef.normalize("my-tool:1.0.0")
    end

    test "canonical stays canonical" do
      assert {:ok, "local.my-tool:1.0.0"} = ComponentRef.normalize("local.my-tool:1.0.0")
    end

    test "normalizes legacy colon-separated" do
      assert {:ok, "local.my-tool:1.0.0"} = ComponentRef.normalize("local:my-tool:1.0.0")
    end

    test "normalizes bare name to canonical with latest" do
      assert {:ok, "local.my-tool:latest"} = ComponentRef.normalize("my-tool")
    end

    test "returns error for empty" do
      assert {:error, _} = ComponentRef.normalize("")
    end
  end

  # ============================================================================
  # from_path/1
  # ============================================================================

  describe "from_path/1" do
    test "extracts ref from catalyst path" do
      assert {:ok, %ComponentRef{namespace: "local", name: "claude", version: "0.1.0"}} =
               ComponentRef.from_path("components/catalysts/local/claude/0.1.0/catalyst.wasm")
    end

    test "extracts ref from reagent path" do
      assert {:ok, %ComponentRef{namespace: "local", name: "parser", version: "1.0.0"}} =
               ComponentRef.from_path("components/reagents/local/parser/1.0.0/reagent.wasm")
    end

    test "extracts ref from formula path" do
      assert {:ok, %ComponentRef{namespace: "cyfr", name: "pipeline", version: "2.0.0"}} =
               ComponentRef.from_path("components/formulas/cyfr/pipeline/2.0.0/formula.wasm")
    end

    test "extracts ref from absolute path" do
      assert {:ok, %ComponentRef{namespace: "local", name: "my-tool", version: "0.1.0"}} =
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
    test "valid canonical ref" do
      assert :ok = ComponentRef.validate("local.my-tool:1.0.0")
    end

    test "valid legacy ref" do
      assert :ok = ComponentRef.validate("my-tool:1.0.0")
    end

    test "valid bare name" do
      assert :ok = ComponentRef.validate("my-tool")
    end

    test "rejects empty" do
      assert {:error, _} = ComponentRef.validate("")
    end

    test "rejects invalid name starting with hyphen" do
      assert {:error, _} = ComponentRef.validate("local.-invalid:1.0.0")
    end

    test "rejects name that is too long" do
      long_name = String.duplicate("a", 65)
      assert {:error, msg} = ComponentRef.validate("local.#{long_name}:1.0.0")
      assert msg =~ "name must be at most 64 characters"
    end

    test "rejects invalid version" do
      assert {:error, msg} = ComponentRef.validate("local.my-tool:not-semver")
      assert msg =~ "version must be valid semver"
    end

    test "accepts latest as version" do
      assert :ok = ComponentRef.validate("local.my-tool:latest")
    end

    test "rejects non-string input" do
      assert {:error, _} = ComponentRef.validate(nil)
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
  end
end
