# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.RegistryToolTest do
  use ExUnit.Case, async: false

  alias Compendium.MCP.RegistryTool
  alias Grimoire.Error

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Valid mutation arguments must reach the credential check, not the missing-argument handler.
  describe "gated identity mutations reach their handlers with valid args" do
    test "tokens_revoke", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryTool.handle(ctx, %{
                 "action" => "tokens_revoke",
                 "slug" => "someslug",
                 "token_id" => "tok_1"
               })

      assert Error.render(reason) =~ "no push token"
    end

    test "members_add", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryTool.handle(ctx, %{
                 "action" => "members_add",
                 "slug" => "someslug",
                 "target_personal_slug" => "bob",
                 "role" => "member"
               })

      assert Error.render(reason) =~ "no push token"
    end

    test "members_update", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryTool.handle(ctx, %{
                 "action" => "members_update",
                 "slug" => "someslug",
                 "target_personal_slug" => "bob",
                 "role" => "admin"
               })

      assert Error.render(reason) =~ "no push token"
    end

    test "members_remove", %{ctx: ctx} do
      assert {:error, reason} =
               RegistryTool.handle(ctx, %{
                 "action" => "members_remove",
                 "slug" => "someslug",
                 "target_personal_slug" => "bob"
               })

      assert Error.render(reason) =~ "no push token"
    end
  end

  describe "a push token that cannot be read" do
    @tag :capture_log
    test "a damaged stored token refuses as unavailable, not as 'no push token'", %{ctx: ctx} do
      registry = Compendium.RegistryHost.canonical_host()
      aad = Sanctum.CipherAAD.registry_token(ctx.user_id, registry, "damagedslug")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt("not json", aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: ctx.user_id,
          registry: registry,
          namespace_slug: "damagedslug",
          credential_ciphertext: ciphertext
        })

      assert {:error, {:unavailable, "The push token stored for namespace 'damagedslug'"}} =
               RegistryTool.handle(ctx, %{"action" => "tokens_list", "slug" => "damagedslug"})
    end

    @tag :capture_log
    test "a credential store that cannot answer refuses as unavailable", %{ctx: ctx} do
      Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

      assert {:error, {:unavailable, "Registry credentials"}} =
               RegistryTool.handle(ctx, %{"action" => "tokens_list", "slug" => "someslug"})

      assert {:error, {:unavailable, "Registry credentials"}} =
               RegistryTool.handle(ctx, %{"action" => "whoami"})
    end
  end

  describe "gated identity mutations still refuse incomplete args" do
    test "each arg-missing arm answers its own sentence", %{ctx: ctx} do
      for {action, sentence} <- [
            {"tokens_revoke", "requires 'slug' and 'token_id'"},
            {"members_add", "requires 'slug', 'target_personal_slug', and 'role'"},
            {"members_update", "requires 'slug', 'target_personal_slug', and 'role'"},
            {"members_remove", "requires 'slug' and 'target_personal_slug'"}
          ] do
        assert {:error, reason} = RegistryTool.handle(ctx, %{"action" => action}),
               "expected a refusal for bare #{action}"

        assert Error.render(reason) =~ sentence,
               "expected the arg-missing sentence for #{action}, got: #{inspect(reason)}"
      end
    end
  end
end
