# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb do
  @moduledoc """
  The entrypoint for defining the Prism web interface.

  This can be used in your application as:

      use PrismWeb, :controller
      use PrismWeb, :live_view
      use PrismWeb, :html

  """

  def static_paths, do: ~w(assets fonts images sdk favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

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

      import PrismWeb.MCPHelpers
      import PrismWeb.DisplayHelpers

      # When embedded in the shell via live_render, handle_params won't be called.
      # This on_mount hook detects shell mode and sends :shell_init so the LiveView
      # can load data in handle_info instead.
      on_mount {PrismWeb.ShellCompat, :maybe_shell}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

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

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PrismWeb.Endpoint,
        router: PrismWeb.Router,
        statics: PrismWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
