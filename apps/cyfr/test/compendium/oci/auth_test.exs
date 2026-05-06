defmodule Compendium.OCI.AuthTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.Auth
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Context

  @registry "registry.test.example"
  @user "oci_auth_test_user"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    for slug <- ["alice", "stripe.com"] do
      CredentialStore.delete(@user, @registry, slug)
    end

    :ok
  end

  defp ctx do
    Context.build(
      user_id: @user,
      project_id: "default",
      permissions: [:*],
      scope: :project,
      auth_method: :local,
      namespace: "testns",
      authenticated: true
    )
  end

  describe "fetch_credential/3" do
    test "returns :anonymous when no credential is stored" do
      assert Auth.fetch_credential(@registry, "alice", ctx()) == :anonymous
    end

    test "returns :anonymous when ctx is nil (no cross-user fallback)" do
      :ok =
        CredentialStore.put(@user, @registry, "alice", %{
          type: :push_token,
          token: "cyfr_pt_fake",
          namespace: "alice"
        })

      assert Auth.fetch_credential(@registry, "alice", nil) == :anonymous
    end

    test "returns the push-token credential when one is stored for the user+namespace" do
      cred = %{
        type: :push_token,
        token: "cyfr_pt_alice_token",
        namespace: "alice",
        label: "laptop"
      }

      :ok = CredentialStore.put(@user, @registry, "alice", cred)

      assert {:ok, fetched} = Auth.fetch_credential(@registry, "alice", ctx())
      assert fetched.type == :push_token
      assert fetched.token == "cyfr_pt_alice_token"
      assert fetched.namespace == "alice"
    end

    test "scoped per-namespace: alice's token does not surface for stripe.com" do
      :ok =
        CredentialStore.put(@user, @registry, "alice", %{
          type: :push_token,
          token: "cyfr_pt_alice",
          namespace: "alice"
        })

      assert Auth.fetch_credential(@registry, "stripe.com", ctx()) == :anonymous
    end
  end

  describe "auth_headers/4" do
    test "returns empty headers when no credential exists (anonymous pull)" do
      assert {:ok, []} = Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end

    test "emits Bearer <push_token> when a push token is stored" do
      :ok =
        CredentialStore.put(@user, @registry, "alice", %{
          type: :push_token,
          token: "cyfr_pt_abc123",
          namespace: "alice"
        })

      assert {:ok, [{"authorization", "Bearer cyfr_pt_abc123"}]} =
               Auth.auth_headers(@registry, "alice/catalysts/foo", "alice", ctx())
    end
  end
end
