# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RouteAuthInventoryTest do
  @moduledoc """
  A mechanical inventory of every HTTP route and how it is authenticated —
  the route-level analogue of `Cyfr.IngressInventoryTest`.

  Auth for a route lives in one of a few places: an MCP-session or webhook-HMAC
  plug on the pipeline, a LiveView `live_session` `on_mount`, the controller
  itself (tincture, whoami/logout), or nowhere by design (health, login). None
  of those is a single boolean the router exposes, so instead every route is
  classified here against a literal map. A NEW route fails this test until it is
  classified — the fail-closed direction — which forces the auth decision to be
  explicit rather than inherited by accident from a scope.
  """

  use ExUnit.Case, async: true

  # {verb, path} => how this route is authenticated. Adding a row is a
  # deliberate act: it records the reviewed auth posture of that route.
  @classified %{
    # EmissaryWeb — chokepoint-authenticated
    {:post, "/mcp"} => :authenticate_plug,
    # GET and DELETE reach only `method_not_allowed`, which answers 405 without
    # consulting the caller. They still run the pipeline, so they authenticate
    # like any other MCP route — but nothing behind them can act on that.
    {:get, "/mcp"} => :authenticate_plug,
    {:delete, "/mcp"} => :authenticate_plug,
    # Same credential plug, its own pipeline: an SSE endpoint that does not
    # speak JSON-RPC and must not answer in it.
    {:get, "/api/executions/:id/events"} => :authenticate_plug,
    {:post, "/hooks/:slug"} => :webhook_hmac,

    # EmissaryWeb — controller self-gates (401/400 without a token), now
    # rate-limited via :auth_api_throttle
    {:delete, "/auth/logout"} => :handler_auth,
    {:get, "/auth/whoami"} => :handler_auth,

    # EmissaryWeb — tincture surface: auth + tenancy in the controller helper
    {:get, "/t/access-token"} => :tincture_handler_auth,
    {:options, "/t/access-token"} => :tincture_handler_auth,
    {:post, "/t/:org/:project/:publisher/:tincture_name/invoke"} => :tincture_handler_auth,
    {:options, "/t/:org/:project/:publisher/:tincture_name/invoke"} => :tincture_handler_auth,
    {:get, "/t/:org/:project/:publisher/:tincture_name"} => :tincture_handler_auth,
    {:get, "/t/:org/:project/:publisher/:tincture_name/*path"} => :tincture_handler_auth,

    # EmissaryWeb — browser OAuth / gates (state token, cookies, IdP callback)
    {:get, "/auth/oauth/callback"} => :public_oauth_state,
    {:get, "/auth/:provider"} => :browser_oauth_start,
    {:get, "/auth/:provider/callback"} => :browser_oauth_callback,
    {:get, "/auth/post-legal-accept"} => :browser_oauth_flow,
    {:get, "/claim-namespace"} => :browser_claim_gate,
    {:post, "/claim-namespace/submit"} => :browser_claim_gate,
    {:get, "/legal/accept"} => :browser_public_legal,
    {:post, "/legal/accept/submit"} => :browser_public_legal,

    # EmissaryWeb — intentionally public
    {:get, "/api/health"} => :public_health,
    {:get, "/api/health/ready"} => :public_health,

    # PrismWeb — public
    {:get, "/auth/session"} => :browser_public_auth,
    {:get, "/auth/logout"} => :browser_public_auth,
    {:get, "/login"} => :browser_public_login,

    # PrismWeb — live_session :authenticated (LiveAuth on_mount)
    {:get, "/"} => :browser_authenticated,
    {:get, "/activities"} => :browser_authenticated,
    {:get, "/enforcements"} => :browser_authenticated,
    {:get, "/executions"} => :browser_authenticated,
    {:get, "/logs"} => :browser_authenticated,
    {:get, "/logs/:id"} => :browser_authenticated,
    {:get, "/components"} => :browser_authenticated,
    {:get, "/components/:ref"} => :browser_authenticated,
    {:get, "/registry"} => :browser_authenticated,
    {:get, "/reports"} => :browser_authenticated,
    {:get, "/builds"} => :browser_authenticated,
    {:get, "/connections"} => :browser_authenticated,
    {:get, "/api-keys"} => :browser_authenticated,
    {:get, "/webhooks"} => :browser_authenticated,
    {:get, "/schedules"} => :browser_authenticated,
    {:get, "/settings"} => :browser_authenticated,
    {:get, "/mcp-servers"} => :browser_authenticated,
    {:get, "/tinctures"} => :browser_authenticated,
    {:get, "/legal"} => :browser_authenticated
  }

  test "every HTTP route has a classified auth posture" do
    found =
      [EmissaryWeb.Router, PrismWeb.Router]
      |> Enum.flat_map(fn router -> router.__routes__() end)
      |> Enum.map(fn r -> {r.verb, r.path} end)
      |> MapSet.new()

    known = MapSet.new(Map.keys(@classified))

    unclassified = MapSet.difference(found, known)
    stale = MapSet.difference(known, found)

    assert MapSet.size(unclassified) == 0, """
    A new HTTP route appeared and its auth posture is not classified:

      #{unclassified |> MapSet.to_list() |> Enum.sort() |> inspect(pretty: true)}

    Add it to @classified with the mechanism that authenticates it (or mark it
    intentionally public). A route must not inherit auth by accident from a scope.
    """

    assert MapSet.size(stale) == 0, """
    These classified routes no longer exist — drop them from @classified:

      #{stale |> MapSet.to_list() |> Enum.sort() |> inspect(pretty: true)}
    """
  end
end
