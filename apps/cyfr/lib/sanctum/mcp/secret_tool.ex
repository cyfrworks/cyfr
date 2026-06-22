# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.SecretTool do
  @moduledoc """
  Secret tool handlers for the Sanctum MCP provider — set, get, delete,
  list, grant, revoke, and access checks for encrypted secrets.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    with :ok <- Shared.require_permission(ctx, :secrets_read) do
      case Sanctum.Secrets.list(ctx) do
        {:ok, names} ->
          visible = Enum.reject(names, &Sanctum.Secrets.system_secret?/1)
          {:ok, %{secrets: visible, count: length(visible)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list secrets: #{inspect(reason)}")
          {:error, "Failed to list secrets"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "name" => name} = _args) do
    with :ok <- Shared.require_permission(ctx, :secrets_read),
         :ok <- reject_system_secret(name) do
      case Sanctum.Secrets.get(ctx, name) do
        {:ok, value} ->
          # Return masked value with length hint for security
          masked = mask_secret(value)
          {:ok, %{name: name, value: masked, length: String.length(value)}}

        {:error, :not_found} ->
          {:error, "Secret not found: #{name}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get secret: #{inspect(reason)}")
          {:error, "Failed to get secret"}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(
        %Context{} = ctx,
        %{"action" => "set", "name" => name, "value" => value} = _args
      ) do
    with :ok <- Shared.require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         :ok <- Sanctum.Secrets.set(ctx, name, value) do
      broadcast_secrets_changed(ctx)
      {:ok, %{stored: true, name: name}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to store secret: #{inspect(reason)}")
        {:error, "Failed to store secret"}
    end
  end

  def handle(_ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: name, value"}
  end

  def handle(%Context{} = ctx, %{"action" => "delete", "name" => name} = _args) do
    with :ok <- Shared.require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         :ok <- Sanctum.Secrets.delete(ctx, name) do
      broadcast_secrets_changed(ctx)
      {:ok, %{deleted: true, name: name}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to delete secret: #{inspect(reason)}")
        {:error, "Failed to delete secret"}
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "grant",
          "name" => name,
          "component_ref" => component_ref
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with {:ok, component_ref} <- Shared.normalize_ref(component_ref),
         :ok <- Shared.require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         {:ok, store_ref, promoted_from} <-
           Shared.maybe_promote_to_name_level(component_ref, pin_version),
         :ok <- Sanctum.Secrets.grant(ctx, name, store_ref) do
      broadcast_secrets_changed(ctx)
      result = %{granted: true, secret: name, component: store_ref}
      result = if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result
      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to grant access: #{inspect(reason)}")
        {:error, "Failed to grant access"}
    end
  end

  def handle(_ctx, %{"action" => "grant"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "revoke",
          "name" => name,
          "component_ref" => component_ref
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with {:ok, component_ref} <- Shared.normalize_ref(component_ref),
         :ok <- Shared.require_permission(ctx, :secrets_write),
         :ok <- reject_system_secret(name),
         {:ok, store_ref, promoted_from} <-
           Shared.maybe_promote_to_name_level(component_ref, pin_version),
         {:ok, status} <- Sanctum.Secrets.revoke(ctx, name, store_ref) do
      broadcast_secrets_changed(ctx)
      result = %{status: status, secret: name, component: store_ref}
      result = if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result
      {:ok, result}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to revoke access: #{inspect(reason)}")
        {:error, "Failed to revoke access"}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "can_access",
        "name" => name,
        "component_ref" => ref
      }) do
    with :ok <- Shared.require_permission(ctx, :secrets_read),
         :ok <- reject_system_secret(name),
         {:ok, ref} <- Shared.normalize_ref(ref) do
      case Sanctum.Secrets.can_access?(ctx, name, ref) do
        {:ok, allowed} ->
          {:ok, %{allowed: allowed}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to check secret access: #{inspect(reason)}")
          {:error, "Failed to check secret access"}
      end
    end
  end

  def handle(_ctx, %{"action" => "can_access"}) do
    {:error, "Missing required arguments: name, component_ref"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "list_component_grants",
        "component_ref" => ref
      }) do
    with :ok <- Shared.require_permission(ctx, :secrets_read),
         {:ok, ref} <- Shared.normalize_ref(ref) do
      case Sanctum.Secrets.list_component_grants(ctx, ref) do
        {:ok, names} ->
          visible = Enum.reject(names, &Sanctum.Secrets.system_secret?/1)
          {:ok, %{component_ref: ref, granted_secrets: visible}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list component grants: #{inspect(reason)}")
          {:error, "Failed to list component grants"}
      end
    end
  end

  def handle(_ctx, %{"action" => "list_component_grants"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(_ctx, %{"action" => "resolve_granted"}) do
    {:error,
     "Secret resolution is not permitted via MCP. Use 'can_access' to check access or 'list_component_grants' to list grants."}
  end

  def handle(_ctx, _args) do
    {:error,
     "Invalid secret action. Use: set, get, delete, list, grant, revoke, can_access, or list_component_grants"}
  end

  # --- helpers ---

  defp mask_secret(value) when byte_size(value) <= 8, do: "****"

  defp mask_secret(value) do
    first = String.slice(value, 0, 4)
    "#{first}...****"
  end

  defp reject_system_secret(name) do
    if Sanctum.Secrets.system_secret?(name) do
      {:error, "Access denied: system secrets cannot be managed through this interface"}
    else
      :ok
    end
  end

  defp broadcast_secrets_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:secrets", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :secrets_changed)
  end
end
