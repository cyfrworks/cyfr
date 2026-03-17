defmodule PrismWeb.SettingsLive do
  use PrismWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Settings")}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[SettingsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-lg font-semibold text-white">Settings</h2>

      <div class="space-y-6">
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
      </div>
    </div>
    """
  end
end
