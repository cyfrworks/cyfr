# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.NotesComponent do
  @moduledoc """
  The page the soul reads first — `about-you` in a person's athanor,
  `about-us` in a group's, pinned through the `notes` tool — and the notes
  kept here out of the threads. Both are written through the tool a
  card in chat goes through, so one gate answers for both; a write here
  changes nothing another section shows, so the section reloads itself.
  """

  use PrismWeb, :live_component

  import PrismWeb.AquaLive.Section

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded, false)
     |> assign(:pinned_name, nil)
     |> assign(:pin_max_bytes, Aqua.Notes.pin_max_bytes())
     |> assign(:about, "")
     |> assign(:about_draft, "")
     |> assign(:about_editing?, false)
     |> assign(:notes, [])
     |> assign(:note_open, nil)}
  end

  @impl true
  def update(%{load: true} = assigns, socket) do
    {:ok, socket |> assign(Map.delete(assigns, :load)) |> load()}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("dismiss_flash", _params, socket), do: {:noreply, clear_flash(socket)}

  # The pinned page, written through the `notes` tool: the person at the
  # keyboard and a card in chat go through one gate. The cap is bytes,
  # since the page is read into every turn; the counter here reads the
  # same number the tool refuses over.
  def handle_event("about_edit", _params, socket) do
    {:noreply,
     socket |> assign(:about_editing?, true) |> assign(:about_draft, socket.assigns.about)}
  end

  def handle_event("about_cancel", _params, socket),
    do: {:noreply, assign(socket, :about_editing?, false)}

  def handle_event("about_change", %{"content" => content}, socket),
    do: {:noreply, assign(socket, :about_draft, content)}

  def handle_event("about_save", %{"content" => content}, socket) do
    args = %{"name" => socket.assigns.pinned_name, "content" => content}

    case call_tool(socket.assigns.context, "notes/pin", args) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:about_editing?, false)
         |> load()
         |> put_flash(:info, Aqua.Notes.describe(result) || "Pinned.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not pin that: #{error_message(reason)}")}
    end
  end

  def handle_event("note_open", %{"name" => name}, socket) do
    case call_tool(socket.assigns.context, "notes/read", %{"name" => name}) do
      {:ok, note} ->
        {:noreply, assign(socket, :note_open, note)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not read that note: #{error_message(reason)}")}
    end
  end

  def handle_event("note_close", _params, socket), do: {:noreply, assign(socket, :note_open, nil)}

  def handle_event("note_forget", %{"name" => name}, socket) do
    case call_tool(socket.assigns.context, "notes/forget", %{"name" => name}) do
      {:ok, result} ->
        open = socket.assigns.note_open
        socket = if open && open.name == name, do: assign(socket, :note_open, nil), else: socket

        {:noreply,
         socket |> load() |> put_flash(:info, Aqua.Notes.describe(result) || "Forgotten.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not forget that note: #{error_message(reason)}")}
    end
  end

  # ============================================================================
  # Reads
  # ============================================================================

  defp load(socket), do: socket |> load_about() |> load_notes() |> assign(:loaded, true)

  # The pinned page: what the soul reads first, every turn here. Which
  # page is the estate's kind (`Aqua.Notes.pinned_page/1`); its body is
  # read the way any note is.
  defp load_about(socket) do
    ctx = socket.assigns.context

    case Aqua.Notes.pinned_page(ctx) do
      {:ok, name} ->
        about =
          case call_tool(ctx, "notes/read", %{"name" => name}) do
            {:ok, %{content: content}} -> content
            _ -> ""
          end

        socket |> assign(:pinned_name, name) |> assign(:about, about)

      {:error, _} ->
        socket
    end
  end

  # The estate's filed notes; a pinned page is a slot, not a note.
  defp load_notes(socket) do
    notes =
      case call_tool(socket.assigns.context, "notes/list", %{}) do
        {:ok, %{notes: notes}} -> Enum.reject(notes, &Aqua.Notes.pinned?(&1.name))
        _ -> []
      end

    assign(socket, :notes, notes)
  end

  defp about_title("about-you"), do: "About you"
  defp about_title(_page), do: "About us"

  defp provenance_line(%{kept_by: by, kept_at: at, thread: thread}) do
    [
      "kept by " <> if(is_binary(by), do: principal_label(by), else: "someone"),
      is_binary(at) && "on " <> at,
      is_binary(thread) && "from a thread"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="aqua-notes-section" phx-target={@myself} class="space-y-6">
      <.section_flash flash={@flash} target={@myself} />

      <%!-- The pinned page: what the soul reads first, every turn here.
            Yours to write; the soul never edits it. This and the notes
            wait for the read: an empty list before it is not "nothing
            here", and must not say so. --%>
      <section
        :if={@loaded}
        id="aqua-about"
        class="rounded-lg border border-gray-800 bg-gray-900/40 p-4 space-y-2"
      >
        <div class="flex items-center justify-between gap-2">
          <div>
            <h4 class="text-sm font-medium text-gray-200">{about_title(@pinned_name)}</h4>
            <p class="text-[11px] text-gray-500">
              Read first on every turn here — up to {@pin_max_bytes} bytes. Written by people, never by AQUA.
            </p>
          </div>
          <button
            :if={not @about_editing? and @pinned_name}
            type="button"
            phx-click="about_edit"
            phx-target={@myself}
            class="rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800"
          >
            Edit
          </button>
        </div>
        <form
          :if={@about_editing?}
          phx-change="about_change"
          phx-target={@myself}
          phx-submit="about_save"
          phx-target={@myself}
          class="space-y-2"
        >
          <textarea
            name="content"
            rows="6"
            phx-debounce="150"
            class="w-full rounded bg-gray-950 border border-gray-700 px-3 py-2 text-sm text-gray-200 focus:border-blue-500 focus:outline-none"
          >{@about_draft}</textarea>
          <div class="flex items-center justify-between gap-2">
            <span
              id="aqua-about-bytes"
              class={[
                "text-[10px]",
                if(byte_size(@about_draft) > @pin_max_bytes,
                  do: "text-red-400",
                  else: "text-gray-500"
                )
              ]}
            >
              {byte_size(@about_draft)} / {@pin_max_bytes} bytes
            </span>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="about_cancel"
                phx-target={@myself}
                class="rounded px-3 py-1 text-xs text-gray-300 hover:bg-gray-800"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
              >
                Pin
              </button>
            </div>
          </div>
        </form>
        <pre
          :if={not @about_editing? and @about != ""}
          class="whitespace-pre-wrap text-xs text-gray-300 font-sans"
        >{@about}</pre>
        <p :if={not @about_editing? and @about == ""} class="text-xs text-gray-600">
          Nothing pinned yet.
        </p>
      </section>

      <%!-- What was kept here, out of the threads. --%>
      <details
        :if={@loaded}
        id="aqua-notes"
        class="rounded-lg border border-gray-800 bg-gray-900/40"
        open={@notes != []}
      >
        <summary class="cursor-pointer px-4 py-2 text-sm font-medium text-gray-200">
          Notes <span class="text-xs text-gray-500">({length(@notes)})</span>
        </summary>
        <div class="border-t border-gray-800 px-4 py-2 space-y-2">
          <p :if={@notes == []} class="text-xs text-gray-600">
            Nothing kept yet. AQUA proposes a note when something is worth keeping; you decide.
          </p>
          <ul :if={@notes != []} class="divide-y divide-gray-800/60">
            <li :for={note <- @notes} class="flex items-center gap-2 py-1">
              <button
                type="button"
                phx-click="note_open"
                phx-target={@myself}
                phx-value-name={note.name}
                class="min-w-0 flex-1 truncate text-left text-xs text-gray-300 hover:text-white font-mono"
              >
                {note.name}
              </button>
              <button
                type="button"
                phx-click="note_forget"
                phx-target={@myself}
                phx-value-name={note.name}
                data-confirm={"Forget #{note.name}? The note is gone for everyone here."}
                class="text-[10px] text-gray-500 hover:text-red-400"
              >
                Forget
              </button>
            </li>
          </ul>
          <div
            :if={@note_open}
            id="aqua-note-open"
            class="rounded border border-gray-800 bg-gray-950 p-3 space-y-1"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs font-mono text-gray-200">{@note_open.name}</span>
              <button
                type="button"
                phx-click="note_close"
                phx-target={@myself}
                class="text-gray-500 hover:text-gray-300"
                aria-label="Close"
              >
                ×
              </button>
            </div>
            <p class="text-[10px] text-gray-500">{provenance_line(@note_open)}</p>
            <pre class="whitespace-pre-wrap text-xs text-gray-300 font-sans">{@note_open.content}</pre>
          </div>
        </div>
      </details>
    </div>
    """
  end
end
