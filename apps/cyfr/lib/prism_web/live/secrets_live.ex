# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SecretsLive do
  use PrismWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Secrets")
      |> assign(:active_nav, "secrets")
      |> assign(:secrets, [])
      |> assign(:show_add, false)
      |> assign(:loading, true)

    {:ok, socket}
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
            {:ok, %{secrets: list}} ->
              enrich_secrets(list, ctx)

            {:ok, list} when is_list(list) ->
              enrich_secrets(list, ctx)

            other ->
              Logger.warning("[SecretsLive] secret/list failed: #{inspect(other)}")
              socket.assigns.secrets
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
        secrets =
          Enum.reject(socket.assigns.secrets, fn s ->
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

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:secrets", ctx))
      {:noreply, socket |> fetch_secrets() |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:secrets_changed, socket) do
    {:noreply, fetch_secrets(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[SecretsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp fetch_secrets(socket) do
    ctx = socket.assigns.context

    secrets =
      case call_tool(socket, "secret/list", %{}) do
        {:ok, %{secrets: list}} ->
          enrich_secrets(list, ctx)

        {:ok, list} when is_list(list) ->
          enrich_secrets(list, ctx)

        other ->
          Logger.warning("[SecretsLive] secret/list failed: #{inspect(other)}")
          []
      end

    socket
    |> assign(:secrets, secrets)
    |> PrismWeb.ActiveContext.set_snapshot(%{
      type: "secrets",
      items:
        Enum.map(secrets, fn s ->
          %{
            name: s[:name] || s["name"],
            grants: length(s[:grants] || s["grants"] || [])
          }
        end),
      total: length(secrets)
    })
  end

  defp enrich_secrets(list, ctx) do
    Enum.map(list, fn
      name when is_binary(name) ->
        grants =
          case Sanctum.Secrets.list_grants(ctx, name) do
            {:ok, g} ->
              g

            other ->
              Logger.warning("[SecretsLive] list_grants failed for #{name}: #{inspect(other)}")
              []
          end

        %{name: name, granted_to: grants}

      other ->
        normalize_keys(other)
    end)
  end

  defp secret_name(s) when is_binary(s), do: s
  defp secret_name(s), do: s[:name] || s["name"]

  @known_secret_keys %{
    "name" => :name,
    "masked_value" => :masked_value,
    "granted_to" => :granted_to,
    "created_at" => :created_at
  }

  defp normalize_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {Map.get(@known_secret_keys, k, k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_keys(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Secrets">
        <:actions>
          <.button phx-click="toggle_add">
            {if @show_add, do: "Cancel", else: "Add Secret"}
          </.button>
        </:actions>
      </.page_header>
      
    <!-- Add secret form -->
      <.card :if={@show_add}>
        <form phx-submit="add_secret" class="space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" required placeholder="SECRET_NAME" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Value</label>
              <.input type="password" name="value" required placeholder="secret value" />
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
            <span class="font-mono">{secret[:name] || "-"}</span>
          </:col>
          <:col :let={secret} label="Value">
            <span class="text-gray-500">
              {secret[:masked_value] || "********"}
            </span>
          </:col>
          <:col :let={secret} label="Granted To">
            {Enum.join(secret[:granted_to] || [], ", ")}
          </:col>
          <:col :let={secret} label="Actions">
            <.button
              variant="ghost"
              phx-click="delete"
              phx-value-name={secret[:name]}
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
