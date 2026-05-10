defmodule PrismWeb.AquaApprovalCard do
  @moduledoc """
  Inline approval card rendered in the AQUA chat thread.

  The agent emits `ui.request_approval` with a `proposal: {tool, action, args}`
  payload. `PrismWeb.AquaLive` queues the intent server-side as a message
  with `role: "approval"` and renders this component for it. On approve/decline
  the parent LiveView dispatches the user's decision.

  All execution and side effects live in the parent LiveView (`AquaLive`);
  this component is purely presentational + dispatch-by-event.
  """

  use PrismWeb, :live_component

  @impl true
  def render(assigns) do
    assigns = Map.put(assigns, :kind, action_kind(assigns.payload))

    ~H"""
    <div class={[
      "rounded-lg border-l-4 bg-gray-900/80 border border-gray-800 p-3 text-sm",
      kind_border(@kind)
    ]}>
      <div class="flex items-center gap-2 mb-1.5">
        <span class={[
          "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium uppercase tracking-wider",
          kind_pill(@kind)
        ]}>
          {kind_label(@kind)}
        </span>
        <span class="text-[11px] text-gray-500">
          {@agent_label || "Aqua"} requested
        </span>
        <%= if status(@status) == :pending do %>
          <span class="text-[10px] text-gray-600 ml-auto">awaiting confirmation</span>
        <% end %>
      </div>

      <div class="font-medium text-gray-100 mb-1">
        {@payload[:title] || @payload["title"]}
      </div>

      <div class="text-gray-300 text-[13px] mb-2 whitespace-pre-wrap">
        {@payload[:summary] || @payload["summary"]}
      </div>

      <%= if proposal = @payload[:proposal] || @payload["proposal"] do %>
        <details class="text-[11px] text-gray-500 mb-2">
          <summary class="cursor-pointer hover:text-gray-300">Show details</summary>
          <div class="mt-1 px-2 py-1.5 bg-gray-950 border border-gray-800 rounded font-mono text-gray-400 break-all">
            {proposal[:tool] || proposal["tool"]}.{proposal[:action] || proposal["action"]}
            <%= for {k, v} <- proposal[:args] || proposal["args"] || %{} do %>
              <div class="ml-4 text-gray-500">
                {k}: <span class="text-gray-400">{inspect(v)}</span>
              </div>
            <% end %>
          </div>
        </details>
      <% end %>

      <%= cond do %>
        <% status(@status) == :pending -> %>
          <%= if @decline_reason_open do %>
            <form phx-submit="approval:decline" phx-target={@myself} class="flex gap-2 items-center mt-2">
              <input
                type="text"
                name="reason"
                placeholder="Reason (optional)"
                maxlength="80"
                class="flex-1 rounded bg-gray-950 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-red-500 focus:outline-none"
              />
              <button
                type="submit"
                class="rounded px-3 py-1 text-xs bg-red-900/60 text-red-200 hover:bg-red-800/80"
              >
                Decline
              </button>
              <button
                type="button"
                phx-click="approval:cancel_decline"
                phx-target={@myself}
                class="rounded px-2 py-1 text-xs text-gray-500 hover:text-gray-300"
              >
                Cancel
              </button>
            </form>
          <% else %>
            <div class="flex gap-2 justify-end mt-2">
              <button
                type="button"
                phx-click="approval:open_decline"
                phx-target={@myself}
                class="rounded px-3 py-1 text-xs text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              >
                Decline
              </button>
              <button
                type="button"
                phx-click="approval:approve"
                phx-target={@myself}
                phx-value-id={@id}
                class={[
                  "rounded px-3 py-1 text-xs font-medium",
                  approve_button_class(@kind)
                ]}
              >
                Approve
              </button>
            </div>
          <% end %>

        <% status(@status) == :approved -> %>
          <div class="mt-2 flex items-center gap-2 text-[11px]">
            <span class="text-green-400">✓ Approved</span>
            <span class="text-gray-500">{format_time(@decided_at)}</span>
            <span :if={@result_summary} class="text-gray-400 ml-2 truncate">— {@result_summary}</span>
          </div>

        <% status(@status) == :declined -> %>
          <div class="mt-2 flex items-center gap-2 text-[11px]">
            <span class="text-gray-400">✕ Declined</span>
            <span class="text-gray-500">{format_time(@decided_at)}</span>
            <span :if={@reason && @reason != ""} class="text-gray-500 ml-2 truncate">— {@reason}</span>
          </div>

        <% status(@status) == :error -> %>
          <div class="mt-2 flex items-center gap-2 text-[11px]">
            <span class="text-red-400">! Failed</span>
            <span class="text-gray-500">{format_time(@decided_at)}</span>
            <span :if={@result_summary} class="text-red-300 ml-2 truncate">— {@result_summary}</span>
          </div>

        <% true -> %>
          <div></div>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:decline_reason_open, fn -> false end)
     |> assign_new(:agent_label, fn -> nil end)
     |> assign_new(:result_summary, fn -> nil end)
     |> assign_new(:reason, fn -> nil end)
     |> assign_new(:decided_at, fn -> nil end)}
  end

  @impl true
  def handle_event("approval:approve", %{"id" => id}, socket) do
    send(self(), {:approval_approve, id})
    {:noreply, socket}
  end

  def handle_event("approval:decline", %{"reason" => reason}, socket) do
    send(self(), {:approval_decline, socket.assigns.id, reason})
    {:noreply, assign(socket, :decline_reason_open, false)}
  end

  def handle_event("approval:open_decline", _params, socket) do
    {:noreply, assign(socket, :decline_reason_open, true)}
  end

  def handle_event("approval:cancel_decline", _params, socket) do
    {:noreply, assign(socket, :decline_reason_open, false)}
  end

  defp status(:pending), do: :pending
  defp status(:approved), do: :approved
  defp status(:declined), do: :declined
  defp status(:error), do: :error
  defp status("pending"), do: :pending
  defp status("approved"), do: :approved
  defp status("declined"), do: :declined
  defp status("error"), do: :error
  defp status(_), do: :pending

  # Extract the action kind from the payload. Risk visualization derives
  # entirely from kind (read = green, write/execute/external = amber,
  # destructive = red); the policy mode is orthogonal.
  defp action_kind(%{action_kind: k}) when is_atom(k), do: k
  defp action_kind(%{"action_kind" => k}) when is_binary(k), do: safe_atom(k)
  defp action_kind(%{action_kind: k}) when is_binary(k), do: safe_atom(k)
  defp action_kind(_), do: nil

  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp kind_border(:read), do: "border-l-emerald-500"
  defp kind_border(:write), do: "border-l-amber-500"
  defp kind_border(:execute), do: "border-l-amber-500"
  defp kind_border(:external), do: "border-l-amber-500"
  defp kind_border(:destructive), do: "border-l-red-500"
  defp kind_border(_), do: "border-l-gray-500"

  defp kind_pill(:read), do: "bg-emerald-900/60 text-emerald-200"
  defp kind_pill(:write), do: "bg-amber-900/60 text-amber-200"
  defp kind_pill(:execute), do: "bg-amber-900/60 text-amber-200"
  defp kind_pill(:external), do: "bg-amber-900/60 text-amber-200 ring-1 ring-amber-500/40"
  defp kind_pill(:destructive), do: "bg-red-900/60 text-red-200"
  defp kind_pill(_), do: "bg-gray-800 text-gray-300"

  defp kind_label(:read), do: "read"
  defp kind_label(:write), do: "write"
  defp kind_label(:execute), do: "execute"
  defp kind_label(:external), do: "external"
  defp kind_label(:destructive), do: "destructive"
  defp kind_label(_), do: "approval"

  defp approve_button_class(:read), do: "bg-emerald-700 text-white hover:bg-emerald-600"
  defp approve_button_class(:write), do: "bg-amber-700 text-white hover:bg-amber-600"
  defp approve_button_class(:execute), do: "bg-amber-700 text-white hover:bg-amber-600"
  defp approve_button_class(:external), do: "bg-amber-700 text-white hover:bg-amber-600"
  defp approve_button_class(:destructive), do: "bg-red-700 text-white hover:bg-red-600"
  defp approve_button_class(_), do: "bg-blue-700 text-white hover:bg-blue-600"

  defp format_time(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M")
  defp format_time(_), do: ""
end
