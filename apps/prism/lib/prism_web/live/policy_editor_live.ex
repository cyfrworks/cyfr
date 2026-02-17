defmodule PrismWeb.PolicyEditorLive do
  use PrismWeb, :live_view

  @impl true
  def mount(%{"ref" => ref}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Policy: #{ref}")
     |> assign(:ref, ref)
     |> assign(:policy, nil)
     |> assign(:policy_json, "")
     |> assign(:validation_result, nil)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(%{"ref" => ref}, _uri, socket) do
    policy =
      case call_tool(socket, "policy/get", %{"component_ref" => ref}) do
        {:ok, policy} -> policy
        _ -> nil
      end

    policy_json =
      if policy do
        Jason.encode!(policy, pretty: true)
      else
        "{}"
      end

    {:noreply,
     socket
     |> assign(:policy, policy)
     |> assign(:policy_json, policy_json)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("save", %{"policy_json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, policy_data} ->
        args = %{"component_ref" => socket.assigns.ref, "policy" => policy_data}

        case call_tool(socket, "policy/set", args) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:policy_json, json)
             |> put_flash(:info, "Policy saved.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid JSON")}
    end
  end

  def handle_event("validate_json", %{"policy_json" => json}, socket) do
    result =
      case Jason.decode(json) do
        {:ok, _} -> %{valid: true, message: "Valid JSON"}
        {:error, err} -> %{valid: false, message: "Invalid JSON: #{inspect(err)}"}
      end

    {:noreply, assign(socket, :validation_result, result)}
  end

  def handle_event("update_field", %{"field" => field, "value" => value}, socket) do
    case call_tool(socket, "policy/update_field", %{
      "component_ref" => socket.assigns.ref,
      "field" => field,
      "value" => value
    }) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:policy, updated)
         |> assign(:policy_json, Jason.encode!(updated, pretty: true))
         |> put_flash(:info, "Field updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <a href={~p"/policies"} class="text-sm text-gray-500 hover:text-gray-300">
          &larr; Back to Policies
        </a>
        <h2 class="text-lg font-semibold text-white mt-1">Policy: {@ref}</h2>
      </div>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-6">
        <!-- JSON editor -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-3">Policy JSON</h3>
          <form phx-submit="save" class="space-y-3">
            <textarea
              name="policy_json"
              phx-change="validate_json"
              phx-debounce="500"
              rows="16"
              class="w-full rounded-lg bg-gray-950 border border-gray-700 px-4 py-3 text-sm text-gray-300 font-mono focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            >{@policy_json}</textarea>

            <div :if={@validation_result} class={[
              "text-xs px-3 py-1 rounded",
              @validation_result.valid && "text-green-400",
              !@validation_result.valid && "text-red-400"
            ]}>
              {@validation_result.message}
            </div>

            <div class="flex gap-3">
              <.button type="submit">Save Policy</.button>
            </div>
          </form>
        </.card>

        <!-- Effective policy preview -->
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-3">Effective Policy</h3>
          <pre class="text-xs text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto"><code>{if @policy, do: Jason.encode!(@policy, pretty: true), else: "No policy loaded"}</code></pre>
        </.card>
      </div>
    </div>
    """
  end
end
