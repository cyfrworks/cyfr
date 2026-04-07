defmodule PrismWeb.ShellLive do
  use PrismWeb, :live_view

  require Logger

  @moduledoc """
  Tincture browser for Prism shell.

  Sandboxed tinctures are loaded from `components/tinctures/` and communicate
  with the platform via the PostMessage bridge (IframeBridge hook + cyfr.js SDK).
  Tinctures have query-only bridge access (no general tool execution).
  """

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Tinctures")
      |> assign(:active_nav, "tinctures")
      |> assign(:active_tincture, nil)
      |> assign(:opened_tinctures, [])
      |> assign(:viewport, %{width: 1280, height: 800})
      |> assign(:tinctures, [])
      |> assign(:menu_open, nil)
      |> assign(:tooltip_open, nil)
      |> assign(:query_count, 0)
      |> assign(:query_window_start, System.monotonic_time(:second))

    socket =
      if connected?(socket) do
        load_tinctures(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # -- Tincture selection --

  @impl true
  def handle_event("select_tincture", %{"tincture" => tincture_id}, socket) do
    if Enum.any?(socket.assigns.tinctures, &(&1.id == tincture_id)) do
      socket =
        socket
        |> assign(:active_tincture, tincture_id)
        |> maybe_track_tincture(tincture_id)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # -- Refresh / register --

  @impl true
  def handle_event("refresh_tinctures", _params, socket) do
    ctx = socket.assigns.context
    Compendium.AutoIndexer.scan(Compendium.AutoIndexer.default_component_dirs(), ctx: ctx)
    Prism.TinctureRegistry.reload()
    socket = load_tinctures(socket)
    {:noreply, put_flash(socket, :info, "Tinctures registered and refreshed")}
  end

  # -- Tincture menu --

  @impl true
  def handle_event("toggle_tooltip", %{"tincture" => tincture_id}, socket) do
    tooltip_open = if socket.assigns.tooltip_open == tincture_id, do: nil, else: tincture_id
    {:noreply, assign(socket, tooltip_open: tooltip_open, menu_open: nil)}
  end

  def handle_event("close_tooltip", _params, socket) do
    {:noreply, assign(socket, :tooltip_open, nil)}
  end

  def handle_event("toggle_menu", %{"tincture" => tincture_id}, socket) do
    menu_open = if socket.assigns.menu_open == tincture_id, do: nil, else: tincture_id
    {:noreply, assign(socket, menu_open: menu_open, tooltip_open: nil)}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, :menu_open, nil)}
  end

  def handle_event("copy_url", %{"tincture" => tincture_id}, socket) do
    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id))

    if tincture do
      url = "#{EmissaryWeb.Endpoint.url()}/t/#{tincture.publisher}/#{tincture.name}"

      {:noreply,
       socket
       |> assign(:menu_open, nil)
       |> push_event("cyfr:copy-to-clipboard", %{text: url})
       |> put_flash(:info, "URL copied to clipboard")}
    else
      {:noreply, assign(socket, :menu_open, nil)}
    end
  end

  def handle_event("toggle_visibility", %{"tincture" => tincture_id}, socket) do
    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == tincture_id))

    if tincture do
      ctx = socket.assigns.context
      new_public = !tincture.public

      case Sanctum.TinctureVisibility.set_public(ctx, tincture.publisher, tincture.name, new_public) do
        :ok ->
          tinctures =
            Enum.map(socket.assigns.tinctures, fn t ->
              if t.id == tincture_id do
                url = build_tincture_url(socket, t.publisher, t.name, new_public)
                %{t | public: new_public, url: url}
              else
                t
              end
            end)

          {:noreply, socket |> assign(:tinctures, tinctures) |> assign(:menu_open, nil)}

        {:error, _reason} ->
          {:noreply, assign(socket, :menu_open, nil)}
      end
    else
      {:noreply, assign(socket, :menu_open, nil)}
    end
  end

  # -- Responsive --

  def handle_event("viewport_changed", %{"width" => w, "height" => h}, socket) do
    {:noreply, assign(socket, :viewport, %{width: w, height: h})}
  end

  # -- iframe bridge --

  def handle_event("iframe_message", %{"window_id" => window_id, "message" => msg}, socket) do
    handle_iframe_message(socket, window_id, msg)
  end

  def handle_event("iframe_message", _params, socket) do
    {:noreply, socket}
  end

  # -- Tracking helpers --

  defp maybe_track_tincture(socket, tincture_id) do
    if tincture_id in socket.assigns.opened_tinctures do
      socket
    else
      assign(socket, :opened_tinctures, socket.assigns.opened_tinctures ++ [tincture_id])
    end
  end

  # -- Private Helpers --

  defp load_tinctures(socket) do
    ctx = socket.assigns.context

    tinctures =
      Prism.TinctureRegistry.list_tinctures(ctx)
      |> Enum.map(fn t ->
        public = Sanctum.TinctureVisibility.public?(ctx, t.publisher, t.name)

        %{
          id: "iframe_#{t.name}",
          name: t.name,
          publisher: t.publisher,
          title: t.title,
          icon: t.icon,
          url: build_tincture_url(socket, t.publisher, t.name, public),
          dir: t.dir,
          manifest: t.manifest,
          public: public
        }
      end)

    assign(socket, :tinctures, tinctures)
  end

  defp build_tincture_url(socket, publisher, name, _public?) do
    base = EmissaryWeb.Endpoint.url() <> Cyfr.TinctureHelpers.entry_url(publisher, name, "index.html")
    "#{base}?_session=#{socket.assigns.session_token}"
  end

  defp handle_iframe_message(socket, window_id, %{"type" => "cyfr:request"} = msg) do
    tincture = Enum.find(socket.assigns.tinctures, &(&1.id == window_id))

    if tincture do
      case msg["action"] do
        "query" ->
          handle_query(socket, window_id, tincture, msg)

        "set_title" ->
          tinctures =
            Enum.map(socket.assigns.tinctures, fn t ->
              if t.id == window_id,
                do: Map.put(t, :title, msg["payload"]["title"] || t.title),
                else: t
            end)

          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}

          {:noreply,
           socket
           |> assign(:tinctures, tinctures)
           |> push_event("iframe_response:#{window_id}", response)}

        "close" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          socket = push_event(socket, "iframe_response:#{window_id}", response)

          opened = List.delete(socket.assigns.opened_tinctures, window_id)

          active =
            if socket.assigns.active_tincture == window_id do
              List.first(opened)
            else
              socket.assigns.active_tincture
            end

          {:noreply,
           socket
           |> assign(:opened_tinctures, opened)
           |> assign(:active_tincture, active)}

        "ready" ->
          response = %{type: "cyfr:response", id: msg["id"], result: %{ok: true}}
          {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

        "get_context" ->
          response = %{
            type: "cyfr:response",
            id: msg["id"],
            result: %{tincture_id: tincture.id, window_id: window_id}
          }

          {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

        _ ->
          error_response = %{
            type: "cyfr:response",
            id: msg["id"],
            error: "unknown_action"
          }

          {:noreply, push_event(socket, "iframe_response:#{window_id}", error_response)}
      end
    else
      if msg["id"] do
        response = %{type: "cyfr:response", id: msg["id"], error: "window_not_found"}
        {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}
      else
        {:noreply, socket}
      end
    end
  end

  defp handle_iframe_message(socket, _window_id, _msg), do: {:noreply, socket}

  # Max queries per minute for authenticated shell iframe bridge.
  # Double the public rate (60/min) since these are authenticated users.
  @shell_query_limit 120
  @shell_query_window_seconds 60

  defp handle_query(socket, window_id, tincture, msg) do
    query_name = get_in(msg, ["payload", "name"])
    query_params = get_in(msg, ["payload", "params"]) || %{}

    tincture_record = %{
      name: tincture.name,
      publisher: tincture.publisher,
      dir: tincture.dir,
      manifest: tincture.manifest
    }

    now = System.monotonic_time(:second)
    elapsed = now - socket.assigns.query_window_start

    {count, window_start} =
      if elapsed >= @shell_query_window_seconds do
        {0, now}
      else
        {socket.assigns.query_count, socket.assigns.query_window_start}
      end

    cond do
      count >= @shell_query_limit ->
        response = %{type: "cyfr:response", id: msg["id"], error: "rate_limited"}
        {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

      is_nil(query_name) ->
        response = %{type: "cyfr:response", id: msg["id"], error: "missing query name"}
        {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

      not Sanctum.TinctureAccess.can_query?(tincture_record, query_name) ->
        response = %{type: "cyfr:response", id: msg["id"], error: "unknown query"}
        {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

      true ->
        socket =
          socket
          |> assign(:query_count, count + 1)
          |> assign(:query_window_start, window_start)

        manifest = tincture.manifest || %{}

        case Arca.TinctureData.Schema.parse_manifest_schema(manifest) do
          {:ok, parsed_schema} ->
            query_def = parsed_schema.queries[query_name]
            ctx = socket.assigns.context

            case Arca.TinctureData.QueryRunner.execute(
                   ctx,
                   tincture_record,
                   query_name,
                   query_def,
                   query_params
                 ) do
              {:ok, result} ->
                response = %{type: "cyfr:response", id: msg["id"], result: result}
                {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}

              {:error, reason} ->
                Logger.warning("[ShellLive] query error for #{tincture.name}/#{query_name}: #{inspect(reason)}")
                response = %{type: "cyfr:response", id: msg["id"], error: "query_error"}
                {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}
            end

          {:error, reason} ->
            Logger.warning("[ShellLive] schema error for #{tincture.name}: #{inspect(reason)}")
            response = %{type: "cyfr:response", id: msg["id"], error: "schema_error"}
            {:noreply, push_event(socket, "iframe_response:#{window_id}", response)}
        end
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[ShellLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div id="shell" class="h-full -m-4 lg:-m-8 relative" phx-hook="ShellViewport">
      <%!-- Tincture iframes --%>
      <%= for tincture_id <- @opened_tinctures do %>
        <% tincture = Enum.find(@tinctures, &(&1.id == tincture_id)) %>
        <div
          :if={tincture}
          class={[
            "absolute inset-0 flex flex-col",
            if(tincture_id != @active_tincture, do: "hidden")
          ]}
        >
          <iframe
            id={"iframe_#{tincture_id}"}
            src={tincture.url}
            sandbox="allow-scripts"
            class="w-full h-full border-0"
            phx-hook="IframeBridge"
            data-window-id={tincture_id}
          />
        </div>
      <% end %>

      <%!-- Empty state --%>
      <div
        :if={@active_tincture == nil}
        class="flex flex-col items-center justify-center h-full text-gray-500 gap-4"
      >
        <.icon name="grid" class="w-12 h-12 opacity-20" />
        <p class="text-sm">
          {if @tinctures == [], do: "No tinctures installed", else: "Select a tincture from the sidebar"}
        </p>
      </div>
    </div>
    <%!-- Description tooltip (fixed, outside sidebar overflow) --%>
    <% tooltip_tincture = @tooltip_open && Enum.find(@tinctures, &(&1.id == @tooltip_open)) %>
    <div
      :if={tooltip_tincture}
      id="tincture-tooltip"
      phx-hook="Tooltip"
      phx-click-away="close_tooltip"
      data-anchor={"info-btn-#{tooltip_tincture.id}"}
      class="fixed z-[100] w-52 rounded-lg bg-gray-800 border border-gray-700 shadow-xl px-3 py-2"
    >
      <p class="text-xs text-gray-300">{tooltip_tincture.title}</p>
    </div>
    """
  end

end
