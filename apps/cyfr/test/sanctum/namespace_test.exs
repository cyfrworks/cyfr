# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NamespaceTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.CredentialStore
  alias Sanctum.Namespace
  alias Sanctum.Tenancy.Users

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp person(namespace \\ nil) do
    n = System.unique_integer([:positive])
    id = "github|https://github.com|ns-#{n}"

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: id,
        provider: "github",
        email: "ns#{n}@example.com",
        verified: true
      })

    if is_binary(namespace) do
      # Written straight to the row: the rule is re-checked on read.
      {:ok, _} = user |> Ecto.Changeset.change(namespace: namespace) |> Arca.Repo.update()
    end

    id
  end

  describe "lookup/1" do
    test "returns nil for nil / empty / non-binary input" do
      assert Namespace.lookup(nil) == nil
      assert Namespace.lookup("") == nil
      assert Namespace.lookup(123) == nil
      assert Namespace.lookup(:atom) == nil
    end

    test "returns nil for an unknown person and for one whose row records no namespace" do
      assert Namespace.lookup("github|https://github.com|nobody-#{System.unique_integer()}") ==
               nil

      assert Namespace.lookup(person()) == nil
    end

    test "returns the slug the users row records — push tokens are not consulted" do
      user_id = person("alice")
      assert Namespace.lookup(user_id) == "alice"

      # A push-token row under another slug changes nothing: identity is the
      # users row, tokens are for pushing.
      registry = Compendium.Registry.canonical_host()

      :ok =
        CredentialStore.put_push_token(user_id, registry, "stripe.com", "cyfr_pt_pub", "member")

      Namespace.invalidate(user_id)
      assert Namespace.lookup(user_id) == "alice"

      # And losing every token loses nothing.
      :ok = CredentialStore.delete(user_id, registry, "stripe.com")
      Namespace.invalidate(user_id)
      assert Namespace.lookup(user_id) == "alice"
    end

    test "rejects a recorded slug that does not satisfy the personal-slug rule (defense-in-depth)" do
      for bad <- ["../../etc-passwd", "Alice", "_system", "foo_bar", "-leading", "trailing-"] do
        assert Namespace.lookup(person(bad)) == nil,
               "expected lookup to reject malformed slug #{inspect(bad)}"
      end
    end

    test "a claim recorded through Users.set_namespace/2 is visible at once" do
      user_id = person()
      assert Namespace.lookup(user_id) == nil
      {:ok, user} = Users.get(user_id)
      {:ok, _} = Users.set_namespace(user, "carol")
      assert Namespace.lookup(user_id) == "carol"
    end
  end

  describe "lookup_status/1 (transient store error vs unclaimed)" do
    test ":not_claimed for an unknown person, a row without a namespace, and bad input" do
      assert Namespace.lookup_status("github|https://github.com|none-#{System.unique_integer()}") ==
               :not_claimed

      assert Namespace.lookup_status(person()) == :not_claimed
      assert Namespace.lookup_status(nil) == :not_claimed
      assert Namespace.lookup_status("") == :not_claimed
      assert Namespace.lookup_status(123) == :not_claimed
    end

    test "{:ok, slug} when the row records one" do
      assert {:ok, "bob"} = Namespace.lookup_status(person("bob"))
    end

    # The third outcome — {:error, reason} for a TRANSIENT store failure
    # (distinct from :not_claimed) — is exercised end-to-end by
    # Arca.AuditHandlerTest, where a DBConnection.OwnershipError from an
    # un-owned process is rescued into {:error, _} (and collapsed to nil by
    # lookup/1). It cannot be induced here under this module's
    # {:shared, self()} sandbox.
  end
end
