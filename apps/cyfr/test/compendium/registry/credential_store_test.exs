defmodule Compendium.Registry.CredentialStoreTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore

  @reg "registry.test.com"
  @other_reg "other.registry.com"
  @user "test_user_1"
  @user2 "test_user_2"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Clean up any namespace slots from prior runs.
    for user <- [@user, @user2],
        reg <- [@reg, @other_reg],
        slug <- ["alice", "bob", "stripe.com"] do
      CredentialStore.delete(user, reg, slug)
    end

    :ok
  end

  defp push_token_cred(slug) do
    %{
      type: :push_token,
      token: "cyfr_pt_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}",
      namespace: slug,
      issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      label: "test-host"
    }
  end

  describe "put/4 + get/3" do
    test "stores and retrieves a push-token credential keyed by namespace" do
      cred = push_token_cred("alice")

      assert :ok = CredentialStore.put(@user, @reg, "alice", cred)

      assert {:ok, retrieved} = CredentialStore.get(@user, @reg, "alice")
      assert retrieved.type == :push_token
      assert retrieved.token == cred.token
      assert retrieved.namespace == "alice"
      assert retrieved.label == "test-host"
    end

    test "namespaces under the same user are independent slots" do
      alice_cred = push_token_cred("alice")
      stripe_cred = push_token_cred("stripe.com")

      assert :ok = CredentialStore.put(@user, @reg, "alice", alice_cred)
      assert :ok = CredentialStore.put(@user, @reg, "stripe.com", stripe_cred)

      assert {:ok, %{token: a}} = CredentialStore.get(@user, @reg, "alice")
      assert {:ok, %{token: s}} = CredentialStore.get(@user, @reg, "stripe.com")
      assert a == alice_cred.token
      assert s == stripe_cred.token
    end

    test "overwrites an existing credential on re-put" do
      first = push_token_cred("alice")
      second = push_token_cred("alice")

      assert :ok = CredentialStore.put(@user, @reg, "alice", first)
      assert :ok = CredentialStore.put(@user, @reg, "alice", second)

      assert {:ok, retrieved} = CredentialStore.get(@user, @reg, "alice")
      assert retrieved.token == second.token
    end

    test "returns :not_found for missing slot" do
      assert :not_found = CredentialStore.get(@user, @reg, "nonexistent")
    end
  end

  describe "user + registry isolation" do
    test "different users have separate credentials for the same namespace" do
      a = push_token_cred("alice")
      b = push_token_cred("alice")

      assert :ok = CredentialStore.put(@user, @reg, "alice", a)
      assert :ok = CredentialStore.put(@user2, @reg, "alice", b)

      assert {:ok, %{token: ta}} = CredentialStore.get(@user, @reg, "alice")
      assert {:ok, %{token: tb}} = CredentialStore.get(@user2, @reg, "alice")
      assert ta != tb
    end

    test "different registries have separate credentials for the same slot" do
      r1 = push_token_cred("alice")
      r2 = push_token_cred("alice")

      assert :ok = CredentialStore.put(@user, @reg, "alice", r1)
      assert :ok = CredentialStore.put(@user, @other_reg, "alice", r2)

      assert {:ok, %{token: t1}} = CredentialStore.get(@user, @reg, "alice")
      assert {:ok, %{token: t2}} = CredentialStore.get(@user, @other_reg, "alice")
      assert t1 != t2
    end
  end

  describe "list_for_user/2" do
    test "returns empty list when the user has no credentials" do
      assert [] = CredentialStore.list_for_user("unknown_user", @reg)
    end

    test "personal-first ordering, then publishers alphabetical" do
      for slug <- ["alice", "stripe.com", "bob"] do
        cred = push_token_cred(slug)
        assert :ok = CredentialStore.put(@user, @reg, slug, cred)
      end

      # All three are personal (no dot) except stripe.com.
      # Personal+reserved bucket sorted alphabetically, then publisher bucket.
      list = CredentialStore.list_for_user(@user, @reg)
      assert length(list) == 3

      slugs = Enum.map(list, & &1.namespace)
      # alice (personal), bob (personal), then stripe.com (publisher)
      assert slugs == ["alice", "bob", "stripe.com"]
    end

    test "does not leak credentials from other users" do
      assert :ok = CredentialStore.put(@user, @reg, "alice", push_token_cred("alice"))
      assert :ok = CredentialStore.put(@user2, @reg, "bob", push_token_cred("bob"))

      list = CredentialStore.list_for_user(@user, @reg)
      assert Enum.map(list, & &1.namespace) == ["alice"]
    end
  end

  describe "delete/3" do
    test "removes a single namespace slot without touching siblings" do
      assert :ok = CredentialStore.put(@user, @reg, "alice", push_token_cred("alice"))
      assert :ok = CredentialStore.put(@user, @reg, "stripe.com", push_token_cred("stripe.com"))

      assert :ok = CredentialStore.delete(@user, @reg, "alice")
      assert :not_found = CredentialStore.get(@user, @reg, "alice")
      assert {:ok, _} = CredentialStore.get(@user, @reg, "stripe.com")
    end

    test "delete is idempotent" do
      assert :ok = CredentialStore.delete(@user, @reg, "never-existed")
    end
  end

  describe "multi-user privacy (auth_refactor.md done-when #20)" do
    test "user B asking for user A's namespace gets :not_found, not A's token" do
      # User A holds a personal-namespace push token for "alice".
      a_cred = push_token_cred("alice")
      assert :ok = CredentialStore.put(@user, @reg, "alice", a_cred)

      # User B has no credential for "alice" on this registry. The pre-refactor
      # `get_for_registry/1` cross-user fallback would have leaked A's token to
      # B; post-refactor, get/3 must return :not_found so callers surface
      # `:no_push_token` and prompt B to log in / claim. Privacy guarantee.
      assert :not_found = CredentialStore.get(@user2, @reg, "alice")
    end

    test "user B's has_personal? is false even when user A has claimed" do
      assert :ok = CredentialStore.put(@user, @reg, "alice", push_token_cred("alice"))

      assert CredentialStore.has_personal?(@user, @reg) == true
      assert CredentialStore.has_personal?(@user2, @reg) == false
    end
  end

  describe "has_personal?/2" do
    test "true when user holds any bare-slug credential" do
      assert :ok = CredentialStore.put(@user, @reg, "alice", push_token_cred("alice"))
      assert CredentialStore.has_personal?(@user, @reg) == true
    end

    test "false when user holds only publisher (dotted) credentials" do
      assert :ok = CredentialStore.put(@user, @reg, "stripe.com", push_token_cred("stripe.com"))
      assert CredentialStore.has_personal?(@user, @reg) == false
    end

    test "false when user holds no credentials" do
      assert CredentialStore.has_personal?(@user, @reg) == false
    end
  end
end
