# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.DoorTool do
  @moduledoc """
  The `door` tool: the server allowlist — who may sign in here. Platform
  admins only (`scope: :platform` on every action).

  `allow` writes an entry (email, user_id, or `*`); `deny` writes a sticky
  exclusion and, when the person is already known, ejects them
  (`Sanctum.Tenancy.Users.deny/1`); `remove` deletes an entry; `list` shows
  the door; `requests` the pending invites members asked for; `resolve`
  approves or drops one.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Door.Store
  alias Sanctum.Tenancy.Users

  def handle(%Context{}, %{"action" => "list"}) do
    entries = Store.list()
    {:ok, %{entries: Enum.map(entries, &render/1), count: length(entries)}}
  end

  def handle(%Context{}, %{"action" => "requests"}) do
    requests = Store.requests()
    {:ok, %{requests: Enum.map(requests, &render/1), count: length(requests)}}
  end

  def handle(%Context{} = ctx, %{"action" => "allow", "value" => value} = args)
      when is_binary(value) do
    with {:ok, kind} <- kind_for(value, Map.get(args, "kind")) do
      case Store.allow(kind, value, ctx.user_id, Map.get(args, "note")) do
        {:ok, entry} ->
          # A person denied earlier may sign in again; their own athanor reopens.
          Enum.each(known_users(kind, value), &Users.allow/1)
          {:ok, render(entry)}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] door.allow failed: #{inspect(reason)}")
          {:error, "Failed to write the entry"}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "deny", "value" => value} = args)
      when is_binary(value) do
    with {:ok, kind} <- kind_for(value, Map.get(args, "kind")) do
      case Store.deny(kind, value, ctx.user_id, Map.get(args, "note")) do
        {:ok, entry} ->
          denied = known_users(kind, value)
          Enum.each(denied, &Users.deny/1)
          {:ok, Map.put(render(entry), :ejected, length(denied))}

        {:error, :platform_admin} ->
          {:error, "That email is a platform admin (CYFR_PLATFORM_ADMIN_EMAILS); remove it there"}

        {:error, :wildcard_cannot_be_denied} ->
          {:error, "Remove the * entry instead of denying it"}

        {:error, reason} ->
          Logger.error("[Sanctum.MCP] door.deny failed: #{inspect(reason)}")
          {:error, "Failed to write the entry"}
      end
    end
  end

  def handle(%Context{}, %{"action" => "remove", "id" => id}) when is_binary(id) do
    case Store.remove(id) do
      :ok -> {:ok, %{id: id, removed: true}}
      {:error, :not_found} -> {:error, "Entry not found"}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "resolve", "id" => id, "decision" => decision})
      when is_binary(id) and decision in ["allow", "reject"] do
    case Store.resolve(id, String.to_existing_atom(decision), ctx.user_id) do
      {:ok, entry} -> {:ok, render(entry)}
      :ok -> {:ok, %{id: id, rejected: true}}
      {:error, :not_found} -> {:error, "Request not found"}
      {:error, :not_a_request} -> {:error, "That entry is not a pending request"}
      {:error, _} -> {:error, "Failed to resolve the request"}
    end
  end

  def handle(_ctx, %{"action" => action}) when action in ["allow", "deny"],
    do: {:error, "Missing required argument: value"}

  def handle(_ctx, %{"action" => "remove"}), do: {:error, "Missing required argument: id"}

  def handle(_ctx, %{"action" => "resolve"}),
    do: {:error, "Missing required arguments: id, decision (allow | reject)"}

  def handle(_ctx, %{"action" => action}), do: {:error, "Invalid door action: #{action}"}
  def handle(_ctx, _args), do: {:error, "Missing required argument: action"}

  # The people an entry names, when they are already known here.
  defp known_users("email", value), do: Users.list_by_email(value)

  defp known_users("user_id", value) do
    case Users.get(value) do
      {:ok, user} -> [user]
      _ -> []
    end
  end

  defp known_users(_kind, _value), do: []

  # `*` is the wildcard; an `@` makes an email; anything else is an IdP
  # subject unless the caller said otherwise.
  defp kind_for("*", _), do: {:ok, "wildcard"}
  defp kind_for(_value, kind) when kind in ["email", "user_id"], do: {:ok, kind}

  defp kind_for(value, nil) do
    {:ok, if(String.contains?(value, "@"), do: "email", else: "user_id")}
  end

  defp kind_for(_value, kind), do: {:error, "Invalid kind: #{kind} (email | user_id)"}

  defp render(entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      value: entry.value,
      effect: entry.effect,
      status: entry.status,
      requested_by: entry.requested_by,
      added_by: entry.added_by,
      note: entry.note,
      created_at: entry.created_at
    }
  end
end
