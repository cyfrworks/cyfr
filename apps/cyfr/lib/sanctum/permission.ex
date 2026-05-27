# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Permission do
  @moduledoc """
  RBAC user permissions management for CYFR.

  Provides an interface for storing and retrieving user permissions
  via `Arca.PermissionStorage`.

  ## Usage

      ctx = Sanctum.TestContext.local()

      # Set permissions for a user
      :ok = Sanctum.Permission.set(ctx, "user@example.com", ["execute", "component.publish"])

      # Get permissions for a user
      {:ok, ["execute", "component.publish"]} = Sanctum.Permission.get(ctx, "user@example.com")

      # List all users with permissions
      {:ok, [%{subject: "user@example.com", permissions: [...]}]} = Sanctum.Permission.list(ctx)

      # Check if user has a specific permission
      true = Sanctum.Permission.has?(ctx, "user@example.com", "execute")

  ## Storage

  Permissions are stored via `Arca.PermissionStorage`.
  """

  require Logger

  alias Sanctum.Context

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get permissions for a subject (user or resource).

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Permission.set(ctx, "user@example.com", ["execute"])
      :ok
      iex> Sanctum.Permission.get(ctx, "user@example.com")
      {:ok, ["execute"]}

  """
  def get(%Context{} = ctx, subject) when is_binary(subject) do
    Context.require_tenant!(ctx)

    case Arca.PermissionStorage.get_permissions(
           subject,
           scope_type(ctx),
           org_id(ctx),
           project_id(ctx)
         ) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, perms} -> {:ok, perms}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:ok, []}
    end
  end

  @doc """
  Set permissions for a subject (user or resource).

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Permission.set(ctx, "user@example.com", ["execute", "component.publish"])
      :ok

  """
  def set(%Context{} = ctx, subject, perms) when is_binary(subject) and is_list(perms) do
    # Chokepoint: an upsert is NOT a query, so the where_org_id/2 fail-closed
    # guard cannot protect it — the Sanctum-layer require_tenant! is required
    # here to stop an org-less write (rejected by `Sanctum.TenantPolicy`)
    # landing in the shared "" RBAC bucket.
    Context.require_tenant!(ctx)

    case Jason.encode(perms) do
      {:ok, json} ->
        case Arca.PermissionStorage.set_permissions(
               subject,
               json,
               scope_type(ctx),
               org_id(ctx),
               project_id(ctx)
             ) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  @doc """
  List all subjects with their permissions.
  """
  def list(%Context{} = ctx) do
    Context.require_tenant!(ctx)

    case Arca.PermissionStorage.list_permissions(scope_type(ctx), org_id(ctx), project_id(ctx)) do
      {:ok, rows} ->
        entries =
          rows
          |> Enum.map(fn row ->
            perms =
              case Jason.decode(row.permissions) do
                {:ok, p} -> p
                _ -> []
              end

            %{subject: row.subject, permissions: perms}
          end)

        {:ok, entries}

      error ->
        error
    end
  end

  @doc """
  Check if a subject has a specific permission.

  Returns `true` if the permission is granted, `false` otherwise.
  On error, returns `false` (fail-closed behavior for security) and logs a warning.

  For explicit error handling, use `check_permission/3` instead.
  """
  def has?(%Context{} = ctx, subject, permission)
      when is_binary(subject) and is_binary(permission) do
    case get(ctx, subject) do
      {:ok, perms} ->
        permission in perms or "*" in perms

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Permission] Permission check failed for #{subject}: #{inspect(reason)}, returning false (fail-closed). " <>
            "Use check_permission/3 for explicit error handling."
        )

        false
    end
  end

  @doc """
  Check if a subject has a specific permission, with explicit error handling.

  Returns:
  - `{:ok, true}` if the permission is granted
  - `{:ok, false}` if the permission is denied
  - `{:error, reason}` if an error occurred (e.g., I/O error, decryption failure)

  Use this function when you need to distinguish between "permission denied"
  and "system error" conditions.
  """
  @spec check_permission(Context.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def check_permission(%Context{} = ctx, subject, permission)
      when is_binary(subject) and is_binary(permission) do
    case get(ctx, subject) do
      {:ok, perms} -> {:ok, permission in perms or "*" in perms}
      {:error, _} = error -> error
    end
  end

  @doc """
  Delete permissions for a subject.
  """
  def delete(%Context{} = ctx, subject) when is_binary(subject) do
    Context.require_tenant!(ctx)

    case Arca.PermissionStorage.delete_permissions(
           subject,
           scope_type(ctx),
           org_id(ctx),
           project_id(ctx)
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get permissions for a specific resource reference.

  Returns the permissions associated with the resource path/reference,
  used for MCP resource access control.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Permission.get_for_resource(ctx, "components/my-component:1.0")
      {:ok, ["read", "execute"]}

  """
  def get_for_resource(%Context{} = ctx, reference) when is_binary(reference) do
    resource_key = "resource:#{reference}"
    get(ctx, resource_key)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp scope_type(ctx), do: to_string(ctx.scope)
  defp org_id(ctx), do: ctx.org_id
  defp project_id(ctx), do: ctx.project_id
end
