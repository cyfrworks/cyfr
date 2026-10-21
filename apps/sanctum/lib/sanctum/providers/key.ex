# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Key do
  @moduledoc """
  API key tool handlers for the Sanctum MCP provider — create, get, list,
  revoke, rotate, and re-enable API keys.
  """

  require Logger
  require Prima.ConsentSignal
  require Sanctum.Issuance

  # A sensitive change's own answers (`Sanctum.Consent.Authz`), which pass
  # as they are: the confirmation signal is matched apart, by its shape.
  @confirmation_refusals [:identity_stale, :missing_tenant]

  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new(
          "key",
          "create",
          "Create key",
          [
            Arg.new("name", :string,
              required: true,
              description: "Human-readable name for the key"
            ),
            Arg.new("type", :string,
              description: "Key type: application (frontend), service (backend), admin (CI/CD)",
              enum: ["application", "service", "admin"]
            ),
            Arg.new("scope", {:array, Arg.new(nil, :string)},
              description: "Permissions scope for the key"
            ),
            Arg.new("ip_allowlist", {:array, Arg.new(nil, :string)},
              description: "List of allowed IPs/CIDRs (e.g., ['192.168.1.0/24', '10.0.0.1'])"
            ),
            Arg.new("rate_limit", :string, description: "Rate limit (e.g., '100/1m')")
          ],
          kind: :write,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "key",
          "get",
          "Get key",
          [
            Arg.new("name", :string,
              required: true,
              description: "Human-readable name for the key"
            )
          ],
          kind: :read,
          planes: [:external],
          permission: :admin
        ),
        Operation.new("key", "list", "List key", [],
          kind: :read,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "key",
          "revoke",
          "Revoke key",
          [
            Arg.new("name", :string,
              required: true,
              description: "Human-readable name for the key"
            )
          ],
          reduces_authority: true,
          kind: :write,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "key",
          "rotate",
          "Rotate key",
          [
            Arg.new("name", :string,
              required: true,
              description: "Human-readable name for the key"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :admin
        ),
        Operation.new(
          "key",
          "reenable",
          "Re-enable a key a restore suspended",
          [
            Arg.new("key_id", :string,
              required: true,
              description:
                "The id of your key that restoring this home from a backup suspended (key.list shows it)"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :admin,
          consent: :interactive
        )
      ],
      description:
        "Manage API keys - create, get, list, revoke, rotate, or re-enable a key a restore suspended",
      title: "API Key Management"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.ApiKey.list(ctx) do
      {:ok, keys} ->
        {:ok, %{keys: keys, count: length(keys)}}

      {:error, reason} ->
        Logger.error("[Sanctum.Providers.Key] Failed to list keys: #{inspect(reason)}")
        {:error, "Failed to list keys"}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "name" => name}) do
    case Sanctum.ApiKey.get(ctx, name) do
      {:ok, key_info} ->
        {:ok, key_info}

      {:error, :not_found} ->
        {:error, {:not_found, "Key", name}}
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name} = args) do
    with {:ok, key_type} <- parse_key_type_arg(Map.get(args, "type", "application")) do
      opts = %{
        name: name,
        type: key_type,
        scope: Map.get(args, "scope", []),
        rate_limit: Map.get(args, "rate_limit"),
        ip_allowlist: Map.get(args, "ip_allowlist")
      }

      case Sanctum.ApiKey.create(ctx, opts) do
        {:ok, result} ->
          broadcast_api_keys_changed(ctx)
          {:ok, result}

        {:error, :already_exists} ->
          {:error, {:conflict, "Key already exists: #{name}"}}

        {:error, {:scope_exceeds_ceiling, scope_list, ceiling}} ->
          {:error,
           "Scope #{inspect(scope_list)} exceeds allowed scopes for this key type: #{inspect(ceiling)}"}

        {:error, reason} when Sanctum.Issuance.standing_refusal?(reason) ->
          {:error, Sanctum.Issuance.standing_refusal(reason)}

        {:error, {tag, payload} = signal} when Prima.ConsentSignal.is_signal(tag, payload) ->
          {:error, signal}

        {:error, reason} when reason in @confirmation_refusals ->
          {:error, reason}

        {:error, {:conflict, message} = conflict} when is_binary(message) ->
          {:error, conflict}

        # No re-log: the storage layer already logged this failure with the
        # exception detail (Arca.ApiKeyStorage).
        {:error, _reason} ->
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
        {:error, {:not_found, "Key", name}}

      {:error, reason} ->
        Logger.error("[Sanctum.Providers.Key] Failed to revoke key: #{inspect(reason)}")
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
        {:error, {:not_found, "Key", name}}

      {:error, :capability_key_immutable} ->
        {:error,
         "#{name} carries a consent capability and cannot be rotated — " <>
           "revoke it and mint a new key, which asks for consent again"}

      {:error, :suspended} ->
        {:error, suspended_refusal()}

      {:error, reason} when Sanctum.Issuance.standing_refusal?(reason) ->
        {:error, Sanctum.Issuance.standing_refusal(reason)}

      {:error, {tag, payload} = signal} when Prima.ConsentSignal.is_signal(tag, payload) ->
        {:error, signal}

      {:error, reason} when reason in @confirmation_refusals ->
        {:error, reason}

      {:error, {:conflict, message} = conflict} when is_binary(message) ->
        {:error, conflict}

      {:error, reason} ->
        Logger.error("[Sanctum.Providers.Key] Failed to rotate key: #{inspect(reason)}")
        {:error, "Failed to rotate key"}
    end
  end

  def handle(_ctx, %{"action" => "rotate"}) do
    {:error, "Missing required argument: name"}
  end

  def handle(%Context{} = ctx, %{"action" => "reenable", "key_id" => key_id})
      when is_binary(key_id) do
    case Sanctum.ApiKey.reenable(ctx, key_id, :confirmation) do
      {:ok, key} ->
        {:ok, %{reenabled: key}}

      {:error, reason} ->
        {:error, reenable_refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => "reenable"}) do
    {:error,
     %Prima.Refusal{
       class: :invalid_argument,
       reason: :missing_argument,
       message: "Name the key to re-enable by its id (key_id)"
     }}
  end

  def handle(_ctx, _args) do
    {:error, Prima.Provider.invalid_action("key", action_enum())}
  end

  # --- helpers ---

  # A re-enable's refusals, each in the sentence the person reads; the
  # confirmation's own answers pass as they are.
  defp reenable_refusal(:not_found),
    do: %Prima.Refusal{
      class: :not_found,
      reason: :not_found,
      message: "You have no key with that id in this athanor"
    }

  defp reenable_refusal(:revoked),
    do: %Prima.Refusal{
      class: :conflict,
      reason: :revoked,
      message: "That key was revoked, and a revoked key is never re-enabled: create a new one"
    }

  defp reenable_refusal(:not_suspended),
    do: %Prima.Refusal{
      class: :conflict,
      reason: :not_suspended,
      message: "That key is not suspended, so there is nothing to re-enable"
    }

  defp reenable_refusal(reason) when reason in [:database_error, :not_owner, :unavailable],
    do: Prima.Refusal.classify(:unavailable)

  defp reenable_refusal(reason) when Sanctum.Issuance.standing_refusal?(reason),
    do: Sanctum.Issuance.standing_refusal(reason)

  defp reenable_refusal(reason), do: reason

  defp suspended_refusal,
    do: %Prima.Refusal{
      class: :conflict,
      reason: :suspended,
      message:
        "This key was suspended when this home was restored from a backup: " <>
          "re-enable it first, then rotate it"
    }

  defp parse_key_type_arg("application"), do: {:ok, :application}
  defp parse_key_type_arg("service"), do: {:ok, :service}
  defp parse_key_type_arg("admin"), do: {:ok, :admin}

  defp parse_key_type_arg(invalid),
    do: {:error, "Invalid key type: #{invalid}. Use: application, service, or admin"}

  defp broadcast_api_keys_changed(ctx),
    do: Sanctum.Telemetry.api_keys_changed(Sanctum.Context.athanor!(ctx))

  defp action_enum, do: Prima.Provider.action_enum(definition())
end
