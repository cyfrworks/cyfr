defmodule Sanctum.Session do
  @moduledoc """
  Session management for CYFR.

  Provides session storage backed by SQLite via `Arca.SessionStorage`
  (through MCP boundary). Tokens are hashed (SHA-256) before storage —
  the actual token is never persisted.

  ## Usage

      # Create a session after OAuth callback
      {:ok, session} = Sanctum.Session.create(user)

      # Get user from session token
      {:ok, user} = Sanctum.Session.get_user(session.token)

      # Refresh session (extend expiration)
      {:ok, session} = Sanctum.Session.refresh(session.token)

      # Destroy session on logout
      :ok = Sanctum.Session.destroy(session.token)

      # Revoke a session by ID (for JWT validation)
      :ok = Sanctum.Session.revoke(session_id)

      # Check if session is revoked
      true = Sanctum.Session.revoked?(session_id)

  ## Session Format

  Each session contains:
  - `token` - Random 32-byte base64 token
  - `user_id` - User's ID from OIDC provider
  - `email` - User's email (optional)
  - `provider` - Auth provider (e.g., "github", "google")
  - `created_at` - ISO 8601 timestamp
  - `expires_at` - ISO 8601 timestamp (24 hours by default)

  ## Storage

  Sessions are stored in SQLite via `Arca.SessionStorage`.
  Tokens are stored as SHA-256 hashes for indexed lookups.
  Revoked session IDs are tracked in a separate table.
  Expired sessions and old revocations are automatically cleaned up.
  """

  require Logger

  alias Sanctum.User

  # Session configuration
  @default_session_ttl_hours 24
  @min_session_ttl_hours 1
  @token_bytes 32
  # Year 9999 — used as expires_at when TTL is 0 (infinite)
  @never_expires ~U[9999-12-31 23:59:59Z]

  defp session_ttl_hours do
    case Application.get_env(:sanctum, :session_ttl_hours, @default_session_ttl_hours) do
      0 ->
        # Infinite sessions — intentional self-hosted feature
        0

      hours when is_integer(hours) and hours < @min_session_ttl_hours ->
        Logger.warning(
          "CYFR_SESSION_TTL_HOURS=#{hours} is below minimum (#{@min_session_ttl_hours}). " <>
            "Using #{@min_session_ttl_hours} hour(s). Set to 0 for infinite sessions."
        )

        @min_session_ttl_hours

      hours when is_integer(hours) ->
        hours
    end
  end

  defp mcp_ctx, do: Sanctum.Context.local()

  @type session :: %{
          token: String.t(),
          user_id: String.t(),
          email: String.t() | nil,
          provider: String.t(),
          permissions: [atom()],
          created_at: String.t(),
          expires_at: String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new session for an authenticated user.

  Returns a session map containing the token and user information.

  ## Examples

      user = %Sanctum.User{id: "123", email: "alice@example.com", provider: "github"}
      {:ok, session} = Sanctum.Session.create(user)
      session.token
      #=> "abc123..."

  """
  @spec create(User.t()) :: {:ok, session()} | {:error, term()}
  def create(%User{} = user) do
    with :ok <- check_allowed_user(user.email) do
      token = generate_token()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      expires_at =
        case session_ttl_hours() do
          0 -> @never_expires
          hours -> DateTime.add(now, hours * 3600, :second)
        end

      permissions_json = Jason.encode!(Enum.map(user.permissions, &to_string/1))

      attrs = %{
        "token_prefix" => String.slice(token, 0, 8),
        "user_id" => user.id,
        "email" => user.email,
        "provider" => user.provider,
        "permissions" => permissions_json,
        "expires_at" => DateTime.to_iso8601(expires_at),
        "inserted_at" => DateTime.to_iso8601(now)
      }

      case Arca.MCP.handle("session_store", mcp_ctx(), %{
             "action" => "create",
             "token_hash" => Base.encode64(hash_token(token)),
             "attrs" => attrs
           }) do
        {:ok, _} ->
          session = %{
            token: token,
            user_id: user.id,
            email: user.email,
            provider: user.provider,
            permissions: Enum.map(user.permissions, &to_string/1),
            created_at: DateTime.to_iso8601(now),
            expires_at: DateTime.to_iso8601(expires_at)
          }

          broadcast_session_created(session)
          {:ok, session}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Get user from session token.

  Returns the user if the session is valid and not expired.

  ## Examples

      {:ok, user} = Sanctum.Session.get_user("abc123...")
      user.id
      #=> "123"

  """
  @spec get_user(String.t()) :: {:ok, User.t()} | {:error, :invalid_session | :storage_error}
  def get_user(token) when is_binary(token) do
    case get_session_via_mcp(token) do
      {:ok, row} ->
        {:ok, row_to_user(row)}

      {:error, :not_found} ->
        {:error, :invalid_session}

      {:error, :storage_error} ->
        {:error, :storage_error}
    end
  end

  @doc """
  Get session details from token.

  Returns the full session map if valid and not expired.
  """
  @spec get(String.t()) :: {:ok, session()} | {:error, :invalid_session | :storage_error}
  def get(token) when is_binary(token) do
    case get_session_via_mcp(token) do
      {:ok, row} ->
        {:ok, row_to_external(row, token)}

      {:error, :not_found} ->
        {:error, :invalid_session}

      {:error, :storage_error} ->
        {:error, :storage_error}
    end
  end

  @doc """
  Refresh a session, extending its expiration time.

  ## Examples

      {:ok, session} = Sanctum.Session.refresh("abc123...")
      # Session expiration extended by 24 hours from now

  """
  @spec refresh(String.t()) :: {:ok, session()} | {:error, :invalid_session | :storage_error}
  def refresh(token) when is_binary(token) do
    b64_hash = Base.encode64(hash_token(token))

    with {:ok, _row} <- get_session_via_mcp(token) do
      now = DateTime.utc_now()

      new_expires_at =
        case session_ttl_hours() do
          0 -> @never_expires
          hours -> DateTime.add(now, hours * 3600, :second) |> DateTime.truncate(:microsecond)
        end

      case Arca.MCP.handle("session_store", mcp_ctx(), %{
             "action" => "refresh",
             "token_hash" => b64_hash,
             "new_expires_at" => DateTime.to_iso8601(new_expires_at)
           }) do
        {:ok, _} ->
          case get_session_via_mcp(token) do
            {:ok, row} -> {:ok, row_to_external(row, token)}
            {:error, :not_found} -> {:error, :invalid_session}
            {:error, :storage_error} -> {:error, :storage_error}
          end

        {:error, :not_found} ->
          {:error, :invalid_session}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :invalid_session}
      {:error, :storage_error} -> {:error, :storage_error}
    end
  end

  @doc """
  Destroy a session (logout).

  Also revokes the session_id if present, preventing any JWTs
  containing that session_id from being used.

  ## Examples

      :ok = Sanctum.Session.destroy("abc123...")

  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(token) when is_binary(token) do
    b64_hash = Base.encode64(hash_token(token))

    # If session has a session_id, revoke it
    case get_session_via_mcp(token) do
      {:ok, %{session_id: session_id}} when is_binary(session_id) ->
        revoke(session_id)

      _ ->
        :ok
    end

    case Arca.MCP.handle("session_store", mcp_ctx(), %{
           "action" => "delete",
           "token_hash" => b64_hash
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List all active sessions (for admin purposes).

  Returns sessions with tokens redacted.
  """
  @spec list_active() :: {:ok, [map()]} | {:error, term()}
  def list_active do
    case Arca.MCP.handle("session_store", mcp_ctx(), %{"action" => "list_active"}) do
      {:ok, %{sessions: rows}} ->
        active =
          Enum.map(rows, fn row ->
            prefix = if row[:token_prefix], do: row[:token_prefix] <> "...", else: "..."

            %{
              token_prefix: prefix,
              user_id: row[:user_id],
              email: row[:email],
              provider: row[:provider],
              created_at: row[:inserted_at],
              expires_at: row[:expires_at]
            }
          end)

        {:ok, active}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clean up expired sessions.

  Returns the number of sessions removed.
  """
  @spec cleanup() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup do
    case Arca.MCP.handle("session_store", mcp_ctx(), %{"action" => "cleanup_expired"}) do
      {:ok, %{cleaned: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revoke a session by its session_id (used for JWT validation).

  Revoked session IDs are stored and checked during JWT validation
  to prevent use of tokens from destroyed sessions.
  """
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(session_id) when is_binary(session_id) do
    now = DateTime.utc_now()
    # Revocations expire after max(48h, session_ttl * 2)
    revocation_ttl_seconds = max(48 * 3600, session_ttl_hours() * 3600 * 2)
    expires_at = DateTime.add(now, revocation_ttl_seconds, :second)

    case Arca.MCP.handle("session_store", mcp_ctx(), %{
           "action" => "put_revocation",
           "session_id" => session_id,
           "revoked_at" => DateTime.to_iso8601(now),
           "expires_at" => DateTime.to_iso8601(expires_at)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a session_id has been revoked.
  """
  @spec revoked?(String.t()) :: boolean()
  def revoked?(session_id) when is_binary(session_id) do
    case Arca.MCP.handle("session_store", mcp_ctx(), %{
           "action" => "check_revoked",
           "session_id" => session_id
         }) do
      {:ok, %{revoked: result}} ->
        result

      {:error, reason} ->
        # SECURITY: Any error fails closed (treat as potentially revoked)
        Logger.warning(
          "Cannot verify session revocation due to error: #{inspect(reason)} - treating as potentially revoked"
        )

        true
    end
  end

  @doc """
  Clean up expired revocation entries.

  Returns the number of entries removed.
  """
  @spec cleanup_revocations() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_revocations do
    case Arca.MCP.handle("session_store", mcp_ctx(), %{"action" => "cleanup_revocations"}) do
      {:ok, %{cleaned: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp check_allowed_user(email) do
    case Application.get_env(:sanctum, :allowed_users) do
      nil ->
        :ok

      [] ->
        :ok

      allowed when is_list(allowed) ->
        if email in allowed, do: :ok, else: {:error, :user_not_allowed}
    end
  end

  defp get_session_via_mcp(token) do
    b64_hash = Base.encode64(hash_token(token))

    case Arca.MCP.handle("session_store", mcp_ctx(), %{
           "action" => "get",
           "token_hash" => b64_hash
         }) do
      {:ok, %{session: row}} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp row_to_user(row) do
    permissions =
      case Jason.decode(row[:permissions] || "[]") do
        {:ok, list} when is_list(list) -> Enum.map(list, &safe_to_atom/1)
        _ ->
          Logger.warning("[Sanctum.Session] Malformed permissions JSON for user #{row[:user_id]}, defaulting to empty")
          []
      end

    %User{
      id: row[:user_id],
      email: row[:email],
      provider: row[:provider],
      permissions: permissions
    }
  end

  defp row_to_external(row, token) do
    permissions =
      case Jason.decode(row[:permissions] || "[]") do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    %{
      token: token,
      user_id: row[:user_id],
      email: row[:email],
      provider: row[:provider],
      permissions: permissions,
      created_at: row[:inserted_at],
      expires_at: row[:expires_at]
    }
  end

  defp safe_to_atom(value), do: Sanctum.Atoms.safe_to_permission_atom(value)

  @session_topic "sanctum:sessions"

  defp broadcast_session_created(_session) do
    # Notify subscribers (e.g. AuthLive) that a session was created.
    # No token is sent — subscribers use adopt_active_session() to get their own.
    case Application.get_env(:sanctum, :pubsub_name) do
      nil -> :ok
      pubsub ->
        Phoenix.PubSub.broadcast(
          pubsub,
          @session_topic,
          {:session_created, :notification}
        )
    end
  rescue
    # PubSub may not be running (e.g. in tests or CLI-only mode)
    _ -> :ok
  end
end
