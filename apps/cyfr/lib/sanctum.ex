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
      {:ok, ctx} = Sanctum.authenticate(params)

  ## Sanctum Arx (Enterprise)

  Uses full OIDC authentication with configurable providers:

      {:ok, ctx} = Sanctum.authenticate(params)

  ## Configuration

      config :cyfr,
        auth_provider: Sanctum.Auth.SimpleOAuth  # or Arx.Auth.OIDC

  """

  alias Sanctum.Context

  @doc """
  Get current Context from request connection.
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
  Context for legitimate background/system operations (cron, sweepers, health checks).

  Returns a `scope: :platform` context with `user_id: "system"` and
  `namespace: "_system"`. Platform scope bypasses tenant boundary checks
  (`Sanctum.TenantPolicy.verify/2`), correctly modeling system tasks that
  cross tenant boundaries (retention, cache sweep, audit fan-out).
  """
  def system_context do
    Context.build(
      user_id: "system",
      namespace: "_system",
      permissions: [:execute, :storage_read, :execution_write, :storage_write],
      scope: :platform,
      auth_method: :scheduled,
      authenticated: true
    )
  end

  defp auth_provider do
    Application.get_env(:cyfr, :auth_provider) ||
      raise "No auth provider configured. Set CYFR_GITHUB_CLIENT_ID."
  end
end
