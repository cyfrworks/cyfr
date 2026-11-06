# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.InviteLive do
  @moduledoc """
  `/invite`: the page an invitation link opens
  (`<CYFR address>/invite#<code>`). It names who invited the newcomer and
  to which shared thread, by its title, when the invitation names one.

  It is sessionless. The code travels in the address's fragment, which no
  server log records; the page's script hands it over
  (`system_layer/index.js`, the `SystemLayer` hook with
  `data-account="invite"`), and the page reads the invitation
  (`Sanctum.Invitations.lookup/1`) before it offers anything. A code that
  admits no one, expired, used, revoked or issued by someone who has since
  lost the standing to invite, is one answer, `Prima.Refusal`'s
  `invitation_invalid` sentence.

  Otherwise the newcomer signs in with their account, or creates it, the
  new page offered the name the invitation carries: this CYFR mints a
  sign-in request bound to this browser and holding the code's hash, never
  the code (`Sanctum.SignIn.request/3`), and the page sends the browser to
  the account pages with it. The answer comes back to the sign-in page
  (`PrismWeb.LoginLive`), which redeems the invitation for the account by
  its identifier (`Sanctum.Invitations`), admitting a new person under it
  (`Sanctum.Newcomer`), and signs them in.

  Its controls carry `data-test` names: `invite-from`, `invite-thread`,
  `invite-expires`, `invite-sign-in`, `invite-create`, `invite-error` and
  `invite-refused`.
  """

  use PrismWeb, :live_view

  # Requests minted per address, as the setup and sign-in pages bound their
  # own: the page is reached over the LiveView socket, which passes no
  # rate-limit plug.
  @starts 30
  @window_ms 60_000

  @not_owner "This server is not accepting sign-ins right now. Try again in a moment."
  @rate_limited "Too many sign-ins from here. Try again in a minute."

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "You are invited to CYFR")
     |> assign(:browser_binding, session["_csrf_token"])
     |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
     |> assign(:step, :reading)
     |> assign(:hash, nil)
     |> assign(:invitation, nil)
     |> assign(:error, nil), layout: false}
  end

  # The invitation read: who invited, to which thread, and the name the
  # inviter offered. Only its hash is kept.
  @impl true
  def handle_event("account_token", %{"token" => code}, %{assigns: %{step: :reading}} = socket)
      when is_binary(code) do
    with {:ok, invitation} <- Sanctum.Invitations.lookup(code),
         {:ok, hash} <- Sanctum.Invitations.code_hash(code) do
      {:noreply, assign(socket, step: :invited, hash: hash, invitation: invitation)}
    else
      {:error, :invitation_invalid} -> {:noreply, assign(socket, :step, :refused)}
      {:error, reason} -> {:noreply, assign(socket, :error, PrismWeb.Ops.error_message(reason))}
    end
  end

  def handle_event("account_token", _params, socket), do: {:noreply, socket}

  def handle_event("sign_in", _params, socket), do: {:noreply, hop(socket, :sign)}

  def handle_event("create", _params, socket),
    do: {:noreply, hop(socket, {:new, socket.assigns.invitation[:name]})}

  # The sign-in request holding the invitation's hash, and the browser
  # sent to the account pages with it.
  defp hop(%{assigns: %{step: :invited, hash: hash}} = socket, page) do
    cond do
      not Arca.ControlPlane.held?() ->
        assign(socket, :error, @not_owner)

      Prima.RateLimiter.check({:sign_in, socket.assigns.client_ip}, @starts, @window_ms) != :ok ->
        assign(socket, :error, @rate_limited)

      true ->
        case Sanctum.SignIn.request(:sign_in, {:browser, socket.assigns.browser_binding},
               admission: {:invitation, hash},
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
    assigns = assign(assigns, :refusal, Prima.Refusal.message(:invitation_invalid))

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
          <h1 class="text-2xl font-bold tracking-tight text-indigo-200">
            You are invited to CYFR
          </h1>
        </div>

        <div
          id="invite-account"
          phx-hook="SystemLayer"
          data-account="invite"
          class="bg-gray-900 rounded-lg shadow-xl p-6 space-y-4"
        >
          <p :if={@step == :reading} class="text-sm text-gray-400">Reading the invitation.</p>
          <p :if={@error} role="alert" data-test="invite-error" class="text-sm text-red-300">
            {@error}
          </p>

          <div :if={@step == :invited} class="space-y-4">
            <p class="text-sm text-gray-300 leading-relaxed">
              <span data-test="invite-from" class="font-medium text-gray-100">
                {@invitation.inviter}
              </span>
              invited you to
              <span
                :if={@invitation[:thread]}
                data-test="invite-thread"
                class="font-medium text-gray-100"
              >
                {@invitation.thread}
              </span>
              {if @invitation[:thread], do: "on this CYFR.", else: "this CYFR."}
            </p>
            <p data-test="invite-expires" class="text-xs text-gray-500">
              The invitation can be used once, until {Calendar.strftime(
                @invitation.expires_at,
                "%-d %B %Y, %H:%M UTC"
              )}.
            </p>
            <button
              type="button"
              phx-click="sign_in"
              data-test="invite-sign-in"
              class="w-full px-4 py-3 bg-indigo-700 hover:bg-indigo-600 text-white rounded-lg transition-colors cursor-pointer"
            >
              Sign in with your account
            </button>
            <button
              type="button"
              phx-click="create"
              data-test="invite-create"
              class="w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
            >
              Create your account
            </button>
          </div>

          <div :if={@step == :refused} data-test="invite-refused" class="space-y-4">
            <p class="text-sm text-gray-300">{@refusal}</p>
            <.link
              navigate={~p"/login"}
              class="block w-full text-center px-4 py-3 text-sm text-gray-300 hover:text-white border border-gray-700 rounded-lg"
            >
              Sign in
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
