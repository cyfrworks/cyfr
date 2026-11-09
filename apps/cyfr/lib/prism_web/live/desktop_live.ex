# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DesktopLive do
  @moduledoc """
  The desktop alone, at `/`, `/a` and `/a/<athanor>`: the page that draws
  nothing over the person's desktop, so sign-in lands there. The desktop
  itself is `PrismWeb.ShellLive`, which the session's root layout renders
  beside every page of the session; this page is what stands in the
  page's place while no Dashboard page is open over it, and the address a
  Dashboard page's close returns to (`path/1`).

  `?publisher=<p>&tincture_name=<n>` (the palette's and AQUA's
  `ui.tincture.focus`) asks the desktop's picker to show that tincture;
  the desktop's own hook reads it from this page's address and hands it to
  the shell (`PrismWeb.ShellLive`, `focus_named`), so the page does
  nothing with it. A person with no athanor of their own is sent to sign
  in again.
  """

  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:athanor] do
      nil ->
        {:ok, redirect(socket, to: "/login?error=no_athanor")}

      _athanor ->
        {:ok, socket |> assign(:page_title, "Desktop") |> assign(:overlay, false)}
    end
  end

  @impl true
  def render(assigns), do: ~H""

  @doc "The desktop's address for the athanor route `route`: `/a/<route>`, or `/` for none."
  @spec path(String.t() | nil) :: String.t()
  def path(route), do: PrismWeb.Focus.path(route, "")
end
