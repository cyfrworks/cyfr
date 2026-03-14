defmodule SanctumArx.LicenseTest do
  use ExUnit.Case, async: false

  alias SanctumArx.License

  # Tests run with default Sanctum (community) config

  # Test RSA keypair for signing licenses
  @test_jwk JOSE.JWK.generate_key({:rsa, 2048})
  @test_public_jwk JOSE.JWK.to_public(@test_jwk)
  @test_public_pem JOSE.JWK.to_pem(@test_public_jwk) |> elem(1)

  @valid_claims %{
    "type" => "arx",
    "customer_id" => "test-corp",
    "issued_at" => "2024-01-01T00:00:00Z",
    "expires_at" => "2099-12-31T23:59:59Z",
    "features" => ["saml", "vault", "siem"],
    "seats" => 100
  }

  @expired_claims %{
    "type" => "arx",
    "customer_id" => "test-corp",
    "issued_at" => "2020-01-01T00:00:00Z",
    "expires_at" => "2020-12-31T23:59:59Z",
    "features" => ["saml"],
    "seats" => 10
  }

  defp sign_license(claims) do
    jws = %{"alg" => "RS256"}
    {_, token} = JOSE.JWT.sign(@test_jwk, jws, claims) |> JOSE.JWS.compact()
    token
  end

  describe "edition/0" do
    test "returns :core by default" do
      assert License.edition() == :core
    end
  end

  describe "load/0 in Sanctum mode" do
    test "returns {:ok, :core}" do
      assert {:ok, :core} = License.load()
    end

    test "stores :core as current license" do
      License.load()
      assert License.current_license() == :core
    end
  end

  describe "valid?/0" do
    test "returns true for Sanctum mode" do
      License.load()
      assert License.valid?() == true
    end
  end

  describe "zombie_mode?/0" do
    test "returns false for Sanctum mode" do
      License.load()
      assert License.zombie_mode?() == false
    end
  end

  describe "feature_licensed?/1" do
    setup do
      License.load()
      :ok
    end

    test "returns true for basic community features" do
      assert License.feature_licensed?(:github_oidc) == true
      assert License.feature_licensed?(:google_oidc) == true
      assert License.feature_licensed?(:local_secrets) == true
      assert License.feature_licensed?(:basic_policy) == true
    end

    test "returns false for arx features" do
      assert License.feature_licensed?(:saml) == false
      assert License.feature_licensed?(:vault) == false
    end
  end

  describe "info/0" do
    test "returns edition info for community" do
      License.load()
      info = License.info()

      assert info.edition == :core
      assert info.valid == true
      assert info.zombie_mode == false
    end
  end

  describe "license file parsing" do
    setup do
      # Store original config
      original_edition = Application.get_env(:cyfr, :edition)
      original_pubkey = Application.get_env(:cyfr, :license_public_key)

      # Use test public key for verification
      Application.put_env(:cyfr, :license_public_key, @test_public_pem)

      on_exit(fn ->
        # Restore original config
        if original_edition do
          Application.put_env(:cyfr, :edition, original_edition)
        else
          Application.delete_env(:cyfr, :edition)
        end

        if original_pubkey do
          Application.put_env(:cyfr, :license_public_key, original_pubkey)
        else
          Application.delete_env(:cyfr, :license_public_key)
        end

        # Reset license to community
        :persistent_term.put(:sanctum_arx_license, :core)
      end)

      :ok
    end

    test "loads valid license file in arx mode" do
      token = sign_license(@valid_claims)
      path = Path.join(System.tmp_dir!(), "test_license_#{:rand.uniform(100_000)}.sig")
      File.write!(path, token)

      Application.put_env(:cyfr, :edition, :arx)

      try do
        result = License.load(path: path)
        assert {:ok, license} = result
        assert license.type == :arx
        assert license.customer_id == "test-corp"
        assert license.seats == 100
        assert "saml" in license.features
        assert "vault" in license.features
      after
        File.rm(path)
      end
    end

    test "returns error for expired license in arx mode" do
      token = sign_license(@expired_claims)
      path = Path.join(System.tmp_dir!(), "test_license_expired_#{:rand.uniform(100_000)}.sig")
      File.write!(path, token)

      Application.put_env(:cyfr, :edition, :arx)

      try do
        result = License.load(path: path)
        assert {:error, :expired} = result

        # Should still store the license for zombie mode
        license = License.current_license()
        assert license.customer_id == "test-corp"
      after
        File.rm(path)
      end
    end

    test "returns error for missing license file in arx mode" do
      Application.put_env(:cyfr, :edition, :arx)

      result = License.load(path: "/nonexistent/license.sig")
      assert {:error, {:license_file_missing, _}} = result
    end

    test "returns error for invalid content" do
      path = Path.join(System.tmp_dir!(), "test_license_invalid_#{:rand.uniform(100_000)}.sig")
      File.write!(path, "not valid json or jws")

      Application.put_env(:cyfr, :edition, :arx)

      try do
        result = License.load(path: path)
        assert {:error, _} = result
      after
        File.rm(path)
      end
    end

    test "returns error for unsigned JSON in arx mode" do
      incomplete = Jason.encode!(%{"type" => "arx", "customer_id" => "test"})
      path = Path.join(System.tmp_dir!(), "test_license_unsigned_#{:rand.uniform(100_000)}.sig")
      File.write!(path, incomplete)

      Application.put_env(:cyfr, :edition, :arx)

      try do
        result = License.load(path: path)
        assert {:error, :invalid_license_format} = result
      after
        File.rm(path)
      end
    end
  end
end
