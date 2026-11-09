# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web do
  @moduledoc """
  Emissary's HTTP adapters' `use` definitions: MCP, the HTTP API and its
  event streams, health, inbound webhooks, the vault's OAuth callback,
  tinctures' served files and data routes, a canvas's page
  (`Emissary.Web.CanvasController`) and the identity directory's
  endpoints. The device channel
  (`Emissary.Web.DeviceChannel`) is the socket the endpoint mounts beside
  them, and a frame's stream connection (`Emissary.Web.FrameSocket`) the
  socket its data routes upgrade to.

      use Emissary.Web, :controller

  The adapters answer JSON and server-sent events, and serve pages as
  well: a tincture's entry page and files, a canvas's page, and the
  no-session pages `CyfrWeb.MinimalPage` renders. None renders a template or builds a
  path, so a controller here takes no verified routes.
  Content negotiation is each route's pipeline's `accepts`, not the
  controller's formats.
  """

  use Boundary,
    top_level?: true,
    deps: [Emissary, Sanctum, Arca, Cyfr, Compendium, Opus, CyfrWeb],
    exports: [
      AccountController,
      CanvasController,
      DeviceSessionController,
      DeviceChannel,
      DirectoryController,
      ExecutionEventsController,
      FrameSocket,
      HandleController,
      HealthController,
      MCPController,
      MCPError,
      OAuthCallbackController,
      Plugs.MCPRequestMetadata,
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
