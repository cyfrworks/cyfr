# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SetupLive do
  @moduledoc """
  `/setup`: the page the setup link opens (`<CYFR address>/setup#<token>`,
  which `cyfr init` prints and `cyfr setup`'s done screen opens). It sets
  the CYFR up by admitting its first person, who administers it.

  It is sessionless. The token travels in the address's fragment, which
  no server log records; the page's script hands it over
  (`system_layer/index.js`, the `SystemLayer` hook with
  `data-account="setup"`), and the page asks whether it opens setup
  (`Sanctum.Newcomer.setup_open/1`) before it offers anything. A token
  that is not this CYFR's, or a CYFR set up already, is one answer: the
  page goes to `/`, so the setup link can always be opened, whoever opens
  it. A browser that already holds a session that stands goes into CYFR.

  Otherwise the person signs in with their account, or creates it: this
  CYFR mints a sign-in request bound to this browser and holding the
  setup token (`Sanctum.SignIn.request/3`), and the page sends the
  browser to the account pages with it, the sign page or the new page.
  The answer comes back to the sign-in page (`PrismWeb.LoginLive`), which
  admits the account under the token (`Sanctum.Newcomer`) and signs them
  in.

  Its controls carry `data-test` names: `setup-sign-in`, `setup-create`
  and `setup-error`.
  """

  use PrismWeb, :live_view

  # Requests minted per address, as the sign-in page bounds its own: the
  # page is reached over the LiveView socket, which passes no rate-limit
  # plug.
  @starts 30
  @window_ms 60_000

  @not_owner "This server is not accepting sign-ins right now. Try again in a moment."
  @rate_limited "Too many sign-ins from here. Try again in a minute."

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Set up CYFR")
      |> assign(:browser_binding, session["_csrf_token"])
      |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
      |> assign(:step, :reading)
      |> assign(:token, nil)
      |> assign(:error, nil)

    {:ok, signed_in(socket, params, session), layout: false}
  end

  # A browser that holds a session that stands is guarded as every console
  # page is and goes into CYFR; a session that no longer stands leaves the
  # sessionless step, so a stale cookie never keeps a person from setting
  # up.
  defp signed_in(socket, params, session) do
    case session[to_string(CyfrWeb.ContextGuard.session_key())] do
      token when is_binary(token) and token != "" ->
        case CyfrWeb.ContextGuard.on_mount(:protected, params, session, socket) do
          {:cont, guarded} -> redirect(guarded, to: ~p"/")
          {:halt, _refused} -> socket
        end

      _none ->
        socket
    end
  end

  @impl true
  def handle_event("account_token", %{"token" => token}, %{assigns: %{step: :reading}} = socket)
      when is_binary(token) do
    case Sanctum.Newcomer.setup_open(token) do
      :ok -> {:noreply, assign(socket, step: :open, token: token, error: nil)}
      {:error, :setup_closed} -> {:noreply, redirect(socket, to: ~p"/")}
      {:error, reason} -> {:noreply, assign(socket, :error, PrismWeb.Ops.error_message(reason))}
    end
  end

  def handle_event("account_token", _params, socket), do: {:noreply, socket}

  def handle_event("sign_in", _params, socket), do: {:noreply, hop(socket, :sign)}
  def handle_event("create", _params, socket), do: {:noreply, hop(socket, {:new, nil})}

  # The sign-in request under the setup token, and the browser sent to the
  # account pages with it.
  defp hop(%{assigns: %{step: :open, token: token}} = socket, page) do
    cond do
      not Arca.ControlPlane.held?() ->
        assign(socket, :error, @not_owner)

      Prima.RateLimiter.check({:sign_in, socket.assigns.client_ip}, @starts, @window_ms) != :ok ->
        assign(socket, :error, @rate_limited)

      true ->
        case Sanctum.SignIn.request(:sign_in, {:browser, socket.assigns.browser_binding},
               admission: {:setup, token},
               page: page
             ) do
          {:ok, %{url: url}} -> push_event(socket, "account:hop", %{url: url})
          {:error, reason} -> assign(socket, :error, PrismWeb.Ops.error_message(reason))
        end
    end
  end

  defp hop(socket, _page), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <div class="min-h-screen flex items-center justify-center bg-gray-950 px-4 py-8">
      <div class="max-w-md w-full space-y-6">
        <div class="text-center space-y-3">
          <img
            src={~p"/images/logo.jpg"}
            alt="AQUA"
            class="h-14 w-14 rounded-full mx-auto ring-2 ring-indigo-400/30"
          />
          <h1 class="text-2xl font-bold tracking-tight text-indigo-200">Set up CYFR</h1>
        </div>

        <div
          id="setup-account"
          phx-hook="SystemLayer"
          data-account="setup"
          class="bg-gray-900 rounded-lg shadow-xl p-6 space-y-4"
        >
          <p :if={@step == :reading} class="text-sm text-gray-400">Reading the setup link.</p>
          <p :if={@error} role="alert" data-test="setup-error" class="text-sm text-red-300">
            {@error}
          </p>
          <div :if={@step == :open} class="space-y-4">
            <p class="text-sm text-gray-300 leading-relaxed">
              You are the first person on this CYFR, and you run it.
            </p>
            <button
              type="button"
              phx-click="sign_in"
              data-test="setup-sign-in"
              class="w-full px-4 py-3 bg-indigo-700 hover:bg-indigo-600 text-white rounded-lg transition-colors cursor-pointer"
            >
              Sign in with your account
            </button>
            <button
              type="button"
              phx-click="create"
              data-test="setup-create"
              class="w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
            >
              Create your account
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
