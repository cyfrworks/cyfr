defmodule PrismWeb.BuildsLive do
  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Builds")
     |> assign(:toolchains, [])
     |> assign(:reference, "")
     |> assign(:components, [])
     |> assign(:build_output, nil)
     |> assign(:build_log, [])
     |> assign(:build_id, nil)
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

    component_refs = discover_local_components()

    {:noreply,
     socket
     |> assign(:toolchains, toolchains)
     |> assign(:components, component_refs)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("compile", %{"reference" => ""}, socket) do
    {:noreply, put_flash(socket, :error, "Please select a component first.")}
  end

  def handle_event("compile", %{"reference" => reference}, socket) do
    build_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Phoenix.PubSub.subscribe(Emissary.PubSub, "build:#{build_id}")

    socket =
      socket
      |> assign(:building, true)
      |> assign(:build_id, build_id)
      |> assign(:build_log, [])
      |> assign(:build_output, nil)

    # Run compile async so progress messages can be received
    lv = self()

    Task.start(fn ->
      args = %{"reference" => reference, "build_id" => build_id}
      result = call_tool(socket, "build/compile", args)
      send(lv, {:build_complete, result})
    end)

    {:noreply, socket}
  end

  def handle_event("validate", %{"wasm_base64" => wasm_base64}, socket) do
    case call_tool(socket, "build/validate", %{"wasm_base64" => wasm_base64}) do
      {:ok, result} ->
        {:noreply, assign(socket, :build_output, result)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Validation failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:build_progress, %{phase: phase, message: message}}, socket) do
    entry = %{phase: phase, message: message, at: DateTime.utc_now()}
    {:noreply, assign(socket, :build_log, socket.assigns.build_log ++ [entry])}
  end

  def handle_info({:build_complete, {:ok, result}}, socket) do
    if socket.assigns.build_id do
      Phoenix.PubSub.unsubscribe(Emissary.PubSub, "build:#{socket.assigns.build_id}")
    end

    Phoenix.PubSub.broadcast(Emissary.PubSub, "prism:components", :components_changed)

    {:noreply,
     socket
     |> assign(:build_output, result)
     |> assign(:building, false)
     |> assign(:build_id, nil)
     |> put_flash(:info, "Build completed successfully.")}
  end

  def handle_info({:build_complete, {:error, reason}}, socket) do
    if socket.assigns.build_id do
      Phoenix.PubSub.unsubscribe(Emissary.PubSub, "build:#{socket.assigns.build_id}")
    end

    {:noreply,
     socket
     |> assign(:build_output, %{error: reason})
     |> assign(:building, false)
     |> assign(:build_id, nil)
     |> put_flash(:error, "Build failed: #{inspect(reason)}")}
  end

  @component_types ~w(catalyst reagent formula)

  defp discover_local_components do
    ctx = Sanctum.Context.local()

    Enum.flat_map(@component_types, fn type ->
      type_dir = ["components", "#{type}s", "local"]

      case Arca.list(ctx, type_dir) do
        {:ok, names} ->
          Enum.flat_map(names, fn name ->
            case Arca.list(ctx, type_dir ++ [name]) do
              {:ok, versions} ->
                Enum.map(versions, fn version ->
                  "#{type}:local.#{name}:#{version}"
                end)

              _ ->
                []
            end
          end)

        _ ->
          []
      end
    end)
    |> Enum.sort()
  end

  defp build_phase_color(:preparing), do: "bg-yellow-400"
  defp build_phase_color(:compiling), do: "bg-blue-400"
  defp build_phase_color(:validating), do: "bg-purple-400"
  defp build_phase_color(:complete), do: "bg-green-400"
  defp build_phase_color(:error), do: "bg-red-400"
  defp build_phase_color(:output), do: "bg-gray-600"
  defp build_phase_color(_), do: "bg-gray-600"

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
              <select
                name="reference"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              >
                <option value="" disabled selected={@reference == ""}>Select a component...</option>
                <option :for={ref <- @components} value={ref} selected={@reference == ref}>
                  {ref}
                </option>
              </select>
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
          <div :if={@build_log == [] and !@build_output} class="py-8">
            <.empty_state message="No build output yet" />
          </div>
          <div
            :if={@build_log != [] or @build_output}
            id="build-log"
            phx-hook="ScrollBottom"
            class="bg-gray-950 rounded p-3 max-h-96 overflow-y-auto space-y-0.5"
          >
            <div :for={entry <- @build_log} class="flex items-start gap-2 text-xs font-mono">
              <span class={[
                "shrink-0 w-2 h-2 rounded-full mt-1",
                build_phase_color(entry.phase)
              ]} />
              <span class={[
                "break-all",
                if(entry.phase == :output, do: "text-gray-500", else: "text-gray-300")
              ]}>
                {entry.message}
              </span>
            </div>
            <div :if={@building} class="flex items-center gap-2 text-xs text-blue-400 pt-1">
              <span class="inline-block w-2 h-2 rounded-full bg-blue-400 animate-pulse" />
              Building...
            </div>
          </div>
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
