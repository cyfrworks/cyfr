defmodule PrismWeb.CoreComponents do
  @moduledoc """
  Shared UI components for Prism.

  Provides buttons, tables, badges, modals, forms, flash messages,
  icons, and navigation helpers.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ============================================================================
  # Flash Messages
  # ============================================================================

  attr :kind, :atom, required: true
  slot :inner_block, required: true

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block)}
      class={[
        "mt-4 rounded-lg px-4 py-3 text-sm",
        @kind == :info && "bg-blue-900/50 text-blue-300 border border-blue-800",
        @kind == :error && "bg-red-900/50 text-red-300 border border-red-800"
      ]}
      role="alert"
    >
      {msg}
    </div>
    """
  end

  # ============================================================================
  # Navigation
  # ============================================================================

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  def nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class="group flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-gray-300 hover:bg-gray-800 hover:text-white transition-colors"
    >
      <.icon name={@icon} class="h-5 w-5 text-gray-500 group-hover:text-gray-300" />
      {@label}
    </a>
    """
  end

  # ============================================================================
  # Icons (simple SVG-based)
  # ============================================================================

  attr :name, :string, required: true
  attr :class, :string, default: "h-5 w-5"

  def icon(%{name: "home"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25"
      />
    </svg>
    """
  end

  def icon(%{name: "play"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M5.25 5.653c0-.856.917-1.398 1.667-.986l11.54 6.347a1.125 1.125 0 0 1 0 1.972l-11.54 6.347a1.125 1.125 0 0 1-1.667-.986V5.653Z"
      />
    </svg>
    """
  end

  def icon(%{name: "cube"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"
      />
    </svg>
    """
  end

  def icon(%{name: "wrench"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M11.42 15.17 17.25 21A2.652 2.652 0 0 0 21 17.25l-5.877-5.877M11.42 15.17l2.496-3.03c.317-.384.74-.626 1.208-.766M11.42 15.17l-4.655 5.653a2.548 2.548 0 1 1-3.586-3.586l6.837-5.63m5.108-.233c.55-.164 1.163-.188 1.743-.14a4.5 4.5 0 0 0 4.486-6.336l-3.276 3.277a3.004 3.004 0 0 1-2.25-2.25l3.276-3.276a4.5 4.5 0 0 0-6.336 4.486c.091 1.076-.071 2.264-.904 2.95l-.102.085m-1.745 1.437L5.909 7.5H4.5L2.25 3.75l1.5-1.5L7.5 4.5v1.409l4.26 4.26m-1.745 1.437 1.745-1.437m6.615 8.206L15.75 15.75M4.867 19.125h.008v.008h-.008v-.008Z"
      />
    </svg>
    """
  end

  def icon(%{name: "shield"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9 12.75 11.25 15 15 9.75m-3-7.036A11.959 11.959 0 0 1 3.598 6 11.99 11.99 0 0 0 3 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285Z"
      />
    </svg>
    """
  end

  def icon(%{name: "key"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M15.75 5.25a3 3 0 0 1 3 3m3 0a6 6 0 0 1-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1 1 21.75 8.25Z"
      />
    </svg>
    """
  end

  def icon(%{name: "lock"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z"
      />
    </svg>
    """
  end

  def icon(%{name: "document"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"
      />
    </svg>
    """
  end

  def icon(%{name: "cog"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.431.992a7.723 7.723 0 0 1 0 .255c-.007.378.138.75.43.991l1.004.827c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"
      />
      <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
    </svg>
    """
  end

  def icon(%{name: "logout"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M8.25 9V5.25A2.25 2.25 0 0 1 10.5 3h6a2.25 2.25 0 0 1 2.25 2.25v13.5A2.25 2.25 0 0 1 16.5 21h-6a2.25 2.25 0 0 1-2.25-2.25V15m-3 0-3-3m0 0 3-3m-3 3H15"
      />
    </svg>
    """
  end

  def icon(%{name: "check-circle"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      />
    </svg>
    """
  end

  def icon(%{name: "x-circle"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="m9.75 9.75 4.5 4.5m0-4.5-4.5 4.5M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      />
    </svg>
    """
  end

  def icon(%{name: "clock"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      />
    </svg>
    """
  end

  def icon(assigns) do
    ~H"""
    <span class={@class}></span>
    """
  end

  # ============================================================================
  # Buttons
  # ============================================================================

  attr :type, :string, default: "button"
  attr :variant, :string, default: "primary"
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900",
        button_variant_class(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_variant_class("primary"),
    do: "bg-blue-600 text-white hover:bg-blue-500 focus:ring-blue-500"

  defp button_variant_class("secondary"),
    do: "bg-gray-700 text-gray-200 hover:bg-gray-600 focus:ring-gray-500"

  defp button_variant_class("danger"),
    do: "bg-red-600 text-white hover:bg-red-500 focus:ring-red-500"

  defp button_variant_class("ghost"),
    do: "text-gray-400 hover:text-white hover:bg-gray-800 focus:ring-gray-500"

  defp button_variant_class(_), do: button_variant_class("primary")

  # ============================================================================
  # Badges
  # ============================================================================

  attr :color, :string, default: "gray"
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
      badge_color_class(@color)
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_color_class("green"), do: "bg-green-900/50 text-green-300 border border-green-800"
  defp badge_color_class("red"), do: "bg-red-900/50 text-red-300 border border-red-800"
  defp badge_color_class("yellow"), do: "bg-yellow-900/50 text-yellow-300 border border-yellow-800"
  defp badge_color_class("blue"), do: "bg-blue-900/50 text-blue-300 border border-blue-800"
  defp badge_color_class(_), do: "bg-gray-800 text-gray-300 border border-gray-700"

  # ============================================================================
  # Cards
  # ============================================================================

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["rounded-lg border border-gray-800 bg-gray-900 p-6", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Tables
  # ============================================================================

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_click, :any, default: nil
  slot :col, required: true do
    attr :label, :string, required: true
  end

  def table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="min-w-full divide-y divide-gray-800">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-gray-500"
            >
              {col[:label]}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-800">
          <tr
            :for={row <- @rows}
            class={["hover:bg-gray-800/50 transition-colors", @row_click && "cursor-pointer"]}
            phx-click={@row_click && @row_click.(row)}
          >
            <td :for={col <- @col} class="px-4 py-3 text-sm text-gray-300 whitespace-nowrap">
              {render_slot(col, row)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ============================================================================
  # Modal
  # ============================================================================

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-mounted={JS.transition({"ease-out duration-200", "opacity-0", "opacity-100"})}
    >
      <div class="fixed inset-0 bg-black/60" phx-click={@on_cancel} />
      <div class="relative z-10 w-full max-w-lg rounded-lg bg-gray-900 border border-gray-800 shadow-xl p-6">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ============================================================================
  # Status Indicator
  # ============================================================================

  attr :status, :string, required: true

  def status_indicator(assigns) do
    ~H"""
    <span class="flex items-center gap-2">
      <span class={[
        "h-2 w-2 rounded-full",
        status_dot_class(@status)
      ]} />
      <span class="text-sm">{@status}</span>
    </span>
    """
  end

  defp status_dot_class("healthy"), do: "bg-green-400"
  defp status_dot_class("running"), do: "bg-green-400 animate-pulse"
  defp status_dot_class("completed"), do: "bg-green-400"
  defp status_dot_class("failed"), do: "bg-red-400"
  defp status_dot_class("error"), do: "bg-red-400"
  defp status_dot_class("pending"), do: "bg-yellow-400"
  defp status_dot_class("degraded"), do: "bg-yellow-400"
  defp status_dot_class(_), do: "bg-gray-400"

  # ============================================================================
  # Empty State
  # ============================================================================

  attr :message, :string, default: "No data available"
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-gray-500">
      <p class="text-sm">{@message}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
