defmodule PrismWeb.BuildsLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Builds")
     |> assign(:toolchains, [])
     |> assign(:reference, "")
     |> assign(:build_output, nil)
     |> assign(:building, false)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    toolchains =
      case call_tool(socket, "build/toolchains", %{}) do
        {:ok, %{toolchains: tc}} when is_map(tc) -> normalize_toolchains(tc)
        {:ok, %{toolchains: list}} when is_list(list) -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    {:noreply,
     socket
     |> assign(:toolchains, toolchains)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("compile", %{"reference" => reference}, socket) do
    socket = assign(socket, :building, true)

    args = %{"reference" => reference}

    case call_tool(socket, "build/compile", args) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:build_output, result)
         |> assign(:building, false)
         |> put_flash(:info, "Build completed successfully.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:build_output, %{error: reason})
         |> assign(:building, false)
         |> put_flash(:error, "Build failed: #{inspect(reason)}")}
    end
  end

  def handle_event("validate", %{"wasm_base64" => wasm_base64}, socket) do
    case call_tool(socket, "build/validate", %{"wasm_base64" => wasm_base64}) do
      {:ok, result} ->
        {:noreply, assign(socket, :build_output, result)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Validation failed: #{inspect(reason)}")}
    end
  end

  defp normalize_toolchains(map) when is_map(map) do
    Enum.map(map, fn {lang, info} ->
      Map.merge(info, %{name: to_string(lang)})
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Builds</h2>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <!-- Build form -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Compile Component</h3>
          <form phx-submit="compile" class="space-y-4">
            <div>
              <label class="block text-xs text-gray-500 uppercase mb-1">Component Reference</label>
              <input
                type="text"
                name="reference"
                value={@reference}
                placeholder="catalyst:local.my-api:0.1.0"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
            </div>
            <div class="flex gap-3">
              <.button type="submit" class={@building && "opacity-50"}>
                {if @building, do: "Building...", else: "Compile"}
              </.button>
            </div>
          </form>
          <div class="mt-4 border-t border-gray-700 pt-4">
            <h4 class="text-xs text-gray-500 uppercase mb-2">Validate WASM</h4>
            <form phx-submit="validate" class="space-y-3">
              <input
                type="text"
                name="wasm_base64"
                placeholder="Base64-encoded WASM binary"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              />
              <.button type="submit" variant="secondary">
                Validate
              </.button>
            </form>
          </div>
        </.card>

        <!-- Build output -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Output</h3>
          <div :if={!@build_output} class="py-8">
            <.empty_state message="No build output yet" />
          </div>
          <pre
            :if={@build_output}
            class="text-xs text-gray-300 bg-gray-950 rounded p-3 max-h-96 overflow-y-auto"
          ><code>{inspect(@build_output, pretty: true, width: 80)}</code></pre>
        </.card>
      </div>

      <!-- Toolchains list -->
      <.card :if={!@loading}>
        <h3 class="text-sm font-medium text-gray-400 mb-4">Available Toolchains</h3>
        <div :if={@toolchains == []} class="py-4">
          <.empty_state message="No toolchains available" />
        </div>
        <div :if={@toolchains != []} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          <div
            :for={tc <- @toolchains}
            class="rounded-lg bg-gray-800 border border-gray-700 p-3"
          >
            <p class="text-sm font-medium text-white">{tc[:name] || tc["name"] || tc}</p>
            <p :if={tc[:description] || tc["description"]} class="text-xs text-gray-400 mt-1">
              {tc[:description] || tc["description"]}
            </p>
          </div>
        </div>
      </.card>
    </div>
    """
  end
end
