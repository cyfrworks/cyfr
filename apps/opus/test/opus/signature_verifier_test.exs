defmodule Opus.SignatureVerifierTest do
  use ExUnit.Case, async: true

  alias Opus.SignatureVerifier
  alias Sanctum.Context

  describe "verify/3" do
    test "allows local files without verification" do
      assert :ok = SignatureVerifier.verify(%{"local" => "/path/to/file.wasm"}, nil, nil)
      assert :ok = SignatureVerifier.verify(%{"local" => "~/file.wasm"}, "bob@example.com", nil)
    end

    test "allows arca artifacts without verification" do
      assert :ok = SignatureVerifier.verify(%{"arca" => "tools/calculator.wasm"}, nil, nil)
      assert :ok = SignatureVerifier.verify(%{"arca" => "artifacts/v1/tool.wasm"}, "admin@cyfr.run", nil)
    end

    test "allows OCI references (stub behavior)" do
      # Current stub implementation allows all OCI references
      assert :ok = SignatureVerifier.verify(
        %{"oci" => "registry.cyfr.run/tools/calculator:1.0"},
        "security@cyfr.run",
        "https://github.com/login/oauth"
      )
    end

    test "allows OCI references with nil identity and issuer" do
      assert :ok = SignatureVerifier.verify(%{"oci" => "ghcr.io/example/tool:latest"}, nil, nil)
    end

    test "returns error for unknown reference format" do
      {:error, msg} = SignatureVerifier.verify(%{"unknown" => "value"}, nil, nil)
      assert msg =~ "Unknown reference format"
    end

    test "returns error for empty reference" do
      {:error, msg} = SignatureVerifier.verify(%{}, nil, nil)
      assert msg =~ "Unknown reference format"
    end

    test "returns error for non-map reference" do
      {:error, msg} = SignatureVerifier.verify("not a map", nil, nil)
      assert msg =~ "Unknown reference format"
    end
  end

  describe "verify_trusted/3" do
    setup do
      ctx = %Context{
        user_id: "user_test",
        permissions: MapSet.new([:execute]),
        scope: :personal,
        auth_method: :local
      }

      {:ok, ctx: ctx}
    end

    test "allows all component types (stub behavior)", %{ctx: ctx} do
      assert :ok = SignatureVerifier.verify_trusted(%{"oci" => "example/tool:1.0"}, :catalyst, ctx)
      assert :ok = SignatureVerifier.verify_trusted(%{"oci" => "example/tool:1.0"}, :reagent, ctx)
      assert :ok = SignatureVerifier.verify_trusted(%{"oci" => "example/tool:1.0"}, :formula, ctx)
    end

    test "allows local files for all component types", %{ctx: ctx} do
      assert :ok = SignatureVerifier.verify_trusted(%{"local" => "/tmp/tool.wasm"}, :catalyst, ctx)
      assert :ok = SignatureVerifier.verify_trusted(%{"local" => "/tmp/tool.wasm"}, :reagent, ctx)
    end

    test "allows arca artifacts for all component types", %{ctx: ctx} do
      assert :ok = SignatureVerifier.verify_trusted(%{"arca" => "tools/calc.wasm"}, :catalyst, ctx)
      assert :ok = SignatureVerifier.verify_trusted(%{"arca" => "tools/calc.wasm"}, :reagent, ctx)
    end
  end

  describe "requires_verification?/1" do
    test "returns true for OCI references" do
      assert SignatureVerifier.requires_verification?(%{"oci" => "registry.io/tool:1.0"}) == true
    end

    test "returns false for local files" do
      assert SignatureVerifier.requires_verification?(%{"local" => "/path/to/file.wasm"}) == false
    end

    test "returns false for arca artifacts" do
      assert SignatureVerifier.requires_verification?(%{"arca" => "tools/calc.wasm"}) == false
    end

    test "returns false for unknown reference types" do
      assert SignatureVerifier.requires_verification?(%{"unknown" => "value"}) == false
      assert SignatureVerifier.requires_verification?(%{}) == false
    end
  end
end
