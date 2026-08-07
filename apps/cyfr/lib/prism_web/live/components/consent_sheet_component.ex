# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponent do
  @moduledoc """
  The operator's consent sheet: the three §4.4 moments — grant, the
  embedded connection picker, and the delta shown when a component asks
  for something new — over one plan → preview → commit walk.

  Vocabulary is the operator column of §4.4: Profile, Connection,
  Consent rev N, Grant. Copy never suggests a credential is hidden from
  the operator (§2.9 physics): what the sheet promises is that material
  is sealed at rest and that components see only what was granted.
  """

  use PrismWeb, :live_component

  alias PrismWeb.MCPHelpers

  @impl true
  def mount(socket) do
    {:ok, assign(socket, plan: nil, preview: nil, decisions: %{}, error: nil, busy: false)}
  end

  @impl true
  def update(%{ref: ref} = assigns, socket) do
    socket = assign(socket, assigns)

    case socket.assigns[:plan] do
      nil -> {:ok, load_plan(socket, ref)}
      _ -> {:ok, socket}
    end
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("pick_connection", %{"need" => need, "entry_id" => entry_id}, socket) do
    decisions = Map.put(socket.assigns.decisions, need, entry_id)
    {:noreply, socket |> assign(decisions: decisions, preview: nil) |> preview()}
  end

  def handle_event("clear_connection", %{"need" => need}, socket) do
    decisions = Map.delete(socket.assigns.decisions, need)
    {:noreply, socket |> assign(decisions: decisions, preview: nil) |> preview()}
  end

  def handle_event("preview", _params, socket), do: {:noreply, preview(socket)}

  def handle_event("commit", _params, socket) do
    {:noreply, commit(socket)}
  end

  def handle_event("cancel", _params, socket) do
    send(self(), {:consent_sheet_closed, socket.assigns.ref})
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # The walk
  # ---------------------------------------------------------------------------

  defp load_plan(socket, ref) do
    case call(socket, "profile.plan", %{"ref" => ref}) do
      {:ok, plan} -> socket |> assign(plan: plan, error: nil) |> preview()
      {:error, message} -> assign(socket, error: message)
    end
  end

  defp preview(%{assigns: %{plan: nil}} = socket), do: socket

  defp preview(socket) do
    case call(socket, "profile.preview", %{"decisions" => decisions_payload(socket)}) do
      {:ok, preview} -> assign(socket, preview: preview, error: nil)
      {:error, message} -> assign(socket, preview: nil, error: message)
    end
  end

  defp commit(%{assigns: %{plan: plan, preview: preview}} = socket)
       when is_map(plan) and is_map(preview) do
    args = %{
      "decisions" => decisions_payload(socket),
      "plan_token" => plan.plan_token,
      "proof" => preview.proof,
      "commit_digest" => preview.commit_digest,
      "expected_consent_revision" => plan.expected_consent_revision
    }

    case call(socket, "profile.commit", args) do
      {:ok, result} ->
        send(self(), {:consent_granted, socket.assigns.ref, result})
        assign(socket, busy: false, error: nil)

      {:error, message} ->
        # A conflict means the world moved under the sheet — re-plan so
        # the operator decides against what is true now, never against
        # what they were shown a minute ago.
        socket
        |> assign(busy: false, error: message, plan: nil, preview: nil)
        |> load_plan(socket.assigns.ref)
    end
  end

  defp commit(socket), do: assign(socket, error: "Nothing to grant yet")

  defp decisions_payload(socket) do
    bindings =
      Enum.map(socket.assigns.decisions, fn {need, entry_id} ->
        %{"need" => need, "entry_id" => entry_id}
      end)

    %{"ref" => socket.assigns.ref, "bindings" => bindings}
  end

  # The socket carries the operator's :oidc context, which is what makes
  # this surface able to consent at all (§4.1).
  defp call(socket, tool_action, args) do
    MCPHelpers.call_tool(socket, tool_action, args)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="consent-sheet" id={"consent-sheet-#{@id}"}>
      <header class="consent-sheet__header">
        <h2>{title(@plan)}</h2>
        <p :if={@plan} class="consent-sheet__subtitle">{@ref}</p>
      </header>

      <p :if={@error} class="consent-sheet__error" role="alert">{@error}</p>

      <div :if={@plan}>
        <section :if={@plan[:shape_diff] not in [nil, []]} class="consent-sheet__delta">
          <h3>What changed</h3>
          <ul>
            <li :for={entry <- @plan.shape_diff}>
              <strong>{entry.capability}</strong>
              <span :if={entry.added != []}>now wants {Enum.join(entry.added, ", ")}</span>
              <span :if={entry.removed != []}>no longer needs {Enum.join(entry.removed, ", ")}</span>
            </li>
          </ul>
        </section>

        <section class="consent-sheet__needs">
          <h3>Connections</h3>
          <p :if={@plan.needs == []} class="consent-sheet__empty">
            This app asks for no credentials.
          </p>

          <div :for={need <- @plan.needs} class="consent-sheet__need">
            <div class="consent-sheet__need-reason">{need.reason}</div>

            <div class="consent-sheet__choices">
              <button
                :for={candidate <- @plan.candidates}
                type="button"
                phx-click="pick_connection"
                phx-target={@myself}
                phx-value-need={need.need}
                phx-value-entry_id={candidate.id}
                class={choice_class(@decisions, need.need, candidate.id)}
              >
                {candidate.name}
                <span class="consent-sheet__fields">
                  Gets: {fields_label(candidate)}
                </span>
              </button>

              <button
                type="button"
                phx-click="clear_connection"
                phx-target={@myself}
                phx-value-need={need.need}
                class="consent-sheet__choice"
              >
                No connection
              </button>
            </div>
          </div>
        </section>

        <section :if={@plan.caps} class="consent-sheet__caps">
          <h3>Also allowed</h3>
          <ul>
            <li :if={egress(@plan) != []}>Talks to {Enum.join(egress(@plan), ", ")}</li>
            <li :if={tools(@plan) != []}>Uses {length(tools(@plan))} host tools</li>
            <li>Keeps its own private storage</li>
          </ul>
        </section>

        <section :if={@preview} class="consent-sheet__summary">
          <h3>You are approving</h3>
          <ul>
            <li :for={line <- @preview.summary}>{line}</li>
          </ul>
          <p class="consent-sheet__note">
            Connections are sealed at rest. A component only ever receives the
            fields listed above.
          </p>
        </section>

        <footer class="consent-sheet__actions">
          <button type="button" phx-click="cancel" phx-target={@myself} class="btn-secondary">
            Cancel
          </button>
          <button
            type="button"
            phx-click="commit"
            phx-target={@myself}
            disabled={is_nil(@preview) or @busy}
            class="btn-primary"
          >
            {commit_label(@plan)}
          </button>
        </footer>
      </div>
    </div>
    """
  end

  defp title(nil), do: "Loading…"
  defp title(%{expected_consent_revision: 0}), do: "Grant this app"
  defp title(%{expected_consent_revision: n}), do: "Update this grant (consent rev #{n})"

  defp commit_label(%{expected_consent_revision: 0}), do: "Grant"
  defp commit_label(_plan), do: "Approve changes"

  defp choice_class(decisions, need, entry_id) do
    if Map.get(decisions, need) == entry_id,
      do: "consent-sheet__choice consent-sheet__choice--selected",
      else: "consent-sheet__choice"
  end

  defp fields_label(%{field_names: []}), do: "nothing yet"
  defp fields_label(%{field_names: fields}), do: Enum.join(fields, ", ")
  defp fields_label(_), do: "nothing yet"

  defp egress(plan), do: get_in(plan, [:caps, "egress", "domains"]) || []
  defp tools(plan), do: get_in(plan, [:caps, "tools"]) || []
end
