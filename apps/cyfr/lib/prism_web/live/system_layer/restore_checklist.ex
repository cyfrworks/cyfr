# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.RestoreChecklist do
  @moduledoc """
  The restore checklist, which only the system layer draws, for a person
  whose home was restored from a backup: what the declared restore
  (`ARCHITECTURE.md` §6.9) suspended or asks for again, as
  `Sanctum.Recovery.checklist/1` lists it.

    * Passkeys and paired devices to re-enable. While the person's
      recovery is open, re-enabling one needs a door's fresh sign-in or an
      emailed code, never a passkey or device of theirs, and re-enabling
      one ends the recovery.
    * API keys and webhooks to re-enable, the same way.
    * Profiles to consent to again, each naming its component and label,
      with a link to the athanor's Components page, which opens the
      default profile's grant.
    * Entries to rotate at their destination and enter again: the vault
      entries of the athanors the person sits in, and the instance
      entries for a platform administrator.

  Each re-enable is the operation `key.reenable`, `webhook.reenable`,
  `pairing.reenable` or `passkey.reenable` (`request/4`). The layer
  dispatches it as its own sensitive change, under the confirmation
  prompt the operation's `confirmation_required` signal opens. A key,
  webhook or device is re-enabled from a page focused on its own
  athanor, since each is scoped to it. Elsewhere the checklist links to
  that athanor. A passkey is the person's own and is re-enabled from any
  page.

  The checklist holds nothing secret: names, labels, a key's display
  prefix and ids.
  """

  use Phoenix.Component

  # Each operation: the tool it is dispatched as, the argument naming
  # the item, the checklist's list of such items, and the page of an
  # athanor the item is re-enabled from when this page is focused
  # elsewhere.
  @operations %{
    "key.reenable" => {"key/reenable", "key_id", :api_keys, "/api-keys"},
    "webhook.reenable" => {"webhook/reenable", "webhook_id", :webhooks, "/webhooks"},
    "pairing.reenable" => {"pairing/reenable", "client_id", :paired_clients, "/settings"},
    "passkey.reenable" => {"passkey/reenable", "passkey_id", :passkeys, nil}
  }

  @lists [:api_keys, :webhooks, :paired_clients, :passkeys, :profiles, :vault_entries]

  @doc "The four re-enable operations the checklist offers."
  @spec operations() :: [String.t()]
  def operations, do: @operations |> Map.keys() |> Enum.sort()

  @doc """
  The call that re-enables the item `id` under `operation`, from a page
  focused on `athanor_id`: `{:ok, tool, args}` when `checklist` lists the
  item and this page reaches it (a passkey from any page, a key, webhook
  or device from its own athanor), else `:error`. A click for an item no
  longer listed, or held in another athanor, dispatches nothing.
  """
  @spec request(map() | nil, String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), map()} | :error
  def request(%{} = checklist, operation, id, athanor_id) when is_binary(id) do
    with {:ok, {tool, arg, list, _page}} <- Map.fetch(@operations, operation),
         %{} = item <- Enum.find(Map.get(checklist, list, []), &(&1.id == id)),
         true <- here?(item, athanor_id) do
      {:ok, tool, %{arg => id}}
    else
      _not_here -> :error
    end
  end

  def request(_checklist, _operation, _id, _athanor_id), do: :error

  @doc "What the layer says once `operation` re-enabled its item."
  @spec reenabled(String.t()) :: String.t()
  def reenabled("passkey.reenable"), do: "The passkey is re-enabled, and confirms as before."
  def reenabled("pairing.reenable"), do: "The device is re-enabled, and confirms as before."
  def reenabled("key.reenable"), do: "The API key is re-enabled."
  def reenabled("webhook.reenable"), do: "The webhook is re-enabled."

  @doc """
  The athanors the checklist's items sit in, each once, which the layer
  reads to link to where an item is re-enabled, consented again or
  rotated.
  """
  @spec athanor_ids(map()) :: [String.t()]
  def athanor_ids(%{} = checklist) do
    @lists
    |> Enum.flat_map(&Map.get(checklist, &1, []))
    |> Enum.map(&Map.get(&1, :athanor_id))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  # A passkey is the person's own; any other item is reached only from
  # its own athanor.
  defp here?(%{athanor_id: athanor_id}, focus), do: is_binary(focus) and athanor_id == focus
  defp here?(_passkey, _focus), do: true

  attr :id, :string, required: true
  attr :checklist, :map, required: true
  attr :places, :map, required: true, doc: "athanor id => %{route, name}"
  attr :athanor_id, :string, default: nil, doc: "the athanor this page is focused on"
  attr :notice, :string, default: nil
  attr :error, :string, default: nil
  attr :myself, :any, required: true
  attr :button_class, :any, required: true

  @doc "The checklist, drawn while it lists anything."
  def checklist(assigns) do
    checklist = assigns.checklist

    assigns =
      assign(assigns,
        recovering: not is_nil(checklist.restore_id),
        methods:
          Enum.map(checklist.passkeys, &{"passkey.reenable", &1}) ++
            Enum.map(checklist.paired_clients, &{"pairing.reenable", &1}),
        credentials:
          Enum.map(checklist.api_keys, &{"key.reenable", &1}) ++
            Enum.map(checklist.webhooks, &{"webhook.reenable", &1}),
        here: Map.get(assigns.places, assigns.athanor_id)
      )

    ~H"""
    <section
      id={@id}
      data-test="restore-checklist"
      data-recovering={to_string(@recovering)}
      aria-labelledby={"#{@id}-title"}
      class="fixed bottom-4 right-4 z-40 max-h-[70vh] w-full max-w-md overflow-y-auto rounded-lg border border-amber-500 bg-gray-900 p-4 text-sm text-gray-100 shadow-xl"
    >
      <details
        id={"#{@id}-details"}
        open
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        class="space-y-3"
      >
        <summary class="cursor-pointer">
          <h2 id={"#{@id}-title"} class="inline text-base font-semibold">
            This home was restored from a backup
          </h2>
        </summary>

        <div class="mt-3 space-y-3">
          <p :if={@recovering} data-test="restore-checklist-recovering">
            Every session ended, and what the backup carried is suspended until you re-enable it. Re-enabling a passkey or a device needs a door's fresh sign-in or an emailed code, never the passkey or device itself; once one is re-enabled, your recovery is over and it confirms as before.
          </p>
          <p :if={not @recovering} data-test="restore-checklist-recovered">
            Your recovery is over. What the restore suspended or asks for again is still listed below.
          </p>
          <p class="text-gray-300">
            A run open at the backup ended uncertain and is never resumed; start it again.
          </p>

          <p :if={@notice} role="status" data-test="restore-checklist-notice">{@notice}</p>
          <p
            :if={@error}
            role="alert"
            data-test="restore-checklist-error"
            class="rounded border border-red-500 p-2"
          >
            <span class="font-semibold">Not done:</span> {@error}
          </p>

          <section :if={@methods != []} aria-labelledby={"#{@id}-methods"} class="space-y-1">
            <h3 id={"#{@id}-methods"} class="font-medium">Passkeys and devices to re-enable</h3>
            <ul class="divide-y divide-gray-800">
              <.reenable
                :for={{operation, item} <- @methods}
                operation={operation}
                item={item}
                athanor_id={@athanor_id}
                places={@places}
                myself={@myself}
                button_class={@button_class}
              />
            </ul>
          </section>

          <section :if={@credentials != []} aria-labelledby={"#{@id}-credentials"} class="space-y-1">
            <h3 id={"#{@id}-credentials"} class="font-medium">API keys and webhooks to re-enable</h3>
            <ul class="divide-y divide-gray-800">
              <.reenable
                :for={{operation, item} <- @credentials}
                operation={operation}
                item={item}
                athanor_id={@athanor_id}
                places={@places}
                myself={@myself}
                button_class={@button_class}
              />
            </ul>
          </section>

          <section
            :if={@checklist.profiles != []}
            aria-labelledby={"#{@id}-profiles"}
            class="space-y-1"
          >
            <h3 id={"#{@id}-profiles"} class="font-medium">Apps to consent to again</h3>
            <p class="text-gray-300">
              Every app's grant asks for your consent again before it runs.
            </p>
            <ul class="divide-y divide-gray-800">
              <li
                :for={profile <- @checklist.profiles}
                class="space-y-1 py-2"
                data-test="restore-checklist-profile"
                data-id={profile.id}
              >
                <p class="font-mono">{profile.source_ref}</p>
                <p class="text-xs text-gray-400">
                  Its {profile.label} profile{in_place(@places, profile.athanor_id)}.
                </p>
                <.link
                  :if={profile.label == "default" and @places[profile.athanor_id]}
                  navigate={consent_path(@places[profile.athanor_id], profile.source_ref)}
                  data-test="restore-checklist-consent"
                  class="text-blue-300 underline"
                >
                  Consent again
                </.link>
                <p :if={profile.label != "default"} class="text-xs text-gray-300">
                  The app asks for consent to this profile again when it next uses it.
                </p>
              </li>
            </ul>
          </section>

          <section
            :if={@checklist.vault_entries != [] or @checklist.instance_entries != []}
            aria-labelledby={"#{@id}-entries"}
            class="space-y-1"
          >
            <h3 id={"#{@id}-entries"} class="font-medium">Credentials to rotate and enter again</h3>
            <p class="text-gray-300">
              The backup's copy of each may be known: rotate it where it came from, then enter the new value. Until then, nothing uses it.
            </p>
            <ul class="divide-y divide-gray-800">
              <li
                :for={entry <- @checklist.vault_entries}
                class="space-y-1 py-2"
                data-test="restore-checklist-entry"
                data-kind="vault"
                data-id={entry.id}
              >
                <p class="font-medium">{entry.name}</p>
                <p class="text-xs text-gray-400">
                  A vault entry{in_place(@places, entry.athanor_id)}.
                </p>
                <.link
                  :if={@places[entry.athanor_id]}
                  navigate={PrismWeb.Focus.path(@places[entry.athanor_id].route, "/vault")}
                  class="text-blue-300 underline"
                >
                  Open the vault
                </.link>
              </li>
              <li
                :for={entry <- @checklist.instance_entries}
                class="space-y-1 py-2"
                data-test="restore-checklist-entry"
                data-kind="instance"
                data-id={entry.id}
              >
                <p class="font-medium">{entry.name}</p>
                <p class="text-xs text-gray-400">An instance entry.</p>
                <.link
                  :if={@here}
                  navigate={PrismWeb.Focus.path(@here.route, "/settings")}
                  class="text-blue-300 underline"
                >
                  Open the instance entries
                </.link>
              </li>
            </ul>
          </section>
        </div>
      </details>
    </section>
    """
  end

  attr :operation, :string, required: true
  attr :item, :map, required: true
  attr :athanor_id, :string, default: nil
  attr :places, :map, required: true
  attr :myself, :any, required: true
  attr :button_class, :any, required: true

  # One suspended item: its control where this page reaches it, else a
  # link to the athanor it is re-enabled from.
  defp reenable(assigns) do
    item = assigns.item
    {_tool, _arg, _list, page} = Map.fetch!(@operations, assigns.operation)

    assigns =
      assign(assigns,
        here: here?(item, assigns.athanor_id),
        place: Map.get(item, :athanor_id) && Map.get(assigns.places, item.athanor_id),
        page: page,
        name: name(assigns.operation, item),
        detail: detail(assigns.operation, item, assigns.places)
      )

    ~H"""
    <li
      class="flex items-center justify-between gap-2 py-2"
      data-test="restore-checklist-item"
      data-operation={@operation}
      data-id={@item.id}
    >
      <div>
        <p class="font-medium">{@name}</p>
        <p :if={@detail} class="text-xs text-gray-400">{@detail}</p>
      </div>
      <button
        :if={@here}
        type="button"
        phx-click="restore_reenable"
        phx-target={@myself}
        phx-value-operation={@operation}
        phx-value-id={@item.id}
        data-test="restore-reenable"
        data-operation={@operation}
        data-id={@item.id}
        class={@button_class}
      >
        Re-enable
      </button>
      <.link
        :if={not @here and @place != nil}
        navigate={PrismWeb.Focus.path(@place.route, @page)}
        data-test="restore-checklist-elsewhere"
        class="shrink-0 text-blue-300 underline"
      >
        Re-enable in {@place.name}
      </.link>
      <span :if={not @here and is_nil(@place)} class="shrink-0 text-xs text-gray-300">
        Re-enable it from its own athanor.
      </span>
    </li>
    """
  end

  defp name("passkey.reenable", _item), do: "A passkey"
  defp name("pairing.reenable", _item), do: "A paired device"
  defp name("key.reenable", item), do: present(item.name) || "An API key"
  defp name("webhook.reenable", item), do: present(item.name) || "A webhook"

  defp detail("passkey.reenable", %{rp_id: rp_id}, _places) when is_binary(rp_id),
    do: "A passkey for #{rp_id}"

  defp detail("passkey.reenable", _item, _places), do: "A passkey"

  defp detail("pairing.reenable", item, places),
    do: "A paired device" <> in_place(places, item.athanor_id)

  defp detail("key.reenable", item, places) do
    prefix = if present(item.prefix), do: ", beginning #{item.prefix}", else: ""
    "An API key#{prefix}" <> in_place(places, item.athanor_id)
  end

  defp detail("webhook.reenable", item, places),
    do: "A webhook" <> in_place(places, item.athanor_id)

  defp in_place(places, athanor_id) do
    case Map.get(places, athanor_id) do
      %{name: name} -> ", in #{name}"
      nil -> ""
    end
  end

  # The components page opens the grant of a component's default profile
  # from this link (`?setup=true`).
  defp consent_path(%{route: route}, source_ref),
    do:
      PrismWeb.Focus.path(
        route,
        "/components?" <> URI.encode_query(%{"ref" => source_ref, "setup" => "true"})
      )

  defp present(text) when is_binary(text) and text != "", do: text
  defp present(_text), do: nil
end
