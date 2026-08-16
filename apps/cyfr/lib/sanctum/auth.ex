# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth do
  @moduledoc """
  Behaviour for authentication providers.

  Different providers implement this behaviour:
  - `Sanctum.Auth.OAuth` - the default, GitHub/Google OAuth Device Flow
  - a configured auth provider - full OIDC

  Both callbacks return a `Sanctum.Context` carrying the persistent identity
  fields (`user_id`, `email`, `provider`, `permissions`, `athanor_id`).
  Per-request fields (`request_id`, etc.) are populated
  later in the request pipeline.
  """

  alias Sanctum.Context

  @doc """
  Authenticate with provided credentials/params.

  Returns `{:ok, context}` on success, `{:error, reason}` on failure. A
  provider maps an identity to a Context; whether that identity may sign in
  to this server is the door's decision (`Sanctum.Door`), taken by the
  caller that mints the session — never by the provider.
  """
  @callback authenticate(params :: map()) :: {:ok, Context.t()} | {:error, term()}

  @doc """
  Get current user context from request connection.

  Returns the authenticated context or `nil` if not authenticated.
  """
  @callback current_user(conn :: Plug.Conn.t()) :: Context.t() | nil
end
