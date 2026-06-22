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
  alias Sanctum.MCP.Shared

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    with :ok <- Shared.require_permission(ctx, :storage_read) do
      case Sanctum.Webhook.list(ctx) do
        {:ok, hooks} ->
          {:ok, %{webhooks: hooks, count: length(hooks)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list webhooks: #{inspect(reason)}")
          {:error, "Failed to list webhooks"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "name" => name}) do
    with :ok <- Shared.require_permission(ctx, :storage_read) do
      case Sanctum.Webhook.get(ctx, name) do
        {:ok, hook} ->
          {:ok, hook}

        {:error, :not_found} ->
          {:error, "Webhook not found: #{name}"}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name, "target_ref" => target_ref} = args) do
    with :ok <- Shared.require_permission(ctx, :admin) do
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
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, "Missing required arguments: name and target_ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "update", "name" => name} = args) do
    with :ok <- Shared.require_permission(ctx, :admin) do
      attrs = build_webhook_opts(args, %{})

      case Sanctum.Webhook.update(ctx, name, attrs) do
        {:ok, result} ->
          broadcast_webhooks_changed(ctx)
          {:ok, result}

        {:error, :not_found} ->
          {:error, "Webhook not found: #{name}"}

        {:error, :no_fields} ->
          {:error, "No mutable fields supplied. Allowed: target_ref, signature_header, input_template, description, rate_limit"}

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
  end

  def handle(_ctx, %{"action" => "update"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "name" => name}) do
    with :ok <- Shared.require_permission(ctx, :admin) do
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
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "rotate", "name" => name}) do
    with :ok <- Shared.require_permission(ctx, :admin) do
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
  end

  def handle(_ctx, %{"action" => "rotate"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid webhook action. Use: create, get, list, update, revoke, rotate"}
  end

  # --- helpers ---

  defp broadcast_webhooks_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:webhooks", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :webhooks_changed)
  end

  # Translate string-keyed JSON args from the MCP boundary into the atom-keyed
  # map shape that `Sanctum.Webhook.{create,update}` expect. Only known fields
  # are forwarded; unknown keys are ignored.
  defp build_webhook_opts(args, base) when is_map(args) and is_map(base) do
    Enum.reduce(
      [
        {"target_ref", :target_ref},
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
end
