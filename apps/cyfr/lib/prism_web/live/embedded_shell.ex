# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.EmbeddedShell do
  @moduledoc """
  on_mount hook that detects shell-embedded mode and sends :shell_init
  so LiveViews can load data via handle_info instead of handle_params
  (which is not called for child LiveViews rendered via live_render/3).

  Also propagates the authentication context from the parent shell session
  so child LiveViews can make MCP tool calls.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Sanctum.Session

  def on_mount(:maybe_shell, _params, session, socket) do
    if session["shell"] do
      socket =
        socket
        |> assign(:shell_mode, true)
        |> maybe_assign_context(session)

      if connected?(socket) do
        send(self(), :shell_init)
      end

      {:cont, socket, layout: {PrismWeb.Layouts, :embedded}}
    else
      {:cont, assign(socket, :shell_mode, false)}
    end
  end

  defp maybe_assign_context(socket, session) do
    # Skip if context is already assigned (e.g. by LiveAuth)
    if socket.assigns[:context] do
      socket
    else
      case session["session_token"] && Session.load(session["session_token"], surface: :console) do
        {:ok, ctx} ->
          socket
          |> assign(:context, ctx)
          |> assign(:current_user, ctx)
          |> assign(:session_token, session["session_token"])

        _ ->
          socket
      end
    end
  end
end
