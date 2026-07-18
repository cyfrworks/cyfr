# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.PolicyTool do
  @moduledoc """
  Host Policy tool handlers for the Sanctum MCP provider — get, set, patch,
  delete, list, effective/ceiling resolution, rate-limit checks, type
  defaults, and migration.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  # Guards can't call functions; pinned at compile time from the SSOT.
  @valid_type_strings Sanctum.ComponentRef.valid_types()

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    with :ok <- Shared.require_permission(ctx, :policy_read) do
      case Sanctum.PolicyStore.list(ctx) do
        {:ok, policies} ->
          formatted =
            Enum.map(policies, fn %{component_ref: ref, policy: policy} ->
              %{component_ref: ref, policy: Map.from_struct(policy)}
            end)

          {:ok, %{policies: formatted, count: length(formatted)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list policies: #{inspect(reason)}")
          {:error, "Failed to list policies"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "component_ref" => ref}) do
    with :ok <- Shared.require_permission(ctx, :policy_read),
         {:ok, ref} <- Shared.normalize_ref(ref) do
      case Sanctum.PolicyStore.get(ctx, ref) do
        {:ok, policy} ->
          {:ok, %{component_ref: ref, policy: Map.from_struct(policy)}}

        {:error, :not_found} ->
          {:error, "Policy not found: #{ref}"}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "set",
          "component_ref" => ref,
          "policy" => policy_map
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with :ok <- Shared.require_permission(ctx, :policy_manage),
         {:ok, ref} <- Shared.normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref),
         {:ok, store_ref, promoted_from} <- Shared.maybe_promote_to_name_level(ref, pin_version) do
      case Sanctum.PolicyStore.put(ctx, store_ref, policy_map) do
        :ok ->
          broadcast_policies_changed(ctx)
          result = %{stored: true, component_ref: store_ref}

          result =
            if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result

          {:ok, result}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to set policy: #{inspect(reason)}")
          {:error, "Failed to set policy"}
      end
    end
  end

  def handle(_ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: component_ref, policy"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "patch",
          "component_ref" => ref,
          "field" => field,
          "value" => value
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with :ok <- Shared.require_permission(ctx, :policy_manage),
         {:ok, ref} <- Shared.normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref),
         {:ok, store_ref, promoted_from} <- Shared.maybe_promote_to_name_level(ref, pin_version) do
      case Sanctum.PolicyStore.update_field(ctx, store_ref, field, value) do
        :ok ->
          broadcast_policies_changed(ctx)
          result = %{updated: true, component_ref: store_ref, field: field}

          result =
            if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result

          {:ok, result}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to update policy field: #{inspect(reason)}")
          {:error, "Failed to update policy field"}
      end
    end
  end

  def handle(_ctx, %{"action" => "patch"}) do
    {:error, "Missing required arguments: component_ref, field, value"}
  end

  def handle(%Context{} = ctx, %{"action" => "delete", "component_ref" => ref}) do
    with :ok <- Shared.require_permission(ctx, :policy_manage),
         {:ok, ref} <- Shared.normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref) do
      case Sanctum.PolicyStore.delete(ctx, ref) do
        :ok ->
          broadcast_policies_changed(ctx)
          {:ok, %{deleted: true, component_ref: ref}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to delete policy: #{inspect(reason)}")
          {:error, "Failed to delete policy"}
      end
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "get_effective", "component_ref" => ref}) do
    with :ok <- Shared.require_permission(ctx, :policy_read),
         {:ok, ref} <- Shared.normalize_ref(ref) do
      case Sanctum.Policy.get_effective(ctx, ref) do
        {:ok, policy, %{source: source} = meta} ->
          ceiling = Sanctum.Policy.Ceiling.effective_ceiling(ctx)
          clamped = Sanctum.Policy.Ceiling.clamp(policy, ceiling)

          result =
            Sanctum.Policy.to_map(policy)
            |> Map.put(:policy_source, source)
            |> Map.put(:effective, Sanctum.Policy.to_map(clamped))
            |> Map.put(:ceiling, ceiling)

          result =
            case Map.get(meta, :uncovered_capabilities) do
              nil -> result
              [] -> result
              caps -> Map.put(result, :uncovered_capabilities, caps)
            end

          {:ok, result}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get effective policy: #{inspect(reason)}")
          {:error, "Failed to get effective policy"}
      end
    end
  end

  def handle(_ctx, %{"action" => "get_effective"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "get_ceiling"}) do
    with :ok <- Shared.require_permission(ctx, :policy_read) do
      ceiling = Sanctum.Policy.Ceiling.effective_ceiling(ctx)
      {:ok, %{ceiling: ceiling}}
    end
  end

  def handle(_ctx, %{"action" => "get_ceiling"}) do
    {:error, "Authentication required"}
  end

  def handle(%Context{} = ctx, %{"action" => "check_rate_limit", "component_ref" => ref}) do
    with :ok <- Shared.require_permission(ctx, :policy_read),
         {:ok, ref} <- Shared.normalize_ref(ref),
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, ref) do
      case Sanctum.Policy.check_rate_limit(policy, ctx, ref) do
        {:ok, remaining} ->
          {:ok, %{allowed: true, remaining: remaining}}

        {:error, :rate_limited, retry_after} ->
          {:ok, %{allowed: false, retry_after: retry_after}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Rate limit check failed: #{inspect(reason)}")
          {:error, "Rate limit check failed"}
      end
    else
      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Rate limit check failed: #{inspect(reason)}")
        {:error, "Rate limit check failed"}
    end
  end

  def handle(_ctx, %{"action" => "check_rate_limit"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "get_type_default",
        "component_type" => type_str
      }) do
    with :ok <- Shared.require_permission(ctx, :policy_read),
         {:ok, type_atom} <- parse_component_type(type_str) do
      case Sanctum.PolicyStore.get_type_default(ctx, type_atom) do
        {:ok, policy} ->
          {:ok,
           %{component_type: type_str, source: "stored", policy: Sanctum.Policy.to_map(policy)}}

        {:error, :not_found} ->
          {:ok,
           %{
             component_type: type_str,
             source: "hardcoded",
             policy: Sanctum.Policy.to_map(Sanctum.Policy.default(type_atom))
           }}
      end
    end
  end

  def handle(_ctx, %{"action" => "get_type_default"}) do
    {:error, "Missing required argument: component_type"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "set_type_default",
        "component_type" => type_str,
        "policy" => policy_map
      }) do
    with :ok <- Shared.require_permission(ctx, :policy_manage),
         {:ok, type_atom} <- parse_component_type(type_str),
         {:ok, policy} <- Sanctum.Policy.from_map(policy_map) do
      case Sanctum.PolicyStore.put_type_default(ctx, type_atom, policy) do
        :ok ->
          {:ok, %{stored: true, component_type: type_str}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to set type default: #{inspect(reason)}")
          {:error, "Failed to set type default"}
      end
    end
  end

  def handle(_ctx, %{"action" => "set_type_default"}) do
    {:error, "Missing required arguments: component_type, policy"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "delete_type_default",
        "component_type" => type_str
      }) do
    with :ok <- Shared.require_permission(ctx, :policy_manage),
         {:ok, type_atom} <- parse_component_type(type_str) do
      case Sanctum.PolicyStore.delete_type_default(ctx, type_atom) do
        :ok ->
          {:ok, %{deleted: true, component_type: type_str}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to delete type default: #{inspect(reason)}")
          {:error, "Failed to delete type default"}
      end
    end
  end

  def handle(_ctx, %{"action" => "delete_type_default"}) do
    {:error, "Missing required argument: component_type"}
  end

  def handle(%Context{} = ctx, %{"action" => "list_type_defaults"}) do
    with :ok <- Shared.require_permission(ctx, :policy_read) do
      {:ok, defaults} = Sanctum.PolicyStore.list_type_defaults(ctx)

      formatted =
        Enum.map(defaults, fn %{type: type, source: source, policy: policy} ->
          %{component_type: type, source: source, policy: Sanctum.Policy.to_map(policy)}
        end)

      {:ok, %{type_defaults: formatted}}
    end
  end

  def handle(%Context{} = ctx, %{
        "action" => "migrate",
        "component_ref" => ref
      }) do
    with :ok <- Shared.require_permission(ctx, :policy_manage),
         {:ok, ref} <- Shared.normalize_ref(ref),
         :ok <- require_policy_ownership(ctx, ref) do
      # Only versioned refs can be migrated
      case Sanctum.ComponentRef.parse(ref) do
        {:ok, %Sanctum.ComponentRef{version: nil}} ->
          {:error, "Reference is already name-level: #{ref}"}

        {:ok, parsed} ->
          name_ref = Sanctum.ComponentRef.to_name_ref(parsed)

          case Sanctum.PolicyStore.get(ctx, ref) do
            {:ok, policy} ->
              case Sanctum.PolicyStore.put(ctx, name_ref, policy) do
                :ok ->
                  Sanctum.PolicyStore.delete(ctx, ref)
                  {:ok, %{migrated: true, from: ref, to: name_ref}}

                {:error, reason} ->
                  Logger.error("[Sanctum.MCP] Failed to migrate policy: #{inspect(reason)}")
                  {:error, "Failed to store name-level policy"}
              end

            {:error, :not_found} ->
              {:error, "No version-specific policy found for: #{ref}"}

            {:error, reason} ->
              Logger.error(
                "[Sanctum.MCP] Failed to read policy for migration: #{inspect(reason)}"
              )

              {:error, "Failed to read policy for migration"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def handle(_ctx, %{"action" => "migrate"}) do
    {:error, "Missing required argument: component_ref"}
  end

  def handle(_ctx, _args) do
    {:error,
     "Invalid policy action. Use: get, set, patch, delete, list, get_effective, get_ceiling, check_rate_limit, get_type_default, set_type_default, delete_type_default, list_type_defaults, or migrate"}
  end

  # --- helpers ---

  defp parse_component_type(type) when type in @valid_type_strings do
    {:ok, String.to_existing_atom(type)}
  end

  defp parse_component_type(invalid) do
    {:error,
     "Invalid component_type '#{inspect(invalid)}'. Must be one of: catalyst, formula, reagent, tincture"}
  end

  defp require_policy_ownership(ctx, ref) do
    if Context.has_permission?(ctx, :admin) do
      :ok
    else
      case Sanctum.ComponentRef.parse(ref) do
        {:ok, %Sanctum.ComponentRef{namespace: "local"}} ->
          :ok

        _ ->
          {:error,
           "Unauthorized: modifying policies for non-local components requires admin permission"}
      end
    end
  end

  defp broadcast_policies_changed(ctx) do
    topic = Sanctum.PubSub.topic("prism:policies", ctx)
    Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :policies_changed)
  end
end
