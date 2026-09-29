# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SessionStorage do
  @moduledoc """
  Storage operations for sessions.

  This module provides the database layer for session storage.
  It's called by `Sanctum.Session` which handles token hashing.

  Tokens are stored as SHA-256 hashes for indexed lookups.
  Session metadata (user_id, email, provider) is stored as plaintext.

  A session of a person whose identity is `remote`
  (`Arca.PersonIdentities`) records the `identity_key_epoch` of the head
  verified when it was minted, whichever door admitted it, and a local
  person's session records none: the insert refuses either the other way
  round, and refuses an epoch that is not the cached head's current one
  (`Arca.DirectoryHeads.bindable!/2`, read under the person's lock, so an
  advance that retires the epoch either retires this session or refuses
  it). `revoke_key_epoch/3` ends every session carrying a `key_epoch` a
  fresh head retired.
  """

  import Ecto.Query

  alias Arca.Schemas.Session

  # ============================================================================
  # Sessions
  # ============================================================================

  @doc """
  Insert a new session, in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): `lock:` names the rows the
  session's standing rests on and `verify:` is the caller's policy over
  them, asked with them locked. A standing transition that retires the
  person or the athanor either commits first and is reread here, or waits
  for this session and then retires it.

  `attrs[:identity_key_epoch]` is required for a person whose identity is
  `remote` (`{:error, :identity_key_epoch_required}`), must be the cached
  head's current `key_epoch` (`{:error, :stale_key_epoch}`), and is refused
  for any other person (`{:error, :unexpected_key_epoch}`). `also:`
  (optional) is the higher owner's closure, run in the same transaction
  after the insert and handed the session's `%{id, user_id}`: it answers
  `:ok`, or `{:error, reason}` to roll the session back; any other answer
  raises `ArgumentError`, which rolls the session back too.

  Answers `:ok`, or the policy's refusal with nothing written.
  """
  @spec create_session(binary(), map(), keyword()) :: :ok | {:error, term()}
  def create_session(token_hash, attrs, opts) when is_binary(token_hash) and is_list(opts) do
    lock = Keyword.fetch!(opts, :lock)
    verify = Keyword.fetch!(opts, :verify)
    also = Keyword.get(opts, :also, fn _session -> :ok end)

    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.create_session", fn ->
      Arca.SecurityTransitions.Issuance.run(lock, verify, fn _locked ->
        with {:ok, session} <- insert_session(token_hash, attrs),
             :ok <- also_ran(also.(session)) do
          {:ok, :inserted}
        end
      end)
      |> case do
        {:ok, :inserted} -> :ok
        {:error, _reason} = refusal -> refusal
      end
    end)
  end

  defp insert_session(token_hash, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    epoch = attrs[:identity_key_epoch]

    row = %{
      id: Prima.UUID7.generate_id("ses"),
      token_hash: token_hash,
      token_prefix: attrs[:token_prefix],
      user_id: attrs.user_id,
      email: attrs[:email],
      provider: attrs.provider,
      # A nil athanor is a real state: the session exists from sign-in on,
      # before the caller's athanor is resolved. Membership re-resolution
      # runs on the next load; nothing is coerced.
      athanor_id: attrs[:athanor_id],
      identity_key_epoch: epoch,
      expires_at: attrs.expires_at,
      inserted_at: Map.get(attrs, :inserted_at, now)
    }

    with :ok <- Arca.DirectoryHeads.bindable!(attrs.user_id, epoch) do
      Arca.Repo.insert_all(Session, [row])
      {:ok, %{id: row.id, user_id: row.user_id}}
    end
  end

  defp also_ran(:ok), do: :ok
  defp also_ran({:error, _reason} = refusal), do: refusal

  defp also_ran(other) do
    raise ArgumentError,
          "an also: closure answers :ok or {:error, reason}, got " <>
            Prima.LoggerContext.shape(other)
  end

  @doc """
  Get a session by token_hash. Returns `{:ok, row}` or `{:error, :not_found}`.

  Only returns non-expired sessions.
  """
  @spec get_session(binary()) :: {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok sessions are credential-keyed; athanor_id is nullable pre-resolution (tenancy fabric).
  def get_session(token_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.get_session", fn ->
      now = DateTime.utc_now()

      # Select a struct with everything except the secret token_hash/token_prefix.
      query =
        from(s in Session,
          where: s.token_hash == ^token_hash and s.expires_at > ^now,
          limit: 1,
          select: [
            :id,
            :user_id,
            :email,
            :provider,
            :athanor_id,
            :identity_key_epoch,
            :expires_at,
            :inserted_at
          ]
        )

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Update a session's expires_at.
  """
  @spec refresh_session(binary(), DateTime.t()) :: :ok | {:error, :not_found | :database_error}
  # arca:unscoped-ok sessions are addressed by token hash — the credential is
  # the scope, and the athanor is a column on the row it finds.
  def refresh_session(token_hash, new_expires_at) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.refresh_session", fn ->
      query = from(s in Session, where: s.token_hash == ^token_hash)

      case Arca.Repo.update_all(query, set: [expires_at: new_expires_at]) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end)
  end

  @doc """
  Delete a session by token_hash.
  """
  @spec delete_session(binary()) :: :ok | {:error, :database_error}
  # arca:unscoped-ok signing out is addressed by the token being retired.
  def delete_session(token_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.delete_session", fn ->
      query = from(s in Session, where: s.token_hash == ^token_hash)
      Arca.Repo.delete_all(query)
      :ok
    end)
  end

  @doc """
  Point a session at another athanor. Returns `{:error, :not_found}` when no
  live session has that hash.
  """
  @spec update_athanor(binary(), String.t()) :: :ok | {:error, :not_found | :database_error}
  def update_athanor(token_hash, athanor_id) when is_binary(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.update_athanor", fn ->
      query = from(s in Session, where: s.token_hash == ^token_hash)

      case Arca.Repo.update_all(query, set: [athanor_id: athanor_id]) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end)
  end

  @doc """
  Delete every session of one user. Returns `{:ok, count}`.
  """
  @spec delete_by_user(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  # arca:unscoped-ok crossing athanors is the point: a person denied at the
  # door loses every session, wherever it was established.
  def delete_by_user(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.delete_by_user", fn ->
      {count, _} = Arca.Repo.delete_all(from(s in Session, where: s.user_id == ^user_id))
      {:ok, count}
    end)
  end

  @doc """
  The token hashes of every session of one user — what a user-wide
  revocation invalidates in the established-context memo, which is keyed
  by hash. A store failure returns `[]`: the delete that follows still
  lands, and the memo entries it misses lapse with the TTL.
  """
  @spec hashes_by_user(String.t()) :: [binary()]
  def hashes_by_user(user_id) when is_binary(user_id) do
    # Deliberate fail-open to []: the revocation's delete still runs, and a
    # memo entry this read missed dies with the memo TTL — never a grant.
    # arca:unscoped-ok sessions are user-owned rows (a session exists from
    # sign-in on, before any athanor is resolved); user_id is the scope.
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.hashes_by_user", [], fn ->
      Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))
    end)
  end

  @doc """
  End every session of the people `user_ids` that carries `key_epoch`: a
  fresh head retired it, and a session minted under a live key the head no
  longer names must not outlive the refresh. The platform's own actor
  only. Answers the token hashes it ended, for the caller to invalidate
  after commit.
  """
  @spec revoke_key_epoch(Prima.Actor.t(), [String.t()], String.t()) ::
          {:ok, [binary()]} | {:error, :cross_tenant | :database_error}
  def revoke_key_epoch(%Prima.Actor{scope: :platform, system: true}, user_ids, key_epoch)
      when is_list(user_ids) and is_binary(key_epoch) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.revoke_key_epoch", fn ->
      Arca.Repo.locking_transaction(fn -> delete_key_epoch!(user_ids, key_epoch) end)
    end)
  end

  def revoke_key_epoch(%Prima.Actor{}, _user_ids, _key_epoch), do: {:error, :cross_tenant}

  @doc false
  # The statement behind `revoke_key_epoch/3`, run in a caller's
  # transaction (`Arca.DirectoryHeads.advance/4`).
  @spec delete_key_epoch!([String.t()], String.t()) :: [binary()]
  def delete_key_epoch!([], _key_epoch), do: []

  # arca:unscoped-ok sessions are person-owned; the people and the epoch are the scope.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def delete_key_epoch!(user_ids, key_epoch) when is_list(user_ids) and is_binary(key_epoch) do
    {_count, hashes} =
      Arca.Repo.delete_all(
        from(s in Session,
          where: s.user_id in ^user_ids and s.identity_key_epoch == ^key_epoch,
          select: s.token_hash
        )
      )

    hashes || []
  end

  @doc """
  Delete all expired sessions globally. Used by daemon processes for housekeeping.

  Returns `{:ok, count}`.
  """
  @spec cleanup_expired_sessions() :: {:ok, non_neg_integer()}
  # arca:unscoped-ok expiry is server-wide housekeeping over a column that
  # has nothing to do with tenancy.
  def cleanup_expired_sessions do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.cleanup_expired_sessions", fn ->
      now = DateTime.utc_now()
      query = from(s in Session, where: s.expires_at <= ^now)

      {count, _} = Arca.Repo.delete_all(query)
      {:ok, count}
    end)
  end
end
