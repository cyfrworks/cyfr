defmodule Arca.SessionStorage do
  @moduledoc """
  SQLite storage operations for sessions and revocations.

  This module provides the database layer for session storage.
  It's called by `Sanctum.Session` which handles token hashing.

  Tokens are stored as SHA-256 hashes for indexed lookups.
  Session metadata (user_id, email, provider, permissions) is stored as plaintext.
  """

  require Logger
  import Ecto.Query

  # ============================================================================
  # Sessions
  # ============================================================================

  @doc """
  Insert a new session.
  """
  @spec create_session(binary(), map()) :: :ok | {:error, term()}
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
      session_id: attrs[:session_id],
      org_id: attrs[:org_id] || "",
      project_id: attrs[:project_id] || "default",
      expires_at: attrs.expires_at,
      inserted_at: Map.get(attrs, :inserted_at, now)
    }

    Arca.Repo.insert_all("sessions", [row])
    :ok
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] -> {:error, Exception.message(e)}
  end

  @doc """
  Get a session by token_hash. Returns `{:ok, row}` or `{:error, :not_found}`.

  Only returns non-expired sessions.
  """
  @spec get_session(binary()) :: {:ok, map()} | {:error, :not_found}
  def get_session(token_hash) do
    now = DateTime.utc_now()

    query =
      from(s in "sessions",
        where: s.token_hash == ^token_hash and s.expires_at > ^now,
        limit: 1,
        select: %{
          id: s.id,
          user_id: s.user_id,
          email: s.email,
          provider: s.provider,
          permissions: s.permissions,
          session_id: s.session_id,
          org_id: s.org_id,
          project_id: s.project_id,
          expires_at: s.expires_at,
          inserted_at: s.inserted_at
        }
      )

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[Arca.SessionStorage] Error in get_session: #{inspect(e.__struct__)}: #{Exception.message(e)}")
      {:error, :storage_error}
  end

  @doc """
  Update a session's expires_at.
  """
  @spec refresh_session(binary(), DateTime.t()) :: :ok | {:error, :not_found}
  def refresh_session(token_hash, new_expires_at) do
    query = from(s in "sessions", where: s.token_hash == ^token_hash)

    case Arca.Repo.update_all(query, set: [expires_at: new_expires_at]) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] -> {:error, Exception.message(e)}
  end

  @doc """
  Delete a session by token_hash.
  """
  @spec delete_session(binary()) :: :ok | {:error, :session_delete_failed}
  def delete_session(token_hash) do
    query = from(s in "sessions", where: s.token_hash == ^token_hash)
    Arca.Repo.delete_all(query)
    :ok
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[Arca.SessionStorage] Error in delete_session: #{Exception.message(e)}")
      {:error, :session_delete_failed}
  end

  @doc """
  List active (non-expired) sessions scoped to a tenant.

  Requires `:org_id` and `:project_id` in opts. Does not include token_hash.
  """
  @spec list_active_sessions(keyword()) :: {:ok, [map()]} | {:error, :storage_error}
  def list_active_sessions(opts) when is_list(opts) do
    now = DateTime.utc_now()
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    query =
      from(s in "sessions",
        where: s.expires_at > ^now,
        select: %{
          token_prefix: s.token_prefix,
          user_id: s.user_id,
          email: s.email,
          provider: s.provider,
          org_id: s.org_id,
          project_id: s.project_id,
          expires_at: s.expires_at,
          inserted_at: s.inserted_at
        },
        order_by: [desc: s.inserted_at]
      )

    query = Arca.QueryHelpers.where_org_id(query, org_id)
    query = Arca.QueryHelpers.where_project_id(query, project_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[Arca.SessionStorage] Error in list_active_sessions: #{Exception.message(e)}")
      {:error, :storage_error}
  end

  @doc """
  Delete all expired sessions globally. Used by daemon processes for housekeeping.

  Returns `{:ok, count}`.
  """
  @spec cleanup_expired_sessions() :: {:ok, non_neg_integer()}
  def cleanup_expired_sessions do
    now = DateTime.utc_now()
    query = from(s in "sessions", where: s.expires_at <= ^now)

    {count, _} = Arca.Repo.delete_all(query)
    {:ok, count}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[Arca.SessionStorage] Error in cleanup_expired_sessions: #{Exception.message(e)}")
      {:error, :storage_error}
  end

  @doc """
  Delete expired sessions scoped to a tenant. Returns `{:ok, count}`.

  Requires `:org_id` and `:project_id` in opts.
  """
  @spec cleanup_expired_sessions(keyword()) :: {:ok, non_neg_integer()} | {:error, :storage_error}
  def cleanup_expired_sessions(opts) when is_list(opts) do
    now = DateTime.utc_now()
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    query = from(s in "sessions", where: s.expires_at <= ^now)
    query = Arca.QueryHelpers.where_org_id(query, org_id)
    query = Arca.QueryHelpers.where_project_id(query, project_id)

    {count, _} = Arca.Repo.delete_all(query)
    {:ok, count}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.error("[Arca.SessionStorage] Error in cleanup_expired_sessions: #{Exception.message(e)}")
      {:error, :storage_error}
  end

  # ============================================================================
  # Revocations
  # ============================================================================

  @doc """
  Insert a revocation entry. Ignores conflict (idempotent).

  Accepts an optional keyword list to set tenant columns:
    * `:org_id` — defaults to `""`
    * `:project_id` — defaults to `"default"`
  """
  @spec put_revocation(String.t(), DateTime.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def put_revocation(session_id, revoked_at, expires_at, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      revoked_at: DateTime.truncate(revoked_at, :microsecond),
      expires_at: DateTime.truncate(expires_at, :microsecond),
      org_id: Keyword.get(opts, :org_id, ""),
      project_id: Keyword.get(opts, :project_id, "default"),
      inserted_at: now
    }

    Arca.Repo.insert_all("revoked_sessions", [row],
      on_conflict: :nothing,
      conflict_target: [:session_id]
    )

    :ok
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] -> {:error, Exception.message(e)}
  end

  @doc """
  Check if a session_id has been revoked and the revocation hasn't expired.
  """
  @spec revoked?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def revoked?(session_id) do
    now = DateTime.utc_now()

    query =
      from(r in "revoked_sessions",
        where: r.session_id == ^session_id and r.expires_at > ^now,
        select: r.id
      )

    {:ok, Arca.Repo.exists?(query)}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] -> {:error, Exception.message(e)}
  end

  @doc """
  Delete all expired revocation entries globally. Used by daemon processes for housekeeping.

  Returns `{:ok, count}`.
  """
  @spec cleanup_revocations() :: {:ok, non_neg_integer()}
  def cleanup_revocations do
    now = DateTime.utc_now()
    query = from(r in "revoked_sessions", where: r.expires_at <= ^now)

    {count, _} = Arca.Repo.delete_all(query)
    {:ok, count}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("[Arca.SessionStorage] Error in cleanup_revocations: #{Exception.message(e)}")
      {:error, :storage_error}
  end

  @doc """
  Delete expired revocation entries scoped to a tenant. Returns `{:ok, count}`.

  Requires `:org_id` and `:project_id` in opts.
  """
  @spec cleanup_revocations(keyword()) :: {:ok, non_neg_integer()} | {:error, :storage_error}
  def cleanup_revocations(opts) when is_list(opts) do
    now = DateTime.utc_now()
    org_id = Keyword.fetch!(opts, :org_id)
    project_id = Keyword.fetch!(opts, :project_id)

    query = from(r in "revoked_sessions", where: r.expires_at <= ^now)
    query = Arca.QueryHelpers.where_org_id(query, org_id)
    query = Arca.QueryHelpers.where_project_id(query, project_id)

    {count, _} = Arca.Repo.delete_all(query)
    {:ok, count}
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("[Arca.SessionStorage] Error in cleanup_revocations: #{Exception.message(e)}")
      {:error, :storage_error}
  end
end
