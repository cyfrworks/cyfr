defmodule SanctumArx.LicenseVerificationTest do
  use ExUnit.Case, async: false

  alias SanctumArx.License

  # Generate a test RSA keypair for signing
  @test_jwk JOSE.JWK.generate_key({:rsa, 2048})
  @test_public_jwk JOSE.JWK.to_public(@test_jwk)
  @test_public_pem JOSE.JWK.to_pem(@test_public_jwk) |> elem(1)

  # A different keypair (for wrong-key test)
  @wrong_jwk JOSE.JWK.generate_key({:rsa, 2048})

  @valid_claims %{
    "type" => "arx",
    "customer_id" => "test-corp",
    "issued_at" => "2025-01-01T00:00:00Z",
    "expires_at" => "2099-01-01T00:00:00Z",
    "features" => ["saml", "vault"],
    "seats" => 50
  }

  defp sign_license(claims, jwk \\ @test_jwk) do
    jws = %{"alg" => "RS256"}
    {_, token} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
    token
  end

  setup do
    original_edition = Application.get_env(:cyfr, :edition)
    original_pubkey = Application.get_env(:cyfr, :license_public_key)
    original_license = :persistent_term.get(:sanctum_arx_license, nil)

    Application.put_env(:cyfr, :license_public_key, @test_public_pem)

    on_exit(fn ->
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

      if original_license do
        :persistent_term.put(:sanctum_arx_license, original_license)
      else
        :persistent_term.put(:sanctum_arx_license, :core)
      end
    end)

    :ok
  end

  describe "signature verification" do
    test "valid signature passes verification" do
      token = sign_license(@valid_claims)
      tmp = write_tmp_license(token)

      Application.put_env(:cyfr, :edition, :arx)
      result = License.load(path: tmp)
      assert {:ok, %{type: :arx, customer_id: "test-corp"}} = result
    end

    test "wrong key is rejected" do
      token = sign_license(@valid_claims, @wrong_jwk)
      tmp = write_tmp_license(token)

      Application.put_env(:cyfr, :edition, :arx)
      result = License.load(path: tmp)
      assert {:error, :invalid_signature} = result
    end

    test "tampered payload is rejected" do
      token = sign_license(@valid_claims)
      [header, _payload, signature] = String.split(token, ".")
      fake_payload = Base.url_encode64(Jason.encode!(%{@valid_claims | "customer_id" => "hacked"}), padding: false)
      tampered = "#{header}.#{fake_payload}.#{signature}"
      tmp = write_tmp_license(tampered)

      Application.put_env(:cyfr, :edition, :arx)
      result = License.load(path: tmp)
      assert {:error, :invalid_signature} = result
    end

    test "unsigned JSON is rejected in Arx mode" do
      plain_json = Jason.encode!(@valid_claims)
      tmp = write_tmp_license(plain_json)

      Application.put_env(:cyfr, :edition, :arx)
      result = License.load(path: tmp)
      assert {:error, :invalid_license_format} = result
    end
  end

  describe "license_public_key/0" do
    test "returns configured key" do
      assert License.license_public_key() == @test_public_pem
    end

    test "falls back to default" do
      Application.delete_env(:cyfr, :license_public_key)

      key = License.license_public_key()
      assert String.contains?(key, "BEGIN PUBLIC KEY")
    end
  end

  defp write_tmp_license(content) do
    path = Path.join(System.tmp_dir!(), "test_license_#{:rand.uniform(999_999)}.sig")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
