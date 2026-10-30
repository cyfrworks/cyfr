# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.RestoreLive do
  @moduledoc """
  `/restore`: the page an empty CYFR serves its returning person,
  sessionless.

  Restore is an ingress, not an operation (`Emissary.Web.RestoreController`,
  `Sanctum.Recovery`): no person exists yet to admit one. This view reads
  nothing and decides nothing. Its form is the browser's
  (`phx-update="ignore"`, `data-restore="page"`, driven by
  `assets/js/system_layer/recovery.js`): the person types the
  installation token their operator gave them and their recovery code,
  and the browser posts them straight to `POST /restore` on this origin,
  the token in the `authorization` header and the code in the JSON body
  (`recovery_code`). None of it reaches this view, an address or the
  browser's storage: the inputs carry no `name`, so even a form submitted
  with its script gone sends nothing, and the token is cleared once the
  restore completes or the person clears the form.

  The ingress answers the restore's phase while it is still underway, and
  the browser asks again under the same token until it ends; a restore
  that completed set the restored person's session in the answer's cookie,
  and the page then leads to their own home, where they register their
  first passkey. A restore already completed whose first-method window
  closed with no method installed is proven again from the recovery code
  (`POST /restore/challenge`, then `POST /restore/reproof`).

  Its second section, the recovery after a backup restore
  (`data-restore-kit`, driven by the same script's `KitStep`), serves a
  CYFR restored from a backup, whose restore suspended every method and
  session. The person types their recovery code into an input with no
  `name`; the browser reads from it the identifier and the secret
  (`assets/js/system_layer/recovery_code.js`), asks
  `POST /restore/kit/challenge` for a challenge, signs a proof over it
  with the secret, and trades the proof at `POST /restore/kit` for a
  recovery credential held in the page's memory alone. Under that
  credential, in the `authorization` header, it lists each class's
  suspended items and re-enables the one the person picks
  (`POST /restore/kit/reenable`); re-enabling a passkey or a device ends
  the recovery and the person signs in with it. Neither the code nor its
  secret is sent, and neither they nor the credential reach this view.

  Its controls carry `data-test` names: `restore-form`, `restore-token`,
  `restore-code`, `restore-submit`, `restore-clear`, `restore-status`
  (with `data-state`), `restore-reproof` and `restore-continue`; the
  second section's are `restore-kit-form`, `restore-kit-code`,
  `restore-kit-submit`, `restore-kit-clear`, `restore-kit-items`,
  `restore-kit-reenable` (one per suspended item, drawn by the script)
  and `restore-kit-status` (with `data-state`).
  """

  use PrismWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Restore your identity"), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-md space-y-4 p-6 text-gray-100">
      <h1 class="text-xl font-semibold">Restore your identity</h1>
      <p class="text-sm text-gray-300">
        This CYFR is empty and its operator set it up for one restore. Type the installation token they gave you and your recovery code. They go to this CYFR alone, and nothing is kept in this browser.
      </p>
      <ul class="list-disc space-y-1 pl-5 text-sm text-gray-300">
        <li>
          A restore brings back your identity alone: never your private data, and never the CYFR addresses your devices saved. Add those addresses again from surviving devices or invitations.
        </li>
        <li>
          Every other CYFR you use sees the new keys within its freshness bound, and ends what it bound to the old ones. Pair your devices here again.
        </li>
      </ul>

      <div id="restore" phx-hook="SystemLayer" data-restore="page" phx-update="ignore">
        <form
          id="restore-form"
          data-restore-form
          data-test="restore-form"
          autocomplete="off"
          class="space-y-3"
        >
          <.field id="restore-token" label="Installation token" field="token" test="restore-token" />
          <.field
            id="restore-code"
            label="Your recovery code"
            field="recovery_code"
            test="restore-code"
          />
          <div class="flex flex-wrap gap-2">
            <button
              type="submit"
              data-test="restore-submit"
              class="rounded-md bg-blue-600 px-3 py-2 text-sm font-semibold text-white hover:bg-blue-500"
            >
              Restore
            </button>
            <button
              type="button"
              data-restore-clear
              data-test="restore-clear"
              class="rounded-md border border-gray-600 px-3 py-2 text-sm font-semibold hover:bg-gray-800"
            >
              Clear
            </button>
          </div>
        </form>

        <p class="text-sm" role="status" data-test="restore-status" data-state="idle"></p>

        <button
          type="button"
          hidden
          data-restore-reproof
          data-test="restore-reproof"
          class="rounded-md border border-gray-600 px-3 py-2 text-sm font-semibold hover:bg-gray-800"
        >
          Check your recovery code again
        </button>
        <a
          href="/"
          hidden
          data-restore-continue
          data-test="restore-continue"
          class="inline-block rounded-md bg-blue-600 px-3 py-2 text-sm font-semibold text-white"
        >
          Continue to Aqua
        </a>

        <section
          id="restore-kit"
          data-restore-kit
          aria-labelledby="restore-kit-title"
          class="space-y-3 border-t border-gray-700 pt-4"
        >
          <h2 id="restore-kit-title" class="text-lg font-semibold">Recover after a restore</h2>
          <p class="text-sm text-gray-300">
            When this CYFR was restored from a backup, every passkey, device, API key and webhook it held was suspended and every session ended. Type your recovery code here to turn back on what is yours. It signs in this browser and is never sent.
          </p>
          <form
            id="restore-kit-form"
            data-restore-kit-form
            data-test="restore-kit-form"
            autocomplete="off"
            class="space-y-3"
          >
            <.field
              id="restore-kit-code"
              label="Your recovery code"
              field="recovery_code"
              test="restore-kit-code"
            />
            <div class="flex flex-wrap gap-2">
              <button
                type="submit"
                data-test="restore-kit-submit"
                class="rounded-md bg-blue-600 px-3 py-2 text-sm font-semibold text-white hover:bg-blue-500"
              >
                Recover
              </button>
              <button
                type="button"
                data-restore-kit-clear
                data-test="restore-kit-clear"
                class="rounded-md border border-gray-600 px-3 py-2 text-sm font-semibold hover:bg-gray-800"
              >
                Clear
              </button>
            </div>
          </form>

          <p class="text-sm" role="status" data-test="restore-kit-status" data-state="idle"></p>
          <div data-restore-kit-items data-test="restore-kit-items" hidden class="space-y-3"></div>
        </section>

        <noscript>
          <p class="text-sm">This page needs JavaScript to send your recovery code to this CYFR.</p>
        </noscript>
      </div>
    </main>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :test, :string, required: true

  # An input with no `name`: only the page's script reads it, so no form
  # submission of the browser's own ever carries it anywhere.
  defp field(assigns) do
    ~H"""
    <div class="space-y-1">
      <label for={@id} class="block text-sm font-medium">{@label}</label>
      <input
        id={@id}
        type="text"
        data-field={@field}
        data-test={@test}
        autocomplete="off"
        autocapitalize="off"
        autocorrect="off"
        spellcheck="false"
        required
        class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400"
      />
    </div>
    """
  end
end
