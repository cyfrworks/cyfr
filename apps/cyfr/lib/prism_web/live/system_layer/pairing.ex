# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Pairing do
  @moduledoc """
  The pairing prompt's body, which only the system layer draws: the
  person's Devices, one list, in the athanor in focus, each with its
  revoke control and what holds its key (`Sanctum.Pairing.list/1`): a
  protected device with what it last reported of its disks, a report a
  person reads and never a decision, and each passkey as **Passkey**, one
  entry per credential, saying whether it may sync to their other
  machines and that revoking it ends it on each of them. A command line
  is a protected device like any other.

  A device comes here by its first connection (`Sanctum.DeviceUnlock`),
  once it is a key of the person's account; nothing is paired from this
  list.
  """

  use Phoenix.Component

  attr :prompt_id, :string, required: true
  attr :pairing, :map, default: nil
  attr :myself, :any, required: true
  attr :button_class, :any, required: true

  @doc "The paired clients, each with its revoke control."
  def devices(assigns) do
    assigns = assign(assigns, clients: clients(assigns.pairing))

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
                <p class="font-medium" data-test="pairing-client-name">
                  {name(client)}
                </p>
                <p :if={holder(client)} class="text-xs text-gray-300" data-test="pairing-holder">
                  {holder(client)}
                </p>
                <p
                  :if={storage(client)}
                  class="text-xs text-gray-300"
                  data-test="pairing-storage"
                  data-storage={storage_state(client)}
                >
                  {storage(client)}
                </p>
                <p :if={scope(client)} class="text-xs text-gray-300" data-test="pairing-scope">
                  {scope(client)}
                </p>
                <p class="text-xs text-gray-400">
                  {added(client)} {client.paired_at}{expiry(client)}
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
    </section>
    """
  end

  defp clients(%{clients: clients}), do: clients
  defp clients(_pairing), do: {:ok, []}

  defp expiry(%{certificate_expires_at: at}) when is_binary(at),
    do: "; its certificate renews before #{at}"

  defp expiry(_client), do: ""

  defp name(%{holder_kind: "platform"}), do: "Passkey"
  defp name(client), do: client[:display_name] || "Paired device"

  defp added(%{holder_kind: "platform"}), do: "Registered"
  defp added(_client), do: "Paired"

  # What revoking an entry ends: a passkey wherever it synced, a device on
  # that device alone.
  defp scope(%{holder_kind: "platform", synced: true}),
    do:
      "May sync to your other phones and computers. Revoking it ends it on every one of them, " <>
        "and the sessions it signed in."

  defp scope(%{holder_kind: "platform"}),
    do: "Kept on the one phone, computer or security key that made it. Revoking it ends it there."

  defp scope(_device), do: nil

  # What holds a protected device's key, as the device reports it; a
  # passkey's platform keeps it under the person's own screen lock.
  defp holder(%{holder_kind: "platform"}),
    do: "Signs in and confirms with your face, fingerprint or screen lock, at this CYFR alone."

  defp holder(%{holder_kind: "chip"}),
    do: "Unlocks with a PIN; its key is sealed in this device's security chip."

  defp holder(%{holder_kind: "software"}),
    do: "Unlocks with a passphrase; its key is encrypted on this device's disk."

  defp holder(_client), do: nil

  # What a protected device last reported of its disks: any volume it
  # keeps unencrypted is named, and a volume it could not determine is
  # never called encrypted.
  defp storage(%{storage: %{root: root, data: data}}) do
    unencrypted = for {name, "unencrypted"} <- [{"system", root}, {"data", data}], do: name

    cond do
      unencrypted != [] ->
        "This box keeps its data unencrypted, whoever takes it reads everything " <>
          "(#{Enum.join(unencrypted, " and ")} disk)."

      "unknown" in [root, data] ->
        "Whether this box's disks are encrypted could not be determined."

      true ->
        "This box's system and data disks are encrypted."
    end
  end

  defp storage(_client), do: nil

  defp storage_state(%{storage: %{root: root, data: data}}), do: "#{root} #{data}"
end
