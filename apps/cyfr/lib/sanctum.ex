defmodule Sanctum do
  require Logger

  @moduledoc """
  Identity and authorization layer for CYFR.

  Sanctum is the gatekeeper for all CYFR operations. It manages:
  - **Authentication**: Who is making the request (OAuth, API keys)
  - **Authorization**: What they're allowed to do (permissions)
  - **Context**: The execution context that flows through all services

  ## Sanctum Core

  Uses OAuth Device Flow for CLI authentication:

      # User runs: cyfr login
      # After auth completes:
      {:ok, user} = Sanctum.authenticate(params)
      ctx = Sanctum.build_context(user)

  ## Sanctum Arx (Enterprise)

  Uses full OIDC authentication with configurable providers:

      {:ok, user} = Sanctum.authenticate(params)
      ctx = Sanctum.build_context(user)

  ## Configuration

      config :cyfr,
        auth_provider: Sanctum.Auth.SimpleOAuth  # or SanctumArx.Auth.OIDC

  """

  alias Sanctum.Context
  alias Sanctum.User

  @doc """
  Get current user from request context.
  """
  def current_user(conn) do
    auth_provider().current_user(conn)
  end

  @doc """
  Authenticate with provided credentials/params.
  """
  def authenticate(params) do
    auth_provider().authenticate(params)
  end

  @doc """
  Build execution context from authenticated user.

  ## Examples

      iex> user = Sanctum.User.local()
      iex> ctx = Sanctum.build_context(user)
      iex> ctx.user_id
      "local_user"

  """
  def build_context(%User{} = user) do
    Context.build(
      user_id: user.id,
      permissions: user.permissions,
      scope: :project
    )
  end

  @doc """
  Get context for local development (Sanctum).

  Shortcut that returns a context with full permissions.

  ## Examples

      iex> ctx = Sanctum.local_context()
      iex> Sanctum.Context.has_permission?(ctx, :execute)
      true

  """
  def local_context do
    if Application.get_env(:cyfr, :edition, :core) == :arx do
      raise "[Sanctum] local_context/0 is forbidden in Arx edition — use tenant-scoped context instead"
    end

    Context.local()
  end

  @doc """
  Context for legitimate background/system operations (cron, sweepers, health checks).

  Uses `Sanctum.Context.for_scheduled("system")` — limited permissions, auditable,
  no god-mode. Prefer this over `local_context/0` for system-level tasks.

  **WARNING**: This context has no tenant scope (empty org_id/project_id).
  It must NOT be used for tenant-scoped operations in Arx mode. Use it only
  for cross-tenant administrative tasks like retention cleanup, cache sweeping,
  and health checks.
  """
  def system_context do
    Context.for_scheduled("system")
  end

  defp auth_provider do
    Application.get_env(:cyfr, :auth_provider) ||
      raise "No auth provider configured. Set CYFR_GITHUB_CLIENT_ID."
  end
end
