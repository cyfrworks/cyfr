# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.GrantsComponent do
  @moduledoc """
  A component's grants, each with Revoke: the one list Components' expanded
  row and the component's own page both draw.

  The grants are the component's profiles in the person's athanor that are
  not revoked, read through `profile.list` with the component's name-level
  reference, and a press of Revoke calls `profile.revoke` with that
  profile's id. Both go through the gate as the person (`PrismWeb.Ops`), so
  the operations' own rules decide: a surface that cannot consent is
  refused there, and the refusal is shown under the list. After a revoke
  the list is read again, so it shows what the store holds, never what the
  page assumed.

  A grant reads as granted only when its head reads; one whose head is
  missing or damaged says so and that revoking it and granting access again
  mends it, and one the store could not answer says so and offers to read
  it again, so an outage never reads as a grant.
  """

  use PrismWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, grants: nil, refusal: nil, error: nil)}
  end

  # The list is read when the component first mounts and whenever the
  # parent hands it another component, on a current context
  # (`CyfrWeb.ContextGuard.guard/2`), as every read and revoke here is.
  @impl true
  def update(assigns, socket) do
    reread? = socket.assigns[:ref] != assigns.ref
    socket = assign(socket, assigns)

    if reread? do
      {:noreply, socket} =
        CyfrWeb.ContextGuard.guard(socket, fn socket -> {:noreply, load(socket)} end)

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("reload", _params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket -> {:noreply, load(socket)} end)
  end

  def handle_event("revoke", %{"profile" => profile_id}, socket) when is_binary(profile_id) do
    CyfrWeb.ContextGuard.guard(socket, fn socket -> {:noreply, revoke(socket, profile_id)} end)
  end

  # Only a grant this list holds is revoked: an id it never listed, another
  # athanor's among them, reaches no operation.
  defp revoke(socket, profile_id) do
    if Enum.any?(socket.assigns.grants || [], &(&1.id == profile_id)) do
      case call_tool(socket.assigns.context, "profile/revoke", %{"profile_id" => profile_id}) do
        {:ok, _revoked} -> socket |> assign(:error, nil) |> load()
        {:error, reason} -> assign(socket, :error, error_message(reason))
      end
    else
      socket
    end
  end

  defp load(socket) do
    case call_tool(socket.assigns.context, "profile/list", %{"ref" => socket.assigns.ref}) do
      {:ok, %{profiles: profiles}} when is_list(profiles) ->
        assign(socket, grants: profiles, refusal: nil)

      {:error, reason} ->
        assign(socket, grants: [], refusal: error_message(reason))
    end
  end

  defp kind_label(%{kind: :public}), do: "Public"
  defp kind_label(%{kind: :owner}), do: "Your grant"
  defp kind_label(_damaged), do: "Grant"

  defp grant_title(%{label: label} = grant) when is_binary(label) and label != "",
    do: "#{kind_label(grant)} · #{label}"

  defp grant_title(grant), do: kind_label(grant)

  defp grant_state(%{status: :corrupt}), do: damaged()
  defp grant_state(%{head_state: "damaged"}), do: damaged()

  defp grant_state(%{head_state: "missing"}),
    do: "Not granted: no grant is recorded for it. Revoke it and grant access again."

  defp grant_state(%{head_state: "unavailable"}), do: "Could not be read just now."

  defp grant_state(%{head_state: "present", status: :active, head_revision: revision}),
    do: "Granted · revision #{revision}"

  defp grant_state(%{head_state: "present", status: :needs_consent, head_revision: revision}),
    do: "Asks for your grant again · revision #{revision}"

  defp grant_state(_unknown), do: damaged()

  defp damaged, do: "Damaged: it cannot be read. Revoke it and grant access again."

  defp unavailable?(grant), do: Map.get(grant, :head_state) == "unavailable"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <h4 class="text-xs font-medium uppercase tracking-wider text-gray-500">Grants</h4>
      <p :if={@grants == [] and is_nil(@refusal)} class="text-sm text-gray-500">
        No grants.
      </p>
      <p :if={@refusal} class="text-sm text-red-300">
        The grants could not be read: {@refusal}
      </p>
      <ul :if={@grants not in [nil, []]} class="divide-y divide-gray-800">
        <li
          :for={grant <- @grants}
          id={"#{@id}-#{grant.id}"}
          class="flex items-center justify-between gap-3 py-2"
        >
          <div class="min-w-0">
            <p class="text-sm text-gray-200">{grant_title(grant)}</p>
            <p class="text-xs text-gray-500">{grant_state(grant)}</p>
          </div>
          <button
            :if={unavailable?(grant)}
            type="button"
            phx-click="reload"
            phx-target={@myself}
            class="shrink-0 rounded border border-gray-700 px-2.5 py-1 text-xs text-gray-300 hover:bg-gray-800"
          >
            Try again
          </button>
          <button
            type="button"
            phx-click="revoke"
            phx-value-profile={grant.id}
            phx-target={@myself}
            data-confirm="Revoke this grant? The component asks for your grant again before it next runs."
            class="shrink-0 rounded border border-gray-700 px-2.5 py-1 text-xs text-gray-300 hover:border-red-800 hover:bg-red-900/40 hover:text-red-200"
          >
            Revoke
          </button>
        </li>
      </ul>
      <p :if={@error} class="text-sm text-red-300">The grant was not revoked: {@error}</p>
    </div>
    """
  end
end
