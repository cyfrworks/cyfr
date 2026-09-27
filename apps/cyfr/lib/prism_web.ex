# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb do
  @moduledoc """
  The entrypoint for defining the Prism web interface.

  Prism is the LiveView face served by the one endpoint
  (`CyfrWeb.Endpoint`); its routes are `Prism.Router`'s, composed into
  `CyfrWeb.Router`. This can be used in your application as:

      use PrismWeb, :controller
      use PrismWeb, :live_view
      use PrismWeb, :html

  """

  use Boundary,
    deps: [Prism, CyfrWeb, Grimoire, Sanctum, Arca, Cyfr, Compendium, Aqua, Crucible],
    exports: [
      ActiveContext,
      ActivitiesLive,
      ApiKeysLive,
      AquaLive,
      AttachmentController,
      BuildsLive,
      ChatLive,
      ChatRedirectLive,
      ClaimNamespaceController,
      ComponentDetailLive,
      ComponentsLive,
      EnforcementsLive,
      ExecutionsLive,
      FileController,
      FilesLive,
      Focus,
      Layouts,
      LegalAcceptController,
      LegalLive,
      LoginLive,
      McpServersLive,
      MembersLive,
      MyReportsLive,
      RegistryLive,
      RootRedirectLive,
      SchedulesLive,
      SettingsLive,
      ShellLive,
      WebhooksLive
    ],
    dirty_xrefs: [CyfrWeb.Endpoint, CyfrWeb.Router],
    check: [aliases: true]

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: PrismWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {PrismWeb.Layouts, :app}

      import PrismWeb.Ops
      import PrismWeb.DisplayHelpers

      use PrismWeb.LiveDefaults

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      import PrismWeb.Ops
      import PrismWeb.DisplayHelpers

      use PrismWeb.LiveDefaults

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      import PrismWeb.CoreComponents

      use Gettext, backend: PrismWeb.Gettext

      unquote(verified_routes())
    end
  end

  # Prism's LiveViews mount in the one endpoint; their routes are its routes.
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
