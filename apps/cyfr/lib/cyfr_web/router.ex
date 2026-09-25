# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Router do
  @moduledoc """
  The composition router: the one module whose `__routes__/0` is every
  HTTP route the endpoint serves.

  It declares no route and no pipeline of its own. Each adapter's route
  provider hands its pipelines and routes in by macro, so the table stays
  one table and each adapter's routes stay in its own file. The providers'
  prefixes are disjoint, so their order here does not change matching.
  """

  use CyfrWeb, :router

  require CyfrWeb.Ingress.Router
  # The console's and the ingress's browser pipelines expand from this macro.
  require CyfrWeb.Pipelines
  require Emissary.Router
  require Prism.Router

  # The MCP adapter: the `:mcp` pipeline and the `/mcp` scope.
  Emissary.Router.routes()

  # The host's ingress: sign-in and sign-out, the OAuth grant callback,
  # tincture serving, health, the execution-events stream and webhooks.
  CyfrWeb.Ingress.Router.routes()

  # The console: the claim and legal pages, sign-in, attachments and the LiveViews.
  Prism.Router.routes()
end
