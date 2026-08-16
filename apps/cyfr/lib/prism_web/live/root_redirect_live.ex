# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` and `/a` land in the session's athanor; `/a/<athanor>` lands on that
  athanor's activity stream — the home view since the cockpit-with-cards
  landing was retired in favour of live indicators in the topbar.
  """

  use PrismWeb, :live_view

  def mount(_params, _session, socket) do
    case socket.assigns[:athanor] do
      nil -> {:ok, redirect(socket, to: "/login?error=no_athanor")}
      athanor -> {:ok, push_navigate(socket, to: PrismWeb.Focus.path(athanor, "/activities"))}
    end
  end

  def render(assigns), do: ~H""
end
