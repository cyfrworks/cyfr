# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.EnforcementsLive do
  @moduledoc """
  Live feed of policy enforcement decisions.

  Each row is one `Arca.PolicyLog` record — an allow/deny outcome from one
  of the enforcement chokepoints (`Opus.Executor` pre-execution gate, the
  HTTP egress validators, or the tincture rate limiter). Telemetry from
  `[:cyfr, :sanctum, :policy, :decision]` fans out via PubSub so the table
  updates without a full reload.

  Click a row → jump to `/activities?request_id=…` to see the request-anchored
  causal chain (mcp_log + executions + every policy decision in that request).
  """

  use PrismWeb, :live_view

  require Logger

  @page_size 100

  @event_types [
    {"All", ""},
    {"policy_consultation", "policy_consultation"},
    {"domain_blocked", "domain_blocked"},
    {"method_blocked", "method_blocked"},
    {"scheme_blocked", "scheme_blocked"},
    {"rate_limit", "rate_limit"},
    {"request_size", "request_size"},
    {"denied", "denied"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:enforcement", ctx))
    end

    {:ok,
     socket
     |> assign(:page_title, "Enforcements")
     |> assign(:active_nav, "enforcements")
     |> assign(:logs, [])
     |> assign(:event_type_filter, nil)
     |> assign(:decision_filter, nil)
     |> assign(:component_filter, nil)
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:refresh_pending, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:event_type_filter, normalize_filter(params["event_type"]))
      |> assign(:decision_filter, normalize_filter(params["decision"]))
      |> assign(:component_filter, normalize_filter(params["component"]))

    if connected?(socket) do
      send(self(), :load_data)
      {:noreply, assign(socket, :loading, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "filter",
        %{"event_type" => et, "decision" => d, "component" => c},
        socket
      ) do
    socket =
      socket
      |> assign(:event_type_filter, normalize_filter(et))
      |> assign(:decision_filter, normalize_filter(d))
      |> assign(:component_filter, normalize_filter(c))

    {:noreply, push_patch(socket, to: filters_path(socket))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_logs(socket)}
  end

  @impl true
  def handle_info({:policy_decision, _metadata, _measurements}, socket),
    do: schedule_refresh(socket)

  def handle_info(:load_data, socket) do
    {:noreply, fetch_logs(socket)}
  end

  def handle_info(:do_refresh, socket) do
    {:noreply, socket |> assign(:refresh_pending, false) |> fetch_logs()}
  end

  def handle_info(msg, socket) do
    Logger.debug("[EnforcementLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Data
  # ============================================================================

  defp fetch_logs(socket) do
    args =
      %{"action" => "list", "limit" => @page_size}
      |> maybe_put("event_type", socket.assigns.event_type_filter)

    case call_tool(socket, "policy_log", args) do
      {:ok, %{logs: logs}} when is_list(logs) ->
        filtered = apply_client_filters(logs, socket.assigns)

        socket
        |> assign(:logs, filtered)
        |> assign(:loading, false)
        |> assign(:error, nil)

      {:error, reason} ->
        Logger.warning("[EnforcementLive] policy_log list failed: #{inspect(reason)}")

        socket
        |> assign(:logs, [])
        |> assign(:loading, false)
        |> assign(:error, "Failed to load enforcement: #{inspect(reason)}")
    end
  end

  # `policy_log/list` doesn't accept `decision` / `component_ref` filters on
  # the server side yet, so apply those client-side. With @page_size = 100 the
  # cost is negligible.
  defp apply_client_filters(logs, assigns) do
    logs
    |> Enum.filter(fn log ->
      decision_match?(log, assigns.decision_filter) and
        component_match?(log, assigns.component_filter)
    end)
  end

  defp decision_match?(_log, nil), do: true
  defp decision_match?(log, decision), do: f(log, :decision) == decision

  defp component_match?(_log, nil), do: true

  defp component_match?(log, query) do
    ref = f(log, :component_ref) || ""
    String.contains?(ref, query)
  end

  defp schedule_refresh(socket) do
    if socket.assigns.refresh_pending do
      {:noreply, socket}
    else
      Process.send_after(self(), :do_refresh, 250)
      {:noreply, assign(socket, :refresh_pending, true)}
    end
  end

  defp filters_path(socket) do
    params =
      [
        {"event_type", socket.assigns.event_type_filter},
        {"decision", socket.assigns.decision_filter},
        {"component", socket.assigns.component_filter}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    case params do
      [] -> PrismWeb.Focus.path(socket.assigns.athanor_route, "/enforcements")
      p -> PrismWeb.Focus.path(socket.assigns.athanor_route, "/enforcements?#{p}")
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  defp f(m, k), do: m[k] || m[to_string(k)]

  defp event_type_chip(event_type) do
    case to_string(event_type || "") do
      "policy_consultation" -> "bg-emerald-900/30 text-emerald-300 border-emerald-800/50"
      "domain_blocked" -> "bg-red-900/30 text-red-300 border-red-800/50"
      "method_blocked" -> "bg-red-900/30 text-red-300 border-red-800/50"
      "scheme_blocked" -> "bg-red-900/30 text-red-300 border-red-800/50"
      "rate_limit" -> "bg-amber-900/30 text-amber-300 border-amber-800/50"
      "request_size" -> "bg-amber-900/30 text-amber-300 border-amber-800/50"
      "denied" -> "bg-red-900/30 text-red-300 border-red-800/50"
      _ -> "bg-gray-800 text-gray-300 border-gray-700"
    end
  end

  defp decision_status("allowed"), do: "ok"
  defp decision_status("denied"), do: "failed"
  defp decision_status(_), do: "pending"

  defp truncate(nil), do: "—"
  defp truncate(s) when is_binary(s) and byte_size(s) > 60, do: String.slice(s, 0, 60) <> "…"
  defp truncate(s), do: to_string(s)

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :event_types, @event_types)

    ~H"""
    <div class="space-y-6">
      <.page_header title="Enforcements">
        <:actions>
          <span class="flex items-center gap-1.5 text-xs text-green-400">
            <span class="h-2 w-2 rounded-full bg-green-400 animate-pulse" /> Live
          </span>
          <.button size="sm" variant="secondary" phx-click="refresh">Refresh</.button>
        </:actions>
      </.page_header>

      <p class="text-xs text-gray-500 max-w-2xl">
        Every allow / deny decision from CYFR's enforcement chokepoints —
        pre-execution gate, HTTP egress, tincture rate limit — lands here.
        Click a row to jump to the request's full causal chain in Activity.
      </p>

      <form phx-change="filter" class="flex items-center gap-3 flex-wrap">
        <select
          name="event_type"
          class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
        >
          <option
            :for={{label, value} <- @event_types}
            value={value}
            selected={(@event_type_filter || "") == value}
          >
            {label}
          </option>
        </select>
        <select
          name="decision"
          class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
        >
          <option value="" selected={is_nil(@decision_filter)}>All decisions</option>
          <option value="allowed" selected={@decision_filter == "allowed"}>allowed</option>
          <option value="denied" selected={@decision_filter == "denied"}>denied</option>
          <option value="default" selected={@decision_filter == "default"}>default</option>
        </select>
        <input
          type="text"
          name="component"
          value={@component_filter}
          placeholder="Filter component_ref…"
          class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5 placeholder-gray-500 w-64"
          phx-debounce="300"
        />
      </form>

      <.live_loading :if={@loading} message="Loading enforcement decisions…" />
      <.live_error :if={!@loading && @error} message={@error} />
      <.live_empty
        :if={!@loading && !@error && @logs == []}
        message="No enforcement decisions yet. They'll appear here as components run."
      />

      <div
        :if={!@loading && !@error && @logs != []}
        class="overflow-x-auto rounded-lg border border-gray-800 bg-gray-900"
      >
        <table class="min-w-full table-fixed">
          <thead class="border-b border-gray-800 bg-gray-900/60">
            <tr>
              <th class="w-[14%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                When
              </th>
              <th class="w-[16%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Rule
              </th>
              <th class="w-[10%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Decision
              </th>
              <th class="w-[24%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Component
              </th>
              <th class="w-[36%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Reason
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for log <- @logs do %>
              <% req_id = f(log, :request_id) %>
              <tr
                phx-click={
                  req_id &&
                    Phoenix.LiveView.JS.navigate(
                      PrismWeb.Focus.path(@athanor_route, "/activities?request_id=#{req_id}")
                    )
                }
                class={[
                  "border-t border-gray-800/60 transition-colors",
                  if(req_id, do: "cursor-pointer hover:bg-gray-800/40", else: "cursor-default")
                ]}
              >
                <td
                  class="px-4 py-2 text-xs text-gray-400 whitespace-nowrap"
                  title={f(log, :timestamp)}
                >
                  {relative_time(f(log, :timestamp))}
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border",
                    event_type_chip(f(log, :event_type))
                  ]}>
                    {f(log, :event_type) || "—"}
                  </span>
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <.status_indicator status={decision_status(f(log, :decision))} />
                </td>
                <td class="px-4 py-2 text-sm text-gray-300 font-mono text-xs truncate">
                  {f(log, :component_ref) || "—"}
                </td>
                <td class="px-4 py-2 text-xs text-gray-400 italic">
                  {truncate(f(log, :decision_reason))}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
