defmodule Compendium.Registry.IdentityTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.{CredentialStore, Identity}
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Clean up test credentials from prior runs
    CredentialStore.delete("identity_test_user", "registry.cyfr.run")

    ctx =
      Context.build(
        user_id: "identity_test_user",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :local,
        authenticated: true
      )

    {:ok, ctx: ctx}
  end

  describe "identity/1" do
    test "returns unauthenticated when no credentials exist", %{ctx: ctx} do
      result = Identity.identity(ctx)
      assert result.authenticated == false
    end

    test "resolves credentials from CredentialStore", %{ctx: ctx} do
      # Store credentials in CredentialStore
      CredentialStore.put("identity_test_user", "registry.cyfr.run", %{
        type: :basic,
        username: "test@example.com",
        password: "fake_jwt_token"
      })

      # identity/1 will try to call the registry with the fake token.
      # This proves credential resolution is working since we get a specific
      # error (invalid_credentials/unreachable/error) rather than just
      # unauthenticated with no reason (which means no credentials were found).
      result = Identity.identity(ctx)
      assert result.authenticated == false
      assert result.reason in ["invalid_credentials", "unreachable", "error"]
    end
  end

  describe "error handling" do
    test "handles errors gracefully", %{ctx: ctx} do
      result = Identity.identity(ctx)
      # Should not raise, should return a map
      assert is_map(result)
      assert Map.has_key?(result, :authenticated)
    end
  end
end
