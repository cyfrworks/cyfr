defmodule PrismWeb.AuthLive do
  use PrismWeb, :live_view

  alias Sanctum.Auth.DeviceFlow

  @poll_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    providers = available_providers()

    {:ok,
     socket
     |> assign(:providers, providers)
     |> assign(:page_title, "Sign In")
     |> assign(:flow_state, :idle)
     |> assign(:user_code, nil)
     |> assign(:verification_uri, nil)
     |> assign(:device_code, nil)
     |> assign(:provider, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("start_device_flow", %{"provider" => provider}, socket) do
    provider_atom = String.to_existing_atom(provider)

    case DeviceFlow.init_device_flow(provider_atom) do
      {:ok, info} ->
        if connected?(socket), do: schedule_poll(info.interval)

        {:noreply,
         socket
         |> assign(:flow_state, :waiting)
         |> assign(:user_code, info.user_code)
         |> assign(:verification_uri, info.verification_uri)
         |> assign(:device_code, info.device_code)
         |> assign(:provider, provider_atom)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:flow_state, :idle)
     |> assign(:user_code, nil)
     |> assign(:verification_uri, nil)
     |> assign(:device_code, nil)
     |> assign(:provider, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info(:poll, socket) do
    case socket.assigns.flow_state do
      :waiting ->
        case DeviceFlow.poll_for_session(socket.assigns.provider, socket.assigns.device_code) do
          {:ok, %{status: "complete", session_id: token}} ->
            # Device flow creates the session — redirect to a controller
            # that stores the token in the cookie and redirects to /
            code = Prism.AuthExchange.create(token)

            {:noreply,
             socket
             |> assign(:flow_state, :complete)
             |> redirect(to: ~p"/auth/session?code=#{code}")}

          {:ok, %{status: "pending"}} ->
            schedule_poll(nil)
            {:noreply, socket}

          {:ok, %{status: "expired"}} ->
            {:noreply,
             socket
             |> assign(:flow_state, :idle)
             |> assign(:error, "Code expired. Please try again.")}

          {:ok, %{status: "denied"}} ->
            {:noreply,
             socket
             |> assign(:flow_state, :idle)
             |> assign(:error, "Authorization was denied.")}

          {:error, reason} ->
            {:noreply, assign(socket, :error, format_error(reason))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Ignore session creation events from other clients (e.g. CLI login).
  # Each client must authenticate independently.
  def handle_info({:session_created, _}, socket) do
    {:noreply, socket}
  end

  defp schedule_poll(interval) do
    ms = if interval, do: interval * 1_000, else: @poll_interval_ms
    Process.send_after(self(), :poll, ms)
  end

  defp available_providers do
    if github_configured?(), do: [:github], else: []
  end

  defp github_configured? do
    !!(Application.get_env(:cyfr, :github_client_id) ||
         System.get_env("CYFR_GITHUB_CLIENT_ID"))
  end

  defp format_error({:client_id_not_configured, provider}),
    do: "#{provider} client ID not configured."

  defp format_error(reason), do: "Authentication error: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-950">
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <h1 class="text-4xl font-bold text-white tracking-tight">Prism</h1>
          <p class="mt-2 text-sm text-gray-400">CYFR Dashboard</p>
        </div>

        <div class="bg-gray-900 rounded-lg shadow-xl p-8 space-y-4">
          <!-- Error message -->
          <div :if={@error} class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300">
            {@error}
          </div>

          <!-- Idle: show provider buttons -->
          <div :if={@flow_state == :idle}>
            <h2 class="text-lg font-medium text-white text-center mb-4">Sign in to continue</h2>

            <div :if={@providers == []} class="text-center text-gray-400 text-sm py-4">
              No providers configured. Set CYFR_GITHUB_CLIENT_ID.
            </div>

            <div class="flex flex-col gap-3">
              <.provider_button :for={provider <- @providers} provider={provider} />
            </div>
          </div>

          <!-- Waiting: show device code -->
          <div :if={@flow_state == :waiting} class="text-center space-y-6">
            <h2 class="text-lg font-medium text-white">Enter this code</h2>

            <div class="py-4">
              <code class="text-3xl font-bold tracking-[0.3em] text-white bg-gray-800 px-6 py-3 rounded-lg select-all">
                {@user_code}
              </code>
            </div>

            <div class="space-y-2">
              <p class="text-sm text-gray-400">
                Open the link below and paste the code:
              </p>
              <a
                href={@verification_uri}
                target="_blank"
                rel="noopener"
                class="inline-flex items-center gap-2 text-blue-400 hover:text-blue-300 text-sm font-medium"
              >
                {@verification_uri}
                <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
                </svg>
              </a>
            </div>

            <div class="flex items-center justify-center gap-2 text-gray-500 text-sm">
              <svg class="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
              <span>Waiting for authorization...</span>
            </div>

            <button
              phx-click="cancel"
              class="text-sm text-gray-500 hover:text-gray-300 transition-colors"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp provider_button(%{provider: :github} = assigns) do
    ~H"""
    <button
      phx-click="start_device_flow"
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

  defp provider_button(assigns) do
    ~H"""
    <button
      phx-click="start_device_flow"
      phx-value-provider={to_string(@provider)}
      class="flex items-center justify-center gap-3 w-full px-4 py-3 bg-gray-800 hover:bg-gray-700 text-white rounded-lg border border-gray-700 transition-colors cursor-pointer"
    >
      <span>Sign in with {@provider}</span>
    </button>
    """
  end
end
