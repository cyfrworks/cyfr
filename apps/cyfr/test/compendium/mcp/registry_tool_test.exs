# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.RegistryToolTest do
  use ExUnit.Case, async: false

  alias Compendium.MCP.RegistryTool
  alias Cyfr.Ops.Error

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
