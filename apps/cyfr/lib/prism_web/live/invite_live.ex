# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.InviteLive do
  @moduledoc """
  `/invite`: the page an invitation link opens
  (`<CYFR address>/invite#<code>`). It names who invited the newcomer and
  to which athanor, and makes their identity here.

  It is sessionless. The code travels in the address's fragment, which no
  server log records; the page's script hands it over
  (`system_layer/index.js`, the `SystemLayer` hook in its `invite` mode),
  and the page reads the invitation (`Sanctum.Invitations.lookup/1`)
  before any ceremony starts. A code that admits no one, expired, used,
  revoked or issued by someone who has since lost the standing to invite,
  is one answer, `Prima.Refusal`'s `invitation_invalid` sentence, and no
  passkey is created.

  Otherwise the newcomer meets the two screens (`PrismWeb.AdmissionCard`),
  the name field filled with the name the invitation carries, if any, and
  checked against cyfr.run under the code the page holds. The passkey
  (`Sanctum.Passkeys.newcomer_options/0`) whose registration, with the
  name and the recovery secret and request id the browser drew, is the
  invitation admission's credential (`Sanctum.Newcomer.admit/2` with
  `{:invitation, code}`) makes the person, their keys, their athanor, the
  passkey, the seat the invitation names and their enrollment in one
  transaction with the code's redemption. A cancelled ceremony sends
  nothing. Then screen 2 registers them at cyfr.run, shows their
  recovery code, and "I saved it" signs them in, landing as any sign-in
  does.

  Its controls carry `data-test` names: `invite-from`, `invite-athanor`,
  `invite-expires` and `invite-refused`; the screens carry their own.
  """

  use PrismWeb, :live_view

  alias PrismWeb.AdmissionCard

  # Passkey ceremonies begun per address, as the setup and sign-in pages
  # bound their own: the page is reached over the LiveView socket, which
  # passes no rate-limit plug.
  @starts 30
  @window_ms 60_000

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
     |> AdmissionCard.mount(), layout: false}
  end

  # The invitation read: who invited, to which athanor, and the name the
  # inviter typed, which fills the field and is checked at once.
  @impl true
  def handle_event("invite_token", %{"token" => code}, %{assigns: %{step: :reading}} = socket)
      when is_binary(code) do
    case Sanctum.Invitations.lookup(code) do
      {:ok, invitation} ->
        socket = assign(socket, step: :invited, code: code, invitation: invitation)

        case invitation[:name] do
          name when is_binary(name) -> {:noreply, AdmissionCard.check(socket, %{"name" => name})}
          _none -> {:noreply, socket}
        end

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("invite_token", _params, socket), do: {:noreply, socket}

  # The name is checked under the code the page holds.
  def handle_event("admission_check", params, %{assigns: %{step: :invited}} = socket),
    do: {:noreply, AdmissionCard.check(socket, params)}

  def handle_event("admission_check", _params, socket), do: {:noreply, socket}

  def handle_event("invite_start", _params, %{assigns: %{step: :invited, code: code}} = socket) do
    cond do
      not AdmissionCard.startable?(socket) ->
        {:reply, %{error: true}, socket}

      not Arca.ControlPlane.held?() ->
        {:reply, %{error: @not_owner}, assign(socket, :admission_error, @not_owner)}

      Prima.RateLimiter.check({:invite_passkey, socket.assigns.client_ip}, @starts, @window_ms) !=
          :ok ->
        message = "Too many passkey ceremonies from here. Try again in a minute."
        {:reply, %{error: message}, assign(socket, :admission_error, message)}

      true ->
        with {:ok, _invitation} <- Sanctum.Invitations.lookup(code),
             {:ok, %{public_key: public_key, registration: registration}} <-
               Sanctum.Passkeys.newcomer_options() do
          {:reply, %{public_key: public_key, registration: registration},
           assign(socket, :admission_error, nil)}
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
    with {:ok, identity} <- AdmissionCard.identity(socket, params),
         {:ok, admitted} <-
           Sanctum.Newcomer.admit({:invitation, code}, {:passkey, credential, identity}) do
      {:noreply, socket |> assign(:step, :admitted) |> AdmissionCard.admitted(admitted)}
    else
      {:error, reason} -> {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("invite_passkey", _params, socket), do: {:noreply, socket}

  def handle_event("invite_error", _params, %{assigns: %{step: :invited}} = socket),
    do: {:noreply, assign(socket, :admission_error, AdmissionCard.ceremony_failed())}

  def handle_event("invite_error", _params, socket), do: {:noreply, socket}

  # Screen 2's events, once the person is admitted.
  def handle_event("admission_" <> _ = event, params, %{assigns: %{step: :admitted}} = socket),
    do: {:noreply, AdmissionCard.event(event, params, socket)}

  def handle_event("admission_" <> _, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(message, socket) do
    case AdmissionCard.handle_info(message, socket) do
      :pass -> {:noreply, socket}
      handled -> handled
    end
  end

  defp refused(socket, :invitation_invalid),
    do: assign(socket, step: :refused, admission_error: nil, invitation: nil)

  defp refused(socket, reason),
    do: assign(socket, :admission_error, AdmissionCard.refusal(reason))

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
            :if={@step in [:reading, :invited, :admitted]}
            id="invite-passkey"
            phx-hook="SystemLayer"
            data-webauthn="invite"
            class="space-y-4"
          >
            <div :if={@step == :reading} class="space-y-2">
              <p class="text-sm text-gray-400">Reading the invitation.</p>
              <p
                :if={@admission_error}
                role="alert"
                data-test="admission-error"
                class="text-sm text-red-300"
              >
                {@admission_error}
              </p>
            </div>
            <AdmissionCard.name_screen
              :if={@step == :invited}
              name={@admission_name}
              check={@admission_check}
              error={@admission_error}
            >
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
                {if @invitation[:athanor], do: "on this CYFR.", else: "this CYFR."} This CYFR keeps your identity.
              </p>
              <p data-test="invite-expires" class="text-xs text-gray-500">
                The invitation can be used once, until {Calendar.strftime(
                  @invitation.expires_at,
                  "%-d %B %Y, %H:%M UTC"
                )}.
              </p>
            </AdmissionCard.name_screen>
            <AdmissionCard.code_screen
              :if={@step == :admitted}
              state={@admission_state}
              name={@admission_name}
              error={@admission_error}
            />
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
