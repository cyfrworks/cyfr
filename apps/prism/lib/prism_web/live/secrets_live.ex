defmodule PrismWeb.SecretsLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Secrets")
     |> assign(:secrets, [])
     |> assign(:show_add, false)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    ctx = socket.assigns.context

    secrets =
      case call_tool(socket, "secret/list", %{}) do
        {:ok, %{secrets: list}} -> enrich_secrets(list, ctx)
        {:ok, list} when is_list(list) -> enrich_secrets(list, ctx)
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:secrets, secrets)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("toggle_add", _params, socket) do
    {:noreply, assign(socket, :show_add, !socket.assigns.show_add)}
  end

  def handle_event("add_secret", %{"name" => name, "value" => value}, socket) do
    case call_tool(socket, "secret/set", %{"name" => name, "value" => value}) do
      {:ok, _} ->
        ctx = socket.assigns.context

        secrets =
          case call_tool(socket, "secret/list", %{}) do
            {:ok, %{secrets: list}} -> enrich_secrets(list, ctx)
            {:ok, list} when is_list(list) -> enrich_secrets(list, ctx)
            _ -> socket.assigns.secrets
          end

        {:noreply,
         socket
         |> assign(:secrets, secrets)
         |> assign(:show_add, false)
         |> put_flash(:info, "Secret added.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to add: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case call_tool(socket, "secret/delete", %{"name" => name}) do
      {:ok, _} ->
        secrets = Enum.reject(socket.assigns.secrets, fn s ->
          secret_name(s) == name
        end)

        {:noreply,
         socket
         |> assign(:secrets, secrets)
         |> put_flash(:info, "Secret deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event("grant", %{"name" => name, "component" => component}, socket) do
    case call_tool(socket, "secret/grant", %{"name" => name, "component_ref" => component}) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Access granted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to grant: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke", %{"name" => name, "component" => component}, socket) do
    case call_tool(socket, "secret/revoke", %{"name" => name, "component_ref" => component}) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Access revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{inspect(reason)}")}
    end
  end

  defp enrich_secrets(list, ctx) do
    Enum.map(list, fn
      name when is_binary(name) ->
        grants =
          case Sanctum.Secrets.list_grants(ctx, name) do
            {:ok, g} -> g
            _ -> []
          end

        %{"name" => name, "granted_to" => grants}

      other ->
        other
    end)
  end

  defp secret_name(s) when is_binary(s), do: s
  defp secret_name(s), do: s[:name] || s["name"]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Secrets</h2>
        <.button phx-click="toggle_add">
          {if @show_add, do: "Cancel", else: "Add Secret"}
        </.button>
      </div>

      <!-- Add secret form -->
      <.card :if={@show_add}>
        <form phx-submit="add_secret" class="space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <input
                type="text"
                name="name"
                required
                placeholder="SECRET_NAME"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Value</label>
              <input
                type="password"
                name="value"
                required
                placeholder="secret value"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
          </div>
          <.button type="submit">Save Secret</.button>
        </form>
      </.card>

      <!-- Secrets list -->
      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @secrets == []} class="py-8">
          <.empty_state message="No secrets configured" />
        </div>
        <.table :if={!@loading && @secrets != []} id="secrets" rows={@secrets}>
          <:col :let={secret} label="Name">
            <span class="font-mono">{secret[:name] || secret["name"] || "-"}</span>
          </:col>
          <:col :let={secret} label="Value">
            <span class="text-gray-500">
              {if secret[:masked_value] || secret["masked_value"],
                do: secret[:masked_value] || secret["masked_value"],
                else: "********"}
            </span>
          </:col>
          <:col :let={secret} label="Granted To">
            {Enum.join(secret[:granted_to] || secret["granted_to"] || [], ", ")}
          </:col>
          <:col :let={secret} label="Actions">
            <.button
              variant="ghost"
              phx-click="delete"
              phx-value-name={secret[:name] || secret["name"]}
              data-confirm="Are you sure?"
            >
              Delete
            </.button>
          </:col>
        </.table>
      </.card>
    </div>
    """
  end
end
