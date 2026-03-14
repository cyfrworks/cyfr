defmodule PrismWeb.LiveAuth do
  @moduledoc """
  LiveView on_mount hook for authentication.

  Validates the session token from the cookie, builds a
  `Sanctum.Context`, and stores it in socket assigns.
  Redirects to /login if unauthenticated.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Sanctum.Session
  alias Sanctum.Context

  def on_mount(:require_auth, _params, session, socket) do
    token = session["session_token"]

    case token && Session.get_user(token) do
      {:ok, user} ->
        context = Context.build(
          user_id: user.id,
          org_id: Map.get(user, :org_id),
          project_id: Map.get(user, :project_id),
          permissions: user.permissions,
          scope: :project,
          auth_method: :oidc,
          authenticated: true
        )

        {:cont,
         socket
         |> assign(:current_user, user)
         |> assign(:context, context)
         |> assign(:session_token, token)}

      _ ->
        {:halt, redirect(socket, to: "/login")}
    end
  end
end
