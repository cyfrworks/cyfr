# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web do
  @moduledoc """
  The MCP adapter's `use` definitions.

      use Emissary.Web, :controller

  The adapter answers JSON and server-sent events only, so a controller
  here takes neither verified routes nor Gettext; the host's shared web
  tier (`CyfrWeb`) keeps those for the adapters that render pages.
  """

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

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
