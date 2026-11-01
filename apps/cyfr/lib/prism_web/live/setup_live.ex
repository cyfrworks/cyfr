# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SetupLive do
  @moduledoc """
  `/setup`: the page the setup link opens (`<CYFR address>/setup#<token>`,
  which `cyfr init` prints and `cyfr setup`'s done screen opens). It sets
  the CYFR up by creating its first person, who administers it.

  It is sessionless. The token travels in the address's fragment, which
  no server log records; the page's script hands it over
  (`system_layer/index.js`, the `SystemLayer` hook in its `setup` mode),
  and the page asks whether it opens setup (`Sanctum.Newcomer.setup_open/1`)
  before any ceremony starts. A token that is not this CYFR's, or a CYFR
  set up already, is one answer: the page goes to `/`, so the setup link
  can always be opened, whoever opens it. A browser that already holds a
  session that stands goes into CYFR.

  Otherwise the person meets the two screens (`PrismWeb.AdmissionCard`):
  their name, checked against cyfr.run under the token the page holds,
  and a passkey (`Sanctum.Passkeys.newcomer_options/0`) whose
  registration, with the name and the recovery secret and request id
  the browser drew, is the setup admission's credential
  (`Sanctum.Newcomer.admit/2` with `{:setup, token}`), which makes the
  person, their keys, their athanor, the passkey, the platform grant and
  their enrollment in one transaction. A cancelled ceremony sends
  nothing. Then screen 2 registers them at cyfr.run, shows their
  recovery code, and "I saved it" signs them in.

  The screens carry their own `data-test` names.
  """

  use PrismWeb, :live_view

  alias PrismWeb.AdmissionCard

  # Passkey ceremonies begun per address, as the sign-in page bounds its
  # own: the page is reached over the LiveView socket, which passes no
  # rate-limit plug.
  @starts 30
  @window_ms 60_000

  @not_owner "This server is not accepting sign-ins right now. Try again in a moment."

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
      |> AdmissionCard.mount()

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
  def handle_event("setup_token", %{"token" => token}, %{assigns: %{step: :reading}} = socket)
      when is_binary(token) do
    case Sanctum.Newcomer.setup_open(token) do
      :ok -> {:noreply, assign(socket, step: :passkey, token: token, error: nil)}
      {:error, :setup_closed} -> {:noreply, redirect(socket, to: ~p"/")}
      {:error, reason} -> {:noreply, assign(socket, :error, PrismWeb.Ops.error_message(reason))}
    end
  end

  def handle_event("setup_token", _params, socket), do: {:noreply, socket}

  # The name is checked under the token the page holds.
  def handle_event("admission_check", params, %{assigns: %{step: :passkey}} = socket),
    do: {:noreply, AdmissionCard.check(socket, params)}

  def handle_event("admission_check", _params, socket), do: {:noreply, socket}

  def handle_event("setup_start", _params, %{assigns: %{step: :passkey, token: token}} = socket) do
    cond do
      not AdmissionCard.startable?(socket) ->
        {:reply, %{error: true}, socket}

      not Arca.ControlPlane.held?() ->
        {:reply, %{error: @not_owner}, assign(socket, :admission_error, @not_owner)}

      Prima.RateLimiter.check({:setup_passkey, socket.assigns.client_ip}, @starts, @window_ms) !=
          :ok ->
        message = "Too many passkey ceremonies from here. Try again in a minute."
        {:reply, %{error: message}, assign(socket, :admission_error, message)}

      true ->
        with :ok <- Sanctum.Newcomer.setup_open(token),
             {:ok, %{public_key: public_key, registration: registration}} <-
               Sanctum.Passkeys.newcomer_options() do
          {:reply, %{public_key: public_key, registration: registration},
           assign(socket, :admission_error, nil)}
        else
          {:error, reason} -> {:reply, %{error: true}, refused(socket, reason)}
        end
    end
  end

  def handle_event("setup_start", _params, socket), do: {:reply, %{error: true}, socket}

  def handle_event(
        "setup_passkey",
        %{"credential" => credential} = params,
        %{assigns: %{step: :passkey, token: token}} = socket
      )
      when is_map(credential) do
    with {:ok, identity} <- AdmissionCard.identity(socket, params),
         {:ok, admitted} <-
           Sanctum.Newcomer.admit({:setup, token}, {:passkey, credential, identity}) do
      {:noreply, socket |> assign(:step, :admitted) |> AdmissionCard.admitted(admitted)}
    else
      {:error, reason} -> {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("setup_passkey", _params, socket), do: {:noreply, socket}

  def handle_event("setup_error", _params, %{assigns: %{step: :passkey}} = socket),
    do: {:noreply, assign(socket, :admission_error, AdmissionCard.ceremony_failed())}

  def handle_event("setup_error", _params, socket), do: {:noreply, socket}

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

  defp refused(socket, :setup_closed), do: redirect(socket, to: ~p"/")

  defp refused(socket, reason),
    do: assign(socket, :admission_error, AdmissionCard.refusal(reason))

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

        <div class="bg-gray-900 rounded-lg shadow-xl p-6 space-y-4">
          <div
            :if={@step in [:reading, :passkey, :admitted]}
            id="setup-passkey"
            phx-hook="SystemLayer"
            data-webauthn="setup"
            class="space-y-4"
          >
            <div :if={@step == :reading} class="space-y-2">
              <p class="text-sm text-gray-400">Reading the setup link.</p>
              <p :if={@error} role="alert" data-test="admission-error" class="text-sm text-red-300">
                {@error}
              </p>
            </div>
            <AdmissionCard.name_screen
              :if={@step == :passkey}
              name={@admission_name}
              check={@admission_check}
              error={@admission_error}
            >
              <p class="text-sm text-gray-300 leading-relaxed">
                You are the first person on this CYFR, and you run it.
              </p>
            </AdmissionCard.name_screen>
            <AdmissionCard.code_screen
              :if={@step == :admitted}
              state={@admission_state}
              name={@admission_name}
              error={@admission_error}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
