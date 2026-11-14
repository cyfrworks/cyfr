# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalLive do
  @moduledoc """
  Fetches legal Markdown through `registry/legal_page` and renders it in
  the client, including terms, privacy, acceptable use and content policies.

  Each tab triggers a fresh fetch (cached server-side at 5min by the
  upstream Cache-Control); markdown is rendered by the
  `MarkdownContent` JS hook. The pages are the registry's this deployment
  names (`Sanctum.registry_url/0`, cyfr.run unless configured), so a link
  in them that names a path alone is made absolute against its address
  before it is rendered: on this CYFR such a path names nothing.

  The Privacy tab opens with a paragraph of this CYFR's own, saying who
  can read what is kept here, before cyfr.run's policy.
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
      |> assign(:publisher, Sanctum.registry_url())

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
         |> assign(:markdown, absolute_links(md))
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
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h2 class="text-lg font-semibold text-white">Legal</h2>
        <p class="text-sm text-gray-400 mt-1">
          Policy text published by {@publisher}. Lawyer-drafted final copy
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

      <section
        :if={@active_tab == "privacy"}
        id="who-reads"
        class="rounded-lg border border-gray-800 bg-gray-900/60 p-4 text-sm text-gray-300"
      >
        <h3 class="text-base font-semibold text-white mb-2">Who can read what on this CYFR</h3>
        <p>
          Whoever runs the machine this CYFR runs on can read what it keeps there: your files,
          your vault's values and your messages among them. The people of a thread see its
          messages, and leaving a thread does not take yours out of it. A key someone shares
          with you is used for you and never shown to you. What you ask AQUA goes to the model
          provider whose key AQUA uses. The policy below is {@publisher}'s, for your account
          and the components you publish there.
        </p>
      </section>

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

  # A link that names a path alone, in Markdown or in HTML, made absolute
  # against the address of the registry whose pages these are.
  defp absolute_links(markdown) do
    base = Sanctum.registry_base_url(Sanctum.registry_url())

    markdown
    |> String.replace(~r{\]\((/[^/)\s][^)\s]*)}, "](" <> base <> "\\1")
    |> String.replace(~r{href="(/[^/"][^"]*)"}, ~s(href=") <> base <> ~s(\\1"))
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
