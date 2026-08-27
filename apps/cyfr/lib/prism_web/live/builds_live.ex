# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.BuildsLive do
  use PrismWeb, :live_view
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Builds")
      |> assign(:active_nav, "builds")
      |> assign(:toolchains, [])
      |> assign(:reference, "")
      |> assign(:components, [])
      |> assign(:build_output, nil)
      |> assign(:build_log, [])
      |> assign(:build_id, nil)
      |> assign(:building, false)
      |> assign(:loading, true)

    {:ok, socket}
  end

  @impl true
  def handle_event("compile", %{"reference" => ""}, socket) do
    {:noreply, put_flash(socket, :error, "Please select a component first.")}
  end

  def handle_event("compile", %{"reference" => reference}, socket) do
    build_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Prism.Topics.build(build_id, socket.assigns[:context])
    )

    socket =
      socket
      |> assign(:building, true)
      |> assign(:build_id, build_id)
      |> assign(:build_log, [])
      |> assign(:build_output, nil)

    # Run compile async so progress messages can be received
    lv = self()

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           args = %{"reference" => reference, "build_id" => build_id}
           result = call_tool(socket, "build/compile", args)
           send(lv, {:build_complete, result})
         end) do
      {:ok, _pid} ->
        Process.send_after(self(), {:task_timeout, :build}, 120_000)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to start build task: #{inspect(reason)}")

        {:noreply,
         socket |> assign(:building, false) |> put_flash(:error, "Failed to start build")}
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

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      toolchains =
        case call_tool(socket, "build/toolchains", %{}) do
          {:ok, %{toolchains: tc}} when is_map(tc) ->
            normalize_toolchains(tc)

          {:ok, %{toolchains: list}} when is_list(list) ->
            list

          {:ok, list} when is_list(list) ->
            list

          other ->
            Logger.warning("[BuildsLive] build/toolchains failed: #{inspect(other)}")
            []
        end

      component_refs = discover_local_components(socket.assigns.context)

      {:noreply,
       socket
       |> assign(:toolchains, toolchains)
       |> assign(:components, component_refs)
       |> assign(:loading, false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:build_progress, %{phase: phase, message: message}}, socket) do
    entry = %{phase: phase, message: message, at: DateTime.utc_now()}
    {:noreply, assign(socket, :build_log, socket.assigns.build_log ++ [entry])}
  end

  def handle_info({:build_complete, {:ok, result}}, socket) do
    if socket.assigns.build_id do
      Phoenix.PubSub.unsubscribe(
        Emissary.PubSub,
        Prism.Topics.build(socket.assigns.build_id, socket.assigns[:context])
      )
    end

    topic = Prism.Topics.components(socket.assigns[:context])

    case Phoenix.PubSub.broadcast(Emissary.PubSub, topic, :components_changed) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[BuildsLive] PubSub broadcast failed: #{inspect(reason)}")
    end

    {:noreply,
     socket
     |> assign(:build_output, result)
     |> assign(:building, false)
     |> assign(:build_id, nil)
     |> put_flash(:info, "Build completed successfully.")}
  end

  def handle_info({:build_complete, {:error, reason}}, socket) do
    if socket.assigns.build_id do
      Phoenix.PubSub.unsubscribe(
        Emissary.PubSub,
        Prism.Topics.build(socket.assigns.build_id, socket.assigns[:context])
      )
    end

    {:noreply,
     socket
     |> assign(:build_output, %{error: reason})
     |> assign(:building, false)
     |> assign(:build_id, nil)
     |> put_flash(:error, "Build failed: #{inspect(reason)}")}
  end

  def handle_info({:task_timeout, :build}, socket) do
    if socket.assigns.building do
      Logger.warning("[BuildsLive] Build task timed out after 120s")

      {:noreply,
       socket
       |> assign(:building, false)
       |> assign(:build_id, nil)
       |> put_flash(:error, "Build timed out")}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[BuildsLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp discover_local_components(ctx) do
    # The build plane's one walk (`Compendium.AutoIndexer.discover/1`) —
    # the same manifest-bearing roster registration sees, so the picker
    # can never diverge from the scanner. Manifest-less version dirs
    # rightly vanish: a scaffold always writes the manifest, so a dir
    # without one was never buildable.
    ctx
    |> Compendium.AutoIndexer.discover()
    |> Enum.flat_map(fn segments ->
      case Compendium.ComponentPath.parse(segments) do
        {:ok, %{type: type, publisher: publisher, name: name, version: version}} ->
          [
            Sanctum.ComponentRef.to_string(%Sanctum.ComponentRef{
              type: type,
              namespace: publisher,
              name: name,
              version: version
            })
          ]

        :error ->
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
      <.page_header title="Builds" />

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
              <.input name="wasm_base64" placeholder="Base64-encoded WASM binary" />
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
              <span class="inline-block w-2 h-2 rounded-full bg-blue-400 animate-pulse" /> Building...
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
