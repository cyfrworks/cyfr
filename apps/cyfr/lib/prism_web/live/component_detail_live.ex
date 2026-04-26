defmodule PrismWeb.ComponentDetailLive do
  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS
  require Logger

  @report_categories [
    {"csam", "Child sexual abuse material"},
    {"ncii", "Non-consensual intimate imagery"},
    {"objectionable", "Violence / hate / sexual content"},
    {"malware", "Malware / unsafe code"},
    {"impersonation", "Impersonation"},
    {"dmca", "Copyright (DMCA)"},
    {"ip_infringement", "Trademark / patent infringement"},
    {"security", "Security vulnerability"},
    {"policy_violation", "Acceptable-use policy violation"},
    {"spam", "Spam"},
    {"other", "Other"}
  ]

  @report_details_max 4096

  @impl true
  def mount(%{"ref" => ref}, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:components", ctx))
    end

    {:ok,
     socket
     |> assign(:page_title, "Component: #{ref}")
     |> assign(:ref, ref)
     |> assign(:component, nil)
     |> assign(:readme, nil)
     |> assign(:loading, true)
     |> assign(:execute_form, %{"input" => ""})
     |> assign(:report_open, false)
     |> assign(:report_submitting, false)
     |> assign(:report_error, nil)}
  end

  @impl true
  def handle_params(%{"ref" => ref}, _uri, socket) do
    component =
      case call_tool(socket, "component/inspect", %{"reference" => ref}) do
        {:ok, comp} ->
          comp

        other ->
          Logger.warning("[ComponentDetailLive] component/inspect failed: #{inspect(other)}")
          nil
      end

    readme =
      case call_tool(socket, "guide/readme", %{"reference" => ref}) do
        {:ok, %{content: content}} ->
          content

        {:ok, content} when is_binary(content) ->
          content

        other ->
          Logger.warning("[ComponentDetailLive] guide/readme failed: #{inspect(other)}")
          nil
      end

    {:noreply,
     socket
     |> assign(:component, component)
     |> assign(:readme, readme)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("execute", %{"input" => input}, socket) do
    args = %{"reference" => socket.assigns.ref}
    args = if input != "", do: Map.put(args, "input", input), else: args

    case call_tool(socket, "execution/run", args) do
      {:ok, %{execution_id: _id}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Execution started.")
         |> push_navigate(to: ~p"/logs")}

      {:ok, result} ->
        {:noreply, put_flash(socket, :info, "Execution started: #{inspect(result)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to execute: #{inspect(reason)}")}
    end
  end

  def handle_event("open_report", _params, socket) do
    {:noreply,
     socket
     |> assign(:report_open, true)
     |> assign(:report_error, nil)}
  end

  def handle_event("close_report", _params, socket) do
    {:noreply,
     socket
     |> assign(:report_open, false)
     |> assign(:report_error, nil)}
  end

  def handle_event("submit_report", %{"category" => category, "details" => details}, socket) do
    details = String.trim(details || "")
    category = String.trim(category || "")

    cond do
      category == "" ->
        {:noreply, assign(socket, :report_error, "Pick a category.")}

      details == "" ->
        {:noreply, assign(socket, :report_error, "Describe the issue.")}

      String.length(details) > @report_details_max ->
        {:noreply,
         assign(socket, :report_error, "Details too long (max #{@report_details_max} chars).")}

      true ->
        socket = assign(socket, :report_submitting, true)

        args = %{
          "action" => "report",
          "category" => category,
          "target_component_ref" => socket.assigns.ref,
          "details" => details
        }

        case call_tool(socket, "registry", args) do
          {:ok, _body} ->
            {:noreply,
             socket
             |> assign(:report_open, false)
             |> assign(:report_submitting, false)
             |> assign(:report_error, nil)
             |> put_flash(:info, "Report submitted. Thanks.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:report_submitting, false)
             |> assign(:report_error, format_err(reason))}
        end
    end
  end

  @impl true
  def handle_info(:components_changed, socket) do
    ref = socket.assigns.ref

    component =
      case call_tool(socket, "component/inspect", %{"reference" => ref}) do
        {:ok, comp} -> comp
        _ -> socket.assigns.component
      end

    {:noreply, assign(socket, :component, component)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ComponentDetailLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp format_err(reason) when is_binary(reason), do: reason
  defp format_err(%{message: msg}) when is_binary(msg), do: msg
  defp format_err(other), do: inspect(other)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :report_categories, @report_categories)

    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <a href={~p"/components"} class="text-sm text-gray-500 hover:text-gray-300">
            &larr; Back to Components
          </a>
          <h2 class="text-lg font-semibold text-white mt-1">{@ref}</h2>
        </div>
        <button
          :if={!@loading && @component}
          phx-click="open_report"
          class="shrink-0 px-3 py-1.5 text-xs rounded border border-gray-700 bg-gray-800 text-gray-300 hover:bg-red-900/40 hover:text-red-200 hover:border-red-800"
          title="Report this component to cyfr.run moderators"
        >
          Report
        </button>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @component} class="space-y-6">
        <!-- Metadata -->
        <.card>
          <dl class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <dt class="text-xs text-gray-500 uppercase">Name</dt>
              <dd class="text-sm text-white mt-1">
                {@component[:name] || @component["name"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Version</dt>
              <dd class="text-sm text-white mt-1">
                {@component[:version] || @component["version"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Category</dt>
              <dd class="text-sm text-white mt-1">
                {@component[:category] || @component["category"] || "-"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500 uppercase">Language</dt>
              <dd class="text-sm text-white mt-1">
                {@component[:language] || @component["language"] || "-"}
              </dd>
            </div>
          </dl>
        </.card>

    <!-- Description -->
        <.card :if={@component[:description] || @component["description"]}>
          <h3 class="text-sm font-medium text-gray-400 mb-2">Description</h3>
          <p class="text-sm text-gray-300">
            {@component[:description] || @component["description"]}
          </p>
        </.card>

    <!-- Execute -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-3">Execute Component</h3>
          <form phx-submit="execute" class="flex gap-3">
            <input
              type="text"
              name="input"
              placeholder="Input (optional)"
              class="flex-1 rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            />
            <.button type="submit">Execute</.button>
          </form>
        </.card>

    <!-- README -->
        <.card :if={@readme}>
          <h3 class="text-sm font-medium text-gray-400 mb-2">README</h3>
          <div class="prose prose-invert prose-sm max-w-none">
            <pre class="text-xs text-gray-300 whitespace-pre-wrap">{@readme}</pre>
          </div>
        </.card>

    <!-- Dependencies -->
        <.card :if={@component[:dependencies] || @component["dependencies"]}>
          <h3 class="text-sm font-medium text-gray-400 mb-2">Dependencies</h3>
          <ul class="space-y-1">
            <li
              :for={dep <- @component[:dependencies] || @component["dependencies"] || []}
              class="text-sm text-gray-300"
            >
              {dep}
            </li>
          </ul>
        </.card>
      </div>

      <div :if={!@loading && !@component}>
        <.empty_state message="Component not found" />
      </div>

      <!-- Report modal -->
      <.modal
        id="report-modal"
        show={@report_open}
        on_cancel={JS.push("close_report")}
      >
        <div class="space-y-4">
          <div>
            <h3 class="text-base font-semibold text-white">Report this component</h3>
            <p class="text-sm text-gray-400 mt-1">
              <span class="font-mono text-gray-300">{@ref}</span>
            </p>
            <p class="text-xs text-gray-500 mt-2">
              Your report goes to cyfr.run moderators. Track status under
              <a href="/reports" class="underline hover:text-gray-400">My Reports</a>.
            </p>
          </div>

          <form phx-submit="submit_report" class="space-y-3">
            <div>
              <label class="text-xs text-gray-500 uppercase">Category</label>
              <select
                name="category"
                required
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-red-600 focus:ring-1 focus:ring-red-600"
              >
                <option value="">Select…</option>
                <option :for={{value, label} <- @report_categories} value={value}>{label}</option>
              </select>
            </div>

            <div>
              <label class="text-xs text-gray-500 uppercase">Details</label>
              <textarea
                name="details"
                required
                rows="4"
                maxlength="4096"
                placeholder="What's wrong? Include URLs, commit hashes, screenshots…"
                class="w-full mt-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-sm text-white focus:border-red-600 focus:ring-1 focus:ring-red-600"
                autofocus
              ></textarea>
            </div>

            <div
              :if={@report_error}
              class="text-xs text-red-300 bg-red-900/40 border border-red-800 rounded px-3 py-2"
            >
              {@report_error}
            </div>

            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="close_report"
                class="px-3 py-1.5 text-xs rounded bg-gray-800 text-gray-300 border border-gray-700 hover:bg-gray-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={@report_submitting}
                phx-disable-with="Sending…"
                class="px-3 py-1.5 text-xs rounded bg-red-900 text-red-100 border border-red-700 hover:bg-red-800 disabled:opacity-50"
              >
                Submit report
              </button>
            </div>
          </form>
        </div>
      </.modal>
    </div>
    """
  end
end
