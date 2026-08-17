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
          # A person denied earlier may sign in again and their own athanor
          # reopens; the group seats the deny removed stay removed — a
          # member adds them again. Said in the result, not left to guess.
          restored = denied_users(kind, value)
          Enum.each(restored, &Users.allow/1)
          Sanctum.Notify.allowlist_changed()
          {:ok, with_restore_note(render(entry), restored)}

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
          results = Enum.map(denied, &Users.deny/1)
          ejected = Enum.count(results, &match?({:ok, _}, &1))
          rendered = Map.put(render(entry), :ejected, ejected)
          Sanctum.Notify.allowlist_changed()

          if ejected == length(denied) do
            {:ok, rendered}
          else
            # The entry is written (the door is shut) but a person's sessions,
            # keys or rows may survive — say so rather than report a clean eject.
            {:error,
             "Denied at the door, but ejecting #{length(denied) - ejected} of #{length(denied)} " <>
               "known accounts failed — retry deny to finish"}
          end

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
    with {:ok, entry} <- Store.get(id),
         :ok <- Store.remove(id) do
      # Removing a deny is letting the person back through: undo what the
      # deny did to their account, exactly as `allow` does — otherwise they
      # stay `denied` with no entry left to explain why.
      restored =
        if entry.effect == "deny",
          do: denied_users(entry.kind, entry.value),
          else: []

      Enum.each(restored, &Users.allow/1)
      Sanctum.Notify.allowlist_changed()
      {:ok, with_restore_note(%{id: id, removed: true}, restored)}
    else
      {:error, :not_found} -> {:error, "Entry not found"}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "resolve", "id" => id, "decision" => decision})
      when is_binary(id) and decision in ["allow", "reject"] do
    result = Store.resolve(id, String.to_existing_atom(decision), ctx.user_id)
    Sanctum.Notify.allowlist_changed()

    case result do
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
  # Allowing a denied person back reopens their own athanor only; the
  # result says what did not come back so the operator re-adds them where
  # they belong.
  defp with_restore_note(result, []), do: result

  defp with_restore_note(result, restored) do
    Map.merge(result, %{
      restored: length(restored),
      note: "Their own athanor is reopened; group seats removed by the deny are not restored"
    })
  end

  defp known_users("email", value), do: Users.list_by_email(value)

  defp known_users("user_id", value) do
    case Users.get(value) do
      {:ok, user} -> [user]
      _ -> []
    end
  end

  defp known_users(_kind, _value), do: []

  defp denied_users(kind, value),
    do: kind |> known_users(value) |> Enum.filter(&(&1.status == "denied"))

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
