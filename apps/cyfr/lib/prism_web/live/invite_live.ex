# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.InviteLive do
  @moduledoc """
  `/invite`: the page an invitation link opens
  (`<CYFR address>/invite#<code>`). It names who invited the newcomer and
  to which athanor, and offers one thing: creating their identity here.

  It is sessionless. The code travels in the address's fragment, which no
  server log records; the page's script hands it over
  (`system_layer/index.js`, the `SystemLayer` hook in its `invite` mode),
  and the page reads the invitation (`Sanctum.Invitations.lookup/1`)
  before any ceremony starts. A code that admits no one, expired, used,
  revoked or issued by someone who has since lost the standing to invite,
  is one answer, `Prima.Refusal`'s `invitation_invalid` sentence, and no
  passkey is created. Otherwise "Create your identity here" asks for a
  passkey (`Sanctum.Passkeys.newcomer_options/0`); the registration is the
  invitation admission's credential (`Sanctum.Newcomer.admit/2` with
  `{:invitation, code}`), which makes the person, their keys, their
  athanor, the passkey and the seat the invitation names in one
  transaction with the code's redemption. A cancelled ceremony sends
  nothing. The admitted person's session reaches the browser's cookie
  through the passkey sign-in's one-time ticket
  (`PrismWeb.PasskeyController`), and they land as any sign-in does.

  Its controls carry `data-test` names: `invite-passkey` (the passkey
  step), `invite-from`, `invite-athanor`, `invite-expires`,
  `invite-create`, `invite-refused` and `invite-error`.
  """

  use PrismWeb, :live_view

  # Passkey ceremonies begun per address, as the setup and sign-in pages
  # bound their own: the page is reached over the LiveView socket, which
  # passes no rate-limit plug.
  @starts 30
  @window_ms 60_000
  @ticket_ttl_ms 60_000

  @not_owner "This server is not accepting sign-ins right now. Try again in a moment."

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "You are invited to CYFR")
     |> assign(:browser_binding, session["_csrf_token"])
     |> assign(:client_ip, PrismWeb.AuthHelpers.socket_client_ip(socket))
     |> assign(:step, :reading)
     |> assign(:code, nil)
     |> assign(:invitation, nil)
     |> assign(:error, nil), layout: false}
  end

  @impl true
  def handle_event("invite_token", %{"token" => code}, %{assigns: %{step: :reading}} = socket)
      when is_binary(code) do
    case Sanctum.Invitations.lookup(code) do
      {:ok, invitation} ->
        {:noreply, assign(socket, step: :invited, code: code, invitation: invitation)}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("invite_token", _params, socket), do: {:noreply, socket}

  def handle_event("invite_start", _params, %{assigns: %{step: :invited, code: code}} = socket) do
    cond do
      not Arca.ControlPlane.held?() ->
        {:reply, %{error: @not_owner}, assign(socket, :error, @not_owner)}

      Prima.RateLimiter.check({:invite_passkey, socket.assigns.client_ip}, @starts, @window_ms) !=
          :ok ->
        message = "Too many passkey ceremonies from here. Try again in a minute."
        {:reply, %{error: message}, assign(socket, :error, message)}

      true ->
        with {:ok, _invitation} <- Sanctum.Invitations.lookup(code),
             {:ok, %{public_key: public_key, registration: registration}} <-
               Sanctum.Passkeys.newcomer_options() do
          {:reply, %{public_key: public_key, registration: registration},
           assign(socket, :error, nil)}
        else
          {:error, reason} -> {:reply, %{error: true}, refused(socket, reason)}
        end
    end
  end

  def handle_event("invite_start", _params, socket), do: {:reply, %{error: true}, socket}

  def handle_event(
        "invite_passkey",
        %{"credential" => credential} = params,
        %{assigns: %{step: :invited, code: code}} = socket
      )
      when is_map(credential) do
    with {:ok, identity} <- Sanctum.Newcomer.identity(params),
         {:ok, %{session_token: session_token}} <-
           Sanctum.Newcomer.admit({:invitation, code}, {:passkey, credential, identity}) do
      ticket = mint_ticket(session_token, socket.assigns.browser_binding)
      {:noreply, redirect(socket, to: ~p"/auth/passkey/complete/#{ticket}")}
    else
      {:error, reason} -> {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("invite_passkey", _params, socket), do: {:noreply, socket}

  def handle_event("invite_error", _params, socket) do
    {:noreply,
     assign(socket, :error, "The passkey was not created, so nothing was saved. Try again.")}
  end

  defp refused(socket, :invitation_invalid),
    do: assign(socket, step: :refused, error: nil, invitation: nil)

  defp refused(socket, :registration_refused),
    do: assign(socket, :error, "That passkey could not be registered here. Try again.")

  defp refused(socket, reason), do: assign(socket, :error, PrismWeb.Ops.error_message(reason))

  # The passkey sign-in's ticket, bound to this browser. It names no path,
  # so the newcomer lands as any sign-in does.
  defp mint_ticket(session_token, browser_binding) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:login_passkey_ticket, ticket},
      %{session_token: session_token, browser_binding: browser_binding},
      @ticket_ttl_ms
    )

    ticket
  end

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

        <div class="bg-gray-900 rounded-lg shadow-xl p-6 space-y-4">
          <div
            :if={@error}
            role="alert"
            data-test="invite-error"
            class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
          >
            {@error}
          </div>

          <div
            :if={@step in [:reading, :invited]}
            id="invite-passkey"
            phx-hook="SystemLayer"
            data-webauthn="invite"
            data-test="invite-passkey"
            class="space-y-4"
          >
            <p :if={@step == :reading} class="text-sm text-gray-400">Reading the invitation.</p>
            <div :if={@step == :invited} class="space-y-4">
              <p class="text-sm text-gray-300 leading-relaxed">
                <span data-test="invite-from" class="font-medium text-gray-100">
                  {@invitation.inviter}
                </span>
                invited you to
                <span
                  :if={@invitation[:athanor]}
                  data-test="invite-athanor"
                  class="font-medium text-gray-100"
                >
                  {@invitation.athanor}
                </span>
                {if @invitation[:athanor], do: "on this CYFR.", else: "this CYFR."}
              </p>
              <p class="text-sm text-gray-400 leading-relaxed">
                This CYFR keeps your identity, and a passkey on this device signs you in, with no
                network needed.
              </p>
              <p data-test="invite-expires" class="text-xs text-gray-500">
                The invitation can be used once, until {Calendar.strftime(
                  @invitation.expires_at,
                  "%-d %B %Y, %H:%M UTC"
                )}.
              </p>
              <button
                type="button"
                data-webauthn-start
                data-test="invite-create"
                class="w-full px-4 py-3 bg-indigo-700 hover:bg-indigo-600 text-white rounded-lg transition-colors cursor-pointer"
              >
                Create your identity here
              </button>
            </div>
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
