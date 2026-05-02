defmodule PrismWeb.MyReportsLive do
  @moduledoc """
  "Reports" — lists abuse reports the current user has filed on
  cyfr.run. Read-only view that surfaces status (open / resolved /
  dismissed), SLA countdown, and the resolution note once moderators
  close a report.

  Data source: `registry.list-my-reports` MCP action → cyfr.run's
  `GET /v1/abuse-reports/mine`. Scoped server-side by the push-token
  identity tuple, so no additional filter is needed here.
  """

  use PrismWeb, :live_view

  require Logger

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :load)
    end

    {:ok,
     socket
     |> assign(:page_title, "Reports")
     |> assign(:active_nav, "reports")
     |> assign(:reports, [])
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:offset, 0)
     |> assign(:has_more, false)}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    send(self(), :load)
    {:noreply, socket |> assign(:loading, true) |> assign(:offset, 0)}
  end

  def handle_event("load-more", _params, socket) do
    send(self(), :load)
    {:noreply, assign(socket, :loading, true)}
  end

  @impl true
  def handle_info(:load, socket) do
    offset = socket.assigns.offset

    args = %{"limit" => @page_size, "offset" => offset}

    case call_tool(socket, "registry/list-my-reports", args) do
      {:ok, %{"reports" => reports}} when is_list(reports) ->
        existing = if offset == 0, do: [], else: socket.assigns.reports

        {:noreply,
         socket
         |> assign(:reports, existing ++ reports)
         |> assign(:offset, offset + length(reports))
         |> assign(:has_more, length(reports) >= @page_size)
         |> assign(:loading, false)
         |> assign(:error, nil)}

      {:ok, %{reports: reports}} when is_list(reports) ->
        # Atom-keyed map fallback (in case upstream normalises).
        existing = if offset == 0, do: [], else: socket.assigns.reports

        {:noreply,
         socket
         |> assign(:reports, existing ++ reports)
         |> assign(:offset, offset + length(reports))
         |> assign(:has_more, length(reports) >= @page_size)
         |> assign(:loading, false)
         |> assign(:error, nil)}

      {:ok, _unknown} ->
        {:noreply,
         socket
         |> assign(:reports, [])
         |> assign(:has_more, false)
         |> assign(:loading, false)
         |> assign(:error, nil)}

      {:error, err} ->
        Logger.warning("[MyReportsLive] load failed: #{inspect(err)}")

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, format_err(err))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-lg font-semibold text-white">My Reports</h2>
          <p class="text-sm text-gray-400 mt-1">
            Abuse reports you've filed on cyfr.run. Moderator outcomes show here
            once a report is resolved or dismissed.
          </p>
        </div>
        <button
          type="button"
          phx-click="reload"
          class="text-xs text-gray-400 hover:text-white border border-gray-700 rounded-lg px-3 py-1.5"
        >
          Refresh
        </button>
      </div>

      <div :if={@loading && @reports == []} class="text-sm text-gray-500">Loading…</div>

      <div
        :if={@error}
        class="rounded-lg border border-red-900/40 bg-red-950/20 p-3 text-xs text-red-300"
      >
        Couldn't load reports: {@error}
      </div>

      <div :if={!@loading && @reports == [] && !@error} class="text-sm text-gray-500">
        You haven't filed any reports yet.
      </div>

      <ul :if={@reports != []} class="divide-y divide-gray-800 rounded-lg border border-gray-800">
        <li :for={r <- @reports} class="p-4 space-y-2">
          <div class="flex items-start justify-between gap-3">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 text-sm">
                <span class="font-mono text-gray-300">{target(r)}</span>
                <span class={"px-2 py-0.5 rounded text-xs " <> badge_class(r["status"])}>
                  {r["status"]}
                </span>
              </div>
              <p class="text-xs text-gray-500 mt-1">
                {r["category"]} · filed {format_time(r["created_at"])}
              </p>
            </div>
            <div class="text-xs text-gray-500 text-right shrink-0">
              <span :if={r["sla_due_at"] && r["status"] == "open"}>
                SLA: {format_time(r["sla_due_at"])}
              </span>
              <span :if={r["resolved_at"]}>
                closed {format_time(r["resolved_at"])}
              </span>
            </div>
          </div>
          <p :if={r["resolution"]} class="text-xs text-gray-400 italic">
            Moderator note: {r["resolution"]}
          </p>
        </li>
      </ul>

      <div :if={@has_more} class="text-center">
        <button
          type="button"
          phx-click="load-more"
          disabled={@loading}
          class="text-xs text-gray-400 hover:text-white border border-gray-700 rounded-lg px-3 py-1.5 disabled:opacity-50"
        >
          <span :if={@loading}>Loading…</span>
          <span :if={!@loading}>Load more</span>
        </button>
      </div>
    </div>
    """
  end

  defp target(r) do
    cond do
      is_binary(r["target_namespace"]) and r["target_namespace"] != "" ->
        "ns:" <> r["target_namespace"]

      is_binary(r["target_component_id"]) and r["target_component_id"] != "" ->
        "comp:" <> r["target_component_id"]

      true ->
        "(no target)"
    end
  end

  defp badge_class("open"), do: "bg-amber-950/50 text-amber-300 border border-amber-900/40"
  defp badge_class("resolved"), do: "bg-emerald-950/50 text-emerald-300 border border-emerald-900/40"
  defp badge_class("dismissed"), do: "bg-gray-800 text-gray-400 border border-gray-700"
  defp badge_class(_), do: "bg-gray-800 text-gray-400 border border-gray-700"

  defp format_time(nil), do: ""

  defp format_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso
    end
  end

  defp format_time(_), do: ""

  defp format_err(err) when is_binary(err), do: err
  defp format_err(err), do: inspect(err)
end
