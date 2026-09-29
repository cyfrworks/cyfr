# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Router do
  @moduledoc """
  The composition router: the one module whose `__routes__/0` is every
  HTTP route the endpoint serves.

  It declares no route and no pipeline of its own. Each adapter's route
  provider hands its pipelines and routes in by macro, so the table stays
  one table and each adapter's routes stay in its own file. Both
  providers hold `/auth` paths, so their order here is part of matching:
  Emissary's static `/auth` paths expand before Prism's `/auth/:provider`
  wildcards.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Arca,
      Sanctum,
      Grimoire,
      Cyfr,
      Compendium,
      Aqua,
      Crucible,
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

  # The shared pipelines both providers declare expand from these macros.
  require CyfrWeb.Pipelines
  require Emissary.Router
  require Prism.Router

  # Emissary: MCP, the HTTP API's sign-out and session read, the OAuth
  # grant callback, tincture serving, health, the execution-events stream
  # and webhooks. Before the console, so its static `/auth` paths precede
  # the browser's `/auth/:provider` wildcards.
  Emissary.Router.routes()

  # The console: browser sign-in and sign-out, the claim and legal pages,
  # attachments and the LiveViews.
  Prism.Router.routes()
end
