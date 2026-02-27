defmodule Opus.SignatureVerifierTest do
  use ExUnit.Case, async: true

  alias Opus.SignatureVerifier

  describe "verify/3" do
    test "allows string references without enforcement" do
      assert :ok = SignatureVerifier.verify("catalyst:local.claude:0.2.0", nil, nil)
      assert :ok = SignatureVerifier.verify("reagent:cyfr.json-transform:1.0.0", "bob@example.com", nil)
    end

    test "allows string references with identity and issuer" do
      assert :ok = SignatureVerifier.verify(
        "catalyst:cyfr.calculator:1.0.0",
        "security@cyfr.run",
        "https://github.com/login/oauth"
      )
    end

    test "returns error for non-string reference" do
      {:error, msg} = SignatureVerifier.verify(%{"unknown" => "value"}, nil, nil)
      assert msg =~ "Unknown reference format"
    end

    test "returns error for empty map reference" do
      {:error, msg} = SignatureVerifier.verify(%{}, nil, nil)
      assert msg =~ "Unknown reference format"
    end
  end

  describe "verify_trusted/3" do
    setup do
      ctx = %Sanctum.Context{
        user_id: "user_test",
        permissions: MapSet.new([:execute]),
        scope: :personal,
        auth_method: :local
      }

      {:ok, ctx: ctx}
    end

    test "allows all component types (stub behavior)", %{ctx: ctx} do
      assert :ok = SignatureVerifier.verify_trusted("catalyst:cyfr.tool:1.0", :catalyst, ctx)
      assert :ok = SignatureVerifier.verify_trusted("reagent:local.test:0.1.0", :reagent, ctx)
      assert :ok = SignatureVerifier.verify_trusted("formula:local.compose:0.2.0", :formula, ctx)
    end
  end

  describe "enforce_signatures?/0" do
    test "defaults to false" do
      refute SignatureVerifier.enforce_signatures?()
    end
  end
end
