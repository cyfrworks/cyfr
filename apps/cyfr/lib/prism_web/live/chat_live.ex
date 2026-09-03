# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatLive do
  @moduledoc """
  The chat — one zone across every estate the person belongs to, at
  `/chat`.

  The rail is the person's contact list: their own athanor, their DMs (the
  frozen pairs, shown by the other person's name), their groups and each
  group's topics — membership IS the list. Opening a row opens that thread
  in place as `PrismWeb.ConversationPaneLive`, a nested LiveView with a
  focused context of its own, so nothing here depends on which estate the
  session happens to default to. The workbench's switcher governs the
  workbench; this page governs itself through its address:
  `?a=<route>` names the estate, `?c=<conversation_id>` the thread (without
  it the estate's most recent, or a fresh one started by the first message).

  A DM opens from the rail: click a person you share an estate with and
  the frozen pair of the two of you is found or minted (`athanor.pair`) and
  selected here — the session's default athanor does not move.

  The page owns what is the page's: the selection, the lists and what is
  followed, the say-aloud picker, and the selected estate's own
  notifications. The pane owns the thread.
  """

  use PrismWeb, :live_view

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
  alias Phoenix.LiveView.JS
  alias Sanctum.Tenancy.Athanors

  @impl true
  def mount(_params, session, socket) do
    # The tray is the session's (`Prism.Tray`): opening an estate here is
    # looking at it, so its badge is read the same as focusing the bench.
    token = session[to_string(PrismWeb.SignInResponse.session_key())]

    {:ok,
     socket
     |> assign(:tray_key, token && Prism.Tray.session_hash(token))
     |> assign(:page_title, "Chat")
     |> assign(:active_nav, "chat")
     |> assign(:estates, [])
     |> assign(:people, [])
     |> assign(:focus, nil)
     |> assign(:conversations, [])
     |> assign(:followed, MapSet.new())
     |> assign(:conversation, nil)
     |> assign(:aloud_for, nil)
     |> assign(:aloud_targets, [])
     |> assign(:aloud_estate, nil)
     |> assign(:aloud_topics, [])
     |> assign(:notified, nil)}
  end

  @doc "The chat's address for an estate, and optionally one of its threads."
  @spec chat_path(String.t() | nil, String.t() | nil) :: String.t()
  def chat_path(route, conversation_id \\ nil) do
    query =
      [a: route, c: conversation_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    if query == [], do: "/chat", else: "/chat?" <> URI.encode_query(query)
  end

  # The address decides everything: which estate (a member's own default
  # without `a`), then which thread. The estate is entered through
  # `Context.focus/2` — membership checked, an archived one refused — and
  # that focused context is what the lists and the pane run under.
  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      ctx = socket.assigns.context

      case focus_on(ctx, params["a"]) do
        {:ok, focus, athanor} ->
          conversations = Conversations.list(focus)

          target =
            case params["c"] do
              id when is_binary(id) and id != "" -> Enum.find(conversations, &(&1.id == id))
              _ -> List.first(conversations)
            end

          if socket.assigns.tray_key, do: Prism.Tray.clear(socket.assigns.tray_key, athanor.id)

          {:noreply,
           socket
           |> subscribe_estate(athanor)
           |> assign(:focus, focus)
           |> assign(:athanor, athanor)
           |> assign(:athanor_route, Athanors.route_slug(athanor))
           |> assign(:conversations, conversations)
           |> refresh_followed()
           |> select(target)
           |> load_rail()}

        {:error, :no_estate} ->
          # No seat anywhere: nothing to open, and nothing to patch to.
          {:noreply,
           socket
           |> assign(:athanor, nil)
           |> assign(:focus, nil)
           |> assign(:conversation, nil)
           |> assign(:estates, [])
           |> assign(:people, [])}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "That estate cannot be opened (#{reason}).")
           |> push_navigate(to: chat_path(nil))}
      end
    else
      {:noreply, socket}
    end
  end

  # No estate named: the session's default, or — when that seat is gone —
  # the first estate the person still holds one in. Never a patch back to
  # the default, which is how a lost seat would loop.
  defp focus_on(ctx, route) when route in [nil, ""] do
    candidates =
      [ctx.athanor_id && Athanors.get(ctx.athanor_id)]
      |> Enum.flat_map(fn
        {:ok, %{status: "active"} = athanor} -> [athanor]
        _ -> []
      end)
      |> Kernel.++(Sanctum.Tenancy.list_athanors(ctx))

    Enum.find_value(candidates, {:error, :no_estate}, fn athanor ->
      case Sanctum.Context.focus(ctx, athanor) do
        {:ok, focus} -> {:ok, focus, athanor}
        {:error, _} -> nil
      end
    end)
  end

  defp focus_on(ctx, route) when is_binary(route) do
    with {:ok, athanor} <- Athanors.by_route_slug(route),
         {:ok, focus} <- Sanctum.Context.focus(ctx, athanor) do
      {:ok, focus, athanor}
    end
  end

  # The selected estate's own notifications (a rename, an archive); the
  # previous estate's are dropped with the selection.
  defp subscribe_estate(socket, athanor) do
    case socket.assigns.notified do
      ^athanor ->
        socket

      previous ->
        if previous,
          do: Phoenix.PubSub.unsubscribe(Emissary.PubSub, Sanctum.Notify.topic(previous.id))

        Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(athanor.id))
        assign(socket, :notified, athanor)
    end
  end

  # The rail follows the open thread's rows (titles, last activity), so the
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

  # The rail: every estate the person holds a seat in, each entered through
  # `Context.focus/2` for its own list, sorted own athanor, DMs, groups;
  # and the people they share an estate with, for a DM.
  defp load_rail(socket) do
    ctx = socket.assigns.context
    mine = personal_athanor(ctx)

    estates =
      for athanor <- Sanctum.Tenancy.list_athanors(ctx),
          {:ok, focus} <- [Sanctum.Context.focus(ctx, athanor)] do
        %{
          athanor: athanor,
          route: Athanors.route_slug(athanor),
          kind: estate_kind(athanor, mine),
          label: estate_label(athanor, mine, ctx),
          topics: Conversations.list(focus),
          followed: Arca.TopicSubscriptionStorage.followed(focus, ctx.user_id)
        }
      end
      |> Enum.sort_by(&{kind_rank(&1.kind), String.downcase(&1.label)})

    people =
      estates
      |> Enum.filter(&(&1.kind == :group))
      |> Enum.flat_map(fn %{athanor: athanor} -> members_of(athanor) end)
      |> Enum.reject(&(&1.user_id == ctx.user_id))
      |> Enum.uniq_by(& &1.user_id)
      |> Enum.sort_by(&String.downcase(&1.label))

    socket
    |> assign(:estates, estates)
    |> assign(:people, people)
  end

  defp personal_athanor(%{user_id: user_id}) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{personal_athanor_id: id}} -> id
      _ -> nil
    end
  end

  defp personal_athanor(_), do: nil

  defp estate_kind(%{id: id}, mine) when id == mine, do: :mine
  defp estate_kind(%{roster: "frozen"}, _mine), do: :dm
  defp estate_kind(_athanor, _mine), do: :group

  defp kind_rank(:mine), do: 0
  defp kind_rank(:dm), do: 1
  defp kind_rank(:group), do: 2

  # A DM is named by the other person, never by the pair estate's own name.
  defp estate_label(%{id: id}, mine, _ctx) when id == mine, do: "You"

  defp estate_label(%{roster: "frozen"} = athanor, _mine, ctx) do
    case Enum.find(members_of(athanor), &(&1.user_id != ctx.user_id)) do
      %{label: label} -> label
      nil -> athanor.name
    end
  end

  defp estate_label(athanor, _mine, _ctx), do: athanor.name

  defp members_of(athanor) do
    case Sanctum.Tenancy.Members.list_by_athanor(athanor.id) do
      {:ok, rows} ->
        for m <- rows, is_binary(m.user_id), m.status == "active" do
          %{user_id: m.user_id, label: m.display_name || m.email || m.user_id}
        end

      {:error, _} ->
        []
    end
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("open_estate", %{"route" => route}, socket) do
    {:noreply, push_patch(socket, to: chat_path(route))}
  end

  def handle_event("open_conversation", %{"route" => route, "id" => id}, socket) do
    # Deliberately does NOT follow: reading a thread is not joining it.
    {:noreply, push_patch(socket, to: chat_path(route, id))}
  end

  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_patch(socket, to: chat_path(socket.assigns.athanor_route))}
  end

  # Click a person → the frozen pair of the two of you, found or minted,
  # and selected here. The session's default athanor does not move; the
  # tool decides reachability ("you already share an active estate").
  def handle_event("open_dm", %{"user-id" => user_id}, socket) do
    with {:ok, %{id: id}} <- call_tool(socket, "athanor/pair", %{"user" => user_id}),
         {:ok, pair} <- Athanors.get(id) do
      {:noreply, push_patch(socket, to: chat_path(Athanors.route_slug(pair)))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open a DM: #{error_message(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not open a DM.")}
    end
  end

  # A seeding that failed is retried by any member; the row says how it went.
  def handle_event("provision", _params, socket) do
    case call_tool(socket.assigns.focus, "athanor/provision", %{}) do
      {:ok, _} ->
        {:noreply, socket |> reload_athanor() |> put_flash(:info, "Set up — AQUA is ready.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload_athanor()
         |> put_flash(:error, "Still not set up: #{error_message(reason)}")}
    end
  end

  # Saying one of your own lines out loud: pick an estate you belong to,
  # then one of its topics. The rules (author-only — or your own assistant's
  # line in your own athanor — membership on both sides, byte-copied
  # attachments) are `Aqua.Aloud`'s — this UI drives the same
  # `conversation.aloud` verb a headless client has.
  def handle_event("aloud_open", %{"id" => msg_id}, socket) do
    targets =
      socket.assigns.estates
      |> Enum.reject(&(&1.athanor.id == socket.assigns.athanor.id))
      |> Enum.map(&%{id: &1.athanor.id, name: &1.label, kind: &1.kind})

    {:noreply,
     socket
     |> assign(:aloud_for, msg_id)
     |> assign(:aloud_targets, targets)
     |> assign(:aloud_estate, nil)
     |> assign(:aloud_topics, [])}
  end

  def handle_event("aloud_pick_estate", %{"athanor" => athanor_id}, socket) do
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
    %{conversation: conv, aloud_for: msg_id, aloud_estate: estate, focus: focus} = socket.assigns

    result =
      call_tool(focus, "conversation/aloud", %{
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
    focus = socket.assigns.focus

    case Arca.TopicSubscriptionStorage.follow(focus, id, focus.user_id) do
      :ok -> {:noreply, socket |> refresh_followed() |> load_rail()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not follow — try again.")}
    end
  end

  def handle_event("unfollow_topic", %{"id" => id}, socket) do
    focus = socket.assigns.focus

    case Arca.TopicSubscriptionStorage.unfollow(focus, id, focus.user_id) do
      :ok -> {:noreply, socket |> refresh_followed() |> load_rail()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unfollow — try again.")}
    end
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    focus = socket.assigns.focus

    # The turn may be running in a thread this tab is not looking at: the
    # runner is the fact, not what this socket happens to be rendering.
    if Aqua.ConversationRunner.turn_running?(focus, id) do
      {:noreply, put_flash(socket, :error, "Stop the running turn before deleting.")}
    else
      case Conversations.delete(focus, id) do
        :ok ->
          current = socket.assigns.conversation && socket.assigns.conversation.id

          if current == id do
            {:noreply, push_patch(socket, to: chat_path(socket.assigns.athanor_route))}
          else
            {:noreply, socket |> refresh_list() |> load_rail()}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Delete failed: #{error_message(reason)}")}
      end
    end
  end

  # ============================================================================
  # PubSub fan-in — the lists, and what the pane tells the page
  # ============================================================================

  @impl true
  def handle_info(
        {:conversation, id, {:message, _row}},
        %{assigns: %{conversation: %{id: id}}} = socket
      ) do
    {:noreply, socket |> refresh_list() |> load_rail()}
  end

  def handle_info({:conversation, _id, _event}, socket), do: {:noreply, socket}

  # The pane's first message created the thread: the address is this page's.
  def handle_info({:pane, _pane, {:opened, conv}}, socket) do
    {:noreply,
     socket
     |> refresh_list()
     |> load_rail()
     |> push_patch(to: chat_path(socket.assigns.athanor_route, conv.id))}
  end

  # A line the pane offers to say aloud: the picker is this page's.
  def handle_info({:pane, _pane, {:aloud_open, msg_id}}, socket) do
    handle_event("aloud_open", %{"id" => msg_id}, socket)
  end

  # A rename or a settings change re-reads the row; an archive sends the
  # page back to the default — the runner behind the thread has stopped.
  def handle_info({:notify, _athanor_id, :athanor_changed, _payload}, socket) do
    socket = reload_athanor(socket)

    case socket.assigns.athanor do
      %{status: "archived"} ->
        {:noreply,
         socket
         |> put_flash(:error, "This athanor has been archived.")
         |> push_navigate(to: chat_path(nil))}

      _ ->
        {:noreply, load_rail(socket)}
    end
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  defp reload_athanor(socket) do
    case Athanors.get(socket.assigns.athanor.id) do
      {:ok, athanor} -> assign(socket, :athanor, athanor)
      _ -> socket
    end
  end

  defp refresh_list(socket) do
    socket
    |> assign(:conversations, Conversations.list(socket.assigns.focus))
    |> refresh_followed()
  end

  # Which of the estate's topics are in this person's sidebar. Following
  # decides emphasis and notification, never visibility.
  defp refresh_followed(socket) do
    focus = socket.assigns.focus
    assign(socket, :followed, Arca.TopicSubscriptionStorage.followed(focus, focus.user_id))
  end

  defp provisioning_error(athanor) do
    case Athanors.settings(athanor)["provisioning_error"] do
      %{} = error -> error
      _ -> nil
    end
  end

  defp provisioning_detail(athanor) do
    case provisioning_error(athanor) do
      %{"detail" => detail} when is_binary(detail) ->
        if String.length(detail) > 120, do: String.slice(detail, 0, 120) <> "…", else: detail

      _ ->
        ""
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-root" class="flex h-full min-h-0">
      <%!-- The rail: your own athanor, your DMs, your groups and their
            topics, across every estate you belong to — a column beside the
            chat, a panel over it on a phone. --%>
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
              title={"Start a new conversation in #{@athanor && @athanor.name}"}
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

        <div class="flex-1 overflow-y-auto">
          <details
            :for={estate <- @estates}
            id={"estate-" <> estate.athanor.id}
            open={@athanor && estate.athanor.id == @athanor.id}
            class="border-b border-gray-800/60"
          >
            <summary
              class={[
                "flex items-center gap-2 px-3 py-1.5 text-[11px] uppercase tracking-wider cursor-pointer hover:text-gray-200",
                if(@athanor && estate.athanor.id == @athanor.id,
                  do: "text-gray-200",
                  else: "text-gray-500"
                )
              ]}
              phx-click="open_estate"
              phx-value-route={estate.route}
            >
              <span class="truncate">{estate.label}</span>
              <span :if={estate.kind == :dm} class="text-[9px] text-gray-600 normal-case">DM</span>
              <span class="ml-auto text-[10px] text-gray-600 normal-case">
                {length(estate.topics)}
              </span>
            </summary>
            <div :if={estate.topics == []} class="px-3 py-2 text-xs text-gray-600">
              No conversations yet.
            </div>
            <% {following, other} =
              Enum.split_with(estate.topics, &MapSet.member?(estate.followed, &1.id)) %>
            <ul :if={following != []} class="divide-y divide-gray-800/60">
              <.topic_row
                :for={conv <- following}
                conv={conv}
                route={estate.route}
                current={@conversation}
                followed
              />
            </ul>
            <details :if={other != []} open={following == []} class="border-t border-gray-800/60">
              <summary class="px-4 py-1 text-[10px] uppercase tracking-wider text-gray-600 cursor-pointer hover:text-gray-400">
                Other topics ({length(other)})
              </summary>
              <ul class="divide-y divide-gray-800/60">
                <.topic_row
                  :for={conv <- other}
                  conv={conv}
                  route={estate.route}
                  current={@conversation}
                  followed={false}
                />
              </ul>
            </details>
          </details>

          <%!-- People you share an estate with: a click is a DM, found or
                minted, opened here — the estate switcher does not move. --%>
          <div :if={@people != []} class="border-b border-gray-800/60">
            <p class="px-3 py-1.5 text-[11px] uppercase tracking-wider text-gray-500">People</p>
            <ul>
              <li :for={person <- @people}>
                <button
                  type="button"
                  phx-click="open_dm"
                  phx-value-user-id={person.user_id}
                  class="flex w-full items-center px-3 py-1.5 text-xs text-gray-400 hover:bg-gray-800/50 hover:text-gray-200"
                  title={"Message #{person.label}"}
                >
                  <span class="truncate">{person.label}</span>
                </button>
              </li>
            </ul>
          </div>
        </div>
      </aside>

      <div class="flex flex-1 min-w-0 flex-col">
        <div
          :if={@athanor && is_nil(@athanor.provisioned_at)}
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
        {if @athanor,
          do:
            live_render(@socket, PrismWeb.ConversationPaneLive,
              id: "pane-" <> @athanor.id <> "-" <> ((@conversation && @conversation.id) || "new"),
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
            A copy of the line lands on an estate's thread, attributed to you.
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
              phx-value-athanor={t.id}
              class={[
                "block w-full text-left rounded px-2 py-1 text-xs",
                if(@aloud_estate == t.id,
                  do: "bg-gray-800 text-white",
                  else: "text-gray-300 hover:bg-gray-800/60"
                )
              ]}
            >
              {t.name}
              <span :if={t.kind == :dm} class="text-[10px] text-gray-500 ml-1">DM</span>
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

  attr :conv, :map, required: true
  attr :route, :string, required: true
  attr :current, :any, default: nil
  attr :followed, :boolean, required: true

  # One topic in the rail. Follow/unfollow is a word, not a glyph — the
  # action must read as what it does. Following decides emphasis and
  # notification, never access: every row opens on a click.
  defp topic_row(assigns) do
    ~H"""
    <li
      id={"conv-" <> @conv.id}
      class={[
        "group flex items-start gap-2 px-4 py-2 text-xs cursor-pointer hover:bg-gray-800/50",
        if(@current && @conv.id == @current.id, do: "bg-gray-800/80", else: "")
      ]}
      phx-click={
        JS.push("open_conversation", value: %{route: @route, id: @conv.id})
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
        :if={@current && @conv.athanor_id == @current.athanor_id}
        type="button"
        phx-click={if @followed, do: "unfollow_topic", else: "follow_topic"}
        phx-value-id={@conv.id}
        class="opacity-0 group-hover:opacity-100 text-[10px] text-gray-500 hover:text-gray-200 shrink-0"
      >
        {if @followed, do: "Unfollow", else: "Follow"}
      </button>
      <button
        :if={@current && @conv.athanor_id == @current.athanor_id}
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
end
