# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Router do
  @moduledoc """
  The composition router: the one module whose `__routes__/0` is every
  HTTP route the endpoint serves.

  It declares no route and no pipeline of its own. Each adapter's route
  provider hands its pipelines and routes in by macro, so the table stays
  one table and each adapter's routes stay in its own file.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Arca,
      Sanctum,
      Cyfr,
      Compendium,
      Aqua,
      Opus,
      Emissary,
      Emissary.Router,
      Emissary.Web,
      Prism,
      Prism.Router,
      PrismWeb,
      CyfrWeb
    ],
    exports: [],
    check: [aliases: true]

  use CyfrWeb, :router

  # The browser pipelines Prism declares expand from `CyfrWeb.Pipelines.browser/2`.
  require CyfrWeb.Pipelines
  require Emissary.Router
  require Prism.Router

  # Emissary: MCP, the HTTP API's sign-out and session read, the OAuth
  # grant callback, tincture serving, health, the execution-events stream
  # and webhooks.
  Emissary.Router.routes()

  # The console: browser sign-in and sign-out, the claim and legal pages,
  # attachments and the LiveViews.
  Prism.Router.routes()
end
