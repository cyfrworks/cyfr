# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SetupLive do
  @moduledoc """
  `/setup`: the page the setup link opens (`<CYFR address>/setup#<token>`,
  which `cyfr init` prints and `cyfr setup`'s done screen opens). It sets
  the CYFR up by creating its first person, who administers it.

  Its first step is sessionless. The token travels in the address's
  fragment, which no server log records; the page's script hands it over
  (`system_layer/index.js`, the `SystemLayer` hook in its `setup` mode),
  and the page asks whether it opens setup (`Sanctum.Newcomer.setup_open/1`)
  before any ceremony starts. A token that is not this CYFR's, or a CYFR
  set up already, is one answer: the link is not valid or setup is
  complete, with the way to sign in. Otherwise the page asks the person to
  create a passkey (`Sanctum.Passkeys.newcomer_options/0`); the
  registration is the setup admission's credential
  (`Sanctum.Newcomer.admit/2` with `{:setup, token}`), which makes the
  person, their keys, their athanor, the passkey and the platform grant in
  one transaction. A cancelled ceremony sends nothing. The admitted
  person's session reaches the browser's cookie through the passkey
  sign-in's one-time ticket (`PrismWeb.PasskeyController`), which brings
  them back here.

  Signed in, the page guards their session as every console page does
  (`CyfrWeb.ContextGuard`) and offers a handle through the identity card
  (`PrismWeb.IdentityCard`): skipping goes into CYFR, and choosing one
  runs the enrollment ceremony and claims the handle once its kit is
  acknowledged. The person, the attempt and the wanted handle are on the
  server, so a page reloaded mid-step resumes where they stand.

  Its controls carry `data-test` names: `setup-passkey` (the passkey
  step), `setup-create`, `setup-closed`, `setup-error`, `setup-done` and
  `setup-continue`.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.{IdentityCard, SystemLayer}

  # Passkey ceremonies begun per address, as the sign-in page bounds its
  # own: the page is reached over the LiveView socket, which passes no
  # rate-limit plug.
  @starts 30
  @window_ms 60_000
  @ticket_ttl_ms 60_000

  @closed "This setup link is not valid, or setup is complete."
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

    {:ok, signed_in(socket, params, session), layout: false}
  end

  # A browser that holds a session is guarded as every console page is; a
  # session that no longer stands leaves the sessionless step, so a stale
  # cookie never keeps a person from setting up.
  defp signed_in(socket, params, session) do
    case session[to_string(CyfrWeb.ContextGuard.session_key())] do
      token when is_binary(token) and token != "" ->
        case CyfrWeb.ContextGuard.on_mount(:protected, params, session, socket) do
          {:cont, guarded} -> assign(guarded, :step, :signed_in)
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
      :ok -> {:noreply, assign(socket, step: :passkey, token: token)}
      {:error, :setup_closed} -> {:noreply, assign(socket, :step, :closed)}
      {:error, reason} -> {:noreply, assign(socket, :error, PrismWeb.Ops.error_message(reason))}
    end
  end

  def handle_event("setup_token", _params, socket), do: {:noreply, socket}

  def handle_event("setup_start", _params, %{assigns: %{step: :passkey, token: token}} = socket) do
    cond do
      not Arca.ControlPlane.held?() ->
        {:reply, %{error: @not_owner}, assign(socket, :error, @not_owner)}

      Prima.RateLimiter.check({:setup_passkey, socket.assigns.client_ip}, @starts, @window_ms) !=
          :ok ->
        message = "Too many passkey ceremonies from here. Try again in a minute."
        {:reply, %{error: message}, assign(socket, :error, message)}

      true ->
        with :ok <- Sanctum.Newcomer.setup_open(token),
             {:ok, %{public_key: public_key, registration: registration}} <-
               Sanctum.Passkeys.newcomer_options() do
          {:reply, %{public_key: public_key, registration: registration},
           assign(socket, :error, nil)}
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
    with {:ok, identity} <- Sanctum.Newcomer.identity(params),
         {:ok, %{session_token: session_token}} <-
           Sanctum.Newcomer.admit({:setup, token}, {:passkey, credential, identity}) do
      ticket = mint_ticket(session_token, socket.assigns.browser_binding)
      {:noreply, redirect(socket, to: ~p"/auth/passkey/complete/#{ticket}")}
    else
      {:error, reason} -> {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("setup_passkey", _params, socket), do: {:noreply, socket}

  def handle_event("setup_error", _params, socket) do
    {:noreply,
     assign(socket, :error, "The passkey was not created, so nothing was saved. Try again.")}
  end

  # A recovery prompt the identity card opened ended: the card reads where
  # the person stands again.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_report(prompt_id, outcome, socket) do
    if IdentityCard.prompt?(prompt_id) do
      send_update(IdentityCard, id: IdentityCard.id(), report: {prompt_id, outcome})
      {:noreply, socket}
    else
      :pass
    end
  end

  defp refused(socket, :setup_closed), do: assign(socket, step: :closed, error: nil)

  defp refused(socket, :registration_refused),
    do: assign(socket, :error, "That passkey could not be registered here. Try again.")

  defp refused(socket, reason), do: assign(socket, :error, PrismWeb.Ops.error_message(reason))

  # The passkey sign-in's ticket, bound to this browser, naming this page
  # as where the signed-in person lands.
  defp mint_ticket(session_token, browser_binding) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:login_passkey_ticket, ticket},
      %{session_token: session_token, browser_binding: browser_binding, to: ~p"/setup"},
      @ticket_ttl_ms
    )

    ticket
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :closed, @closed)

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
            :if={@error}
            role="alert"
            data-test="setup-error"
            class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
          >
            {@error}
          </div>

          <div
            :if={@step in [:reading, :passkey]}
            id="setup-passkey"
            phx-hook="SystemLayer"
            data-webauthn="setup"
            data-test="setup-passkey"
            class="space-y-4"
          >
            <p :if={@step == :reading} class="text-sm text-gray-400">Reading the setup link.</p>
            <div :if={@step == :passkey} class="space-y-4">
              <p class="text-sm text-gray-300 leading-relaxed">
                You are this CYFR's first person, and you administer it. Create a passkey on this
                device: it signs you in here, with no network needed.
              </p>
              <button
                type="button"
                data-webauthn-start
                data-test="setup-create"
                class="w-full px-4 py-3 bg-indigo-700 hover:bg-indigo-600 text-white rounded-lg transition-colors cursor-pointer"
              >
                Create a passkey
              </button>
            </div>
          </div>

          <div :if={@step == :closed} data-test="setup-closed" class="space-y-4">
            <p class="text-sm text-gray-300">{@closed}</p>
            <.link
              navigate={~p"/login"}
              class="block w-full text-center px-4 py-3 bg-indigo-700 hover:bg-indigo-600 text-white rounded-lg"
            >
              Sign in
            </.link>
          </div>

          <div :if={@step == :signed_in} data-test="setup-done" class="space-y-4">
            <p class="text-sm text-gray-300 leading-relaxed">
              CYFR is set up, and you are signed in. A handle at the registry lets people find
              you by name. It is optional, and Settings offers it later.
            </p>
            <.live_component
              module={IdentityCard}
              id={IdentityCard.id()}
              context={@context}
              offer="setup"
            />
            <.link
              navigate={~p"/"}
              data-test="setup-continue"
              class="block w-full text-center px-4 py-3 text-sm text-gray-300 hover:text-white border border-gray-700 rounded-lg"
            >
              Continue to CYFR
            </.link>
          </div>
        </div>
      </div>
      <.live_component
        :if={@step == :signed_in}
        module={SystemLayer}
        id={SystemLayer.layer_id()}
        context={@context}
      />
    </div>
    """
  end
end
