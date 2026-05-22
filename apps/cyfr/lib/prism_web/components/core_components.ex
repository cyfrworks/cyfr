# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
      id={"flash-#{@kind}"}
      phx-hook="FlashAutoHide"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind})}
      class={[
        "rounded-lg px-4 py-3 text-sm flex items-center justify-between cursor-pointer transition-opacity duration-500 shadow-lg",
        @kind == :info && "bg-blue-900/80 text-blue-300 border border-blue-800",
        @kind == :error && "bg-red-900/80 text-red-300 border border-red-800",
        @kind == :warning && "bg-yellow-900/80 text-yellow-300 border border-yellow-800"
      ]}
      role="alert"
    >
      <span>{msg}</span>
      <span class="text-xs opacity-60 ml-3">&times;</span>
    </div>
    """
  end

  @doc """
  Renders a fixed toast container for flash messages, centered at the top of the viewport.
  Use this in layouts to get consistent toast positioning.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 left-1/2 -translate-x-1/2 z-[99999] w-auto max-w-md space-y-2 pointer-events-auto">
      <.flash :if={Phoenix.Flash.get(@flash, :info)} kind={:info}>
        {Phoenix.Flash.get(@flash, :info)}
      </.flash>
      <.flash :if={Phoenix.Flash.get(@flash, :warning)} kind={:warning}>
        {Phoenix.Flash.get(@flash, :warning)}
      </.flash>
      <.flash :if={Phoenix.Flash.get(@flash, :error)} kind={:error}>
        {Phoenix.Flash.get(@flash, :error)}
      </.flash>
    </div>
    """
  end

  # ============================================================================
  # Navigation
  # ============================================================================

  # Sidebar nav-link styling. Factored into module attributes so the
  # OptimisticNav JS hook can read the exact same class strings via
  # data-active-class / data-inactive-class — when the hook swaps classes
  # on click, LiveView's next render produces an identical attribute and
  # the diff is a no-op.
  @nav_link_base "group flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors"
  @nav_link_active "bg-blue-600/20 text-blue-300"
  @nav_link_inactive "text-gray-300 hover:bg-gray-800 hover:text-white"
  @nav_icon_active "text-blue-400"
  @nav_icon_inactive "text-gray-500 group-hover:text-gray-300"

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  def nav_link(assigns) do
    assigns =
      assigns
      |> assign(:link_class, @nav_link_base <> " " <> if(assigns.active, do: @nav_link_active, else: @nav_link_inactive))
      |> assign(:icon_class, "h-5 w-5 " <> if(assigns.active, do: @nav_icon_active, else: @nav_icon_inactive))
      |> assign(:active_class, @nav_link_active)
      |> assign(:inactive_class, @nav_link_inactive)

    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class={@link_class}
      phx-hook="OptimisticNav"
      data-nav-group="sidebar"
      data-active-class={@active_class}
      data-inactive-class={@inactive_class}
    >
      <.icon name={@icon} class={@icon_class} />
      {@label}
    </.link>
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

  def icon(%{name: "clipboard"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M8.25 7.5V6.108c0-1.135.845-2.098 1.976-2.192.373-.03.748-.057 1.123-.08M15.75 18H18a2.25 2.25 0 0 0 2.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 0 0-1.123-.08M15.75 18.75v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5A3.375 3.375 0 0 0 6.375 7.5H5.25m11.9-3.664A2.251 2.251 0 0 0 15 2.25h-1.5a2.251 2.251 0 0 0-2.15 1.586m5.8 0c.065.21.1.433.1.664v.75h-6V4.5c0-.231.035-.454.1-.664M6.75 7.5H4.875c-.621 0-1.125.504-1.125 1.125v12c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V16.5a9 9 0 0 0-9-9Z"
      />
    </svg>
    """
  end

  def icon(%{name: "globe"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 21a9.004 9.004 0 0 0 8.716-6.747M12 21a9.004 9.004 0 0 1-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3m0 0a8.997 8.997 0 0 1 7.843 4.582M12 3a8.997 8.997 0 0 0-7.843 4.582m15.686 0A11.953 11.953 0 0 1 12 10.5c-2.998 0-5.74-1.1-7.843-2.918m15.686 0A8.959 8.959 0 0 1 21 12c0 .778-.099 1.533-.284 2.253m0 0A17.919 17.919 0 0 1 12 16.5c-3.162 0-6.133-.815-8.716-2.247m0 0A9.015 9.015 0 0 1 3 12c0-1.605.42-3.113 1.157-4.418"
      />
    </svg>
    """
  end

  def icon(%{name: "grid"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M3.75 6A2.25 2.25 0 0 1 6 3.75h2.25A2.25 2.25 0 0 1 10.5 6v2.25a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25V6ZM3.75 15.75A2.25 2.25 0 0 1 6 13.5h2.25a2.25 2.25 0 0 1 2.25 2.25V18a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18v-2.25ZM13.5 6a2.25 2.25 0 0 1 2.25-2.25H18A2.25 2.25 0 0 1 20.25 6v2.25A2.25 2.25 0 0 1 18 10.5h-2.25a2.25 2.25 0 0 1-2.25-2.25V6ZM13.5 15.75a2.25 2.25 0 0 1 2.25-2.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-2.25a2.25 2.25 0 0 1-2.25-2.25v-2.25Z"
      />
    </svg>
    """
  end

  def icon(%{name: "palette"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M4.098 19.902a3.75 3.75 0 0 0 5.304 0l6.401-6.402M6.75 21A3.75 3.75 0 0 1 3 17.25V4.125C3 3.504 3.504 3 4.125 3h5.25c.621 0 1.125.504 1.125 1.125v4.072M6.75 21a3.75 3.75 0 0 0 3.75-3.75V8.197M6.75 21h13.125c.621 0 1.125-.504 1.125-1.125v-5.25c0-.621-.504-1.125-1.125-1.125h-4.072M10.5 8.197l2.88-2.88c.438-.439 1.15-.439 1.59 0l3.712 3.713c.44.44.44 1.152 0 1.59l-2.879 2.88M6.75 17.25h.008v.008H6.75v-.008Z"
      />
    </svg>
    """
  end

  def icon(%{name: "refresh"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182M21.015 4.356v4.992"
      />
    </svg>
    """
  end

  def icon(%{name: "info"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="m11.25 11.25.041-.02a.75.75 0 0 1 1.063.852l-.708 2.836a.75.75 0 0 0 1.063.853l.041-.021M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9-3.75h.008v.008H12V8.25Z"
      />
    </svg>
    """
  end

  def icon(%{name: "dots-vertical"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 6.75a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5ZM12 12.75a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5ZM12 18.75a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5Z"
      />
    </svg>
    """
  end

  def icon(%{name: "link"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244"
      />
    </svg>
    """
  end

  def icon(%{name: "flag"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M3 3v1.5M3 21v-6m0 0 2.77-.693a9 9 0 0 1 6.208.682l.108.054a9 9 0 0 0 6.086.71l3.114-.732a48.524 48.524 0 0 1-.005-10.499l-3.11.732a9 9 0 0 1-6.085-.711l-.108-.054a9 9 0 0 0-6.208-.682L3 4.5M3 15V4.5"
      />
    </svg>
    """
  end

  def icon(%{name: "user"} = assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0zM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632z"
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
  attr :size, :string, default: "md"
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(disabled)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-offset-gray-900",
        button_size_class(@size),
        button_variant_class(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_size_class("sm"), do: "px-3 py-1.5 text-xs"
  defp button_size_class(_), do: "px-4 py-2 text-sm"

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

  defp badge_color_class("yellow"),
    do: "bg-yellow-900/50 text-yellow-300 border border-yellow-800"

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

  # Indicator colors are mapped per semantic state, not per status string,
  # so /activities (McpLog: pending/success/error) and /executions (Execution:
  # running/completed/failed/cancelled) render the same state identically.
  #
  # Green pulse — in flight (running, pending)
  # Green       — terminal success (completed, success, ok, healthy)
  # Red         — terminal failure (failed, error)
  # Amber       — non-error termination or warning (cancelled, degraded)
  # Gray        — unknown
  defp status_dot_class("running"), do: "bg-green-400 animate-pulse"
  defp status_dot_class("pending"), do: "bg-green-400 animate-pulse"
  defp status_dot_class("completed"), do: "bg-green-400"
  defp status_dot_class("success"), do: "bg-green-400"
  defp status_dot_class("ok"), do: "bg-green-400"
  defp status_dot_class("healthy"), do: "bg-green-400"
  defp status_dot_class("failed"), do: "bg-red-400"
  defp status_dot_class("error"), do: "bg-red-400"
  defp status_dot_class("cancelled"), do: "bg-amber-400"
  defp status_dot_class("degraded"), do: "bg-amber-400"
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

  # ============================================================================
  # Loading / Empty / Error State Triplet
  #
  # One canonical look for the three states every async LiveView panel cycles
  # through. Use these instead of inlining custom spinner/empty/error markup.
  # ============================================================================

  attr :message, :string, default: "Loading…"
  attr :class, :string, default: ""

  def live_loading(assigns) do
    ~H"""
    <div class={["flex items-center justify-center gap-2 py-8 text-sm text-gray-500", @class]}>
      <span
        class="inline-block h-3 w-3 animate-spin rounded-full border-2 border-gray-600 border-t-blue-400"
        aria-hidden="true"
      />
      <span>{@message}</span>
    </div>
    """
  end

  attr :message, :string, default: "Nothing here yet."
  attr :class, :string, default: ""
  slot :inner_block

  def live_empty(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center gap-2 py-8 text-sm text-gray-500", @class]}>
      <span>{@message}</span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :message, :string, default: "Something went wrong."
  attr :class, :string, default: ""
  slot :inner_block

  def live_error(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center gap-2 py-8 text-sm text-red-400",
      @class
    ]}>
      <span>{@message}</span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Page Header
  # ============================================================================

  attr :title, :string, required: true
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <h2 class="text-lg font-semibold text-white">{@title}</h2>
      <div :if={@actions != []} class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  # ============================================================================
  # Filter Pill
  # ============================================================================

  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :active_class, :string, default: "bg-gray-700 text-white"
  attr :class, :string, default: ""
  attr :rest, :global

  def filter_pill(assigns) do
    ~H"""
    <button
      class={[
        "px-3 py-1.5 rounded-full text-xs font-medium transition-colors",
        if(@active, do: @active_class, else: "bg-gray-800 text-gray-400 hover:text-gray-300"),
        @class
      ]}
      {@rest}
    >
      {@label}
    </button>
    """
  end

  # ============================================================================
  # Form Inputs
  # ============================================================================

  attr :type, :string, default: "text"
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(name value required placeholder disabled readonly id phx-debounce)

  def input(assigns) do
    ~H"""
    <input
      type={@type}
      class={[
        "w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500",
        @class
      ]}
      {@rest}
    />
    """
  end

  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(name required placeholder disabled readonly rows id phx-debounce)

  def textarea(assigns) do
    ~H"""
    <textarea
      class={[
        "w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:ring-1 focus:ring-blue-500",
        @class
      ]}
      {@rest}
    ></textarea>
    """
  end
end