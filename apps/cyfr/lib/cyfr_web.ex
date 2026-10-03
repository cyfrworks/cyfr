# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use CyfrWeb, :controller
      use CyfrWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  use Boundary,
    deps: [Grimoire, Sanctum, Arca, Cyfr],
    exports: [
      ApiError,
      ContextGuard,
      ErrorJSON,
      ErrorRenderer,
      LiveSocket,
      MetricsPlug,
      MinimalPage,
      PendingProbe,
      Pipelines,
      Plugs.ApiSecurityHeaders,
      Plugs.AuthRateLimit,
      Plugs.Authenticate,
      Plugs.BrowserCSP,
      Plugs.CORS,
      Plugs.CallIdentity,
      Plugs.ConfiguredUeberauth,
      Plugs.ControlPlaneOwnership,
      Plugs.FrameRequest,
      Plugs.Headless,
      Plugs.MCPOrigin,
      Plugs.MCPRateLimit,
      Plugs.ParserErrors,
      Plugs.RawBodyReader,
      Plugs.ScrubTinctureCredentials,
      Plugs.TinctureRateLimit,
      Plugs.VerifyWebhookSignature,
      Plugs.WebhookIdempotency,
      Plugs.WebhookRateLimit,
      SSE,
      SSE.Registry,
      SafeRedirect,
      SignInResponse,
      Telemetry
    ],
    check: [aliases: true]

  # `manifest.webmanifest` and `sw.js` are the PWA's; the service worker is
  # registered by its literal path and both are served undigested.
  def static_paths,
    do: ~w(assets images sdk favicon.ico robots.txt manifest.webmanifest sw.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: CyfrWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: CyfrWeb.Endpoint,
        router: CyfrWeb.Router,
        statics: CyfrWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
