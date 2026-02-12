defmodule Sanctum.ContextJWTTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context

  @test_key "test_secret_key_for_jwt_signing_32_bytes"

  setup do
    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    # Store original config and set test key
    original_key = Application.get_env(:sanctum, :jwt_signing_key)
    Application.put_env(:sanctum, :jwt_signing_key, @test_key)

    on_exit(fn ->
      if original_key do
        Application.put_env(:sanctum, :jwt_signing_key, original_key)
      else
        Application.delete_env(:sanctum, :jwt_signing_key)
      end
    end)

    :ok
  end

  describe "from_jwt/1" do
    test "parses valid JWT with sub claim" do
      jwt = create_jwt(%{"sub" => "user_123"})

      {:ok, ctx} = Context.from_jwt(jwt)

      assert ctx.user_id == "user_123"
      assert ctx.auth_method == :oidc
      assert ctx.scope == :personal
    end

    test "extracts permissions from JWT" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "permissions" => ["execute", "read", "write"]
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert Context.has_permission?(ctx, :execute)
      assert Context.has_permission?(ctx, :read)
      assert Context.has_permission?(ctx, :write)
      refute Context.has_permission?(ctx, :admin)
    end

    test "extracts organization from JWT" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "org" => "acme-corp"
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert ctx.org_id == "acme-corp"
    end

    test "handles org scope" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "org" => "acme-corp",
        "scope" => "org"
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert ctx.scope == :org
    end

    test "defaults to personal scope" do
      jwt = create_jwt(%{"sub" => "user_123"})

      {:ok, ctx} = Context.from_jwt(jwt)

      assert ctx.scope == :personal
    end

    test "extracts session_id from JWT" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "session_id" => "sess_abc123"
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert ctx.session_id == "sess_abc123"
    end

    test "returns error for invalid signature" do
      # Create JWT with wrong key
      wrong_key = JOSE.JWK.from_oct("wrong_key_for_signing_1234567890")
      claims = %{"sub" => "user_123"}
      {_, jwt} = JOSE.JWT.sign(wrong_key, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()

      assert {:error, :invalid_signature} = Context.from_jwt(jwt)
    end

    test "returns error for missing sub claim" do
      jwt = create_jwt(%{"permissions" => ["execute"]})

      assert {:error, :missing_sub_claim} = Context.from_jwt(jwt)
    end

    test "returns error for empty sub claim" do
      jwt = create_jwt(%{"sub" => ""})

      assert {:error, :missing_sub_claim} = Context.from_jwt(jwt)
    end

    test "returns error for non-string token" do
      assert {:error, :invalid_token} = Context.from_jwt(nil)
      assert {:error, :invalid_token} = Context.from_jwt(123)
      assert {:error, :invalid_token} = Context.from_jwt(%{})
    end

    test "returns error when no signing key configured" do
      Application.delete_env(:sanctum, :jwt_signing_key)

      jwt = "some.jwt.token"

      assert {:error, :no_signing_key_configured} = Context.from_jwt(jwt)
    end

    test "handles malformed JWT" do
      assert {:error, _} = Context.from_jwt("not.a.valid.jwt")
      assert {:error, _} = Context.from_jwt("random-string")
      assert {:error, _} = Context.from_jwt("")
    end

    test "permissions are MapSet" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "permissions" => ["execute", "execute", "read"]
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      # MapSet deduplicates
      assert MapSet.size(ctx.permissions) == 2
    end

    test "handles empty permissions" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "permissions" => []
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert MapSet.size(ctx.permissions) == 0
    end

    test "handles missing permissions" do
      jwt = create_jwt(%{"sub" => "user_123"})

      {:ok, ctx} = Context.from_jwt(jwt)

      assert MapSet.size(ctx.permissions) == 0
    end
  end

  describe "JWT signing algorithms" do
    test "accepts HS256 signed JWT" do
      jwt = create_jwt_with_alg(%{"sub" => "user_123"}, "HS256")
      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end

    test "accepts HS384 signed JWT" do
      jwt = create_jwt_with_alg(%{"sub" => "user_123"}, "HS384")
      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end

    test "accepts HS512 signed JWT" do
      jwt = create_jwt_with_alg(%{"sub" => "user_123"}, "HS512")
      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end
  end

  describe "integration with has_permission?" do
    test "works correctly with JWT-based context" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "permissions" => ["execute", "read"]
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert Context.has_permission?(ctx, :execute)
      assert Context.has_permission?(ctx, :read)
      refute Context.has_permission?(ctx, :admin)
    end
  end

  describe "integration with require_permission!" do
    test "works correctly with JWT-based context" do
      jwt = create_jwt(%{
        "sub" => "user_123",
        "permissions" => ["execute"]
      })

      {:ok, ctx} = Context.from_jwt(jwt)

      assert :ok = Context.require_permission!(ctx, :execute)

      assert_raise Sanctum.UnauthorizedError, fn ->
        Context.require_permission!(ctx, :admin)
      end
    end
  end

  describe "JWT expiration validation" do
    test "accepts JWT with future exp claim" do
      # Expires in 1 hour
      exp = System.system_time(:second) + 3600
      jwt = create_jwt(%{"sub" => "user_123", "exp" => exp})

      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end

    test "rejects JWT with past exp claim" do
      # Expired 1 hour ago
      exp = System.system_time(:second) - 3600
      jwt = create_jwt(%{"sub" => "user_123", "exp" => exp})

      assert {:error, :token_expired} = Context.from_jwt(jwt)
    end

    test "accepts JWT within clock skew tolerance" do
      # Expired 30 seconds ago (within default 60s skew)
      exp = System.system_time(:second) - 30
      jwt = create_jwt(%{"sub" => "user_123", "exp" => exp})

      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end

    test "rejects JWT beyond clock skew tolerance" do
      # Expired 120 seconds ago (beyond default 60s skew)
      exp = System.system_time(:second) - 120
      jwt = create_jwt(%{"sub" => "user_123", "exp" => exp})

      assert {:error, :token_expired} = Context.from_jwt(jwt)
    end

    test "accepts JWT without exp claim" do
      # No expiration - token doesn't expire
      jwt = create_jwt(%{"sub" => "user_123"})

      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end

    test "respects custom clock skew configuration" do
      # Set a larger clock skew
      original_skew = Application.get_env(:sanctum, :jwt_clock_skew_seconds)
      Application.put_env(:sanctum, :jwt_clock_skew_seconds, 300)

      on_exit(fn ->
        if original_skew do
          Application.put_env(:sanctum, :jwt_clock_skew_seconds, original_skew)
        else
          Application.delete_env(:sanctum, :jwt_clock_skew_seconds)
        end
      end)

      # Expired 200 seconds ago (within 300s skew)
      exp = System.system_time(:second) - 200
      jwt = create_jwt(%{"sub" => "user_123", "exp" => exp})

      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
    end
  end

  describe "session revocation validation" do
    setup do
      # Use a temp directory for revocation tests
      test_dir = Path.join(System.tmp_dir!(), "cyfr_jwt_revoke_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      original_path = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
        if original_path do
          Application.put_env(:arca, :base_path, original_path)
        else
          Application.delete_env(:arca, :base_path)
        end
      end)

      :ok
    end

    test "accepts JWT with non-revoked session_id" do
      session_id = "sess_valid_#{:rand.uniform(100_000)}"
      jwt = create_jwt(%{"sub" => "user_123", "session_id" => session_id})

      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
      assert ctx.session_id == session_id
    end

    test "rejects JWT with revoked session_id" do
      session_id = "sess_revoked_#{:rand.uniform(100_000)}"

      # Revoke the session
      :ok = Sanctum.Session.revoke(session_id)

      jwt = create_jwt(%{"sub" => "user_123", "session_id" => session_id})

      assert {:error, :session_revoked} = Context.from_jwt(jwt)
    end

    test "accepts JWT without session_id claim" do
      jwt = create_jwt(%{"sub" => "user_123"})

      {:ok, ctx} = Context.from_jwt(jwt)
      assert ctx.user_id == "user_123"
      assert ctx.session_id == nil
    end
  end

  describe "JWT key validation" do
    test "rejects short JWT signing key" do
      short_key = "short_key_only_20!"
      Application.put_env(:sanctum, :jwt_signing_key, short_key)

      jwt = "some.jwt.token"

      assert {:error, {:jwt_key_too_short, len}} = Context.from_jwt(jwt)
      assert len == byte_size(short_key)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp create_jwt(claims) do
    create_jwt_with_alg(claims, "HS256")
  end

  defp create_jwt_with_alg(claims, alg) do
    jwk = JOSE.JWK.from_oct(@test_key)
    {_, jwt} = JOSE.JWT.sign(jwk, %{"alg" => alg}, claims) |> JOSE.JWS.compact()
    jwt
  end
end
