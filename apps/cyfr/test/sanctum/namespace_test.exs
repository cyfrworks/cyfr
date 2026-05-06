defmodule Sanctum.NamespaceTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore
  alias Sanctum.Namespace

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  describe "lookup/1" do
    test "returns nil for nil input" do
      assert Namespace.lookup(nil) == nil
    end

    test "returns nil for empty string" do
      assert Namespace.lookup("") == nil
    end

    test "returns nil for non-binary input" do
      assert Namespace.lookup(123) == nil
      assert Namespace.lookup(:atom) == nil
    end

    test "returns nil when user has no credentials" do
      assert Namespace.lookup("user_with_no_creds_#{System.unique_integer([:positive])}") == nil
    end

    test "returns the slug when a personal-namespace credential exists" do
      user_id = "ns_test_#{System.unique_integer([:positive])}"
      registry = Compendium.Edition.cyfr_run_registry()

      :ok =
        CredentialStore.put(user_id, registry, "alice", %{
          type: :push_token,
          token: "cyfr_pt_test",
          namespace: "alice",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert Namespace.lookup(user_id) == "alice"
    end

    test "ignores publisher slugs (containing dot)" do
      user_id = "ns_test_pub_#{System.unique_integer([:positive])}"
      registry = Compendium.Edition.cyfr_run_registry()

      :ok =
        CredentialStore.put(user_id, registry, "stripe.com", %{
          type: :push_token,
          token: "cyfr_pt_pub",
          namespace: "stripe.com",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert Namespace.lookup(user_id) == nil
    end

    test "rejects malformed slugs that don't match the regex (defense-in-depth)" do
      user_id = "ns_test_bad_#{System.unique_integer([:positive])}"
      registry = Compendium.Edition.cyfr_run_registry()

      # Inject a slug that bypasses the dot check but contains path-unsafe
      # characters. cyfr.run server-side validation would never accept this,
      # but a corrupted CredentialStore row should be rejected here too.
      :ok =
        CredentialStore.put(user_id, registry, "../../etc-passwd", %{
          type: :push_token,
          token: "cyfr_pt_evil",
          namespace: "../../etc-passwd",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert Namespace.lookup(user_id) == nil
    end

    test "rejects slugs with uppercase / underscores / leading hyphens / whitespace" do
      registry = Compendium.Edition.cyfr_run_registry()
      bad_slugs = ["Alice", "_system", "foo_bar", "-leading", "trailing-", "with space"]

      for bad <- bad_slugs do
        user_id = "ns_test_bad_#{System.unique_integer([:positive])}"

        :ok =
          CredentialStore.put(user_id, registry, bad, %{
            type: :push_token,
            token: "cyfr_pt_bad",
            namespace: bad,
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        assert Namespace.lookup(user_id) == nil,
               "expected lookup to reject malformed slug #{inspect(bad)}"
      end
    end
  end
end
