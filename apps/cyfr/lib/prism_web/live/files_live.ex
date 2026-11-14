# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FilesLive do
  @moduledoc """
  The athanor's files, one tree: the folders the storage layout shows a
  person, each in its tier. `data/` is theirs to fill and clear;
  `components/` and `aqua/` hold shaped units whose files are edited in
  place; `notes/` and `threads/` are read here and managed on
  their own pages. The server's own storage is not a folder at all.

  Every read and change goes through the `file` tool; the bytes of a
  file are downloaded from `PrismWeb.FileController`. The folder in view
  rides the URL (`?p=data/reports`), so a location is a link. A picture
  shows in the open panel only when its bytes begin as one of the raster
  types a browser draws and never runs; anything else is downloaded.

  A new folder is held by the page, listed in its parent and opened,
  until a file is written there: storage keeps no empty folder. Rename
  and Move are both `file/move`, a rename keeping the folder and a move
  the name.

  ## Sending a copy

  Files picked under `data/` are offered, through `file/offer`, to a
  person picked from those the person sits with in a shared thread
  (`Sanctum.SharedThreads.people_in_threads_with/1`). The Inbox lists what
  `file/offers` answers: the offers waiting for the person, each with its
  files' names and sizes and its sender, accepted into the folder the
  answer names unless the person names another, or declined; the files
  accepted here that are still landing, or that could not be delivered;
  and the offers sent from this athanor, each withdrawn while it waits.
  Nothing of an offered file's bytes reaches the page before it lands.
  The page reads the offers again whenever the person's own topic
  (`Cyfr.Bus.file_offers/1`) says one of theirs moved.
  """

  use PrismWeb, :live_view

  require Logger

  alias Cyfr.Bus
  alias PrismWeb.{Ops, People}

  @impl true
  def mount(_params, _session, socket) do
    ctx = socket.assigns.context

    if connected?(socket) and is_binary(ctx.user_id) do
      Bus.subscribe_global(Bus.file_offers(ctx.user_id))
      send(self(), :load_offers)
    end

    {:ok,
     socket
     |> assign(:page_title, "Files")
     |> assign(:active_nav, "files")
     |> assign(:path, "")
     |> assign(:listing, nil)
     |> assign(:loading, true)
     |> assign(:open, nil)
     |> assign(:editing, false)
     |> assign(:upload_error, nil)
     |> assign(:selected, MapSet.new())
     |> assign(:picker, nil)
     |> assign(:offers, nil)
     |> assign(:people, %{})
     |> assign(:new_folders, MapSet.new())
     |> assign(:naming, nil)
     |> assign(:relocating, nil)
     |> allow_upload(:files,
       accept: :any,
       max_entries: 10,
       max_file_size: Arca.Files.max_write()
     )}
  end

  @doc """
  The offers of a `file/offers` inbox still waiting for the person:
  offered and not yet past their expiry, one entry per offer carrying its
  files, in the order the inbox lists them. The Files page lists these and
  the topbar counts them.
  """
  @spec awaiting([map()]) :: [map()]
  def awaiting(inbox) when is_list(inbox) do
    now = DateTime.utc_now()

    inbox
    |> Enum.filter(&(&1.status == "offered" and DateTime.compare(&1.expires_at, now) == :gt))
    |> by_offer()
  end

  # One entry per offer, in the order the listing first names it, with the
  # files it carries.
  defp by_offer(rows) do
    {order, offers} =
      Enum.reduce(rows, {[], %{}}, fn %{offer_id: id} = row, {order, offers} ->
        file = %{filename: row.filename, size: row.size}

        case offers do
          %{^id => offer} ->
            {order, Map.put(offers, id, %{offer | files: offer.files ++ [file]})}

          _new ->
            offer = row |> Map.drop([:filename, :size]) |> Map.put(:files, [file])
            {[id | order], Map.put(offers, id, offer)}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(offers, &1))
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = params |> Map.get("p", "") |> String.trim("/")

    socket =
      socket
      |> assign(:path, path)
      |> assign(:open, nil)
      |> assign(:editing, false)
      |> assign(:naming, nil)
      |> assign(:relocating, nil)

    if connected?(socket) do
      send(self(), :load)
      {:noreply, assign(socket, :loading, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, load(socket)}

  def handle_info(:load_offers, socket), do: {:noreply, load_offers(socket)}

  # An offer of several files is announced once per file: the messages
  # already queued behind this one ask for the same read, so one serves
  # them all.
  def handle_info(%Bus.FileOffer{}, socket) do
    drain_offer_messages()
    {:noreply, load_offers(socket)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ---- navigation ----------------------------------------------------------

  @impl true
  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: folder_href(socket.assigns.athanor_route, path))}
  end

  def handle_event("open", %{"path" => path}, socket) do
    case Ops.call_tool(socket, "file/read", %{"path" => path}) do
      {:ok, file} ->
        {:noreply,
         socket
         |> assign(:open, Map.put(file, :picture, picture(file)))
         |> assign(:editing, false)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Ops.error_message(reason))}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply, socket |> assign(:open, nil) |> assign(:editing, false)}
  end

  # ---- editing --------------------------------------------------------------

  def handle_event("edit", _params, socket), do: {:noreply, assign(socket, :editing, true)}

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, assign(socket, :editing, false)}

  def handle_event("save", %{"content" => content}, %{assigns: %{open: %{path: path}}} = socket) do
    case Ops.call_tool(socket, "file/write", %{"path" => path, "content" => content}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing, false)
         |> assign(:open, %{socket.assigns.open | content: content, size: byte_size(content)})
         |> put_flash(:info, "Saved #{path}")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Ops.error_message(reason))}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"path" => path}, socket) do
    if held?(socket, path),
      do: {:noreply, forget_folder(socket, path)},
      else: {:noreply, delete(socket, path)}
  end

  # ---- folders, rename and move -------------------------------------------

  def handle_event("new_folder", _params, socket),
    do: {:noreply, socket |> assign(:naming, :folder) |> assign(:relocating, nil)}

  def handle_event("cancel_new_folder", _params, socket),
    do: {:noreply, assign(socket, :naming, nil)}

  def handle_event("create_folder", %{"name" => name}, socket) do
    name = String.trim(name)

    case folder_name(name) do
      :ok ->
        folder = child(socket.assigns.path, name)

        {:noreply,
         socket
         |> update(:new_folders, &MapSet.put(&1, folder))
         |> assign(:naming, nil)
         |> push_patch(to: folder_href(socket.assigns.athanor_route, folder))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("relocate", %{"path" => path, "mode" => mode}, socket)
      when mode in ~w(rename move) do
    {:noreply, socket |> assign(:relocating, %{path: path, mode: mode}) |> assign(:naming, nil)}
  end

  def handle_event("cancel_relocate", _params, socket),
    do: {:noreply, assign(socket, :relocating, nil)}

  # A held folder has nothing stored to move: its rename is the page's own.
  def handle_event("move", params, %{assigns: %{relocating: %{path: path, mode: mode}}} = socket) do
    if held?(socket, path),
      do: {:noreply, rename_held(socket, path, params)},
      else: {:noreply, move(socket, path, destination(path, mode, params))}
  end

  def handle_event("move", _params, socket), do: {:noreply, socket}

  # ---- uploads --------------------------------------------------------------

  def handle_event("validate", _params, socket),
    do: {:noreply, assign(socket, :upload_error, nil)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("upload", _params, socket) do
    folder = socket.assigns.path

    outcomes =
      consume_uploaded_entries(socket, :files, fn %{path: tmp}, entry ->
        # arca:bypass-ok=D — Plug-managed upload tmp file.
        bytes = File.read!(tmp)
        target = Enum.join(Enum.reject([folder, entry.client_name], &(&1 == "")), "/")

        result =
          Ops.call_tool(socket, "file/write", %{
            "path" => target,
            "content" => Base.encode64(bytes),
            "encoding" => "base64"
          })

        {:ok, {target, result}}
      end)

    failed =
      for {target, {:error, reason}} <- outcomes, do: "#{target}: #{Ops.error_message(reason)}"

    landed = for {_target, {:ok, _}} <- outcomes, do: 1

    socket =
      cond do
        failed != [] -> put_flash(socket, :error, Enum.join(failed, " "))
        landed != [] -> put_flash(socket, :info, "Uploaded #{length(landed)} file(s)")
        true -> socket
      end

    {:noreply, load(socket)}
  end

  # ---- sending a copy -------------------------------------------------------

  def handle_event("toggle_select", %{"path" => path}, socket) do
    if offerable?(path) do
      {:noreply,
       update(socket, :selected, fn selected ->
         if MapSet.member?(selected, path),
           do: MapSet.delete(selected, path),
           else: MapSet.put(selected, path)
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, socket |> assign(:selected, MapSet.new()) |> assign(:picker, nil)}

  # Who the person may send to is read when they ask, so the list is as
  # current as the moment they pick from it.
  def handle_event("open_picker", _params, socket) do
    ctx = socket.assigns.context

    picker =
      case Sanctum.SharedThreads.people_in_threads_with(ctx.user_id) do
        {:ok, people} ->
          people
          |> Enum.map(&Map.put(&1, :label, People.label(&1, ctx)))
          |> Enum.sort_by(&{String.downcase(&1.label), &1.user_id})

        {:error, _reason} ->
          :error
      end

    {:noreply, assign(socket, :picker, picker)}
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, assign(socket, :picker, nil)}

  def handle_event("send_copy", %{"to" => to}, socket) when is_binary(to) and to != "" do
    paths = socket.assigns.selected |> MapSet.to_list() |> Enum.sort()

    case Ops.call_tool(socket, "file/offer", %{"paths" => paths, "to" => to}) do
      {:ok, %{files: files}} ->
        {:noreply,
         socket
         |> assign(:selected, MapSet.new())
         |> assign(:picker, nil)
         |> put_flash(:info, "Offered a copy of #{count(files, "file")}")
         |> load_offers()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Ops.error_message(reason))}
    end
  end

  def handle_event("send_copy", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Pick who to send the copy to.")}

  def handle_event("accept", %{"offer_id" => offer_id} = params, socket) do
    args =
      case params |> Map.get("folder", "") |> String.trim() do
        "" -> %{"offer_id" => offer_id}
        folder -> %{"offer_id" => offer_id, "folder" => folder}
      end

    case Ops.call_tool(socket, "file/accept", args) do
      {:ok, %{folder: folder}} ->
        {:noreply,
         socket |> put_flash(:info, "Accepted into #{folder}") |> load_offers() |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, Ops.error_message(reason)) |> load_offers()}
    end
  end

  def handle_event("decline", %{"offer_id" => offer_id}, socket),
    do: {:noreply, end_offer(socket, "file/decline", offer_id, "Declined")}

  def handle_event("withdraw", %{"offer_id" => offer_id}, socket),
    do: {:noreply, end_offer(socket, "file/withdraw", offer_id, "Withdrawn")}

  defp end_offer(socket, operation, offer_id, done) do
    case Ops.call_tool(socket, operation, %{"offer_id" => offer_id}) do
      {:ok, _} -> socket |> put_flash(:info, done) |> load_offers()
      {:error, reason} -> socket |> put_flash(:error, Ops.error_message(reason)) |> load_offers()
    end
  end

  # Only a file under `data/` is offered; the operation holds to it too.
  defp offerable?(path), do: String.starts_with?(path, "data/")

  defp in_data?(folder), do: folder == "data" or offerable?(folder)

  defp drain_offer_messages do
    receive do
      %Bus.FileOffer{} -> drain_offer_messages()
    after
      0 -> :ok
    end
  end

  defp held?(socket, path), do: MapSet.member?(socket.assigns.new_folders, path)

  defp rename_held(socket, path, params) do
    name = params |> Map.get("name", "") |> String.trim()

    case folder_name(name) do
      :ok ->
        to = child(parent(path), name)

        socket
        |> update(:new_folders, &(&1 |> MapSet.delete(path) |> MapSet.put(to)))
        |> assign(:relocating, nil)
        |> put_flash(:info, "Renamed #{path} to #{to}")

      {:error, message} ->
        put_flash(socket, :error, message)
    end
  end

  defp move(socket, path, to) do
    case Ops.call_tool(socket, "file/move", %{"path" => path, "to" => to}) do
      {:ok, %{moved: moved, to: to}} ->
        open = if match?(%{path: ^moved}, socket.assigns.open), do: nil, else: socket.assigns.open

        socket
        |> assign(:relocating, nil)
        |> assign(:open, open)
        |> assign(:editing, false)
        |> update(:selected, &MapSet.delete(&1, moved))
        |> update(:new_folders, &moved_under(&1, moved, to))
        |> put_flash(:info, "Moved #{moved} to #{to}")
        |> load()

      {:error, reason} ->
        put_flash(socket, :error, Ops.error_message(reason))
    end
  end

  # The held folders below a moved folder go with it.
  defp moved_under(held, moved, to) do
    MapSet.new(held, fn folder ->
      if String.starts_with?(folder, moved <> "/"),
        do: to <> String.trim_leading(folder, moved),
        else: folder
    end)
  end

  # A folder the page holds has nothing stored to delete.
  defp forget_folder(socket, path) do
    socket
    |> update(:new_folders, &MapSet.delete(&1, path))
    |> put_flash(:info, "Removed the empty folder #{path}")
  end

  defp delete(socket, path) do
    case Ops.call_tool(socket, "file/delete", %{"path" => path}) do
      {:ok, _} ->
        open = if match?(%{path: ^path}, socket.assigns.open), do: nil, else: socket.assigns.open

        socket
        |> assign(:open, open)
        |> assign(:editing, false)
        |> update(:selected, &MapSet.delete(&1, path))
        |> put_flash(:info, "Deleted #{path}")
        |> load()

      {:error, reason} ->
        put_flash(socket, :error, Ops.error_message(reason))
    end
  end

  # A rename keeps the folder and takes the typed name; a move keeps the
  # name and takes the typed folder.
  defp destination(path, "rename", %{"name" => name}),
    do: child(parent(path), String.trim(name))

  defp destination(path, "move", %{"folder" => folder}),
    do: child(String.trim(folder, "/") |> String.trim(), Path.basename(path))

  defp destination(path, _mode, _params), do: path

  defp folder_name(""), do: {:error, "Name the folder."}

  defp folder_name(name) do
    with false <- String.contains?(name, "/"),
         :ok <- Prima.PathSafety.validate_segments([name]) do
      :ok
    else
      _refused -> {:error, "'#{name}' cannot name a folder: use one name without / or .."}
    end
  end

  # ---- data -----------------------------------------------------------------

  defp load(socket) do
    case Ops.call_tool(socket, "file/list", %{"path" => socket.assigns.path}) do
      {:ok, listing} ->
        socket
        |> assign(:listing, listing)
        |> assign(:loading, false)
        |> update(:new_folders, &unheld(&1, socket.assigns.path, listing))

      {:error, reason} ->
        socket
        |> assign(:listing, nil)
        |> assign(:loading, false)
        |> put_flash(:error, Ops.error_message(reason))
    end
  end

  # What the page shows of `file/offers`, and nothing more: the offers
  # waiting, the receipts with their senders, the offers sent. A failed
  # read says so rather than showing an empty inbox.
  defp load_offers(socket) do
    case Ops.call_tool(socket, "file/offers") do
      {:ok, %{inbox: inbox, outbox: outbox, receipts: receipts}} ->
        senders = Map.new(inbox, &{&1.offer_id, &1.sender})
        receipts = Enum.map(receipts, &Map.put(&1, :sender, Map.get(senders, &1.offer_id)))
        waiting = awaiting(inbox)
        sent = by_offer(outbox)

        people =
          (Enum.map(waiting, & &1.sender) ++
             Enum.map(receipts, & &1.sender) ++ Enum.map(sent, & &1.recipient))
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Map.new(&{&1, People.label(&1, socket.assigns.context)})

        socket
        |> assign(:offers, %{awaiting: waiting, receipts: receipts, sent: sent})
        |> assign(:people, people)

      {:error, reason} ->
        Logger.debug("[PrismWeb.FilesLive] offers not read: #{inspect(reason)}")
        assign(socket, :offers, :error)
    end
  end

  # ---- links ----------------------------------------------------------------

  defp folder_href(route, ""), do: PrismWeb.Focus.path(route, "/files")

  defp folder_href(route, path),
    do: PrismWeb.Focus.path(route, "/files?" <> URI.encode_query(%{"p" => path}))

  defp download_href(route, path) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    PrismWeb.Focus.path(route, "/files/download/" <> encoded)
  end

  defp child(path, name), do: Enum.join(Enum.reject([path, name], &(&1 == "")), "/")

  defp parent(path), do: path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

  # A held folder the listing shows is stored now, and the page lets it
  # go: a child listed under the folder in view, or that folder itself
  # once anything is in it.
  defp unheld(held, path, %{entries: entries}) do
    listed = MapSet.new(entries, &child(path, &1.name))

    MapSet.reject(held, fn folder ->
      MapSet.member?(listed, folder) or (folder == path and entries != [])
    end)
  end

  # The folder's entries with the new folders the page holds under it,
  # directories first, each by name, as the listing orders them.
  defp entries(%{entries: entries}, path, new_folders) do
    listed = MapSet.new(entries, & &1.name)

    held =
      for folder <- new_folders,
          parent(folder) == path,
          name = Path.basename(folder),
          not MapSet.member?(listed, name),
          do: %{name: name, kind: :dir, size: nil, held: true}

    Enum.sort_by(entries ++ held, &{&1.kind != :dir, &1.name})
  end

  # The raster types a browser draws and never runs, told by their first
  # bytes rather than the file's name; SVG, which can carry script, is
  # downloaded like any other file.
  defp picture(%{encoding: "base64", content: content}) do
    case Base.decode64(binary_part(content, 0, min(byte_size(content), 16))) do
      {:ok, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>} -> "image/png"
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> "image/jpeg"
      {:ok, <<"GIF8", v, "a", _::binary>>} when v in [?7, ?9] -> "image/gif"
      {:ok, <<"RIFF", _size::binary-size(4), "WEBP", _::binary>>} -> "image/webp"
      _other -> nil
    end
  end

  defp picture(_file), do: nil

  # The breadcrumb: each folder on the way, with the path it opens.
  defp crumbs(""), do: []

  defp crumbs(path) do
    path
    |> String.split("/")
    |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
    |> Enum.map(fn segments -> {List.last(segments), Enum.join(segments, "/")} end)
  end

  defp tier_label(:open), do: "open"
  defp tier_label(:shaped), do: "shaped"
  defp tier_label(:read), do: "read-only"
  defp tier_label(_), do: nil

  defp tier_class(:open), do: "bg-emerald-900/50 text-emerald-300"
  defp tier_class(:shaped), do: "bg-amber-900/50 text-amber-300"
  defp tier_class(:read), do: "bg-gray-800 text-gray-400"
  defp tier_class(_), do: "bg-gray-800 text-gray-400"

  defp tier_hint(:shaped, "components" <> _),
    do:
      "A shaped folder: files live inside a component's version directory and are edited " <>
        "in place. Create, pull or reset a component from the Components page."

  defp tier_hint(:shaped, "aqua" <> _),
    do:
      "A shaped folder: the soul, its roles and its scrolls, edited in place. Create, " <>
        "disable or reset them from the AQUA page."

  defp tier_hint(:read, "notes" <> _),
    do: "Kept out of threads — managed on the Notes surface."

  defp tier_hint(:read, "threads" <> _),
    do: "Chat attachments — managed from the threads they belong to."

  defp tier_hint(_tier, _path), do: nil

  defp size_label(nil), do: ""
  defp size_label(bytes), do: format_bytes(bytes)

  defp writable?(nil), do: false
  defp writable?(%{tier: tier}), do: tier in [:open, :shaped]

  defp count([_one], noun), do: "1 #{noun}"
  defp count(list, noun), do: "#{length(list)} #{noun}s"

  defp person(people, user_id), do: Map.get(people, user_id) || "someone"

  defp sent_status("offered"), do: "waiting"
  defp sent_status(status), do: status

  defp upload_error(:too_large), do: "too large"
  defp upload_error(:too_many_files), do: "too many files"
  defp upload_error(other), do: to_string(other)

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :crumbs, crumbs(assigns.path))

    ~H"""
    <div class="space-y-6" id="files-page">
      <.page_header title="Files" />

      <nav id="files-crumbs" class="flex items-center gap-1 text-sm text-gray-400 flex-wrap">
        <button
          type="button"
          phx-click="navigate"
          phx-value-path=""
          class="hover:text-white"
        >
          athanor
        </button>
        <span :for={{name, path} <- @crumbs} class="flex items-center gap-1">
          <span class="text-gray-600">/</span>
          <button type="button" phx-click="navigate" phx-value-path={path} class="hover:text-white">
            {name}
          </button>
        </span>
        <span
          :if={@listing && @listing.tier}
          class={"ml-2 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium #{tier_class(@listing.tier)}"}
        >
          {tier_label(@listing.tier)}
        </span>
      </nav>

      <p :if={@listing && tier_hint(@listing.tier, @path)} class="text-xs text-gray-500">
        {tier_hint(@listing.tier, @path)}
      </p>

      <div
        :if={MapSet.size(@selected) > 0}
        id="files-selection"
        class="flex flex-wrap items-center gap-3 text-sm text-gray-300"
      >
        <span>{MapSet.size(@selected)} selected</span>
        <.button id="files-send-copy" size="sm" phx-click="open_picker">Send a copy</.button>
        <.button variant="ghost" size="sm" phx-click="clear_selection">Clear</.button>
      </div>

      <.card :if={@picker}>
        <div id="send-copy" class="space-y-3">
          <p class="text-sm text-gray-300">
            Send a copy of {count(MapSet.to_list(@selected), "file")} to someone you share a thread with. The copy is taken now: later edits do not follow it, and nothing lands until they accept it.
          </p>
          <p :if={@picker == :error} class="text-sm text-red-300">
            Who you share a thread with could not be read. Try again.
          </p>
          <p :if={@picker == []} class="text-sm text-gray-500">
            You share no thread with anyone yet.
          </p>
          <form
            :if={is_list(@picker) and @picker != []}
            id="send-copy-form"
            phx-submit="send_copy"
            class="space-y-2"
          >
            <label
              :for={person <- @picker}
              class="flex items-center gap-2 text-sm text-gray-200"
            >
              <input type="radio" name="to" value={person.user_id} />
              <span>{person.label}</span>
              <span
                :if={is_binary(person.email) and person.email != person.label}
                class="text-xs text-gray-500"
              >
                {person.email}
              </span>
            </label>
            <div class="flex gap-2">
              <.button type="submit" size="sm">Send</.button>
              <.button variant="ghost" size="sm" phx-click="close_picker">Cancel</.button>
            </div>
          </form>
          <.button
            :if={not is_list(@picker) or @picker == []}
            variant="ghost"
            size="sm"
            phx-click="close_picker"
          >
            Close
          </.button>
        </div>
      </.card>

      <.card :if={@relocating}>
        <form id="files-move" phx-submit="move" class="space-y-2">
          <label :if={@relocating.mode == "rename"} class="block text-sm text-gray-300">
            Rename <span class="font-mono">{@relocating.path}</span>
            to
            <input
              type="text"
              name="name"
              value={Path.basename(@relocating.path)}
              class="mt-1 block w-full rounded bg-gray-800 border border-gray-700 px-2 py-1 font-mono text-xs text-white"
            />
          </label>
          <label :if={@relocating.mode == "move"} class="block text-sm text-gray-300">
            Move <span class="font-mono">{@relocating.path}</span>
            into the folder
            <input
              type="text"
              name="folder"
              value={parent(@relocating.path)}
              class="mt-1 block w-full rounded bg-gray-800 border border-gray-700 px-2 py-1 font-mono text-xs text-white"
            />
          </label>
          <div class="flex gap-2">
            <.button type="submit" size="sm">
              {if @relocating.mode == "rename", do: "Rename", else: "Move"}
            </.button>
            <.button type="button" variant="ghost" size="sm" phx-click="cancel_relocate">
              Cancel
            </.button>
          </div>
        </form>
      </.card>

      <div class="grid gap-6 lg:grid-cols-5">
        <.card class={if @open, do: "lg:col-span-2", else: "lg:col-span-5"}>
          <div :if={@path != "" and writable?(@listing)} class="mb-3 space-y-2">
            <.button
              :if={is_nil(@naming)}
              id="files-new-folder"
              variant="ghost"
              size="sm"
              phx-click="new_folder"
            >
              New folder
            </.button>
            <form
              :if={@naming == :folder}
              id="files-folder-form"
              phx-submit="create_folder"
              class="flex flex-wrap items-center gap-2"
            >
              <input
                type="text"
                name="name"
                aria-label="The new folder's name"
                class="min-w-0 flex-1 rounded bg-gray-800 border border-gray-700 px-2 py-1 font-mono text-xs text-white"
              />
              <.button type="submit" size="sm">Create</.button>
              <.button type="button" variant="ghost" size="sm" phx-click="cancel_new_folder">
                Cancel
              </.button>
            </form>
          </div>

          <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>

          <div
            :if={!@loading && @listing && entries(@listing, @path, @new_folders) == []}
            class="py-8"
          >
            <.empty_state message="Nothing here yet" />
          </div>

          <table
            :if={!@loading && @listing && entries(@listing, @path, @new_folders) != []}
            id="files-entries"
            class="min-w-full"
          >
            <tbody class="divide-y divide-gray-800/50">
              <tr
                :for={entry <- entries(@listing, @path, @new_folders)}
                class="hover:bg-gray-800/30"
              >
                <td :if={in_data?(@path)} class="w-6 pl-3 py-2">
                  <input
                    :if={entry.kind == :file}
                    type="checkbox"
                    phx-click="toggle_select"
                    phx-value-path={child(@path, entry.name)}
                    checked={MapSet.member?(@selected, child(@path, entry.name))}
                    aria-label={"Pick #{entry.name}"}
                    class="rounded border-gray-600 bg-gray-800"
                  />
                </td>
                <td class="px-3 py-2 text-sm">
                  <button
                    :if={entry.kind == :dir}
                    type="button"
                    phx-click="navigate"
                    phx-value-path={child(@path, entry.name)}
                    class="flex items-center gap-2 text-gray-200 hover:text-white"
                  >
                    <.icon name="folder" class="h-4 w-4 text-gray-500" />
                    <span class="font-mono">{entry.name}/</span>
                  </button>
                  <button
                    :if={entry.kind == :file}
                    type="button"
                    phx-click="open"
                    phx-value-path={child(@path, entry.name)}
                    class="flex items-center gap-2 text-gray-300 hover:text-white"
                  >
                    <.icon name="document" class="h-4 w-4 text-gray-600" />
                    <span class="font-mono">{entry.name}</span>
                  </button>
                </td>
                <td class="px-3 py-2 text-xs text-gray-500 text-right whitespace-nowrap">
                  {size_label(entry.size)}
                </td>
                <td class="px-3 py-2 text-right whitespace-nowrap">
                  <a
                    :if={entry.kind == :file}
                    href={download_href(@athanor_route, child(@path, entry.name))}
                    class="text-xs text-blue-400 hover:text-blue-300 mr-2"
                  >
                    Download
                  </a>
                  <button
                    :if={@path != "" and writable?(@listing)}
                    type="button"
                    phx-click="relocate"
                    phx-value-path={child(@path, entry.name)}
                    phx-value-mode="rename"
                    class="text-xs text-gray-500 hover:text-white mr-2"
                  >
                    Rename
                  </button>
                  <button
                    :if={@path != "" and writable?(@listing) and not Map.get(entry, :held, false)}
                    type="button"
                    phx-click="relocate"
                    phx-value-path={child(@path, entry.name)}
                    phx-value-mode="move"
                    class="text-xs text-gray-500 hover:text-white mr-2"
                  >
                    Move
                  </button>
                  <button
                    :if={@path != "" and writable?(@listing)}
                    type="button"
                    phx-click="delete"
                    phx-value-path={child(@path, entry.name)}
                    data-confirm={"Delete #{child(@path, entry.name)}?"}
                    class="text-xs text-gray-500 hover:text-red-300"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={@listing && @listing.truncated} class="px-3 py-2 text-xs text-gray-500">
            Only the first entries are shown.
          </p>

          <form
            :if={@path != "" and writable?(@listing)}
            id="files-upload"
            phx-submit="upload"
            phx-change="validate"
            class="mt-4 border-t border-gray-800 pt-4 space-y-2"
          >
            <label class="block text-xs text-gray-500 uppercase">Upload into {@path}/</label>
            <.live_file_input upload={@uploads.files} class="text-sm text-gray-400" />
            <div :for={entry <- @uploads.files.entries} class="text-xs text-gray-400 flex gap-2">
              <span class="font-mono">{entry.client_name}</span>
              <span :for={err <- upload_errors(@uploads.files, entry)} class="text-red-400">
                {upload_error(err)}
              </span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-gray-500 hover:text-gray-300"
              >
                ×
              </button>
            </div>
            <.button type="submit" variant="ghost" class="text-xs px-2 py-0.5">Upload</.button>
          </form>
        </.card>

        <.card :if={@open} class="lg:col-span-3">
          <div id="files-open" class="space-y-3">
            <div class="flex items-center justify-between gap-2">
              <span class="font-mono text-sm text-gray-200 truncate">{@open.path}</span>
              <div class="flex items-center gap-1 shrink-0">
                <span class="text-xs text-gray-500">{size_label(@open.size)}</span>
                <a
                  href={download_href(@athanor_route, @open.path)}
                  class="rounded px-2 py-1 text-[11px] text-blue-400 hover:bg-gray-800 hover:text-blue-300"
                >
                  Download
                </a>
                <.button
                  :if={@open.encoding == "utf8" and !@editing and writable?(@listing)}
                  variant="ghost"
                  class="text-xs px-2 py-0.5"
                  phx-click="edit"
                >
                  Edit
                </.button>
                <button
                  type="button"
                  phx-click="close"
                  class="text-gray-500 hover:text-gray-300 px-1"
                  aria-label="Close"
                >
                  ×
                </button>
              </div>
            </div>

            <form :if={@editing} id="files-editor" phx-submit="save" class="space-y-2">
              <textarea
                name="content"
                rows="24"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-4 py-2 font-mono text-xs text-white focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              >{@open.content}</textarea>
              <div class="flex gap-2">
                <.button type="submit" class="text-xs px-2 py-0.5">Save</.button>
                <.button
                  type="button"
                  variant="ghost"
                  class="text-xs px-2 py-0.5"
                  phx-click="cancel_edit"
                >
                  Cancel
                </.button>
              </div>
            </form>

            <pre
              :if={!@editing and @open.encoding == "utf8"}
              class="whitespace-pre-wrap break-words font-mono text-xs text-gray-300 bg-gray-950/60 rounded p-3 max-h-[70vh] overflow-auto"
            >{@open.content}</pre>

            <img
              :if={@open.picture}
              id="files-picture"
              src={"data:#{@open.picture};base64,#{@open.content}"}
              alt={@open.path}
              class="max-h-[70vh] max-w-full rounded"
            />

            <p
              :if={@open.encoding == "base64" and is_nil(@open.picture)}
              class="text-xs text-gray-500"
            >
              Binary content — download it to open.
            </p>
          </div>
        </.card>
      </div>

      <.card>
        <div id="files-offers" class="space-y-5">
          <section class="space-y-3">
            <div>
              <h2 class="text-sm font-medium text-gray-200">Inbox</h2>
              <p class="text-xs text-gray-500">
                Copies people sent you. Nothing lands in this athanor until you accept it.
              </p>
            </div>

            <p :if={is_nil(@offers)} class="text-sm text-gray-500">Loading...</p>
            <p :if={@offers == :error} class="text-sm text-red-300">
              Your offers could not be read.
            </p>
            <p
              :if={is_map(@offers) and @offers.awaiting == [] and @offers.receipts == []}
              class="text-sm text-gray-500"
            >
              Nothing is waiting for you.
            </p>

            <div
              :for={offer <- if(is_map(@offers), do: @offers.awaiting, else: [])}
              id={"offer-#{offer.offer_id}"}
              class="space-y-2 rounded-lg border border-gray-800 p-3"
            >
              <div class="flex flex-wrap items-center justify-between gap-2 text-sm">
                <span class="text-gray-200">From {person(@people, offer.sender)}</span>
                <span class="text-xs text-gray-500">
                  until {format_time(offer.expires_at, :datetime)}
                </span>
              </div>
              <ul class="space-y-0.5 text-xs text-gray-400">
                <li :for={file <- offer.files} class="flex justify-between gap-2">
                  <span class="font-mono">{file.filename}</span>
                  <span>{size_label(file.size)}</span>
                </li>
              </ul>
              <div class="flex flex-wrap items-center gap-2">
                <form
                  id={"accept-#{offer.offer_id}"}
                  phx-submit="accept"
                  class="flex flex-1 flex-wrap items-center gap-2"
                >
                  <input type="hidden" name="offer_id" value={offer.offer_id} />
                  <input
                    type="text"
                    name="folder"
                    value={offer.folder}
                    aria-label="The folder under data/ to accept into"
                    class="min-w-0 flex-1 rounded bg-gray-800 border border-gray-700 px-2 py-1 font-mono text-xs text-white"
                  />
                  <.button type="submit" size="sm">Accept</.button>
                </form>
                <.button
                  variant="ghost"
                  size="sm"
                  phx-click="decline"
                  phx-value-offer_id={offer.offer_id}
                >
                  Decline
                </.button>
              </div>
            </div>

            <ul
              :if={is_map(@offers) and @offers.receipts != []}
              class="space-y-1 text-sm text-gray-300"
            >
              <li :for={receipt <- @offers.receipts} data-receipt={receipt.offer_id}>
                <span class="font-mono">{receipt.filename}</span>
                from {person(@people, receipt.sender)}
                <span :if={receipt.status == "failed"} class="text-red-300">
                  could not be delivered. Ask them to send it again.
                </span>
                <span :if={receipt.status != "failed"} class="text-gray-500">
                  is still landing: it waits for space in this athanor, or for the next retry.
                </span>
              </li>
            </ul>
          </section>

          <section :if={is_map(@offers)} class="space-y-3">
            <h2 class="text-sm font-medium text-gray-200">Sent from this athanor</h2>
            <p :if={@offers.sent == []} class="text-sm text-gray-500">
              You have sent no copies from this athanor.
            </p>
            <div
              :for={offer <- @offers.sent}
              id={"sent-#{offer.offer_id}"}
              class="space-y-2 rounded-lg border border-gray-800 p-3"
            >
              <div class="flex flex-wrap items-center justify-between gap-2 text-sm">
                <span class="text-gray-200">To {person(@people, offer.recipient)}</span>
                <span class="text-xs text-gray-400">{sent_status(offer.status)}</span>
              </div>
              <ul class="space-y-0.5 text-xs text-gray-400">
                <li :for={file <- offer.files} class="flex justify-between gap-2">
                  <span class="font-mono">{file.filename}</span>
                  <span>{size_label(file.size)}</span>
                </li>
              </ul>
              <.button
                :if={offer.status == "offered"}
                variant="ghost"
                size="sm"
                phx-click="withdraw"
                phx-value-offer_id={offer.offer_id}
              >
                Withdraw
              </.button>
            </div>
          </section>
        </div>
      </.card>
    </div>
    """
  end
end
