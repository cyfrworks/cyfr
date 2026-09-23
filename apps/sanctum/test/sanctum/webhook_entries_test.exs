# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.WebhookEntriesTest do
  # The two webhook entries above Sanctum: the ingress lookup a delivery's
  # slug makes before any caller is known, and the removal cascade's
  # disable. Rows are written past `create/2`, which asks the component
  # domain whether the target exists, and this suite has none.
  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.Webhook

  @target "reagent:local.hook-target"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {ctx, other} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: ctx, other: other}
  end

  defp seal(ctx, name, secret),
    do: elem(Sanctum.Cipher.encrypt(secret, CipherAAD.webhook_secret(ctx.athanor_id, name)), 1)

  defp hook!(ctx, name, opts \\ []) do
    slug = "wh_" <> name <> "_#{System.unique_integer([:positive])}"
    secret = "whsec_" <> name

    :ok =
      Arca.WebhookStorage.create_webhook(%{
        name: name,
        slug: slug,
        target_ref: Keyword.get(opts, :target_ref, @target <> ":1.0.0"),
        secret_encrypted: Keyword.get(opts, :secret_encrypted, seal(ctx, name, secret)),
        athanor_id: ctx.athanor_id,
        profile_id: "prof_fixture",
        created_by: ctx.user_id
      })

    {:ok, row} = Arca.WebhookStorage.get_by_slug(slug)
    %{slug: slug, secret: secret, id: row.id, name: name}
  end

  defp sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp outage!, do: Arca.Repo.query!("ALTER TABLE webhooks RENAME TO webhooks_unavailable")

  # With no keyring, any decryption raises: a call that returns without one
  # decrypted nothing.
  defp without_keyring(fun) do
    keyring = Application.fetch_env!(:sanctum, :crypto_keyring)
    Application.delete_env(:sanctum, :crypto_keyring)

    try do
      fun.()
    after
      Application.put_env(:sanctum, :crypto_keyring, keyring)
    end
  end

  # A store that refuses to disable one row, mid-statement: the write fails
  # after it has begun, the way an outage partway through would.
  defp refuse_disabling!(name) do
    case Arca.Repo.adapter() do
      Ecto.Adapters.Postgres ->
        Arca.Repo.query!("""
        CREATE FUNCTION refuse_disabling() RETURNS trigger AS $$
        BEGIN
          IF OLD.name = '#{name}' THEN RAISE EXCEPTION 'refused'; END IF;
          RETURN NEW;
        END $$ LANGUAGE plpgsql
        """)

        Arca.Repo.query!(
          "CREATE TRIGGER refuse_disabling BEFORE UPDATE ON webhooks " <>
            "FOR EACH ROW EXECUTE FUNCTION refuse_disabling()"
        )

      Ecto.Adapters.SQLite3 ->
        Arca.Repo.query!(
          "CREATE TRIGGER refuse_disabling BEFORE UPDATE ON webhooks " <>
            "WHEN OLD.name = '#{name}' BEGIN SELECT RAISE(ABORT, 'refused'); END"
        )
    end
  end

  describe "resolve_ingress/1" do
    test "an enabled hook carries its secret opened, and never printable", %{ctx: ctx} do
      %{slug: slug, secret: secret} = hook!(ctx, "opened")

      assert {:ok, row} = Webhook.resolve_ingress(slug)
      assert row.enabled == true
      assert row.athanor_id == ctx.athanor_id
      refute Map.has_key?(row, :secret_encrypted)
      refute Map.has_key?(row, :previous_secret_encrypted)

      assert %{current: ^secret, previous: nil} = row.signing_secrets.()
      refute inspect(row) =~ secret

      assert :ok = Webhook.verify_with_grace(row, "{}", sign(secret, "{}"))

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(row, "{}", sign("whsec_wrong", "{}"))
    end

    test "nothing is decrypted at the lookup; the secrets open when called", %{ctx: ctx} do
      %{slug: slug, secret: secret} = hook!(ctx, "lazy")

      assert {:ok, row} = without_keyring(fn -> Webhook.resolve_ingress(slug) end)
      assert is_function(row.signing_secrets, 0)

      assert %{current: ^secret} = row.signing_secrets.()
    end

    test "a disabled hook is found, marked disabled, and carries no secret", %{ctx: ctx} do
      %{slug: slug} = hook!(ctx, "disabled")
      :ok = Arca.WebhookStorage.set_disabled(Sanctum.Context.actor(ctx), "disabled")

      assert {:ok, %{enabled: false} = row} = Webhook.resolve_ingress(slug)
      refute Map.has_key?(row, :signing_secrets)
      refute Map.has_key?(row, :secret_encrypted)
    end

    test "an unknown slug is absent" do
      assert {:error, :not_found} = Webhook.resolve_ingress("wh_nobody")
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable, never absent", %{ctx: ctx} do
      %{slug: slug} = hook!(ctx, "outage")
      outage!()

      assert {:error, :unavailable} = Webhook.resolve_ingress(slug)
    end

    test "a secret that does not open is unreadable, not a signature failure", %{ctx: ctx} do
      # Sealed for another tenant: the row's own AAD does not open it.
      foreign = elem(Sanctum.Cipher.encrypt("whsec_x", CipherAAD.webhook_secret("ath_b", "x")), 1)
      %{slug: slug} = hook!(ctx, "damaged", secret_encrypted: foreign)

      assert {:ok, row} = Webhook.resolve_ingress(slug)
      assert %{current: :unreadable} = row.signing_secrets.()

      assert {:error, :secret_unreadable} =
               Webhook.verify_with_grace(row, "{}", sign("whsec_x", "{}"))

      # A delivery that is malformed is still reported as malformed.
      assert {:error, :malformed_signature} = Webhook.verify_with_grace(row, "{}", "nope")
    end

    test "the outgoing secret verifies through its grace window and not after", %{ctx: ctx} do
      %{slug: slug, secret: old} = hook!(ctx, "rotating")
      actor = Sanctum.Context.actor(ctx)
      later = DateTime.add(DateTime.utc_now(), 3600, :second)

      :ok = Arca.WebhookStorage.rotate_secret(actor, "rotating", seal(ctx, "rotating", "whsec_new"), later)

      assert {:ok, row} = Webhook.resolve_ingress(slug)
      assert %{current: "whsec_new", previous: ^old} = row.signing_secrets.()
      assert :ok = Webhook.verify_with_grace(row, "{}", sign("whsec_new", "{}"))
      assert :ok = Webhook.verify_with_grace(row, "{}", sign(old, "{}"))

      earlier = DateTime.add(DateTime.utc_now(), -1, :second)
      :ok = Arca.WebhookStorage.rotate_secret(actor, "rotating", seal(ctx, "rotating", "whsec_3"), earlier)

      assert {:ok, row} = Webhook.resolve_ingress(slug)
      assert %{current: "whsec_3", previous: nil} = row.signing_secrets.()

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(row, "{}", sign("whsec_new", "{}"))
    end
  end

  describe "disable_for_component/2" do
    test "disables the caller's hooks on the component at any version, and no others",
         %{ctx: ctx, other: other} do
      pinned = hook!(ctx, "pinned")
      versionless = hook!(ctx, "versionless", target_ref: @target)
      elsewhere = hook!(ctx, "elsewhere", target_ref: "reagent:local.other-target:1.0.0")
      theirs = hook!(other, "theirs")

      assert {:ok, %{disabled: disabled}} = Webhook.disable_for_component(ctx, @target)
      assert Enum.sort(disabled) == Enum.sort([pinned.id, versionless.id])

      assert {:ok, %{enabled: false}} = Webhook.resolve_ingress(pinned.slug)
      assert {:ok, %{enabled: false}} = Webhook.resolve_ingress(versionless.slug)
      assert {:ok, %{enabled: true}} = Webhook.resolve_ingress(elsewhere.slug)
      assert {:ok, %{enabled: true}} = Webhook.resolve_ingress(theirs.slug)

      # Already disabled: nothing left to disable.
      assert {:ok, %{disabled: []}} = Webhook.disable_for_component(ctx, @target <> ":2.0.0")
    end

    @tag :capture_log
    test "a write that fails partway disables none of them, not some", %{ctx: ctx} do
      first = hook!(ctx, "first")
      second = hook!(ctx, "second", target_ref: @target)
      refuse_disabling!("second")

      assert {:error, :unavailable} = Webhook.disable_for_component(ctx, @target)

      assert {:ok, %{enabled: true}} = Webhook.resolve_ingress(first.slug)
      assert {:ok, %{enabled: true}} = Webhook.resolve_ingress(second.slug)
    end

    test "a ref that does not parse names no target", %{ctx: ctx} do
      hook!(ctx, "kept")
      assert {:ok, %{disabled: []}} = Webhook.disable_for_component(ctx, "not a ref")
    end

    @tag :capture_log
    test "a store that cannot answer is unavailable", %{ctx: ctx} do
      hook!(ctx, "outage")
      outage!()

      assert {:error, :unavailable} = Webhook.disable_for_component(ctx, @target)
    end

    test "a context with no tenant is refused", %{ctx: ctx} do
      assert {:error, :no_athanor} =
               Webhook.disable_for_component(%{ctx | athanor_id: nil}, @target)
    end
  end
end
