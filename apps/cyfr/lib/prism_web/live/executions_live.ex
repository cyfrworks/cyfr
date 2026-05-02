defmodule PrismWeb.ExecutionsLive do
  @moduledoc """
  Opus execution monitor — every WASM run, grouped by the request that
  triggered it and laid out as a parent/child tree.

  Distinct from `ActivityLive` (`/activity`):

  - `/activity` is **request-anchored** — one row per `Arca.McpLog`
    request, with executions surfaced as a fan-out count and tree on
    row expand. Right surface for "what happened around request X."
  - `/executions` is **execution-anchored** — every `Arca.Execution` is
    a row, organised by request_id (collapsible sections) with the
    parent_execution_id tree shown via indentation. Right surface for
    "what's running right now / why did this WASM fail / what did the
    formula spawn."

  Both subscribe to `prism:executions` for live updates.

  ## Data shape

  Executions form a 3-level hierarchy at the data layer:

      request_id (Arca.McpLog row, shared)
      └── root execution        parent_execution_id = nil
            ├── child           parent_execution_id = root.id
            │   └── grandchild  parent_execution_id = child.id
            └── child

  Trees can be deeper than 2 levels (formula → sub-formula → catalyst),
  but `parent_execution_id` always points exactly one step up. Roots
  within a request are rows where `parent_execution_id` is nil. Orphan
  children whose parent isn't in the visible page are also treated as
  local roots (rendered at depth 0 with a small indicator).
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS

  require Logger

  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:executions", ctx))
    end

    {:ok,
     socket
     |> assign(:page_title, "Executions")
     |> assign(:active_nav, "executions")
     |> assign(:executions, [])
     |> assign(:groups, [])
     |> assign(:collapsed_groups, MapSet.new())
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:status_filter, nil)
     |> assign(:type_filter, nil)
     |> assign(:expanded_id, nil)
     |> assign(:expanded_detail, nil)
     |> assign(:expanded_loading, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:status_filter, normalize(params["status"]))
      |> assign(:type_filter, normalize(params["type"]))

    if connected?(socket) do
      {:noreply, fetch_executions(socket)}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("filter", %{"status" => status, "type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:status_filter, normalize(status))
     |> assign(:type_filter, normalize(type))
     |> fetch_executions()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, fetch_executions(socket)}

  def handle_event("toggle_group", %{"id" => request_id}, socket) do
    set =
      if MapSet.member?(socket.assigns.collapsed_groups, request_id) do
        MapSet.delete(socket.assigns.collapsed_groups, request_id)
      else
        MapSet.put(socket.assigns.collapsed_groups, request_id)
      end

    {:noreply, assign(socket, :collapsed_groups, set)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply,
       socket
       |> assign(:expanded_id, nil)
       |> assign(:expanded_detail, nil)
       |> assign(:expanded_loading, false)}
    else
      send(self(), {:load_detail, id})

      {:noreply,
       socket
       |> assign(:expanded_id, id)
       |> assign(:expanded_detail, nil)
       |> assign(:expanded_loading, true)}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case call_tool(socket, "execution", %{"action" => "cancel", "execution_id" => id}) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Cancellation requested.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Cancel failed: #{inspect(reason)}")}
    end
  end

  # ============================================================================
  # PubSub fan-in
  # ============================================================================

  @impl true
  def handle_info({:execution_started, metadata, _meas}, socket) do
    eid = metadata[:execution_id]

    if eid && Enum.any?(socket.assigns.executions, &(f(&1, :execution_id) == eid)) do
      {:noreply, socket}
    else
      entry = %{
        execution_id: eid,
        request_id: metadata[:request_id],
        parent_execution_id: metadata[:parent_execution_id],
        reference: metadata[:component] || metadata[:reference],
        component_type: metadata[:component_type] && to_string(metadata[:component_type]),
        status: "running",
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        duration_ms: nil,
        error: nil
      }

      if matches?(entry, socket.assigns.status_filter, socket.assigns.type_filter) do
        executions = [entry | socket.assigns.executions] |> Enum.take(@page_size)
        {:noreply, socket |> assign(:executions, executions) |> regroup()}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info({:execution_completed, metadata, _meas}, socket) do
    {:noreply, socket |> update_execution(metadata, "completed") |> regroup()}
  end

  def handle_info({:execution_failed, metadata, _meas}, socket) do
    status = if metadata[:status] == :cancelled, do: "cancelled", else: "failed"
    {:noreply, socket |> update_execution(metadata, status) |> regroup()}
  end

  def handle_info({:load_detail, id}, socket) do
    if socket.assigns.expanded_id == id do
      detail =
        case call_tool(socket, "execution", %{"action" => "logs", "execution_id" => id}) do
          {:ok, result} -> result
          _ -> nil
        end

      {:noreply, socket |> assign(:expanded_detail, detail) |> assign(:expanded_loading, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[ExecutionsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Data
  # ============================================================================

  defp fetch_executions(socket) do
    args =
      %{"action" => "list", "limit" => @page_size}
      |> maybe_put("status", socket.assigns.status_filter)

    case call_tool(socket, "execution", args) do
      {:ok, %{executions: list}} when is_list(list) ->
        filtered = filter_by_type(list, socket.assigns.type_filter)

        socket
        |> assign(:executions, filtered)
        |> assign(:loading, false)
        |> assign(:error, nil)
        |> regroup()

      {:error, reason} ->
        Logger.warning("[ExecutionsLive] list failed: #{inspect(reason)}")

        socket
        |> assign(:executions, [])
        |> assign(:groups, [])
        |> assign(:loading, false)
        |> assign(:error, "Failed to load executions: #{inspect(reason)}")

      _ ->
        socket
        |> assign(:executions, [])
        |> assign(:groups, [])
        |> assign(:loading, false)
    end
  end

  defp update_execution(socket, metadata, status) do
    target = metadata[:execution_id]

    list =
      Enum.map(socket.assigns.executions, fn exec ->
        if f(exec, :execution_id) == target do
          exec
          |> Map.put(:status, status)
          |> put_some(:duration_ms, metadata[:duration_ms])
          |> put_some(:error, metadata[:error])
          |> put_some(:request_id, metadata[:request_id])
          |> put_some(:component_type, metadata[:component_type] && to_string(metadata[:component_type]))
          |> put_some(:parent_execution_id, metadata[:parent_execution_id])
        else
          exec
        end
      end)

    assign(socket, :executions, list)
  end

  # ============================================================================
  # Grouping + tree flattening
  # ============================================================================

  defp regroup(socket) do
    assign(socket, :groups, build_groups(socket.assigns.executions))
  end

  defp build_groups(executions) do
    executions
    |> Enum.group_by(fn e -> f(e, :request_id) || "(no request)" end)
    |> Enum.map(fn {request_id, execs} ->
      flat = flatten_tree(execs)
      total_duration = Enum.reduce(execs, 0, fn e, acc -> acc + (f(e, :duration_ms) || 0) end)
      latest = latest_started_at(execs)
      running = Enum.count(execs, &(f(&1, :status) == "running"))

      %{
        request_id: request_id,
        executions: flat,
        count: length(execs),
        total_duration_ms: total_duration,
        latest_started_at: latest,
        running: running
      }
    end)
    |> Enum.sort_by(& &1.latest_started_at, fn a, b -> a >= b end)
  end

  # Depth-first walk producing a flat list with `:__depth` and `:__last`
  # annotations. Roots are `parent_execution_id == nil` plus orphans whose
  # parent isn't in the page (so the row still renders).
  defp flatten_tree(executions) do
    by_parent = Enum.group_by(executions, fn e -> f(e, :parent_execution_id) end)
    exec_ids = MapSet.new(Enum.map(executions, &f(&1, :execution_id)))

    real_roots = Map.get(by_parent, nil, [])

    orphan_roots =
      by_parent
      |> Map.delete(nil)
      |> Enum.flat_map(fn {parent_id, children} ->
        if parent_id && MapSet.member?(exec_ids, parent_id), do: [], else: children
      end)

    roots = sort_by_started_at_asc(real_roots ++ orphan_roots)

    Enum.flat_map(roots, fn root -> walk(root, by_parent, 0) end)
  end

  defp walk(exec, by_parent, depth) do
    exec_id = f(exec, :execution_id)
    children = Map.get(by_parent, exec_id, []) |> sort_by_started_at_asc()

    [Map.put(exec, :__depth, depth) | Enum.flat_map(children, &walk(&1, by_parent, depth + 1))]
  end

  defp sort_by_started_at_asc(execs) do
    Enum.sort_by(execs, fn e -> f(e, :started_at) || "" end)
  end

  defp latest_started_at(execs) do
    execs
    |> Enum.map(&(f(&1, :started_at) || ""))
    |> Enum.max(fn -> "" end)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp filter_by_type(list, nil), do: list
  defp filter_by_type(list, type), do: Enum.filter(list, &(f(&1, :component_type) == type))

  defp matches?(entry, status_filter, type_filter) do
    (is_nil(status_filter) or f(entry, :status) == status_filter) and
      (is_nil(type_filter) or f(entry, :component_type) == type_filter)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize(nil), do: nil
  defp normalize(""), do: nil
  defp normalize(v), do: v

  defp f(m, k), do: m[k] || m[to_string(k)]

  defp type_class("catalyst"), do: "bg-purple-900/30 text-purple-300"
  defp type_class("reagent"), do: "bg-blue-900/30 text-blue-300"
  defp type_class("formula"), do: "bg-emerald-900/30 text-emerald-300"
  defp type_class(_), do: "bg-gray-800 text-gray-400"

  defp short(nil), do: "-"
  defp short(s) when is_binary(s) and byte_size(s) > 14, do: String.slice(s, 0, 14) <> "…"
  defp short(s), do: to_string(s)

  defp running_count(executions) do
    Enum.count(executions, &(f(&1, :status) == "running"))
  end

  # Indent the Reference cell by depth. Inline style so depth can grow
  # arbitrarily without a fixed Tailwind class for each level.
  defp depth_padding(depth), do: "padding-left: #{0.5 + depth * 1.25}rem"

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Executions">
        <:actions>
          <span class="flex items-center gap-1.5 text-xs text-green-400">
            <span class="h-2 w-2 rounded-full bg-green-400 animate-pulse" /> Live
          </span>
          <span :if={running_count(@executions) > 0} class="text-xs text-amber-400">
            {running_count(@executions)} running
          </span>
          <.button size="sm" variant="secondary" phx-click="refresh">Refresh</.button>
        </:actions>
      </.page_header>

      <div class="flex items-center gap-3 flex-wrap">
        <form phx-change="filter" class="flex gap-3">
          <select
            name="status"
            class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
          >
            <option value="" selected={is_nil(@status_filter)}>All statuses</option>
            <option value="running" selected={@status_filter == "running"}>running</option>
            <option value="completed" selected={@status_filter == "completed"}>completed</option>
            <option value="failed" selected={@status_filter == "failed"}>failed</option>
            <option value="cancelled" selected={@status_filter == "cancelled"}>cancelled</option>
          </select>
          <select
            name="type"
            class="bg-gray-800 text-gray-300 text-sm rounded-md border-gray-700 px-3 py-1.5"
          >
            <option value="" selected={is_nil(@type_filter)}>All types</option>
            <option value="catalyst" selected={@type_filter == "catalyst"}>catalyst</option>
            <option value="reagent" selected={@type_filter == "reagent"}>reagent</option>
            <option value="formula" selected={@type_filter == "formula"}>formula</option>
          </select>
        </form>
      </div>

      <.live_loading :if={@loading} message="Loading executions…" />
      <.live_error :if={!@loading && @error} message={@error} />
      <.live_empty :if={!@loading && !@error && @groups == []} message="No executions yet." />

      <div :if={!@loading && !@error && @groups != []} class="overflow-x-auto rounded-lg border border-gray-800 bg-gray-900">
        <table class="min-w-full table-fixed">
          <thead class="border-b border-gray-800 bg-gray-900/60">
            <tr>
              <th class="w-[10%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">Type</th>
              <th class="w-[42%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">Reference</th>
              <th class="w-[10%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">Status</th>
              <th class="w-[10%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">Duration</th>
              <th class="w-[16%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">Execution</th>
              <th class="w-[12%] px-4 py-2 text-left text-[10px] font-medium uppercase tracking-wider text-gray-500">Started</th>
            </tr>
          </thead>
          <tbody>
            <%= for group <- @groups do %>
              <% collapsed = MapSet.member?(@collapsed_groups, group.request_id) %>
              <tr class="border-t border-gray-800 bg-gray-800/30 hover:bg-gray-800/50 cursor-pointer">
                <td colspan="6" class="px-4 py-1.5" phx-click="toggle_group" phx-value-id={group.request_id}>
                  <div class="flex items-center justify-between gap-3 text-xs">
                    <div class="flex items-center gap-2 min-w-0">
                      <span class="text-gray-500 font-mono w-3 text-center">{if collapsed, do: "▶", else: "▼"}</span>
                      <span class="text-blue-400 font-mono truncate" title={group.request_id}>
                        {group.request_id}
                      </span>
                      <span :if={group.running > 0} class="inline-flex items-center gap-1 text-amber-400">
                        <span class="h-1.5 w-1.5 rounded-full bg-amber-400 animate-pulse" />
                        {group.running} running
                      </span>
                    </div>
                    <div class="flex items-center gap-3 text-gray-500 whitespace-nowrap">
                      <span>{group.count} {if group.count == 1, do: "exec", else: "execs"}</span>
                      <span :if={group.total_duration_ms > 0}>{format_duration(group.total_duration_ms)}</span>
                      <span>{relative_time(group.latest_started_at)}</span>
                    </div>
                  </div>
                </td>
              </tr>

              <%= if !collapsed do %>
                <%= for exec <- group.executions do %>
                  <% eid = f(exec, :execution_id) || "-" %>
                  <% depth = exec[:__depth] || 0 %>
                  <tr
                    phx-click="toggle_expand"
                    phx-value-id={eid}
                    class={[
                      "border-t border-gray-800/60 cursor-pointer transition-colors",
                      if(@expanded_id == eid, do: "bg-gray-800/80", else: "hover:bg-gray-800/40")
                    ]}
                  >
                    <td class="px-4 py-2 text-sm whitespace-nowrap">
                      <span class={["inline-flex items-center px-2 py-0.5 rounded text-xs font-medium", type_class(f(exec, :component_type))]}>
                        {f(exec, :component_type) || "—"}
                      </span>
                    </td>
                    <td class="py-2 text-sm text-gray-300 truncate max-w-0" style={depth_padding(depth)}>
                      <span :if={depth > 0} class="text-gray-600 mr-1">↳</span>
                      {format_ref(f(exec, :reference))}
                    </td>
                    <td class="px-4 py-2 text-sm whitespace-nowrap">
                      <.status_indicator status={to_string(f(exec, :status) || "unknown")} />
                    </td>
                    <td class="px-4 py-2 text-sm text-gray-300 whitespace-nowrap">
                      {format_duration(f(exec, :duration_ms))}
                    </td>
                    <td class="px-4 py-2 text-sm whitespace-nowrap">
                      <span class="text-blue-400 font-mono text-xs" title={eid}>{short(eid)}</span>
                    </td>
                    <td class="px-4 py-2 text-sm whitespace-nowrap">
                      <span class="text-xs text-gray-400" title={f(exec, :started_at)}>
                        {relative_time(f(exec, :started_at))}
                      </span>
                    </td>
                  </tr>

                  <tr :if={@expanded_id == eid} class="border-t border-gray-800/60 bg-gray-900/60">
                    <td colspan="6" class="px-4 py-4">
                      <.live_loading :if={@expanded_loading} message="Loading detail…" />

                      <div :if={!@expanded_loading && @expanded_detail} class="space-y-4">
                        <.expanded_detail detail={@expanded_detail} />
                      </div>

                      <.live_empty
                        :if={!@expanded_loading && !@expanded_detail}
                        message="No detail available."
                      />
                    </td>
                  </tr>
                <% end %>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :detail, :map, required: true

  defp expanded_detail(assigns) do
    has_input = f(assigns.detail, :input) not in [nil, %{}]
    has_output = f(assigns.detail, :output) not in [nil, %{}]
    has_error = f(assigns.detail, :error) not in [nil, ""]
    # Error and output are mutually exclusive in the schema; error fills the
    # right column when the execution failed.
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
      <dl class="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Execution ID</dt>
          <dd class="text-white mt-0.5 font-mono text-xs flex items-center gap-1.5">
            <span class="truncate" title={f(@detail, :execution_id)}>{f(@detail, :execution_id)}</span>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: f(@detail, :execution_id)})}
              class="text-gray-500 hover:text-gray-300 shrink-0"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Request ID</dt>
          <dd class="text-white mt-0.5 font-mono text-xs flex items-center gap-1.5">
            <span class="truncate" title={f(@detail, :request_id)}>{f(@detail, :request_id) || "—"}</span>
            <button
              :if={f(@detail, :request_id)}
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: f(@detail, :request_id)})}
              class="text-gray-500 hover:text-gray-300 shrink-0"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Started</dt>
          <dd class="text-white mt-0.5 text-xs truncate">{f(@detail, :started_at)}</dd>
        </div>
        <div class="min-w-0">
          <dt class="text-xs text-gray-500 uppercase">Completed</dt>
          <dd class="text-white mt-0.5 text-xs truncate">{f(@detail, :completed_at) || "—"}</dd>
        </div>
      </dl>

      <div :if={@has_input or @has_right} class="grid gap-4 md:grid-cols-2">
        <section :if={@has_input} class={if !@has_right, do: "md:col-span-2", else: ""}>
          <div class="flex items-center justify-between mb-1">
            <h4 class="text-xs font-medium text-gray-400">Input</h4>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(f(@detail, :input))})}
              class="text-gray-500 hover:text-gray-300"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </div>
          <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(f(@detail, :input))}</code></pre>
        </section>
        <section :if={@has_output} class={if !@has_input, do: "md:col-span-2", else: ""}>
          <div class="flex items-center justify-between mb-1">
            <h4 class="text-xs font-medium text-gray-400">Output</h4>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: format_json(f(@detail, :output))})}
              class="text-gray-500 hover:text-gray-300"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </div>
          <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{format_json(f(@detail, :output))}</code></pre>
        </section>
        <section :if={@show_error} class={if !@has_input, do: "md:col-span-2", else: ""}>
          <div class="flex items-center justify-between mb-1">
            <h4 class="text-xs font-medium text-red-400">Error</h4>
            <button
              phx-click={JS.dispatch("phx:clipboard", detail: %{text: to_string(f(@detail, :error))})}
              class="text-gray-500 hover:text-gray-300"
              title="Copy"
            >
              <.icon name="clipboard" class="h-3.5 w-3.5" />
            </button>
          </div>
          <pre class="text-xs text-red-300 bg-red-950/40 rounded p-3 border border-red-900/50 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{f(@detail, :error)}</code></pre>
        </section>
      </div>

      <section :if={f(@detail, :logs) not in [nil, "", []]}>
        <div class="flex items-center justify-between mb-1">
          <h4 class="text-xs font-medium text-gray-400">Logs</h4>
          <button
            phx-click={JS.dispatch("phx:clipboard", detail: %{text: to_string(f(@detail, :logs))})}
            class="text-gray-500 hover:text-gray-300"
            title="Copy"
          >
            <.icon name="clipboard" class="h-3.5 w-3.5" />
          </button>
        </div>
        <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-auto max-h-48 whitespace-pre-wrap break-all"><code>{f(@detail, :logs)}</code></pre>
      </section>
    </div>
    """
  end
end
