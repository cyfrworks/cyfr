defmodule PrismWeb.LiveAuth do
  @moduledoc """
  LiveView on_mount hook for authentication.

  Validates the session token from the cookie, builds a
  `Sanctum.Context`, and stores it in socket assigns.
  Redirects to /login if unauthenticated.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  require Logger

  alias Sanctum.Session
  alias Sanctum.Context

  def on_mount(:require_auth, _params, session, socket) do
    token = session["session_token"]

    case token && Session.get_user(token) do
      {:ok, user} ->
        user = maybe_resolve_membership(user)

        context =
          Context.build(
            user_id: user.id,
            org_id: user.org_id,
            project_id: user.project_id,
            permissions: user.permissions,
            scope: :project,
            auth_method: :oidc,
            authenticated: true
          )

        if arx_mode?() and (is_nil(context.org_id) or context.org_id == "") do
          {:halt, redirect(socket, to: "/login?error=no_org")}
        else
          Cyfr.LoggerContext.set_from_context(context)

          {:cont,
           socket
           |> assign(:current_user, user)
           |> assign(:context, context)
           |> assign(:session_token, token)}
        end

      _ ->
        {:halt, redirect(socket, to: "/login")}
    end
  end

  # In Arx mode, if a session's user has no org_id, try to re-resolve membership.
  # This handles stale sessions created before membership was assigned.
  defp maybe_resolve_membership(user) do
    if arx_mode?() and (is_nil(user.org_id) or user.org_id == "") do
      case SanctumArx.Memberships.list_by_user(user.id) do
        memberships when is_list(memberships) and memberships != [] ->
          membership =
            Enum.find(memberships, List.first(memberships), fn m ->
              m.accepted_at != nil
            end)

          %{user | org_id: membership.org_id, project_id: user.project_id || "default"}

        [] ->
          user

        {:error, reason} ->
          Logger.error(
            "[LiveAuth] Failed to resolve membership for user #{user.id}: #{inspect(reason)}"
          )

          user
      end
    else
      user
    end
  end

  defp arx_mode?, do: Application.get_env(:cyfr, :edition, :core) == :arx
end
