# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WebhooksLive do
  @moduledoc """
  Inbound webhooks management dashboard.

  Mirrors the API keys page in posture: list/create/update/revoke/rotate
  via the `webhook` MCP tool. Secrets are surfaced exactly once on create
  or rotate via the same `@new_secret` reveal card; never thereafter.

  The webhook URL is rendered against `CYFR_PUBLIC_URL` so users can copy
  the full URL into their external service (GitHub, Stripe, etc).
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS
  require Logger

  @default_signature_header "x-cyfr-signature"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Webhooks")
     |> assign(:active_nav, "webhooks")
     |> assign(:webhooks, [])
     |> assign(:loading, true)
     |> assign(:show_form, false)
     |> assign(:editing_name, nil)
     |> assign(:form_name, "")
     |> assign(:form_target_ref, "")
     |> assign(:form_signature_header, @default_signature_header)
     |> assign(:form_description, "")
     |> assign(:form_rate_limit, "")
     |> assign(:form_input_template, "{}")
     |> assign(:form_error, nil)
     |> assign(:new_secret, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:webhooks", ctx))
      send(self(), :load_data)
      {:noreply, assign(socket, :loading, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> fetch_webhooks() |> assign(:loading, false)}
  end

  def handle_info(:webhooks_changed, socket) do
    {:noreply, fetch_webhooks(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[WebhooksLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Form events
  # ============================================================================

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply, reset_form(socket, !socket.assigns.show_form, nil)}
  end

  def handle_event("edit", %{"id" => name}, socket) do
    case Enum.find(socket.assigns.webhooks, &(to_string(&1[:name] || &1["name"]) == name)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Webhook not found")}

      hook ->
        {:noreply,
         socket
         |> assign(:show_form, true)
         |> assign(:editing_name, name)
         |> assign(:form_name, hook[:name] || "")
         |> assign(:form_target_ref, hook[:target_ref] || "")
         |> assign(:form_signature_header, hook[:signature_header] || @default_signature_header)
         |> assign(:form_description, hook[:description] || "")
         |> assign(:form_rate_limit, hook[:rate_limit] || "")
         |> assign(:form_input_template, encode_template_for_form(hook[:input_template]))
         |> assign(:form_error, nil)
         |> assign(:new_secret, nil)}
    end
  end

  def handle_event("form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:form_name, params["name"] || socket.assigns.form_name)
     |> assign(:form_target_ref, params["target_ref"] || socket.assigns.form_target_ref)
     |> assign(
       :form_signature_header,
       params["signature_header"] || socket.assigns.form_signature_header
     )
     |> assign(:form_description, params["description"] || socket.assigns.form_description)
     |> assign(:form_rate_limit, params["rate_limit"] || socket.assigns.form_rate_limit)
     |> assign(
       :form_input_template,
       params["input_template"] || socket.assigns.form_input_template
     )}
  end

  def handle_event("submit", params, socket) do
    case decode_template_param(params["input_template"]) do
      {:ok, template_map} ->
        if socket.assigns.editing_name do
          submit_update(socket, params, template_map)
        else
          submit_create(socket, params, template_map)
        end

      {:error, msg} ->
        {:noreply, assign(socket, :form_error, msg)}
    end
  end

  def handle_event("revoke", %{"id" => name}, socket) do
    case call_tool(socket, "webhook/revoke", %{"name" => name}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> fetch_webhooks()
         |> put_flash(:info, "Webhook revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{inspect(reason)}")}
    end
  end

  def handle_event("rotate", %{"id" => name}, socket) do
    case call_tool(socket, "webhook/rotate", %{"name" => name}) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:new_secret, %{
           name: name,
           secret: extract(result, :secret),
           url: extract(result, :url)
         })
         |> put_flash(:info, "Secret rotated. Copy the new secret now.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate: #{inspect(reason)}")}
    end
  end

  # ============================================================================
  # Submission helpers
  # ============================================================================

  defp submit_create(socket, params, template_map) do
    args = build_args(params, template_map)

    case call_tool(socket, "webhook/create", args) do
      {:ok, result} ->
        {:noreply,
         socket
         |> reset_form(false, nil)
         |> assign(:new_secret, %{
           name: extract(result, :name),
           secret: extract(result, :secret),
           url: extract(result, :url)
         })
         |> fetch_webhooks()
         |> put_flash(:info, "Webhook created. Copy the secret now — it won't be shown again.")}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, format_tool_error(reason))}
    end
  end

  defp submit_update(socket, params, template_map) do
    args = build_args(params, template_map) |> Map.put("name", socket.assigns.editing_name)

    case call_tool(socket, "webhook/update", args) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> reset_form(false, nil)
         |> fetch_webhooks()
         |> put_flash(:info, "Webhook updated.")}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, format_tool_error(reason))}
    end
  end

  defp build_args(params, template_map) do
    %{
      "name" => params["name"],
      "target_ref" => params["target_ref"],
      "input_template" => template_map,
      "signature_header" => default_or_value(params["signature_header"]),
      "description" => default_or_value(params["description"]),
      "rate_limit" => default_or_value(params["rate_limit"])
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp default_or_value(nil), do: nil
  defp default_or_value(""), do: nil
  defp default_or_value(value), do: value

  defp reset_form(socket, show, _name) do
    socket
    |> assign(:show_form, show)
    |> assign(:editing_name, nil)
    |> assign(:form_name, "")
    |> assign(:form_target_ref, "")
    |> assign(:form_signature_header, @default_signature_header)
    |> assign(:form_description, "")
    |> assign(:form_rate_limit, "")
    |> assign(:form_input_template, "{}")
    |> assign(:form_error, nil)
  end

  defp decode_template_param(nil), do: {:ok, %{}}
  defp decode_template_param(""), do: {:ok, %{}}

  defp decode_template_param(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} ->
        if Map.has_key?(map, "_webhook"),
          do: {:error, "input_template must not contain reserved key '_webhook'"},
          else: {:ok, map}

      {:ok, _} ->
        {:error, "input_template must be a JSON object"}

      {:error, _} ->
        {:error, "input_template is not valid JSON"}
    end
  end

  defp encode_template_for_form(nil), do: "{}"
  defp encode_template_for_form(%{} = map), do: Jason.encode!(map, pretty: true)
  defp encode_template_for_form(other) when is_binary(other), do: other
  defp encode_template_for_form(_), do: "{}"

  defp fetch_webhooks(socket) do
    list =
      case call_tool(socket, "webhook/list", %{}) do
        {:ok, %{webhooks: webhooks}} ->
          normalize_list(webhooks)

        {:ok, list} when is_list(list) ->
          normalize_list(list)

        other ->
          Logger.warning("[WebhooksLive] webhook/list failed: #{inspect(other)}")
          []
      end

    assign(socket, :webhooks, list)
  end

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &normalize_webhook/1)
  defp normalize_list(other), do: other

  defp normalize_webhook(%{} = map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_webhook(other), do: other

  defp extract(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp extract(_, _), do: nil

  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(reason), do: inspect(reason)

  # Display the URL exactly as the server returned it. The server uses
  # `Application.get_env(:cyfr, :public_url)` to build a full URL when set,
  # or falls back to a path. The LiveView never reconstructs it.
  defp display_url(%{url: url}) when is_binary(url) and url != "", do: url
  defp display_url(%{slug: slug}) when is_binary(slug) and slug != "", do: "/hooks/" <> slug
  defp display_url(_), do: ""

  defp path_only?(url) when is_binary(url), do: String.starts_with?(url, "/")
  defp path_only?(_), do: true

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Webhooks">
        <:actions>
          <.button phx-click="toggle_create">
            {if @show_form && is_nil(@editing_name), do: "Cancel", else: "Create Webhook"}
          </.button>
        </:actions>
      </.page_header>
      
    <!-- New / rotated secret reveal -->
      <.card :if={@new_secret}>
        <div class="space-y-2">
          <p class="text-sm text-yellow-400 font-medium">
            Copy this secret now. It will not be shown again.
          </p>
          <div :if={@new_secret[:url]}>
            <label class="block text-xs text-gray-500 uppercase mb-1">Webhook URL</label>
            <code class="block bg-gray-950 rounded p-3 text-sm text-blue-300 font-mono break-all">
              {@new_secret[:url]}
            </code>
            <p :if={path_only?(@new_secret[:url])} class="text-xs text-gray-500 mt-1">
              Set <code>CYFR_PUBLIC_URL</code> on the server to display the full URL.
            </p>
          </div>
          <label class="block text-xs text-gray-500 uppercase mb-1 mt-2">Secret</label>
          <div class="flex items-start gap-2">
            <code class="flex-1 block bg-gray-950 rounded p-3 text-sm text-green-400 font-mono break-all">
              {@new_secret[:secret]}
            </code>
            <.button
              variant="secondary"
              size="sm"
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: @new_secret[:secret] || ""})}
            >
              Copy
            </.button>
          </div>
        </div>
      </.card>
      
    <!-- Create / Edit form -->
      <.card :if={@show_form}>
        <form phx-submit="submit" phx-change="form_changed" class="space-y-4">
          <div :if={@form_error} class="text-sm text-red-400">{@form_error}</div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Name</label>
              <.input
                name="name"
                value={@form_name}
                required
                placeholder="github-push"
                disabled={!is_nil(@editing_name)}
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Target component</label>
              <.input
                name="target_ref"
                value={@form_target_ref}
                required
                placeholder="f:local.handle-github-push"
              />
            </div>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Signature header</label>
              <.input
                name="signature_header"
                value={@form_signature_header}
                placeholder="x-cyfr-signature"
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Rate limit</label>
              <.input name="rate_limit" value={@form_rate_limit} placeholder="100/1m" />
            </div>
          </div>

          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">Description</label>
            <.input name="description" value={@form_description} />
          </div>

          <div>
            <label class="block text-xs text-gray-500 uppercase mb-1">
              Input template (JSON object) — merged into the component invocation alongside the request envelope under the reserved key <code>_webhook</code>.
            </label>
            <textarea
              name="input_template"
              rows="6"
              class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white font-mono focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              phx-debounce="250"
            >{@form_input_template}</textarea>
          </div>

          <.button type="submit">
            {if is_nil(@editing_name), do: "Create webhook", else: "Save changes"}
          </.button>
        </form>
      </.card>
      
    <!-- List -->
      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @webhooks == []} class="py-8">
          <.empty_state message="No webhooks created" />
        </div>
        <.table :if={!@loading && @webhooks != []} id="webhooks" rows={@webhooks}>
          <:col :let={hook} label="Name">{hook[:name] || "-"}</:col>
          <:col :let={hook} label="Target">
            <code class="text-xs text-gray-300">{hook[:target_ref] || "-"}</code>
          </:col>
          <:col :let={hook} label="URL">
            <code class="text-xs text-blue-300 break-all">{display_url(hook)}</code>
          </:col>
          <:col :let={hook} label="Header">
            <code class="text-xs text-gray-400">{hook[:signature_header] || "-"}</code>
          </:col>
          <:col :let={hook} label="Created">{hook[:created_at] || "-"}</:col>
          <:col :let={hook} label="Actions">
            <div class="flex gap-2">
              <.button variant="ghost" phx-click="edit" phx-value-id={hook[:name]}>
                Edit
              </.button>
              <.button variant="ghost" phx-click="rotate" phx-value-id={hook[:name]}>
                Rotate
              </.button>
              <.button
                variant="ghost"
                phx-click="revoke"
                phx-value-id={hook[:name]}
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
end