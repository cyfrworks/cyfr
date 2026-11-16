# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WorkspaceLive.BrowserLive do
  @moduledoc """
  A workspace thread's window in Aqua's browser, shown live in the middle
  of its layer (`PrismWeb.WorkspaceLive`), where the person may click and
  type in it while Aqua goes on with its work (C12). A view of its own,
  nested as the thread pane is, so the window's images come to a process
  of its own and the guard (`CyfrWeb.ContextGuard`) runs before each of
  them as before every event.

  While the person's browser holds a window for this thread it offers to
  show it; nothing streams before they ask. Asking is `browser.watch`
  through the gate as the person, from this view's own process, which
  the watch then belongs to: its images come here and go to this page's
  own socket alone, each drawn by the `WorkspaceStream` hook
  (`assets/js/hooks/workspace_stream.js`) before the next is sent, and
  the person's input goes back the same way to that window alone
  (`Opus.Browser.input/2`). Neither is kept in this view's assigns: an
  image passes straight to the page, and what the person types travels
  as an event parameter `Prima.Sanitizer.filter_parameters/0` names.

  The stream ends when the person closes it, when this page goes or its
  context no longer stands, when the browser setting goes off, when the
  browser stops, and when another page of the person's takes the window,
  which this page says, offering to take it back. A window Aqua has not
  opened, or closed, waits and shows as soon as Aqua opens it.
  """

  use PrismWeb, :live_view

  alias Cyfr.Bus.ThreadEvent

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket) do
    thread_id = session["thread_id"]

    socket =
      socket
      |> assign(:thread_id, thread_id)
      |> assign(:stream, nil)
      |> assign(:watch, nil)
      |> assign(:holder, nil)
      |> assign(:dropped, 0)
      |> assign(:window?, false)

    if connected?(socket) and is_binary(thread_id) do
      actor = Sanctum.Context.actor(socket.assigns.context)
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.thread(actor, thread_id))
    end

    {:ok, read_window(socket), layout: false}
  end

  # Whether the person's browser holds a window for this thread now.
  defp read_window(%{assigns: %{context: ctx, thread_id: id}} = socket) when is_binary(id),
    do: assign(socket, :window?, id in Opus.Browser.windows(ctx.athanor_id, ctx.user_id))

  defp read_window(socket), do: socket

  # ============================================================================
  # Events
  # ============================================================================

  # The person asks to see the window, at the size the hook measured.
  @impl true
  def handle_event("browser_watch", %{"width" => width, "height" => height}, socket)
      when is_integer(width) and is_integer(height) and is_nil(socket.assigns.watch) do
    args = %{
      "thread" => socket.assigns.thread_id,
      "width" => clamp(width),
      "height" => clamp(height)
    }

    case PrismWeb.Ops.call_tool(socket.assigns.context, "browser/watch", args) do
      {:ok, _watching} ->
        {:noreply, assign(socket, :stream, :starting)}

      {:error, reason} ->
        {:noreply, assign(socket, :stream, {:refused, Sanctum.Refusals.render(reason)})}
    end
  end

  def handle_event("browser_watch", _params, socket), do: {:noreply, socket}

  # The page drew image n: the next may come.
  def handle_event("browser_drawn", %{"n" => n}, %{assigns: %{watch: watch}} = socket)
      when is_integer(n) and watch != nil do
    :ok = Opus.Browser.seen(watch, n)
    {:noreply, socket}
  end

  # The person's clicks and keys, for the window this page watches, one
  # batch on its way at a time: the hook sends the next once it hears the
  # last was taken. What does not read as events, or comes while one is on
  # its way, is dropped and counted, and the hook is told it may go on.
  def handle_event(
        "browser_input",
        %{"browser_input" => events},
        %{assigns: %{watch: watch}} = socket
      )
      when is_list(events) and watch != nil do
    case Opus.Browser.input(watch, events) do
      :ok ->
        {:noreply, socket}

      {:error, _busy_or_bad} ->
        {:noreply,
         socket
         |> assign(:dropped, socket.assigns.dropped + 1)
         |> push_event("browser_input_taken", %{})}
    end
  end

  def handle_event("browser_input", _params, socket),
    do: {:noreply, push_event(socket, "browser_input_taken", %{})}

  def handle_event("browser_close", _params, socket), do: {:noreply, stop(socket)}

  # ============================================================================
  # The watch and the thread
  # ============================================================================

  @impl true
  def handle_info({Opus.Browser, {holder, _ref} = watch, :watching}, socket) do
    case socket.assigns do
      %{stream: :starting, watch: nil} ->
        Process.monitor(holder)
        {:noreply, socket |> assign(:watch, watch) |> assign(:holder, holder)}

      # The person closed it before it was admitted: it ends at once.
      _closed_meanwhile ->
        :ok = Opus.Browser.unwatch(watch)
        {:noreply, socket}
    end
  end

  def handle_info(
        {Opus.Browser, watch, {:image, n, %Opus.Programs.Output{bytes: jpeg}}},
        %{assigns: %{watch: watch}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:stream, :showing)
     |> push_event("browser_image", %{n: n, jpeg: Base.encode64(jpeg)})}
  end

  def handle_info({Opus.Browser, watch, :waiting}, %{assigns: %{watch: watch}} = socket),
    do: {:noreply, assign(socket, :stream, :waiting)}

  # The holder took the last batch of input: the hook may send the next.
  def handle_info({Opus.Browser, watch, :input_taken}, %{assigns: %{watch: watch}} = socket) do
    :ok = Opus.Browser.input_taken(watch)
    {:noreply, push_event(socket, "browser_input_taken", %{})}
  end

  # A stream that another page took leaves the window standing; any other
  # end is the browser stopping, which leaves no window to offer.
  def handle_info(
        {Opus.Browser, watch, {:ended, :replaced}},
        %{assigns: %{watch: watch}} = socket
      ),
      do: {:noreply, socket |> forget() |> assign(:stream, ended(:replaced))}

  def handle_info({Opus.Browser, watch, {:ended, reason}}, %{assigns: %{watch: watch}} = socket),
    do:
      {:noreply, socket |> forget() |> assign(:window?, false) |> assign(:stream, ended(reason))}

  # A watch this page no longer holds says nothing here.
  def handle_info({Opus.Browser, _another, _message}, socket), do: {:noreply, socket}

  def handle_info(
        {:DOWN, _monitor, :process, holder, _reason},
        %{assigns: %{holder: holder}} = socket
      ),
      do:
        {:noreply,
         socket |> forget() |> assign(:window?, false) |> assign(:stream, ended(:unavailable))}

  def handle_info(%ThreadEvent{kind: kind}, socket) when kind in [:tool_activity, :turn_finished],
    do: {:noreply, read_window(socket)}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp stop(%{assigns: %{watch: nil}} = socket), do: assign(socket, :stream, nil)

  defp stop(%{assigns: %{watch: watch}} = socket) do
    :ok = Opus.Browser.unwatch(watch)
    socket |> forget() |> assign(:stream, nil) |> read_window()
  end

  defp forget(%{assigns: %{watch: watch}} = socket) do
    # A watch that ended leaves nothing of its input behind in this process.
    if watch, do: :ok = Opus.Browser.input_taken(watch)
    socket |> assign(:watch, nil) |> assign(:holder, nil)
  end

  defp clamp(side), do: side |> max(16) |> min(4096)

  # What the page says when the stream ended.
  defp ended(:replaced), do: :taken
  defp ended(:turned_off), do: {:ended, Aqua.Providers.Browser.turned_off()}

  defp ended(_stopped),
    do: {:ended, "Aqua's browser stopped. It starts again when Aqua next uses it."}

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="workspace-browser"
      phx-hook="WorkspaceStream"
      data-stream={stream_name(@stream)}
      data-dropped={@dropped}
      class={if(@window? or @stream != nil, do: nil, else: "hidden")}
    >
      <div class="mb-2 flex items-center gap-2">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-gray-500">Browser</h2>
        <span class="flex-1"></span>
        <button
          :if={@stream in [:starting, :showing, :waiting]}
          id="workspace-browser-close"
          type="button"
          phx-click="browser_close"
          class="rounded-md px-2 py-0.5 text-xs text-gray-400 hover:bg-gray-800 hover:text-gray-200"
        >
          Stop showing
        </button>
      </div>

      <div :if={@stream == nil or match?({:ended, _}, @stream)} class="space-y-2">
        <p
          :if={match?({:ended, _}, @stream)}
          id="workspace-browser-ended"
          class="text-sm text-gray-400"
        >
          {elem(@stream, 1)}
        </p>
        <button
          :if={@window?}
          id="workspace-browser-watch"
          type="button"
          data-browser-watch
          class="rounded-md border border-gray-700 px-3 py-1.5 text-sm text-gray-200 hover:bg-gray-800"
        >
          Show Aqua's browser
        </button>
        <p :if={@window?} class="text-xs text-gray-500">
          See this thread's window live and use it yourself; Aqua carries on.
        </p>
      </div>

      <div :if={match?({:refused, _}, @stream)} id="workspace-browser-refused" class="space-y-2">
        <p class="text-sm text-gray-400">{elem(@stream, 1)}</p>
        <button
          type="button"
          data-browser-watch
          class="rounded-md border border-gray-700 px-3 py-1.5 text-sm text-gray-200 hover:bg-gray-800"
        >
          Try again
        </button>
      </div>

      <div :if={@stream == :taken} id="workspace-browser-taken" class="space-y-2">
        <p class="text-sm text-gray-400">
          This thread's browser is showing on another page of yours now.
        </p>
        <button
          type="button"
          data-browser-watch
          class="rounded-md border border-gray-700 px-3 py-1.5 text-sm text-gray-200 hover:bg-gray-800"
        >
          Show it here instead
        </button>
      </div>

      <p :if={@stream == :starting} id="workspace-browser-starting" class="text-sm text-gray-500">
        Opening Aqua's browser…
      </p>
      <p :if={@stream == :waiting} id="workspace-browser-waiting" class="text-sm text-gray-400">
        Aqua has no page open in this thread yet. It shows here as soon as Aqua opens one.
      </p>

      <%!-- The window, drawn by the hook: the page keeps its own drawing,
            so only the wrapper around it is shown or hidden from here. --%>
      <div id="workspace-browser-screen" class={if(@stream == :showing, do: nil, else: "hidden")}>
        <div id="workspace-browser-canvas" phx-update="ignore">
          <canvas
            tabindex="0"
            aria-label="Aqua's browser, this thread's window. Click or type to use it."
            class="block h-auto w-full touch-none rounded-md border border-gray-800 bg-black outline-none focus:border-blue-500"
          ></canvas>
        </div>
      </div>
    </div>
    """
  end

  defp stream_name(nil), do: "closed"
  defp stream_name(state) when is_atom(state), do: Atom.to_string(state)
  defp stream_name({state, _sentence}), do: Atom.to_string(state)
end
