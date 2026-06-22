# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.PermissionTool do
  @moduledoc """
  Permission tool handlers for the Sanctum MCP provider — get, set, and
  list RBAC permissions.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    with :ok <- Shared.require_permission(ctx, :users_read) do
      case Sanctum.Permission.list(ctx) do
        {:ok, entries} ->
          {:ok, %{permissions: entries, count: length(entries)}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to list permissions: #{inspect(reason)}")
          {:error, "Failed to list permissions"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "get", "subject" => subject}) do
    with :ok <- Shared.require_permission(ctx, :users_read) do
      case Sanctum.Permission.get(ctx, subject) do
        {:ok, perms} ->
          {:ok, %{subject: subject, permissions: perms}}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] Failed to get permissions: #{inspect(reason)}")
          {:error, "Failed to get permissions"}
      end
    end
  end

  def handle(_ctx, %{"action" => "get"}) do
    {:error, "Missing required argument: subject"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "set",
          "subject" => subject,
          "permissions" => perms
        } = _args
      ) do
    with :ok <- Shared.require_permission(ctx, :users_manage),
         :ok <- validate_permission_grant(ctx, subject, perms),
         :ok <- Sanctum.Permission.set(ctx, subject, perms) do
      {:ok, %{updated: true, subject: subject, permissions: perms}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("[Sanctum.MCP] Failed to set permissions: #{inspect(reason)}")
        {:error, "Failed to set permissions"}
    end
  end

  def handle(_ctx, %{"action" => "set"}) do
    {:error, "Missing required arguments: subject, permissions"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid permission action. Use: get, set, or list"}
  end

  # --- helpers ---

  defp validate_permission_grant(%Context{} = ctx, subject, perms) do
    is_admin = Context.has_permission?(ctx, :admin)

    cond do
      is_admin ->
        :ok

      subject == ctx.user_id ->
        {:error, "Cannot modify own permissions without admin privilege"}

      true ->
        granted = Enum.map(perms, &Sanctum.Atoms.safe_to_permission_atom/1)
        caller_perms = ctx.permissions

        unauthorized =
          Enum.reject(granted, fn perm -> MapSet.member?(caller_perms, perm) end)

        if unauthorized == [] do
          :ok
        else
          names = unauthorized |> Enum.map(&to_string/1) |> Enum.join(", ")
          {:error, "Cannot grant permissions you do not possess: #{names}"}
        end
    end
  end
end
