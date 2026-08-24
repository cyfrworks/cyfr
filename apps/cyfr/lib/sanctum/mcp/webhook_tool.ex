# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.WebhookTool do
  @moduledoc """
  Webhook tool handlers for the Sanctum MCP provider — create, list, get,
  update, revoke, and rotate inbound webhooks.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    %{
      name: "webhook",
      title: "Webhook Management",
      description:
        "Manage inbound webhooks — stable URLs that accept HMAC-SHA256-signed POSTs and dispatch to a target component. Secrets are returned plaintext exactly once on create/rotate.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: false,
        actions: %{
          # create/update also require the registration's consent binding —
          # a conditional Authz check the annotation cannot express; it
          # stays in Sanctum.Webhook.
          "create" => %{kind: :write, planes: [:external], permission: :admin},
          "list" => %{kind: :read, planes: [:external, :in_chain], permission: :storage_read},
          "get" => %{kind: :read, planes: [:external, :in_chain], permission: :storage_read},
          "update" => %{kind: :write, planes: [:external], permission: :admin},
          "revoke" => %{kind: :write, planes: [:external], permission: :admin},
          "rotate" => %{kind: :write, planes: [:external], permission: :admin}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["create", "list", "get", "update", "revoke", "rotate"],
            "description" => "Action to perform"
          },
          "name" => %{
            "type" => "string",
            "description" => "Human-readable name for the webhook (unique per tenant)"
          },
          "target_ref" => %{
            "type" => "string",
            "description" =>
              "Component reference to invoke on inbound delivery (e.g. 'f:local.handle-github-push')"
          },
          "profile_id" => %{
            "type" => "string",
            "description" =>
              "Profile the webhook fires under (required on create). Deliveries run " <>
                "with this profile's consented authority; binding takes the consent " <>
                "authorization class, so an interactive session or consent-capable key is needed."
          },
          "input_template" => %{
            "type" => "object",
            "description" =>
              "JSON object merged into the invocation envelope. The reserved key '_webhook' is set by the controller and must not be present here. Max 16 KB."
          },
          "signature_header" => %{
            "type" => "string",
            "description" =>
              "HTTP header carrying the HMAC signature (default 'x-cyfr-signature'). Use 'x-hub-signature-256' for GitHub, 'stripe-signature' for Stripe, etc."
          },
          "timestamp_header" => %{
            "type" => "string",
            "description" =>
              "HTTP header carrying a unix-seconds timestamp for replay protection. When set, HMAC payload becomes '<ts>.<raw_body>' (Stripe-style) and requests outside ±5 min are rejected. LEFT UNSET, A CAPTURED DELIVERY CAN BE REPLAYED INDEFINITELY — a signature stays valid forever, so anyone who reads one off a proxy log or mirrored traffic can re-fire the bound component. Set it to whatever the sender emits ('stripe-signature' carries its own; GitHub has no timestamp header). Empty string clears the field."
          },
          "idempotency_key_header" => %{
            "type" => "string",
            "description" =>
              "HTTP header carrying a unique event id (e.g. 'x-github-delivery' for GitHub, the Stripe event id for Stripe). When set, repeat deliveries with the same id short-circuit to a 200 with status 'duplicate' for as long as the delivery record is retained (the retention scheduler's cadence; unbounded when retention is off), and deliveries MISSING the header are refused with 400. Left unset, a sender's own retries each run the bound component again. Empty string clears the field."
          },
          "description" => %{
            "type" => "string",
            "description" => "Free-form description for operator reference"
          },
          "rate_limit" => %{
            "type" => "string",
            "description" =>
              "Per-slug rate limit (e.g. '100/1m', '1000/1h'). Default 100/1m if unset."
          }
        },
        "required" => ["action"]
      }
    }
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.Webhook.list(ctx) do
      {:ok, hooks} ->
        {:ok, %{webhooks: hooks, count: length(hooks)}}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to list webhooks: #{inspect(reason)}")
        {:error, "Failed to list webhooks"}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "name" => name}) do
    case Sanctum.Webhook.get(ctx, name) do
      {:ok, hook} ->
        {:ok, hook}

      {:error, :not_found} ->
        {:error, "Webhook not found: #{name}"}
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(
        %Context{} = ctx,
        %{"action" => "create", "name" => name, "target_ref" => target_ref} = args
      ) do
    opts = build_webhook_opts(args, %{name: name, target_ref: target_ref})

    case Sanctum.Webhook.create(ctx, opts) do
      {:ok, result} ->
        broadcast_webhooks_changed(ctx)
        {:ok, result}

      {:error, :already_exists} ->
        {:error, "Webhook already exists: #{name}"}

      {:error, :reserved_key} ->
        {:error, "input_template must not contain reserved key '_webhook'"}

      {:error, :input_template_too_large} ->
        {:error, "input_template exceeds 16 KB limit"}

      {:error, :invalid_input_template} ->
        {:error, "input_template is invalid"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to create webhook: #{inspect(reason)}")
        {:error, "Failed to create webhook"}
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, "Missing required arguments: name and target_ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    attrs = build_webhook_opts(args, %{})

    case Sanctum.Webhook.update(ctx, name, attrs) do
      {:ok, result} ->
        broadcast_webhooks_changed(ctx)
        {:ok, result}

      {:error, :not_found} ->
        {:error, "Webhook not found: #{name}"}

      {:error, :no_fields} ->
        {:error,
         "No mutable fields supplied. Allowed: target_ref, signature_header, input_template, description, rate_limit"}

      {:error, :reserved_key} ->
        {:error, "input_template must not contain reserved key '_webhook'"}

      {:error, :input_template_too_large} ->
        {:error, "input_template exceeds 16 KB limit"}

      {:error, :invalid_input_template} ->
        {:error, "input_template is invalid"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to update webhook: #{inspect(reason)}")
        {:error, "Failed to update webhook"}
    end
  end

  def handle(_ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "name" => name}) do
    case Sanctum.Webhook.revoke(ctx, name) do
      :ok ->
        broadcast_webhooks_changed(ctx)
        {:ok, %{revoked: true, name: name}}

      {:error, :not_found} ->
        {:error, "Webhook not found: #{name}"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to revoke webhook: #{inspect(reason)}")
        {:error, "Failed to revoke webhook"}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "rotate", "name" => name}) do
    case Sanctum.Webhook.rotate(ctx, name) do
      {:ok, result} ->
        broadcast_webhooks_changed(ctx)
        {:ok, result}

      {:error, :not_found} ->
        {:error, "Webhook not found: #{name}"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to rotate webhook: #{inspect(reason)}")
        {:error, "Failed to rotate webhook"}
    end
  end

  def handle(_ctx, %{"action" => "rotate"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(_ctx, _args) do
    {:error, Emissary.MCP.ToolProvider.invalid_action("webhook", action_enum())}
  end

  # --- helpers ---

  defp broadcast_webhooks_changed(ctx) do
    topic = Prism.Topics.webhooks(ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :webhooks_changed)
  end

  # Translate string-keyed JSON args from the MCP boundary into the atom-keyed
  # map shape that `Sanctum.Webhook.{create,update}` expect. Only known fields
  # are forwarded; unknown keys are ignored.
  defp build_webhook_opts(args, base) when is_map(args) and is_map(base) do
    Enum.reduce(
      [
        {"target_ref", :target_ref},
        {"profile_id", :profile_id},
        {"input_template", :input_template},
        {"signature_header", :signature_header},
        {"timestamp_header", :timestamp_header},
        {"idempotency_key_header", :idempotency_key_header},
        {"description", :description},
        {"rate_limit", :rate_limit}
      ],
      base,
      fn {string_key, atom_key}, acc ->
        case Map.get(args, string_key) do
          nil -> acc
          value -> Map.put(acc, atom_key, value)
        end
      end
    )
  end

  defp action_enum, do: get_in(definition(), [:input_schema, "properties", "action", "enum"])
end
