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
  The configured provider (`:sanctum, :auth_provider`), or `nil` when the
  deployment runs without sign-in.

  Which strategy proves an identity is the identity domain's own
  selection, the same shape as the consent proof store: declared and
  implemented inside Sanctum, chosen by configuration. Nothing above
  needs to know which one — `Sanctum.auth_configured?/0` answers the only
  question exposure-dependent behaviour asks.
  """
  @spec provider() :: module() | nil
  def provider, do: Application.get_env(:sanctum, :auth_provider)

  @doc """
  Authenticate with provided credentials/params.

  Returns `{:ok, context}` on success, `{:error, reason}` on failure. A
  provider maps an identity to a Context; whether that identity may sign in
  to this server is the door's decision (`Sanctum.Door`), taken by the
  caller that mints the session — never by the provider.
  """
  @callback authenticate(params :: map()) :: {:ok, Context.t()} | {:error, term()}

  @doc """
  The context a bearer credential of the provider's OWN issue names, or
  `nil` when the request carries none it recognises.

  Sessions and API keys are this server's credentials, established by
  `Sanctum.Caller.establish/2` before the provider is asked. A release
  configures `Sanctum.Auth.OAuth`, `Sanctum.Auth.OIDC` or none
  (`Cyfr.RuntimeConfig.resolve_auth_provider/1`), and both issue no
  credential of their own and answer `nil`, so in production this asks
  and is told nothing. The callback is the test harness's seam:
  `CyfrWeb.ConnCase` signs a test in through `Emissary.TestAuthProvider`,
  whose bearer this callback reads into a person's context, and
  `CyfrWeb.Plugs.Authenticate` takes a context answered here through the
  same establish recipe as a session's.
  """
  @callback current_user(conn :: Plug.Conn.t()) :: Context.t() | nil
end
