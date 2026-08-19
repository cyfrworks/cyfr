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
    if connected?(socket),
      do: {:noreply, socket |> load() |> assign(:loading, false)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("add", %{"email" => email}, socket) do
    case call_tool(socket, "member/add", %{"email" => String.trim(email)}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:new_email, "")
         |> load()
         |> put_flash(:info, "Added. If they have never signed in here, the seat waits for them.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add: #{inspect(reason)}")}
    end
  end

  def handle_event("remove", %{"user-id" => user_id}, socket) do
    case call_tool(socket, "member/remove", %{"user_id" => user_id}) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove: #{inspect(reason)}")}
    end
  end

  def handle_event("remove_invite", %{"email" => email}, socket) do
    case call_tool(socket, "member/remove", %{"email" => email}) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Invitation withdrawn.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not withdraw: #{inspect(reason)}")}
    end
  end

  def handle_event("leave", _params, socket) do
    case call_tool(socket, "member/leave", %{}) do
      {:ok, _} ->
        {:noreply, redirect(socket, to: "/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not leave: #{inspect(reason)}")}
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
        {:noreply, put_flash(socket, :error, "Could not create: #{inspect(reason)}")}
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
        {:noreply, put_flash(socket, :error, "Could not switch: #{inspect(reason)}")}
    end
  end

  def handle_event("form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:new_email, Map.get(params, "email", socket.assigns.new_email))
     |> assign(:new_group_name, Map.get(params, "name", socket.assigns.new_group_name))}
  end

  @impl true
  def handle_info({:notify, _athanor_id, kind, _payload}, socket)
      when kind in [:member_changed, :athanor_changed] do
    {:noreply, load(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  defp leave_confirm(_athanor, members) do
    if last_active?(members),
      do: "You are the last member. Leaving archives this group. Continue?",
      else: "Leave this group? The others keep it."
  end

  defp last_active?(members) when is_list(members),
    do: Enum.count(members, &(&1[:status] == "active")) <= 1

  defp last_active?(_), do: false

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
            Leave group
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
            <%= if @athanor && @athanor.kind == "person" do %>
              Your own athanor. It has one member — you.
            <% else %>
              Every member is this group's admin: anyone here may add or remove anyone.
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
                  :if={m[:status] == "active" && m[:user_id] != @context.user_id}
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
            :if={@athanor && @athanor.kind == "group"}
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
