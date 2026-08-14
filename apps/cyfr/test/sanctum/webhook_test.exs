# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.WebhookTest do
  use ExUnit.Case, async: false

  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.Webhook

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Webhook create/update validates that target_ref names a registered
    # component; register the refs these tests point at.
    Sanctum.Test.ComponentHelpers.register_test_component("handler", "1.0.0", "formula", %{})
    Sanctum.Test.ComponentHelpers.register_test_component("h", "1.0.0", "formula", %{})

    # A webhook binds a consented profile at create; these tests focus on
    # other behaviour, so seed one owner profile per target.
    ctx = Sanctum.TestContext.local()
    ConsentFixtures.start_source!()
    ConsentFixtures.bindable_profile(ctx, "f:local.handler", profile_id: "prof-handler")
    ConsentFixtures.bindable_profile(ctx, "f:local.h", profile_id: "prof-h")

    {:ok, ctx: ctx}
  end

  # Injects the seeded profile for the target so each test stays a one-liner;
  # a test may still pass its own :profile_id to exercise binding behaviour.
  defp create(ctx, opts) do
    profile =
      case opts[:target_ref] do
        "f:local.h" -> "prof-h"
        _ -> "prof-handler"
      end

    Webhook.create(ctx, Map.put_new(opts, :profile_id, profile))
  end

  describe "create/2" do
    test "generates whsec_/wh_ prefixed credentials and stores", %{ctx: ctx} do
      assert {:ok, result} = create(ctx, %{name: "github", target_ref: "f:local.handler"})

      assert String.starts_with?(result.secret, "whsec_")
      assert String.starts_with?(result.slug, "wh_")
      assert byte_size(result.secret) > 30
      assert result.target_ref == "f:local.handler"
      assert result.input_template == %{}
      assert result.signature_header == "x-cyfr-signature"
      assert is_binary(result.url)
      assert String.ends_with?(result.url, "/hooks/" <> result.slug)
    end

    test "the URL is absolute when the operator declares a public URL", %{ctx: ctx} do
      # A sender needs an absolute URL, and behind a proxy or a tunnel only
      # the operator knows the host. Both surfaces told users to set
      # CYFR_PUBLIC_URL long before anything read it.
      original = Application.get_env(:cyfr, :public_url)
      Application.put_env(:cyfr, :public_url, "https://cyfr.example.com/")

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :public_url, original),
          else: Application.delete_env(:cyfr, :public_url)
      end)

      assert {:ok, result} = create(ctx, %{name: "absolute", target_ref: "f:local.handler"})
      assert result.url == "https://cyfr.example.com/hooks/" <> result.slug
    end

    test "the URL is a bare path when no public URL is declared", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :public_url)
      Application.delete_env(:cyfr, :public_url)

      on_exit(fn ->
        if original, do: Application.put_env(:cyfr, :public_url, original)
      end)

      assert {:ok, result} = create(ctx, %{name: "relative", target_ref: "f:local.handler"})
      assert result.url == "/hooks/" <> result.slug
    end

    test "url is path-only — clients prepend their own host", %{ctx: ctx} do
      {:ok, result} = create(ctx, %{name: "url-shape", target_ref: "f:local.h"})
      assert result.url == "/hooks/" <> result.slug
    end

    test "stores input_template and reads it back via get/2", %{ctx: ctx} do
      {:ok, _} =
        create(ctx, %{
          name: "with-template",
          target_ref: "f:local.handler",
          input_template: %{"channel" => "alerts", "priority" => "high"}
        })

      {:ok, fetched} = Webhook.get(ctx, "with-template")
      assert fetched.input_template == %{"channel" => "alerts", "priority" => "high"}
      refute Map.has_key?(fetched, :secret)
      refute Map.has_key?(fetched, :secret_encrypted)
    end

    test "rejects input_template containing reserved key _webhook (string)", %{ctx: ctx} do
      assert {:error, :reserved_key} =
               create(ctx, %{
                 name: "reserved",
                 target_ref: "f:local.handler",
                 input_template: %{"_webhook" => %{"foo" => "bar"}}
               })
    end

    test "rejects input_template containing reserved key :_webhook (atom)", %{ctx: ctx} do
      # Direct Elixir callers may pass atom-keyed maps; defense-in-depth check.
      assert {:error, :reserved_key} =
               create(ctx, %{
                 name: "reserved-atom",
                 target_ref: "f:local.handler",
                 input_template: %{_webhook: %{"foo" => "bar"}}
               })
    end

    test "rejects input_template that is not a map", %{ctx: ctx} do
      assert {:error, :invalid_input_template} =
               create(ctx, %{
                 name: "bad",
                 target_ref: "f:local.handler",
                 input_template: ["not", "an", "object"]
               })
    end

    test "rejects input_template larger than 16 KB", %{ctx: ctx} do
      huge = %{"data" => String.duplicate("x", 17 * 1024)}

      assert {:error, :input_template_too_large} =
               create(ctx, %{
                 name: "big",
                 target_ref: "f:local.handler",
                 input_template: huge
               })
    end

    test "duplicate name returns already_exists", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "dup", target_ref: "f:local.handler"})

      assert {:error, :already_exists} =
               create(ctx, %{name: "dup", target_ref: "f:local.handler"})
    end

    test "missing required fields returns error", %{ctx: ctx} do
      assert {:error, _} = create(ctx, %{})
      assert {:error, _} = create(ctx, %{name: "only-name"})
    end

    test "lowercases custom signature_header", %{ctx: ctx} do
      {:ok, result} =
        create(ctx, %{
          name: "case",
          target_ref: "f:local.handler",
          signature_header: "X-Hub-Signature-256"
        })

      assert result.signature_header == "x-hub-signature-256"
    end

    test "rejects a target_ref that names no registered component", %{ctx: ctx} do
      assert {:error, message} =
               create(ctx, %{name: "ghost", target_ref: "f:local.never-published"})

      assert message =~ "never-published"
    end
  end

  describe "list/1, get/2" do
    test "list excludes secrets", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "a", target_ref: "f:local.handler"})
      {:ok, _} = create(ctx, %{name: "b", target_ref: "f:local.handler"})

      {:ok, hooks} = Webhook.list(ctx)
      assert length(hooks) >= 2

      Enum.each(hooks, fn h ->
        refute Map.has_key?(h, :secret)
        refute Map.has_key?(h, :secret_encrypted)
      end)
    end

    test "get returns not_found for missing", %{ctx: ctx} do
      assert {:error, :not_found} = Webhook.get(ctx, "nope")
    end
  end

  describe "update/3" do
    test "changes input_template without rotating secret", %{ctx: ctx} do
      {:ok, %{secret: original_secret}} =
        create(ctx, %{name: "u", target_ref: "f:local.handler"})

      assert {:ok, updated} =
               Webhook.update(ctx, "u", %{input_template: %{"v" => 1}})

      assert updated.input_template == %{"v" => 1}

      # Same secret still verifies — proves rotate did not happen.
      assert :ok = verify_with_secret(ctx, "u", original_secret, "body")
    end

    test "rejects update with reserved key in input_template", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "r", target_ref: "f:local.handler"})

      assert {:error, :reserved_key} =
               Webhook.update(ctx, "r", %{input_template: %{"_webhook" => 1}})
    end

    test "ignores unknown fields", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "i", target_ref: "f:local.handler"})

      assert {:error, :no_fields} = Webhook.update(ctx, "i", %{not_a_field: "x"})
    end

    test "returns not_found for missing webhook", %{ctx: ctx} do
      assert {:error, :not_found} = Webhook.update(ctx, "missing", %{description: "x"})
    end

    test "rejects repointing at an unregistered target_ref", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "repoint", target_ref: "f:local.handler"})

      assert {:error, message} =
               Webhook.update(ctx, "repoint", %{target_ref: "f:local.never-published"})

      assert message =~ "never-published"

      # Original target is untouched
      assert {:ok, %{target_ref: "f:local.handler"}} = Webhook.get(ctx, "repoint")
    end

    test "repointing at a registered target_ref succeeds", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "repoint-ok", target_ref: "f:local.handler"})

      assert {:ok, %{target_ref: "f:local.h"}} =
               Webhook.update(ctx, "repoint-ok", %{target_ref: "f:local.h"})
    end
  end

  describe "revoke/2" do
    test "soft-disables and excludes from list", %{ctx: ctx} do
      {:ok, _} = create(ctx, %{name: "rev", target_ref: "f:local.handler"})
      assert :ok = Webhook.revoke(ctx, "rev")

      {:ok, hooks} = Webhook.list(ctx)
      refute Enum.any?(hooks, &(&1.name == "rev"))
    end
  end

  describe "rotate/2" do
    test "old secret keeps verifying during the grace window, dropped after expiry",
         %{ctx: ctx} do
      {:ok, %{secret: old_secret, slug: slug, url: url}} =
        create(ctx, %{name: "rot", target_ref: "f:local.handler"})

      assert {:ok, rotated} = Webhook.rotate(ctx, "rot")
      assert rotated.secret != old_secret
      # URL is unchanged across rotation — same slug.
      assert rotated.url == url
      assert rotated.slug == slug

      # New secret verifies. Old secret ALSO verifies via the grace path
      # (in-flight requests aren't dropped).
      assert :ok = verify_grace_with_slug(slug, rotated.secret, "body")
      assert :ok = verify_grace_with_slug(slug, old_secret, "body")

      # Expire the grace window; the old secret is now rejected, new still ok.
      import Ecto.Query
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:microsecond)

      from(w in Arca.Schemas.Webhook, where: w.slug == ^slug)
      |> Arca.Repo.update_all(set: [previous_secret_expires_at: past])

      assert :ok = verify_grace_with_slug(slug, rotated.secret, "body")
      assert {:error, :signature_mismatch} = verify_grace_with_slug(slug, old_secret, "body")
    end

    test "returns not_found for missing webhook", %{ctx: ctx} do
      assert {:error, :not_found} = Webhook.rotate(ctx, "ghost")
    end
  end

  describe "verify_with_grace/3" do
    test "verifies a correctly-signed payload", %{ctx: ctx} do
      {:ok, %{slug: slug, secret: secret}} =
        create(ctx, %{name: "v", target_ref: "f:local.handler"})

      body = ~s({"hello":"world"})
      assert :ok = verify_with_slug(slug, secret, body)
    end

    test "rejects tampered body", %{ctx: ctx} do
      {:ok, %{slug: slug, secret: secret}} =
        create(ctx, %{name: "tamper", target_ref: "f:local.handler"})

      body = ~s({"hello":"world"})
      sig = "sha256=" <> hmac_hex(secret, body)
      tampered = ~s({"hello":"WORLD"})

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)

      assert {:error, :signature_mismatch} =
               Webhook.verify_with_grace(hook, tampered, sig)
    end

    test "rejects malformed signature header", %{ctx: ctx} do
      {:ok, %{slug: slug}} = create(ctx, %{name: "m", target_ref: "f:local.handler"})
      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)

      assert {:error, :malformed_signature} =
               Webhook.verify_with_grace(hook, "body", "no-prefix")

      assert {:error, :malformed_signature} =
               Webhook.verify_with_grace(hook, "body", "")
    end
  end

  describe "verify_with_grace/4 (replay protection)" do
    test "verifies a timestamped payload within the skew window", %{ctx: ctx} do
      {:ok, %{slug: slug, secret: secret}} =
        create(ctx, %{
          name: "ts-ok",
          target_ref: "f:local.handler",
          timestamp_header: "X-Cyfr-Timestamp"
        })

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
      assert hook.timestamp_header == "x-cyfr-timestamp"

      body = ~s({"event":"x"})
      ts = System.system_time(:second) |> Integer.to_string()
      payload = ts <> "." <> body
      sig = "sha256=" <> hmac_hex(secret, payload)

      assert :ok = Webhook.verify_with_grace(hook, body, sig, ts)
    end

    test "rejects timestamps outside the skew window", %{ctx: ctx} do
      {:ok, %{slug: slug, secret: secret}} =
        create(ctx, %{
          name: "ts-skew",
          target_ref: "f:local.handler",
          timestamp_header: "X-Cyfr-Timestamp"
        })

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)

      body = "{}"
      stale_ts = (System.system_time(:second) - 600) |> Integer.to_string()
      payload = stale_ts <> "." <> body
      sig = "sha256=" <> hmac_hex(secret, payload)

      assert {:error, :timestamp_skew} =
               Webhook.verify_with_grace(hook, body, sig, stale_ts)
    end

    test "rejects malformed (non-integer) timestamps", %{ctx: ctx} do
      {:ok, %{slug: slug, secret: secret}} =
        create(ctx, %{name: "ts-bad", target_ref: "f:local.handler"})

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)

      body = "{}"
      sig = "sha256=" <> hmac_hex(secret, "0." <> body)

      assert {:error, :malformed_timestamp} =
               Webhook.verify_with_grace(hook, body, sig, "not-a-number")
    end

    test "without a timestamp arg, body-only HMAC verifies (replay protection off)",
         %{ctx: ctx} do
      {:ok, %{slug: slug, secret: secret}} =
        create(ctx, %{name: "no-ts", target_ref: "f:local.handler"})

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
      body = ~s({"a":1})
      sig = "sha256=" <> hmac_hex(secret, body)

      assert :ok = Webhook.verify_with_grace(hook, body, sig)
      assert :ok = Webhook.verify_with_grace(hook, body, sig, nil)
    end

    test "empty timestamp_header on create stores nil (replay protection off)", %{ctx: ctx} do
      {:ok, %{slug: slug}} =
        create(ctx, %{
          name: "empty-ts",
          target_ref: "f:local.handler",
          timestamp_header: ""
        })

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
      assert hook.timestamp_header == nil
    end

    test "update can clear timestamp_header by passing empty string", %{ctx: ctx} do
      {:ok, %{slug: slug}} =
        create(ctx, %{
          name: "clear-ts",
          target_ref: "f:local.handler",
          timestamp_header: "X-Cyfr-Timestamp"
        })

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
      assert hook.timestamp_header == "x-cyfr-timestamp"

      assert {:ok, _} = Webhook.update(ctx, "clear-ts", %{timestamp_header: ""})

      {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
      assert hook.timestamp_header == nil
    end
  end

  describe "decode_input_template/1" do
    test "nil/empty default to empty map" do
      assert {:ok, %{}} = Webhook.decode_input_template(nil)
      assert {:ok, %{}} = Webhook.decode_input_template("")
    end

    test "valid JSON object decodes" do
      assert {:ok, %{"k" => "v"}} = Webhook.decode_input_template(~s({"k":"v"}))
    end

    test "non-object JSON returns :not_an_object" do
      assert {:error, :not_an_object} = Webhook.decode_input_template(~s([1,2,3]))
      assert {:error, :not_an_object} = Webhook.decode_input_template("42")
    end

    test "invalid JSON returns :invalid_json" do
      assert {:error, :invalid_json} = Webhook.decode_input_template(~s({broken))
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp hmac_hex(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp verify_with_slug(slug, secret, body) do
    {:ok, hook} = Arca.WebhookStorage.get_by_slug(slug)
    sig = "sha256=" <> hmac_hex(secret, body)
    Webhook.verify_with_grace(hook, body, sig)
  end

  # Alias kept for tests that still emphasise the grace-window codepath.
  defp verify_grace_with_slug(slug, secret, body),
    do: verify_with_slug(slug, secret, body)

  defp verify_with_secret(ctx, name, secret, body) do
    {:ok, hook_meta} = Webhook.get(ctx, name)
    {:ok, hook_row} = Arca.WebhookStorage.get_by_slug(hook_meta.slug)
    sig = "sha256=" <> hmac_hex(secret, body)
    Webhook.verify_with_grace(hook_row, body, sig)
  end
end
