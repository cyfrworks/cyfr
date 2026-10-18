# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb do
  @moduledoc """
  The entrypoint for defining the Prism web interface.

  Prism is the LiveView face served by the one endpoint
  (`CyfrWeb.Endpoint`); its routes are `Prism.Router`'s, composed into
  `CyfrWeb.Router`.

  A default that decides authority when nobody chooses is read from the
  module that owns its policy, never set here: an API key's default
  scopes are `Sanctum.ApiKey.default_scopes/1`'s, and a consent sheet
  opens on what the grant's head binds and the suggestions of Sanctum's
  plan rows (`Prism.ConsentChoices.initial_choices/2`).

  This can be used in your application as:

      use PrismWeb, :controller
      use PrismWeb, :live_view
      use PrismWeb, :html

  """

  use Boundary,
    deps: [Prism, CyfrWeb, Sanctum, Arca, Cyfr, Compendium, Aqua, Opus],
    exports: [
      ActiveContext,
      ActivitiesLive,
      ApiKeysLive,
      AquaLive,
      AttachmentController,
      AuthController,
      BuildsLive,
      CarryLive,
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
      PairLive,
      PasskeyController,
      ReauthController,
      RegistryLive,
      RestoreLive,
      RootRedirectLive,
      SchedulesLive,
      SettingsLive,
      ShellLive,
      VaultLive,
      WebhooksLive
    ],
    dirty_xrefs: [CyfrWeb.Endpoint, CyfrWeb.Router],
    check: [aliases: true]

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

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
