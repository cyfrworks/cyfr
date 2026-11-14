# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ApiKeysLive do
  @moduledoc """
  The athanor's API keys: list, create, rotate, revoke, through the `key`
  tool. A minted key is shown once, in its reveal card, until dismissed.
  A key's permissions are ticked from a preset and may be narrowed to
  named tools; both are fixed once it is made (`Sanctum.ApiKey`).

  Creating and rotating a key are sensitive changes: the page asks for a
  fresh confirmation through its system layer (`PrismWeb.SystemLayer.call/5`),
  which shows the request as this page's own, and the page repeats the
  change once its record is confirmed, wherever the person proved it.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias Phoenix.LiveView.JS
  alias PrismWeb.SystemLayer
  require Logger

  defp first_preset, do: Sanctum.ApiKey.presets() |> hd() |> elem(1)

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe once, at mount — handle_params re-fires on every patch,
    # and PubSub's :duplicate registry would deliver every message twice.
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.api_keys(actor))
    end

    socket =
      socket
      |> assign(:page_title, "API Keys")
      |> assign(:active_nav, "api_keys")
      |> assign(:keys, [])
      |> assign(:show_create, false)
      |> assign(:new_key, nil)
      |> assign(:loading, true)
      |> assign(:permissions, Sanctum.ApiKey.permissions())
      |> assign(:presets, Sanctum.ApiKey.presets())
      |> assign(:checked_scopes, first_preset())
      |> assign(:key_name, "")
      |> assign(:key_tools, "")

    {:ok, socket}
  end

  @impl true
  # The minted key is plaintext in the socket's assigns, which
  # `Phoenix.LiveView.Socket` prints in a crash report and the DOM holds until
  # the page changes. Once it has been copied there is no reason to keep it,
  # and nothing else cleared it for the rest of the session.
  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  def handle_event("toggle_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create, !socket.assigns.show_create)
     |> assign(:new_key, nil)
     |> assign(:key_name, "")
     |> assign(:key_tools, "")
     |> assign(:checked_scopes, first_preset())}
  end

  def handle_event("form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:key_name, params["name"] || socket.assigns.key_name)
     |> assign(:key_tools, params["tools"] || socket.assigns.key_tools)}
  end

  # A preset ticks its permissions in place of what was ticked; the person
  # may still tick or untick each one.
  def handle_event("preset", %{"preset" => name}, socket) do
    case List.keyfind(socket.assigns.presets, name, 0) do
      {^name, scopes} -> {:noreply, assign(socket, :checked_scopes, scopes)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("toggle_scope", %{"scope" => scope}, socket) do
    checked = socket.assigns.checked_scopes

    checked =
      if scope in checked,
        do: List.delete(checked, scope),
        else: [scope | checked]

    {:noreply, assign(socket, :checked_scopes, checked)}
  end

  def handle_event("create", %{"name" => name} = params, socket) do
    # Sent in reading order; the server refuses a name it does not know.
    scope =
      for {scope, _what} <- socket.assigns.permissions,
          scope in socket.assigns.checked_scopes,
          do: scope

    create(socket, %{"name" => name, "scope" => scope, "tools" => tools(params["tools"])})
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case call_tool(socket, "key/revoke", %{"name" => id}) do
      {:ok, _} ->
        keys =
          Enum.reject(socket.assigns.keys, &(&1.name == id))

        {:noreply,
         socket
         |> assign(:keys, keys)
         |> put_flash(:info, "API key revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{error_message(reason)}")}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket), do: rotate(socket, id)

  # Minting and rotating a key each need a fresh confirmation: asked for
  # through the system layer, and repeated from `system_layer_repeat/4`
  # once confirmed.
  defp create(socket, args) do
    case SystemLayer.call(socket, :key_create, "key/create", args) do
      {:ok, key, socket} ->
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

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to create: #{error_message(reason)}")}
    end
  end

  defp rotate(socket, name) do
    case SystemLayer.call(socket, {:key_rotate, name}, "key/rotate", %{"name" => name}) do
      {:ok, key, socket} ->
        {:noreply,
         socket
         |> assign(:new_key, key)
         |> put_flash(:info, "API key rotated. Copy the new key now.")}

      {:asked, socket} ->
        {:noreply, socket}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate: #{error_message(reason)}")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # Paint the frame first; the rows arrive in :load so the first
    # connected render is never blocked on the fetch.
    if connected?(socket), do: send(self(), :load)
    {:noreply, socket}
  end

  # A change this page asked for was confirmed: made again, once.
  @impl PrismWeb.SystemLayer.Hook
  def system_layer_repeat(:key_create, _tool, args, socket), do: create(socket, args)
  def system_layer_repeat({:key_rotate, name}, _tool, _args, socket), do: rotate(socket, name)

  @impl true
  def handle_info(:load, socket) do
    {:noreply, socket |> fetch_keys() |> assign(:loading, false)}
  end

  def handle_info(%Cyfr.Bus.ApiKeys{}, socket) do
    {:noreply, fetch_keys(socket)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
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
            <.button variant="secondary" size="sm" phx-click="dismiss_key">
              Done
            </.button>
          </div>
        </div>
      </.card>

      <!-- Create form -->
      <.card :if={@show_create}>
        <form id="api-key-form" phx-submit="create" phx-change="form_changed" class="space-y-4">
          <p class="text-sm text-gray-400">
            A key acts as you in this athanor, within what you give it here. What it may do
            is fixed once it is made: to change it, make a new key and revoke this one.
          </p>
          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
            <.input name="name" value={@key_name} required placeholder="my-api-key" />
          </div>

          <div>
            <label class="block text-xs text-gray-500 uppercase mb-2">What it may do</label>
            <div class="flex flex-wrap gap-2 mb-3">
              <.button
                :for={{name, _scopes} <- @presets}
                type="button"
                variant="secondary"
                size="sm"
                phx-click="preset"
                phx-value-preset={name}
              >
                {name}
              </.button>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <label
                :for={{scope, what} <- @permissions}
                class="flex items-center gap-2 rounded-lg bg-gray-800/50 px-3 py-2 text-sm cursor-pointer hover:bg-gray-800"
              >
                <input
                  type="checkbox"
                  checked={scope in @checked_scopes}
                  phx-click="toggle_scope"
                  phx-value-scope={scope}
                  class="rounded border-gray-600 bg-gray-700 text-blue-500 focus:ring-blue-500 focus:ring-offset-0"
                />
                <span class="text-gray-300">{what}</span>
              </label>
            </div>
          </div>

          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Only these tools</label>
            <.input name="tools" value={@key_tools} placeholder="c:local.my-tool, c:local.other" />
            <p class="mt-1 text-xs text-gray-500">
              Leave empty and the key runs any tool you granted.
            </p>
          </div>

          <%!-- A key with nothing ticked would hold the first preset's permissions. --%>
          <.button type="submit" disabled={@checked_scopes == []}>Create API Key</.button>
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
          <:col :let={key} label="What it may do">
            <span :if={key[:scope_unreadable]} class="text-red-400">
              Cannot be used: what this key may do could not be read. Revoke it and make a new key.
            </span>
            <span :if={!key[:scope_unreadable]}>{format_scope(key[:scope], @permissions)}</span>
          </:col>
          <:col :let={key} label="Tools">{format_tools(key[:tools])}</:col>
          <:col :let={key} label="Created">{key[:created_at] || "-"}</:col>
          <:col :let={key} label="Actions">
            <div class="flex gap-2">
              <.button
                variant="ghost"
                phx-click="rotate"
                phx-value-id={key.name}
              >
                Rotate
              </.button>
              <.button
                variant="ghost"
                phx-click="revoke"
                phx-value-id={key.name}
                data-confirm="Are you sure?"
              >
                Revoke
              </.button>
            </div>
          </:col>
        </.table>
      </.card>

      <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
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

  # The tools field as the person typed it: names split on commas and
  # white space; the server checks each one.
  defp tools(nil), do: []
  defp tools(text), do: String.split(text, [",", " ", "\n", "\t"], trim: true)

  defp format_scope(scopes, permissions) when is_list(scopes) and scopes != [] do
    Enum.join(for({scope, what} <- permissions, scope in scopes, do: what), ", ")
  end

  defp format_scope(_scopes, _permissions), do: "nothing"

  defp format_tools(tools) when is_list(tools) and tools != [], do: Enum.join(tools, ", ")
  defp format_tools(_tools), do: "any tool you granted"
end
