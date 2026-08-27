# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ApiKeysLive do
  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS
  require Logger

  # `type` arrives from form params — match it against the three key types
  # instead of String.to_existing_atom, which crashes the LiveView on any
  # other value.
  defp key_type("application"), do: :application
  defp key_type("service"), do: :service
  defp key_type("admin"), do: :admin
  defp key_type(_), do: :application

  defp valid_scopes_for(type), do: Sanctum.ApiKey.valid_scopes(key_type(type))

  defp default_scopes_for(type), do: Sanctum.ApiKey.default_scopes(key_type(type))

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe once, at mount — handle_params re-fires on every patch,
    # and PubSub's :duplicate registry would deliver every message twice.
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Prism.Topics.api_keys(ctx))
    end

    socket =
      socket
      |> assign(:page_title, "API Keys")
      |> assign(:active_nav, "api_keys")
      |> assign(:keys, [])
      |> assign(:show_create, false)
      |> assign(:new_key, nil)
      |> assign(:loading, true)
      |> assign(:selected_type, "application")
      |> assign(:available_scopes, valid_scopes_for("application"))
      |> assign(:checked_scopes, default_scopes_for("application"))
      |> assign(:key_name, "")
      |> assign(:grant_all, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create, !socket.assigns.show_create)
     |> assign(:new_key, nil)
     |> assign(:key_name, "")
     |> assign(:selected_type, "application")
     |> assign(:available_scopes, valid_scopes_for("application"))
     |> assign(:checked_scopes, default_scopes_for("application"))
     |> assign(:grant_all, false)}
  end

  def handle_event("form_changed", params, socket) do
    socket = assign(socket, :key_name, params["name"] || socket.assigns.key_name)

    type = params["type"] || socket.assigns.selected_type

    socket =
      if type != socket.assigns.selected_type do
        socket
        |> assign(:selected_type, type)
        |> assign(:available_scopes, valid_scopes_for(type))
        |> assign(:checked_scopes, default_scopes_for(type))
        |> assign(:grant_all, type == "admin")
      else
        socket
      end

    {:noreply, socket}
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
        else: default_scopes_for(socket.assigns.selected_type)

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
          case fetch_list(socket, "key/list", :keys) do
            {:ok, list} ->
              list

            {:error, message} ->
              Logger.warning("[ApiKeysLive] key/list failed: #{message}")
              socket.assigns.keys
          end

        {:noreply,
         socket
         |> assign(:keys, keys)
         |> assign(:new_key, key)
         |> put_flash(:info, "API key created. Copy it now — it won't be shown again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create: #{error_message(reason)}")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case call_tool(socket, "key/revoke", %{"name" => id}) do
      {:ok, _} ->
        keys =
          Enum.reject(socket.assigns.keys, fn k ->
            to_string(k[:name] || k[:id]) == id
          end)

        {:noreply,
         socket
         |> assign(:keys, keys)
         |> put_flash(:info, "API key revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{error_message(reason)}")}
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
        {:noreply, put_flash(socket, :error, "Failed to rotate: #{error_message(reason)}")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      {:noreply, socket |> fetch_keys() |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:api_keys_changed, socket) do
    {:noreply, fetch_keys(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ApiKeysLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="API Keys">
        <:actions>
          <.button phx-click="toggle_create">
            {if @show_create, do: "Cancel", else: "Create Key"}
          </.button>
        </:actions>
      </.page_header>
      
    <!-- New key display -->
      <.card :if={@new_key}>
        <div class="space-y-2">
          <p class="text-sm text-yellow-400 font-medium">
            Copy this key now. It will not be shown again.
          </p>
          <div class="flex items-start gap-2">
            <code class="flex-1 block bg-gray-950 rounded p-3 text-sm text-green-400 font-mono break-all">
              {@new_key[:api_key] || inspect(@new_key)}
            </code>
            <.button
              variant="secondary"
              size="sm"
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: @new_key[:api_key] || ""})}
            >
              Copy
            </.button>
          </div>
        </div>
      </.card>
      
    <!-- Create form -->
      <.card :if={@show_create}>
        <form phx-submit="create" phx-change="form_changed" class="space-y-4">
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input name="name" value={@key_name} required placeholder="my-api-key" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Type</label>
              <select
                name="type"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              >
                <option value="application" selected={@selected_type == "application"}>
                  Application
                </option>
                <option value="service" selected={@selected_type == "service"}>Service</option>
                <option value="admin" selected={@selected_type == "admin"}>Admin</option>
              </select>
            </div>
          </div>
          
    <!-- Scope selection -->
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-2">Scopes</label>
            <div class="space-y-2">
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
          <:col :let={key} label="Name">{key[:name] || "-"}</:col>
          <:col :let={key} label="Type">
            <.badge color={key_type_color(key[:type])}>
              {key[:type] || "-"}
            </.badge>
          </:col>
          <:col :let={key} label="Scope">{format_scope(key[:scope])}</:col>
          <:col :let={key} label="Created">{key[:created_at] || "-"}</:col>
          <:col :let={key} label="Actions">
            <div class="flex gap-2">
              <.button
                variant="ghost"
                phx-click="rotate"
                phx-value-id={key[:name] || key[:id]}
              >
                Rotate
              </.button>
              <.button
                variant="ghost"
                phx-click="revoke"
                phx-value-id={key[:name] || key[:id]}
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

  defp fetch_keys(socket) do
    case fetch_list(socket, "key/list", :keys) do
      {:ok, list} ->
        assign(socket, :keys, list)

      {:error, message} ->
        Logger.warning("[ApiKeysLive] key/list failed: #{message}")
        assign(socket, :keys, [])
    end
  end

  defp key_type_color("admin"), do: "red"
  defp key_type_color(:admin), do: "red"
  defp key_type_color("service"), do: "yellow"
  defp key_type_color(:service), do: "yellow"
  defp key_type_color("application"), do: "green"
  defp key_type_color(:application), do: "green"
  defp key_type_color(_), do: "gray"

  defp format_scope(nil), do: "-"
  defp format_scope([]), do: "none"
  defp format_scope(["*"]), do: "* (all)"
  defp format_scope(scopes) when is_list(scopes), do: Enum.join(scopes, ", ")
  defp format_scope(other), do: to_string(other)
end
