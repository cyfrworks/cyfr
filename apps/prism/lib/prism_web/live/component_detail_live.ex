defmodule PrismWeb.ComponentDetailLive do
  use PrismWeb, :live_view

  @impl true
  def mount(%{"ref" => ref}, _session, socket) do
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
      case call_tool(socket, "component/inspect", %{"reference" => ref}) do
        {:ok, comp} -> comp
        _ -> nil
      end

    readme =
      case call_tool(socket, "guide/readme", %{"reference" => ref}) do
        {:ok, %{content: content}} -> content
        {:ok, content} when is_binary(content) -> content
        _ -> nil
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
      {:ok, %{execution_id: id}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Execution started.")
         |> push_navigate(to: ~p"/executions/#{id}")}

      {:ok, result} ->
        {:noreply, put_flash(socket, :info, "Execution started: #{inspect(result)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to execute: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <a href={~p"/components"} class="text-sm text-gray-500 hover:text-gray-300">
          &larr; Back to Components
        </a>
        <h2 class="text-lg font-semibold text-white mt-1">{@ref}</h2>
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
    </div>
    """
  end
end
