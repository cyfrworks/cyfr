# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WebhookStorageTest do
  use ExUnit.Case, async: false

  alias Arca.WebhookStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    actor = Arca.Test.Actor.local()
    {:ok, athanor_id: actor.athanor_id}
  end

  defp wh_attrs(name, athanor_id, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        slug: "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
        target_ref: "f:local.handler",
        secret_encrypted: :crypto.strong_rand_bytes(64),
        signature_header: "x-cyfr-signature",
        input_template: "{}",
        athanor_id: athanor_id,
        created_by: "test_user",
        profile_id: "prof_test"
      },
      overrides
    )
  end

  describe "create_webhook/1 + get_by_name/2" do
    test "stores and retrieves a webhook", %{athanor_id: athanor_id} do
      attrs = wh_attrs("test-hook", athanor_id)
      assert :ok = WebhookStorage.create_webhook(attrs)

      assert {:ok, hook} =
               WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), "test-hook")

      assert hook.name == "test-hook"
      assert hook.slug == attrs.slug
      assert hook.target_ref == "f:local.handler"
      assert hook.enabled == true
      assert hook.input_template == "{}"
    end

    test "returns not_found for missing webhook", %{athanor_id: athanor_id} do
      assert {:error, :not_found} =
               WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), "missing")
    end

    test "duplicate name returns already_exists", %{athanor_id: athanor_id} do
      attrs = wh_attrs("dup-hook", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)

      assert {:error, :already_exists} = WebhookStorage.create_webhook(attrs)
    end

    test "duplicate slug returns already_exists", %{athanor_id: athanor_id} do
      attrs1 = wh_attrs("hook-a", athanor_id)
      attrs2 = wh_attrs("hook-b", athanor_id, %{slug: attrs1.slug})

      :ok = WebhookStorage.create_webhook(attrs1)
      assert {:error, :already_exists} = WebhookStorage.create_webhook(attrs2)
    end
  end

  describe "get_by_slug/1" do
    test "returns webhook regardless of tenant" do
      attrs = wh_attrs("slug-hook", "ath_isolated")
      :ok = WebhookStorage.create_webhook(attrs)

      assert {:ok, hook} = WebhookStorage.get_by_slug(attrs.slug)
      assert hook.name == "slug-hook"
      assert hook.athanor_id == "ath_isolated"
    end

    test "returns disabled webhooks too — caller must check :enabled",
         %{athanor_id: athanor_id} do
      attrs = wh_attrs("disabled-hook", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)
      :ok = WebhookStorage.set_disabled(Prima.Actor.in_athanor(athanor_id), "disabled-hook")

      assert {:ok, hook} = WebhookStorage.get_by_slug(attrs.slug)
      assert hook.enabled == false
    end

    test "returns not_found for unknown slug" do
      assert {:error, :not_found} = WebhookStorage.get_by_slug("wh_does_not_exist")
    end
  end

  describe "list_webhooks/3" do
    test "lists enabled webhooks within tenant scope", %{athanor_id: athanor_id} do
      :ok = WebhookStorage.create_webhook(wh_attrs("list-a", athanor_id))
      :ok = WebhookStorage.create_webhook(wh_attrs("list-b", athanor_id))

      {:ok, hooks} = WebhookStorage.list_webhooks(Prima.Actor.in_athanor(athanor_id))
      names = Enum.map(hooks, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "excludes disabled webhooks", %{athanor_id: athanor_id} do
      :ok = WebhookStorage.create_webhook(wh_attrs("hidden", athanor_id))
      :ok = WebhookStorage.set_disabled(Prima.Actor.in_athanor(athanor_id), "hidden")

      {:ok, hooks} = WebhookStorage.list_webhooks(Prima.Actor.in_athanor(athanor_id))
      refute Enum.any?(hooks, &(&1.name == "hidden"))
    end
  end

  describe "update_webhook/3" do
    test "updates input_template without rotating secret", %{athanor_id: athanor_id} do
      attrs = wh_attrs("update-me", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)

      assert :ok =
               WebhookStorage.update_webhook(Prima.Actor.in_athanor(athanor_id), "update-me", %{
                 input_template: ~s({"channel":"alerts"})
               })

      assert {:ok, hook} =
               WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), "update-me")

      assert hook.input_template == ~s({"channel":"alerts"})
      assert hook.secret_encrypted == attrs.secret_encrypted
    end

    test "rejects when no allowed fields provided", %{athanor_id: athanor_id} do
      :ok = WebhookStorage.create_webhook(wh_attrs("no-fields", athanor_id))

      assert {:error, :no_fields} =
               WebhookStorage.update_webhook(Prima.Actor.in_athanor(athanor_id), "no-fields", %{
                 not_allowed: "x"
               })
    end

    test "returns not_found for missing webhook", %{athanor_id: athanor_id} do
      assert {:error, :not_found} =
               WebhookStorage.update_webhook(Prima.Actor.in_athanor(athanor_id), "missing", %{
                 description: "x"
               })
    end
  end

  describe "set_disabled/4" do
    test "soft-disables webhook so list excludes it but slug still resolves",
         %{athanor_id: athanor_id} do
      attrs = wh_attrs("dis", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)

      assert :ok = WebhookStorage.set_disabled(Prima.Actor.in_athanor(athanor_id), "dis")

      assert {:error, :not_found} =
               WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), "dis")

      assert {:ok, %{enabled: false}} = WebhookStorage.get_by_slug(attrs.slug)
    end

    test "returns not_found for missing webhook", %{athanor_id: athanor_id} do
      assert {:error, :not_found} =
               WebhookStorage.set_disabled(Prima.Actor.in_athanor(athanor_id), "nope")
    end
  end

  describe "disable_all/2" do
    test "disables the actor's enabled hooks among the ids, and answers them", %{
      athanor_id: athanor_id
    } do
      actor = Prima.Actor.in_athanor(athanor_id)
      a = wh_attrs("all-a", athanor_id)
      b = wh_attrs("all-b", athanor_id)
      done = wh_attrs("all-done", athanor_id)
      kept = wh_attrs("all-kept", athanor_id)
      theirs = wh_attrs("all-theirs", "ath_b")
      for attrs <- [a, b, done, kept, theirs], do: :ok = WebhookStorage.create_webhook(attrs)
      :ok = WebhookStorage.set_disabled(actor, "all-done")

      ids =
        for attrs <- [a, b, done, theirs] do
          {:ok, row} = WebhookStorage.get_by_slug(attrs.slug)
          row.id
        end

      assert {:ok, disabled} = WebhookStorage.disable_all(actor, ids)
      assert Enum.sort(disabled) == Enum.sort(Enum.take(ids, 2))

      assert {:ok, %{enabled: false}} = WebhookStorage.get_by_slug(a.slug)
      assert {:ok, %{enabled: false}} = WebhookStorage.get_by_slug(b.slug)
      assert {:ok, %{enabled: true}} = WebhookStorage.get_by_slug(kept.slug)
      assert {:ok, %{enabled: true}} = WebhookStorage.get_by_slug(theirs.slug)
    end

    test "an actor with no athanor is refused before any query" do
      assert {:error, :no_athanor} = WebhookStorage.disable_all(%Prima.Actor{}, ["whk_x"])
    end

    @tag :capture_log
    test "a store that cannot answer is a database error", %{athanor_id: athanor_id} do
      Arca.Repo.query!("ALTER TABLE webhooks RENAME TO webhooks_unavailable")

      assert {:error, :database_error} =
               WebhookStorage.disable_all(Prima.Actor.in_athanor(athanor_id), ["whk_x"])
    end
  end

  describe "rotate_secret/4" do
    test "replaces secret, retains the old one as previous within the grace window",
         %{athanor_id: athanor_id} do
      attrs = wh_attrs("rotate-me", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)
      old_secret = attrs.secret_encrypted

      new_secret = :crypto.strong_rand_bytes(64)
      grace_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert :ok =
               WebhookStorage.rotate_secret(
                 Prima.Actor.in_athanor(athanor_id),
                 "rotate-me",
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

    test "returns not_found for missing webhook", %{athanor_id: athanor_id} do
      new_secret = :crypto.strong_rand_bytes(64)
      grace_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:error, :not_found} =
               WebhookStorage.rotate_secret(
                 Prima.Actor.in_athanor(athanor_id),
                 "nope",
                 new_secret,
                 grace_until
               )
    end
  end

  describe "tenant isolation" do
    test "different athanors see disjoint webhooks" do
      :ok = WebhookStorage.create_webhook(wh_attrs("shared-name", "ath_alpha"))
      :ok = WebhookStorage.create_webhook(wh_attrs("shared-name", "ath_beta"))

      {:ok, hook_a} =
        WebhookStorage.get_by_name(Prima.Actor.in_athanor("ath_alpha"), "shared-name")

      {:ok, hook_b} =
        WebhookStorage.get_by_name(Prima.Actor.in_athanor("ath_beta"), "shared-name")

      assert hook_a.athanor_id != hook_b.athanor_id

      {:ok, list_a} = WebhookStorage.list_webhooks(Prima.Actor.in_athanor("ath_alpha"))
      {:ok, list_b} = WebhookStorage.list_webhooks(Prima.Actor.in_athanor("ath_beta"))
      assert length(list_a) == 1
      assert length(list_b) == 1
    end
  end

  # A declared restore suspends every webhook; these put one in that state
  # the way the transition leaves it.
  defp suspend!(athanor_id, name) do
    import Ecto.Query

    {1, _} =
      from(w in Arca.Schemas.Webhook, where: w.athanor_id == ^athanor_id and w.name == ^name)
      |> Arca.Repo.update_all(set: [suspended: true])

    {:ok, hook} = WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), name)
    hook
  end

  defp stored(id), do: Arca.Repo.get!(Arca.Schemas.Webhook, id)

  describe "a suspended webhook" do
    test "is no ingress lookup's, and is listed with its flag", %{athanor_id: athanor_id} do
      attrs = wh_attrs("held", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)
      hook = suspend!(athanor_id, "held")

      assert hook.suspended == true
      assert {:error, :not_found} = WebhookStorage.get_by_slug(attrs.slug)

      assert {:ok, [%{name: "held", suspended: true}]} =
               WebhookStorage.list_webhooks(Prima.Actor.in_athanor(athanor_id))
    end
  end

  describe "reenable/4" do
    setup %{athanor_id: athanor_id} do
      attrs = wh_attrs("held", athanor_id)
      :ok = WebhookStorage.create_webhook(attrs)

      %{
        attrs: attrs,
        hook: suspend!(athanor_id, "held"),
        actor: Prima.Actor.in_athanor(athanor_id)
      }
    end

    test "writes the person's suspended webhook back after verify agrees, without its secrets",
         %{attrs: attrs, hook: hook, actor: actor} do
      parent = self()

      verify = fn row ->
        send(parent, {:verified, row})
        :ok
      end

      assert {:ok, reenabled} =
               WebhookStorage.reenable(actor, "test_user", hook.id, verify: verify)

      assert %{suspended: false, enabled: true} = reenabled
      assert reenabled.id == hook.id
      refute Map.has_key?(reenabled, :secret_encrypted)
      refute Map.has_key?(reenabled, :previous_secret_encrypted)

      assert_received {:verified, %{suspended: true} = seen}
      refute Map.has_key?(seen, :secret_encrypted)

      assert %{suspended: false} = stored(hook.id)
      assert {:ok, %{name: "held"}} = WebhookStorage.get_by_slug(attrs.slug)
    end

    test "a verify refusal rolls back and is the answer", %{
      attrs: attrs,
      hook: hook,
      actor: actor
    } do
      assert {:error, :not_standing} =
               WebhookStorage.reenable(actor, "test_user", hook.id,
                 verify: fn _ -> {:error, :not_standing} end
               )

      assert %{suspended: true} = stored(hook.id)
      assert {:error, :not_found} = WebhookStorage.get_by_slug(attrs.slug)
    end

    test "another person's webhook, another athanor's or an unknown id is not found", %{
      hook: hook,
      actor: actor
    } do
      never = fn _ -> flunk("verify asked for a webhook that is not the person's") end

      assert {:error, :not_found} =
               WebhookStorage.reenable(actor, "someone_else", hook.id, verify: never)

      assert {:error, :not_found} =
               WebhookStorage.reenable(Prima.Actor.in_athanor("ath_other"), "test_user", hook.id,
                 verify: never
               )

      assert {:error, :not_found} =
               WebhookStorage.reenable(actor, "test_user", "whk_unknown", verify: never)

      assert {:error, :no_athanor} =
               WebhookStorage.reenable(Prima.Actor.system(), "test_user", hook.id, verify: never)

      assert %{suspended: true} = stored(hook.id)
    end

    test "a disabled webhook is never revived, and a standing one is not suspended", %{
      athanor_id: athanor_id,
      hook: hook,
      actor: actor
    } do
      never = fn _ -> flunk("verify asked for a webhook that cannot be re-enabled") end
      :ok = WebhookStorage.set_disabled(actor, "held")

      assert {:error, :revoked} =
               WebhookStorage.reenable(actor, "test_user", hook.id, verify: never)

      assert %{enabled: false, suspended: true} = stored(hook.id)

      :ok = WebhookStorage.create_webhook(wh_attrs("live", athanor_id))
      {:ok, live} = WebhookStorage.get_by_name(actor, "live")

      assert {:error, :not_suspended} =
               WebhookStorage.reenable(actor, "test_user", live.id, verify: never)
    end
  end

  describe "get_created_webhook/3" do
    test "reads the person's own webhook in any state, without secrets, and no one else's", %{
      athanor_id: athanor_id
    } do
      :ok = WebhookStorage.create_webhook(wh_attrs("mine", athanor_id))
      actor = Prima.Actor.in_athanor(athanor_id)
      {:ok, hook} = WebhookStorage.get_by_name(actor, "mine")
      :ok = WebhookStorage.set_disabled(actor, "mine")

      assert {:ok, %{enabled: false, suspended: false} = read} =
               WebhookStorage.get_created_webhook(actor, "test_user", hook.id)

      refute Map.has_key?(read, :secret_encrypted)
      assert {:error, :not_found} = WebhookStorage.get_created_webhook(actor, "other", hook.id)
    end
  end
end
