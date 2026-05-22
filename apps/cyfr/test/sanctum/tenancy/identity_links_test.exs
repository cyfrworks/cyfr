# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.IdentityLinksTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{IdentityLink, IdentityLinks}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    :ok
  end

  defp valid_link_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "oidcc|https://okta.example.com|" <> Ecto.UUID.generate(),
        provider: "github",
        provider_subject: "12345678"
      },
      overrides
    )
  end

  describe "create/1" do
    test "creates a link with auto-generated id and linked_at" do
      assert {:ok, link} = IdentityLinks.create(valid_link_attrs())
      assert String.starts_with?(link.id, "lnk_")
      assert link.provider == "github"
      assert link.linked_at != nil
    end

    test "accepts google provider" do
      assert {:ok, link} = IdentityLinks.create(valid_link_attrs(%{provider: "google"}))
      assert link.provider == "google"
    end

    test "rejects invalid provider" do
      assert {:error, changeset} =
               IdentityLinks.create(valid_link_attrs(%{provider: "microsoft"}))

      assert %{provider: [_ | _]} = errors_on(changeset)
    end

    test "rejects duplicate (user_id, provider) pair" do
      attrs = valid_link_attrs()
      assert {:ok, _} = IdentityLinks.create(attrs)
      assert {:error, changeset} = IdentityLinks.create(attrs)
      assert %{user_id: [_ | _]} = errors_on(changeset)
    end

    test "same user + different provider succeeds" do
      user_id = "oidcc|https://okta.example.com|" <> Ecto.UUID.generate()
      assert {:ok, _} = IdentityLinks.create(valid_link_attrs(%{user_id: user_id, provider: "github"}))
      assert {:ok, _} = IdentityLinks.create(valid_link_attrs(%{user_id: user_id, provider: "google"}))
    end

    test "stores access_token_ciphertext opaquely" do
      ciphertext = :crypto.strong_rand_bytes(48)
      attrs = valid_link_attrs(%{access_token_ciphertext: ciphertext})
      assert {:ok, link} = IdentityLinks.create(attrs)
      assert link.access_token_ciphertext == ciphertext
    end
  end

  describe "get/2" do
    test "returns the link when present" do
      attrs = valid_link_attrs()
      {:ok, link} = IdentityLinks.create(attrs)
      assert {:ok, %IdentityLink{} = found} = IdentityLinks.get(attrs.user_id, attrs.provider)
      assert found.id == link.id
    end

    test "returns not_found when absent" do
      assert {:error, :not_found} = IdentityLinks.get("oidcc|https://nope|x", "github")
    end
  end

  describe "list_by_user/2" do
    test "lists a user's links across providers ordered by linked_at desc" do
      user_id = "oidcc|https://okta.example.com|" <> Ecto.UUID.generate()
      {:ok, first} = IdentityLinks.create(valid_link_attrs(%{user_id: user_id, provider: "github"}))
      # Ensure linked_at is strictly later for the second row.
      Process.sleep(5)
      {:ok, second} = IdentityLinks.create(valid_link_attrs(%{user_id: user_id, provider: "google"}))

      assert [a, b] = IdentityLinks.list_by_user(user_id)
      assert a.id == second.id
      assert b.id == first.id
    end

    test "returns empty list for unknown user" do
      assert [] = IdentityLinks.list_by_user("oidcc|https://nope|nobody")
    end
  end

  describe "delete/1" do
    test "removes the row" do
      attrs = valid_link_attrs()
      {:ok, link} = IdentityLinks.create(attrs)
      assert {:ok, _} = IdentityLinks.delete(link)
      assert {:error, :not_found} = IdentityLinks.get(attrs.user_id, attrs.provider)
    end
  end

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
