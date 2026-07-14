# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.PoliciesLive do
  use PrismWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ctx = socket.assigns[:context]
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("prism:policies", ctx))
    end

    {:ok,
     socket
     |> assign(:page_title, "Policies")
     |> assign(:policies, [])
     |> assign(:loading, true)
     |> assign(:expanded, MapSet.new())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, fetch_policies(socket) |> assign(:loading, false)}
  end

  @impl true
  def handle_event("toggle_expand", %{"ref" => ref}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, ref),
        do: MapSet.delete(expanded, ref),
        else: MapSet.put(expanded, ref)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("delete", %{"ref" => ref}, socket) do
    case call_tool(socket, "policy/delete", %{"component_ref" => ref}) do
      {:ok, _} ->
        policies =
          Enum.reject(socket.assigns.policies, fn p ->
            policy_ref(p) == ref
          end)

        {:noreply,
         socket
         |> assign(:policies, policies)
         |> put_flash(:info, "Policy deleted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:policies_changed, socket) do
    {:noreply, fetch_policies(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[PoliciesLive] unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp fetch_policies(socket) do
    policies =
      case call_tool(socket, "policy/list", %{}) do
        {:ok, %{policies: list}} -> list
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    socket
    |> assign(:policies, policies)
    |> PrismWeb.ActiveContext.set_snapshot(%{
      type: "policies",
      items:
        Enum.map(policies, fn p ->
          %{
            ref: get_field(p, :component_ref) || get_field(p, :ref),
            type: get_field(p, :component_type) || get_field(p, :type),
            is_public: get_field(p, :is_public)
          }
        end),
      total: length(policies)
    })
  end

  defp policy_ref(policy) do
    get_field(policy, :component_ref) || get_field(policy, :ref)
  end

  defp get_field(map, key) when is_map(map) do
    map[key] || map[to_string(key)]
  end

  defp get_field(_, _), do: nil

  defp policy_summary(nil), do: "-"

  defp policy_summary(policy) when is_map(policy) do
    parts = []

    timeout = get_field(policy, :timeout)
    parts = if timeout, do: ["timeout: #{timeout}" | parts], else: parts

    rate = get_field(policy, :rate_limit)
    parts = if rate, do: ["rate: #{format_rate(rate)}" | parts], else: parts

    domains = get_field(policy, :allowed_domains) || []
    parts = if domains != [], do: ["#{length(domains)} domain(s)" | parts], else: parts

    if parts == [], do: "default policy", else: Enum.join(Enum.reverse(parts), ", ")
  end

  defp policy_summary(_), do: "-"

  defp format_rate(%{} = rate) do
    reqs = get_field(rate, :requests)
    window = get_field(rate, :window)
    if reqs && window, do: "#{reqs}/#{window}", else: inspect(rate)
  end

  defp format_rate(rate), do: to_string(rate)

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail_field(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-gray-500 uppercase">{@label}</dt>
      <dd class="text-sm text-white mt-1">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :policy, :map, default: nil

  defp policy_details(%{policy: nil} = assigns) do
    ~H"""
    <div class="p-4 text-sm text-gray-500">No policy details available.</div>
    """
  end

  defp policy_details(assigns) do
    policy = assigns.policy

    assigns =
      assigns
      |> assign(:timeout, get_field(policy, :timeout))
      |> assign(:rate_limit, get_field(policy, :rate_limit))
      |> assign(:max_memory, get_field(policy, :max_memory_bytes))
      |> assign(:max_request, get_field(policy, :max_request_size))
      |> assign(:max_response, get_field(policy, :max_response_size))
      |> assign(:domains, get_field(policy, :allowed_domains) || [])
      |> assign(:methods, get_field(policy, :allowed_methods) || [])
      |> assign(:tools, get_field(policy, :allowed_tools) || [])
      |> assign(:storage_paths, get_field(policy, :allowed_paths) || [])

    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 p-4">
      <dl class="space-y-4">
        <.detail_field label="Timeout">{@timeout || "-"}</.detail_field>
        <.detail_field label="Rate Limit">{@rate_limit || "-"}</.detail_field>
        <.detail_field label="Max Memory">{format_bytes(@max_memory)}</.detail_field>
        <.detail_field label="Max Request Size">{format_bytes(@max_request)}</.detail_field>
        <.detail_field label="Max Response Size">{format_bytes(@max_response)}</.detail_field>
      </dl>
      <dl class="space-y-4">
        <.detail_field label="Allowed Domains">
          <div :if={@domains == []} class="text-gray-500">None</div>
          <div :if={@domains != []} class="flex flex-wrap gap-1">
            <.badge :for={d <- @domains} color="blue">{d}</.badge>
          </div>
        </.detail_field>
        <.detail_field label="Allowed Methods">
          <div :if={@methods == []} class="text-gray-500">None</div>
          <div :if={@methods != []} class="flex flex-wrap gap-1">
            <.badge :for={m <- @methods} color="green">{m}</.badge>
          </div>
        </.detail_field>
        <.detail_field label="Allowed Tools">
          <div :if={@tools == []} class="text-gray-500">None</div>
          <div :if={@tools != []} class="flex flex-wrap gap-1">
            <.badge :for={t <- @tools} color="yellow">{t}</.badge>
          </div>
        </.detail_field>
        <.detail_field label="Allowed Storage Paths">
          <div :if={@storage_paths == []} class="text-gray-500">None</div>
          <div :if={@storage_paths != []} class="flex flex-wrap gap-1">
            <span :for={p <- @storage_paths} class="text-sm text-white font-mono">{p}</span>
          </div>
        </.detail_field>
      </dl>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold text-white">Policies</h2>
      </div>

      <.card>
        <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>
        <div :if={!@loading && @policies == []} class="py-8">
          <.empty_state message="No policies defined" />
        </div>
        <div :if={!@loading && @policies != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-800">
            <thead>
              <tr>
                <th class="w-8 px-4 py-3"></th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Reference</th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Policy Summary</th>
                <th class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for policy <- @policies do %>
                <% ref = policy_ref(policy) || "unknown" %>
                <% expanded? = MapSet.member?(@expanded, ref) %>
                <% inner_policy = get_field(policy, :policy) %>
                <tr class="hover:bg-gray-800/50 transition-colors">
                  <td
                    class="px-4 py-3 text-gray-400 cursor-pointer"
                    phx-click="toggle_expand"
                    phx-value-ref={ref}
                  >
                    <svg
                      class={[
                        "w-4 h-4 transition-transform duration-200",
                        expanded? && "rotate-90"
                      ]}
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                      stroke-width="2"
                    >
                      <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
                    </svg>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    <span class="text-blue-400">
                      {ref}
                    </span>
                  </td>
                  <td
                    class="px-4 py-3 text-sm text-gray-300 cursor-pointer"
                    phx-click="toggle_expand"
                    phx-value-ref={ref}
                  >
                    {policy_summary(inner_policy)}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    <.button
                      variant="ghost"
                      phx-click="delete"
                      phx-value-ref={ref}
                      data-confirm="Are you sure you want to delete this policy?"
                    >
                      Delete
                    </.button>
                  </td>
                </tr>
                <tr :if={expanded?} class="bg-gray-900/60">
                  <td colspan="4" class="p-0">
                    <.policy_details policy={inner_policy} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </.card>
    </div>
    """
  end
end