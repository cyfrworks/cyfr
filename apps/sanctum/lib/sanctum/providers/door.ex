# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Door do
  @moduledoc """
  The `door` tool: the server allowlist — who may sign in here. Platform
  admins only (`scope: :platform` on every action).

  The entry's kind is read from its value (`entry_for/2`): `*` is the
  wildcard, a person identifier (`per_…`) an identifier, a person's own
  id (`usr_…`) a person, and a handle (`@name`) the identifier the
  registry answers for it (`Sanctum.Handle.identifier/1`), resolved
  before anything is written and written as an identifier entry labelled
  with the handle. The entry keeps the identifier, so a handle the
  registry later gives someone else moves no access; `list` shows the
  label beside the identifier.

  `allow` writes an allow of an identifier or `*`, by which the door
  admits an account at sign-in. Every person here is an account's, and the
  door admits a person only by their account's identifier: one with no
  identity row names no account and is refused (`Sanctum.Door`), so an
  allow never names a person's own id.
  `deny` writes a sticky exclusion of a person or an identifier, ejects
  the person when they are already known
  (`Sanctum.Tenancy.Users.deny/1`) and withdraws the invitations the
  identifier holds in shared threads either way
  (`Sanctum.SharedThreads.withdraw_identifier/1`); `remove` deletes an entry — and,
  when it was an allow, ejects everyone the door would now refuse
  (`Sanctum.Door.reconcile/0`), which is the only way `*` is covered,
  since it names nobody; `list` shows the door; `requests` what is
  waiting on the operator — an identifier someone invited into a thread, or one whose
  sign-in the door refused; `resolve` approves or drops one.
  """

  require Logger

  @not_restored "denied people were not restored and stay denied"

  alias Sanctum.Context
  alias Sanctum.Door
  alias Sanctum.Door.Store
  alias Sanctum.Tenancy.Users

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new("door", "list", "List sign-in allowlist entries", [],
          scope: :platform,
          kind: :read,
          planes: [:external]
        ),
        Operation.new("door", "requests", "List sign-in requests", [],
          scope: :platform,
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "allow",
          "Allow sign-in",
          [
            Arg.new("value", :string,
              required: true,
              description:
                "A person identifier (per_…), a handle (@name) or * to allow; a person's id (usr_…), a person identifier or a handle to deny. A handle is resolved at the registry and its identifier written, labelled with the handle (allow, deny)"
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
          "Deny sign-in",
          [
            Arg.new("value", :string,
              required: true,
              description:
                "A person identifier (per_…), a handle (@name) or * to allow; a person's id (usr_…), a person identifier or a handle to deny. A handle is resolved at the registry and its identifier written, labelled with the handle (allow, deny)"
            ),
            Arg.new("note", :string, nullable: true, description: "Why (allow, deny)")
          ],
          scope: :platform,
          reduces_authority: true,
          kind: :destructive,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "remove",
          "Remove a sign-in allowlist entry",
          [Arg.new("id", :string, required: true, description: "Entry id (remove, resolve)")],
          scope: :platform,
          kind: :write,
          planes: [:external]
        ),
        Operation.new(
          "door",
          "resolve",
          "Resolve a sign-in request",
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
        "Who may sign in to this server — platform admins only. An account signs in when `*` or an allow names its identifier, and a deny wins over both; setup and a redeemed invitation write the allow of the account they admit. A deny names a person or an identifier, stays until it is removed and ejects the person; an allow or a deny by handle (@name) writes the identifier the handle names. Requests are identifiers members invited or whose sign-in the allowlist refused.",
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
    with {:ok, kind, value, label} <- entry_for(value, "allow") do
      case Store.allow(kind, value, ctx.user_id, note: Map.get(args, "note"), label: label) do
        {:ok, entry} ->
          # A person denied earlier may sign in again and their own athanor
          # reopens; the thread seats the deny removed stay removed — a
          # thread's people add them again. Said in the result, not left to guess.
          restored = denied_users(kind, value)
          failed = refused(restored, &Users.allow/1)
          Sanctum.Notify.allowlist_changed()

          partial(
            failed,
            restored,
            "Sign-in is allowed",
            @not_restored,
            with_restore_note(render(entry), restored)
          )

        {:error, reason} ->
          Logger.error("[Sanctum.Providers.Door] door.allow failed: #{inspect(reason)}")
          {:error, {:unavailable, "The sign-in allowlist"}}
      end
    end
  end

  def handle(%Context{} = ctx, %{"action" => "deny", "value" => value} = args)
      when is_binary(value) do
    with {:ok, kind, value, label} <- entry_for(value, "deny") do
      case Store.deny(kind, value, ctx.user_id, note: Map.get(args, "note"), label: label) do
        {:ok, entry} ->
          denied = known_users(kind, value)
          failed = refused(denied, &Users.deny/1)
          ejected = length(denied) - length(failed)

          # An identifier nobody here holds can still hold invitations in
          # shared threads. `Users.deny/1` withdraws them for a person it
          # knows; for an identifier it does not, this is the whole eject.
          withdrawn = withdraw_pending(kind, value)

          rendered =
            render(entry) |> Map.put(:ejected, ejected) |> Map.put(:invites_withdrawn, withdrawn)

          Sanctum.Notify.allowlist_changed()

          # The entry is written (the door is shut) but a person's sessions,
          # keys or rows may survive — say so rather than report a clean eject.
          partial(failed, denied, "Sign-in is denied", "known people were not ejected", rendered)

        {:error, :platform_admin} ->
          {:error,
           {:invalid_argument,
            "That is this server's platform administrator, who is never denied here"}}

        {:error, reason} ->
          Logger.error("[Sanctum.Providers.Door] door.deny failed: #{inspect(reason)}")
          {:error, {:unavailable, "The sign-in allowlist"}}
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

      failed = refused(restored, &Users.allow/1)

      # Removing an allow is closing the door on whoever it admitted, and the
      # credentials it issued would otherwise outlive it by their whole TTL.
      # `Door.reconcile/0` re-asks the door about everyone rather than guess
      # which entry admitted whom — the only way `*` is covered, since it
      # names nobody. Standing is untouched: this closes a door, it does not
      # deny a person.
      {:ok, ejected} = if entry.effect == "allow", do: Door.reconcile(), else: {:ok, 0}

      Sanctum.Notify.allowlist_changed()

      partial(
        failed,
        restored,
        "The entry is removed",
        @not_restored,
        with_restore_note(%{id: id, removed: true, ejected: ejected}, restored)
      )
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Allowlist entry", id}}

      {:error, reason} ->
        Logger.error("[Sanctum.Providers.Door] door.remove failed: #{inspect(reason)}")
        {:error, {:unavailable, "The sign-in allowlist"}}
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
        {:error, {:unavailable, "The sign-in allowlist"}}
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
      note: "Their own athanor is reopened; thread seats removed by the deny are not restored"
    })
  end

  # `transition` (`Users.deny/1` or `Users.allow/1`) run for each person,
  # answering the ones it refused, each with its refusal.
  defp refused(people, transition) do
    for user <- people,
        {:error, reason} <- [transition.(user)],
        do: {user, Sanctum.Refusals.classify(reason)}
  end

  # What an entry's write answers once it has moved its people: its result
  # when every person moved, else one refusal of the first failure's class
  # whose sentence says the write stands and names each person who did not
  # move with their own refusal's sentence.
  defp partial([], _people, _done, _left, result), do: {:ok, result}

  defp partial([{_user, first} | _] = failed, people, done, left, _result) do
    reasons =
      Enum.map_join(failed, "; ", fn {user, refusal} -> "#{user.id}: #{refusal.message}" end)

    {:error,
     %{
       first
       | message: "#{done}, but #{length(failed)} of #{length(people)} #{left} — #{reasons}"
     }}
  end

  # Every invitation the identifier still holds, withdrawn once; the count
  # is what a pending seat cost.
  defp withdraw_pending("identifier", value) do
    case Sanctum.SharedThreads.withdraw_identifier(value) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  defp withdraw_pending(_kind, _value), do: 0

  defp known_users("person", value) do
    case Users.get(value) do
      {:ok, user} -> [user]
      _ -> []
    end
  end

  defp known_users("identifier", value) do
    case Users.get_by_identifier(value) do
      {:ok, user} -> [user]
      _ -> []
    end
  end

  defp known_users(_kind, _value), do: []

  defp denied_users(kind, value),
    do: kind |> known_users(value) |> Enum.filter(&(&1.status == "denied"))

  # The entry a value names, as `{kind, value, label}`. A handle is asked
  # of the registry first, and only its answer's identifier is written:
  # the resolution writes nothing, so a call stopped before the write
  # leaves no entry.
  defp entry_for("@" <> handle, _effect) do
    with {:ok, identifier} <- Sanctum.Handle.identifier(handle),
         do: {:ok, "identifier", identifier, handle}
  end

  defp entry_for(value, effect) do
    with {:ok, kind} <- kind_for(value, effect), do: {:ok, kind, value, nil}
  end

  # The value decides the kind: `*` is the wildcard, a person identifier's
  # shape (`per_` and 64 hexadecimal digits) an identifier, and a person's
  # own id a person. An allow names an identifier or `*`; a deny a person
  # or an identifier.
  defp kind_for(value, effect) do
    kind =
      cond do
        value == "*" -> "wildcard"
        Prima.Identity.Encoding.identifier?(value) -> "identifier"
        Prima.PersonId.person?(value) -> "person"
        true -> nil
      end

    cond do
      kind in Arca.Doors.kinds(effect) -> {:ok, kind}
      is_nil(kind) -> {:error, {:invalid_argument, unread(effect)}}
      true -> {:error, {:invalid_argument, refused_kind(kind, effect)}}
    end
  end

  defp unread("allow"),
    do: "Allow names a person identifier (per_ and 64 hexadecimal digits), a handle (@name) or *"

  defp unread("deny"),
    do:
      "Deny names a person's id (usr_…), a person identifier (per_ and 64 hexadecimal digits) " <>
        "or a handle (@name)"

  defp refused_kind("person", "allow"),
    do:
      "An allow names an account by its identifier (per_…) or name (@name), or *, never a " <>
        "person's own id (usr_…); removing a deny lets a person back in"

  defp refused_kind("wildcard", "deny"),
    do: "Remove the * entry instead of denying it"

  # The label is a key only when the entry was made from a handle.
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
    |> then(&if(is_binary(entry.label), do: Map.put(&1, :label, entry.label), else: &1))
  end
end
