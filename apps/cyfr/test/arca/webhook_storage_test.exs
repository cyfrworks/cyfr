# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WebhookStorageTest do
  use ExUnit.Case, async: false

  alias Arca.WebhookStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, org_id: ctx.org_id, project_id: ctx.project_id}
  end

  defp wh_attrs(name, org_id, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        slug: "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
        target_ref: "f:local.handler",
        secret_encrypted: :crypto.strong_rand_bytes(64),
        signature_header: "x-cyfr-signature",
        input_template: "{}",
        scope_type: "project",
        org_id: org_id,
        created_by: "test_user",
        profile_id: "prof_test"
      },
      overrides
    )
  end

  describe "create_webhook/1 + get_by_name/4" do
    test "stores and retrieves a webhook", %{org_id: org_id} do
      attrs = wh_attrs("test-hook", org_id)
      assert :ok = WebhookStorage.create_webhook(attrs)

      assert {:ok, hook} = WebhookStorage.get_by_name("test-hook", "project", org_id)
      assert hook.name == "test-hook"
      assert hook.slug == attrs.slug
      assert hook.target_ref == "f:local.handler"
      assert hook.enabled == true
      assert hook.input_template == "{}"
    end

    test "returns not_found for missing webhook", %{org_id: org_id} do
      assert {:error, :not_found} = WebhookStorage.get_by_name("missing", "project", org_id)
    end

    test "duplicate name returns already_exists", %{org_id: org_id} do
      attrs = wh_attrs("dup-hook", org_id)
      :ok = WebhookStorage.create_webhook(attrs)

      assert {:error, :already_exists} = WebhookStorage.create_webhook(attrs)
    end

    test "duplicate slug returns already_exists", %{org_id: org_id} do
      attrs1 = wh_attrs("hook-a", org_id)
      attrs2 = wh_attrs("hook-b", org_id, %{slug: attrs1.slug})

      :ok = WebhookStorage.create_webhook(attrs1)
      assert {:error, :already_exists} = WebhookStorage.create_webhook(attrs2)
    end
  end

  describe "get_by_slug/1" do
    test "returns webhook regardless of tenant" do
      attrs = wh_attrs("slug-hook", "org_isolated")
      :ok = WebhookStorage.create_webhook(attrs)

      assert {:ok, hook} = WebhookStorage.get_by_slug(attrs.slug)
      assert hook.name == "slug-hook"
      assert hook.org_id == "org_isolated"
    end

    test "returns disabled webhooks too — caller must check :enabled", %{org_id: org_id} do
      attrs = wh_attrs("disabled-hook", org_id)
      :ok = WebhookStorage.create_webhook(attrs)
      :ok = WebhookStorage.set_disabled("disabled-hook", "project", org_id)

      assert {:ok, hook} = WebhookStorage.get_by_slug(attrs.slug)
      assert hook.enabled == false
    end

    test "returns not_found for unknown slug" do
      assert {:error, :not_found} = WebhookStorage.get_by_slug("wh_does_not_exist")
    end
  end

  describe "list_webhooks/3" do
    test "lists enabled webhooks within tenant scope", %{org_id: org_id} do
      :ok = WebhookStorage.create_webhook(wh_attrs("list-a", org_id))
      :ok = WebhookStorage.create_webhook(wh_attrs("list-b", org_id))

      {:ok, hooks} = WebhookStorage.list_webhooks("project", org_id)
      names = Enum.map(hooks, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "excludes disabled webhooks", %{org_id: org_id} do
      :ok = WebhookStorage.create_webhook(wh_attrs("hidden", org_id))
      :ok = WebhookStorage.set_disabled("hidden", "project", org_id)

      {:ok, hooks} = WebhookStorage.list_webhooks("project", org_id)
      refute Enum.any?(hooks, &(&1.name == "hidden"))
    end
  end

  describe "update_webhook/5" do
    test "updates input_template without rotating secret", %{org_id: org_id} do
      attrs = wh_attrs("update-me", org_id)
      :ok = WebhookStorage.create_webhook(attrs)

      assert :ok =
               WebhookStorage.update_webhook(
                 "update-me",
                 "project",
                 org_id,
                 nil,
                 %{input_template: ~s({"channel":"alerts"})}
               )

      assert {:ok, hook} = WebhookStorage.get_by_name("update-me", "project", org_id)
      assert hook.input_template == ~s({"channel":"alerts"})
      assert hook.secret_encrypted == attrs.secret_encrypted
    end

    test "rejects when no allowed fields provided", %{org_id: org_id} do
      :ok = WebhookStorage.create_webhook(wh_attrs("no-fields", org_id))

      assert {:error, :no_fields} =
               WebhookStorage.update_webhook("no-fields", "project", org_id, nil, %{
                 not_allowed: "x"
               })
    end

    test "returns not_found for missing webhook", %{org_id: org_id} do
      assert {:error, :not_found} =
               WebhookStorage.update_webhook("missing", "project", org_id, nil, %{
                 description: "x"
               })
    end
  end

  describe "set_disabled/4" do
    test "soft-disables webhook so list excludes it but slug still resolves", %{org_id: org_id} do
      attrs = wh_attrs("dis", org_id)
      :ok = WebhookStorage.create_webhook(attrs)

      assert :ok = WebhookStorage.set_disabled("dis", "project", org_id)
      assert {:error, :not_found} = WebhookStorage.get_by_name("dis", "project", org_id)
      assert {:ok, %{enabled: false}} = WebhookStorage.get_by_slug(attrs.slug)
    end

    test "returns not_found for missing webhook", %{org_id: org_id} do
      assert {:error, :not_found} = WebhookStorage.set_disabled("nope", "project", org_id)
    end
  end

  describe "rotate_secret/6" do
    test "replaces secret, retains the old one as previous within the grace window",
         %{org_id: org_id} do
      attrs = wh_attrs("rotate-me", org_id)
      :ok = WebhookStorage.create_webhook(attrs)
      old_secret = attrs.secret_encrypted

      new_secret = :crypto.strong_rand_bytes(64)
      grace_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert :ok =
               WebhookStorage.rotate_secret(
                 "rotate-me",
                 "project",
                 org_id,
                 nil,
                 new_secret,
                 grace_until
               )

      {:ok, hook} = WebhookStorage.get_by_slug(attrs.slug)
      assert hook.secret_encrypted == new_secret
      assert hook.rotated_at != nil
      # The outgoing secret is retained for the grace window.
      assert hook.previous_secret_encrypted == old_secret
      assert hook.previous_secret_expires_at != nil
    end

    test "returns not_found for missing webhook", %{org_id: org_id} do
      new_secret = :crypto.strong_rand_bytes(64)
      grace_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:error, :not_found} =
               WebhookStorage.rotate_secret(
                 "nope",
                 "project",
                 org_id,
                 nil,
                 new_secret,
                 grace_until
               )
    end
  end

  describe "tenant isolation" do
    test "different org_ids see disjoint webhooks" do
      :ok = WebhookStorage.create_webhook(wh_attrs("shared-name", "org_alpha"))
      :ok = WebhookStorage.create_webhook(wh_attrs("shared-name", "org_beta"))

      {:ok, hook_a} = WebhookStorage.get_by_name("shared-name", "project", "org_alpha")
      {:ok, hook_b} = WebhookStorage.get_by_name("shared-name", "project", "org_beta")
      assert hook_a.org_id != hook_b.org_id

      {:ok, list_a} = WebhookStorage.list_webhooks("project", "org_alpha")
      {:ok, list_b} = WebhookStorage.list_webhooks("project", "org_beta")
      assert length(list_a) == 1
      assert length(list_b) == 1
    end
  end
end
