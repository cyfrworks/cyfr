defmodule PrismWeb.Plugs.OptionalAuth do
  @moduledoc """
  Like `RequireAuth`, but does not halt when authentication fails.

  Sets `conn.assigns.context` and `conn.assigns.current_user` when a
  valid session is present; leaves them unset otherwise.
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

      {:error, _} ->
        conn
    end
  end
end
