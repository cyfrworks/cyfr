# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentDetailLive do
  use PrismWeb, :live_view

  require Logger

  @impl true
  def mount(%{"ref" => ref}, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Cyfr.Bus.components(ctx))
    end

    {:ok,
     socket
     |> assign(:page_title, "Component: #{ref}")
     |> assign(:ref, ref)
     |> assign(:component, nil)
     |> assign(:readme, nil)
     |> assign(:loading, true)
     |> assign(:execute_form, %{"input" => ""})}
  end

  @impl true
  def handle_params(%{"ref" => ref}, _uri, socket) do
    component =
      case call_tool(socket, "component/inspect", %{
             "reference" => ref,
             "include_readme" => true
           }) do
        {:ok, comp} ->
          comp

        other ->
          Logger.warning("[ComponentDetailLive] component/inspect failed: #{inspect(other)}")
          nil
      end

    readme = extract_readme(component)

    {:noreply,
     socket
     |> assign(:component, component)
     |> assign(:readme, readme)
     |> assign(:loading, false)}
  end

  defp extract_readme(nil), do: nil

  defp extract_readme(comp) when is_map(comp) do
    case Map.get(comp, "readme") || Map.get(comp, :readme) do
      r when is_binary(r) and r != "" -> r
      _ -> nil
    end
  end

  defp extract_readme(_), do: nil

  @impl true
  def handle_event("execute", %{"input" => input}, socket) do
    args = %{"reference" => socket.assigns.ref}
    args = if input != "", do: Map.put(args, "input", input), else: args

    case call_tool(socket, "execution/run", args) do
      {:ok, %{execution_id: _id}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Execution started.")
         |> push_navigate(to: PrismWeb.Focus.path(socket.assigns.athanor_route, "/activities"))}

      {:ok, _result} ->
        {:noreply, put_flash(socket, :info, "Execution started.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to execute: #{error_message(reason)}")}
    end
  end

  def handle_event("open_report", _params, socket) do
    PrismWeb.ReportComponent.open("report", socket.assigns.ref)
    {:noreply, socket}
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

  def handle_info({:report_component, :submitted}, socket) do
    {:noreply, put_flash(socket, :info, "Report submitted. Thanks.")}
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <a
            href={PrismWeb.Focus.path(@athanor_route, "/components")}
            class="text-sm text-gray-500 hover:text-gray-300"
          >
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
      
    <!-- Report modal — the shared component owns taxonomy, validation and submit -->
      <.live_component
        module={PrismWeb.ReportComponent}
        id="report"
        context={@context}
        athanor_route={@athanor_route}
      />
    </div>
    """
  end
end
