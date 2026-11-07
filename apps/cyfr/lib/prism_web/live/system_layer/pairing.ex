# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Pairing do
  @moduledoc """
  The pairing prompt's body, which only the system layer draws: the
  person's Devices, one list, in the athanor in focus, each with its
  control that signs it out of this CYFR (`pairing.revoke`, listed by
  `Sanctum.Pairing.list/1`): a protected device with what holds its key
  and what it last reported of its disks, a report a person reads and
  never a decision, and each passkey of their account that signed in here
  as **Passkey**. This CYFR owns only its own bindings, so the list says
  that signing one out leaves its key on the account, and that removing
  the key from the account ends it everywhere. A command line is a
  protected device like any other.

  A device comes here by its first connection (`Sanctum.DeviceUnlock`),
  once it is a key of the person's account; nothing is paired from this
  list.
  """

  use Phoenix.Component

  attr :prompt_id, :string, required: true
  attr :pairing, :map, default: nil
  attr :myself, :any, required: true
  attr :button_class, :any, required: true

  @doc "The paired clients, each with its control that signs it out of this CYFR."
  def devices(assigns) do
    assigns = assign(assigns, clients: clients(assigns.pairing))

    ~H"""
    <section class="space-y-3" aria-label="Paired devices" data-test="pairing">
      <%= case @clients do %>
        <% {:ok, []} -> %>
          <p class="text-sm text-gray-300" data-test="pairing-none">No device is paired yet.</p>
        <% {:ok, clients} -> %>
          <p class="text-xs text-gray-300" data-test="pairing-account">
            Signing a device or passkey out ends it at this CYFR alone: it stays on your account.
            Removing its key from your account ends it everywhere.
          </p>
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
                {sign_out(client)}
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

  defp name(%{source: "passkey"}), do: "Passkey"
  defp name(client), do: client[:display_name] || "Paired device"

  defp added(%{source: "passkey"}), do: "Signed in"
  defp added(_client), do: "Paired"

  defp sign_out(%{source: "passkey"}), do: "Sign out this passkey"
  defp sign_out(_device), do: "Sign out this device"

  # What signing a passkey out ends: its sessions here, never the key.
  defp scope(%{source: "passkey"}),
    do:
      "Signing it out ends its sessions at this CYFR. It stays a passkey of your account, " <>
        "and signing in with it again brings it back."

  defp scope(_device), do: nil

  # What holds a key: a passkey's own platform, under the person's screen
  # lock, or what a protected device reports.
  defp holder(%{source: "passkey"}),
    do: "Signs in and confirms with your face, fingerprint or screen lock."

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
