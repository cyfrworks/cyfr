# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaRedirectLive do
  @moduledoc """
  `/a/<athanor>/agents` used to be the agents page. The estate's AQUA lives
  at `/a/<athanor>/aqua` now (`PrismWeb.AquaLive`); the old address
  forwards there.
  """

  use PrismWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: PrismWeb.Focus.path(socket.assigns.athanor_route, "/aqua"))}
  end

  def render(assigns), do: ~H""
end
