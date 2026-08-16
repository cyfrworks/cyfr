# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RouteAuthInventoryTest do
  @moduledoc """
  A mechanical inventory of every HTTP route and how it is authenticated —
  the route-level analogue of `Cyfr.IngressInventoryTest`.

  Auth for a route lives in one of a few places: a bearer-credential or
  webhook-HMAC plug on the pipeline, a LiveView `live_session` `on_mount`, the controller
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
    {:post, "/t/:athanor/:publisher/:tincture_name/invoke"} => :tincture_handler_auth,
    {:options, "/t/:athanor/:publisher/:tincture_name/invoke"} => :tincture_handler_auth,
    {:get, "/t/:athanor/:publisher/:tincture_name"} => :tincture_handler_auth,
    {:get, "/t/:athanor/:publisher/:tincture_name/*path"} => :tincture_handler_auth,

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

    # Prism on the one endpoint — public
    {:get, "/auth/logout"} => :browser_public_auth,
    {:get, "/login"} => :browser_public_login,

    # Prism — live_session :athanor (LiveAuth + Focus on_mount): every page
    # is `/a/<athanor>/…`, the athanor in focus is the URL's.
    {:get, "/"} => :browser_authenticated,
    {:get, "/a"} => :browser_authenticated,
    {:get, "/a/:athanor"} => :browser_authenticated,
    {:get, "/a/:athanor/agents"} => :browser_authenticated,
    {:get, "/a/:athanor/activities"} => :browser_authenticated,
    {:get, "/a/:athanor/enforcements"} => :browser_authenticated,
    {:get, "/a/:athanor/executions"} => :browser_authenticated,
    {:get, "/a/:athanor/components"} => :browser_authenticated,
    {:get, "/a/:athanor/components/:ref"} => :browser_authenticated,
    {:get, "/a/:athanor/registry"} => :browser_authenticated,
    {:get, "/a/:athanor/reports"} => :browser_authenticated,
    {:get, "/a/:athanor/builds"} => :browser_authenticated,
    {:get, "/a/:athanor/connections"} => :browser_authenticated,
    {:get, "/a/:athanor/api-keys"} => :browser_authenticated,
    {:get, "/a/:athanor/members"} => :browser_authenticated,
    {:get, "/a/:athanor/webhooks"} => :browser_authenticated,
    {:get, "/a/:athanor/schedules"} => :browser_authenticated,
    {:get, "/a/:athanor/settings"} => :browser_authenticated,
    {:get, "/a/:athanor/mcp-servers"} => :browser_authenticated,
    {:get, "/a/:athanor/tinctures"} => :browser_authenticated,
    {:get, "/a/:athanor/legal"} => :browser_authenticated
  }

  test "every HTTP route has a classified auth posture" do
    found =
      [EmissaryWeb.Router]
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
