# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.ScrollsComponent do
  @moduledoc """
  The packs of scrolls, shown as the Scrolls group of what Aqua may use
  (`PrismWeb.AquaLive.AgentsComponent.group/1`), whose switch and entries,
  the `aqua.skill_*` keys, are the roster's to write.

  It is a view of the athanor's `aqua/scrolls/` (`Compendium.Packs`): one
  card for each pack, `cyfr`, the packs brought in and the person's own.
  Its buttons make the writes Files makes there and nothing of their own:
  a new pack is the write of its first scroll, a scroll is written with
  the `aqua` tool's `skill_create` and `skill_update` as a proposal's Save
  writes it, and a scroll or a pack is removed with the `file` tool's
  `delete`. What Files cannot say is the facade's, under the person's
  actor: the sheet a pack is brought in after, the switch, copying a
  scroll into a pack of the person's own, and Download. It reads itself
  when it is first rendered and when the page tells it to.
  """

  use PrismWeb, :live_component

  import PrismWeb.AquaLive.Section

  # The sentence the sheet says, word for word (the act of trust).
  @trust "Its scripts and hooks run in your programs' sessions with each program's own " <>
           "access: its sign-in, any value from your Vault you gave that program, its " <>
           "folder's files, and its network, this CYFR's approved private hosts among it. " <>
           "Switching the pack off takes it out of your programs at their next start, and " <>
           "undoes nothing it already did. Bring in only packs you trust."

  @doc "The sheet's sentence on what a pack's scripts reach, which a proposed script's card says too."
  @spec trust() :: String.t()
  def trust, do: @trust

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded, false)
     |> assign(:packs, [])
     |> assign(:pack_open, nil)
     |> assign(:scroll_open, nil)
     |> assign(:editor, nil)
     |> assign(:bring, nil)
     |> allow_upload(:pack,
       accept: :any,
       max_entries: 1,
       max_file_size: Compendium.pack_archive_bound()
     )}
  end

  @impl true
  def update(%{load: true} = assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :load))

    {:noreply, socket} =
      CyfrWeb.ContextGuard.guard(
        socket,
        &{:noreply, &1 |> load_packs() |> assign(:loaded, true)}
      )

    {:ok, socket}
  end

  def update(assigns, %{assigns: %{loaded: false}} = socket),
    do: update(Map.put(assigns, :load, true), socket)

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("dismiss_flash", _params, socket), do: {:noreply, clear_flash(socket)}

  def handle_event("pack_open", %{"pack" => pack}, socket) do
    open = if socket.assigns.pack_open == pack, do: nil, else: pack
    {:noreply, socket |> assign(:pack_open, open) |> assign(:scroll_open, nil)}
  end

  def handle_event("scroll_open", %{"pack" => pack, "folder" => folder}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case Compendium.scroll_view(socket.assigns.context, pack, folder) do
        {:ok, scroll} ->
          {:noreply, socket |> assign(:scroll_open, scroll) |> assign(:editor, nil)}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not open that scroll: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("scroll_close", _params, socket),
    do: {:noreply, assign(socket, :scroll_open, nil)}

  def handle_event("pack_switch", %{"pack" => pack, "on" => on}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      on? = on == "true"

      case Compendium.switch_pack(socket.assigns.context, pack, on?) do
        :ok ->
          send(self(), {:refresh, :skills})
          {:noreply, load_packs(socket)}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not switch #{pack}: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("pack_new", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:editor, %{pack: nil, scroll: nil, description: "", content: ""})
       |> assign(:scroll_open, nil)}

  def handle_event("scroll_new", %{"pack" => pack}, socket),
    do:
      {:noreply,
       socket
       |> assign(:editor, %{pack: pack, scroll: nil, description: "", content: ""})
       |> assign(:scroll_open, nil)}

  def handle_event("scroll_edit", _params, %{assigns: %{scroll_open: scroll}} = socket)
      when is_map(scroll) do
    {:noreply,
     assign(socket, :editor, %{
       pack: scroll.pack,
       scroll: scroll.scroll,
       description: scroll.description,
       content: scroll.body
     })}
  end

  def handle_event("editor_cancel", _params, socket), do: {:noreply, assign(socket, :editor, nil)}

  def handle_event("editor_save", params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      save(socket, socket.assigns.editor, params)
    end)
  end

  # A scroll goes as Files deletes a folder of a pack: its pack refuses it
  # when the pack is not the person's own.
  def handle_event("scroll_delete", %{"pack" => pack, "folder" => folder}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      path = Enum.join(Compendium.pack_dir(pack) ++ ["skills", folder], "/")

      case call_tool(socket.assigns.context, "file/delete", %{"path" => path}) do
        {:ok, _} ->
          send(self(), {:refresh, :skills})

          {:noreply,
           socket
           |> assign(:scroll_open, nil)
           |> load_packs()
           |> put_flash(:info, "Deleted the scroll '#{folder}' from #{pack}.")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not delete that scroll: #{error_message(reason)}")}
      end
    end)
  end

  # A pack goes as Files deletes its folder; `cyfr` ships and refuses.
  def handle_event("pack_remove", %{"pack" => pack}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      path = Enum.join(Compendium.pack_dir(pack), "/")

      case call_tool(socket.assigns.context, "file/delete", %{"path" => path}) do
        {:ok, _} ->
          send(self(), {:refresh, :skills})

          {:noreply,
           socket
           |> assign(:pack_open, nil)
           |> assign(:scroll_open, nil)
           |> load_packs()
           |> put_flash(:info, "Removed the pack #{pack}.")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not remove #{pack}: #{error_message(reason)}")}
      end
    end)
  end

  def handle_event("scroll_copy", %{"name" => name}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      mine = Compendium.first_pack()

      case Compendium.copy_scroll(socket.assigns.context, name, mine) do
        :ok ->
          send(self(), {:refresh, :skills})

          {:noreply, socket |> load_packs() |> put_flash(:info, "Copied #{name} into #{mine}.")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not copy #{name}: #{error_message(reason)}")}
      end
    end)
  end

  # ---- bringing a pack in --------------------------------------------------

  def handle_event("bring_validate", _params, socket), do: {:noreply, socket}

  def handle_event("bring_cancel", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.pack.entries, socket, &cancel_upload(&2, :pack, &1.ref))

    {:noreply, assign(socket, :bring, nil)}
  end

  # The archive is read once into the sheet; its bytes are held for the
  # press, which reads them again and lands them only when they still make
  # the files the person agreed to.
  def handle_event("bring_read", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      uploaded =
        consume_uploaded_entries(socket, :pack, fn %{path: tmp}, entry ->
          # arca:bypass-ok=D — Plug-managed upload tmp file.
          {:ok, {entry.client_name, File.read!(tmp)}}
        end)

      case uploaded do
        [{filename, bytes}] -> {:noreply, sheet(socket, filename, bytes, %{})}
        [] -> {:noreply, put_flash(socket, :error, "Choose a .zip or .tar.gz archive first.")}
      end
    end)
  end

  def handle_event("bring_choose", params, %{assigns: %{bring: %{} = bring}} = socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      opts = Map.take(params, ["folder", "name"])
      {:noreply, sheet(socket, bring.filename, bring.bytes, opts)}
    end)
  end

  def handle_event(
        "bring_confirm",
        _params,
        %{assigns: %{bring: %{sheet: sheet} = bring}} = socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      params = %{
        "folder" => sheet.folder,
        "name" => sheet.name,
        "agreed" => sheet.agreed,
        "against" => sheet.against
      }

      case Compendium.bring_in_pack(socket.assigns.context, bring.bytes, bring.filename, params) do
        {:ok, name} ->
          send(self(), {:refresh, :skills})

          {:noreply,
           socket
           |> assign(:bring, nil)
           |> assign(:pack_open, name)
           |> load_packs()
           |> put_flash(
             :info,
             if(sheet.update, do: "Updated #{name}.", else: "Brought in #{name}.")
           )}

        {:error, {:changed, sheet}} ->
          {:noreply,
           socket
           |> assign(:bring, %{bring | sheet: sheet})
           |> put_flash(:error, "The pack changed since the sheet was shown: read it again.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not bring it in: #{error_message(reason)}")}
      end
    end)
  end

  # ============================================================================
  # Reads and writes
  # ============================================================================

  defp load_packs(socket) do
    packs =
      case Compendium.packs(socket.assigns.context) do
        {:ok, packs} -> packs
        {:error, _} -> []
      end

    assign(socket, :packs, packs)
  end

  defp sheet(socket, filename, bytes, opts) do
    case Compendium.pack_sheet(socket.assigns.context, bytes, filename, opts) do
      {:ok, sheet} ->
        assign(socket, :bring, %{filename: filename, bytes: bytes, sheet: sheet})

      {:error, reason} ->
        socket
        |> assign(:bring, nil)
        |> put_flash(:error, "Could not read that archive: #{error_message(reason)}")
    end
  end

  # New pack is one act: its name and its first scroll's, written as the
  # write of that scroll's manifest under the new folder, refused under
  # `cyfr`, a pack already here or a name outside the grammar.
  defp save(socket, %{pack: nil} = editor, params) do
    pack = String.trim(params["pack"] || "")

    cond do
      not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, pack) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A pack's name is letters, digits, '_' and '-', starting with a letter or digit."
         )}

      Enum.any?(socket.assigns.packs, &(&1.name == pack)) ->
        {:noreply,
         put_flash(socket, :error, "A pack named #{pack} is already here: choose another name.")}

      true ->
        save(socket, %{editor | pack: pack}, params, :new_pack)
    end
  end

  defp save(socket, editor, params), do: save(socket, editor, params, :scroll)

  defp save(socket, editor, params, kind) do
    scroll = editor.scroll || String.trim(params["scroll"] || "")
    name = editor.pack <> ":" <> scroll
    action = if editor.scroll, do: "skill_update", else: "skill_create"

    args = %{
      "action" => action,
      "name" => name,
      "description" => params["description"],
      "content" => params["content"]
    }

    args = if kind == :new_pack, do: Map.put(args, "new_pack", true), else: args

    case call_aqua(socket.assigns.context, args) do
      {:ok, _} ->
        send(self(), {:refresh, :skills})

        {:noreply,
         socket
         |> assign(:editor, nil)
         |> assign(:pack_open, editor.pack)
         |> load_packs()
         |> put_flash(:info, saved_words(kind, editor.pack, name))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not keep that scroll: #{error_message(reason)}")}
    end
  end

  defp saved_words(:new_pack, pack, name), do: "Made the pack #{pack} with the scroll #{name}."
  defp saved_words(:scroll, _pack, name), do: "Kept the scroll #{name}."

  # ============================================================================
  # What a card says
  # ============================================================================

  defp origin_words(%{origin: "cyfr"}), do: "CYFR"
  defp origin_words(%{origin: "own"}), do: "yours"

  defp origin_words(%{origin: "brought", source: source}) when is_binary(source),
    do: "an upload: #{source}"

  defp origin_words(%{origin: "brought"}), do: "an upload"
  defp origin_words(_pack), do: "unreadable"

  defp count(n, one, many), do: "#{n} #{if n == 1, do: one, else: many}"

  # What each program carries of a pack (the plan's table), said per card.
  defp carried_by(pack) do
    parts =
      pack.parts || %{agents: [], commands: [], hooks: [], servers: [], skills: [], unread: []}

    claude =
      ["scrolls"] ++
        if(parts.agents != [], do: ["agents"], else: []) ++
        if(parts.commands != [], do: ["commands"], else: []) ++
        if(parts.hooks != [], do: ["hooks"], else: []) ++
        if(parts.servers != [], do: ["MCP servers"], else: [])

    [
      {"Claude Code", Enum.join(claude, ", ")},
      {"Codex", "scrolls alone"},
      {"Other programs and API keys", "scrolls, read through Aqua"}
    ]
  end

  defp kept_any?(pack), do: Enum.any?(pack.scrolls, & &1.kept)

  defp download_href(athanor, pack),
    do:
      PrismWeb.Focus.path(
        athanor,
        "/scrolls/download/" <> URI.encode(pack, &URI.char_unreserved?/1)
      )

  defp change_words(:added), do: "added"
  defp change_words(:removed), do: "removed"
  defp change_words(:changed), do: "changed"

  # ============================================================================
  # Render
  # ============================================================================

  attr :pack, :map, required: true
  attr :myself, :any, required: true
  attr :athanor, :any, required: true
  attr :upload, :string, required: true

  defp actions(assigns) do
    ~H"""
    <details class="relative" id={"aqua-pack-menu-" <> @pack.name}>
      <summary class="cursor-pointer list-none rounded px-2 py-1 text-[11px] text-gray-400 hover:bg-gray-800 hover:text-gray-200">
        Actions ▾
      </summary>
      <div class="absolute right-0 z-10 mt-1 w-44 rounded border border-gray-800 bg-gray-950 p-1 shadow-lg">
        <button
          :if={@pack.origin == "own"}
          type="button"
          phx-click="scroll_new"
          phx-target={@myself}
          phx-value-pack={@pack.name}
          class="block w-full rounded px-2 py-1 text-left text-[11px] text-blue-400 hover:bg-gray-800"
        >
          New scroll
        </button>
        <label
          :if={@pack.origin == "brought"}
          for={@upload}
          class="block w-full cursor-pointer rounded px-2 py-1 text-left text-[11px] text-blue-400 hover:bg-gray-800"
        >
          Check for an update
        </label>
        <a
          href={download_href(@athanor, @pack.name)}
          download
          class="block w-full rounded px-2 py-1 text-left text-[11px] text-blue-400 hover:bg-gray-800"
        >
          Download
        </a>
        <button
          :if={@pack.origin in ["own", "brought"]}
          type="button"
          phx-click="pack_remove"
          phx-target={@myself}
          phx-value-pack={@pack.name}
          data-confirm={"Remove the pack " <> @pack.name <> " and every scroll in it?"}
          class="block w-full rounded px-2 py-1 text-left text-[11px] text-gray-400 hover:bg-red-900/40 hover:text-red-300"
        >
          Remove
        </button>
      </div>
    </details>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :trust, @trust)

    ~H"""
    <div id="aqua-scrolls-section" phx-target={@myself}>
      <.section_flash flash={@flash} target={@myself} />

      <PrismWeb.AquaLive.AgentsComponent.group
        group={@group}
        tools={@tools}
        target={@target}
        details_id="aqua-scrolls"
        open={@editor != nil or @bring != nil}
      >
        <div class="space-y-2 px-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="text-[11px] text-gray-500">
              {count(length(@packs), "pack", "packs")} of scrolls: each scroll is a way of working Aqua and your programs read when the task calls for it.
            </p>
            <div class="flex flex-wrap items-center gap-1">
              <form
                id="aqua-bring-form"
                phx-change="bring_validate"
                phx-submit="bring_read"
                phx-target={@myself}
                class="flex items-center gap-1"
              >
                <label
                  for={@uploads.pack.ref}
                  class="cursor-pointer rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
                >
                  Bring in a pack
                </label>
                <.live_file_input upload={@uploads.pack} class="sr-only" />
                <button
                  :if={@uploads.pack.entries != []}
                  type="submit"
                  class="rounded bg-gray-800 px-2 py-1 text-[11px] text-gray-200 hover:bg-gray-700"
                >
                  Read {hd(@uploads.pack.entries).client_name}
                </button>
              </form>
              <button
                :if={@editor == nil}
                type="button"
                phx-click="pack_new"
                phx-target={@myself}
                class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
              >
                + New pack
              </button>
            </div>
          </div>

          <%!-- The sheet: once for each pack, at bringing it in and at each update. --%>
          <div
            :if={@bring}
            id="aqua-pack-sheet"
            class="space-y-2 rounded border border-amber-800/60 bg-gray-950 p-3"
          >
            <% sheet = @bring.sheet %>
            <form
              id="aqua-sheet-choose"
              phx-change="bring_choose"
              phx-target={@myself}
              class="space-y-2"
            >
              <div :if={length(sheet.candidates) > 1}>
                <label class="block text-[11px] text-gray-400">This archive holds more than one pack. Which one?</label>
                <select
                  name="folder"
                  class="w-full rounded border border-gray-700 bg-gray-900 px-2 py-1 text-xs text-gray-200"
                >
                  <option
                    :for={c <- sheet.candidates}
                    value={c.folder}
                    selected={c.folder == sheet.folder}
                  >
                    {if c.folder == "", do: "(the archive's top)", else: c.folder}
                  </option>
                </select>
              </div>
              <div>
                <label class="block text-[11px] text-gray-400">Its name on CYFR</label>
                <input
                  type="text"
                  name="name"
                  value={sheet.name}
                  readonly={sheet.named_by_manifest}
                  class="w-full rounded border border-gray-700 bg-gray-900 px-2 py-1 font-mono text-xs text-gray-200"
                />
                <p :if={sheet.named_by_manifest} class="text-[11px] text-gray-500">
                  Its manifest names it, as Claude Code lists it.
                </p>
              </div>
            </form>
            <p class="text-xs text-gray-300">
              <span class="font-mono">{sheet.name}</span>
              <span :if={sheet.version}> · version {sheet.version}</span> · from {sheet.filename}
            </p>
            <ul class="space-y-0.5 text-[11px] text-gray-400">
              <li>
                {count(length(sheet.scrolls), "scroll", "scrolls")}: {Enum.map_join(
                  sheet.scrolls,
                  ", ",
                  & &1.scroll
                )}
              </li>
              <li>{count(sheet.scripts, "script", "scripts")}</li>
              <li :if={sheet.parts.hooks != []}>Hooks: {Enum.join(sheet.parts.hooks, ", ")}</li>
              <li :if={sheet.parts.agents != []}>Agents: {Enum.join(sheet.parts.agents, ", ")}</li>
              <li :if={sheet.parts.commands != []}>
                Commands: {Enum.join(sheet.parts.commands, ", ")}
              </li>
              <li id="aqua-sheet-servers">
                MCP servers it starts: {if sheet.parts.servers == [],
                  do: "none",
                  else: Enum.join(sheet.parts.servers, ", ")}
              </li>
              <li :if={sheet.parts.skills != []}>
                Skills beside its scrolls: {Enum.join(sheet.parts.skills, ", ")}
              </li>
              <li :for={key <- sheet.parts.unread} class="text-amber-300">
                This pack declares {key} CYFR could not read.
              </li>
            </ul>
            <div :if={sheet.update} id="aqua-sheet-update" class="text-[11px] text-gray-400">
              <p class="text-gray-300">What this update changes, scripts and hooks first:</p>
              <p :if={sheet.update == []}>Nothing: the files are the ones you hold.</p>
              <ul>
                <li :for={c <- sheet.update} class="font-mono">{change_words(c.change)} {c.path}</li>
              </ul>
            </div>
            <p id="aqua-sheet-trust" class="text-xs text-amber-200">{@trust}</p>
            <p :if={sheet.refusal} id="aqua-sheet-refusal" class="text-xs text-red-300">
              {sheet.refusal}
            </p>
            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                phx-click="bring_cancel"
                phx-target={@myself}
                class="rounded px-3 py-1 text-xs text-gray-300 hover:bg-gray-800"
              >
                Cancel
              </button>
              <button
                type="button"
                id="aqua-sheet-confirm"
                phx-click="bring_confirm"
                phx-target={@myself}
                disabled={sheet.refusal != nil}
                class="rounded bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-500 disabled:opacity-40"
              >
                {if sheet.update, do: "Update", else: "Bring in"}
              </button>
            </div>
          </div>

          <form
            :if={@editor}
            id="aqua-scroll-editor"
            phx-submit="editor_save"
            phx-target={@myself}
            class="w-full space-y-2 rounded border border-gray-800 bg-gray-950 p-3"
          >
            <input
              :if={@editor.pack == nil}
              type="text"
              name="pack"
              placeholder="pack-name"
              pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
              required
              class="w-full rounded border border-gray-700 bg-gray-900 px-2 py-1 font-mono text-xs text-white placeholder-gray-600 focus:border-blue-500"
            />
            <input
              :if={@editor.scroll == nil}
              type="text"
              name="scroll"
              placeholder={if @editor.pack == nil, do: "its-first-scroll", else: "scroll-name"}
              pattern="[A-Za-z0-9][A-Za-z0-9_-]*"
              required
              class="w-full rounded border border-gray-700 bg-gray-900 px-2 py-1 font-mono text-xs text-white placeholder-gray-600 focus:border-blue-500"
            />
            <span :if={@editor.scroll} class="block font-mono text-xs text-gray-200">
              {@editor.pack}:{@editor.scroll}
            </span>
            <span :if={@editor.pack && @editor.scroll == nil} class="block text-[11px] text-gray-500">
              A new scroll in {@editor.pack}
            </span>
            <input
              type="text"
              name="description"
              value={@editor.description}
              placeholder="One line: when Aqua should read this"
              required
              class="w-full rounded border border-gray-700 bg-gray-900 px-2 py-1 text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500"
            />
            <textarea
              name="content"
              rows="10"
              required
              placeholder="The way of working, as instructions"
              class="w-full rounded border border-gray-700 bg-gray-900 px-3 py-2 font-mono text-xs text-gray-200 placeholder-gray-600 focus:border-blue-500 focus:outline-none"
            >{@editor.content}</textarea>
            <div class="flex items-center justify-end gap-2">
              <button
                type="button"
                phx-click="editor_cancel"
                phx-target={@myself}
                class="rounded px-3 py-1 text-xs text-gray-300 hover:bg-gray-800"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="rounded bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-500"
              >
                {cond do
                  @editor.pack == nil -> "Make the pack"
                  @editor.scroll -> "Save"
                  true -> "Create"
                end}
              </button>
            </div>
          </form>

          <%!-- The packs as cards: one column at narrow width, two beside each other at wider. --%>
          <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
            <div
              :for={pack <- @packs}
              id={"aqua-pack-" <> pack.name}
              class="space-y-1 rounded border border-gray-800 bg-gray-950 p-2"
            >
              <div class="flex items-start justify-between gap-2">
                <button
                  type="button"
                  phx-click="pack_open"
                  phx-target={@myself}
                  phx-value-pack={pack.name}
                  class="min-w-0 text-left"
                >
                  <span class="font-mono text-xs text-gray-200">{pack.name}</span>
                  <span class="block text-[11px] text-gray-500">
                    {origin_words(pack)}<span :if={pack.version}> · version {pack.version}</span>
                    · {count(length(pack.scrolls), "scroll", "scrolls")}
                  </span>
                </button>
                <div class="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    role="switch"
                    aria-checked={to_string(pack.on)}
                    aria-label={"Switch " <> pack.name <> if(pack.on, do: " off", else: " on")}
                    phx-click="pack_switch"
                    phx-target={@myself}
                    phx-value-pack={pack.name}
                    phx-value-on={to_string(not pack.on)}
                    class={[
                      "rounded px-2 py-0.5 text-[10px] font-medium",
                      if(pack.on,
                        do: "bg-emerald-900/50 text-emerald-300",
                        else: "bg-gray-800 text-gray-400"
                      )
                    ]}
                  >
                    {if pack.on, do: "On", else: "Off"}
                  </button>
                  <.actions
                    pack={pack}
                    myself={@myself}
                    athanor={@athanor}
                    upload={@uploads.pack.ref}
                  />
                </div>
              </div>
              <p :if={pack.past} class="text-[11px] text-amber-400">
                No program uses this pack: {pack.past}.
              </p>
              <dl
                :if={@pack_open == pack.name}
                class="grid grid-cols-1 gap-x-2 text-[11px] sm:grid-cols-[auto_1fr]"
              >
                <%= for {who, what} <- carried_by(pack) do %>
                  <dt class="text-gray-500">{who}</dt>
                  <dd class="text-gray-300">{what}</dd>
                <% end %>
              </dl>
              <p :if={@pack_open == pack.name and kept_any?(pack)} class="text-[11px] text-gray-500">
                Some scrolls here are used when named: Claude Code keeps it from the model; Codex shows the model every skill of a pack.
              </p>
              <p
                :if={@pack_open == pack.name and pack.origin != "own"}
                class="text-[11px] text-gray-500"
              >
                In the sessions CYFR starts, Claude Code loads this pack in place of a plugin of yours named {pack.name}.
              </p>
              <p
                :if={(@pack_open == pack.name and pack.parts) && pack.parts.servers != []}
                class="text-[11px] text-gray-500"
              >
                MCP servers it starts: {Enum.join(pack.parts.servers, ", ")}
              </p>
              <p
                :for={key <- (@pack_open == pack.name && pack.parts && pack.parts.unread) || []}
                class="text-[11px] text-amber-300"
              >
                This pack declares {key} CYFR could not read.
              </p>
              <ul :if={@pack_open == pack.name} class="divide-y divide-gray-800/60">
                <li :for={scroll <- pack.scrolls} class="py-1">
                  <button
                    type="button"
                    phx-click="scroll_open"
                    phx-target={@myself}
                    phx-value-pack={pack.name}
                    phx-value-folder={scroll.folder}
                    class="text-left text-xs text-gray-300 hover:text-white"
                  >
                    <span class="font-mono">{scroll.name}</span>
                    <span :if={scroll.description != ""} class="ml-2 text-gray-500">{scroll.description}</span>
                  </button>
                  <p
                    :if={scroll.kept}
                    id={"aqua-scroll-kept-" <> pack.name <> "-" <> scroll.folder}
                    class="text-[11px] text-gray-500"
                  >
                    used when named
                  </p>
                  <p :if={scroll.shadowed} class="text-[11px] text-amber-400">
                    Not used: an earlier scroll of this pack has the name {scroll.scroll}.
                  </p>
                  <p
                    :if={not scroll.carried and not scroll.shadowed and is_nil(pack.past)}
                    id={"aqua-scroll-too-large-" <> pack.name <> "-" <> scroll.folder}
                    class="text-[11px] text-amber-400"
                  >
                    Aqua does not use this scroll: a scroll, its files' names with it, holds at most {Compendium.skill_bound().bytes} bytes and its description at most {Compendium.skill_bound().description} characters.
                  </p>
                </li>
              </ul>
            </div>
          </div>

          <div
            :if={@scroll_open}
            id="aqua-scroll-open"
            class="w-full space-y-1 rounded border border-gray-800 bg-gray-950 p-3"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="font-mono text-xs text-gray-200">{@scroll_open.name}</span>
              <div class="flex shrink-0 items-center gap-1">
                <button
                  :if={@scroll_open.origin == "own"}
                  type="button"
                  phx-click="scroll_edit"
                  phx-target={@myself}
                  class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
                >
                  Edit
                </button>
                <button
                  :if={@scroll_open.origin == "own"}
                  type="button"
                  phx-click="scroll_delete"
                  phx-target={@myself}
                  phx-value-pack={@scroll_open.pack}
                  phx-value-folder={@scroll_open.folder}
                  data-confirm={"Delete the scroll " <> @scroll_open.name <> "?"}
                  class="rounded px-2 py-1 text-[11px] text-gray-500 hover:bg-red-900/40 hover:text-red-300"
                >
                  Delete
                </button>
                <button
                  :if={@scroll_open.origin != "own"}
                  type="button"
                  phx-click="scroll_copy"
                  phx-target={@myself}
                  phx-value-name={@scroll_open.name}
                  class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
                >
                  Copy to my pack
                </button>
                <button
                  type="button"
                  phx-click="scroll_close"
                  phx-target={@myself}
                  class="px-1 text-gray-500 hover:text-gray-300"
                  aria-label="Close"
                >
                  ×
                </button>
              </div>
            </div>
            <p :if={@scroll_open.kept} class="text-[11px] text-gray-500">used when named</p>
            <pre class="whitespace-pre-wrap font-mono text-xs text-gray-300">{@scroll_open.body}</pre>
            <ul :if={@scroll_open.files != []} class="text-[11px] text-gray-500">
              <li :for={file <- @scroll_open.files} class="font-mono">
                {file.path}<span :if={file.runs} class="ml-1 text-emerald-400">· runs</span>
              </li>
            </ul>
          </div>
        </div>
      </PrismWeb.AquaLive.AgentsComponent.group>
    </div>
    """
  end
end
