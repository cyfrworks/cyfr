# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.DoorTool do
  @moduledoc """
  The `door` tool: the server allowlist — who may sign in here. Platform
  admins only (`scope: :platform` on every action).

  `allow` writes an entry (email, user_id, or `*`); `deny` writes a sticky
  exclusion, ejects the person when they are already known
  (`Sanctum.Tenancy.Users.deny/1`) and withdraws the group invitations the
  address was holding either way; `remove` deletes an entry — and, when it was
  an allow, ejects everyone the door would now refuse
  (`Sanctum.Door.reconcile/0`), which is the only way `*` is covered, since
  it names nobody;
  `list` shows the door; `requests` what is waiting on the operator — an
  address a member invited, or the subject of a sign-in the door refused;
  `resolve` approves or drops one.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Door
  alias Sanctum.Door.Store
  alias Sanctum.Tenancy.Users

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    alias Cyfr.Ops.{Arg, Operation}

    Operation.tool(
      [
        Operation.new("door", "list", "List door", [],
          scope: :platform,
          kind: :read,
          planes: [:external]
        ),
        Operation.new("door", "requests", "Requests door", [],
          scope: :platform,
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "allow",
          "Allow door",
          [
            Arg.new("value", :string,
              required: true,
              description: "An email, an IdP subject, or * (allow, deny)"
            ),
            Arg.new("kind", :string,
              description: "How to read value; inferred from its shape when absent",
              enum: ["email", "user_id"]
            ),
            Arg.new("note", :string, nullable: true, description: "Why (allow, deny)")
          ],
          scope: :platform,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "deny",
          "Deny door",
          [
            Arg.new("value", :string,
              required: true,
              description: "An email, an IdP subject, or * (allow, deny)"
            ),
            Arg.new("kind", :string,
              description: "How to read value; inferred from its shape when absent",
              enum: ["email", "user_id"]
            ),
            Arg.new("note", :string, nullable: true, description: "Why (allow, deny)")
          ],
          scope: :platform,
          kind: :destructive,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "remove",
          "Remove door",
          [Arg.new("id", :string, required: true, description: "Entry id (remove, resolve)")],
          scope: :platform,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "resolve",
          "Resolve door",
          [
            Arg.new("id", :string, required: true, description: "Entry id (remove, resolve)"),
            Arg.new("decision", :string,
              required: true,
              description: "For resolve",
              enum: ["allow", "reject"]
            )
          ],
          scope: :platform,
          kind: :write,
          planes: [:external]
        )
      ],
      description:
        "Who may sign in to this server — platform admins only. Entries name an email, an IdP subject (user id), or `*` for anyone the configured provider authenticates. A deny is sticky and ejects the person; requests are invites members made for addresses the door does not know.",
      title: "Server Allowlist"
    )
  end

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
          Logger.error("[DoorTool] door.allow failed: #{inspect(reason)}")
          {:error, {:unavailable, "The door"}}
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

          # An address nobody has signed in with can still be holding group
          # seats. `Users.deny/1` withdraws them for a person it knows; for
          # an address it does not, this is the whole eject.
          withdrawn = withdraw_pending(kind, value)

          rendered =
            render(entry) |> Map.put(:ejected, ejected) |> Map.put(:invites_withdrawn, withdrawn)

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
          {:error,
           {:invalid_argument,
            "That email is a platform admin (CYFR_PLATFORM_ADMIN_EMAILS); remove it there"}}

        {:error, :wildcard_cannot_be_denied} ->
          {:error, {:invalid_argument, "Remove the * entry instead of denying it"}}

        {:error, reason} ->
          Logger.error("[DoorTool] door.deny failed: #{inspect(reason)}")
          {:error, {:unavailable, "The door"}}
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

      # Removing an allow is closing the door on whoever it admitted, and the
      # credentials it issued would otherwise outlive it by their whole TTL.
      # `Door.reconcile/0` re-asks the door about everyone rather than guess
      # which entry admitted whom — the only way `*` is covered, since it
      # names nobody. Standing is untouched: this closes a door, it does not
      # deny a person.
      {:ok, ejected} = if entry.effect == "allow", do: Door.reconcile(), else: {:ok, 0}

      Sanctum.Notify.allowlist_changed()

      {:ok,
       %{id: id, removed: true, ejected: ejected}
       |> with_restore_note(restored)}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Allowlist entry", id}}

      {:error, reason} ->
        Logger.error("[DoorTool] door.remove failed: #{inspect(reason)}")
        {:error, {:unavailable, "The door"}}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "resolve", "id" => id, "decision" => decision})
      when is_binary(id) and decision in ["allow", "reject"] do
    result = Store.resolve(id, String.to_existing_atom(decision), ctx.user_id)
    Sanctum.Notify.allowlist_changed()

    case result do
      {:ok, entry} ->
        {:ok, render(entry)}

      :ok ->
        {:ok, %{id: id, rejected: true}}

      {:error, :not_found} ->
        {:error, {:not_found, "Request", id}}

      {:error, :not_a_request} ->
        {:error, {:invalid_argument, "That entry is not a pending request"}}

      {:error, _} ->
        {:error, {:unavailable, "The door"}}
    end
  end

  def handle(_ctx, %{"action" => action}) when action in ["allow", "deny"],
    do: {:error, {:invalid_argument, "Missing required argument: value"}}

  def handle(_ctx, %{"action" => "remove"}),
    do: {:error, {:invalid_argument, "Missing required argument: id"}}

  def handle(_ctx, %{"action" => "resolve"}),
    do: {:error, {:invalid_argument, "Missing required arguments: id, decision (allow | reject)"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "door.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

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

  # Every invitation the address still holds, dropped once. `Users.deny/1`
  # already did this for each identity that has signed in with it, and the
  # sweep is idempotent, so the count is what a *pending* seat cost.
  defp withdraw_pending("email", value),
    do: Sanctum.Tenancy.Members.withdraw_invites_for_email(value)

  defp withdraw_pending(_kind, _value), do: 0

  defp known_users("email", value), do: Users.list_by_email(value)

  defp known_users("user_id", value) do
    case Users.get_by_identity(value) do
      {:ok, user} -> [user]
      _ -> []
    end
  end

  defp known_users(_kind, _value), do: []

  defp denied_users(kind, value),
    do: kind |> known_users(value) |> Enum.filter(&(&1.status == "denied"))

  # `*` is the wildcard; an `@` makes an email; anything else is an IdP
  # identity key unless the caller said otherwise. The door speaks the
  # provider's terms — it judges a person before any row of theirs exists
  # — so a person's own id here is not an entry it can act on.
  defp kind_for("*", _), do: {:ok, "wildcard"}
  defp kind_for(value, kind) when kind in ["email", "user_id"], do: identity_kind(value, kind)

  defp kind_for(value, nil) do
    identity_kind(value, if(String.contains?(value, "@"), do: "email", else: "user_id"))
  end

  defp kind_for(_value, kind),
    do: {:error, {:invalid_argument, "Invalid kind: #{kind} (email | user_id)"}}

  defp identity_kind(value, "user_id") do
    if Sanctum.Auth.Identity.key?(value),
      do: {:ok, "user_id"},
      else:
        {:error,
         {:invalid_argument,
          "A user_id entry names an IdP identity (provider|issuer|subject); " <>
            "to act on a person, name their email"}}
  end

  defp identity_kind(_value, kind), do: {:ok, kind}

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
