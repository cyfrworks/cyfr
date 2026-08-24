# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.KeyTool do
  @moduledoc """
  API key tool handlers for the Sanctum MCP provider — create, get, list,
  revoke, and rotate API keys.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    %{
      name: "key",
      title: "API Key Management",
      description: "Manage API keys - create, get, list, revoke, or rotate keys",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: false,
        actions: %{
          "create" => %{kind: :write, planes: [:external], permission: :admin},
          "get" => %{kind: :read, planes: [:external], permission: :admin},
          "list" => %{kind: :read, planes: [:external], permission: :admin},
          "revoke" => %{kind: :write, planes: [:external], permission: :admin},
          "rotate" => %{kind: :write, planes: [:external], permission: :admin}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["create", "get", "list", "revoke", "rotate"],
            "description" => "Action to perform"
          },
          "name" => %{
            "type" => "string",
            "description" => "Human-readable name for the key"
          },
          "key" => %{
            "type" => "string",
            "description" => "API key value (for validation)"
          },
          "type" => %{
            "type" => "string",
            "enum" => ["application", "service", "admin"],
            "description" => "Key type: application (frontend), service (backend), admin (CI/CD)"
          },
          "scope" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Permissions scope for the key"
          },
          "rate_limit" => %{
            "type" => "string",
            "description" => "Rate limit (e.g., '100/1m')"
          },
          "ip_allowlist" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of allowed IPs/CIDRs (e.g., ['192.168.1.0/24', '10.0.0.1'])"
          }
        },
        "required" => ["action"]
      }
    }
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.ApiKey.list(ctx) do
      {:ok, keys} ->
        {:ok, %{keys: keys, count: length(keys)}}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to list keys: #{inspect(reason)}")
        {:error, "Failed to list keys"}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "name" => name}) do
    case Sanctum.ApiKey.get(ctx, name) do
      {:ok, key_info} ->
        {:ok, key_info}

      {:error, :not_found} ->
        {:error, "Key not found: #{name}"}
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with {:ok, key_type} <- parse_key_type_arg(Map.get(args, "type", "application")) do
      scope = Map.get(args, "scope", [])

      scope =
        cond do
          is_binary(scope) -> String.split(scope, ",", trim: true) |> Enum.map(&String.trim/1)
          is_list(scope) -> scope
          true -> []
        end

      opts = %{
        name: name,
        type: key_type,
        scope: scope,
        rate_limit: Map.get(args, "rate_limit"),
        ip_allowlist: Map.get(args, "ip_allowlist")
      }

      case Sanctum.ApiKey.create(ctx, opts) do
        {:ok, result} ->
          broadcast_api_keys_changed(ctx)
          {:ok, result}

        {:error, :already_exists} ->
          {:error, "Key already exists: #{name}"}

        {:error, {:invalid_key_type, type}} ->
          {:error, "Invalid key type: #{type}. Use: application, service, or admin"}

        {:error, {:scope_exceeds_ceiling, scope_list, ceiling}} ->
          {:error,
           "Scope #{inspect(scope_list)} exceeds allowed scopes for this key type: #{inspect(ceiling)}"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to create key: #{inspect(reason)}")
          {:error, "Failed to create key"}
      end
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "name" => name} = _args) do
    with :ok <- Sanctum.ApiKey.revoke(ctx, name) do
      broadcast_api_keys_changed(ctx)
      {:ok, %{revoked: true, name: name}}
    else
      {:error, :not_found} ->
        {:error, "Key not found: #{name}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to revoke key: #{inspect(reason)}")
        {:error, "Failed to revoke key"}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "rotate", "name" => name} = _args) do
    case Sanctum.ApiKey.rotate(ctx, name) do
      {:ok, result} ->
        broadcast_api_keys_changed(ctx)
        {:ok, result}

      {:error, :not_found} ->
        {:error, "Key not found: #{name}"}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to rotate key: #{inspect(reason)}")
        {:error, "Failed to rotate key"}
    end
  end

  def handle(_ctx, %{"action" => "rotate"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(_ctx, _args) do
    {:error, Emissary.MCP.ToolProvider.invalid_action("key", action_enum())}
  end

  # --- helpers ---

  defp parse_key_type_arg("application"), do: {:ok, :application}
  defp parse_key_type_arg("service"), do: {:ok, :service}
  defp parse_key_type_arg("admin"), do: {:ok, :admin}

  defp parse_key_type_arg(invalid),
    do: {:error, "Invalid key type: #{invalid}. Use: application, service, or admin"}

  defp broadcast_api_keys_changed(ctx) do
    topic = Prism.Topics.api_keys(ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :api_keys_changed)
  end

  defp action_enum, do: get_in(definition(), [:input_schema, "properties", "action", "enum"])
end
