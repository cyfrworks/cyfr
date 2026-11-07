# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Users do
  @moduledoc """
  The people this server knows: each person is the plain map
  `Arca.Users` answers for their row.

  A row is written only by an admission (`Sanctum.Newcomer`), together
  with the person's identity row; the door, invited shared-thread seats
  and per-person preferences key off it. The person's identifier is on
  that identity row, never on the `users` row (`identifier/1`).
  `deny/1` and `allow/1` are the operator's eject and re-admit: a denied
  person loses their sessions and API keys, their own athanor is archived
  (nothing deleted), their seats in shared threads are removed and the
  invitations their identifier was still holding there are withdrawn;
  allowing them again reopens the
  door and the athanor, and leaves the revoked credentials revoked.

  ## What is decided here, and what is stored below

  The statements are `Arca.Users`'. What stays here is the deciding: what
  an eject costs the person, and what an unanswerable read should read
  as. A person is not a row inside an
  athanor — they exist before any athanor does and sit in several at once
  — so every call runs as the server (`Prima.Actor.system/0`), which is
  what `Arca.Users` requires and says why.
  """

  alias Sanctum.Tenancy.Athanors

  @typedoc "A person's row, as the plain map `Arca.Users` answers."
  @type user :: %{required(:id) => String.t(), optional(atom()) => term()}

  @doc """
  The person a person identifier names here, by their identity row
  (`Arca.PersonIdentities.lookup_identifier/2`).
  """
  @spec get_by_identifier(String.t()) :: {:ok, user()} | {:error, :not_found | :database_error}
  def get_by_identifier(identifier) when is_binary(identifier) do
    case Arca.PersonIdentities.lookup_identifier(server(), identifier) do
      {:ok, %{user_id: user_id}} -> get(user_id)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :database_error}
    end
  end

  @doc """
  The person's identifier (`per_…`), read from their identity row beside
  the `users` row (`Arca.PersonIdentities`), which the `users` row does not
  carry: `{:ok, identifier}`, or `{:error, :not_found}` for a person with
  no identity row.
  """
  @spec identifier(String.t()) ::
          {:ok, String.t() | nil} | {:error, :not_found | :cross_tenant | :database_error}
  def identifier(user_id) when is_binary(user_id) do
    with {:ok, row} <- Arca.PersonIdentities.get(server(), user_id),
         do: {:ok, row.identifier}
  end

  @spec get(String.t()) :: {:ok, user()} | {:error, :not_found | :database_error}
  def get(id), do: Arca.Users.get(server(), id)

  @doc """
  How a person is named to other people: their display name, else their
  email, else `@` and the name their account holds at cyfr.run once this
  CYFR recorded it (`users.namespace`), else "someone". A person's id is
  never shown: a row that cannot be read is "someone" too.

  Here rather than beside a caller because it is a fact about the `users`
  row, read by domains that must not depend on each other: the agent
  harness prefixing a turn's lines by who said them, a pair named after
  the other person, and the console naming people.
  """
  @spec display_name(String.t() | nil) :: String.t()
  def display_name(nil), do: "someone"

  def display_name(user_id) when is_binary(user_id) do
    case get(user_id) do
      {:ok, user} -> named(user)
      {:error, _unread} -> "someone"
    end
  end

  defp named(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp named(%{email: email}) when is_binary(email) and email != "", do: email
  defp named(%{namespace: name}) when is_binary(name) and name != "", do: "@" <> name
  defp named(_row), do: "someone"

  @doc """
  Whether `athanor_id` is this person's own athanor: the athanor row's
  `owner_user_id` names them.

  The one predicate behind "is the caller at home": a running chain reads
  notes across athanors only from there, and an assistant's line is the
  person's to say aloud only when it was said there. It reads the owner on
  the athanor's row, as the focus does (`Sanctum.Context.focus/2`), so the
  domains that ask it cannot drift from the row that answers. A store that
  cannot answer is false.
  """
  @spec own_athanor?(String.t() | nil, String.t() | nil) :: boolean()
  def own_athanor?(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    match?({:ok, %{owner_user_id: ^user_id}}, Athanors.get(athanor_id))
  end

  def own_athanor?(_user_id, _athanor_id), do: false

  @doc "The identity whose cyfr.run namespace this is, if any."
  @spec get_by_namespace(String.t()) :: {:ok, user()} | {:error, :not_found | :database_error}
  def get_by_namespace(namespace) when is_binary(namespace) and namespace != "",
    do: Arca.Users.get_by_namespace(server(), namespace)

  @doc """
  Everyone the server knows, newest first. A platform view, paged with
  `limit:` (default and ceiling `Arca.Users.max_page/0`) and `offset:`.
  """
  @spec list(keyword()) :: [user()]
  def list(opts \\ []) do
    # Deliberate default: the operator's people page — a display read that
    # decides nothing; an outage renders an empty page, not a refusal.
    rows_or_empty(Arca.Users.list(server(), opts))
  end

  @doc """
  Everyone the server knows, a page at a time in id order: `limit:`
  (default and ceiling `Arca.Users.max_page/0`) people with ids greater
  than `after:`, the last id of the previous page. Walking the pages reads
  no one twice and everyone whose row predates the walk; a row written
  during the walk is read when its id sorts after the last page already
  read (a new person's time-ordered id does), and otherwise by the next
  walk. Answers `{:ok, rows}` or the store's refusal: a read that decides
  who may be named is never answered with nobody.
  """
  @spec list_by_id(keyword()) :: {:ok, [user()]} | {:error, term()}
  def list_by_id(opts \\ []) when is_list(opts),
    do: Arca.Users.list(server(), Keyword.put(opts, :order, :id))

  @doc """
  Record the person's cyfr.run namespace once it is known. This row is what
  every request reads for it (`Sanctum.Namespace`), so the write drops the
  cached slug. It follows a registry's answer, so it is the holder's write
  alone (`Arca.Users.set_namespace/3`): a member whose slot was taken
  meanwhile is refused `:not_owner` and records nothing.
  """
  @spec set_namespace(user(), String.t()) :: {:ok, user()} | {:error, term()}
  def set_namespace(%{namespace: ns} = user, ns), do: {:ok, user}

  def set_namespace(%{id: user_id}, namespace) when is_binary(namespace) do
    with {:ok, updated} <- Arca.Users.set_namespace(server(), user_id, namespace) do
      Sanctum.Namespace.invalidate(updated.id)
      {:ok, updated}
    end
  end

  @doc """
  The person's preferences document, as a map: `mode`, `theme`, and
  `handle_wanted`, the handle they chose and have not claimed yet
  (`PrismWeb.IdentityCard`).
  """
  @spec prefs(user()) :: map()
  def prefs(%{prefs: nil}), do: %{}

  def prefs(%{prefs: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Merge `patch` into the person's preferences; a key patched to `nil` is removed."
  @spec put_prefs(user(), map()) :: {:ok, user()} | {:error, term()}
  def put_prefs(%{id: _} = user, patch) when is_map(patch) do
    prefs =
      user |> prefs() |> Map.merge(patch) |> Map.reject(fn {_key, value} -> is_nil(value) end)

    update(user, %{prefs: Jason.encode!(prefs)})
  end

  @doc """
  Eject a person from this server, as one transaction
  (`Arca.SecurityTransitions.deny_user/3`): mark them denied, revoke every
  session and API key they created, archive their own athanor (revoking
  its keys), clear their platform administrator's mark, and remove their
  seats and invitations in shared threads, archiving every pair they sit
  in and every shared thread they leave empty. Either all of it
  commits or none of it does, and a failure is answered, never reported
  as an eject. The door entry that keeps them out is written by the
  caller (`Sanctum.Door.Store.deny/4`).

  After the commit, and only from what it returned: the removed sessions'
  established contexts are dropped and their revocation announced, the
  archived athanor's cached contexts are dropped and its
  archival is announced, every share the denial revoked announces it, and
  every roster the denial changed is told. Denying a person already
  denied re-runs the retirement and checks it.
  """
  @spec deny(user()) :: {:ok, user()} | {:error, term()}
  def deny(%{id: user_id} = user) do
    with {:ok, change} <-
           Arca.SecurityTransitions.deny_user(server(), user_id, verify: fn _rows -> :ok end) do
      Sanctum.Session.announce_revoked(user_id, change.revoked_session_hashes)
      Athanors.announce_archived(change.archived_athanor_ids, change)
      Sanctum.Shares.announce_each(nil, :revoked, change.revoked_share_ids)
      Sanctum.SharedThreads.announce_denied(user_id, change)

      :telemetry.execute([:cyfr, :sanctum, :door, :denied], %{count: 1}, %{
        user_id: user_id,
        email: user.email
      })

      {:ok, standing(user, change.user)}
    end
  end

  @doc """
  Reverse `deny/1` at the door, as one transaction
  (`Arca.SecurityTransitions.allow_user/3`): the person may sign in again,
  their own athanor is reopened — subject to the server's athanor cap,
  whose refusal leaves them denied. Revoked sessions and keys stay revoked,
  their platform administrator's mark stays cleared, and the shared-thread
  seats and invitations the deny removed are not restored — a thread's
  people add them again. A context read before the deny
  cannot issue a credential after this: the person's generation moved
  twice.
  """
  @spec allow(user()) :: {:ok, user()} | {:error, term()}
  def allow(%{id: user_id} = user) do
    with {:ok, change} <-
           Arca.SecurityTransitions.allow_user(server(), user_id, verify: &restorable/1) do
      {:ok, standing(user, change.user)}
    end
  end

  # Taking the place of an archived athanor back has to ask for it, or
  # archiving and reopening would be the way past `CYFR_MAX_ATHANORS`. The
  # count runs inside the transition, with the athanor locked and the
  # census lock held (`Arca.AthanorCensus`), so a reopen and a mint at the
  # last place cannot both land.
  defp restorable(%{athanor: %{status: "archived"}}),
    do: Sanctum.Tenancy.Caps.check_counted(:max_athanors, &Athanors.count/0)

  defp restorable(_rows), do: :ok

  # The caller's person, carrying the standing the transition committed.
  defp standing(%{} = user, %{} = committed) do
    %{
      user
      | status: committed.status,
        denied_at: committed.denied_at,
        security_generation: committed.security_generation
    }
  end

  # The row the person's id names is reread below and written as it
  # stands: nothing else the caller's map carries reaches the write.
  defp update(%{id: user_id}, attrs), do: Arca.Users.update(server(), user_id, attrs)

  # A person is not a row inside an athanor: the row is written before any
  # athanor exists and read from every one the person sits in.
  defp server, do: Prima.Actor.system()

  defp rows_or_empty({:ok, rows}), do: rows
  defp rows_or_empty({:error, _}), do: []
end
