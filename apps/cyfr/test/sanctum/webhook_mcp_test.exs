# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.WebhookMCPTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Provider

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    # Webhook create/update validates target_ref existence; register the
    # refs these tests point at.
    for name <- ["handler", "original", "updated"] do
      Sanctum.Test.ComponentHelpers.register_test_component(name, "1.0.0", "formula", %{})
    end

    # A webhook binds a consented profile at create; seed one per target.
    ctx = Sanctum.TestContext.local()

    for name <- ["handler", "original", "updated"] do
      Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.#{name}",
        profile_id: "prof-#{name}"
      )
    end

    {:ok, ctx: ctx}
  end

  # The tool, as a person reaches it: a secret it issues needs a proven
  # confirmation, and the call repeats naming it
  # (`Sanctum.TestContext.confirming/2`).
  defp handle(ctx, args),
    do: Sanctum.TestContext.confirming(ctx, &Provider.handle("webhook", &1, args))

  describe "webhook tool definition" do
    test "is exposed in tools/0" do
      tools = Provider.tools()
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
      {:ok, result} = handle(ctx, %{"action" => "list"})
      assert result.webhooks == []
      assert result.count == 0
    end

    test "lists created webhooks (without secrets)", %{ctx: ctx} do
      {:ok, _} =
        handle(ctx, %{
          "action" => "create",
          "name" => "github-push",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler"
        })

      {:ok, result} = handle(ctx, %{"action" => "list"})
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
        handle(ctx, %{
          "action" => "create",
          "name" => "stripe",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler"
        })

      assert String.starts_with?(result.secret, "whsec_")
      assert String.starts_with?(result.slug, "wh_")
      assert is_binary(result.url)
    end

    test "missing required args returns error", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "create"})
      assert msg =~ "Missing required arguments"
    end

    test "duplicate name returns error", %{ctx: ctx} do
      handle(ctx, %{
        "action" => "create",
        "name" => "dup",
        "replay_protection" => "none",
        "target_ref" => "f:local.handler",
        "profile_id" => "prof-handler"
      })

      {:error, msg} =
        handle(ctx, %{
          "action" => "create",
          "name" => "dup",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler"
        })

      assert msg =~ "already exists"
    end

    test "rejects reserved input_template key", %{ctx: ctx} do
      {:error, msg} =
        handle(ctx, %{
          "action" => "create",
          "name" => "reserved",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler",
          "input_template" => %{"_webhook" => "no"}
        })

      assert msg =~ "_webhook"
    end

    test "accepts custom signature_header and stores it lowercased", %{ctx: ctx} do
      {:ok, result} =
        handle(ctx, %{
          "action" => "create",
          "name" => "github-style",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler",
          "signature_header" => "X-Hub-Signature-256"
        })

      assert result.signature_header == "x-hub-signature-256"
    end
  end

  describe "webhook/get" do
    test "returns webhook by name without secret", %{ctx: ctx} do
      handle(ctx, %{
        "action" => "create",
        "name" => "g",
        "replay_protection" => "none",
        "target_ref" => "f:local.handler",
        "profile_id" => "prof-handler"
      })

      {:ok, hook} = handle(ctx, %{"action" => "get", "name" => "g"})
      assert hook.name == "g"
      refute Map.has_key?(hook, :secret)
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "get"})
      assert msg =~ "Missing required argument"
    end

    test "unknown name returns not_found", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "get", "name" => "ghost"})
      assert Sanctum.Refusals.render(msg) =~ "not found"
    end
  end

  describe "webhook/update" do
    test "updates target_ref without rotating secret", %{ctx: ctx} do
      {:ok, %{secret: secret_before}} =
        handle(ctx, %{
          "action" => "create",
          "name" => "u",
          "replay_protection" => "none",
          "target_ref" => "f:local.original",
          "profile_id" => "prof-original"
        })

      assert {:ok, _} =
               handle(ctx, %{
                 "action" => "update",
                 "name" => "u",
                 "target_ref" => "f:local.updated"
               })

      {:ok, hook} = handle(ctx, %{"action" => "get", "name" => "u"})
      assert hook.target_ref == "f:local.updated"

      # Same secret still verifies — rotate did NOT happen.
      {:ok, row} = Arca.WebhookStorage.get_by_slug(hook.slug)

      assert :ok =
               Sanctum.Webhook.verify_with_grace(
                 row,
                 "body",
                 "sha256=" <>
                   (:crypto.mac(:hmac, :sha256, secret_before, "body")
                    |> Base.encode16(case: :lower))
               )
    end

    test "no mutable fields returns error", %{ctx: ctx} do
      handle(ctx, %{
        "action" => "create",
        "name" => "x",
        "replay_protection" => "none",
        "target_ref" => "f:local.handler",
        "profile_id" => "prof-handler"
      })

      {:error, msg} = handle(ctx, %{"action" => "update", "name" => "x"})
      assert msg =~ "No mutable fields"
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "update"})
      assert msg =~ "Missing required argument"
    end
  end

  describe "webhook/revoke" do
    test "soft-disables and excludes from list", %{ctx: ctx} do
      handle(ctx, %{
        "action" => "create",
        "name" => "r",
        "replay_protection" => "none",
        "target_ref" => "f:local.handler",
        "profile_id" => "prof-handler"
      })

      {:ok, %{revoked: true}} =
        handle(ctx, %{"action" => "revoke", "name" => "r"})

      {:ok, %{webhooks: hooks}} = handle(ctx, %{"action" => "list"})
      refute Enum.any?(hooks, &(&1.name == "r"))
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "revoke"})
      assert msg =~ "Missing required argument"
    end

    test "unknown name returns not_found", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "revoke", "name" => "ghost"})
      assert Sanctum.Refusals.render(msg) =~ "not found"
    end
  end

  describe "webhook/rotate" do
    test "returns new secret; old one stops verifying", %{ctx: ctx} do
      {:ok, %{secret: old_secret, slug: slug}} =
        handle(ctx, %{
          "action" => "create",
          "name" => "rot",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler"
        })

      {:ok, rotated} = handle(ctx, %{"action" => "rotate", "name" => "rot"})
      assert rotated.secret != old_secret
      assert rotated.slug == slug

      {:ok, row} = Arca.WebhookStorage.get_by_slug(slug)

      assert :ok =
               Sanctum.Webhook.verify_with_grace(
                 row,
                 "body",
                 "sha256=" <>
                   (:crypto.mac(:hmac, :sha256, rotated.secret, "body")
                    |> Base.encode16(case: :lower))
               )

      # Old secret still verifies via the grace path (in-flight requests aren't
      # dropped on rotate); the expiry-window enforcement lives in webhook_test.exs.
      assert :ok =
               Sanctum.Webhook.verify_with_grace(
                 row,
                 "body",
                 "sha256=" <>
                   (:crypto.mac(:hmac, :sha256, old_secret, "body")
                    |> Base.encode16(case: :lower))
               )
    end

    test "missing name returns error", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "rotate"})
      assert msg =~ "Missing required argument"
    end

    test "unknown name returns not_found", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "rotate", "name" => "ghost"})
      assert Sanctum.Refusals.render(msg) =~ "not found"
    end
  end

  describe "webhook/reenable" do
    test "answers the webhook a restore suspended, once confirmed, and refuses in sentences",
         %{ctx: ctx} do
      {:ok, _} =
        handle(ctx, %{
          "action" => "create",
          "name" => "held",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler"
        })

      {:ok, %{id: id}} = handle(ctx, %{"action" => "get", "name" => "held"})

      Ecto.Query.from(w in Arca.Schemas.Webhook, where: w.id == ^id)
      |> Arca.Repo.update_all(set: [suspended: true])

      {:ok, %{webhooks: [listed]}} = handle(ctx, %{"action" => "list"})
      assert %{id: ^id, suspended: true} = listed

      assert {:ok, %{reenabled: %{id: ^id, name: "held", suspended: false}}} =
               handle(ctx, %{"action" => "reenable", "webhook_id" => id})

      assert {:error, %Prima.Refusal{class: :conflict, reason: :not_suspended, message: message}} =
               handle(ctx, %{"action" => "reenable", "webhook_id" => id})

      assert message =~ "not suspended"

      assert {:error, %Prima.Refusal{class: :not_found}} =
               handle(ctx, %{"action" => "reenable", "webhook_id" => "whk_unknown"})

      assert {:error, %Prima.Refusal{class: :invalid_argument}} =
               handle(ctx, %{"action" => "reenable"})
    end
  end

  describe "webhook unknown action" do
    test "returns informative error", %{ctx: ctx} do
      {:error, msg} = handle(ctx, %{"action" => "nonsense"})
      assert msg =~ "Invalid webhook action"
    end
  end

  describe "a profile binding the store cannot read, or reads damaged" do
    # The binding's own class is the class the gate answers and records: an
    # outage is `unavailable` and a damaged head `corrupt`, each in the
    # binding's sentence, never a webhook that failed for no said reason;
    # and the webhook is as it was.
    @outage "profile binding refused: the profile's consent cannot be read right now — try again"
    @damaged "profile binding refused: the profile's consent is damaged and cannot be used — " <>
               "revoke profile prof-handler and grant it again"

    @create %{
      "action" => "create",
      "name" => "refused-hook",
      "replay_protection" => "none",
      "target_ref" => "f:local.handler",
      "profile_id" => "prof-handler"
    }

    @repoint %{
      "action" => "update",
      "name" => "bound-hook",
      "target_ref" => "f:local.handler",
      "profile_id" => "prof-handler"
    }

    @tag :capture_log
    test "a create over a consent outage is unavailable, and no webhook is written", %{ctx: ctx} do
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
      refused!(ctx, "create", @create, @outage, "unavailable")
      Arca.Repo.query!("ALTER TABLE consents_unavailable RENAME TO consents")
      assert {:error, :not_found} = stored(ctx, "refused-hook")
    end

    test "a create over a damaged head is corrupt, and no webhook is written", %{ctx: ctx} do
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, "prof-handler", scope: "sideways")
      refused!(ctx, "create", @create, @damaged, "corrupt")
      assert {:error, :not_found} = stored(ctx, "refused-hook")
    end

    @tag :capture_log
    test "a repointing update over a consent outage is unavailable, and the webhook stands", %{
      ctx: ctx
    } do
      before = bound!(ctx)
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
      refused!(ctx, "update", @repoint, @outage, "unavailable")
      Arca.Repo.query!("ALTER TABLE consents_unavailable RENAME TO consents")
      assert stored(ctx, "bound-hook") == before
    end

    test "a repointing update over a damaged head is corrupt, and the webhook stands", %{
      ctx: ctx
    } do
      before = bound!(ctx)
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, "prof-handler", scope: "sideways")
      refused!(ctx, "update", @repoint, @damaged, "corrupt")
      assert stored(ctx, "bound-hook") == before
    end

    # A caller the consent class refuses is answered as the webhook surface
    # has always answered it: the binding's sentence for the class's refusal.
    test "a caller the consent class refuses keeps its sentence", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, refused} = Provider.handle("webhook", key_ctx, @create)
      assert is_binary(refused)
      assert String.starts_with?(refused, "profile binding refused: ")
      assert {:error, :not_found} = stored(ctx, "refused-hook")
    end

    # A webhook bound to the handler's profile, as stored.
    defp bound!(ctx) do
      {:ok, _} =
        handle(ctx, %{
          "action" => "create",
          "name" => "bound-hook",
          "replay_protection" => "none",
          "target_ref" => "f:local.handler",
          "profile_id" => "prof-handler"
        })

      {:ok, row} = stored(ctx, "bound-hook")
      {:ok, row}
    end

    defp stored(ctx, name),
      do: Arca.WebhookStorage.get_by_name(Sanctum.Context.actor(ctx), name)

    # `action` over MCP answers a failed tool result whose one text block is
    # `sentence`, and the gate's one record of the call is admitted and
    # failed in `class`.
    defp refused!(ctx, action, args, sentence, class) do
      assert decided(ctx) == []
      answer = over_mcp(ctx, args)

      refute Map.has_key?(answer, "error")

      assert {answer["result"]["isError"], answer["result"]["content"]} ==
               {true, [%{"type" => "text", "text" => sentence}]}

      assert decided(ctx) == [{action, "admitted", "failed", class}]
    end

    defp over_mcp(ctx, args) do
      message = %Prima.MCP.Message{
        type: :request,
        id: 1,
        method: "tools/call",
        params: %{"name" => "webhook", "arguments" => args}
      }

      case Emissary.MCP.Router.dispatch(ctx, message) do
        {:ok, result} -> Prima.MCP.Message.encode_result(1, result)
        {:error, code, text} -> Prima.MCP.Message.encode_error(1, code, text)
        {:error, code, text, data} -> Prima.MCP.Message.encode_error(1, code, text, data)
      end
    end

    # The gate's records of the webhook tool in the context's athanor.
    defp decided(ctx) do
      Arca.Repo.all(
        Ecto.Query.from(d in Arca.Schemas.DecisionLog,
          where: d.athanor_id == ^ctx.athanor_id and d.tool == "webhook",
          select: {d.action, d.admission, d.completion, d.completion_class}
        )
      )
    end
  end
end
