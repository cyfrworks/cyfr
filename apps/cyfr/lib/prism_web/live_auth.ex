# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveAuth do
  @moduledoc """
  LiveView on_mount hook for authentication.

  Loads the session token from the cookie session (the one this origin
  has, written by the auth callback), authenticates it via Sanctum, and
  assigns `:current_user` (a Context) to the socket. Redirects to /login
  if unauthenticated and to the claim gate if the person has no namespace
  yet.

  A mounted socket also lets go when the person's standing changes: their
  sessions are revoked (server-denied, or a platform admin ejected them),
  or they lose the athanor they are working in. Both arrive as PubSub
  messages and are handled by hooks attached here, so no LiveView has to
  remember to.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:require_auth, _params, session, socket) do
    token = session["sanctum_session_token"]

    case PrismWeb.AuthHelpers.authenticate_session(token) do
      # A valid session whose person has not claimed a namespace yet loads
      # unauthenticated: the claim gate comes first. The HTTP plug sends the
      # first GET there; the LiveView socket never passes the router, so the
      # connected mount is gated here.
      {:ok, %{authenticated: false, namespace: nil}} ->
        {:halt, redirect(socket, to: "/claim-namespace")}

      # A namespace but no standing: denied at the door since the session
      # was minted.
      {:ok, %{authenticated: false}} ->
        {:halt, redirect(socket, to: "/login")}

      {:ok, ctx} ->
        slug = ctx.namespace

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Session.topic())
          Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Tenancy.Members.topic(ctx.user_id))
        end

        {:cont,
         socket
         |> assign(:current_user, ctx)
         |> assign(:context, ctx)
         |> assign(:session_token, token)
         |> assign(:personal_namespace_slug, slug)
         |> assign(:ui_mode, ui_mode(ctx))
         |> attach_hook(:sanctum_standing, :handle_info, &standing_changed/2)}

      {:error, :no_athanor} ->
        {:halt, redirect(socket, to: "/login?error=no_athanor")}

      # A transient failure reading who the person is: say so, never bounce
      # them into a claim they have already made.
      {:error, :namespace_unavailable} ->
        {:halt, redirect(socket, to: "/login?error=unavailable")}

      {:error, :unauthenticated} ->
        {:halt, redirect(socket, to: "/login")}
    end
  end

  # The person's lite/dev preference decides which views the layout offers
  # and what it calls them (`Prism.Labels`).
  defp ui_mode(%{user_id: user_id} = ctx) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, user} -> Prism.Labels.mode(Sanctum.Tenancy.Users.prefs(user)["mode"], ctx)
      _ -> Prism.Labels.default(ctx)
    end
  end

  defp ui_mode(ctx), do: Prism.Labels.default(ctx)

  # Revoked sessions end the LiveView; a lost focus sends the person back to
  # the root, where the next mount re-derives what they may work in. The
  # standing messages are consumed here; everything else passes through.
  defp standing_changed({:sessions_revoked, user_id}, socket) do
    if socket.assigns.context.user_id == user_id do
      {:halt, redirect(socket, to: "/login")}
    else
      {:halt, socket}
    end
  end

  defp standing_changed({:membership_changed, %{athanor_id: athanor_id, change: :left}}, socket) do
    if socket.assigns.context.athanor_id == athanor_id do
      {:halt, redirect(socket, to: "/")}
    else
      {:halt, socket}
    end
  end

  defp standing_changed({:membership_changed, _}, socket), do: {:halt, socket}
  defp standing_changed({:session_created, _}, socket), do: {:halt, socket}
  defp standing_changed(_msg, socket), do: {:cont, socket}
end
