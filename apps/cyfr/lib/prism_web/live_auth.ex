# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LiveAuth do
  @moduledoc """
  LiveView on_mount hook for authentication.

  Loads the session token from the cookie session (the one this origin
  has, written by the auth callback), authenticates it via Sanctum, and
  assigns `:context` (a Context) to the socket. Redirects to /login
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
    token = session[to_string(PrismWeb.SignInResponse.session_key())]

    case PrismWeb.AuthHelpers.authenticate_session(token) do
      {:ok, ctx} ->
        slug = ctx.namespace

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Session.topic())
          Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Tenancy.Members.topic(ctx.user_id))
        end

        {:cont,
         socket
         |> assign(:context, ctx)
         |> assign(:personal_namespace_slug, slug)
         |> assign(:ui_mode, ui_mode(ctx))
         |> attach_hook(:sanctum_standing, :handle_info, &standing_changed/2)}

      # The decision table lives in AuthHelpers.disposition/1; this gate
      # renders each disposition as a redirect. The HTTP plug sends the
      # first GET to the claim gate; the LiveView socket never passes the
      # router, so the connected mount is gated here too.
      {:error, refusal} ->
        path =
          case PrismWeb.AuthHelpers.disposition(refusal) do
            :claim -> PrismWeb.AuthHelpers.claim_path()
            :sign_in -> PrismWeb.AuthHelpers.sign_in_path()
            :no_workspace -> PrismWeb.AuthHelpers.sign_in_path() <> "?error=no_athanor"
            :unavailable -> PrismWeb.AuthHelpers.sign_in_path() <> "?error=unavailable"
          end

        {:halt, redirect(socket, to: path)}
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

  # Any other membership change — joined a group, the operator bit granted —
  # re-derives the caller instead of trusting the Context assigned at mount
  # for the socket's lifetime.
  #
  # From the Context, not from the session token. Memberships, the operator
  # bit and whether the focused athanor is still granted are all `revalidate/1`
  # answers, and the two questions a token would additionally settle already
  # have their own clauses above: a revoked session arrives as
  # `:sessions_revoked`, a lost seat as `:left`. Keeping the raw token in
  # assigns for this one call put a live bearer credential in every page
  # socket's state, which `Phoenix.LiveView.Socket` prints in a crash report.
  defp standing_changed({:membership_changed, _}, socket) do
    case Sanctum.Tenancy.revalidate(socket.assigns.context) do
      %Sanctum.Context{authenticated: true, athanor_id: id} = ctx when is_binary(id) ->
        Cyfr.LoggerContext.set_from_context(ctx)
        {:halt, assign(socket, :context, ctx)}

      _ ->
        {:halt, redirect(socket, to: "/")}
    end
  end

  defp standing_changed({:session_created, _}, socket), do: {:halt, socket}
  defp standing_changed(_msg, socket), do: {:cont, socket}
end
