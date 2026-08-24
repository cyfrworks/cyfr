# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLive do
  @moduledoc """
  The sign-in page. GitHub and Google use device flow on this page
  (`Sanctum.Auth.DeviceFlow`); a configured OIDC issuer still kicks off
  through `GET /auth/oidcc`. A completed device flow hands a one-time
  ticket to `GET /auth/device/complete/:ticket`, which sets the cookie
  session this origin has.

  A refused sign-in never reaches a session — the door answers on the
  poll; a signed-in person who has no athanor yet is told so.
  """

  use PrismWeb, :live_view

  alias Sanctum.Auth.DeviceFlow
  require Logger

  @ticket_ttl_ms 60_000
  @default_poll_interval_s 5

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:providers, available_providers())
     |> assign(:login_state, :idle)
     |> assign(:provider, nil)
     |> assign(:user_code, nil)
     |> assign(:verification_uri, nil)
     |> assign(:device_code, nil)
     |> assign(:poll_interval, @default_poll_interval_s)
     |> assign(:error, error_from_params(params)), layout: false}
  end

  @impl true
  def handle_event("start", %{"provider" => provider}, socket)
      when provider in ["github", "google"] do
    if socket.assigns.login_state == :waiting do
      {:noreply, socket}
    else
      provider_atom = String.to_existing_atom(provider)

      case device_flow().init_device_flow(provider_atom) do
        {:ok, info} ->
          if connected?(socket), do: schedule_poll(info.interval)

          {:noreply,
           socket
           |> assign(:login_state, :waiting)
           |> assign(:provider, provider_atom)
           |> assign(:user_code, info.user_code)
           |> assign(:verification_uri, info.verification_uri)
           |> assign(:device_code, info.device_code)
           |> assign(:poll_interval, info.interval || @default_poll_interval_s)
           |> assign(:error, nil)}

        {:error, {:client_id_not_configured, p}} ->
          {:noreply, assign(socket, :error, "#{p} is not configured on this server.")}

        {:error, {:device_code_error, code}} ->
          Logger.warning("[LoginLive] device-flow init rejected: #{inspect(code)}")

          {:noreply,
           assign(
             socket,
             :error,
             "Device flow was rejected (#{code}). For Google, the OAuth client must be type \"TV and Limited Input devices\"."
           )}

        {:error, reason} ->
          Logger.warning("[LoginLive] device-flow init failed: #{inspect(reason)}")
          {:noreply, assign(socket, :error, "Couldn't start sign-in. Try again in a moment.")}
      end
    end
  end

  def handle_event("start", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    {:noreply, assign_idle(socket, nil)}
  end

  @impl true
  def handle_info(:login_poll, socket) do
    case socket.assigns.login_state do
      :waiting ->
        finish_poll(
          socket,
          device_flow().poll_for_session(socket.assigns.provider, socket.assigns.device_code)
        )

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp finish_poll(socket, {:ok, %{status: "pending"} = result}) do
    interval =
      if result[:slow_down],
        do: max(socket.assigns.poll_interval, @default_poll_interval_s) + 5,
        else: socket.assigns.poll_interval

    schedule_poll(interval)
    {:noreply, socket}
  end

  defp finish_poll(socket, {:ok, %{status: "complete", reauthenticate: true}}) do
    {:noreply,
     assign_idle(
       socket,
       "Your login session expired during setup. Please try again."
     )}
  end

  defp finish_poll(socket, {:ok, %{status: "complete", session_token: token} = result})
       when is_binary(token) do
    ticket = mint_ticket(result)
    {:noreply, redirect(socket, to: ~p"/auth/device/complete/#{ticket}")}
  end

  defp finish_poll(socket, {:ok, %{status: "complete"}}) do
    {:noreply, assign_idle(socket, "Sign-in could not create a session. Please try again.")}
  end

  defp finish_poll(socket, {:ok, %{status: "denied"}}) do
    {:noreply, assign_idle(socket, Sanctum.Door.refusal_message())}
  end

  defp finish_poll(socket, {:ok, %{status: "expired"}}) do
    {:noreply, assign_idle(socket, "Code expired. Please try again.")}
  end

  defp finish_poll(socket, {:ok, %{status: "registry_unavailable", message: message}}) do
    {:noreply, assign_idle(socket, message)}
  end

  defp finish_poll(socket, {:ok, %{status: "error", message: message}}) do
    {:noreply, assign_idle(socket, message)}
  end

  defp finish_poll(socket, {:error, {:client_id_not_configured, provider}}) do
    {:noreply, assign_idle(socket, "#{provider} is not configured on this server.")}
  end

  defp finish_poll(socket, {:error, {:door, _reason}}) do
    {:noreply, assign_idle(socket, Sanctum.Door.refusal_message())}
  end

  defp finish_poll(socket, {:error, reason}) do
    Logger.warning("[LoginLive] device-flow poll failed: #{inspect(reason)}")
    {:noreply, assign_idle(socket, "Couldn't complete sign-in. Try again in a moment.")}
  end

  defp mint_ticket(result) do
    ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    payload = %{
      session_token: result.session_token,
      access_token: Map.get(result, :access_token),
      next: next_from(result),
      suggested_username: Map.get(result, :suggested_username)
    }

    Arca.Cache.put({:login_device_ticket, ticket}, payload, @ticket_ttl_ms)
    ticket
  end

  defp next_from(%{needs_policy_acceptance: true}), do: :legal
  defp next_from(%{needs_personal_namespace: true}), do: :claim
  defp next_from(_), do: :home

  defp assign_idle(socket, error) do
    socket
    |> assign(:login_state, :idle)
    |> assign(:provider, nil)
    |> assign(:user_code, nil)
    |> assign(:verification_uri, nil)
    |> assign(:device_code, nil)
    |> assign(:error, error)
  end

  defp schedule_poll(interval_s) do
    ms =
      cond do
        is_integer(interval_s) and interval_s >= 0 -> interval_s * 1_000
        true -> @default_poll_interval_s * 1_000
      end

    Process.send_after(self(), :login_poll, ms)
  end

  defp device_flow do
    Application.get_env(:cyfr, :device_flow, DeviceFlow)
  end

  # The built-in provider offers GitHub and Google device flow; a deployment
  # with its own OIDC issuer authenticates through `/auth/oidcc`.
  defp available_providers do
    case Application.get_env(:cyfr, :auth_provider) do
      Sanctum.Auth.OIDC ->
        [:oidcc]

      _ ->
        Enum.filter([:github, :google], &provider_configured?/1)
    end
  end

  # App-env only: runtime.exs resolves CYFR_* through Dotenvy's merged .env
  # sources, which are not exported to the OS environment.
  defp provider_configured?(:github), do: present?(Application.get_env(:cyfr, :github_client_id))

  defp provider_configured?(:google) do
    present?(Application.get_env(:cyfr, :google_client_id)) and
      present?(Application.get_env(:cyfr, :google_client_secret))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # Map an auth redirect (`/login?error=<code>`) to a user-facing banner.
  defp error_from_params(%{"error" => "no_athanor"}),
    do:
      "You're signed in, but you have no athanor here yet. If you were just " <>
        "let in, sign in again; otherwise ask the operator."

  defp error_from_params(%{"error" => "unavailable"}),
    do: "The server could not read your account just now. Try again in a moment."

  defp error_from_params(%{"error" => "signed_out"}), do: nil
  defp error_from_params(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <div class="min-h-screen flex items-center justify-center bg-gray-950">
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <p class="text-sm text-indigo-300/70 uppercase tracking-[0.3em] mb-4">
            Dear Alchemist&hellip;
          </p>
          <h1 class="text-3xl md:text-4xl font-extrabold tracking-tight text-indigo-200/80 leading-tight">
            Welcome to <span class="text-indigo-300">CYFR</span>,<br /> your secure personal foundry.
          </h1>
        </div>

        <div class="flex items-start gap-3">
          <img
            src={~p"/images/logo.jpg"}
            alt="AQUA"
            class="h-10 w-10 rounded-full shrink-0 mt-1 ring-2 ring-indigo-400/30"
          />
          <div class="flex-1 min-w-0">
            <div class="text-[10px] text-indigo-300/60 uppercase tracking-wider mb-1.5">AQUA</div>
            <div class="relative bg-gray-900 rounded-lg rounded-tl-none px-4 py-3">
              <div class="absolute -left-2 top-3 w-0 h-0 border-t-[6px] border-t-transparent border-b-[6px] border-b-transparent border-r-[8px] border-r-gray-900">
              </div>
              <p class="text-sm text-gray-300 leading-relaxed">
                <span class="font-semibold text-white">AQUA</span>, your trusted assistant,
                is at your service&mdash;ready to forge your brilliance into reality.
              </p>
            </div>
          </div>
        </div>

        <div class="bg-gray-900 rounded-lg shadow-xl p-8 space-y-4">
          <div
            :if={@error}
            class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
          >
            {@error}
          </div>

          <h2 class="text-lg font-medium text-white text-center mb-4">Sign in to continue</h2>

          <div :if={@login_state == :waiting} class="space-y-4">
            <p class="text-sm text-gray-300 text-center">
              Open
              <a
                href={@verification_uri}
                target="_blank"
                rel="noopener noreferrer"
                class="text-indigo-400 hover:text-indigo-300"
              >
                {@verification_uri}
              </a>
              and enter:
            </p>
            <div class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-3 text-center">
              <span class="font-mono text-2xl tracking-widest text-white">{@user_code}</span>
            </div>
            <.live_loading message="Waiting for authorization…" />
            <button
              type="button"
              phx-click="cancel"
              class="w-full px-4 py-2 text-sm text-gray-400 hover:text-white"
            >
              Cancel
            </button>
          </div>

          <div
            :if={@login_state == :idle && @providers == []}
            class="text-center text-gray-400 text-sm py-4"
          >
            No providers configured. Set CYFR_GITHUB_CLIENT_ID or CYFR_GOOGLE_CLIENT_ID.
          </div>

          <div :if={@login_state == :idle} class="flex flex-col gap-3">
            <.provider_button :for={provider <- @providers} provider={provider} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp provider_button(%{provider: :github} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="start"
      phx-value-provider="github"
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
    >
      <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
        <path
          fill-rule="evenodd"
          d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"
          clip-rule="evenodd"
        />
      </svg>
      <span>Sign in with GitHub</span>
    </button>
    """
  end

  defp provider_button(%{provider: :google} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="start"
      phx-value-provider="google"
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-white hover:bg-gray-100 text-gray-800 rounded-lg border border-gray-300 transition-colors cursor-pointer"
    >
      <svg class="w-5 h-5" viewBox="0 0 24 24">
        <path
          fill="#4285F4"
          d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
        />
        <path
          fill="#34A853"
          d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
        />
        <path
          fill="#FBBC05"
          d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
        />
        <path
          fill="#EA4335"
          d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
        />
      </svg>
      <span>Sign in with Google</span>
    </button>
    """
  end

  defp provider_button(assigns) do
    ~H"""
    <a
      href={"/auth/#{@provider}"}
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
    >
      <span>Sign in with {@provider}</span>
    </a>
    """
  end
end
