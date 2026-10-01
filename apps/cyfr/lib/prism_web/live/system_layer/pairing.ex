# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Pairing do
  @moduledoc """
  The pairing prompt's body, which only the system layer draws: the
  person's paired clients in the athanor in focus, each with its revoke
  control, and the pairing code.

  Pairing a device begins with `pairing.begin`, a sensitive change the
  layer confirms like any other. Its answer's `invitation_url` (this
  home's `/pair` page, the secret in the fragment) is drawn here as a QR
  code (`PrismWeb.QR`), when the address is short enough for one, and as
  the link itself, with when it expires: the
  code is a bearer invitation, so whoever opens it before then pairs a
  device as this person. The layer holds the drawn code only while the
  prompt is open.

  Where the person cannot confirm from this client, the begin control
  reads "Request confirmation": the request is made, and waits for a
  proof given on another client of theirs.
  """

  use Phoenix.Component

  attr :prompt_id, :string, required: true
  attr :pairing, :map, default: nil
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :button_class, :any, required: true
  attr :primary_class, :any, required: true

  @doc "The paired clients, the begin control and, once begun, the pairing code."
  def devices(assigns) do
    assigns =
      assign(assigns,
        clients: clients(assigns.pairing),
        invitation: assigns.pairing && assigns.pairing.invitation
      )

    ~H"""
    <section class="space-y-3" aria-label="Paired devices" data-test="pairing">
      <%= case @clients do %>
        <% {:ok, []} -> %>
          <p class="text-sm text-gray-300" data-test="pairing-none">No device is paired yet.</p>
        <% {:ok, clients} -> %>
          <ul class="divide-y divide-gray-800 text-sm" data-test="pairing-clients">
            <li
              :for={client <- clients}
              class="flex items-center justify-between gap-2 py-2"
              data-test="pairing-client"
              data-client={client.client_id}
            >
              <div>
                <p class="font-medium">{client.label || "Paired device"}</p>
                <p class="text-xs text-gray-400">
                  Paired {client.paired_at}{expiry(client)}
                </p>
              </div>
              <button
                type="button"
                phx-click="pairing_revoke"
                phx-target={@myself}
                phx-value-id={@prompt_id}
                phx-value-client={client.client_id}
                data-test="pairing-revoke"
                class={@button_class}
              >
                Revoke
              </button>
            </li>
          </ul>
        <% {:error, sentence} -> %>
          <p class="text-sm" role="alert" data-test="pairing-unread">{sentence}</p>
        <% :unread -> %>
          <p class="text-sm text-gray-300" data-test="pairing-reading">Reading your devices.</p>
      <% end %>

      <div :if={@invitation} class="space-y-2" data-test="pairing-code">
        <p :if={@invitation.svg} class="text-sm">
          Scan this with the device to pair, or open the link on it. Whoever opens it before {@invitation.expires_at} pairs a device as you; show it to no one else.
        </p>
        <p :if={is_nil(@invitation.svg)} class="text-sm" data-test="pairing-link-only">
          This home's address is too long for a QR code: open the link on the device to pair. Whoever opens it before {@invitation.expires_at} pairs a device as you; show it to no one else.
        </p>
        <div :if={@invitation.svg} class="w-fit rounded bg-white p-2" data-test="pairing-qr">
          {Phoenix.HTML.raw(@invitation.svg)}
        </div>
        <label class="block text-xs text-gray-400" for={"#{@prompt_id}-pairing-link"}>
          Pairing link
        </label>
        <input
          id={"#{@prompt_id}-pairing-link"}
          type="text"
          readonly
          value={@invitation.url}
          data-test="pairing-link"
          class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-xs"
        />
      </div>

      <button
        :if={is_nil(@invitation)}
        type="button"
        phx-click="pairing_begin"
        phx-target={@myself}
        phx-value-id={@prompt_id}
        data-test="pairing-begin"
        class={@primary_class}
      >
        {if @may, do: "Pair a device", else: "Request confirmation"}
      </button>
    </section>
    """
  end

  defp clients(%{clients: clients}), do: clients
  defp clients(_pairing), do: {:ok, []}

  defp expiry(%{certificate_expires_at: at}) when is_binary(at),
    do: "; its certificate renews before #{at}"

  defp expiry(_client), do: ""
end
