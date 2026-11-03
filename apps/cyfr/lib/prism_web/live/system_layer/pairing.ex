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
  machines and that revoking it ends it on each of them. And the pairing
  code. A command line is a protected device like any other, listed with
  its holder.

  Pairing a device begins on the new device: a command line's `cyfr
  login`, or the box's own screen, makes its key and shows
  the key's code (`Prima.Device.key_code/1`) and a QR code of this home's
  `/devices/add` page with the key's digest in the fragment
  (`PrismWeb.DeviceAddLive`), which a phone's camera opens here with the
  code filled in. A device without a camera types the code, or pastes it,
  and `pairing.begin` asks for it, a
  sensitive change the layer confirms like any other, whose preview names
  the same code. Its answer's `invitation_url` (this home's `/pair` page,
  the secret in the fragment) is drawn here as a QR code (`PrismWeb.QR`),
  when the address is short enough for one, and as the link itself, with
  the code it is for and when it expires: only the device that showed
  that code can pair under it, before then. The layer holds the drawn code
  only while the prompt is open.

  Where the person cannot confirm from this client, the begin control
  reads "Request confirmation": the request is made, and waits for a
  proof given on another client of theirs.
  """

  use Phoenix.Component

  attr :prompt_id, :string, required: true
  attr :key_code, :string, default: nil
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

      <div :if={@invitation} class="space-y-2" data-test="pairing-code">
        <p :if={@invitation.svg} class="text-sm">
          Scan this with the device showing the code below, or open the link on it, before {@invitation.expires_at}. Only that device can pair under it.
        </p>
        <p :if={is_nil(@invitation.svg)} class="text-sm" data-test="pairing-link-only">
          This CYFR's address is too long for a QR code: open the link on the device showing the code below, before {@invitation.expires_at}. Only that device can pair under it.
        </p>
        <p class="font-mono text-sm" data-test="pairing-key-code">{@invitation.code}</p>
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

      <form
        :if={is_nil(@invitation)}
        id={"#{@prompt_id}-pairing-begin"}
        phx-submit="pairing_begin"
        phx-target={@myself}
        class="space-y-2"
        data-test="pairing-begin-form"
      >
        <input type="hidden" name="prompt_id" value={@prompt_id} />
        <label class="block text-sm" for={"#{@prompt_id}-pairing-key-code"}>
          Type or paste the code the new device shows: cyfr login on a command line, or a box's own screen. Check it matches before you pair.
        </label>
        <input
          id={"#{@prompt_id}-pairing-key-code"}
          name="key_code"
          value={@key_code}
          type="text"
          autocomplete="off"
          spellcheck="false"
          required
          data-test="pairing-key-input"
          class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm"
        />
        <button type="submit" data-test="pairing-begin" class={@primary_class}>
          {if @may, do: "Pair a device", else: "Request confirmation"}
        </button>
      </form>
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
