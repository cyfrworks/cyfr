# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DeviceAddLive do
  @moduledoc """
  `/devices/add`: where a person adds a new device to the ones they hold.

  A new device, a command line's `cyfr login` or a browser at this home's
  `/pair` page, makes its key first and shows a QR code of this page's
  address with the key's digest in the fragment's `key`
  (`tests/fixtures/device_unlock.json`, `exchange.pairing.approve_url`),
  which a browser never sends. A phone's camera opens it here; the page's
  script (`hooks/device_add.js`) reads the digest, clears it from the
  address at once, and hands it to the page, which opens the person's
  Devices prompt (`PrismWeb.SystemLayer.Pairing`) with the key's code
  filled in. Nothing begins until the person checks the code against the
  one the new device shows and asks: the prompt's `pairing.begin` shows
  the addition and asks for its fresh confirmation, on this device or
  another of theirs, before an invitation for that key alone exists.

  Opened with no key, on a device without a camera, the prompt opens empty
  and the person types or pastes the code. A fragment that names no key
  opens it empty too.

  It is session-only: a person not signed in here is sent through
  `/login`, which clears the fragment the redirect carried there, and the
  person scans the code again once signed in.
  """

  use PrismWeb, :live_view

  @behaviour PrismWeb.SystemLayer.Hook
  on_mount PrismWeb.SystemLayer.Hook

  alias PrismWeb.SystemLayer

  @prompt_id "pairing-add"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Add a device")
     |> assign(:active_nav, nil)
     |> assign(:key_code, nil)}
  end

  # The fragment's key digest, or nil when the address carried none.
  @impl true
  def handle_event("device_key", params, socket) do
    key_code =
      case params do
        %{"key_digest" => digest} when is_binary(digest) ->
          if Prima.Device.key_digest?(digest), do: Prima.Device.key_code(digest)

        _none ->
          nil
      end

    subject = if key_code, do: %{key_code: key_code}, else: %{}

    SystemLayer.show(SystemLayer.layer_id(), %{
      id: @prompt_id,
      kind: :pairing,
      action: :device_pairing,
      subject: subject
    })

    {:noreply, assign(socket, :key_code, key_code)}
  end

  @impl true
  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="device-add" phx-hook="DeviceAdd" class="max-w-2xl space-y-6">
      <.page_header title="Add a device" />
      <p :if={@key_code} class="text-sm text-gray-200" data-test="device-add-code">
        The new device shows <span class="font-mono text-white">{@key_code}</span>. Check it matches before you pair it.
      </p>
      <p :if={is_nil(@key_code)} class="text-sm text-gray-300" data-test="device-add-none">
        Type or paste the code the new device shows, or scan its QR code with this device's camera.
      </p>
    </div>

    <.live_component module={SystemLayer} id={SystemLayer.layer_id()} context={@context} />
    """
  end
end
