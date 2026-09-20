# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.Users do
  @moduledoc """
  The people this server knows (`Arca.Schemas.User`).

  A row is written on the first admitted sign-in and touched on every later
  one; the door, invited memberships and per-person preferences key off it.
  `deny/1` and `allow/1` are the operator's eject and re-admit: a denied
  person loses their sessions and API keys, their own athanor is archived
  (nothing deleted), their group rows are removed and the invitations their
  address was still holding are withdrawn; allowing them again reopens the
  door and the athanor, re-seats them in it, and leaves the revoked
  credentials revoked.

  ## What is decided here, and what is stored below

  The statements are `Arca.Users`'. What stays here is the deciding: which
  provider claims are recorded and which are left as they stand, that a
  person's id is minted with `Cyfr.PersonId.prefix/0` and that only an IdP
  identity may sign in, what an eject costs the person, and what an
  unanswerable read should read as. A person is not a row inside an
  athanor — they exist before any athanor does and sit in several at once
  — so every call runs as the server (`Cyfr.Actor.system/0`), which is
  what `Arca.Users` requires and says why.
  """

  alias Arca.Schemas.{ExternalIdentity, User}
  alias Sanctum.Auth.Identity
  alias Sanctum.Tenancy.{Athanors, Members}

  @typedoc """
  What the door admitted: `id` is the IdP identity key
  (`Sanctum.Auth.Identity.key/3`), never a person's own id.
  """
  @type provider_info :: %{
          required(:id) => String.t(),
          required(:provider) => String.t() | atom(),
          optional(:email) => String.t() | nil,
          optional(:verified) => boolean() | :unknown,
          optional(:name) => String.t() | nil
        }

  @doc """
  The person an admitted identity names: their row refreshed, or a new
  person minted (an id of this server's, `Cyfr.PersonId.prefix/0`) with
  the identity recorded as theirs.

  `first_seen_at` is set once; `last_seen_at`, `email`, `email_verified`
  and `display_name` follow what the provider asserted this time —
  `email_verified` as the provider's own three answers, so "it never said"
  is not recorded as "it said no".

  An absent provider claim preserves the stored value, including name and email verification.
  """
  @spec upsert_from_provider(provider_info()) :: {:ok, User.t()} | {:error, term()}
  def upsert_from_provider(%{id: key, provider: provider} = info) when is_binary(key) do
    now = DateTime.utc_now()

    seen =
      %{
        email_verified: verified_claim(Map.get(info, :verified)),
        provider: to_string(provider),
        last_seen_at: now,
        updated_at: now
      }
      |> Cyfr.MapUtil.put_present(:email, Map.get(info, :email))
      |> Cyfr.MapUtil.put_present(:display_name, Map.get(info, :name))

    case get_by_identity(key) do
      {:ok, user} ->
        Arca.Users.touch_identity(server(), key, now)
        Arca.Users.update(server(), user, seen)

      {:error, :not_found} ->
        first_sign_in(key, seen, now)

      {:error, _} = err ->
        err
    end
  end

  # The person and the identity that names them, minted together. A
  # concurrent first sign-in of the same identity wins the unique index;
  # the loser reads the person it minted.
  defp first_sign_in(key, seen, now) do
    with {:ok, %{provider: provider, issuer: issuer, subject: subject}} <- Identity.parse(key) do
      user_attrs =
        Map.merge(seen, %{
          id: Cyfr.UUID7.generate_id(Cyfr.PersonId.prefix()),
          first_seen_at: now,
          created_at: now,
          prefs: Jason.encode!(%{})
        })

      Arca.Users.mint(server(), user_attrs, %{
        key: key,
        provider: provider,
        issuer: issuer,
        subject: subject,
        first_seen_at: now,
        last_seen_at: now
      })
    end
  end

  @doc "The person an IdP identity key names, if any."
  @spec get_by_identity(String.t()) :: {:ok, User.t()} | {:error, :not_found | :database_error}
  def get_by_identity(key), do: Arca.Users.get_by_identity(server(), key)

  @doc "Every IdP identity that names this person, oldest first."
  @spec identities(String.t()) :: [ExternalIdentity.t()]
  def identities(user_id) when is_binary(user_id) do
    # Deliberate default: a display read of how a person has signed in —
    # an outage shows fewer providers, it grants nothing.
    rows_or_empty(Arca.Users.identities(server(), user_id))
  end

  @spec get(String.t()) :: {:ok, User.t()} | {:error, :not_found | :database_error}
  def get(id), do: Arca.Users.get(server(), id)

  @doc """
  How a person is named to other people: their display name, else their
  email, else the raw id.

  Here rather than beside a caller because it is a fact about the `users`
  row, and it is now read by two domains that must not depend on each
  other — the agent harness prefixing a group turn's lines, and tenancy
  naming a pair estate after the two people in it.
  """
  @spec display_name(String.t() | nil) :: String.t()
  def display_name(nil), do: "someone"

  def display_name(user_id) when is_binary(user_id) do
    case get(user_id) do
      {:ok, %{display_name: name}} when is_binary(name) and name != "" -> name
      {:ok, %{email: email}} when is_binary(email) and email != "" -> email
      _ -> user_id
    end
  end

  @doc "Every identity that signed in with this (lowercased) email."
  @spec list_by_email(String.t()) :: [User.t()]
  def list_by_email(email) when is_binary(email) do
    # Deliberate default: an unanswerable read means "no identity known for
    # this address" — callers then take the invite path, which grants nothing.
    rows_or_empty(Arca.Users.list_by_email(server(), String.downcase(email)))
  end

  @doc """
  Whether this athanor is somebody's personal furnace.

  `Athanors.destroy/1` refuses one. `personal_athanor_id` is not an
  athanor-scoped column, so erasure would leave it naming a tombstone:
  the unique index would block minting a replacement, and
  `unarchive_personal/1` would try to reopen a wiped shell.

  Fail-CLOSED on an unanswerable read — the default is `true`, so a
  database fault refuses an irreversible delete rather than permitting it.
  """
  @spec personal_athanor?(String.t()) :: boolean()
  def personal_athanor?(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    case Arca.Users.personal_athanor?(server(), athanor_id) do
      {:ok, personal?} -> personal?
      {:error, _} -> true
    end
  end

  def personal_athanor?(_), do: true

  @doc """
  The person's own athanor — `{:ok, id}` once one has been minted, else
  `:none`.

  `:none` covers a person the server does not know, one whose furnace has
  not been minted yet, and an unanswerable read alike: every caller asks
  so it may open something (a cross-estate note read, a copy out of a
  private thread), and "could not tell" must read as "not yours" there.
  """
  @spec personal_athanor_id(String.t() | nil) :: {:ok, String.t()} | :none
  def personal_athanor_id(user_id) when is_binary(user_id) do
    case get(user_id) do
      {:ok, %{personal_athanor_id: id}} when is_binary(id) and id != "" -> {:ok, id}
      _ -> :none
    end
  end

  def personal_athanor_id(_), do: :none

  @doc """
  Whether `athanor_id` is this person's own athanor.

  The one predicate behind "is the caller at home": a running chain reads
  notes across estates only from there, and an assistant's line is the
  person's to say aloud only when it was said there. Spelled once so the
  domains that ask it cannot drift from the row that answers.
  """
  @spec own_athanor?(String.t() | nil, String.t() | nil) :: boolean()
  def own_athanor?(user_id, athanor_id) when is_binary(user_id) and is_binary(athanor_id) do
    personal_athanor_id(user_id) == {:ok, athanor_id}
  end

  def own_athanor?(_user_id, _athanor_id), do: false

  @doc "The identity whose cyfr.run namespace this is, if any."
  @spec get_by_namespace(String.t()) :: {:ok, User.t()} | {:error, :not_found | :database_error}
  def get_by_namespace(namespace) when is_binary(namespace) and namespace != "",
    do: Arca.Users.get_by_namespace(server(), namespace)

  @doc """
  Everyone the server knows, newest first. A platform view, paged with
  `limit:` (default and ceiling `Arca.Users.max_page/0`) and `offset:`.
  """
  @spec list(keyword()) :: [User.t()]
  def list(opts \\ []) do
    # Deliberate default: the operator's people page — a display read that
    # decides nothing; an outage renders an empty page, not a refusal.
    rows_or_empty(Arca.Users.list(server(), opts))
  end

  @doc """
  Record the person's cyfr.run namespace once it is known. This row is what
  every request reads for it (`Sanctum.Namespace`), so the write drops the
  cached slug.
  """
  @spec set_namespace(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def set_namespace(%User{namespace: ns} = user, ns), do: {:ok, user}

  def set_namespace(%User{} = user, namespace) when is_binary(namespace) do
    with {:ok, updated} <- update(user, %{namespace: namespace}) do
      Sanctum.Namespace.invalidate(updated.id)
      {:ok, updated}
    end
  end

  @doc "Record the person's own athanor once minted."
  @spec set_personal_athanor(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def set_personal_athanor(%User{} = user, athanor_id) when is_binary(athanor_id) do
    update(user, %{personal_athanor_id: athanor_id})
  end

  @doc "The person's preferences document (`mode`, `theme`), as a map."
  @spec prefs(User.t()) :: map()
  def prefs(%User{prefs: nil}), do: %{}

  def prefs(%User{prefs: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Merge `patch` into the person's preferences."
  @spec put_prefs(User.t(), map()) :: {:ok, User.t()} | {:error, term()}
  def put_prefs(%User{} = user, patch) when is_map(patch) do
    update(user, %{prefs: Jason.encode!(Map.merge(prefs(user), patch))})
  end

  @doc """
  Eject a person from this server: mark them denied, revoke every session
  and API key they created, archive their own athanor and remove their
  group rows. The door entry that keeps them out is written by the caller
  (`Sanctum.Door.Store.deny/4`) — this is the part that acts on what the
  person already has.
  """
  @spec deny(User.t()) :: {:ok, User.t()} | {:error, term()}
  def deny(%User{} = user) do
    now = DateTime.utc_now()

    with {:ok, user} <- update(user, %{status: "denied", denied_at: now}) do
      Sanctum.Session.revoke_all_for_user(user.id)
      Sanctum.ApiKey.revoke_all_created_by(user.id)
      archive_personal(user)
      # Seats held for the address, not yet for the person: the sweep below
      # goes by `user_id` and cannot see them.
      Members.withdraw_invites_for_email(user.email)

      # The status is written (the person is out at the door either way);
      # what fails here is reported so the operator can retry, not hidden.
      with :ok <- Members.remove_all_for_user(user.id) do
        :telemetry.execute([:cyfr, :sanctum, :door, :denied], %{count: 1}, %{
          user_id: user.id,
          email: user.email
        })

        {:ok, user}
      end
    end
  end

  @doc """
  Reverse `deny/1` at the door: the person may sign in again, their own
  athanor is reopened and they are seated in it again. Revoked sessions and
  keys stay revoked, and the group seats the deny removed are not restored —
  eject is permanent for groups; a member adds them again.
  """
  @spec allow(User.t()) :: {:ok, User.t()} | {:error, term()}
  def allow(%User{} = user) do
    with {:ok, user} <- update(user, %{status: "active", denied_at: nil}),
         :ok <- unarchive_personal(user) do
      # The deny swept every membership by user id, their own seat included.
      # Reopening the furnace without re-seating its owner would leave them
      # locked out of it until their next sign-in re-provisioned the row.
      reseat_personal(user)
      {:ok, user}
    end
  end

  defp archive_personal(%User{personal_athanor_id: id}) when is_binary(id) do
    case Athanors.get(id) do
      {:ok, athanor} -> Athanors.archive(athanor, force: true)
      _ -> :ok
    end
  end

  defp archive_personal(_), do: :ok

  defp unarchive_personal(%User{personal_athanor_id: id}) when is_binary(id) do
    case Athanors.get(id) do
      {:ok, %{status: "archived"} = athanor} ->
        case Athanors.unarchive(athanor) do
          {:ok, _} -> :ok
          # The server is full: say so rather than report a person restored
          # to a furnace that is still shut.
          {:error, {:limit_reached, _key, _cap}} = err -> err
          {:error, _} = err -> err
        end

      _ ->
        :ok
    end
  end

  defp unarchive_personal(_), do: :ok

  defp reseat_personal(%User{id: user_id, personal_athanor_id: id}) when is_binary(id) do
    Members.ensure(user_id, scope: "athanor", athanor_id: id, added_by: "system")
    :ok
  end

  defp reseat_personal(_), do: :ok

  # What the provider asserted about the address, kept as asserted: `true`
  # proved, `false` refused, `nil` never claimed. An issuer that does not
  # emit `email_verified` must not read as one that denied it.
  defp verified_claim(true), do: true
  defp verified_claim(false), do: false
  defp verified_claim(_), do: nil

  defp update(%User{} = user, attrs), do: Arca.Users.update(server(), user, attrs)

  # A person is not a row inside an athanor: the row is written before any
  # athanor exists and read from every one the person sits in.
  defp server, do: Cyfr.Actor.system()

  defp rows_or_empty({:ok, rows}), do: rows
  defp rows_or_empty({:error, _}), do: []
end
