defmodule Sanctum.WebhookMCPTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "webhook tool definition" do
    test "is exposed in tools/0" do
      tools = MCP.tools()
      assert Enum.any?(tools, &(&1.name == "webhook"))

      webhook = Enum.find(tools, &(&1.name == "webhook"))
      enum = webhook.input_schema["properties"]["action"]["enum"]
      assert "create" in enum
      assert "list" in enum
      assert "get" in enum
      assert "update" in enum
      assert "revoke" in enum
      assert "rotate" in enum
    end
  end

  describe "webhook/list" do
    test "returns empty initially", %{ctx: ctx} do
      {:ok, result} = MCP.handle("webhook", ctx, %{"action" => "list"})
      assert result.webhooks == []
      assert result.count == 0
    end

    test "lists created webhooks (without secrets)", %{ctx: ctx} do
      {:ok, _} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "github-push",
          "target_ref" => "f:local.handler"
        })

      {:ok, result} = MCP.handle("webhook", ctx, %{"action" => "list"})
      assert result.count == 1

      hook = hd(result.webhooks)
      assert hook.name == "github-push"
      refute Map.has_key?(hook, :secret)
      refute Map.has_key?(hook, :secret_encrypted)
    end
  end

  describe "webhook/create" do
    test "returns plaintext secret + slug exactly once", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "stripe",
          "target_ref" => "f:local.handler"
        })

      assert String.starts_with?(result.secret, "whsec_")
      assert String.starts_with?(result.slug, "wh_")
      assert is_binary(result.url)
    end

    test "missing required args returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "create"})
      assert msg =~ "Missing required arguments"
    end

    test "duplicate name returns error", %{ctx: ctx} do
      MCP.handle("webhook", ctx, %{
        "action" => "create",
        "name" => "dup",
        "target_ref" => "f:local.handler"
      })

      {:error, msg} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "dup",
          "target_ref" => "f:local.handler"
        })

      assert msg =~ "already exists"
    end

    test "rejects reserved input_template key", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "reserved",
          "target_ref" => "f:local.handler",
          "input_template" => %{"_webhook" => "no"}
        })

      assert msg =~ "_webhook"
    end

    test "accepts custom signature_header and stores it lowercased", %{ctx: ctx} do
      {:ok, result} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "github-style",
          "target_ref" => "f:local.handler",
          "signature_header" => "X-Hub-Signature-256"
        })

      assert result.signature_header == "x-hub-signature-256"
    end
  end

  describe "webhook/get" do
    test "returns webhook by name without secret", %{ctx: ctx} do
      MCP.handle("webhook", ctx, %{
        "action" => "create",
        "name" => "g",
        "target_ref" => "f:local.handler"
      })

      {:ok, hook} = MCP.handle("webhook", ctx, %{"action" => "get", "name" => "g"})
      assert hook.name == "g"
      refute Map.has_key?(hook, :secret)
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "get"})
      assert msg =~ "Missing required argument"
    end

    test "unknown name returns not_found", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "get", "name" => "ghost"})
      assert msg =~ "not found"
    end
  end

  describe "webhook/update" do
    test "updates target_ref without rotating secret", %{ctx: ctx} do
      {:ok, %{secret: secret_before}} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "u",
          "target_ref" => "f:local.original"
        })

      assert {:ok, _} =
               MCP.handle("webhook", ctx, %{
                 "action" => "update",
                 "name" => "u",
                 "target_ref" => "f:local.updated"
               })

      {:ok, hook} = MCP.handle("webhook", ctx, %{"action" => "get", "name" => "u"})
      assert hook.target_ref == "f:local.updated"

      # Same secret still verifies — rotate did NOT happen.
      {:ok, row} = Arca.WebhookStorage.get_by_slug(hook.slug)

      assert :ok =
               Sanctum.Webhook.verify_signature(
                 row.secret_encrypted,
                 "body",
                 "sha256=" <>
                   (:crypto.mac(:hmac, :sha256, secret_before, "body") |> Base.encode16(case: :lower))
               )
    end

    test "no mutable fields returns error", %{ctx: ctx} do
      MCP.handle("webhook", ctx, %{
        "action" => "create",
        "name" => "x",
        "target_ref" => "f:local.handler"
      })

      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "update", "name" => "x"})
      assert msg =~ "No mutable fields"
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "update"})
      assert msg =~ "Missing required argument"
    end
  end

  describe "webhook/revoke" do
    test "soft-disables and excludes from list", %{ctx: ctx} do
      MCP.handle("webhook", ctx, %{
        "action" => "create",
        "name" => "r",
        "target_ref" => "f:local.handler"
      })

      {:ok, %{revoked: true}} = MCP.handle("webhook", ctx, %{"action" => "revoke", "name" => "r"})

      {:ok, %{webhooks: hooks}} = MCP.handle("webhook", ctx, %{"action" => "list"})
      refute Enum.any?(hooks, &(&1.name == "r"))
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "revoke"})
      assert msg =~ "Missing required argument"
    end

    test "unknown name returns not_found", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "revoke", "name" => "ghost"})
      assert msg =~ "not found"
    end
  end

  describe "webhook/rotate" do
    test "returns new secret; old one stops verifying", %{ctx: ctx} do
      {:ok, %{secret: old_secret, slug: slug}} =
        MCP.handle("webhook", ctx, %{
          "action" => "create",
          "name" => "rot",
          "target_ref" => "f:local.handler"
        })

      {:ok, rotated} = MCP.handle("webhook", ctx, %{"action" => "rotate", "name" => "rot"})
      assert rotated.secret != old_secret
      assert rotated.slug == slug

      {:ok, row} = Arca.WebhookStorage.get_by_slug(slug)

      assert :ok =
               Sanctum.Webhook.verify_signature(
                 row.secret_encrypted,
                 "body",
                 "sha256=" <>
                   (:crypto.mac(:hmac, :sha256, rotated.secret, "body")
                    |> Base.encode16(case: :lower))
               )

      assert {:error, :signature_mismatch} =
               Sanctum.Webhook.verify_signature(
                 row.secret_encrypted,
                 "body",
                 "sha256=" <>
                   (:crypto.mac(:hmac, :sha256, old_secret, "body") |> Base.encode16(case: :lower))
               )
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "rotate"})
      assert msg =~ "Missing required argument"
    end

    test "unknown name returns not_found", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "rotate", "name" => "ghost"})
      assert msg =~ "not found"
    end
  end

  describe "webhook unknown action" do
    test "returns informative error", %{ctx: ctx} do
      {:error, msg} = MCP.handle("webhook", ctx, %{"action" => "nonsense"})
      assert msg =~ "Invalid webhook action"
    end
  end
end
