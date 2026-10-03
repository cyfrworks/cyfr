# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.OAuth do
  @moduledoc """
  The built-in GitHub and Google sign-in.

  Both sign in by device flow (`Sanctum.Auth.DeviceFlow`), which proves the
  identity and mints the session itself — in the CLI and on Prism's login
  page alike. There is no browser callback for this provider, so
  `authenticate/1` refuses every callback; a deployment that signs people in
  through its own issuer configures `Sanctum.Auth.OIDC`.

  ## Configuration

      config :sanctum, auth_provider: Sanctum.Auth.OAuth

  - `CYFR_GITHUB_CLIENT_ID` for GitHub (device flow needs no secret)
  - `CYFR_GOOGLE_CLIENT_ID` / `CYFR_GOOGLE_CLIENT_SECRET` for Google

  Whether a proven identity may sign in to this server is the door's
  decision (`Sanctum.Door`), taken before any session is minted.

  A plain OAuth sign-in proves who someone is and never that they are
  present now (`proves_freshness?/0`): the provider may answer it from its
  own session, and a device-flow grant can be approved on another device
  at any time. So it never confirms a sensitive change; a pending
  confirmation is proven by a passkey, a forced-fresh OpenID Connect
  re-authentication or an emailed code (`Sanctum.Consent.Authz`).
  """

  @behaviour Sanctum.Auth

  @doc "A plain OAuth sign-in proves no freshness, so it never counts as a fresh proof."
  @spec proves_freshness?() :: false
  def proves_freshness?, do: false

  @impl true
  @doc """
  Refuses every browser callback: GitHub and Google sign in by device flow.
  """
  def authenticate(_params), do: {:error, :auth_provider_not_supported}

  @impl true
  @doc """
  This provider issues no bearer credential of its own: a session token or
  an API key on a request is established by the one recipe
  (`Sanctum.Caller.establish/2`) in `CyfrWeb.Plugs.Authenticate`
  before the provider is asked. Always `nil`.
  """
  def current_user(_conn), do: nil
end
