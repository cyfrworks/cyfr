# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ActivitiesLive do
  @moduledoc """
  Unified activity view: every admission decision and what it led to.

  Each row is one `Prima.Decision` — a call the server admitted or
  refused in this athanor (an MCP call, a tincture invoke, a cron firing),
  whose own id is its call id — read through `Arca.DecisionLog` under the
  caller's actor. A row is keyed by the request it belongs to — its
  `request_id`, which the calls of one chain share: expanding it
  correlates that request (its decisions, the request-log rows that carry
  each call's input and output, the executions it started and its policy
  logs), the fan-out counts are the request's, and `?id=req_…` focuses
  the request.

  Reads call the storage facades directly under the caller's context,
  held to the freshness rule first (`CyfrWeb.ContextGuard.check/1`); none
  of them is an operation. `ExecutionsLive` at `/executions` groups
  activity by execution for run inspection and control.
  """

  use PrismWeb, :live_view

  alias Cyfr.Bus

  alias Phoenix.LiveView.JS

  require Logger

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      actor = Sanctum.Context.actor(socket.assigns[:context])

      for topic <- [Bus.requests(actor), Bus.tinctures(actor), Bus.schedule_runs(actor)] do
        Bus.subscribe(actor, topic)
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "Activities")
     |> assign(:active_nav, "activities")
     |> assign(:decisions, [])
     |> assign(:leaders, MapSet.new())
     |> assign(:fan_outs, %{})
     |> assign(:source_filter, nil)
     |> assign(:admission_filter, nil)
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
      |> assign(:admission_filter, normalize_filter(params["admission"]))
      |> assign(:time_filter, normalize_filter(params["time"]))
      |> focus_request(params["id"])

    if connected?(socket) do
      send(self(), :load_data)
      {:noreply, assign(socket, :loading, true)}
    else
      {:noreply, socket}
    end
  end

  # `ui.activity.focus` navigates here with `?id=req_…` — the agent's half
  # of the act a person performs by clicking the row, so it lands in the
  # same state. Reading the key is also what makes the palette honest:
  # `PrismWeb.ActiveContext` already derives `{:request, id}` from this URL,
  # so without this the palette offered "rerun current request" over a page
  # showing a bare list.
  #
  # Absent key leaves the socket alone: a filter `push_patch` carries no
  # `id`, and must not collapse a row the person opened by hand.
  defp focus_request(socket, id) when is_binary(id) and id != "" do
    if socket.assigns.expanded_id == id do
      socket
    else
      if connected?(socket), do: send(self(), {:load_correlate, id})

      socket
      |> assign(:expanded_id, id)
      |> assign(:expanded_tree, nil)
      |> assign(:expanded_loading, connected?(socket))
    end
  end

  defp focus_request(socket, _id), do: socket

  @impl true
  def handle_event("filter", %{"source" => source, "admission" => admission}, socket) do
    socket =
      socket
      |> assign(:source_filter, normalize_filter(source))
      |> assign(:admission_filter, normalize_filter(admission))

    {:noreply, push_patch(socket, to: filters_path(socket))}
  end

  def handle_event("time_filter", %{"time" => time}, socket) do
    socket = assign(socket, :time_filter, normalize_filter(time))
    {:noreply, push_patch(socket, to: filters_path(socket))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_decisions(socket)}
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
  # Bus messages the host's bridge publishes — re-fetch the row list on a
  # debounced timer so a burst of events doesn't hammer the DB. The cockpit
  # is single-user; rates are low and clarity beats micro-optimisation here.
  # A schedule that fired or failed is an activity either way.
  def handle_info(%Bus.Request{}, socket), do: schedule_refresh(socket)

  def handle_info(%Bus.Tinctures{kind: kind}, socket)
      when kind in [:invoke_started, :invoke_stopped],
      do: schedule_refresh(socket)

  def handle_info(%Bus.Tinctures{}, socket), do: {:noreply, socket}

  def handle_info(%Bus.ScheduleRun{}, socket), do: schedule_refresh(socket)

  def handle_info(:load_data, socket) do
    {:noreply, fetch_decisions(socket)}
  end

  def handle_info(:do_refresh, socket) do
    socket = socket |> assign(:refresh_pending, false) |> fetch_decisions()

    cond do
      is_nil(socket.assigns.expanded_id) ->
        {:noreply, socket}

      Enum.any?(socket.assigns.decisions, &(&1.request_id == socket.assigns.expanded_id)) ->
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
        case correlate(socket, request_id) do
          {:ok, tree} ->
            tree

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
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ============================================================================
  # Data
  # ============================================================================

  defp fetch_decisions(socket) do
    opts =
      [limit: @page_size]
      |> put_opt(:tool, socket.assigns.source_filter)
      |> put_opt(:admission, admission(socket.assigns.admission_filter))
      |> put_opt(:since, since(socket.assigns.time_filter))

    with {:ok, actor} <- reader(socket),
         {:ok, decisions} <- Arca.DecisionLog.list(actor, opts) do
      decisions = Enum.map(decisions, &Map.from_struct/1)

      socket
      |> assign(:decisions, decisions)
      |> assign(:leaders, leaders(decisions))
      |> assign(:fan_outs, build_fan_outs(actor, decisions))
      |> assign(:loading, false)
      |> assign(:error, nil)
    else
      {:error, reason} ->
        Logger.warning("[ActivitiesLive] decision list failed: #{inspect(reason)}")

        socket
        |> assign(:decisions, [])
        |> assign(:leaders, MapSet.new())
        |> assign(:loading, false)
        |> assign(:error, "Failed to load activity: #{error_message(read_refusal(reason))}")
    end
  end

  # The caller's actor, once its context still stands: a long-lived
  # socket's context is revalidated past the freshness bound before any
  # read, as `PrismWeb.Ops.call_tool/3` does before a call.
  defp reader(socket) do
    case socket.assigns do
      %{context: %Sanctum.Context{} = ctx} ->
        with {:ok, ctx} <- CyfrWeb.ContextGuard.check(ctx),
             do: {:ok, Sanctum.Context.actor(ctx)}

      _ ->
        {:error, :no_context}
    end
  end

  defp read_refusal(:no_athanor), do: :missing_tenant
  defp read_refusal(:database_error), do: {:unavailable, "Storage"}
  defp read_refusal(reason), do: reason

  # The first row of each request on the page: the one its expansion
  # renders under, so a chain's calls expand once.
  defp leaders(decisions) do
    decisions
    |> Enum.uniq_by(& &1.request_id)
    |> MapSet.new(& &1.call_id)
  end

  # A request's correlation: its decisions, the request-log rows that
  # project them (a call's input and output), the executions it started
  # and its policy logs. The decisions are the tree's spine, so a store
  # that cannot answer them is the expansion's refusal; the other legs are
  # joined best-effort, and an outage on one leaves it empty.
  defp correlate(socket, request_id) do
    with {:ok, actor} <- reader(socket),
         {:ok, decisions} <- Arca.DecisionLog.correlate(actor, request_id) do
      scope = [request_id: request_id, limit: 100, athanor_id: actor.athanor_id]

      {:ok,
       %{
         request_id: request_id,
         decisions: Enum.map(decisions, &Map.from_struct/1),
         mcp_logs: leg(Arca.McpLog.list(scope)),
         executions: leg(Arca.Execution.list_by_request(actor, request_id)),
         policy_logs: leg(Arca.PolicyLog.list(scope))
       }}
    end
  end

  defp leg({:ok, rows}) when is_list(rows), do: rows
  defp leg(rows) when is_list(rows), do: rows
  defp leg({:error, _reason}), do: []

  # Fan-out count per request_id: how many executions share this request's
  # id? One GROUP BY, scoped to the current page's requests.
  defp build_fan_outs(actor, decisions) do
    ids =
      decisions
      |> Enum.map(& &1.request_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids != [] && Arca.Execution.count_by_request(actor, ids) do
      counts when is_map(counts) -> counts
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

  defp normalize_filter(nil), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # A filter name outside the vocabulary filters nothing.
  defp admission(name) when is_binary(name),
    do: Enum.find(Prima.Decision.admissions(), &(Atom.to_string(&1) == name))

  defp admission(_name), do: nil

  # Build a shareable /activities URL from current filter assigns. Filters that
  # are nil/empty are omitted so the canonical "all" URL stays clean.
  defp filters_path(socket) do
    params =
      [
        {"source", socket.assigns.source_filter},
        {"admission", socket.assigns.admission_filter},
        {"time", socket.assigns.time_filter}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    case params do
      [] ->
        PrismWeb.Focus.path(socket.assigns.athanor_route, "/activities")

      p ->
        # `URI.encode_query/1`, not interpolation: a list of tuples has no
        # String.Chars implementation, so `"?#{p}"` raised and took the
        # LiveView down on every filter that was not "all".
        PrismWeb.Focus.path(
          socket.assigns.athanor_route,
          "/activities?" <> URI.encode_query(p)
        )
    end
  end

  defp since("1h"), do: DateTime.add(DateTime.utc_now(), -3600, :second)
  defp since("24h"), do: DateTime.add(DateTime.utc_now(), -86_400, :second)
  defp since("7d"), do: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
  defp since(_), do: nil

  defp operation_label(%{tool: tool, action: action})
       when tool not in [nil, ""] and action not in [nil, ""],
       do: "#{tool}.#{action}"

  defp operation_label(%{tool: tool}) when tool not in [nil, ""], do: tool
  defp operation_label(_decision), do: "-"

  defp plane_label(:in_chain), do: "in-chain"
  defp plane_label(plane), do: to_string(plane || "-")

  # The admission's indicator: green for an admission, red for a refusal,
  # whose class stands beside it.
  defp admission_status(%{admission: :admitted}), do: "ok"
  defp admission_status(_decision), do: "failed"

  defp admission_label(%{admission: :refused, refusal_class: class}) when not is_nil(class),
    do: "refused: #{class}"

  defp admission_label(decision), do: to_string(decision.admission)

  # How the admitted work ended. No completion is an unknown outcome — in
  # flight, or never recorded — never a success; a refusal ran nothing.
  defp completion_status(%{completion: :succeeded}), do: "success"
  defp completion_status(%{completion: :failed}), do: "failed"
  defp completion_status(%{completion: :cancelled}), do: "cancelled"
  defp completion_status(%{completion: :uncertain}), do: "degraded"
  defp completion_status(_decision), do: "unknown"

  defp completion_label(%{admission: :refused}), do: "—"
  defp completion_label(%{completion: nil}), do: "unknown"

  defp completion_label(%{completion: completion, completion_class: class})
       when not is_nil(class),
       do: "#{completion}: #{class}"

  defp completion_label(%{completion: completion}), do: to_string(completion)

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
            <option value="webhook" selected={@source_filter == "webhook"}>Webhooks</option>
            <option value="execution" selected={@source_filter == "execution"}>
              MCP / execution
            </option>
          </select>
          <select
            name="admission"
            class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
          >
            <option value="" selected={is_nil(@admission_filter)}>All Decisions</option>
            <option value="admitted" selected={@admission_filter == "admitted"}>admitted</option>
            <option value="refused" selected={@admission_filter == "refused"}>refused</option>
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
      <.live_empty :if={!@loading && !@error && @decisions == []} message="No activity yet." />

      <div
        :if={!@loading && !@error && @decisions != []}
        class="overflow-x-auto rounded-lg border border-gray-800 bg-gray-900"
      >
        <table class="min-w-full table-fixed">
          <thead class="border-b border-gray-800 bg-gray-900/60">
            <tr>
              <th class="w-[11%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                When
              </th>
              <th class="w-[23%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Operation
              </th>
              <th class="w-[9%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Plane
              </th>
              <th class="w-[18%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Admission
              </th>
              <th class="w-[15%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Completion
              </th>
              <th class="w-[8%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Execs
              </th>
              <th class="w-[16%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">
                Request ID
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for decision <- @decisions do %>
              <% id = decision.request_id || "-" %>
              <% fan_out = Map.get(@fan_outs, id, 0) %>
              <% at = Prima.Time.iso8601(decision.inserted_at) %>
              <tr
                phx-click="toggle_expand"
                phx-value-id={id}
                data-call-id={decision.call_id}
                class={[
                  "border-t border-gray-800/60 cursor-pointer transition-colors",
                  if(@expanded_id == id, do: "bg-gray-800/80", else: "hover:bg-gray-800/40")
                ]}
              >
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span class="text-xs text-gray-400" title={at}>{relative_time(at)}</span>
                </td>
                <td class="px-4 py-2 text-sm text-gray-300 font-mono truncate max-w-0">
                  {operation_label(decision)}
                </td>
                <td class="px-4 py-2 text-xs text-gray-400 whitespace-nowrap">
                  {plane_label(decision.plane)}
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap" title={decision.reason}>
                  <.decision_state status={admission_status(decision)}>
                    {admission_label(decision)}
                  </.decision_state>
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span :if={decision.admission == :refused} class="text-gray-600">—</span>
                  <.decision_state
                    :if={decision.admission != :refused}
                    status={completion_status(decision)}
                  >
                    {completion_label(decision)}
                  </.decision_state>
                </td>
                <td class="px-4 py-2 text-sm text-gray-400 whitespace-nowrap">
                  <span :if={fan_out > 0} class="inline-flex items-center gap-1">
                    <span class="font-mono">{fan_out}</span>
                    <span class="text-xs">↳</span>
                  </span>
                  <span :if={fan_out == 0} class="text-gray-600">—</span>
                </td>
                <td class="px-4 py-2 text-sm whitespace-nowrap">
                  <span class="text-blue-400 font-mono text-xs" title={id}>{truncate(id, 14)}</span>
                </td>
              </tr>

              <tr
                :if={@expanded_id == id and MapSet.member?(@leaders, decision.call_id)}
                class="border-t border-gray-800/60 bg-gray-900/60"
              >
                <td colspan="7" class="px-4 py-4">
                  <.live_loading :if={@expanded_loading} message="Correlating…" />

                  <div :if={!@expanded_loading && @expanded_tree} class="space-y-4">
                    <.expanded_tree tree={@expanded_tree} decision={decision} />
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

  # One state cell: the indicator's colour for `status`, the words given.
  attr :status, :string, required: true
  slot :inner_block, required: true

  defp decision_state(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2" data-status={@status}>
      <span class={["h-2 w-2 rounded-full shrink-0", state_dot(@status)]} />
      <span class="text-xs text-gray-300">{render_slot(@inner_block)}</span>
    </span>
    """
  end

  defp state_dot("ok"), do: "bg-green-400"
  defp state_dot("success"), do: "bg-green-400"
  defp state_dot("failed"), do: "bg-red-400"
  defp state_dot("cancelled"), do: "bg-amber-400"
  defp state_dot("degraded"), do: "bg-amber-400"
  defp state_dot(_unknown), do: "bg-gray-500"

  # ----------------------------------------------------------------------------
  # Expanded tree component — the request's decisions, the call's request-log
  # row, the execution tree and the policy logs.
  # ----------------------------------------------------------------------------

  attr :tree, :map, required: true
  attr :decision, :map, required: true

  defp expanded_tree(assigns) do
    # The call's own request-log row carries its input and output; a
    # refusal before any caller was established has none.
    log =
      Enum.find(Map.get(assigns.tree, :mcp_logs, []), &(f(&1, :id) == assigns.decision.call_id)) ||
        %{}

    has_input = f(log, :input) not in [nil, "", %{}]
    has_output = f(log, :output) not in [nil, "", %{}]
    has_error = f(log, :error) not in [nil, ""]
    show_error = has_error and not has_output
    has_right = has_output or show_error

    assigns =
      assigns
      |> assign(:log, log)
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
            <span class="truncate" title={@decision.request_id}>
              {@decision.request_id || "—"}
            </span>
            <button
              :if={@decision.request_id}
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: @decision.request_id})}
              class="text-gray-500 hover:text-gray-300 shrink-0"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Call ID</dt>
          <dd class="text-white mt-0.5 font-mono text-xs flex items-center gap-1.5">
            <span class="truncate" title={@decision.call_id}>{@decision.call_id}</span>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: @decision.call_id})}
              class="text-gray-500 hover:text-gray-300 shrink-0"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Routed To</dt>
          <dd class="text-white mt-0.5 font-mono text-xs truncate">{f(@log, :routed_to) || "—"}</dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">When</dt>
          <dd class="text-white mt-0.5 text-xs truncate">
            {Prima.Time.iso8601(@decision.inserted_at) || "—"}
          </dd>
        </div>
      </dl>

      <p :if={@decision.reason} class="text-xs text-gray-400">
        <span class="text-gray-500 uppercase">Reason</span>
        <span class="ml-2">{@decision.reason}</span>
      </p>
      
    <!-- The request's decisions: every call of its chain -->
      <section :if={Map.get(@tree, :decisions) not in [nil, []]}>
        <h4 class="text-xs font-medium uppercase tracking-wider text-gray-500 mb-2">
          Decisions ({length(@tree.decisions)})
        </h4>
        <div class="rounded-lg border border-gray-800 bg-gray-900/60 overflow-hidden">
          <%= for call <- @tree.decisions do %>
            <div class="flex items-center gap-3 px-4 py-1.5 text-sm border-t border-gray-800/60 first:border-t-0">
              <.decision_state status={admission_status(call)}>
                {admission_label(call)}
              </.decision_state>
              <span class="text-gray-300 font-mono text-xs flex-1 min-w-0 truncate">
                {operation_label(call)}
              </span>
              <span class="text-gray-500 text-xs whitespace-nowrap">{plane_label(call.plane)}</span>
              <span class="text-gray-500 text-xs whitespace-nowrap">{completion_label(call)}</span>
              <span class="text-gray-600 text-xs font-mono whitespace-nowrap" title={call.call_id}>
                {truncate(call.call_id, 14)}
              </span>
            </div>
          <% end %>
        </div>
      </section>
      
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
                {truncate(f(exec, :id), 14)}
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

  # Order executions parent-first and annotate depth in a single traversal.
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
