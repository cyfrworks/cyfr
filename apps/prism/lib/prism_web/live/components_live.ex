defmodule PrismWeb.ComponentsLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Components")
     |> assign(:components, [])
     |> assign(:categories, [])
     |> assign(:search, "")
     |> assign(:selected_category, nil)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    categories =
      case call_tool(socket, "component/categories", %{}) do
        {:ok, %{categories: cats}} -> cats
        {:ok, cats} when is_list(cats) -> cats
        _ -> []
      end

    components =
      case call_tool(socket, "component/search", %{}) do
        {:ok, %{components: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:categories, categories)
     |> assign(:components, components)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    args = %{"query" => query}

    args =
      if cat = socket.assigns.selected_category do
        Map.put(args, "category", cat)
      else
        args
      end

    components =
      case call_tool(socket, "component/search", args) do
        {:ok, %{components: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:search, query)
     |> assign(:components, components)}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    category = if category == "", do: nil, else: category

    args = if category, do: %{"category" => category}, else: %{}

    args =
      if socket.assigns.search != "" do
        Map.put(args, "query", socket.assigns.search)
      else
        args
      end

    components =
      case call_tool(socket, "component/search", args) do
        {:ok, %{components: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:selected_category, category)
     |> assign(:components, components)}
  end

  defp cat_name(cat) when is_binary(cat), do: cat
  defp cat_name(cat) when is_map(cat), do: cat[:name] || cat["name"] || inspect(cat)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Components</h2>
      </div>

      <!-- Search and filters -->
      <div class="flex gap-4">
        <form phx-change="search" phx-submit="search" class="flex-1">
          <input
            type="text"
            name="query"
            value={@search}
            placeholder="Search components..."
            phx-debounce="300"
            class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          />
        </form>
        <form phx-change="filter_category">
          <select
            name="category"
            class="rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All Categories</option>
            <option :for={cat <- @categories} value={cat_name(cat)} selected={cat_name(cat) == @selected_category}>
              {cat_name(cat)}
            </option>
          </select>
        </form>
      </div>

      <!-- Components grid -->
      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading && @components == []} class="py-8">
        <.empty_state message="No components found" />
      </div>

      <div :if={!@loading && @components != []} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <a
          :for={comp <- @components}
          href={~p"/components/#{comp[:component_ref] || comp["component_ref"] || comp[:ref] || comp["ref"] || comp[:name] || comp["name"] || "unknown"}"}
          class="block"
        >
          <.card class="hover:border-gray-700 transition-colors h-full">
            <h3 class="font-medium text-white">
              {comp[:name] || comp["name"] || "-"}
            </h3>
            <p :if={comp[:description] || comp["description"]} class="text-xs text-gray-400 mt-1 line-clamp-2">
              {comp[:description] || comp["description"]}
            </p>
            <div class="flex items-center gap-2 mt-3">
              <.badge :if={comp[:category] || comp["category"]} color="blue">
                {comp[:category] || comp["category"]}
              </.badge>
              <.badge :if={comp[:version] || comp["version"]} color="gray">
                {comp[:version] || comp["version"]}
              </.badge>
            </div>
          </.card>
        </a>
      </div>
    </div>
    """
  end
end
