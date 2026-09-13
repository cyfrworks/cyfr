# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.ScrollsComponent do
  @moduledoc """
  The scrolls AQUA can read on demand — Agent Skills under
  `aqua/skills/<name>/SKILL.md` — listed, read, written and removed
  through the `aqua` tool. A write changes a scroll's provenance, which
  the page reads for every section at once, so a write here asks the page
  to re-read it (`{:refresh, :skills}`).
  """

  use PrismWeb, :live_component

  import PrismWeb.AquaLive.Section

  alias Compendium.AquaPath

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded, false)
     |> assign(:skills, [])
     |> assign(:skill_open, nil)
     |> assign(:skill_editor, nil)}
  end

  @impl true
  def update(%{load: true} = assigns, socket) do
    {:ok, socket |> assign(Map.delete(assigns, :load)) |> load_skills() |> assign(:loaded, true)}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("dismiss_flash", _params, socket), do: {:noreply, clear_flash(socket)}

  def handle_event("skill_open", %{"name" => name}, socket) do
    case read_skill(socket, name) do
      {:ok, skill} ->
        {:noreply, assign(socket, :skill_open, skill)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not read that scroll: #{error_message(reason)}")}
    end
  end

  def handle_event("skill_close", _params, socket),
    do: {:noreply, assign(socket, :skill_open, nil)}

  def handle_event("skill_new", _params, socket) do
    {:noreply, assign(socket, :skill_editor, %{name: nil, description: "", content: ""})}
  end

  # Editing starts from the scroll as it is now, not from the index row:
  # the index carries the description alone, and the body is what is
  # being edited.
  def handle_event("skill_edit", %{"name" => name}, socket) do
    case read_skill(socket, name) do
      {:ok, skill} ->
        {:noreply,
         assign(socket, :skill_editor, %{
           name: name,
           description: skill.description,
           content: skill.content
         })}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not read that scroll: #{error_message(reason)}")}
    end
  end

  def handle_event("skill_cancel", _params, socket),
    do: {:noreply, assign(socket, :skill_editor, nil)}

  def handle_event(
        "skill_save",
        %{"description" => description, "content" => content} = params,
        socket
      ) do
    ctx = socket.assigns.context

    {action, name} =
      case socket.assigns.skill_editor do
        %{name: name} when is_binary(name) -> {"skill_update", name}
        _ -> {"skill_create", params["name"] || ""}
      end

    case call_aqua(ctx, %{
           "action" => action,
           "name" => name,
           "description" => description,
           "content" => content
         }) do
      {:ok, _} ->
        send(self(), {:refresh, :skills})

        {:noreply,
         socket
         |> assign(:skill_editor, nil)
         |> reopen_skill(name)
         |> put_flash(:info, "Kept the scroll '#{name}'.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not keep that scroll: #{error_message(reason)}")}
    end
  end

  # Same disposition as a role: the estate's own scroll is deleted, an
  # edited copy of a shipped one is restored.
  def handle_event("skill_delete", %{"name" => name}, socket) do
    case call_aqua(socket.assigns.context, %{"action" => "skill_delete", "name" => name}) do
      {:ok, _} ->
        open = socket.assigns.skill_open
        socket = if open && open.name == name, do: assign(socket, :skill_open, nil), else: socket
        send(self(), {:refresh, :skills})
        {:noreply, put_flash(socket, :info, "Deleted the scroll '#{name}'.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not delete that scroll: #{error_message(reason)}")}
    end
  end

  def handle_event("skill_revert", %{"name" => name}, socket) do
    case call_aqua(socket.assigns.context, %{"action" => "skill_reset", "name" => name}) do
      {:ok, _} ->
        open = socket.assigns.skill_open
        socket = if open && open.name == name, do: assign(socket, :skill_open, nil), else: socket
        send(self(), {:refresh, :skills})

        {:noreply,
         put_flash(socket, :info, "Reverted the scroll '#{name}' to what ships with the server.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not revert that scroll: #{error_message(reason)}")}
    end
  end

  # ============================================================================
  # Reads and helpers
  # ============================================================================

  defp load_skills(socket) do
    skills =
      case call_tool(socket.assigns.context, "aqua/skill_list", %{}) do
        {:ok, %{skills: skills}} -> skills
        _ -> []
      end

    assign(socket, :skills, skills)
  end

  defp read_skill(socket, name),
    do: call_tool(socket.assigns.context, "aqua/skill_get", %{"name" => name})

  # After a save, the open scroll (if it is the one saved) shows the new body.
  defp reopen_skill(socket, name) do
    case socket.assigns.skill_open do
      %{name: ^name} ->
        case read_skill(socket, name) do
          {:ok, skill} -> assign(socket, :skill_open, skill)
          _ -> assign(socket, :skill_open, nil)
        end

      _ ->
        socket
    end
  end

  defp skill_provenance(provenance, name) when is_binary(name),
    do: Map.get(provenance, Enum.join(AquaPath.skill_dir(name), "/"))

  # Label, confirm prefix and event of the one removal verb an open
  # scroll may offer.
  defp skill_removal("user"), do: {"Delete", "Delete the scroll '", "skill_delete"}

  defp skill_removal("bundled_modified"),
    do: {"Revert to shipped", "Revert the scroll '", "skill_revert"}

  defp skill_removal(_state), do: nil

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="aqua-scrolls-section" phx-target={@myself}>
      <.section_flash flash={@flash} target={@myself} />

      <%!-- The scrolls: what AQUA can read on demand. --%>
      <details
        :if={@loaded}
        id="aqua-scrolls"
        class="rounded-lg border border-gray-800 bg-gray-900/40"
        open={@skills != [] or @skill_editor != nil}
      >
        <summary class="cursor-pointer px-4 py-2 text-sm font-medium text-gray-200">
          Scrolls <span class="text-xs text-gray-500">({length(@skills)})</span>
        </summary>
        <div class="border-t border-gray-800 px-4 py-2 space-y-2">
          <div class="flex items-center justify-between gap-2">
            <p :if={@skills == []} class="text-xs text-gray-600">
              No scrolls here. AQUA can write one when it learns a way of working worth keeping — or you can.
            </p>
            <p :if={@skills != []} class="text-xs text-gray-600">
              A way of working AQUA reads when the task calls for it.
            </p>
            <button
              :if={@skill_editor == nil}
              type="button"
              phx-click="skill_new"
              phx-target={@myself}
              class="shrink-0 rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
            >
              + New scroll
            </button>
          </div>
          <ul :if={@skills != []} class="divide-y divide-gray-800/60">
            <li :for={skill <- @skills} class="py-1">
              <button
                type="button"
                phx-click="skill_open"
                phx-target={@myself}
                phx-value-name={skill.name}
                class="text-left text-xs text-gray-300 hover:text-white"
              >
                <span class="font-mono">{skill.name}</span>
                <span :if={skill.description != ""} class="ml-2 text-gray-500">
                  {skill.description}
                </span>
              </button>
            </li>
          </ul>
          <form
            :if={@skill_editor}
            id="aqua-scroll-editor"
            phx-submit="skill_save"
            phx-target={@myself}
            class="rounded border border-gray-800 bg-gray-950 p-3 space-y-2"
          >
            <input
              :if={@skill_editor.name == nil}
              type="text"
              name="name"
              placeholder="scroll-name"
              pattern="[A-Za-z0-9_-]+"
              required
              class="w-full rounded bg-gray-900 border border-gray-700 px-2 py-1 text-xs text-white placeholder-gray-600 focus:border-blue-500 font-mono"
            />
            <span :if={@skill_editor.name} class="block text-xs font-mono text-gray-200">
              {@skill_editor.name}
            </span>
            <input
              type="text"
              name="description"
              value={@skill_editor.description}
              placeholder="One line: when AQUA should read this"
              required
              class="w-full rounded bg-gray-900 border border-gray-700 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500"
            />
            <textarea
              name="content"
              rows="10"
              required
              placeholder="The way of working, as instructions"
              class="w-full rounded bg-gray-900 border border-gray-700 px-3 py-2 text-xs text-gray-200 font-mono placeholder-gray-600 focus:border-blue-500 focus:outline-none"
            >{@skill_editor.content}</textarea>
            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                phx-click="skill_cancel"
                phx-target={@myself}
                class="rounded px-3 py-1 text-xs text-gray-300 hover:bg-gray-800"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="rounded bg-blue-600 hover:bg-blue-500 px-3 py-1 text-xs font-medium text-white"
              >
                {if @skill_editor.name, do: "Save", else: "Create"}
              </button>
            </div>
          </form>
          <div
            :if={@skill_open}
            id="aqua-scroll-open"
            class="rounded border border-gray-800 bg-gray-950 p-3 space-y-1"
          >
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2 min-w-0">
                <span class="text-xs font-mono text-gray-200">{@skill_open.name}</span>
                <.provenance_chip state={skill_provenance(@provenance, @skill_open.name)} />
              </div>
              <div class="flex items-center gap-1 shrink-0">
                <button
                  type="button"
                  phx-click="skill_edit"
                  phx-target={@myself}
                  phx-value-name={@skill_open.name}
                  class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
                >
                  Edit
                </button>
                <% removal = skill_removal(skill_provenance(@provenance, @skill_open.name)) %>
                <button
                  :if={removal}
                  type="button"
                  phx-click={elem(removal, 2)}
                  phx-target={@myself}
                  phx-value-name={@skill_open.name}
                  data-confirm={elem(removal, 1) <> @skill_open.name <> "'?"}
                  class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
                >
                  {elem(removal, 0)}
                </button>
                <button
                  type="button"
                  phx-click="skill_close"
                  phx-target={@myself}
                  class="text-gray-500 hover:text-gray-300 px-1"
                  aria-label="Close"
                >
                  ×
                </button>
              </div>
            </div>
            <pre class="whitespace-pre-wrap text-xs text-gray-300 font-mono">{@skill_open.content}</pre>
            <p :if={@skill_open.resources != []} class="text-[10px] text-gray-500">
              Files: {Enum.join(@skill_open.resources, ", ")}
            </p>
          </div>
        </div>
      </details>
    </div>
    """
  end
end
