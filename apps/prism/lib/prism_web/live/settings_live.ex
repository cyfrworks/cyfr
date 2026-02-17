defmodule PrismWeb.SettingsLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:config, %{})
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    config =
      case call_tool(socket, "config/get_all", %{}) do
        {:ok, config} when is_map(config) -> config
        {:ok, %{config: config}} -> config
        _ -> %{}
      end

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("save_config", %{"key" => key, "value" => value}, socket) do
    case call_tool(socket, "config/set", %{"key" => key, "value" => value}) do
      {:ok, _} ->
        config = Map.put(socket.assigns.config, key, value)

        {:noreply,
         socket
         |> assign(:config, config)
         |> put_flash(:info, "Configuration updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_config", %{"key" => key}, socket) do
    case call_tool(socket, "config/delete", %{"key" => key}) do
      {:ok, _} ->
        config = Map.delete(socket.assigns.config, key)

        {:noreply,
         socket
         |> assign(:config, config)
         |> put_flash(:info, "Configuration key deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-lg font-semibold text-white">Settings</h2>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-6">
        <!-- User profile -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">User Profile</h3>
          <dl class="grid grid-cols-2 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">User ID</dt>
              <dd class="text-sm text-white mt-1">{@current_user.id}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Email</dt>
              <dd class="text-sm text-white mt-1">{@current_user.email || "-"}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Provider</dt>
              <dd class="text-sm text-white mt-1">{@current_user.provider}</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Permissions</dt>
              <dd class="text-sm text-white mt-1">
                {Enum.join(Enum.map(@current_user.permissions, &to_string/1), ", ")}
              </dd>
            </div>
          </dl>
        </.card>

        <!-- Configuration -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Configuration</h3>
          <div :if={@config == %{}} class="py-4">
            <.empty_state message="No configuration entries" />
          </div>
          <div :if={@config != %{}} class="space-y-3">
            <div
              :for={{key, value} <- @config}
              class="flex items-center justify-between rounded-lg bg-gray-800 px-4 py-3"
            >
              <div>
                <span class="text-sm font-mono text-gray-300">{key}</span>
                <span class="ml-3 text-sm text-gray-500">{inspect(value)}</span>
              </div>
              <.button
                variant="ghost"
                phx-click="delete_config"
                phx-value-key={key}
                data-confirm="Delete this configuration key?"
              >
                Delete
              </.button>
            </div>
          </div>
        </.card>
      </div>
    </div>
    """
  end
end
