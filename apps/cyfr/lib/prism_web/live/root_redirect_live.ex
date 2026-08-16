# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` and `/a` land in the session's athanor — its chat
  (`PrismWeb.ConversationLive` at `/a/<athanor>`).
  """

  use PrismWeb, :live_view

  def mount(_params, _session, socket) do
    case socket.assigns[:athanor] do
      nil -> {:ok, redirect(socket, to: "/login?error=no_athanor")}
      athanor -> {:ok, push_navigate(socket, to: PrismWeb.Focus.path(athanor, ""))}
    end
  end

  def render(assigns), do: ~H""
end
