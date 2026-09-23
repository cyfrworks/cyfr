# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.RestoreComponent do
  @moduledoc """
  The shipped files: what the server brought, and the way back to it. Two
  restores, two confirms — the first reverts edited copies of what ships
  and keeps what the estate made; the second also deletes every role and
  scroll the estate made. Either changes what the roster and the scrolls
  show, so both are asked of the page (`{:refresh, :agents}`,
  `{:refresh, :skills}`).
  """

  use PrismWeb, :live_component

  import PrismWeb.AquaLive.Section

  @impl true
  def mount(socket), do: {:ok, socket |> assign(:reset_result, nil) |> assign(:loaded, false)}

  @impl true
  def handle_event("dismiss_flash", _params, socket), do: {:noreply, clear_flash(socket)}

  # Two restores, two confirms: the first reverts edited copies of what
  # ships and keeps what the estate made; the second also deletes every
  # role and scroll the estate made, so the tree is exactly the shipped
  # set again. The tool answers what it reverted and what it kept, and
  # the page shows both lists rather than a bare "done".
  def handle_event("restore_shipped", _params, socket),
    do: CyfrWeb.ContextGuard.guard(socket, fn socket -> restore(socket, false) end)

  def handle_event("restore_all", _params, socket),
    do: CyfrWeb.ContextGuard.guard(socket, fn socket -> restore(socket, true) end)

  def handle_event("restore_dismiss", _params, socket),
    do: {:noreply, assign(socket, :reset_result, nil)}

  defp restore(socket, all?) do
    case call_aqua(socket.assigns.context, %{"action" => "reset", "all" => all?}) do
      {:ok, %{"reverted" => reverted, "kept" => kept}} ->
        send(self(), {:refresh, :agents})
        send(self(), {:refresh, :skills})

        {:noreply, assign(socket, :reset_result, %{reverted: reverted, kept: kept, all?: all?})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restore failed: #{error_message(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="aqua-restore-section" phx-target={@myself} class="space-y-3">
      <.section_flash flash={@flash} target={@myself} />
      <section
        :if={@loaded}
        id="aqua-restore"
        class="rounded-lg border border-gray-800 bg-gray-900/40 p-4 space-y-3"
      >
        <div class="flex items-center justify-between gap-3">
          <div>
            <h4 class="text-sm font-medium text-gray-200">Shipped files</h4>
            <p class="text-[11px] text-gray-500">
              The soul, some roles and some scrolls ship with the server. Restoring puts an edited copy back to what shipped; roles and scrolls this estate made are kept.
            </p>
          </div>
          <button
            type="button"
            phx-click="restore_shipped"
            phx-target={@myself}
            data-confirm="Restore the shipped files? Edited copies of the soul, the shipped roles and the shipped scrolls go back to what ships with the server. Roles and scrolls this estate made are kept."
            class="shrink-0 rounded border border-gray-700 px-3 py-1 text-xs text-gray-200 hover:bg-gray-800"
          >
            Restore shipped files
          </button>
        </div>
        <div
          :if={@reset_result}
          id="aqua-restore-result"
          class="rounded border border-gray-800 bg-gray-950 p-3 space-y-1 text-xs"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="text-gray-300">
              {if @reset_result.all?,
                do: "Restored to the shipped set.",
                else: "Restored the shipped files."}
            </span>
            <button
              type="button"
              phx-click="restore_dismiss"
              phx-target={@myself}
              class="text-gray-500 hover:text-gray-300"
              aria-label="Close"
            >
              ×
            </button>
          </div>
          <p class="text-gray-500">
            {if @reset_result.all?, do: "Reverted or removed", else: "Reverted"} ({length(
              @reset_result.reverted
            )}):
            <span :if={@reset_result.reverted == []} class="text-gray-600">nothing was edited</span>
            <code :for={path <- @reset_result.reverted} class="font-mono text-gray-300 mr-2">
              {path}
            </code>
          </p>
          <p :if={not @reset_result.all?} class="text-gray-500">
            Kept ({length(@reset_result.kept)}):
            <span :if={@reset_result.kept == []} class="text-gray-600">
              nothing this estate made
            </span>
            <code :for={path <- @reset_result.kept} class="font-mono text-gray-300 mr-2">{path}</code>
          </p>
        </div>
        <div class="border-t border-gray-800 pt-3 flex items-center justify-between gap-3">
          <p class="text-[11px] text-gray-500">
            Or start over: revert every edited copy <em>and</em>
            delete every role and scroll this estate made, so the tree is exactly what ships.
          </p>
          <button
            type="button"
            phx-click="restore_all"
            phx-target={@myself}
            data-confirm="Remove everything this estate made? Every edited copy reverts AND every role and scroll this estate made is deleted — the tree becomes exactly the shipped set. This cannot be undone."
            class="shrink-0 rounded px-3 py-1 text-xs text-red-300 hover:bg-red-900/40"
          >
            Remove everything this estate made too
          </button>
        </div>
      </section>
    </div>
    """
  end
end
