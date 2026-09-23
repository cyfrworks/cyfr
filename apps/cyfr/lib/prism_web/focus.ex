# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Focus do
  @moduledoc """
  LiveView on_mount hook that puts the URL's athanor in focus.

  `/a/<athanor>/…` names the athanor a page works in — `@<namespace>` for
  a person's, the slug for a group's. The hook resolves the segment,
  narrows the authenticated context to it (`Sanctum.Context.focus/2`: a
  member may, a platform admin may with an audit record, nobody else may)
  and assigns `:athanor` and `:athanor_route`. Two tabs can be two athanors;
  the session's default athanor only decides where `/` lands.

  A mount without an `:athanor` param (the root redirect) passes through
  with the session's athanor in focus.

  It runs after `CyfrWeb.ContextGuard`, which established the caller; a
  narrowed context goes back through the guard (`refocus/2`), so what
  the page holds is the context the guard keeps current. It also assigns
  what the layout reads of the person: their publisher namespace and
  their lite/dev preference.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  def on_mount(:assign, %{"athanor" => segment}, _session, socket) do
    socket = person_assigns(socket)
    ctx = socket.assigns.context

    # `by_route_slug/1` names active athanors only, so an archived one is a
    # 404 here — `Context.focus/2` never sees it.
    with {:ok, athanor} <- Athanors.by_route_slug(segment),
         {:ok, focused} <- Context.focus(ctx, athanor),
         {:ok, refocused} <- CyfrWeb.ContextGuard.refocus(socket, focused) do
      {:cont, focus_assigns(refocused, athanor)}
    else
      {:error, :not_found} ->
        {:halt,
         socket
         |> put_flash(:error, "There is no estate at #{segment}.")
         |> redirect(to: "/")}

      {:error, :unavailable} ->
        {:halt, redirect(socket, to: "/login?error=unavailable")}

      {:error, reason} when reason in [:unauthenticated, :not_standing] ->
        {:halt, redirect(socket, to: "/login")}

      {:error, _not_member} ->
        {:halt,
         socket
         |> put_flash(:error, "You are not a member of that estate.")
         |> redirect(to: "/")}
    end
  end

  def on_mount(:assign, _params, _session, socket) do
    socket = person_assigns(socket)
    ctx = socket.assigns.context

    case ctx.athanor_id && Athanors.get(ctx.athanor_id) do
      {:ok, %{status: "active"} = athanor} ->
        {:cont, focus_assigns(socket, athanor)}

      _ ->
        {:cont, socket |> assign(:athanor, nil) |> assign(:athanor_route, nil)}
    end
  end

  defp focus_assigns(socket, athanor) do
    socket
    |> assign(:athanor, athanor)
    |> assign(:athanor_route, Athanors.route_slug(athanor))
  end

  # What the layout reads of the person: the publisher namespace, and the
  # lite/dev preference that decides which views it offers and what it
  # calls them (`Prism.Labels`).
  defp person_assigns(socket) do
    ctx = socket.assigns.context

    socket
    |> assign(:personal_namespace_slug, ctx.namespace)
    |> assign(:ui_mode, ui_mode(ctx))
  end

  defp ui_mode(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, user} -> Prism.Labels.mode(Sanctum.Tenancy.Users.prefs(user)["mode"], ctx)
      _ -> Prism.Labels.default(ctx)
    end
  end

  defp ui_mode(ctx), do: Prism.Labels.default(ctx)

  @doc "The route segment of the athanor a context works in, or nil."
  @spec route_of(Context.t()) :: String.t() | nil
  def route_of(%Context{athanor_id: id}) when is_binary(id) do
    case Athanors.get(id) do
      {:ok, athanor} -> Athanors.route_slug(athanor)
      _ -> nil
    end
  end

  def route_of(_), do: nil

  @doc "The page path for an athanor: `/a/<route>` + `suffix`."
  @spec path(Arca.Schemas.Athanor.t() | String.t(), String.t()) :: String.t()
  def path(%{} = athanor, suffix), do: path(Athanors.route_slug(athanor), suffix)
  def path(route, suffix) when is_binary(route), do: "/a/" <> route <> suffix
  # A page rendered before focus (no athanor yet) links to the root, which
  # re-derives the default.
  def path(nil, _suffix), do: "/"
end
