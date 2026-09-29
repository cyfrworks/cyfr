# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web do
  @moduledoc """
  Emissary's HTTP adapters' `use` definitions: MCP, the HTTP API and its
  event streams, health, inbound webhooks, the vault's OAuth callback,
  and tinctures' served files and data routes.

      use Emissary.Web, :controller

  The adapters answer JSON and server-sent events, and serve pages as
  well: a tincture's entry page and files, and the no-session pages
  `CyfrWeb.MinimalPage` renders. None renders a template or builds a
  path, so a controller here takes neither verified routes nor Gettext.
  Content negotiation is each route's pipeline's `accepts`, not the
  controller's formats.
  """

  use Boundary,
    top_level?: true,
    deps: [Emissary, Grimoire, Sanctum, Arca, Cyfr, Compendium, Crucible, CyfrWeb],
    exports: [
      ExecutionEventsController,
      HealthController,
      MCPController,
      MCPError,
      OAuthCallbackController,
      Plugs.MCPRequestMetadata,
      SessionController,
      TinctureController,
      TinctureDataController,
      WebhookController
    ],
    check: [aliases: true]

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn
    end
  end

  @doc """
  When used, dispatch to the appropriate definition.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
