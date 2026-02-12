defmodule Sanctum do
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

      config :sanctum,
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
    %Context{
      user_id: user.id,
      org_id: nil,
      permissions: MapSet.new(user.permissions),
      scope: :personal
    }
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
    Context.local()
  end

  defp auth_provider do
    Application.get_env(:sanctum, :auth_provider) ||
      raise "No auth provider configured. Set CYFR_GITHUB_CLIENT_ID or CYFR_GOOGLE_CLIENT_ID."
  end
end
