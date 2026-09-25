# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Router do
  @moduledoc """
  The MCP adapter's routes: the `:mcp` pipeline and the `/mcp` scope.

  The composition router invokes `routes/0` where the adapter's routes
  stand, so its `__routes__/0` stays the total table. The quoted calls
  resolve where the macro expands, against the composition router's
  `use Phoenix.Router` and its imports; this module imports nothing.
  """

  # The root's table is the one table; `Phoenix.Router.forward/4` cannot span several prefixes.
  defmacro routes do
    quote do
      # MCP accepts POST only. GET and DELETE return 405; preflight must
      # advertise only the supported method.
      pipeline :mcp do
        plug CyfrWeb.Plugs.CallIdentity
        plug :accepts, ["json", "event-stream"]
        plug CyfrWeb.Plugs.ApiSecurityHeaders
        plug CyfrWeb.Plugs.CORS, methods: ~w(POST)
        plug CyfrWeb.Plugs.MCPOrigin, errors: Emissary.Web.MCPError
        # Before Authenticate so unauthenticated floods never touch DB state.
        plug CyfrWeb.Plugs.MCPRateLimit, errors: Emissary.Web.MCPError
        plug CyfrWeb.Plugs.Authenticate, errors: Emissary.Web.MCPError
        plug Emissary.Web.Plugs.MCPRequestMetadata
      end

      # MCP endpoint. POST is the only verb this revision defines: a request's own
      # response stream carries its progress, so there is no standalone stream to
      # open, and there is no session to terminate.
      scope "/mcp", Emissary.Web do
        pipe_through :mcp

        post "/", MCPController, :handle, metadata: %{auth: :authenticate_plug}
        get "/", MCPController, :method_not_allowed, metadata: %{auth: :authenticate_plug}
        delete "/", MCPController, :method_not_allowed, metadata: %{auth: :authenticate_plug}
      end
    end
  end
end
