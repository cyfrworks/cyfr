# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConversationLive do
  @moduledoc """
  The athanor's chat — where `/a/<athanor>` lands.

  The page is the list of the estate's threads and one open thread beside
  it. The thread itself is `PrismWeb.ConversationPaneLive`, a nested
  LiveView with a mailbox and a focused context of its own: the tape, the
  composer, the cards. This page owns what is the page's — which thread is
  open (`?c=<conversation_id>`; without it the most recent one, or a fresh
  one started by the first message), the list and what is followed, the
  say-aloud picker, and the athanor's own notifications. Two members with
  the same conversation open see the same stream; a card one of them
  decides resolves on both screens.
  """

  use PrismWeb, :live_view

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    ctx = socket.assigns[:context]

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:active_nav, "chat")
      |> assign(:conversations, [])
      |> assign(:followed, MapSet.new())
      |> assign(:aloud_for, nil)
      |> assign(:aloud_targets, [])
      |> assign(:aloud_estate, nil)
      |> assign(:aloud_topics, [])
      |> assign(:conversation, nil)

    if connected?(socket) and ctx do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(ctx.athanor_id))
    end

    {:ok, socket}
  end

  # The athanor row as it is now — after a settings change or a provisioning retry.
  defp reload_athanor(socket) do
    case Sanctum.Tenancy.Athanors.get(socket.assigns.context.athanor_id) do
      {:ok, athanor} -> assign(socket, :athanor, athanor)
      _ -> socket
    end
  end

  defp provisioning_error(athanor) do
    case Sanctum.Tenancy.Athanors.settings(athanor)["provisioning_error"] do
      %{} = error -> error
      _ -> nil
    end
  end

  # `detail` is `inspect/1` of whatever failed — a list of refs, a reason —
  # shown short; the log has the whole of it.
  defp provisioning_detail(athanor) do
    case provisioning_error(athanor) do
      %{"detail" => detail} when is_binary(detail) ->
        if String.length(detail) > 120, do: String.slice(detail, 0, 120) <> "…", else: detail

      _ ->
        ""
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      ctx = socket.assigns.context
      conversations = Conversations.list(ctx)

      target =
        case params["c"] do
          id when is_binary(id) and id != "" -> Enum.find(conversations, &(&1.id == id))
          _ -> List.first(conversations)
        end

      {:noreply,
       socket
       |> assign(:conversations, conversations)
       |> refresh_followed()
       |> select(target)}
    else
      {:noreply, socket}
    end
  end

  # The list follows the open thread's rows (titles, last activity), so the
  # page listens on that thread too — for the message events alone; the
  # pane applies the rest in its own process.
  defp select(socket, target) do
    socket = unsubscribe_current(socket)
    if target, do: ConversationRunner.subscribe(target.id, target.athanor_id)
    assign(socket, :conversation, target)
  end

  defp unsubscribe_current(
         %{assigns: %{conversation: %{id: id, athanor_id: athanor_id}}} = socket
       ) do
    Phoenix.PubSub.unsubscribe(Emissary.PubSub, ConversationRunner.topic(id, athanor_id))
    socket
  end

  defp unsubscribe_current(socket), do: socket

  # ============================================================================
  # Events
  # ============================================================================

  # A seeding that failed is retried by any member; the row says how it went.
  @impl true
  def handle_event("provision", _params, socket) do
    case call_tool(socket, "athanor/provision", %{}) do
      {:ok, _} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:info, "Set up — AQUA is ready.")}

      {:error, reason} ->
        # error_message/1, not interpolation: the registry answers with
        # tuple reasons ({:tool_auth_required, _}, {:timeout, _}, …) and
        # interpolating one crashes the LiveView mid-render.
        {:noreply,
         socket
         |> reload_athanor()
         |> put_flash(:error, "Still not set up: #{error_message(reason)}")}
    end
  end

  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_patch(socket, to: chat_path(socket, nil))}
  end

  def handle_event("open_conversation", %{"id" => id}, socket) do
    # Deliberately does NOT follow: reading a thread is not joining it.
    {:noreply, push_patch(socket, to: chat_path(socket, id))}
  end

  # Saying one of your own private lines out loud: pick an estate you
  # belong to, then one of its topics. The rules (author-only — or your own
  # assistant's line in your own athanor — membership on both sides,
  # byte-copied attachments) are `Aqua.Aloud`'s — this UI drives the same
  # `conversation.aloud` verb a headless client has.
  def handle_event("aloud_open", %{"id" => msg_id}, socket) do
    # Every active estate the person belongs to except this one — the
    # verb's own domain (membership both sides), so a DM or your own
    # athanor is as much a target as a team room. DMs are labeled.
    targets =
      case call_tool(socket, "athanor/list", %{}) do
        {:ok, %{athanors: athanors}} ->
          Enum.filter(
            athanors,
            &(&1[:status] == "active" and &1[:id] != socket.assigns.context.athanor_id)
          )

        _ ->
          []
      end

    {:noreply,
     socket
     |> assign(:aloud_for, msg_id)
     |> assign(:aloud_targets, targets)
     |> assign(:aloud_estate, nil)
     |> assign(:aloud_topics, [])}
  end

  def handle_event("aloud_pick_estate", %{"athanor" => athanor_id}, socket) do
    # `focus/2` is the audited narrowing entry — membership checked, an
    # archived estate refused — and the read lists that estate's topics.
    case Sanctum.Context.focus(socket.assigns.context, athanor_id) do
      {:ok, focused} ->
        {:noreply,
         socket
         |> assign(:aloud_estate, athanor_id)
         |> assign(:aloud_topics, Conversations.list(focused))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "You are not a member of that estate.")}
    end
  end

  def handle_event("aloud_post", %{"conversation" => topic_id}, socket) do
    %{conversation: conv, aloud_for: msg_id, aloud_estate: estate} = socket.assigns

    result =
      call_tool(socket, "conversation/aloud", %{
        "conversation" => conv.id,
        "message_ids" => [msg_id],
        "target_athanor" => estate,
        "target_conversation" => topic_id
      })

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:aloud_for, nil)
         |> put_flash(:info, "Said aloud — a copy is on that thread, attributed to you.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not say it aloud: #{error_message(reason)}")}
    end
  end

  def handle_event("aloud_cancel", _params, socket) do
    {:noreply, assign(socket, :aloud_for, nil)}
  end

  def handle_event("follow_topic", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    case Arca.TopicSubscriptionStorage.follow(ctx, id, ctx.user_id) do
      :ok -> {:noreply, refresh_followed(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not follow — try again.")}
    end
  end

  def handle_event("unfollow_topic", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    case Arca.TopicSubscriptionStorage.unfollow(ctx, id, ctx.user_id) do
      :ok -> {:noreply, refresh_followed(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unfollow — try again.")}
    end
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    ctx = socket.assigns.context

    # The turn may be running in a thread this tab is not looking at: the
    # runner is the fact, not what this socket happens to be rendering.
    # Check-then-act across a process boundary: a turn that starts in the
    # window has its conversation deleted from under it — accepted, because
    # the runner degrades cleanly (its next append re-fetches and gets
    # :not_found), and serializing would mean starting a runner just to
    # delete its conversation.
    if Aqua.ConversationRunner.turn_running?(ctx, id) do
      {:noreply, put_flash(socket, :error, "Stop the running turn before deleting.")}
    else
      case Conversations.delete(ctx, id) do
        :ok ->
          current = socket.assigns.conversation && socket.assigns.conversation.id

          if current == id do
            {:noreply, push_patch(socket, to: chat_path(socket, nil))}
          else
            {:noreply, assign(socket, :conversations, Conversations.list(ctx))}
          end

        {:error, reason} ->
          # A failed delete leaves the row listed; saying nothing made the
          # button look broken.
          {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
      end
    end
  end

  # ============================================================================
  # PubSub fan-in — the list, and what the pane tells the page
  # ============================================================================

  @impl true
  def handle_info(
        {:conversation, id, {:message, _row}},
        %{assigns: %{conversation: %{id: id}}} = socket
      ) do
    {:noreply, refresh_list(socket)}
  end

  def handle_info({:conversation, _id, _event}, socket), do: {:noreply, socket}

  # The pane's first message created the thread: the URL is this page's.
  def handle_info({:pane, _pane, {:opened, conv}}, socket) do
    {:noreply,
     socket
     |> refresh_list()
     |> push_patch(to: chat_path(socket, conv.id))}
  end

  # A line the pane offers to say aloud: the picker is this page's.
  def handle_info({:pane, _pane, {:aloud_open, msg_id}}, socket) do
    handle_event("aloud_open", %{"id" => msg_id}, socket)
  end

  # A rename or a settings change re-reads the row; an archive closes the
  # page — the runner behind it has already stopped.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    socket = reload_athanor(socket)

    case socket.assigns.athanor do
      %{status: "archived"} ->
        {:noreply,
         socket
         |> put_flash(:error, "This athanor has been archived.")
         |> redirect(to: "/")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp refresh_list(socket) do
    socket
    |> assign(:conversations, Conversations.list(socket.assigns.context))
    |> refresh_followed()
  end

  # Which of the estate's topics are in this person's sidebar. The list
  # itself is every topic — following decides emphasis and notification,
  # never visibility, so this read failing costs a dimmed list and nothing
  # more.
  defp refresh_followed(socket) do
    ctx = socket.assigns.context
    assign(socket, :followed, Arca.TopicSubscriptionStorage.followed(ctx, ctx.user_id))
  end

  defp followed?(followed, %{id: id}), do: MapSet.member?(followed, id)

  attr :conv, :map, required: true
  attr :current, :any, default: nil
  attr :followed, :boolean, required: true

  # One topic in the sidebar. Follow/unfollow is a word, not a glyph — the
  # action must read as what it does. Following decides emphasis and
  # notification, never access: every row opens on a click.
  defp topic_row(assigns) do
    ~H"""
    <li
      id={"conv-" <> @conv.id}
      class={[
        "group flex items-start gap-2 px-3 py-2 text-xs cursor-pointer hover:bg-gray-800/50",
        if(@current && @conv.id == @current.id, do: "bg-gray-800/80", else: "")
      ]}
      phx-click={
        JS.push("open_conversation", value: %{id: @conv.id})
        |> JS.add_class("max-md:hidden", to: "#conversation-list")
      }
    >
      <div class="flex-1 min-w-0">
        <p class={["truncate", if(@followed, do: "text-gray-200", else: "text-gray-400")]}>
          {@conv.title}
        </p>
        <p class="text-[10px] text-gray-600 mt-0.5">
          {Calendar.strftime(@conv.last_message_at || @conv.inserted_at, "%b %d %H:%M")}
          <span :if={@conv.execution_id} class="ml-1 text-blue-400">● running</span>
        </p>
      </div>
      <button
        type="button"
        phx-click={if @followed, do: "unfollow_topic", else: "follow_topic"}
        phx-value-id={@conv.id}
        class="opacity-0 group-hover:opacity-100 text-[10px] text-gray-500 hover:text-gray-200 shrink-0"
      >
        {if @followed, do: "Unfollow", else: "Follow"}
      </button>
      <button
        type="button"
        phx-click="delete_conversation"
        phx-value-id={@conv.id}
        class="opacity-0 group-hover:opacity-100 text-gray-500 hover:text-red-400 shrink-0"
        data-confirm="Delete this conversation for everyone?"
        aria-label="Delete"
      >
        ×
      </button>
    </li>
    """
  end

  defp chat_path(socket, nil), do: PrismWeb.Focus.path(socket.assigns.athanor_route, "")

  defp chat_path(socket, id),
    do: PrismWeb.Focus.path(socket.assigns.athanor_route, "?c=" <> URI.encode_www_form(id))

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="conversation-root" class="flex h-full min-h-0">
      <!-- The athanor's threads: a column beside the chat, a panel over it on a phone -->
      <aside
        id="conversation-list"
        class="flex w-64 shrink-0 flex-col border-r border-gray-800 bg-gray-900/40 max-md:fixed max-md:inset-y-12 max-md:bottom-0 max-md:left-0 max-md:z-30 max-md:hidden max-md:bg-gray-900 max-md:shadow-xl md:flex"
      >
        <div class="flex items-center justify-between px-3 py-2 border-b border-gray-800">
          <span class="text-xs font-semibold uppercase tracking-wider text-gray-500">Chats</span>
          <div class="flex items-center gap-1">
            <button
              type="button"
              phx-click="new_conversation"
              class="rounded px-2 py-1 text-[11px] uppercase tracking-wider text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              title="Start a new conversation"
            >
              + New
            </button>
            <button
              type="button"
              phx-click={JS.add_class("max-md:hidden", to: "#conversation-list")}
              class="md:hidden rounded px-2 py-1 text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              aria-label="Close the list"
            >
              ×
            </button>
          </div>
        </div>
        <div :if={@conversations == []} class="px-3 py-4 text-xs text-gray-500">
          No conversations yet.
        </div>
        <%!-- Two lists, not one dimmed pile: what you follow, then the
              estate's other topics folded under a heading. Access is
              unchanged either way — every row opens on a click. --%>
        <% {following, other} = Enum.split_with(@conversations, &followed?(@followed, &1)) %>
        <div class="flex-1 overflow-y-auto">
          <ul :if={following != []} class="divide-y divide-gray-800/60">
            <.topic_row :for={conv <- following} conv={conv} current={@conversation} followed />
          </ul>
          <details :if={other != []} open={following == []} class="border-t border-gray-800">
            <summary class="px-3 py-1.5 text-[10px] uppercase tracking-wider text-gray-600 cursor-pointer hover:text-gray-400">
              Other topics ({length(other)})
            </summary>
            <ul class="divide-y divide-gray-800/60">
              <.topic_row
                :for={conv <- other}
                conv={conv}
                current={@conversation}
                followed={false}
              />
            </ul>
          </details>
        </div>
      </aside>

      <div class="flex flex-1 min-w-0 flex-col">
        <div
          :if={is_nil(@athanor.provisioned_at)}
          class="flex items-center justify-between gap-3 border-b border-amber-900/60 bg-amber-950/40 px-4 py-2 text-xs text-amber-200"
        >
          <span class="min-w-0 truncate">
            This athanor is still being set up
            <span :if={provisioning_error(@athanor)} class="text-amber-300/80">
              — last attempt failed at {provisioning_error(@athanor)["step"]}: {provisioning_detail(
                @athanor
              )}
            </span>
          </span>
          <button
            type="button"
            phx-click="provision"
            class="shrink-0 rounded px-2 py-1 text-[11px] uppercase tracking-wider bg-amber-800/60 text-amber-100 hover:bg-amber-700/80"
          >
            Retry
          </button>
        </div>

        <%!-- The open thread, as its own LiveView: a different thread is a
              different pane, mounted fresh under its own focused context. --%>
        {live_render(@socket, PrismWeb.ConversationPaneLive,
          id: "pane-" <> ((@conversation && @conversation.id) || "new"),
          session: %{
            "athanor_id" => @athanor.id,
            "conversation_id" => @conversation && @conversation.id,
            "ui_mode" => assigns[:ui_mode]
          }
        )}
      </div>

      <%!-- Say-aloud picker: which estate, then which of its topics. --%>
      <div
        :if={@aloud_for}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/70"
        phx-click="aloud_cancel"
      >
        <div
          class="w-full max-w-sm rounded-lg bg-gray-900 border border-gray-800 shadow-2xl p-4 space-y-3"
          phx-click-away="aloud_cancel"
        >
          <h3 class="text-sm font-medium text-gray-200">Say aloud</h3>
          <p class="text-[11px] text-gray-500">
            A copy of your line lands on an estate's thread, attributed to you.
            This conversation keeps the original.
          </p>

          <div :if={@aloud_targets == []} class="text-xs text-gray-500">
            You are not in any other estate yet — there is no room to say it in.
          </div>

          <div :if={@aloud_targets != []} class="space-y-1">
            <p class="text-[10px] uppercase tracking-wider text-gray-500">Estate</p>
            <button
              :for={t <- @aloud_targets}
              type="button"
              phx-click="aloud_pick_estate"
              phx-value-athanor={t[:id]}
              class={[
                "block w-full text-left rounded px-2 py-1 text-xs",
                if(@aloud_estate == t[:id],
                  do: "bg-gray-800 text-white",
                  else: "text-gray-300 hover:bg-gray-800/60"
                )
              ]}
            >
              {t[:name]}
              <span :if={t[:roster] == "frozen"} class="text-[10px] text-gray-500 ml-1">DM</span>
            </button>
          </div>

          <div :if={@aloud_estate} class="space-y-1">
            <p class="text-[10px] uppercase tracking-wider text-gray-500">Topic</p>
            <div :if={@aloud_topics == []} class="text-xs text-gray-500">
              That estate has no topics yet.
            </div>
            <button
              :for={topic <- @aloud_topics}
              type="button"
              phx-click="aloud_post"
              phx-value-conversation={topic.id}
              class="block w-full text-left rounded px-2 py-1 text-xs text-gray-300 hover:bg-gray-800/60"
            >
              {topic.title}
            </button>
          </div>

          <div class="flex justify-end">
            <button
              type="button"
              phx-click="aloud_cancel"
              class="rounded px-3 py-1 text-xs text-gray-400 hover:bg-gray-800"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
