defmodule Sanctum.Auth do
  @moduledoc """
  Behaviour for authentication providers.

  Different providers implement this behaviour:
  - `Sanctum.Auth.SimpleOAuth` - Sanctum Core, GitHub/Google OAuth Device Flow
  - `Arx.Auth.OIDC` - Sanctum Arx, full OIDC (multi-tenant, enterprise)

  Both callbacks return a `Sanctum.Context` carrying the persistent identity
  fields (`user_id`, `email`, `provider`, `permissions`, `org_id`, `project_id`).
  Per-request fields (`request_id`, `correlation_id`, etc.) are populated
  later in the request pipeline.
  """

  alias Sanctum.Context

  @doc """
  Authenticate with provided credentials/params.

  Returns `{:ok, context}` on success, `{:error, reason}` on failure.
  """
  @callback authenticate(params :: map()) :: {:ok, Context.t()} | {:error, term()}

  @doc """
  Get current user context from request connection.

  Returns the authenticated context or `nil` if not authenticated.
  """
  @callback current_user(conn :: Plug.Conn.t()) :: Context.t() | nil
end
