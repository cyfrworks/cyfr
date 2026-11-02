# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SharedThreadLive do
  @moduledoc """
  A shared thread, opened from the chat (`PrismWeb.ChatLive`, `?s=<thread>`)
  as a nested LiveView of its own: what its people said, with their
  names and files, a composer that posts words and files, and a header
  with the thread's people and invitations.

  Nothing runs in a shared thread: there is no agent to pick, no
  approval to decide, no grant and no follow — being in the thread is
  the follow. Every control goes through the gate's `shared_thread` tool
  (`PrismWeb.Ops.call_tool/3`), the read included, under the person's
  own seat: any of a thread's people renames it, adds someone by name,
  removes someone, withdraws an invitation, makes an invitation link to
  this CYFR naming the thread (`invitation.create`), archives it or
  leaves it. A pair is a thread of two that gains and loses no one, so
  its only control is leave.

  The pane listens on the person's own `Cyfr.Bus.shared_threads/1`: a
  message posted reads the messages after the last one shown; any other
  change reads the thread and its people again, and a thread the person
  no longer sits in, or that was archived, says so — the chat around the
  pane moves on (`PrismWeb.ChatLive`). A file opens through
  `/shared/:thread/attachments/:message_id/:filename`
  (`PrismWeb.SharedAttachmentController`), which checks the seat again.
  """

  use PrismWeb, :live_view

  require Logger

  alias PrismWeb.People

  # One page of messages, as the tool reads them.
  @page 500

  # The session's own, kept current by the guard; a shared thread is no
  # athanor's, so none is named here.
  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket) do
    thread_id = session["thread_id"]
    ctx = socket.assigns.context

    if connected?(socket),
      do: Cyfr.Bus.subscribe_global(Cyfr.Bus.shared_threads(ctx.user_id))

    limits = Sanctum.SharedThreads.limits()

    socket =
      socket
      |> assign(:thread_id, thread_id)
      |> assign(:thread, nil)
      |> assign(:gone, nil)
      |> assign(:people, [])
      |> assign(:names, %{})
      |> assign(:last_seq, 0)
      |> assign(:input, "")
      |> assign(:renaming?, false)
      |> assign(:invite_link, nil)
      |> stream_configure(:messages, dom_id: &("shared-m-" <> &1.id))
      |> stream(:messages, [])
      |> allow_upload(:files,
        accept: :any,
        max_entries: 10,
        max_file_size: limits.max_file_bytes,
        auto_upload: true
      )

    socket = if connected?(socket), do: socket |> load_thread() |> load_messages(), else: socket

    {:ok, socket, layout: false}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("update_input", %{"content" => content}, socket),
    do: {:noreply, assign(socket, :input, content)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("post", params, socket) do
    content = String.trim(params["content"] || "")

    case files(socket) do
      {:ok, []} when content == "" ->
        {:noreply, socket}

      {:ok, []} ->
        tool(socket, "shared_thread/post", %{"content" => content}, &sent/2)

      {:ok, files} ->
        args = %{"files" => files}
        args = if content == "", do: args, else: Map.put(args, "content", content)
        tool(socket, "shared_thread/attach", args, &sent/2)

      {:error, sentence} ->
        {:noreply, put_flash(socket, :error, sentence)}
    end
  end

  def handle_event("add", %{"person" => person}, socket) do
    case person_name(person) do
      {:ok, name} ->
        tool(socket, "shared_thread/add", %{"handle" => name}, fn socket, _added ->
          socket
          |> load_people()
          |> put_flash(
            :info,
            "Added. If they have never signed in here, their seat waits for their first sign-in."
          )
        end)

      {:error, sentence} ->
        {:noreply, put_flash(socket, :error, sentence)}
    end
  end

  def handle_event("remove", %{"user-id" => user_id}, socket) do
    tool(socket, "shared_thread/remove", %{"user_id" => user_id}, fn socket, _removed ->
      socket |> load_people() |> put_flash(:info, "Removed.")
    end)
  end

  def handle_event("withdraw", %{"identifier" => identifier}, socket) do
    tool(socket, "shared_thread/withdraw", %{"identifier" => identifier}, fn socket, _gone ->
      socket |> load_people() |> put_flash(:info, "Invitation withdrawn.")
    end)
  end

  def handle_event("invite_link", _params, socket) do
    args = %{"thread_id" => socket.assigns.thread_id}

    case call_tool(socket, "invitation/create", args) do
      {:ok, %{invitation_url: link}} ->
        {:noreply, assign(socket, :invite_link, link)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "No link was made: #{error_message(reason)}")}
    end
  end

  def handle_event("toggle_rename", _params, socket),
    do: {:noreply, update(socket, :renaming?, &(not &1))}

  def handle_event("rename", %{"title" => title}, socket) do
    tool(socket, "shared_thread/rename", %{"title" => title}, fn socket, thread ->
      socket |> assign(:thread, thread) |> assign(:renaming?, false)
    end)
  end

  def handle_event("archive", _params, socket) do
    tool(socket, "shared_thread/archive", %{}, fn socket, _archived -> socket end)
  end

  def handle_event("leave", _params, socket) do
    tool(socket, "shared_thread/leave", %{}, fn socket, _left -> socket end)
  end

  # The list beside the thread is the chat's drawer on a phone.
  def handle_event("toggle_rail", _params, socket) do
    if pid = socket.parent_pid, do: send(pid, {:pane, socket.id, :toggle_rail})
    {:noreply, socket}
  end

  # ============================================================================
  # The person's shared threads changed
  # ============================================================================

  @impl true
  def handle_info(
        %Cyfr.Bus.SharedThreadChanged{kind: :posted, thread_id: id},
        %{assigns: %{thread_id: id}} = socket
      ),
      do: {:noreply, load_messages(socket)}

  def handle_info(
        %Cyfr.Bus.SharedThreadChanged{kind: :changed, thread_id: id},
        %{assigns: %{thread_id: id}} = socket
      ),
      do: {:noreply, load_thread(socket)}

  def handle_info(%Cyfr.Bus.SharedThreadChanged{}, socket), do: {:noreply, socket}

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # ============================================================================
  # Reads, each through the tool under the person's seat
  # ============================================================================

  # The thread and its people. One the person no longer sits in answers as
  # a missing one; an archived one is shown as such, with nothing to post.
  defp load_thread(socket) do
    case call(socket, "shared_thread/get", %{}) do
      {:ok, %{status: "active"} = thread} ->
        socket |> assign(:thread, thread) |> assign(:gone, nil) |> load_people()

      {:ok, thread} ->
        socket |> assign(:thread, thread) |> assign(:gone, "This thread has been archived.")

      {:error, {:unavailable, _what}} ->
        put_flash(socket, :error, "This thread cannot be read just now. Try again shortly.")

      {:error, _missing} ->
        socket |> assign(:thread, nil) |> assign(:gone, "You are no longer in this thread.")
    end
  end

  defp load_people(socket) do
    case call(socket, "shared_thread/people", %{}) do
      {:ok, %{people: people}} ->
        names =
          Enum.reduce(people, socket.assigns.names, fn
            %{user_id: id, name: name}, names -> Map.put(names, id, name)
            _invited, names -> names
          end)

        socket |> assign(:people, people) |> assign(:names, names)

      {:error, _reason} ->
        socket
    end
  end

  # Every message after the last one shown, page by page.
  defp load_messages(%{assigns: %{gone: gone}} = socket) when is_binary(gone), do: socket

  defp load_messages(socket) do
    args = %{"after_seq" => socket.assigns.last_seq, "limit" => @page}

    case call(socket, "shared_thread/messages", args) do
      {:ok, %{messages: []}} ->
        socket

      {:ok, %{messages: messages}} ->
        socket =
          socket
          |> name_authors(messages)
          |> stream(:messages, messages)
          |> assign(:last_seq, List.last(messages).seq)

        if length(messages) >= @page,
          do: load_messages(socket),
          else: socket

      {:error, reason} ->
        Logger.warning("[SharedThreadLive] messages unread: #{inspect(reason)}")
        socket
    end
  end

  # A name for each author, once: people who left are still named.
  defp name_authors(socket, messages) do
    ctx = socket.assigns.context

    names =
      Enum.reduce(messages, socket.assigns.names, fn %{author: author}, names ->
        Map.put_new_lazy(names, author, fn -> People.label(author, ctx) end)
      end)

    assign(socket, :names, names)
  end

  defp call(socket, tool, args),
    do: call_tool(socket, tool, Map.put(args, "thread", socket.assigns.thread_id))

  # A control's call, and what the pane does when it answers.
  defp tool(socket, tool, args, done) do
    case call(socket, tool, args) do
      {:ok, result} -> {:noreply, done.(socket, result)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp sent(socket, _message), do: socket |> assign(:input, "") |> load_messages()

  defp files(socket) do
    files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        # arca:bypass-ok=D — Plug-managed upload tmp file.
        bytes = File.read!(path)

        {:ok,
         %{
           "filename" => entry.client_name,
           "media_type" => entry.client_type,
           "data" => Base.encode64(bytes)
         }}
      end)

    {:ok, files}
  rescue
    e ->
      Logger.warning(
        "[SharedThreadLive] reading uploads failed: #{Prima.LogFilter.exception_message(e)}"
      )

      {:error, "The files could not be read — nothing was sent."}
  end

  defp person_name(person) do
    name = person |> String.trim() |> String.trim_leading("@")

    if Prima.ComponentRef.valid_personal_slug?(name),
      do: {:ok, name},
      else:
        {:error,
         "A name is lowercase letters and digits joined by single hyphens, at most 39 characters."}
  end

  # ============================================================================
  # Render
  # ============================================================================

  defp title(%{kind: "pair", with: %{name: name}}), do: name
  defp title(%{title: title}) when is_binary(title), do: title
  defp title(_thread), do: "Thread"

  defp pair?(%{kind: "pair"}), do: true
  defp pair?(_thread), do: false

  defp attachment_path(thread_id, message_id, %{"stored_name" => stored}),
    do: "/shared/#{thread_id}/attachments/#{message_id}/#{URI.encode(stored)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="shared-thread" class="flex h-full min-h-0 flex-1 flex-col">
      <header
        id="shared-header"
        class="space-y-2 border-b border-gray-800 px-4 py-2"
        aria-label="Thread"
      >
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="toggle_rail"
            class="md:hidden rounded px-2 py-1 text-xs text-gray-400 hover:bg-gray-800"
          >
            Chats
          </button>
          <h2 id="shared-title" class="min-w-0 flex-1 truncate text-sm font-medium text-gray-200">
            {if @thread, do: title(@thread), else: "Thread"}
          </h2>
          <div :if={@thread != nil and is_nil(@gone)} class="flex shrink-0 items-center gap-1">
            <button
              :if={not pair?(@thread)}
              type="button"
              id="shared-rename"
              phx-click="toggle_rename"
              class="rounded px-2 py-1 text-xs text-gray-400 hover:bg-gray-800 hover:text-gray-200"
            >
              Rename
            </button>
            <button
              :if={not pair?(@thread)}
              type="button"
              id="shared-invite"
              phx-click="invite_link"
              class="rounded px-2 py-1 text-xs text-gray-400 hover:bg-gray-800 hover:text-gray-200"
            >
              Invitation link
            </button>
            <button
              :if={not pair?(@thread)}
              type="button"
              id="shared-archive"
              phx-click="archive"
              data-confirm="Archive this thread for everyone in it?"
              class="rounded px-2 py-1 text-xs text-gray-400 hover:bg-gray-800 hover:text-red-300"
            >
              Archive
            </button>
            <button
              type="button"
              id="shared-leave"
              phx-click="leave"
              data-confirm={
                if pair?(@thread),
                  do: "Leave? The thread of you two ends.",
                  else: "Leave this thread?"
              }
              class="rounded px-2 py-1 text-xs text-gray-400 hover:bg-gray-800 hover:text-red-300"
            >
              Leave
            </button>
          </div>
        </div>

        <form
          :if={@renaming? and @thread != nil and is_nil(@gone)}
          id="shared-rename-form"
          phx-submit="rename"
          class="flex gap-2"
        >
          <input
            type="text"
            name="title"
            value={@thread.title}
            required
            maxlength="200"
            aria-label="Title"
            class="flex-1 rounded border border-gray-700 bg-gray-950 px-2 py-1 text-xs text-white"
          />
          <button type="submit" class="rounded bg-blue-600 px-2 py-1 text-xs text-white">
            Save
          </button>
        </form>

        <p :if={@invite_link} id="shared-invite-link" class="text-xs text-gray-400">
          Give this link to the person you invite; it admits one person, once, for seven days:
          <span class="select-all break-all text-gray-200">{@invite_link}</span>
        </p>

        <ul :if={@people != []} id="shared-people" class="flex flex-wrap gap-1" aria-label="People">
          <li
            :for={person <- @people}
            class="flex items-center gap-1 rounded bg-gray-800/70 px-2 py-0.5 text-xs text-gray-300"
          >
            <%= if person.status == "invited" do %>
              <span class="truncate max-w-[14rem]">{person.identifier}</span>
              <span class="text-gray-500">invited</span>
              <button
                :if={not pair?(@thread)}
                type="button"
                phx-click="withdraw"
                phx-value-identifier={person.identifier}
                class="text-gray-500 hover:text-red-300"
              >
                Withdraw
              </button>
            <% else %>
              <span class="truncate max-w-[14rem]">
                {if person.user_id == @context.user_id, do: "You", else: person.name}
              </span>
              <button
                :if={not pair?(@thread) and person.user_id != @context.user_id}
                type="button"
                phx-click="remove"
                phx-value-user-id={person.user_id}
                data-confirm="Remove them from this thread?"
                class="text-gray-500 hover:text-red-300"
              >
                Remove
              </button>
            <% end %>
          </li>
        </ul>

        <form
          :if={@thread != nil and is_nil(@gone) and not pair?(@thread)}
          id="shared-add"
          phx-submit="add"
          class="flex gap-2"
        >
          <input
            type="text"
            name="person"
            placeholder="Add someone by name"
            aria-label="Add someone by name"
            class="flex-1 rounded border border-gray-700 bg-gray-950 px-2 py-1 text-xs text-white placeholder-gray-500"
          />
          <button type="submit" class="rounded bg-gray-700 px-2 py-1 text-xs text-gray-100">
            Add
          </button>
        </form>
      </header>

      <p :if={@gone} id="shared-gone" class="px-4 py-3 text-sm text-gray-400">{@gone}</p>

      <div
        id="shared-messages"
        phx-update="stream"
        class="flex-1 space-y-3 overflow-y-auto px-4 py-3"
        aria-live="polite"
      >
        <div :for={{dom_id, msg} <- @streams.messages} id={dom_id} class="text-sm">
          <p class="text-xs text-gray-500">
            <span class="font-medium text-gray-300">
              {if msg.author == @context.user_id,
                do: "You",
                else: Map.get(@names, msg.author, "Someone")}
            </span>
            <span>{Calendar.strftime(msg.inserted_at, "%b %d %H:%M")}</span>
          </p>
          <p :if={msg.content != ""} class="whitespace-pre-wrap text-gray-200">{msg.content}</p>
          <ul :if={msg.attachments != []} class="mt-1 flex flex-wrap gap-1">
            <li :for={ref <- msg.attachments}>
              <a
                href={attachment_path(@thread_id, msg.id, ref)}
                class="rounded bg-gray-800 px-2 py-0.5 text-xs text-blue-300 hover:text-blue-200"
              >
                {ref["filename"]}
              </a>
            </li>
          </ul>
        </div>
      </div>

      <form
        :if={@thread != nil and is_nil(@gone)}
        id="shared-composer"
        phx-submit="post"
        phx-change="validate"
        class="space-y-2 border-t border-gray-800 p-3"
      >
        <div :if={@uploads.files.entries != []} class="flex flex-wrap gap-1">
          <div
            :for={entry <- @uploads.files.entries}
            class="flex items-center gap-1 rounded bg-gray-800 px-2 py-0.5 text-xs"
          >
            <span class="max-w-[12rem] truncate text-gray-300">{entry.client_name}</span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="inline-flex min-h-6 min-w-6 items-center justify-center text-gray-500 hover:text-red-400"
              aria-label="Remove"
            >
              ×
            </button>
          </div>
        </div>
        <div class="flex items-end gap-2">
          <label
            class="cursor-pointer rounded-md border border-gray-700 bg-gray-800 px-2 py-2 text-sm text-gray-400 hover:bg-gray-700"
            title="Attach files"
          >
            📎 <.live_file_input upload={@uploads.files} class="hidden" />
          </label>
          <textarea
            id="shared-input"
            name="content"
            phx-change="update_input"
            rows="1"
            placeholder={"Write to " <> title(@thread)}
            class="max-h-40 flex-1 resize-none overflow-y-auto rounded-md border border-gray-700 bg-gray-950 px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none"
          >{@input}</textarea>
          <button
            type="submit"
            class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500"
          >
            Send
          </button>
        </div>
      </form>
    </div>
    """
  end
end
