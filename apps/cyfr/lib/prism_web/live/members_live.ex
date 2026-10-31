# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MembersLive do
  @moduledoc """
  Who is in the focused athanor: the members, the pending invites, and the
  controls every member has: add by name, remove, withdraw an invite,
  leave. In an open group a name no one holds offers a link with that name
  filled in. Withdraw reaches only an
  invitation: one accepted since the page loaded stays a member. A
  person's own athanor has one member and no controls beyond the list.

  In an open group, the invitation links section creates a link that
  makes a new person here and seats them in the group, shows it once with
  a copy control, lists the links the viewer sees for this group
  (`invitation.list`: their own, or every one for the platform
  administrator) and revokes one still pending.
  """

  use PrismWeb, :live_view

  alias Phoenix.LiveView.JS
  alias Sanctum.Tenancy.Athanors

  @impl true
  def mount(_params, _session, socket) do
    ctx = socket.assigns[:context]

    if connected?(socket) do
      actor = Sanctum.Context.actor(ctx)
      Cyfr.Bus.subscribe(actor, Cyfr.Bus.notify(actor))
    end

    {:ok,
     socket
     |> assign(:page_title, "Members")
     |> assign(:active_nav, "members")
     |> assign(:athanor, nil)
     |> assign(:athanor_label, nil)
     |> assign(:members, [])
     |> assign(:groups, [])
     |> assign(:new_person, "")
     |> assign(:unknown_name, nil)
     |> assign(:new_group_name, "")
     |> assign(:invitations, [])
     |> assign(:new_link, nil)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket), do: send(self(), :load_members)
    {:noreply, socket}
  end

  @impl true
  def handle_event("add", %{"person" => person}, socket) do
    socket = socket |> assign(:unknown_name, nil) |> clear_flash()

    with {:ok, name} <- member_name(person) do
      case call_tool(socket, "member/add", %{"handle" => name}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:new_person, "")
           |> load()
           |> put_flash(
             :info,
             "Added. If they have never signed in here the seat waits for them; if the " <>
               "operator has not allowed their address or identifier yet, it waits for that too."
           )}

        {:error, reason} ->
          {:noreply, add_refused(socket, name, reason)}
      end
    else
      {:error, sentence} -> {:noreply, put_flash(socket, :error, sentence)}
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

  # Withdraw names the invitation only: once the invitee's first sign-in
  # has claimed it, the row is their seat, and Withdraw must never remove a
  # member. The roster this page shows may be older than that claim.
  def handle_event("remove_invite", params, socket) do
    args = params |> Map.take(["identifier"]) |> Map.put("invitation", true)

    case call_tool(socket, "member/remove", args) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Invitation withdrawn.")}

      {:error, {:not_found, "Invitation", _named}} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "That invitation was already accepted — they are a member now.")}

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

  # Growing a DM is a NEW open group with the three of you — the pair's
  # door stays closed and its history stays where it was said. The partner
  # is seated by user id (an active seat at once); the new person is named
  # before the group is created, so an invalid or unanswered name leaves no group.
  def handle_event("add_third", %{"person" => person}, socket) do
    socket = socket |> assign(:unknown_name, nil) |> clear_flash()
    %{athanor: pair, members: members, context: ctx} = socket.assigns

    partner =
      Enum.find_value(members, fn m ->
        id = m[:user_id]
        if is_binary(id) and id != ctx.user_id and m[:status] == "active", do: id
      end)

    name = String.slice("#{pair.name} +", 0, 80)

    with {:ok, person_name} <- member_name(person),
         {:ok, %{identifier: identifier}} <- Sanctum.Handle.resolve(person_name),
         true <- is_binary(partner),
         {:ok, %{id: group_id}} <- call_tool(socket, "athanor/create", %{"name" => name}),
         {:ok, _} <-
           call_tool(socket, "member/add", %{"user_id" => partner, "athanor" => group_id}),
         {:ok, _} <-
           call_tool(socket, "member/add", %{"identifier" => identifier, "athanor" => group_id}),
         {:ok, %{athanor: %{route: route}}} <-
           call_tool(socket, "session/use", %{"athanor" => group_id}) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "A new group with the three of you. This thread stays as it was — " <>
           "nothing moves."
       )
       |> push_navigate(to: PrismWeb.Focus.path(route, "/members"))}
    else
      {:error, sentence} when is_binary(sentence) ->
        {:noreply, put_flash(socket, :error, sentence)}

      {:error, reason} ->
        name = person |> String.trim() |> String.trim_leading("@")
        {:noreply, add_refused(socket, name, reason)}

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

  def handle_event("invitation_create", _params, %{assigns: %{athanor: %{id: id}}} = socket) do
    case call_tool(socket, "invitation/create", %{"athanor_id" => id}) do
      {:ok, %{invitation_url: link}} ->
        {:noreply, socket |> assign(:new_link, link) |> load()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not create the link: #{error_message(reason)}")}
    end
  end

  def handle_event("invite_name", _params, socket) do
    with %{unknown_name: name, athanor: %{id: id} = athanor} when is_binary(name) <-
           socket.assigns,
         true <- invitable?(athanor) do
      case call_tool(socket, "invitation/create", %{"name" => name, "athanor_id" => id}) do
        {:ok, %{invitation_url: link}} ->
          {:noreply,
           socket
           |> assign(:new_link, link)
           |> assign(:new_person, "")
           |> assign(:unknown_name, nil)
           |> clear_flash()
           |> load()}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not create the link: #{error_message(reason)}")}
      end
    else
      _no_offer -> {:noreply, socket}
    end
  end

  def handle_event("invitation_revoke", %{"id" => id}, socket) do
    case call_tool(socket, "invitation/revoke", %{"invitation_id" => id}) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Invitation link revoked.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke: #{error_message(reason)}")}
    end
  end

  def handle_event("form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:unknown_name, nil)
     |> assign(:new_person, Map.get(params, "person", socket.assigns.new_person))
     |> assign(:new_group_name, Map.get(params, "name", socket.assigns.new_group_name))}
  end

  @impl true
  def handle_info(:load_members, socket) do
    {:noreply, socket |> load() |> assign(:loading, false)}
  end

  def handle_info(%Cyfr.Bus.Notify{kind: kind}, socket)
      when kind in [:member_changed, :athanor_changed] do
    {:noreply, load(socket)}
  end

  def handle_info(msg, socket) do
    Prima.LoggerContext.unexpected(__MODULE__, msg, :debug)
    {:noreply, socket}
  end

  # What leaving actually does, said before it happens: the last member out
  # archives the group.
  #
  # A frozen pair ends when ANYONE leaves — and a later click mints a new,
  # empty tape. Said before it happens, because people will read it as
  # data loss otherwise: it is, and it is deliberate.
  defp leave_confirm(%{roster: "frozen"}, _members) do
    "Leaving ends this thread for both of you — it is archived, and " <>
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

  defp member_name(person) do
    name =
      case String.trim(person) do
        "@" <> name -> name
        name -> name
      end

    cond do
      String.starts_with?(name, ["per_", "usr_"]) ->
        {:error,
         "Add people by name here. To add someone by identifier, use cyfr member add on the command line."}

      Prima.ComponentRef.valid_personal_slug?(name) ->
        {:ok, name}

      true ->
        {:error,
         "A name is lowercase letters and digits joined by single hyphens, at most 39 characters."}
    end
  end

  defp add_refused(socket, name, %Prima.Refusal{reason: reason}),
    do: add_refused(socket, name, reason)

  defp add_refused(socket, name, reason) when reason in [:handle_not_found, :not_found],
    do: assign(socket, :unknown_name, name)

  defp add_refused(socket, _name, reason)
       when reason in [:registry_unavailable, :malformed_answer],
       do: put_flash(socket, :error, "cyfr.run did not answer. Try again.")

  defp add_refused(socket, _name, :no_registry),
    do:
      put_flash(
        socket,
        :error,
        "This CYFR does not reach cyfr.run, so nobody can be found by name."
      )

  defp add_refused(socket, _name, reason),
    do: put_flash(socket, :error, "Could not add: #{error_message(reason)}")

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
    |> assign(:athanor_label, athanor && PrismWeb.Athanors.label(athanor, ctx))
    |> assign(:members, members)
    |> assign(:groups, groups)
    |> assign(:invitations, invitations(socket, athanor))
  end

  # The invitation links the viewer sees that seat people in this group,
  # newest first.
  defp invitations(socket, %{id: athanor_id} = athanor) do
    with true <- invitable?(athanor),
         {:ok, %{invitations: invitations}} <- call_tool(socket, "invitation/list", %{}) do
      Enum.filter(invitations, &(&1[:athanor_id] == athanor_id))
    else
      _none -> []
    end
  end

  defp invitations(_socket, _athanor), do: []

  defp invitable?(%{kind: "group", status: "active", roster: "open"}), do: true
  defp invitable?(_athanor), do: false

  defp until(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")
      _unparsed -> iso
    end
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
            {if frozen?(@athanor), do: "End thread", else: "Leave group"}
          </.button>
        </:actions>
      </.page_header>

      <div :if={@loading} class="text-center text-gray-500 py-12">Loading...</div>

      <div :if={!@loading} class="space-y-6">
        <.card>
          <h3 class="text-sm font-medium text-gray-400 mb-1">
            {@athanor_label || "Athanor"}
          </h3>
          <p class="text-xs text-gray-500 mb-4">
            <%= cond do %>
              <% @athanor && @athanor.kind == "person" -> %>
                Your own athanor. It has one member — you.
              <% @athanor && frozen?(@athanor) -> %>
                A direct thread — its two members were set when it opened, and
                nobody else can join. To bring someone in, add them below: that starts
                a new group with the three of you and leaves this one as it is.
              <% true -> %>
                Every member is this group's admin: anyone here may add or remove anyone.
                You can only DM someone you already share an athanor with — anyone on
                this list qualifies.
            <% end %>
          </p>

          <div :if={@members == []} class="py-8"><.empty_state message="No members" /></div>
          <.table :if={@members != []} id="members" rows={@members}>
            <:col :let={m} label="Name">
              {if m[:namespace], do: "@#{m[:namespace]}", else: m[:email] || "-"}
            </:col>
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
                  phx-click="remove"
                  phx-value-user-id={m[:user_id]}
                  data-confirm="Remove this member?"
                >
                  Remove
                </.button>
                <.button
                  :if={m[:status] == "invited" && m[:identifier]}
                  variant="ghost"
                  phx-click="remove_invite"
                  phx-value-identifier={m[:identifier]}
                >
                  Withdraw
                </.button>
              </div>
            </:col>
          </.table>

          <form
            :if={@athanor && @athanor.kind == "group" && not frozen?(@athanor)}
            id="member-add-form"
            phx-submit="add"
            phx-change="form_changed"
            class="mt-4 flex gap-2 items-end"
          >
            <div class="flex-1">
              <.input
                name="person"
                value={@new_person}
                type="text"
                required
                placeholder="@name"
              />
            </div>
            <.button type="submit">Add member</.button>
          </form>
          <p
            :if={@athanor && @athanor.kind == "group" && not frozen?(@athanor)}
            class="mt-1 text-xs text-gray-500"
            data-test="member-add-help"
          >
            Add someone by their name. A name no one holds yet offers an invitation link with that name filled in.
          </p>

          <%!-- A DM's door is closed; growing the room is a different act.
                The pair stands, nothing is copied. --%>
          <form
            :if={@athanor && frozen?(@athanor)}
            id="member-add-third-form"
            phx-submit="add_third"
            phx-change="form_changed"
            class="mt-4 flex gap-2 items-end"
          >
            <div class="flex-1">
              <.input
                name="person"
                value={@new_person}
                type="text"
                required
                placeholder="@name"
              />
            </div>
            <.button type="submit">Add someone — starts a new group</.button>
          </form>

          <div :if={@unknown_name} data-test="member-unknown-name" class="mt-4 space-y-2">
            <p class="text-sm text-gray-400">No one has @{@unknown_name} yet.</p>
            <.button :if={invitable?(@athanor)} phx-click="invite_name">
              Create an invitation link for @{@unknown_name}
            </.button>
          </div>
        </.card>

        <.card :if={invitable?(@athanor)}>
          <h3 class="text-sm font-medium text-gray-400 mb-1">Invitation links</h3>
          <p class="text-xs text-gray-500 mb-4">
            A link makes someone new to this CYFR a person here and seats them in this group.
            Someone who already has a CYFR name signs in with it from the same link. It works once
            and expires after seven days.
          </p>

          <div :if={@new_link} data-test="invitation-new" class="mb-4 space-y-2">
            <p class="text-xs text-gray-400">
              Send this link to the person you invite. It is shown only now.
            </p>
            <div class="flex gap-2 items-center">
              <code
                data-test="invitation-link"
                class="flex-1 text-xs text-gray-200 bg-gray-800 rounded px-2 py-2 break-all"
              >
                {@new_link}
              </code>
              <.button
                variant="ghost"
                data-test="invitation-copy"
                phx-click={JS.dispatch("phx:clipboard", detail: %{text: @new_link})}
              >
                Copy
              </.button>
            </div>
          </div>

          <div :if={@invitations != []} id="invitations">
            <.table id="invitation-rows" rows={@invitations}>
              <:col :let={i} label="State">
                <.badge color={if i[:state] == "pending", do: "green", else: "yellow"}>
                  {i[:state]}
                </.badge>
              </:col>
              <:col :let={i} label="Expires">{until(i[:expires_at])}</:col>
              <:col :let={i} label="Actions">
                <.button
                  :if={i[:state] == "pending"}
                  variant="ghost"
                  phx-click="invitation_revoke"
                  phx-value-id={i[:id]}
                  data-confirm="Revoke this link? It will admit no one."
                >
                  Revoke
                </.button>
              </:col>
            </.table>
          </div>

          <.button class="mt-4" phx-click="invitation_create" data-test="invitation-create">
            Create an invitation link
          </.button>
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

          <form
            id="group-create-form"
            phx-submit="create_group"
            phx-change="form_changed"
            class="mt-4 flex gap-2 items-end"
          >
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
