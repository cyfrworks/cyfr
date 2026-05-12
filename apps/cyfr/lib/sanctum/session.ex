defmodule Sanctum.Session do
  @moduledoc """
  Session management for CYFR.

  Provides session storage backed by SQLite via `Arca.SessionStorage`.
  Tokens are hashed (SHA-256) before storage —
  the actual token is never persisted.

  ## Usage

      # Create a session after OAuth callback
      {:ok, session} = Sanctum.Session.create(ctx)

      # Load context from session token
      {:ok, ctx} = Sanctum.Session.load(session.token)

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
  - `user_id` - Identity ID from OIDC provider (`<provider>|<iss>|<sub>`)
  - `email` - Email (optional)
  - `provider` - Auth provider (e.g., "github", "google")
  - `created_at` - ISO 8601 timestamp
  - `expires_at` - ISO 8601 timestamp (30 days by default; extended on activity)

  ## Storage

  Sessions are stored in SQLite via `Arca.SessionStorage`.
  Tokens are stored as SHA-256 hashes for indexed lookups.
  Revoked session IDs are tracked in a separate table.
  Expired sessions and old revocations are automatically cleaned up.
  """

  require Logger

  alias Sanctum.Context

  # Session configuration
  # 30 days by default — sessions slide forward on activity (see refresh_if_stale/1),
  # so this acts as an idle timeout, not a hard cap.
  @default_session_ttl_hours 720
  @min_session_ttl_hours 1
  @token_bytes 32
  # Year 9999 — used as expires_at when TTL is 0 (infinite)
  @never_expires ~U[9999-12-31 23:59:59Z]

  defp session_ttl_hours do
    case Application.get_env(:cyfr, :session_ttl_hours, @default_session_ttl_hours) do
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
  Create a new session for an authenticated context.

  Returns a session map containing the token and identity fields.

  ## Examples

      ctx = Sanctum.Context.build(user_id: "123", email: "alice@example.com", provider: "github")
      {:ok, session} = Sanctum.Session.create(ctx)
      session.token
      #=> "abc123..."

  """
  @spec create(Context.t()) :: {:ok, session()} | {:error, term()}
  def create(%Context{} = ctx) do
    with :ok <- check_allowed_user(ctx.email) do
      token = generate_token()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      expires_at =
        case session_ttl_hours() do
          0 -> @never_expires
          hours -> DateTime.add(now, hours * 3600, :second)
        end

      permissions_list = ctx.permissions |> MapSet.to_list() |> Enum.map(&to_string/1)

      case Jason.encode(permissions_list) do
        {:ok, permissions_json} ->
          create_session_with_permissions(ctx, token, now, expires_at, permissions_json)

        {:error, reason} ->
          {:error, {:encode_failed, reason}}
      end
    end
  end

  defp create_session_with_permissions(%Context{} = ctx, token, now, expires_at, permissions_json) do
    attrs = %{
      "token_prefix" => String.slice(token, 0, 8),
      "user_id" => ctx.user_id,
      "email" => ctx.email,
      "provider" => ctx.provider,
      "permissions" => permissions_json,
      "expires_at" => DateTime.to_iso8601(expires_at),
      "inserted_at" => DateTime.to_iso8601(now)
    }

    parsed_attrs = %{
      token_prefix: attrs["token_prefix"],
      user_id: attrs["user_id"],
      email: attrs["email"],
      provider: attrs["provider"],
      permissions: attrs["permissions"],
      org_id: ctx.org_id || "",
      project_id: ctx.project_id,
      expires_at: expires_at,
      inserted_at: now
    }

    case Arca.SessionStorage.create_session(hash_token(token), parsed_attrs) do
      :ok ->
        session = %{
          token: token,
          user_id: ctx.user_id,
          email: ctx.email,
          provider: ctx.provider,
          permissions: ctx.permissions |> MapSet.to_list() |> Enum.map(&to_string/1),
          created_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        broadcast_session_created(session)
        {:ok, session}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Load a Context from a session token.

  Returns a Context with the persistent identity fields populated and
  ephemeral fields (request_id, etc.) nil. Returns `{:error, :invalid_session}`
  if the token is unknown or expired.

  ## Examples

      {:ok, ctx} = Sanctum.Session.load("abc123...")
      ctx.user_id
      #=> "123"

  """
  @spec load(String.t()) :: {:ok, Context.t()} | {:error, :invalid_session | :database_error}
  def load(token) when is_binary(token) do
    case get_session_direct(token) do
      {:ok, row} ->
        {:ok, row_to_context(row)}

      {:error, :not_found} ->
        {:error, :invalid_session}

      {:error, :database_error} ->
        {:error, :database_error}
    end
  end

  @doc """
  Get session details from token.

  Returns the full session map if valid and not expired.
  """
  @spec get(String.t()) :: {:ok, session()} | {:error, :invalid_session | :database_error}
  def get(token) when is_binary(token) do
    case get_session_direct(token) do
      {:ok, row} ->
        {:ok, row_to_external(row, token)}

      {:error, :not_found} ->
        {:error, :invalid_session}

      {:error, :database_error} ->
        {:error, :database_error}
    end
  end

  @doc """
  Refresh a session, extending its expiration time.

  ## Examples

      {:ok, session} = Sanctum.Session.refresh("abc123...")
      # Session expiration extended by 24 hours from now

  """
  @spec refresh(String.t()) :: {:ok, session()} | {:error, :invalid_session | :database_error}
  def refresh(token) when is_binary(token) do
    token_hash = hash_token(token)

    with {:ok, _row} <- get_session_direct(token) do
      now = DateTime.utc_now()

      new_expires_at =
        case session_ttl_hours() do
          0 -> @never_expires
          hours -> DateTime.add(now, hours * 3600, :second) |> DateTime.truncate(:microsecond)
        end

      case Arca.SessionStorage.refresh_session(token_hash, new_expires_at) do
        :ok ->
          case get_session_direct(token) do
            {:ok, row} -> {:ok, row_to_external(row, token)}
            {:error, :not_found} -> {:error, :invalid_session}
            {:error, :database_error} -> {:error, :database_error}
          end

        {:error, :not_found} ->
          {:error, :invalid_session}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :invalid_session}
      {:error, :database_error} -> {:error, :database_error}
    end
  end

  @doc """
  Extend a session's expiration, but only if it hasn't been extended recently.

  This is the activity-based ("sliding window") refresh used on the hot path —
  calling `refresh/1` on every authenticated request would write to SQLite each
  time, so this no-ops unless more than ~1 day (or half the TTL, whichever is
  smaller) has elapsed since the last extension. Always returns `:ok`
  (best-effort — load/write failures are swallowed). No-op for infinite (TTL 0)
  sessions.
  """
  @spec refresh_if_stale(String.t()) :: :ok
  def refresh_if_stale(token) when is_binary(token) do
    case session_ttl_hours() do
      0 ->
        :ok

      ttl_hours ->
        ttl_seconds = ttl_hours * 3600
        stale_after = ttl_seconds - min(86_400, div(ttl_seconds, 2))

        with {:ok, row} <- get_session_direct(token),
             %DateTime{} = expires_at <- coerce_datetime(row[:expires_at]),
             true <- DateTime.diff(expires_at, DateTime.utc_now()) < stale_after,
             {:ok, _session} <- refresh(token) do
          :ok
        else
          _ -> :ok
        end
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
    token_hash = hash_token(token)

    # If session has a session_id, revoke it
    case get_session_direct(token) do
      {:ok, %{session_id: session_id}} when is_binary(session_id) ->
        revoke(session_id)

      _ ->
        :ok
    end

    Arca.SessionStorage.delete_session(token_hash)
  end

  @doc """
  List active sessions scoped to a tenant context (for admin purposes).

  Returns sessions with tokens redacted. Requires a `%Context{}` to scope
  the query to the caller's org and project.
  """
  @spec list_active(Sanctum.Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list_active(%Sanctum.Context{} = ctx) do
    opts = [
      org_id: ctx.org_id || "",
      project_id: ctx.project_id
    ]

    case Arca.SessionStorage.list_active_sessions(opts) do
      {:ok, rows} ->
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

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Clean up expired sessions.

  Returns the number of sessions removed.
  """
  @spec cleanup() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup do
    Arca.SessionStorage.cleanup_expired_sessions()
  end

  @doc """
  Revoke a session by its session_id (used for JWT validation).

  Revoked session IDs are stored and checked during JWT validation
  to prevent use of tokens from destroyed sessions.

  Accepts an optional keyword list to set tenant columns on the
  revocation entry (`:org_id`, `:project_id`).
  """
  @spec revoke(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke(session_id, opts \\ []) when is_binary(session_id) do
    now = DateTime.utc_now()

    expires_at =
      if session_ttl_hours() == 0 do
        # Infinite sessions get permanent revocation
        @never_expires
      else
        # Revocations expire after max(48h, session_ttl * 2)
        revocation_ttl_seconds = max(48 * 3600, session_ttl_hours() * 3600 * 2)
        DateTime.add(now, revocation_ttl_seconds, :second)
      end

    Arca.SessionStorage.put_revocation(session_id, now, expires_at, opts)
  end

  @doc """
  Check if a session_id has been revoked.
  """
  @spec revoked?(String.t()) :: boolean()
  def revoked?(session_id) when is_binary(session_id) do
    case Arca.SessionStorage.revoked?(session_id) do
      {:ok, result} ->
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
  Clean up all expired revocation entries globally. Used by daemon processes.

  Returns the number of entries removed.
  """
  @spec cleanup_revocations() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_revocations do
    Arca.SessionStorage.cleanup_revocations()
  end

  @doc """
  Clean up expired revocation entries scoped to a tenant.

  Requires `:org_id` and `:project_id` in opts.
  """
  @spec cleanup_revocations(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_revocations(opts) when is_list(opts) do
    Arca.SessionStorage.cleanup_revocations(opts)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp check_allowed_user(email) do
    case Application.get_env(:cyfr, :allowed_users) do
      nil ->
        :ok

      [] ->
        :ok

      allowed when is_list(allowed) ->
        if email in allowed, do: :ok, else: {:error, :user_not_allowed}
    end
  end

  defp get_session_direct(token) do
    Arca.SessionStorage.get_session(hash_token(token))
  end

  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp row_to_context(row) do
    permissions =
      case Jason.decode(row[:permissions] || "[]") do
        {:ok, list} when is_list(list) ->
          Enum.map(list, &safe_to_atom/1)

        _ ->
          Logger.warning(
            "[Sanctum.Session] Malformed permissions JSON for user #{row[:user_id]}, defaulting to empty"
          )

          []
      end

    case Sanctum.Namespace.lookup(row[:user_id]) do
      nil ->
        # Session valid, but the user has no claimed namespace yet — keep the
        # context unauthenticated so RequirePersonalNamespace plug forwards
        # them to /claim-namespace before any tenant-scoped operation runs.
        Context.build(
          user_id: row[:user_id],
          email: row[:email],
          provider: row[:provider],
          authenticated: false
        )

      ns when is_binary(ns) ->
        Context.build(
          user_id: row[:user_id],
          email: row[:email],
          provider: row[:provider],
          namespace: ns,
          permissions: permissions,
          org_id: row[:org_id],
          project_id: row[:project_id],
          scope: :project,
          auth_method: :oidc,
          authenticated: true
        )
    end
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
      created_at: format_datetime(row[:inserted_at]),
      expires_at: format_datetime(row[:expires_at])
    }
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_datetime(str) when is_binary(str) do
    # Ensure ISO8601 strings have timezone suffix
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        DateTime.to_iso8601(dt)

      _ ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
          _ -> str
        end
    end
  end

  defp format_datetime(other), do: other

  # Normalize a stored expires_at value (DateTime, NaiveDateTime, or ISO8601
  # string) to a UTC DateTime, or nil if it can't be parsed.
  defp coerce_datetime(%DateTime{} = dt), do: dt
  defp coerce_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp coerce_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp coerce_datetime(_), do: nil

  defp safe_to_atom(value), do: Sanctum.Atoms.safe_to_permission_atom(value)

  @session_topic "sanctum:sessions"

  defp broadcast_session_created(_session) do
    # Notify subscribers (e.g. AuthLive) that a session was created.
    # No token is sent — subscribers use adopt_active_session() to get their own.
    case Application.get_env(:cyfr, :pubsub_name) do
      nil ->
        :ok

      pubsub ->
        Phoenix.PubSub.broadcast(
          pubsub,
          @session_topic,
          {:session_created, :notification}
        )
    end
  rescue
    # PubSub may not be running (e.g. in tests or CLI-only mode)
    _e in [ArgumentError] -> :ok
  end
end
