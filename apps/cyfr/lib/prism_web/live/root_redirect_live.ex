# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RootRedirectLive do
  @moduledoc """
  `/` and `/a` land in the chat (`PrismWeb.ChatLive` at `/chat`), with the
  session's athanor selected. A person whose name and recovery code are
  not finished (an enrollment attempt still open, as `person.status`
  lists it) lands on Settings instead, where the identity card finishes
  them; a status that cannot be read lands in the chat.
  """

  use PrismWeb, :live_view

  def mount(_params, _session, socket) do
    case socket.assigns[:athanor] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      athanor ->
        slug = Sanctum.Tenancy.Athanors.route_slug(athanor)

        if unfinished?(socket),
          do: {:ok, push_navigate(socket, to: PrismWeb.Focus.path(slug, "/settings"))},
          else: {:ok, push_navigate(socket, to: PrismWeb.ChatLive.chat_path(slug))}
    end
  end

  defp unfinished?(socket) do
    case PrismWeb.Ops.call_tool(socket, "person/status", %{}) do
      {:ok, %{kits: kits}} -> Enum.any?(kits, &(&1.kind == "enrollment"))
      _unread -> false
    end
  end

  def render(assigns), do: ~H""
end
