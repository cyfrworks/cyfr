# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponent do
  @moduledoc """
  The consent walk a grant prompt shows: the body of the system layer's
  `:grant` prompt (`PrismWeb.SystemLayer`), drawn nowhere else, since only
  the system layer is never covered.

  It shows what a component asks for and what the person chooses: the
  vault entry each credential need is bound to, picked here and previewed
  again after each pick; the warnings, with a way to add a vault entry;
  what changed since the last grant; what else the component is allowed;
  and the summary the person approves. Credentials are sealed at rest; a
  component receives only the fields of the entries bound here.

  It starts from the walk the prompt arrived with (`walk`: the plan as
  `profile.plan` answers it, its preview and the decisions), so opening
  it reads nothing; given none, it plans `ref` itself. Each walk it makes
  goes to its layer (`layer`, the prompt `prompt_id`) as `walk:` — the
  plan, the preview of exactly the decisions it holds (`nil` while one
  is read or when none could be), and those decisions with their
  bindings. When the person confirms, the layer asks the sheet (`confirm:
  prompt_id`), and the sheet hands it the walk as it stands then, after
  every pick that came before the confirm, as `commit:`: that is the walk
  the layer commits.
  Told to plan again (`replan: true`), after a commit that consumed the
  plan's token, it plans and previews the same choices again.
  """

  use PrismWeb, :live_component

  alias PrismWeb.Ops

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       plan: nil,
       preview: nil,
       decisions: %{},
       error: nil,
       layer: nil,
       started: false
     )}
  end

  @impl true
  def update(%{replan: true}, socket) do
    {:noreply, socket} =
      CyfrWeb.ContextGuard.guard(socket, fn socket ->
        {:noreply, socket |> assign(plan: nil, preview: nil) |> load_plan() |> tell_layer()}
      end)

    {:ok, socket}
  end

  # The person confirmed the grant prompt `prompt_id`: the layer is handed
  # the walk as it stands now, after every pick that came before the
  # confirm, and commits exactly that. Reads nothing.
  def update(%{confirm: prompt_id}, socket) do
    case socket.assigns do
      %{layer: layer, prompt_id: ^prompt_id} when is_binary(layer) ->
        send_update(PrismWeb.SystemLayer, id: layer, commit: walk_now(socket))

      _other ->
        :ok
    end

    {:ok, socket}
  end

  # The walk starts once, from the prompt's; after that the sheet's own
  # walk is the one its layer holds, and the prompt's is not read again.
  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:walk]))

    case {socket.assigns.started, Map.get(assigns, :walk)} do
      {false, %{plan: %{plan_token: _} = plan} = walk} ->
        {:ok, socket |> assign(:started, true) |> from_walk(plan, walk)}

      {false, _no_walk} ->
        {:noreply, socket} =
          CyfrWeb.ContextGuard.guard(socket, fn socket ->
            {:noreply, socket |> assign(:started, true) |> load_plan() |> tell_layer()}
          end)

        {:ok, socket}

      _walking ->
        {:ok, socket}
    end
  end

  # The walk the prompt arrived with: its plan and preview, and the entry
  # each need was bound to.
  defp from_walk(socket, plan, walk) do
    bindings =
      case walk do
        %{decisions: %{"bindings" => bindings}} when is_list(bindings) -> bindings
        _none -> []
      end

    decisions =
      for %{"need" => need, "entry_id" => entry_id} <- bindings, into: %{}, do: {need, entry_id}

    assign(socket, plan: plan, preview: Map.get(walk, :preview), decisions: decisions, error: nil)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("pick_entry", %{"need" => need, "entry_id" => entry_id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      decisions = Map.put(socket.assigns.decisions, need, entry_id)

      {:noreply,
       socket |> assign(decisions: decisions, preview: nil) |> preview() |> tell_layer()}
    end)
  end

  def handle_event("clear_entry", %{"need" => need}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      decisions = Map.delete(socket.assigns.decisions, need)

      {:noreply,
       socket |> assign(decisions: decisions, preview: nil) |> preview() |> tell_layer()}
    end)
  end

  # ---------------------------------------------------------------------------
  # The walk
  # ---------------------------------------------------------------------------

  defp load_plan(socket) do
    case Ops.call_tool(socket, "profile/plan", %{"ref" => socket.assigns.ref}) do
      {:ok, plan} ->
        socket |> assign(plan: plan, error: nil) |> preview()

      {:error, reason} ->
        assign(socket, plan: nil, preview: nil, error: Ops.error_message(reason))
    end
  end

  defp preview(%{assigns: %{plan: nil}} = socket), do: socket

  defp preview(socket) do
    case Ops.call_tool(socket, "profile/preview", %{"decisions" => decisions_payload(socket)}) do
      {:ok, preview} -> assign(socket, preview: preview, error: nil)
      {:error, reason} -> assign(socket, preview: nil, error: Ops.error_message(reason))
    end
  end

  # The layer holds what its confirmation commits: told each walk, the
  # preview of exactly these decisions or none.
  defp tell_layer(%{assigns: %{layer: layer}} = socket) when is_binary(layer) do
    send_update(PrismWeb.SystemLayer, id: layer, walk: walk_now(socket))
    socket
  end

  defp tell_layer(socket), do: socket

  defp walk_now(socket) do
    %{
      prompt: socket.assigns[:prompt_id],
      plan: socket.assigns.plan,
      preview: socket.assigns.preview,
      decisions: decisions_payload(socket)
    }
  end

  defp decisions_payload(socket) do
    bindings =
      socket.assigns.decisions
      |> Enum.sort()
      |> Enum.map(fn {need, entry_id} -> %{"need" => need, "entry_id" => entry_id} end)

    %{"ref" => socket.assigns.ref, "bindings" => bindings}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="consent-sheet space-y-3 text-sm" id={"consent-sheet-#{@id}"}>
      <header class="consent-sheet__header">
        <h3 class="font-medium">{title(@plan)}</h3>
        <!-- Which furnace the grant lands in: a vault entry is the athanor's,
             and binding one in the wrong chat is the easy mistake. -->
        <p :if={@plan} class="consent-sheet__subtitle text-gray-400">
          {@ref}{if assigns[:athanor_name], do: " · in #{@athanor_name}"}
        </p>
      </header>

      <p :if={@error} class="consent-sheet__error" role="alert">{@error}</p>

      <div :if={@plan} class="space-y-3">
        <section :if={warnings(@plan) != []} class="consent-sheet__warnings">
          <p :for={warning <- warnings(@plan)}>{warning}</p>
          <p :if={assigns[:athanor_route]}>
            <.link
              navigate={PrismWeb.Focus.path(@athanor_route, "/vault")}
              class="consent-sheet__link underline"
            >
              Add a vault entry
            </.link>
            first, then come back here.
          </p>
        </section>

        <section :if={@plan[:shape_diff] not in [nil, []]} class="consent-sheet__delta">
          <h4 class="font-medium">What changed</h4>
          <ul>
            <li :for={entry <- @plan.shape_diff}>
              <strong>{entry.capability}</strong>
              <span :if={entry.added != []}>now wants {Enum.join(entry.added, ", ")}</span>
              <span :if={entry.removed != []}>no longer needs {Enum.join(entry.removed, ", ")}</span>
            </li>
          </ul>
        </section>

        <section class="consent-sheet__needs" data-test="grant-needs">
          <h4 class="font-medium">Vault entries</h4>
          <p :if={needs(@plan) == []} class="consent-sheet__empty">
            This app asks for no credentials.
          </p>

          <div :for={need <- needs(@plan)} class="consent-sheet__need" data-need={need.need}>
            <div class="consent-sheet__need-reason">{need.reason}</div>

            <div class="consent-sheet__choices flex flex-wrap gap-2">
              <button
                :for={candidate <- candidates(@plan)}
                type="button"
                phx-click="pick_entry"
                phx-target={@myself}
                phx-value-need={need.need}
                phx-value-entry_id={candidate.id}
                aria-pressed={to_string(Map.get(@decisions, need.need) == candidate.id)}
                data-test="grant-pick"
                class={choice_class(@decisions, need.need, candidate.id)}
              >
                {candidate.name}
                <span class="consent-sheet__fields">
                  Gets: {fields_label(candidate)}
                </span>
              </button>

              <button
                type="button"
                phx-click="clear_entry"
                phx-target={@myself}
                phx-value-need={need.need}
                aria-pressed={to_string(not Map.has_key?(@decisions, need.need))}
                class="consent-sheet__choice"
              >
                No entry
              </button>
            </div>
          </div>
        </section>

        <section :if={@plan[:caps]} class="consent-sheet__caps">
          <h4 class="font-medium">Also allowed</h4>
          <ul>
            <li :if={egress(@plan) != []}>Talks to {Enum.join(egress(@plan), ", ")}</li>
            <li :if={tools(@plan) != []}>Uses {length(tools(@plan))} host tools</li>
            <li>Keeps its own private storage</li>
            <li :if={component_writes?(@plan)}>
              Can rewrite this athanor's own (local) components — a rewritten
              component re-registers on the next scan and runs at the same
              version
            </li>
          </ul>
        </section>

        <section :if={@preview} class="consent-sheet__summary" data-test="grant-summary">
          <h4 class="font-medium">You are approving</h4>
          <ul class="list-disc pl-5">
            <li :for={line <- @preview.summary}>{line}</li>
          </ul>
          <p class="consent-sheet__note text-gray-400">
            Vault entries are sealed at rest. A component only ever receives the
            fields listed above.
          </p>
        </section>
      </div>
    </div>
    """
  end

  defp title(nil), do: "Loading…"
  defp title(%{expected_consent_revision: 0}), do: "Grant this app"
  defp title(%{expected_consent_revision: n}), do: "Update this grant (consent rev #{n})"
  defp title(_plan), do: "Grant this app"

  defp choice_class(decisions, need, entry_id) do
    if Map.get(decisions, need) == entry_id,
      do: "consent-sheet__choice consent-sheet__choice--selected",
      else: "consent-sheet__choice"
  end

  defp fields_label(%{field_names: []}), do: "nothing yet"
  defp fields_label(%{field_names: fields}), do: Enum.join(fields, ", ")
  defp fields_label(_), do: "nothing yet"

  defp needs(plan), do: Map.get(plan, :needs) || []
  defp candidates(plan), do: Map.get(plan, :candidates) || []
  defp egress(plan), do: get_in(plan, [:caps, "egress", "domains"]) || []
  defp tools(plan), do: get_in(plan, [:caps, "tools"]) || []

  # A components/ write grant is code-mutation power on the local
  # namespace (pulled publishers are refused at the storage boundary) —
  # said in the sheet, so the operator grants it knowingly.
  defp component_writes?(plan) do
    storage = get_in(plan, [:caps, "storage"]) || %{}
    paths = storage["paths"] || []
    actions = storage["actions"] || []

    writes? = Enum.any?(actions, &(&1 in ["write", "append", "delete"]))

    reaches_components? =
      Enum.any?(paths, &(&1 == "*" or String.starts_with?(&1, "components")))

    writes? and reaches_components?
  end

  defp warnings(plan), do: plan[:warnings] || plan["warnings"] || []
end
