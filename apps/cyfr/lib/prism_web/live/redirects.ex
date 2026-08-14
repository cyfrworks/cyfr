# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` → `/activities`. The cockpit-with-cards landing was retired in favour of
  live indicators in the topbar; the activity stream is now the home view.
  """

  use PrismWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/activities")}
  end

  def render(assigns), do: ~H""
end
