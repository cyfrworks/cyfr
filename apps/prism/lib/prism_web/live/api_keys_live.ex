defmodule PrismWeb.ApiKeysLive do
  use PrismWeb, :live_view

  @type_scopes %{
    "public" => [],
    "secret" => ["secrets_read", "secrets_write"],
    "admin" => ["secrets_read", "secrets_write", "users_manage", "admin"]
  }

  @type_defaults %{
    "public" => [],
    "secret" => ["secrets_read"],
    "admin" => ["*"]
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "API Keys")
     |> assign(:keys, [])
     |> assign(:show_create, false)
     |> assign(:new_key, nil)
     |> assign(:loading, true)
     |> assign(:selected_type, "public")
     |> assign(:available_scopes, Map.get(@type_scopes, "public", []))
     |> assign(:checked_scopes, Map.get(@type_defaults, "public", []))
     |> assign(:grant_all, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    keys =
      case call_tool(socket, "key/list", %{}) do
        {:ok, %{keys: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:keys, keys)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create, !socket.assigns.show_create)
     |> assign(:new_key, nil)
     |> assign(:selected_type, "public")
     |> assign(:available_scopes, Map.get(@type_scopes, "public", []))
     |> assign(:checked_scopes, Map.get(@type_defaults, "public", []))
     |> assign(:grant_all, false)}
  end

  def handle_event("type_changed", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:selected_type, type)
     |> assign(:available_scopes, Map.get(@type_scopes, type, []))
     |> assign(:checked_scopes, Map.get(@type_defaults, type, []))
     |> assign(:grant_all, type == "admin")}
  end

  def handle_event("toggle_scope", %{"scope" => scope}, socket) do
    checked = socket.assigns.checked_scopes

    checked =
      if scope in checked,
        do: List.delete(checked, scope),
        else: [scope | checked]

    {:noreply, assign(socket, :checked_scopes, checked)}
  end

  def handle_event("toggle_grant_all", _params, socket) do
    grant_all = !socket.assigns.grant_all

    checked =
      if grant_all,
        do: socket.assigns.available_scopes,
        else: Map.get(@type_defaults, socket.assigns.selected_type, [])

    {:noreply,
     socket
     |> assign(:grant_all, grant_all)
     |> assign(:checked_scopes, checked)}
  end

  def handle_event("create", %{"name" => name, "type" => type}, socket) do
    scope =
      if socket.assigns.grant_all do
        ["*"]
      else
        socket.assigns.checked_scopes
      end

    case call_tool(socket, "key/create", %{"name" => name, "type" => type, "scope" => scope}) do
      {:ok, key} ->
        keys =
          case call_tool(socket, "key/list", %{}) do
            {:ok, %{keys: list}} -> list
            {:ok, list} when is_list(list) -> list
            _ -> socket.assigns.keys
          end

        {:noreply,
         socket
         |> assign(:keys, keys)
         |> assign(:new_key, key)
         |> put_flash(:info, "API key created. Copy it now — it won't be shown again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case call_tool(socket, "key/revoke", %{"name" => id}) do
      {:ok, _} ->
        keys = Enum.reject(socket.assigns.keys, fn k ->
          to_string(k[:name] || k["name"] || k[:id] || k["id"]) == id
        end)

        {:noreply,
         socket
         |> assign(:keys, keys)
         |> put_flash(:info, "API key revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{inspect(reason)}")}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    case call_tool(socket, "key/rotate", %{"name" => id}) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(:new_key, key)
         |> put_flash(:info, "API key rotated. Copy the new key now.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">API Keys</h2>
        <.button phx-click="toggle_create">
          {if @show_create, do: "Cancel", else: "Create Key"}
        </.button>
      </div>

      <!-- New key display -->
      <.card :if={@new_key}>
        <div class="space-y-2">
          <p class="text-sm text-yellow-400 font-medium">
            Copy this key now. It will not be shown again.
          </p>
          <code class="block bg-gray-950 rounded p-3 text-sm text-green-400 font-mono break-all">
            {@new_key[:key] || @new_key["key"] || inspect(@new_key)}
          </code>
        </div>
      </.card>

      <!-- Create form -->
      <.card :if={@show_create}>
        <form phx-submit="create" class="space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <input
                type="text"
                name="name"
                required
                placeholder="my-api-key"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Type</label>
              <select
                name="type"
                phx-change="type_changed"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              >
                <option value="public" selected={@selected_type == "public"}>Public</option>
                <option value="secret" selected={@selected_type == "secret"}>Secret</option>
                <option value="admin" selected={@selected_type == "admin"}>Admin</option>
              </select>
            </div>
          </div>

          <!-- Scope selection -->
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-2">Scopes</label>
            <div :if={@selected_type == "public"} class="text-sm text-gray-400 py-2">
              Public keys can execute components and search. No additional scopes needed.
            </div>
            <div :if={@selected_type != "public"} class="space-y-2">
              <div :if={@selected_type == "admin"} class="flex items-center gap-2 mb-3">
                <button
                  type="button"
                  phx-click="toggle_grant_all"
                  class={[
                    "relative inline-flex h-5 w-9 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out",
                    if(@grant_all, do: "bg-blue-500", else: "bg-gray-600")
                  ]}
                >
                  <span class={[
                    "pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                    if(@grant_all, do: "translate-x-4", else: "translate-x-0")
                  ]} />
                </button>
                <span class="text-sm text-gray-300">Grant all (<code class="text-xs">*</code>)</span>
              </div>
              <div class="grid grid-cols-2 gap-2">
                <label
                  :for={scope <- @available_scopes}
                  class="flex items-center gap-2 rounded-lg bg-gray-800/50 px-3 py-2 text-sm cursor-pointer hover:bg-gray-800"
                >
                  <input
                    type="checkbox"
                    checked={scope in @checked_scopes}
                    phx-click="toggle_scope"
                    phx-value-scope={scope}
                    disabled={@grant_all}
                    class="rounded border-gray-600 bg-gray-700 text-blue-500 focus:ring-blue-500 focus:ring-offset-0"
                  />
                  <span class={"text-gray-300 #{if @grant_all, do: "opacity-50"}"}>{scope}</span>
                </label>
              </div>
            </div>
          </div>

          <.button type="submit">Create API Key</.button>
        </form>
      </.card>

      <!-- Keys list -->
      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @keys == []} class="py-8">
          <.empty_state message="No API keys created" />
        </div>
        <.table :if={!@loading && @keys != []} id="api-keys" rows={@keys}>
          <:col :let={key} label="Name">{key[:name] || key["name"] || "-"}</:col>
          <:col :let={key} label="Type">
            <.badge color={key_type_color(key[:type] || key["type"])}>
              {key[:type] || key["type"] || "-"}
            </.badge>
          </:col>
          <:col :let={key} label="Scope">{format_scope(key[:scope] || key["scope"])}</:col>
          <:col :let={key} label="Created">{key[:created_at] || key["created_at"] || "-"}</:col>
          <:col :let={key} label="Actions">
            <div class="flex gap-2">
              <.button
                variant="ghost"
                phx-click="rotate"
                phx-value-id={key[:name] || key["name"] || key[:id] || key["id"]}
              >
                Rotate
              </.button>
              <.button
                variant="ghost"
                phx-click="revoke"
                phx-value-id={key[:name] || key["name"] || key[:id] || key["id"]}
                data-confirm="Are you sure?"
              >
                Revoke
              </.button>
            </div>
          </:col>
        </.table>
      </.card>
    </div>
    """
  end

  defp key_type_color("admin"), do: "red"
  defp key_type_color(:admin), do: "red"
  defp key_type_color("secret"), do: "yellow"
  defp key_type_color(:secret), do: "yellow"
  defp key_type_color("public"), do: "green"
  defp key_type_color(:public), do: "green"
  defp key_type_color(_), do: "gray"

  defp format_scope(nil), do: "-"
  defp format_scope([]), do: "none"
  defp format_scope(["*"]), do: "* (all)"
  defp format_scope(scopes) when is_list(scopes), do: Enum.join(scopes, ", ")
  defp format_scope(other), do: to_string(other)
end
