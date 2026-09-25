# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Ingress do
  @moduledoc """
  The host's HTTP ingress `use` definitions.

      use CyfrWeb.Ingress, :controller

  The ingress controllers answer JSON and the no-session pages
  `CyfrWeb.MinimalPage` renders, and redirect to literal paths, so a
  controller here takes neither verified routes nor Gettext.
  """

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
