# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer do
  @moduledoc """
  The system layer: what Prism alone draws above every frame — grant,
  unlock, sign-in and credential-entry prompts, and safe mode. It presents
  a prompt and never decides one; whether a client may confirm is
  Sanctum's (`Sanctum.Pairing`), inside the consent decision.

  This is the mount point the shell mounts. It renders an empty, hidden
  element carrying the `SystemLayer` hook (`assets/js/system_layer/`) and
  holds nothing yet.
  """

  use PrismWeb, :live_component

  @impl true
  def mount(socket), do: {:ok, socket}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, :id, assigns.id)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="SystemLayer" hidden></div>
    """
  end
end
