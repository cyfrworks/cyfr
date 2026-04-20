defmodule PrismWeb.LiveAdmin do
  @moduledoc """
  LiveView on_mount hook that gates `/admin` routes on the caller's context
  carrying the `:admin` permission (or the `:*` wildcard).

  Runs AFTER `PrismWeb.LiveAuth.:require_auth` (for `current_user`) and
  `PrismWeb.LiveClaimGate.:require_claim` (for personal-namespace claim).
  The chain is deliberate: admins are still users, so they must have a
  personal namespace before they can admin. If they don't, they go through
  the claim gate like everyone else.

  A non-admin user reaching `/admin` is redirected to the dashboard rather
  than the login page — they're authenticated, just not authorized.
  """

  import Phoenix.LiveView

  def on_mount(:require_admin, _params, _session, socket) do
    case build_ctx(socket.assigns[:current_user]) do
      {:ok, ctx} ->
        if has_admin?(ctx) do
          {:cont, socket}
        else
          {:halt, redirect(socket, to: "/")}
        end

      :none ->
        # LiveAuth should have redirected already; defensive fallback.
        {:halt, redirect(socket, to: "/login")}
    end
  end

  defp build_ctx(%{id: id, permissions: perms}) when is_binary(id) and id != "" do
    {:ok, Sanctum.Context.build(user_id: id, permissions: perms || [])}
  end

  defp build_ctx(_), do: :none

  defp has_admin?(ctx) do
    Sanctum.Context.has_permission?(ctx, :admin) or
      Sanctum.Context.has_permission?(ctx, :*)
  end
end
