# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MembersLive do
  @moduledoc """
  Who is in the focused athanor: the members, the pending invites, and the
  controls every member has — add by email, remove, leave. A person's own
  athanor has one member and no controls beyond the list.
  """

  use PrismWeb, :live_view

  alias Sanctum.Tenancy.Athanors

  @impl true
  def mount(_params, _session, socket) do
    ctx = socket.assigns[:context]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.Notify.topic(ctx.athanor_id))
    end

    {:ok,
     socket
     |> assign(:page_title, "Members")
     |> assign(:active_nav, "members")
     |> assign(:athanor, nil)
     |> assign(:members, [])
     |> assign(:groups, [])
     |> assign(:new_email, "")
     |> assign(:new_group_name, "")
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket), do: send(self(), :load_members)
    {:noreply, socket}
  end

  @impl true
  def handle_event("add", %{"email" => email}, socket) do
    case call_tool(socket, "member/add", %{"email" => String.trim(email)}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:new_email, "")
         |> load()
         |> put_flash(
           :info,
           "Added. If they have never signed in here the seat waits for them; if the " <>
             "operator has not allowed their address yet, it waits for that too."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add: #{error_message(reason)}")}
    end
  end

  def handle_event("remove", %{"user-id" => user_id}, socket) do
    case call_tool(socket, "member/remove", %{"user_id" => user_id}) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove: #{error_message(reason)}")}
    end
  end

  def handle_event("remove_invite", %{"email" => email}, socket) do
    case call_tool(socket, "member/remove", %{"email" => email}) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Invitation withdrawn.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not withdraw: #{error_message(reason)}")}
    end
  end

  def handle_event("leave", _params, socket) do
    case call_tool(socket, "member/leave", %{}) do
      {:ok, _} ->
        {:noreply, redirect(socket, to: "/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not leave: #{error_message(reason)}")}
    end
  end

  # Click a name → the frozen pair of the two of you, found or minted, and
  # its chat opens. Reachability is decided in the tool ("you already share
  # an active estate"), which is true of anyone on this list.
  def handle_event("open_dm", %{"user-id" => user_id}, socket) do
    with {:ok, %{id: id}} <- call_tool(socket, "athanor/pair", %{"user" => user_id}),
         {:ok, %{athanor: %{route: route}}} <-
           call_tool(socket, "session/use", %{"athanor" => id}) do
      {:noreply, push_navigate(socket, to: PrismWeb.Focus.path(route, ""))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open a DM: #{error_message(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not open a DM.")}
    end
  end

  # Growing a DM is a NEW open group with the three of you — the pair's
  # door stays closed and its history stays where it was said. The partner
  # is seated by user id (an active seat at once); the new person arrives
  # by email, the ordinary first contact on an open athanor.
  def handle_event("add_third", %{"email" => email}, socket) do
    %{athanor: pair, members: members, context: ctx} = socket.assigns

    partner =
      Enum.find_value(members, fn m ->
        id = m[:user_id]
        if is_binary(id) and id != ctx.user_id and m[:status] == "active", do: id
      end)

    name = String.slice("#{pair.name} +", 0, 80)

    with true <- is_binary(partner),
         {:ok, %{id: group_id}} <- call_tool(socket, "athanor/create", %{"name" => name}),
         {:ok, _} <-
           call_tool(socket, "member/add", %{"user_id" => partner, "athanor" => group_id}),
         {:ok, _} <-
           call_tool(socket, "member/add", %{
             "email" => String.trim(email),
             "athanor" => group_id
           }),
         {:ok, %{athanor: %{route: route}}} <-
           call_tool(socket, "session/use", %{"athanor" => group_id}) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "A new group with the three of you. This conversation stays as it was — " <>
           "nothing moves."
       )
       |> push_navigate(to: PrismWeb.Focus.path(route, "/members"))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add: #{error_message(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not add someone right now.")}
    end
  end

  def handle_event("create_group", %{"name" => name}, socket) do
    case call_tool(socket, "athanor/create", %{"name" => String.trim(name)}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:new_group_name, "")
         |> load()
         |> put_flash(:info, "Group created — you are its first member.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create: #{error_message(reason)}")}
    end
  end

  # Focus is in the URL: opening another athanor is a link to its pages.
  # The session's default athanor follows so `/` lands there next time.
  def handle_event("switch", %{"athanor" => athanor_id}, socket) do
    case call_tool(socket, "session/use", %{"athanor" => athanor_id}) do
      {:ok, %{athanor: %{route: route}}} ->
        {:noreply, push_navigate(socket, to: PrismWeb.Focus.path(route, "/members"))}

      {:ok, _} ->
        {:noreply, redirect(socket, to: "/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not switch: #{error_message(reason)}")}
    end
  end

  def handle_event("form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:new_email, Map.get(params, "email", socket.assigns.new_email))
     |> assign(:new_group_name, Map.get(params, "name", socket.assigns.new_group_name))}
  end

  @impl true
  def handle_info(:load_members, socket) do
    {:noreply, socket |> load() |> assign(:loading, false)}
  end

  def handle_info({:notify, _athanor_id, kind, _payload}, socket)
      when kind in [:member_changed, :athanor_changed] do
    {:noreply, load(socket)}
  end

  def handle_info(msg, socket) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # What leaving actually does, said before it happens: the last member out
  # archives the group, and Home is retired for the record — the server
  # starts a new one rather than reopening it.
  defp leave_confirm(%{home: true}, members) do
    if last_active?(members),
      do:
        "You are the last member. Leaving retires Home for the record — " <>
          "the server starts a new one. Continue?",
      else: "Leave Home? The others keep it."
  end

  # A frozen pair ends when ANYONE leaves — and a later click mints a new,
  # empty tape. Said before it happens, because people will read it as
  # data loss otherwise: it is, and it is deliberate.
  defp leave_confirm(%{roster: "frozen"}, _members) do
    "Leaving ends this conversation for both of you — it is archived, and " <>
      "messaging them again starts a new, empty one. Continue?"
  end

  defp leave_confirm(_athanor, members) do
    if last_active?(members),
      do: "You are the last member. Leaving archives this group. Continue?",
      else: "Leave this group? The others keep it."
  end

  defp last_active?(members) when is_list(members),
    do: Enum.count(members, &(&1[:status] == "active")) <= 1

  defp last_active?(_), do: false

  defp frozen?(%{roster: "frozen"}), do: true
  defp frozen?(_), do: false

  defp load(socket) do
    ctx = socket.assigns.context

    athanor =
      case Athanors.get(ctx.athanor_id) do
        {:ok, athanor} -> athanor
        _ -> nil
      end

    members =
      case call_tool(socket, "member/list", %{}) do
        {:ok, %{members: members}} -> members
        _ -> []
      end

    groups =
      case call_tool(socket, "athanor/list", %{}) do
        {:ok, %{athanors: athanors}} -> athanors
        _ -> []
      end

    socket
    |> assign(:athanor, athanor)
    |> assign(:members, members)
    |> assign(:groups, groups)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="Members">
        <:actions>
          <.button
            :if={@athanor && @athanor.kind == "group"}
            variant="ghost"
            phx-click="leave"
            data-confirm={leave_confirm(@athanor, @members)}
          >
            {if frozen?(@athanor), do: "End conversation", else: "Leave group"}
          </.button>
        </:actions>
      </.page_header>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-6">
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-1">
            {if @athanor, do: @athanor.name, else: "Athanor"}
          </h3>
          <p class="text-xs text-gray-500 mb-4">
            <%= cond do %>
              <% @athanor && @athanor.kind == "person" -> %>
                Your own athanor. It has one member — you.
              <% @athanor && frozen?(@athanor) -> %>
                A direct conversation — its two members were set when it opened, and
                nobody else can join. To bring someone in, add them below: that starts
                a new group with the three of you and leaves this one as it is.
              <% true -> %>
                Every member is this group's admin: anyone here may add or remove anyone.
                You can only DM someone you already share an estate with — anyone on
                this list qualifies.
            <% end %>
          </p>

          <div :if={@members == []} class="py-8"><.empty_state message="No members" /></div>
          <.table :if={@members != []} id="members" rows={@members}>
            <:col :let={m} label="Who">
              {m[:display_name] || m[:namespace] || m[:email] || m[:user_id]}
            </:col>
            <:col :let={m} label="Email">{m[:email] || "-"}</:col>
            <:col :let={m} label="Status">
              <.badge color={if m[:status] == "active", do: "green", else: "yellow"}>
                {m[:status]}
              </.badge>
            </:col>
            <:col :let={m} label="Since">{m[:since] || "-"}</:col>
            <:col :let={m} label="Actions">
              <div :if={@athanor && @athanor.kind == "group"} class="flex gap-2">
                <.button
                  :if={
                    m[:status] == "active" && m[:user_id] != @context.user_id &&
                      not frozen?(@athanor)
                  }
                  variant="ghost"
                  phx-click="open_dm"
                  phx-value-user-id={m[:user_id]}
                >
                  Message
                </.button>
                <.button
                  :if={
                    m[:status] == "active" && m[:user_id] != @context.user_id &&
                      not frozen?(@athanor)
                  }
                  variant="ghost"
                  phx-click="remove"
                  phx-value-user-id={m[:user_id]}
                  data-confirm="Remove this member?"
                >
                  Remove
                </.button>
                <.button
                  :if={m[:status] == "invited"}
                  variant="ghost"
                  phx-click="remove_invite"
                  phx-value-email={m[:email]}
                >
                  Withdraw
                </.button>
              </div>
            </:col>
          </.table>

          <form
            :if={@athanor && @athanor.kind == "group" && not frozen?(@athanor)}
            phx-submit="add"
            phx-change="form_changed"
            class="mt-4 flex gap-2 items-end"
          >
            <div class="flex-1">
              <.input
                name="email"
                value={@new_email}
                type="email"
                required
                placeholder="someone@example.com"
              />
            </div>
            <.button type="submit">Add member</.button>
          </form>

          <%!-- A DM's door is closed; growing the room is a different act.
                The pair stands, nothing is copied. --%>
          <form
            :if={@athanor && frozen?(@athanor)}
            phx-submit="add_third"
            phx-change="form_changed"
            class="mt-4 flex gap-2 items-end"
          >
            <div class="flex-1">
              <.input
                name="email"
                value={@new_email}
                type="email"
                required
                placeholder="someone@example.com"
              />
            </div>
            <.button type="submit">Add someone — starts a new group</.button>
          </form>
        </.card>

        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-4">Your athanors</h3>
          <div class="space-y-2">
            <div :for={g <- @groups} class="flex items-center justify-between">
              <span class="text-sm text-gray-200">
                {g[:name]}
                <span class="text-xs text-gray-500 ml-2">
                  {g[:route]} · {g[:member_count]} member{if g[:member_count] == 1, do: "", else: "s"}
                </span>
              </span>
              <.button
                :if={@athanor && g[:id] != @athanor.id}
                variant="ghost"
                phx-click="switch"
                phx-value-athanor={g[:id]}
              >
                Open
              </.button>
              <.badge :if={@athanor && g[:id] == @athanor.id} color="blue">in focus</.badge>
            </div>
          </div>

          <form phx-submit="create_group" phx-change="form_changed" class="mt-4 flex gap-2 items-end">
            <div class="flex-1">
              <.input name="name" value={@new_group_name} required placeholder="New group…" />
            </div>
            <.button type="submit">Create group</.button>
          </form>
        </.card>
      </div>
    </div>
    """
  end
end
