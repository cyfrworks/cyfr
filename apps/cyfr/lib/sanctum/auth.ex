defmodule Sanctum.Auth do
  @moduledoc """
  Behaviour for authentication providers.

  Different providers implement this behaviour:
  - `Sanctum.Auth.SimpleOAuth` - Sanctum Core, GitHub/Google OAuth Device Flow
  - `SanctumArx.Auth.OIDC` - Sanctum Arx, full OIDC (multi-tenant, enterprise)
  """

  alias Sanctum.User

  @doc """
  Authenticate with provided credentials/params.

  Returns `{:ok, user}` on success, `{:error, reason}` on failure.
  """
  @callback authenticate(params :: map()) :: {:ok, User.t()} | {:error, term()}

  @doc """
  Get current user from request connection.

  Returns the authenticated user or `nil` if not authenticated.
  """
  @callback current_user(conn :: Plug.Conn.t()) :: User.t() | nil
end
