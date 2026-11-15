# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TipsLive do
  @moduledoc """
  Tips: short answers to what the first screen and setup leave out, one
  card each, in every UI mode. Each card's "Show me" is a link to the
  place it describes, a page of the athanor's or the desktop with its
  chooser open, so a tip opens nothing a person could not open
  themselves. The page holds words and links only: it reads and stores
  nothing.
  """

  use PrismWeb, :live_view

  # Each tip's "Show me", by the tip's id: a path under the athanor,
  # linked through `PrismWeb.Nav.href/2`.
  @show_me [
    {"desktop", "/?shell=desktops"},
    {"modes", "/settings"},
    {"people", "/settings"},
    {"keys", "/api-keys"},
    {"failures", "/executions"}
  ]

  @doc "Each tip's id and where its \"Show me\" goes, in the page's order."
  @spec show_me() :: [{String.t(), String.t()}]
  def show_me, do: @show_me

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tips")
     |> assign(:active_nav, "tips")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Tips" />
      <p class="text-sm text-gray-400">
        Short answers to what CYFR does not show at first. Each "Show me" opens the place a tip
        talks about.
      </p>

      <.tip id="desktop" title="Change your desktop" athanor_route={@athanor_route}>
        <p>
          <strong>Desktops</strong>, on the shelf along the bottom, opens <strong>Choose your desktop</strong>: pick one and it takes the place of the one you are
          looking at, with your open apps kept. Each app opens as a window, a tile at an edge or
          full, and stays where you leave it.
        </p>
        <p>
          To have Aqua change it, open your Aqua from the shelf (Ctrl+J) and say what you want to
          see. Aqua writes a new version and shows it on a card that names what it reads; nothing
          changes until you approve it.
        </p>
      </.tip>

      <.tip id="modes" title="Two modes: lite and dev" athanor_route={@athanor_route}>
        <p>
          <strong>lite</strong>
          shows the pages for everyday work. <strong>dev</strong>
          adds a side menu with the pages for building and looking closer: Executions, Components,
          Builds and more. What you may do is the same in both, and a page's link opens
          it in either.
        </p>
        <p>
          Everyone starts in lite but the administrator, who starts in dev. Change yours in
          Settings, under Preferences.
        </p>
      </.tip>

      <.tip id="people" title="Letting people in" athanor_route={@athanor_route}>
        <p>
          An administrator lets people into this CYFR from Settings:
          <strong>Create an invitation link</strong>
          makes a link that lets one new person in, once, within seven days, and the
          <strong>Server allowlist</strong>
          decides who may sign in at all.
        </p>
        <p>
          Anyone brings people into a thread from the thread itself: <strong>Add someone by name</strong>, or
          <strong>Invitation link</strong>
          for someone who is not here yet.
        </p>
      </.tip>

      <.tip id="keys" title="API keys and scripts" athanor_route={@athanor_route}>
        <p>
          A script, a CI job or the <code>cyfr</code>
          command line acts as you with an API key. On API Keys, <strong>Create Key</strong>, name
          it and tick what it may do; copy the key when it is shown, since it is shown only once.
          Revoke it there when the script no longer needs it.
        </p>
        <p>
          Give the key to the script: <code>cyfr</code>
          reads it from <code>CYFR_TOKEN</code>
          or <code>--token</code>, and a script calling CYFR over HTTP sends it as
          <code>Authorization: Bearer</code>
          followed by the key.
        </p>
      </.tip>

      <.tip id="failures" title="When something fails" athanor_route={@athanor_route}>
        <p>
          Executions shows recent runs, newest first, with their <strong>Status</strong>,
          <strong>Duration</strong>
          and when each <strong>Started</strong>. Open a failed one to
          read its <strong>Error</strong>, what went wrong in the run's own words.
        </p>
        <p>Executions is in dev's side menu, and "Show me" opens it in lite too.</p>
      </.tip>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :athanor_route, :string, default: nil
  slot :inner_block, required: true

  defp tip(assigns) do
    assigns = assign(assigns, :to, show_me_path(assigns.id))

    ~H"""
    <.card>
      <section id={"tip-" <> @id} class="space-y-3">
        <h3 class="text-sm font-medium text-white">{@title}</h3>
        <div class="space-y-2 text-sm text-gray-300">
          {render_slot(@inner_block)}
        </div>
        <.link
          navigate={PrismWeb.Nav.href(@to, @athanor_route)}
          id={"tip-" <> @id <> "-show"}
          class="inline-block text-sm text-blue-400 hover:underline"
        >
          Show me
        </.link>
      </section>
    </.card>
    """
  end

  defp show_me_path(id) do
    {^id, path} = List.keyfind(@show_me, id, 0)
    path
  end
end
