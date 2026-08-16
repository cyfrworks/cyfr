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

  require Logger
  require Arca.Repo.Errors
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
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.SessionStorage] Error in create_session: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Get a session by token_hash. Returns `{:ok, row}` or `{:error, :not_found}`.

  Only returns non-expired sessions.
  """
  @spec get_session(binary()) :: {:ok, Session.t()} | {:error, :not_found | :database_error}
  def get_session(token_hash) do
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
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[Arca.SessionStorage] Error in get_session: #{inspect(e.__struct__)}: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @doc """
  Update a session's expires_at.
  """
  @spec refresh_session(binary(), DateTime.t()) :: :ok | {:error, :not_found | :database_error}
  def refresh_session(token_hash, new_expires_at) do
    query = from(s in Session, where: s.token_hash == ^token_hash)

    case Arca.Repo.update_all(query, set: [expires_at: new_expires_at]) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.SessionStorage] Error in refresh_session: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete a session by token_hash.
  """
  @spec delete_session(binary()) :: :ok | {:error, :database_error}
  def delete_session(token_hash) do
    query = from(s in Session, where: s.token_hash == ^token_hash)
    Arca.Repo.delete_all(query)
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.SessionStorage] Error in delete_session: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Point a session at another athanor. Returns `{:error, :not_found}` when no
  live session has that hash.
  """
  @spec update_athanor(binary(), String.t()) :: :ok | {:error, :not_found | :database_error}
  def update_athanor(token_hash, athanor_id) when is_binary(athanor_id) do
    query = from(s in Session, where: s.token_hash == ^token_hash)

    case Arca.Repo.update_all(query, set: [athanor_id: athanor_id]) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.SessionStorage] Error in update_athanor: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete every session of one user. Returns `{:ok, count}`.
  """
  @spec delete_by_user(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_by_user(user_id) when is_binary(user_id) do
    {count, _} = Arca.Repo.delete_all(from(s in Session, where: s.user_id == ^user_id))
    {:ok, count}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.SessionStorage] Error in delete_by_user: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Delete all expired sessions globally. Used by daemon processes for housekeeping.

  Returns `{:ok, count}`.
  """
  @spec cleanup_expired_sessions() :: {:ok, non_neg_integer()}
  def cleanup_expired_sessions do
    now = DateTime.utc_now()
    query = from(s in Session, where: s.expires_at <= ^now)

    {count, _} = Arca.Repo.delete_all(query)
    {:ok, count}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[Arca.SessionStorage] Error in cleanup_expired_sessions: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end
end
