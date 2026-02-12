defmodule SanctumArx.EditionTest do
  use ExUnit.Case, async: false

  alias SanctumArx.Edition
  alias SanctumArx.License

  setup do
    # Ensure Sanctum (community) mode and load license
    Application.put_env(:sanctum_arx, :edition, :community)
    License.load()

    on_exit(fn ->
      Application.put_env(:sanctum_arx, :edition, :community)
      :persistent_term.put(:sanctum_arx_license, :community)
    end)

    :ok
  end

  describe "community?/0" do
    test "returns true when in Sanctum mode" do
      assert Edition.community?() == true
    end

    test "returns false when in arx edition" do
      Application.put_env(:sanctum_arx, :edition, :arx)
      assert Edition.community?() == false
    end
  end

  describe "arx?/0" do
    test "returns false when in Sanctum mode" do
      assert Edition.arx?() == false
    end

    test "returns true when in arx edition" do
      Application.put_env(:sanctum_arx, :edition, :arx)
      assert Edition.arx?() == true
    end
  end

  describe "feature_available?/1" do
    test "community features are always available" do
      assert Edition.feature_available?(:github_oidc) == true
      assert Edition.feature_available?(:google_oidc) == true
      assert Edition.feature_available?(:sqlite_storage) == true
      assert Edition.feature_available?(:local_secrets) == true
      assert Edition.feature_available?(:yaml_policy) == true
      assert Edition.feature_available?(:basic_audit) == true
      assert Edition.feature_available?(:execute) == true
      assert Edition.feature_available?(:api_keys) == true
      assert Edition.feature_available?(:sessions) == true
    end

    test "arx features are not available in Sanctum mode" do
      assert Edition.feature_available?(:saml) == false
      assert Edition.feature_available?(:scim) == false
      assert Edition.feature_available?(:vault_secrets) == false
      assert Edition.feature_available?(:aws_kms) == false
      assert Edition.feature_available?(:siem_forwarding) == false
      assert Edition.feature_available?(:unlimited_audit) == false
      assert Edition.feature_available?(:multi_node) == false
    end
  end

  describe "require_feature!/1" do
    test "returns :ok for available community features" do
      assert Edition.require_feature!(:github_oidc) == :ok
      assert Edition.require_feature!(:local_secrets) == :ok
    end

    test "raises FeatureNotAvailable for arx features" do
      assert_raise Edition.FeatureNotAvailable, ~r/requires Sanctum Arx/, fn ->
        Edition.require_feature!(:saml)
      end
    end

    test "error message includes upgrade instructions" do
      error =
        assert_raise Edition.FeatureNotAvailable, fn ->
          Edition.require_feature!(:vault_secrets)
        end

      assert error.message =~ "Contact sales@cyfr.dev"
    end
  end

  describe "available_features/0" do
    test "returns Sanctum features in Sanctum mode" do
      features = Edition.available_features()

      assert :github_oidc in features
      assert :google_oidc in features
      assert :sqlite_storage in features

      # Arx features should not be included
      refute :saml in features
      refute :vault_secrets in features
    end
  end

  describe "community_features/0" do
    test "returns list of community features" do
      features = Edition.community_features()

      assert is_list(features)
      assert :github_oidc in features
      assert :google_oidc in features
    end
  end

  describe "arx_features/0" do
    test "returns list of arx features" do
      features = Edition.arx_features()

      assert is_list(features)
      assert :saml in features
      assert :scim in features
      assert :vault_secrets in features
      assert :aws_kms in features
    end
  end

  describe "info/0" do
    test "returns edition information" do
      info = Edition.info()

      assert info.edition == :community
      assert is_list(info.features)
      assert info.license_valid == true
      assert info.zombie_mode == false
    end
  end

  describe "arx edition with license" do
    setup do
      # Create a valid license
      license = %{
        type: :arx,
        customer_id: "test-corp",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 365, :day),
        features: ["saml", "vault_secrets", "siem_forwarding"],
        seats: 100
      }

      Application.put_env(:sanctum_arx, :edition, :arx)
      :persistent_term.put(:sanctum_arx_license, license)

      :ok
    end

    test "arx features are available with valid license" do
      assert Edition.feature_available?(:saml) == true
      assert Edition.feature_available?(:vault_secrets) == true
      assert Edition.feature_available?(:siem_forwarding) == true
    end

    test "unlicensed arx features are not available" do
      # scim is not in the test license's features
      assert Edition.feature_available?(:scim) == false
      assert Edition.feature_available?(:aws_kms) == false
    end

    test "community features remain available" do
      assert Edition.feature_available?(:github_oidc) == true
      assert Edition.feature_available?(:local_secrets) == true
    end

    test "available_features includes licensed arx features" do
      features = Edition.available_features()

      assert :saml in features
      assert :vault_secrets in features
      # Unlicensed features not included
      refute :scim in features
    end
  end

  describe "zombie mode (expired arx license)" do
    setup do
      # Create an expired license
      expired_license = %{
        type: :arx,
        customer_id: "test-corp",
        issued_at: DateTime.add(DateTime.utc_now(), -365, :day),
        expires_at: DateTime.add(DateTime.utc_now(), -1, :day),
        features: ["saml", "vault_secrets"],
        seats: 100
      }

      Application.put_env(:sanctum_arx, :edition, :arx)
      :persistent_term.put(:sanctum_arx_license, expired_license)

      :ok
    end

    test "arx features are not available in zombie mode" do
      assert License.zombie_mode?() == true
      assert Edition.feature_available?(:saml) == false
      assert Edition.feature_available?(:vault_secrets) == false
    end

    test "community features remain available in zombie mode" do
      assert Edition.feature_available?(:github_oidc) == true
      assert Edition.feature_available?(:local_secrets) == true
    end

    test "require_feature! error message mentions license renewal" do
      error =
        assert_raise Edition.FeatureNotAvailable, fn ->
          Edition.require_feature!(:saml)
        end

      assert error.message =~ "license expired"
      assert error.message =~ "renew"
    end
  end
end
