# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ActivitiesLive do
  @moduledoc """
  Unified activity view: every CYFR request and the executions it spawned.

  Each row is one Arca.McpLog record (real MCP request, tincture invoke, or
  cron firing — all share the same shape after Phase 1.3a). Expanding a row
  calls `mcp_log/correlate` to fetch the full causal tree (executions +
  policy logs).

  Replaces the older ExecutionsLive (`/executions`) and LogsLive (`/logs`)
  surfaces, which sliced the same data along two different axes.
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS

  require Logger

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]

      for topic <- ["prism:requests", "prism:tinctures", "prism:schedules"] do
        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic(topic, ctx))
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Activities")
     |> assign(:active_nav, "activities")
     |> assign(:logs, [])
     |> assign(:fan_outs, %{})
     |> assign(:source_filter, nil)
     |> assign(:status_filter, nil)
     |> assign(:time_filter, nil)
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:expanded_id, nil)
     |> assign(:expanded_tree, nil)
     |> assign(:expanded_loading, false)
     |> assign(:refresh_pending, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:source_filter, normalize_filter(params["source"]))
      |> assign(:status_filter, normalize_filter(params["status"]))
      |> assign(:time_filter, normalize_filter(params["time"]))

    if connected?(socket) do
      send(self(), :load_data)
      {:noreply, assign(socket, :loading, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"source" => source, "status" => status}, socket) do
    socket =
      socket
      |> assign(:source_filter, normalize_filter(source))
      |> assign(:status_filter, normalize_filter(status))

    {:noreply, push_patch(socket, to: filters_path(socket))}
  end

  def handle_event("time_filter", %{"time" => time}, socket) do
    socket = assign(socket, :time_filter, normalize_filter(time))
    {:noreply, push_patch(socket, to: filters_path(socket))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_logs(socket)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply,
       socket
       |> assign(:expanded_id, nil)
       |> assign(:expanded_tree, nil)
       |> assign(:expanded_loading, false)}
    else
      socket =
        socket
        |> assign(:expanded_id, id)
        |> assign(:expanded_tree, nil)
        |> assign(:expanded_loading, true)

      send(self(), {:load_correlate, id})
      {:noreply, socket}
    end
  end

  @impl true
  # PubSub broadcasts from the enriched TelemetryBridge — re-fetch the row list
  # on a debounced timer so a burst of events doesn't hammer the DB. The cockpit
  # is single-user; rates are low and clarity beats micro-optimisation here.
  def handle_info({:request, _metadata, _measurements}, socket), do: schedule_refresh(socket)

  def handle_info({:tincture_invoke_started, _metadata, _measurements}, socket),
    do: schedule_refresh(socket)

  def handle_info({:tincture_invoke_stopped, _metadata, _measurements}, socket),
    do: schedule_refresh(socket)

  def handle_info({:schedule_fired, _metadata, _measurements}, socket),
    do: schedule_refresh(socket)

  def handle_info(:load_data, socket) do
    {:noreply, fetch_logs(socket)}
  end

  def handle_info(:do_refresh, socket) do
    socket = socket |> assign(:refresh_pending, false) |> fetch_logs()

    cond do
      is_nil(socket.assigns.expanded_id) ->
        {:noreply, socket}

      Enum.any?(socket.assigns.logs, fn log -> f(log, :id) == socket.assigns.expanded_id end) ->
        # Expanded row still present — re-correlate so drill-down reflects fresh data.
        send(self(), {:load_correlate, socket.assigns.expanded_id})
        {:noreply, assign(socket, :expanded_loading, true)}

      true ->
        # Expanded row dropped off the page (filter change or pushed past limit).
        {:noreply,
         socket
         |> assign(:expanded_id, nil)
         |> assign(:expanded_tree, nil)
         |> assign(:expanded_loading, false)}
    end
  end

  def handle_info({:load_correlate, request_id}, socket) do
    if socket.assigns.expanded_id == request_id do
      tree =
        case call_tool(socket, "mcp_log", %{"action" => "correlate", "request_id" => request_id}) do
          {:ok, result} ->
            result

          {:error, reason} ->
            Logger.warning("[ActivitiesLive] correlate failed: #{inspect(reason)}")
            nil
        end

      {:noreply, socket |> assign(:expanded_tree, tree) |> assign(:expanded_loading, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[ActivitiesLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Data
  # ============================================================================

  defp fetch_logs(socket) do
    args =
      %{"action" => "list", "limit" => @page_size}
      |> maybe_put("status", socket.assigns.status_filter)
      |> maybe_put("tool", socket.assigns.source_filter)
      |> maybe_put("since", time_filter_to_since(socket.assigns.time_filter))

    case call_tool(socket, "mcp_log", args) do
      {:ok, %{logs: logs}} when is_list(logs) ->
        socket
        |> assign(:logs, logs)
        |> assign(:fan_outs, build_fan_outs(socket, logs))
        |> assign(:loading, false)
        |> assign(:error, nil)

      {:ok, other} ->
        Logger.warning("[ActivitiesLive] unexpected list shape: #{inspect(other)}")
        socket |> assign(:logs, []) |> assign(:loading, false) |> assign(:error, nil)

      {:error, reason} ->
        Logger.warning("[ActivitiesLive] mcp_log list failed: #{inspect(reason)}")

        socket
        |> assign(:logs, [])
        |> assign(:loading, false)
        |> assign(:error, "Failed to load activity: #{inspect(reason)}")
    end
  end

  # Fan-out count per request_id: how many executions share this request's id?
  # Single GROUP BY via `mcp_log/fan_outs`, scoped to the current page's IDs.
  defp build_fan_outs(socket, logs) do
    ids =
      logs
      |> Enum.map(fn log -> log[:id] || log["id"] end)
      |> Enum.reject(&is_nil/1)

    case ids != [] &&
           call_tool(socket, "mcp_log", %{"action" => "fan_outs", "request_ids" => ids}) do
      {:ok, %{counts: counts}} when is_map(counts) -> counts
      _ -> %{}
    end
  end

  defp schedule_refresh(socket) do
    if socket.assigns.refresh_pending do
      {:noreply, socket}
    else
      Process.send_after(self(), :do_refresh, 250)
      {:noreply, assign(socket, :refresh_pending, true)}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  # Build a shareable /activities URL from current filter assigns. Filters that
  # are nil/empty are omitted so the canonical "all" URL stays clean.
  defp filters_path(socket) do
    params =
      [
        {"source", socket.assigns.source_filter},
        {"status", socket.assigns.status_filter},
        {"time", socket.assigns.time_filter}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    case params do
      [] -> PrismWeb.Focus.path(socket.assigns.athanor_route, "/activities")
      p -> PrismWeb.Focus.path(socket.assigns.athanor_route, "/activities?#{p}")
    end
  end

  defp time_filter_to_since("1h"),
    do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

  defp time_filter_to_since("24h"),
    do: DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()

  defp time_filter_to_since("7d"),
    do: DateTime.utc_now() |> DateTime.add(-7 * 86_400, :second) |> DateTime.to_iso8601()

  defp time_filter_to_since(_), do: nil

  defp f(m, k), do: m[k] || m[to_string(k)]

  defp source_badge(tool) do
    case tool do
      "tincture" -> {"Tincture", "bg-pink-900/30 text-pink-300 border-pink-800/50"}
      "schedule" -> {"Cron", "bg-amber-900/30 text-amber-300 border-amber-800/50"}
      _ -> {"MCP", "bg-blue-900/30 text-blue-300 border-blue-800/50"}
    end
  end

  defp trigger_label(log) do
    tool = f(log, :tool)
    action = f(log, :action)
    input = f(log, :input) || %{}

    case tool do
      "tincture" ->
        publisher = input["publisher"] || input[:publisher]
        name = input["tincture_name"] || input[:tincture_name]
        if publisher && name, do: "tincture:#{publisher}.#{name}", else: "tincture/invoke"

      "schedule" ->
        sid = input["schedule_id"] || input[:schedule_id]
        if sid, do: sid, else: "cron/fire"

      _ ->
        cond do
          tool && action -> "#{tool}/#{action}"
          tool -> tool
          true -> "-"
        end
    end
  end

  defp truncate_id(nil), do: "-"

  defp truncate_id(id) when is_binary(id) and byte_size(id) > 14,
    do: String.slice(id, 0, 14) <> "…"

  defp truncate_id(id), do: id

  defp type_class("catalyst"), do: "bg-purple-900/30 text-purple-300"
  defp type_class("reagent"), do: "bg-blue-900/30 text-blue-300"
  defp type_class("formula"), do: "bg-emerald-900/30 text-emerald-300"
  defp type_class(_), do: "bg-gray-800 text-gray-400"

  # Indent the Reference cell in the inline execution tree by depth. Inline
  # style so depth can grow arbitrarily without a fixed Tailwind class for
  # each level. Mirrors the pattern in ExecutionsLive.
  defp depth_padding(depth), do: "padding-left: #{0.5 + depth * 1.25}rem"

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Activities">
        <:actions>
          <span class="flex items-center gap-1.5 text-xs text-green-400">
            <span class="h-2 w-2 rounded-full bg-green-400 animate-pulse" /> Live
          </span>
          <.button size="sm" variant="secondary" phx-click="refresh">Refresh</.button>
        </:actions>
      </.page_header>
      
    <!-- Filters -->
      <div class="flex items-center gap-3 flex-wrap">
        <form phx-change="filter" class="flex gap-3">
          <select
            name="source"
            class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
          >
            <option value="" selected={is_nil(@source_filter)}>All Sources</option>
            <option value="tincture" selected={@source_filter == "tincture"}>Tinctures</option>
            <option value="schedule" selected={@source_filter == "schedule"}>Cron</option>
            <option value="execution" selected={@source_filter == "execution"}>
              MCP / execution
            </option>
          </select>
          <select
            name="status"
            class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
          >
            <option value="" selected={is_nil(@status_filter)}>All Statuses</option>
            <option value="pending" selected={@status_filter == "pending"}>pending</option>
            <option value="success" selected={@status_filter == "success"}>success</option>
            <option value="error" selected={@status_filter == "error"}>error</option>
          </select>
        </form>
        <div class="flex gap-1">
          <.filter_pill
            :for={preset <- [{"1h", "1h"}, {"24h", "24h"}, {"7d", "7d"}, {"All", ""}]}
            label={elem(preset, 0)}
            active={(@time_filter || "") == elem(preset, 1)}
            active_class="bg-indigo-900 text-indigo-300"
            phx-click="time_filter"
            phx-value-time={elem(preset, 1)}
          />
        </div>
      </div>

      <.live_loading :if={@loading} message="Loading activity…" />
      <.live_error :if={!@loading && @error} message={@error} />
      <.live_empty :if={!@loading && !@error && @logs == []} message="No activity yet." />

      <div
        :if={!@loading && !@error && @logs != []}
        class="overflow-x-auto rounded-lg border border-gray-800 bg-gray-900"
      >
        <table class="min-w-full table-fixed">
          <thead class="border-b border-gray-800 bg-gray-900/60">
            <tr>
              <th class="w-[12%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Source
              </th>
              <th class="w-[28%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Trigger
              </th>
              <th class="w-[10%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Status
              </th>
              <th class="w-[10%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Execs
              </th>
              <th class="w-[12%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Duration
              </th>
              <th class="w-[16%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Request ID
              </th>
              <th class="w-[12%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                When
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for log <- @logs do %>
              <% id = f(log, :id) || "-" %>
              <% {label, badge_class} = source_badge(f(log, :tool)) %>
              <% fan_out = Map.get(@fan_outs, id, 0) %>
              <tr
                phx-click="toggle_expand"
                phx-value-id={id}
                class={[
                  "border-t border-gray-800/60 cursor-pointer transition-colors",
                  if(@expanded_id == id, do: "bg-gray-800/80", else: "hover:bg-gray-800/40")
                ]}
              >
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border",
                    badge_class
                  ]}>
                    {label}
                  </span>
                </td>
                <td class="px-4 py-2 text-sm text-gray-300 truncate max-w-0">
                  {trigger_label(log)}
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <.status_indicator status={to_string(f(log, :status) || "unknown")} />
                </td>
                <td class="px-4 py-2 text-sm text-gray-400 whitespace-nowrap">
                  <span :if={fan_out > 0} class="inline-flex items-center gap-1">
                    <span class="font-mono">{fan_out}</span>
                    <span class="text-xs">↳</span>
                  </span>
                  <span :if={fan_out == 0} class="text-gray-600">—</span>
                </td>
                <td class="px-4 py-2 text-sm text-gray-300 whitespace-nowrap">
                  {format_duration(f(log, :duration_ms))}
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span class="text-blue-400 font-mono text-xs" title={id}>{truncate_id(id)}</span>
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span class="text-xs text-gray-400" title={f(log, :timestamp)}>
                    {relative_time(f(log, :timestamp))}
                  </span>
                </td>
              </tr>

              <tr :if={@expanded_id == id} class="border-t border-gray-800/60 bg-gray-900/60">
                <td colspan="7" class="px-4 py-4">
                  <.live_loading :if={@expanded_loading} message="Correlating…" />

                  <div :if={!@expanded_loading && @expanded_tree} class="space-y-4">
                    <.expanded_tree tree={@expanded_tree} log={log} />
                  </div>

                  <.live_empty
                    :if={!@expanded_loading && !@expanded_tree}
                    message="No correlation data."
                  />
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------------------
  # Expanded tree component — MCP log + execution tree + policy logs.
  # ----------------------------------------------------------------------------

  attr :tree, :map, required: true
  attr :log, :map, required: true

  defp expanded_tree(assigns) do
    has_input = f(assigns.log, :input) not in [nil, %{}]
    has_output = f(assigns.log, :output) not in [nil, %{}]
    has_error = f(assigns.log, :error) not in [nil, ""]
    show_error = has_error and not has_output
    has_right = has_output or show_error

    assigns =
      assigns
      |> assign(:has_input, has_input)
      |> assign(:has_output, has_output)
      |> assign(:show_error, show_error)
      |> assign(:has_right, has_right)

    ~H"""
    <div class="space-y-4">
      <!-- Top metadata: 4 cells with copy buttons on IDs -->
      <dl class="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Request ID</dt>
          <dd class="text-white mt-0.5 font-mono text-xs flex items-center gap-1.5">
            <span class="truncate" title={f(@log, :id)}>{f(@log, :id) || "—"}</span>
            <button
              :if={f(@log, :id)}
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: f(@log, :id)})}
              class="text-gray-500 hover:text-gray-300 shrink-0"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Tool / Action</dt>
          <dd class="text-white mt-0.5 font-mono text-xs truncate">
            {f(@log, :tool) || "-"} / {f(@log, :action) || "-"}
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Routed To</dt>
          <dd class="text-white mt-0.5 font-mono text-xs truncate">{f(@log, :routed_to) || "—"}</dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">When</dt>
          <dd class="text-white mt-0.5 text-xs truncate" title={f(@log, :timestamp)}>
            {f(@log, :timestamp) || "—"}
          </dd>
        </div>
      </dl>
      
    <!-- Execution tree — same visual idiom as the /executions main table -->
      <section :if={Map.get(@tree, :executions) not in [nil, []]}>
        <h4 class="text-xs font-medium uppercase tracking-wider text-gray-500 mb-2">
          Executions ({length(@tree.executions)})
        </h4>
        <div class="rounded-lg border border-gray-800 bg-gray-900/60 overflow-hidden">
          <%= for {exec, depth} <- annotated_executions(@tree.executions) do %>
            <div class="flex items-center gap-3 px-4 py-1.5 text-sm border-t border-gray-800/60 first:border-t-0">
              <span class={[
                "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium shrink-0",
                type_class(f(exec, :component_type))
              ]}>
                {f(exec, :component_type) || "—"}
              </span>
              <div class="flex-1 min-w-0 flex items-center gap-2" style={depth_padding(depth)}>
                <span :if={depth > 0} class="text-gray-600 shrink-0">↳</span>
                <span class="text-gray-300 font-mono text-xs truncate">
                  {format_ref(f(exec, :reference))}
                </span>
              </div>
              <.status_indicator status={to_string(f(exec, :status) || "unknown")} />
              <span class="text-gray-500 text-xs whitespace-nowrap w-16 text-right">
                {format_duration(f(exec, :duration_ms))}
              </span>
              <span class="text-gray-600 text-xs font-mono whitespace-nowrap" title={f(exec, :id)}>
                {truncate_id(f(exec, :id))}
              </span>
            </div>
          <% end %>
        </div>
      </section>
      
    <!-- Policy decisions -->
      <section :if={Map.get(@tree, :policy_logs) not in [nil, []]}>
        <h4 class="text-xs font-medium uppercase tracking-wider text-gray-500 mb-2">
          Policy decisions ({length(@tree.policy_logs)})
        </h4>
        <div class="rounded-lg border border-gray-800 bg-gray-900/60 overflow-hidden">
          <%= for plog <- @tree.policy_logs do %>
            <div class="flex items-center gap-3 px-4 py-1.5 text-sm border-t border-gray-800/60 first:border-t-0">
              <.status_indicator status={policy_decision_status(f(plog, :decision))} />
              <span class="text-gray-300 font-mono text-xs">{f(plog, :event_type) || "-"}</span>
              <span class="text-gray-500 text-xs flex-1 min-w-0 truncate">
                {f(plog, :component_ref) || ""}
              </span>
              <span :if={f(plog, :decision_reason)} class="text-gray-600 text-xs italic truncate">
                {f(plog, :decision_reason)}
              </span>
            </div>
          <% end %>
        </div>
      </section>
      
    <!-- Input + Output/Error side-by-side -->
      <div :if={@has_input or @has_right} class="grid gap-4 md:grid-cols-2">
        <section :if={@has_input} class={if !@has_right, do: "md:col-span-2", else: ""}>
          <div class="flex items-center justify-between mb-1">
            <h4 class="text-xs font-medium text-gray-400">Input</h4>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(f(@log, :input))})}
              class="text-gray-500 hover:text-gray-300"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </div>
          <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(f(@log, :input))}</code></pre>
        </section>
        <section :if={@has_output} class={if !@has_input, do: "md:col-span-2", else: ""}>
          <div class="flex items-center justify-between mb-1">
            <h4 class="text-xs font-medium text-gray-400">Output</h4>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(f(@log, :output))})}
              class="text-gray-500 hover:text-gray-300"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </div>
          <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(f(@log, :output))}</code></pre>
        </section>
        <section :if={@show_error} class={if !@has_input, do: "md:col-span-2", else: ""}>
          <div class="flex items-center justify-between mb-1">
            <h4 class="text-xs font-medium text-red-400">Error</h4>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: to_string(f(@log, :error))})}
              class="text-gray-500 hover:text-gray-300"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </div>
          <pre class="text-xs text-red-300 bg-red-950/40 rounded p-3 border border-red-900/50 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{f(@log, :error)}</code></pre>
        </section>
      </div>
    </div>
    """
  end

  # Annotate the executions list with per-row depth, ordered parent-first.
  # Replaces the old ordered_executions/exec_depth/parent_depth trio with a
  # single depth-first walk, mirroring ExecutionsLive's pattern.
  defp annotated_executions(executions) do
    by_parent = Enum.group_by(executions, fn e -> f(e, :parent_execution_id) end)
    exec_ids = MapSet.new(Enum.map(executions, &f(&1, :id)))

    real_roots = Map.get(by_parent, nil, [])

    orphan_roots =
      by_parent
      |> Map.delete(nil)
      |> Enum.flat_map(fn {parent_id, children} ->
        if parent_id && MapSet.member?(exec_ids, parent_id), do: [], else: children
      end)

    roots = real_roots ++ orphan_roots

    Enum.flat_map(roots, fn root -> walk_with_depth(root, by_parent, 0) end)
  end

  defp walk_with_depth(exec, by_parent, depth) do
    children = Map.get(by_parent, f(exec, :id), [])
    [{exec, depth} | Enum.flat_map(children, &walk_with_depth(&1, by_parent, depth + 1))]
  end

  defp policy_decision_status("allowed"), do: "ok"
  defp policy_decision_status("denied"), do: "failed"
  defp policy_decision_status(_), do: "pending"
end
