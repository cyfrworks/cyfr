# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Pairing do
  @moduledoc """
  The pairing prompt's body, which only the system layer draws: the
  person's Devices, one list, in the athanor in focus (listed by
  `Sanctum.Pairing.list/1`): a protected device with what holds its key
  and what it last reported of its disks, a report a person reads and
  never a decision, and each passkey of their account that signed in here
  as **Passkey**. Each that stands has its control that removes it from
  this CYFR (`pairing.remove`): **Remove from this CYFR** for a device,
  which then stays out until **Allow again** (`pairing.allow_again`)
  beside it, and **Sign out this passkey** for a passkey. This CYFR owns
  only its own bindings, so the list names the two removals apart:
  removing from this CYFR leaves the key on the account, and removing the
  key from the account, at the account's own page that **Keys on your
  account** in Settings links to, ends it everywhere.

  A device comes here by its first connection (`Sanctum.DeviceUnlock`),
  once it is a key of the person's account; nothing is paired from this
  list.

  Above the list, each passkey a browser offered for the person's account
  (`pairing.waiting`, `Sanctum.SignIn.waiting/2`) asks to be added, with
  its short code. On a box's own screen, unlocked by its shell, Approve
  opens the shell's own page with the request's public ref alone: the
  shell reads the passkey from this CYFR itself, draws its code, asks for
  the PIN again and adds it with the box's key. Anywhere else the person
  is told to approve it on the box. Times show in the browser's own time
  zone (`time[data-local]`, which the layer's script rewrites).
  """

  use Phoenix.Component

  attr :prompt_id, :string, required: true
  attr :pairing, :map, default: nil
  attr :myself, :any, required: true
  attr :button_class, :any, required: true
  attr :shell, :boolean, default: false

  @doc """
  The passkeys waiting to be added, and the paired clients, each with its
  control that removes it from this CYFR, or allows a removed device
  again.
  """
  def devices(assigns) do
    assigns =
      assign(assigns, clients: clients(assigns.pairing), waiting: waiting(assigns.pairing))

    ~H"""
    <section class="space-y-3" aria-label="Paired devices" data-test="pairing">
      <%= case @waiting do %>
        <% {:ok, waiting} -> %>
          <div
            :for={passkey <- waiting}
            class="space-y-1 rounded-md border border-gray-700 p-3 text-sm"
            data-test="pairing-waiting"
            data-ref={passkey.ref}
          >
            <p class="font-medium">A browser asks to add a passkey</p>
            <p>
              Its code is <span class="font-mono" data-test="pairing-waiting-code">{passkey.code}</span>.
              Approve it only if a browser in front of you shows this same code. If you did
              not ask for it, leave it: it is forgotten five minutes after it was asked,
              and nothing is added.
            </p>
            <p class="text-xs text-gray-400">
              Asked <.local_time at={passkey.asked_at} />
            </p>
            <a
              :if={@shell}
              href={PrismWeb.DeviceUnlockController.passkey_url(passkey.ref)}
              target="_blank"
              rel="noopener noreferrer"
              data-test="pairing-approve"
              class={@button_class}
            >
              Approve
            </a>
            <p :if={!@shell} class="text-xs text-gray-300" data-test="pairing-approve-on-box">
              Approve it on your CYFR box's own screen, in Your devices there.
            </p>
          </div>
        <% {:error, sentence} -> %>
          <p class="text-sm" role="alert" data-test="pairing-waiting-unread">{sentence}</p>
        <% :unread -> %>
      <% end %>
      <%= case @clients do %>
        <% {:ok, []} -> %>
          <p class="text-sm text-gray-300" data-test="pairing-none">No device is paired yet.</p>
        <% {:ok, clients} -> %>
          <p class="text-xs text-gray-300" data-test="pairing-account">
            Removing a device from this CYFR keeps that device's key out of this CYFR alone,
            until you allow it again. It signs no one out of your account: the key stays on
            it, and on that device your passkey still signs you in here. A device that was
            offline is first told this CYFR no longer takes it, and at its next unlock that
            it was removed here. Removing its key from your account ends it everywhere: Keys
            on your account, in Settings, links to your account page, where you do that.
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
                  {added(client)}
                  <.local_time at={client.paired_at} /><span :if={
                    is_binary(client[:certificate_expires_at])
                  }>; its certificate renews before <.local_time at={client.certificate_expires_at} /></span>
                </p>
              </div>
              <button
                :if={client.standing == "removed"}
                type="button"
                phx-click="pairing_allow_again"
                phx-target={@myself}
                phx-value-id={@prompt_id}
                phx-value-client={client.client_id}
                data-test="pairing-allow-again"
                class={@button_class}
              >
                Allow again
              </button>
              <button
                :if={client.standing != "removed"}
                type="button"
                phx-click="pairing_remove"
                phx-target={@myself}
                phx-value-id={@prompt_id}
                phx-value-client={client.client_id}
                data-test="pairing-remove"
                class={@button_class}
              >
                {remove(client)}
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

  attr :at, :string, required: true

  # An ISO 8601 instant, as the server answers it until the layer's script
  # shows it in the browser's own time zone.
  defp local_time(assigns) do
    ~H"""
    <time datetime={@at} data-local>{@at}</time>
    """
  end

  defp clients(%{clients: clients}), do: clients
  defp clients(_pairing), do: {:ok, []}

  defp waiting(%{waiting: waiting}), do: waiting
  defp waiting(_pairing), do: {:ok, []}

  defp name(%{source: "passkey"}), do: "Passkey"
  defp name(client), do: client[:display_name] || "Paired device"

  defp added(%{source: "passkey"}), do: "Signed in"
  defp added(_client), do: "Paired"

  defp remove(%{source: "passkey"}), do: "Sign out this passkey"
  defp remove(_device), do: "Remove from this CYFR"

  # What signing a passkey out ends: its sessions here, never the key; and
  # what keeps a removed device out.
  defp scope(%{source: "passkey"}),
    do:
      "Signing it out ends its sessions at this CYFR. It stays a passkey of your account, " <>
        "and signing in with it again brings it back."

  defp scope(%{standing: "removed"}),
    do:
      "Removed from this CYFR: its key cannot connect here until you allow it again. " <>
        "Your passkey still signs you in here on that device."

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
          "(#{Enum.join(unencrypted, " and ")} disk). Keep the box where only people you " <>
          "trust can reach it, or install Ubuntu again with disk encryption turned on."

      "unknown" in [root, data] ->
        "Whether this box's disks are encrypted could not be determined."

      true ->
        "This box's system and data disks are encrypted."
    end
  end

  defp storage(_client), do: nil

  defp storage_state(%{storage: %{root: root, data: data}}), do: "#{root} #{data}"
end
