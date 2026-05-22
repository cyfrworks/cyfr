# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveAuth do
  @moduledoc """
  LiveView on_mount hook for authentication.

  Validates the session token from the cookie, builds a
  `Sanctum.Context`, and stores it in socket assigns.
  Redirects to /login if unauthenticated.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:require_auth, _params, session, socket) do
    token = session["session_token"]

    case PrismWeb.AuthHelpers.authenticate_session(token) do
      {:ok, ctx} ->
        slug = PrismWeb.AuthHelpers.personal_namespace_slug(ctx.user_id)

        {:cont,
         socket
         |> assign(:current_user, ctx)
         |> assign(:context, ctx)
         |> assign(:session_token, token)
         |> assign(:personal_namespace_slug, slug)}

      {:error, :no_org} ->
        {:halt, redirect(socket, to: "/login?error=no_org")}

      {:error, :unauthenticated} ->
        {:halt, redirect(socket, to: "/login")}
    end
  end
end