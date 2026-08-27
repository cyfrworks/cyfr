# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SessionStorage do
  @moduledoc """
  Storage operations for sessions.

  This module provides the database layer for session storage.
  It's called by `Sanctum.Session` which handles token hashing.

  Tokens are stored as SHA-256 hashes for indexed lookups.
  Session metadata (user_id, email, provider, permissions) is stored as plaintext.
  """

  import Ecto.Query

  alias Arca.Schemas.Session

  # ============================================================================
  # Sessions
  # ============================================================================

  @doc """
  Insert a new session.
  """
  @spec create_session(binary(), map()) :: :ok | {:error, :database_error}
  def create_session(token_hash, attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.create_session", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row = %{
        id: Ecto.UUID.generate(),
        token_hash: token_hash,
        token_prefix: attrs[:token_prefix],
        user_id: attrs.user_id,
        email: attrs[:email],
        provider: attrs.provider,
        permissions: attrs.permissions,
        # A nil athanor is a real state: the session exists from sign-in on,
        # before the caller's athanor is resolved. Membership re-resolution
        # runs on the next load; nothing is coerced.
        athanor_id: attrs[:athanor_id],
        expires_at: attrs.expires_at,
        inserted_at: Map.get(attrs, :inserted_at, now)
      }

      Arca.Repo.insert_all(Session, [row])
      :ok
    end)
  end

  @doc """
  Get a session by token_hash. Returns `{:ok, row}` or `{:error, :not_found}`.

  Only returns non-expired sessions.
  """
  @spec get_session(binary()) :: {:ok, Session.t()} | {:error, :not_found | :database_error}
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
            :permissions,
            :athanor_id,
            :expires_at,
            :inserted_at
          ]
        )

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @doc """
  Update a session's expires_at.
  """
  @spec refresh_session(binary(), DateTime.t()) :: :ok | {:error, :not_found | :database_error}
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
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.hashes_by_user", [], fn ->
      Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))
    end)
  end

  @doc """
  Delete all expired sessions globally. Used by daemon processes for housekeeping.

  Returns `{:ok, count}`.
  """
  @spec cleanup_expired_sessions() :: {:ok, non_neg_integer()}
  def cleanup_expired_sessions do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.cleanup_expired_sessions", fn ->
      now = DateTime.utc_now()
      query = from(s in Session, where: s.expires_at <= ^now)

      {count, _} = Arca.Repo.delete_all(query)
      {:ok, count}
    end)
  end
end
