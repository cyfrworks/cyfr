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
  rides the URL (`?p=data/reports`), so a location is a link.
  """

  use PrismWeb, :live_view

  require Logger

  alias PrismWeb.Ops

  @impl true
  def mount(_params, _session, socket) do
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
     |> allow_upload(:files,
       accept: :any,
       max_entries: 10,
       max_file_size: Arca.Files.max_write()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = params |> Map.get("p", "") |> String.trim("/")
    socket = socket |> assign(:path, path) |> assign(:open, nil) |> assign(:editing, false)

    if connected?(socket) do
      send(self(), :load)
      {:noreply, assign(socket, :loading, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load, socket), do: {:noreply, load(socket)}

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
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
        {:noreply, socket |> assign(:open, file) |> assign(:editing, false)}

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
    case Ops.call_tool(socket, "file/delete", %{"path" => path}) do
      {:ok, _} ->
        open = if match?(%{path: ^path}, socket.assigns.open), do: nil, else: socket.assigns.open

        {:noreply,
         socket
         |> assign(:open, open)
         |> assign(:editing, false)
         |> put_flash(:info, "Deleted #{path}")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Ops.error_message(reason))}
    end
  end

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

  # ---- data -----------------------------------------------------------------

  defp load(socket) do
    case Ops.call_tool(socket, "file/list", %{"path" => socket.assigns.path}) do
      {:ok, listing} ->
        socket |> assign(:listing, listing) |> assign(:loading, false)

      {:error, reason} ->
        socket
        |> assign(:listing, nil)
        |> assign(:loading, false)
        |> put_flash(:error, Ops.error_message(reason))
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

      <div class="grid gap-6 lg:grid-cols-5">
        <.card class={if @open, do: "lg:col-span-2", else: "lg:col-span-5"}>
          <div :if={@loading} class="py-8 text-center text-gray-500">Loading...</div>

          <div :if={!@loading && @listing && @listing.entries == []} class="py-8">
            <.empty_state message="Nothing here yet" />
          </div>

          <table
            :if={!@loading && @listing && @listing.entries != []}
            id="files-entries"
            class="min-w-full"
          >
            <tbody class="divide-y divide-gray-800/50">
              <tr :for={entry <- @listing.entries} class="hover:bg-gray-800/30">
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

            <p :if={@open.encoding == "base64"} class="text-xs text-gray-500">
              Binary content — download it to open.
            </p>
          </div>
        </.card>
      </div>
    </div>
    """
  end
end
