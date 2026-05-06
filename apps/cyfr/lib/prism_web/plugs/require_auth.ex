defmodule PrismWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug for authenticating controller routes.

  Reuses `PrismWeb.AuthHelpers` to validate session tokens and build
  a `Sanctum.Context`. Redirects to `/login` on failure.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    token = get_session(conn, :session_token) || get_session(conn, "session_token")

    case PrismWeb.AuthHelpers.authenticate_session(token) do
      {:ok, ctx} ->
        conn
        |> assign(:current_user, ctx)
        |> assign(:context, ctx)

      {:error, :no_org} ->
        conn
        |> Phoenix.Controller.redirect(to: "/login?error=no_org")
        |> halt()

      {:error, _reason} ->
        conn
        |> Phoenix.Controller.redirect(to: "/login")
        |> halt()
    end
  end
end
