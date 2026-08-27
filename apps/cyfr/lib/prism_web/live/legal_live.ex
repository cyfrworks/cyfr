# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalLive do
  @moduledoc """
  Legal copy browser. Fetches markdown from cyfr.run via the
  `registry/legal_page` MCP action and renders it in-client. Closed-
  platform posture: cyfr.run no longer hosts /legal/* HTML pages, so the
  cyfr client is the canonical disclosure surface for ToS / Privacy /
  AUP / Content Policy / DMCA / Cookies / Transparency.

  Each tab triggers a fresh fetch (cached server-side at 5min by the
  upstream Cache-Control); markdown is rendered by the existing
  `MarkdownContent` JS hook (same one AgentLive uses).
  """

  use PrismWeb, :live_view

  require Logger

  @tabs [
    {"terms", "Terms"},
    {"privacy", "Privacy"},
    {"aup", "AUP"},
    {"content-policy", "Content Policy"},
    {"dmca", "DMCA"},
    {"cookies", "Cookies"},
    {"transparency", "Transparency"}
  ]

  @impl true
  def mount(params, _session, socket) do
    initial = Map.get(params, "page", "terms") |> normalize_tab()

    socket =
      socket
      |> assign(:page_title, "Legal")
      |> assign(:active_nav, "legal")
      |> assign(:tabs, @tabs)
      |> assign(:active_tab, initial)
      |> assign(:title, "")
      |> assign(:markdown, "")
      |> assign(:loading, true)
      |> assign(:error, nil)

    if connected?(socket) do
      send(self(), {:load, initial})
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("select-tab", %{"name" => name}, socket) do
    name = normalize_tab(name)

    {:noreply,
     socket
     |> assign(:active_tab, name)
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> tap(fn _ -> send(self(), {:load, name}) end)}
  end

  @impl true
  def handle_info({:load, name}, socket) do
    case call_tool(socket, "registry/legal_page", %{"name" => name}) do
      {:ok, %{"name" => _, "title" => title, "content_markdown" => md}} ->
        {:noreply,
         socket
         |> assign(:title, title)
         |> assign(:markdown, md)
         |> assign(:loading, false)
         |> assign(:error, nil)}

      {:ok, _other} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, "unexpected response shape")}

      {:error, err} ->
        Logger.warning("[LegalLive] load #{name} failed: #{inspect(err)}")

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, error_message(err))}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[LegalLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-lg font-semibold text-white">Legal</h2>
        <p class="text-sm text-gray-400 mt-1">
          Policy text published by cyfr.run. Lawyer-drafted final copy
          replaces placeholders before public launch.
        </p>
      </div>

      <nav class="flex gap-2 flex-wrap border-b border-gray-800 pb-2">
        <button
          :for={{name, label} <- @tabs}
          type="button"
          phx-click="select-tab"
          phx-value-name={name}
          class={"text-xs px-3 py-1.5 rounded-lg border " <> tab_class(name == @active_tab)}
        >
          {label}
        </button>
      </nav>

      <div :if={@loading} class="text-sm text-gray-500">Loading…</div>

      <div
        :if={@error}
        class="rounded-lg border border-red-900/40 bg-red-950/20 p-3 text-xs text-red-300"
      >
        Couldn't load page: {@error}
      </div>

      <div :if={!@loading && !@error}>
        <h3 class="text-base font-semibold text-white mb-3">{@title}</h3>
        <div
          id={"legal-md-" <> @active_tab}
          phx-hook="MarkdownContent"
          phx-update="ignore"
          data-raw-content={@markdown}
          class="text-gray-300 prose prose-invert max-w-none"
        >
        </div>
      </div>
    </div>
    """
  end

  defp tab_class(true),
    do: "bg-gray-800 text-white border-gray-700"

  defp tab_class(false),
    do: "text-gray-400 hover:text-white border-gray-800 hover:border-gray-700"

  defp normalize_tab(name) when is_binary(name) do
    case Enum.find(@tabs, fn {n, _} -> n == name end) do
      {n, _} -> n
      nil -> "terms"
    end
  end

  defp normalize_tab(_), do: "terms"

end
