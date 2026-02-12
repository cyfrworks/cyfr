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
  @token_bytes 32

  defp session_ttl_seconds do
    hours = Application.get_env(:sanctum, :session_ttl_hours, @default_session_ttl_hours)
    hours * 3600
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
    token = generate_token()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, session_ttl_seconds(), :second)

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
        {:ok,
         %{
           token: token,
           user_id: user.id,
           email: user.email,
           provider: user.provider,
           permissions: Enum.map(user.permissions, &to_string/1),
           created_at: DateTime.to_iso8601(now),
           expires_at: DateTime.to_iso8601(expires_at)
         }}

      {:error, _} = error ->
        error
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
  @spec get_user(String.t()) :: {:ok, User.t()} | {:error, :invalid_session}
  def get_user(token) when is_binary(token) do
    case get_session_via_mcp(token) do
      {:ok, row} ->
        {:ok, row_to_user(row)}

      {:error, :not_found} ->
        {:error, :invalid_session}
    end
  end

  @doc """
  Get session details from token.

  Returns the full session map if valid and not expired.
  """
  @spec get(String.t()) :: {:ok, session()} | {:error, :invalid_session}
  def get(token) when is_binary(token) do
    case get_session_via_mcp(token) do
      {:ok, row} ->
        {:ok, row_to_external(row, token)}

      {:error, :not_found} ->
        {:error, :invalid_session}
    end
  end

  @doc """
  Refresh a session, extending its expiration time.

  ## Examples

      {:ok, session} = Sanctum.Session.refresh("abc123...")
      # Session expiration extended by 24 hours from now

  """
  @spec refresh(String.t()) :: {:ok, session()} | {:error, :invalid_session}
  def refresh(token) when is_binary(token) do
    b64_hash = Base.encode64(hash_token(token))

    with {:ok, _row} <- get_session_via_mcp(token) do
      now = DateTime.utc_now()
      new_expires_at = DateTime.add(now, session_ttl_seconds(), :second) |> DateTime.truncate(:microsecond)

      case Arca.MCP.handle("session_store", mcp_ctx(), %{
        "action" => "refresh",
        "token_hash" => b64_hash,
        "new_expires_at" => DateTime.to_iso8601(new_expires_at)
      }) do
        {:ok, _} ->
          case get_session_via_mcp(token) do
            {:ok, row} -> {:ok, row_to_external(row, token)}
            {:error, :not_found} -> {:error, :invalid_session}
          end

        {:error, :not_found} ->
          {:error, :invalid_session}
      end
    else
      {:error, :not_found} -> {:error, :invalid_session}
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
  @spec list_active() :: {:ok, [map()]}
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
    end
  end

  @doc """
  Clean up expired sessions.

  Returns the number of sessions removed.
  """
  @spec cleanup() :: {:ok, non_neg_integer()}
  def cleanup do
    case Arca.MCP.handle("session_store", mcp_ctx(), %{"action" => "cleanup_expired"}) do
      {:ok, %{cleaned: count}} -> {:ok, count}
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
    revocation_ttl_seconds = max(48 * 3600, session_ttl_seconds() * 2)
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
        Logger.warning("Cannot verify session revocation due to error: #{inspect(reason)} - treating as potentially revoked")
        true
    end
  end

  @doc """
  Clean up expired revocation entries.

  Returns the number of entries removed.
  """
  @spec cleanup_revocations() :: {:ok, non_neg_integer()}
  def cleanup_revocations do
    case Arca.MCP.handle("session_store", mcp_ctx(), %{"action" => "cleanup_revocations"}) do
      {:ok, %{cleaned: count}} -> {:ok, count}
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp get_session_via_mcp(token) do
    b64_hash = Base.encode64(hash_token(token))

    case Arca.MCP.handle("session_store", mcp_ctx(), %{
      "action" => "get",
      "token_hash" => b64_hash
    }) do
      {:ok, %{session: row}} -> {:ok, row}
      {:error, :not_found} -> {:error, :not_found}
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
      row[:permissions]
      |> Jason.decode!()
      |> Enum.map(&safe_to_atom/1)

    %User{
      id: row[:user_id],
      email: row[:email],
      provider: row[:provider],
      permissions: permissions
    }
  end

  defp row_to_external(row, token) do
    %{
      token: token,
      user_id: row[:user_id],
      email: row[:email],
      provider: row[:provider],
      permissions: Jason.decode!(row[:permissions]),
      created_at: row[:inserted_at],
      expires_at: row[:expires_at]
    }
  end

  defp safe_to_atom(value), do: Sanctum.Atoms.safe_to_permission_atom(value)
end
