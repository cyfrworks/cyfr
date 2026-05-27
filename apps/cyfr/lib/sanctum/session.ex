# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Session do
  @moduledoc """
  Session management for CYFR.

  Provides session storage backed by `Arca.SessionStorage`.
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

  ## Session Format

  Each session contains:
  - `token` - Random 32-byte base64 token
  - `user_id` - Identity ID from OIDC provider (`<provider>|<iss>|<sub>`)
  - `email` - Email (optional)
  - `provider` - Auth provider (e.g., "github", "google")
  - `created_at` - ISO 8601 timestamp
  - `expires_at` - ISO 8601 timestamp (30 days by default; extended on activity)

  ## Storage

  Sessions are stored via `Arca.SessionStorage`.
  Tokens are stored as SHA-256 hashes for indexed lookups.
  Expired sessions are automatically cleaned up.
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
  # Microsecond precision so it dumps cleanly into the `:utc_datetime_usec`
  # `expires_at` column on both adapters.
  @never_expires ~U[9999-12-31 23:59:59.999999Z]

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
      # A resolved context carries a concrete org; an org-less ("") value marks a
      # not-yet-resolved session (user with no membership) and is re-resolved on
      # load. Persisting `scope` lets a resolved session skip per-request
      # membership re-resolution on reload.
      org_id: ctx.org_id || "",
      project_id: ctx.project_id,
      scope: to_string(ctx.scope),
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
  @spec load(String.t()) ::
          {:ok, Context.t()}
          | {:error, :invalid_session | :database_error | :namespace_unavailable}
  def load(token) when is_binary(token) do
    case get_session_direct(token) do
      {:ok, row} ->
        case row_to_context(row) do
          {:error, :namespace_unavailable} = err -> err
          %Context{} = ctx -> {:ok, ctx}
        end

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
             %DateTime{} = expires_at <- coerce_datetime(row.expires_at),
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

  ## Examples

      :ok = Sanctum.Session.destroy("abc123...")

  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(token) when is_binary(token) do
    Arca.SessionStorage.delete_session(hash_token(token))
  end

  @doc """
  List active sessions scoped to a tenant context (for admin purposes).

  Returns sessions with tokens redacted. Requires a `%Context{}` to scope
  the query to the caller's org and project.
  """
  @spec list_active(Sanctum.Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list_active(%Sanctum.Context{} = ctx) do
    opts = [
      org_id: ctx.org_id,
      project_id: ctx.project_id
    ]

    case Arca.SessionStorage.list_active_sessions(opts) do
      {:ok, rows} ->
        active =
          Enum.map(rows, fn row ->
            prefix = if row.token_prefix, do: row.token_prefix <> "...", else: "..."

            %{
              token_prefix: prefix,
              user_id: row.user_id,
              email: row.email,
              provider: row.provider,
              created_at: format_datetime(row.inserted_at),
              expires_at: format_datetime(row.expires_at)
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
  Switch the session's active workspace to `(org_id, project_id)`.

  Validates the target is within the caller's authorization ceiling
  (`Sanctum.Tenancy.list_workspaces/1`) before persisting — a platform admin may
  switch into any org; a member only into their granted orgs/projects. Returns
  `{:error, :forbidden}` for an inaccessible workspace. The scope (the ceiling)
  is unchanged; only the active org/project move.
  """
  @spec set_workspace(String.t(), String.t(), String.t()) ::
          :ok
          | {:error,
             :forbidden | :invalid_session | :database_error | :namespace_unavailable}
  def set_workspace(token, org_id, project_id)
      when is_binary(token) and is_binary(org_id) and is_binary(project_id) do
    with {:ok, ctx} <- load(token) do
      if workspace_allowed?(ctx, org_id, project_id) do
        Arca.SessionStorage.update_workspace(hash_token(token), org_id, project_id)
      else
        {:error, :forbidden}
      end
    end
  end

  defp workspace_allowed?(ctx, org_id, project_id) do
    Enum.any?(Sanctum.Tenancy.list_workspaces(ctx), fn w ->
      w.org_id == org_id and w.project_id == project_id
    end)
  end

  # ============================================================================
  # Internal
  # ============================================================================

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
      case Jason.decode(row.permissions || "[]") do
        {:ok, list} when is_list(list) ->
          Enum.map(list, &safe_to_atom/1)

        _ ->
          Logger.warning(
            "[Sanctum.Session] Malformed permissions JSON for user #{row.user_id}, defaulting to empty"
          )

          []
      end

    case Sanctum.Namespace.lookup_status(row.user_id) do
      :not_claimed ->
        # Session valid, but the user has no claimed namespace yet — keep the
        # context unauthenticated so RequirePersonalNamespace plug forwards
        # them to /claim-namespace before any tenant-scoped operation runs.
        Context.build(
          user_id: row.user_id,
          email: row.email,
          provider: row.provider,
          authenticated: false
        )

      {:ok, ns} ->
        {scope, org_id} = restore_workspace(row)

        Context.build(
          user_id: row.user_id,
          email: row.email,
          provider: row.provider,
          namespace: ns,
          permissions: permissions,
          org_id: org_id,
          project_id: row.project_id,
          scope: scope,
          auth_method: :oidc,
          authenticated: true
        )

      {:error, _reason} ->
        # Transient CredentialStore/DB failure — distinct from "not claimed".
        # Surface a retryable error so the caller returns 503 rather than
        # silently downgrading a valid user to unauthenticated and wedging
        # them at /claim-namespace (re-claim then 409s).
        {:error, :namespace_unavailable}
    end
  end

  # Restore the persisted working scope + org. A concrete org means the session
  # was resolved at create time — trust its scope (falling back to :project for
  # legacy rows written before the `scope` column existed; that matches the prior
  # always-`:project` behaviour and is corrected on the next login). An empty/nil
  # org means the session was never resolved to a tenant (a user with no
  # membership, or a legacy platform-admin row stored as ""): hand the builder a
  # nil org so `Sanctum.Tenancy.resolve_into/2` re-reads memberships on this
  # request (and the tenant gate still bounces a genuinely org-less user).
  defp restore_workspace(row) do
    case row.org_id do
      org when is_binary(org) and org != "" -> {parse_scope(row.scope), org}
      _ -> {:project, nil}
    end
  end

  defp parse_scope("platform"), do: :platform
  defp parse_scope("org"), do: :org
  defp parse_scope("project"), do: :project
  defp parse_scope(_), do: :project

  defp row_to_external(row, token) do
    permissions =
      case Jason.decode(row.permissions || "[]") do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    %{
      token: token,
      user_id: row.user_id,
      email: row.email,
      provider: row.provider,
      permissions: permissions,
      created_at: format_datetime(row.inserted_at),
      expires_at: format_datetime(row.expires_at)
    }
  end

  # The schema loads timestamps as `%DateTime{}` on both adapters; pass nil
  # through and stringify the rest for the external session contract.
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(nil), do: nil
  defp format_datetime(other), do: other

  defp coerce_datetime(%DateTime{} = dt), do: dt
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
