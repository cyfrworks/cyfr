# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponent do
  @moduledoc """
  The consent walk a grant prompt shows: the body of the system layer's
  `:grant` prompt (`PrismWeb.SystemLayer`), drawn nowhere else, since only
  the system layer is never covered.

  It draws the typed rows of a `Prima.ConsentPreview` itself, grouped by
  kind in its own words: every row the preview answers, of every kind, a
  tincture's frame, streams, cards and system actions included, and never
  a sentence the home wrote. Before a preview is read it draws the plan's
  rows, the ask. A plan whose closure is unresolved is drawn as that,
  naming what is missing, with no rows and nothing to commit.

  The person's choices are submitted exactly, never as a category:

    * the vault entry each credential need is bound to;
    * narrowing, per node, for each kind its enforcement point can check:
      the egress domains, methods, schemes and private ranges and the
      storage actions as exact values, the storage paths through a picker
      over `file.list` inside each asked folder, the tools per action (a
      wildcard ask whole or none), and the limits, each capped at the ask
      and sent only when lowered;
    * the origins the grant admits: `interactive` is always named, and
      "also for agents and scripts" (`programmatic`), "also on a
      schedule" and "also from webhooks" are each a visible choice,
      unticked on a first grant. A re-grant starts from the origins its
      head admits, so it never quietly drops one.

  What changed since the head (the plan's `shape_diff`) is worded against
  the head as the person narrowed it: what the component asks for that
  the grant does not give, and what it no longer asks for. The person's
  own narrowing never reads as the component widening.

  It starts from the walk the prompt arrived with (`walk`: the plan as
  `profile.plan` answers it, its preview and the decisions), so opening
  it reads nothing; given none, it plans `ref` itself. Each walk it makes
  goes to its layer (`layer`, the prompt `prompt_id`) as `walk:` — the
  plan, the preview of exactly the decisions it holds (`nil` while one
  is read or when none could be), and those decisions. When the person
  confirms, the layer asks the sheet (`confirm: prompt_id`), and the
  sheet hands it the walk as it stands then, after every choice that came
  before the confirm, as `commit:`: that is the walk the layer commits.
  Told to plan again (`replan: true`), after a commit that consumed the
  plan's token, it plans and previews the same choices again.
  """

  use PrismWeb, :live_component

  alias PrismWeb.Ops

  @interactive "interactive"
  @extra_origins [
    {"programmatic", "Also for agents and scripts"},
    {"schedule", "Also on a schedule"},
    {"webhook", "Also from webhooks"}
  ]
  @set_fields %{
    "egress" => ~w(domains methods schemes private_ips),
    "storage" => ~w(paths actions)
  }
  @integer_limits ~w(max_memory_bytes max_request_size max_response_size max_concurrent_tasks)
  @duration_limits ~w(timeout batch_timeout)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       plan: nil,
       preview: nil,
       decisions: %{},
       origins: nil,
       subset: %{},
       label: nil,
       picker: nil,
       error: nil,
       previewed: nil,
       refusal: nil,
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
  # the walk as it stands now, after every choice that came before the
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

  # The walk the prompt arrived with: its plan and preview, the entry each
  # need was bound to, the origins and narrowing it was previewed with.
  defp from_walk(socket, plan, walk) do
    decisions = Map.get(walk, :decisions) || %{}

    bindings =
      case decisions do
        %{"bindings" => bindings} when is_list(bindings) -> bindings
        _none -> []
      end

    entries =
      for %{"need" => need, "entry_id" => entry_id} <- bindings, into: %{}, do: {need, entry_id}

    socket
    |> assign(
      plan: plan,
      preview: Map.get(walk, :preview),
      decisions: entries,
      origins: origins_of(decisions["origins"], plan),
      subset: subset_of(decisions["subset"]),
      label: label_of(decisions["label"]) || socket.assigns.label,
      error: nil
    )
    |> previewed()
  end

  defp origins_of(origins, _plan) when is_list(origins) and origins != [], do: in_order(origins)
  defp origins_of(_none, %{head_origins: [_ | _] = origins}), do: in_order(origins)
  defp origins_of(_none, _plan), do: [@interactive]

  defp subset_of(subset) when is_map(subset), do: subset
  defp subset_of(_none), do: %{}

  defp label_of(label) when is_binary(label) and label != "", do: label
  defp label_of(_none), do: nil

  # The origins named, `interactive` always among them, in the enum's order.
  defp in_order(origins) do
    named = [@interactive | Enum.map(origins, &to_string/1)]
    Enum.filter(Prima.Origin.spellings(), &(&1 in named))
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("pick_entry", %{"need" => need, "entry_id" => entry_id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:decisions, Map.put(socket.assigns.decisions, need, entry_id))
       |> walk_again({:need, need})}
    end)
  end

  def handle_event("clear_entry", %{"need" => need}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:decisions, Map.delete(socket.assigns.decisions, need))
       |> walk_again({:need, need})}
    end)
  end

  def handle_event("toggle_origin", %{"origin" => origin}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      if origin in Enum.map(@extra_origins, &elem(&1, 0)) do
        origins = socket.assigns.origins || [@interactive]

        origins =
          if origin in origins, do: List.delete(origins, origin), else: [origin | origins]

        {:noreply, socket |> assign(:origins, in_order(origins)) |> walk_again(:origins)}
      else
        {:noreply, socket}
      end
    end)
  end

  # One value of a set the enforcement point narrows: chosen or not, from
  # the values the ask names. Anything else is not a choice the sheet
  # offered and changes nothing.
  def handle_event(
        "toggle_value",
        %{"node" => node, "kind" => kind, "field" => field, "value" => value},
        socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      asked = asked_values(socket.assigns.plan, node, kind, field)
      granted = granted_values(socket, node, kind, field)

      if field in Map.get(@set_fields, kind, []) and (value in asked or value in granted) do
        chosen =
          if value in granted,
            do: List.delete(granted, value),
            else: Enum.filter(asked, &(&1 in [value | granted])) ++ (granted -- asked)

        subset = put_set(socket.assigns.subset, node, kind, field, chosen, asked)
        {:noreply, socket |> assign(:subset, subset) |> walk_again({kind, node})}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("toggle_tool", %{"node" => node, "value" => value}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      asked = asked_tools(socket.assigns.plan, node)

      if value in asked and asked != wildcard() do
        granted = granted_tools(socket, node)

        chosen =
          if value in granted,
            do: List.delete(granted, value),
            else: Enum.filter(asked, &(&1 in [value | granted]))

        subset = put_tools(socket.assigns.subset, node, chosen, asked)
        {:noreply, socket |> assign(:subset, subset) |> walk_again({"tools", node})}
      else
        {:noreply, socket}
      end
    end)
  end

  # A wildcard ask is granted whole or not at all: no tool, or every one.
  def handle_event("toggle_every_tool", %{"node" => node}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      if asked_tools(socket.assigns.plan, node) == wildcard() do
        chosen = if granted_tools(socket, node) == [], do: wildcard(), else: []
        subset = put_tools(socket.assigns.subset, node, chosen, wildcard())
        {:noreply, socket |> assign(:subset, subset) |> walk_again({"tools", node})}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("set_limits", %{"node" => node, "limits" => limits}, socket)
      when is_map(limits) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with %{} = asked <- asked_limits(socket.assigns.plan, node),
           {:ok, record} <- lowered(limits, asked) do
        subset = put_record(socket.assigns.subset, node, "limits", record)
        {:noreply, socket |> assign(:subset, subset) |> walk_again({"limits", node})}
      else
        {:error, sentence} -> {:noreply, refuse(socket, {"limits", node}, sentence)}
        nil -> {:noreply, socket}
      end
    end)
  end

  # The trusted picker: a folder inside one the ask names, listed through
  # `file.list` under the person's own context.
  def handle_event("open_picker", %{"node" => node, "path" => path}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      asked = asked_values(socket.assigns.plan, node, "storage", "paths")
      folder = Prima.ComponentPath.door_path(path)

      if folder != nil and inside?(folder, asked) do
        case Ops.call_tool(socket, "file/list", %{"path" => String.trim_trailing(folder, "/")}) do
          {:ok, %{entries: entries}} ->
            {:noreply,
             assign(socket, picker: %{node: node, path: folder, entries: entries}, error: nil)}

          {:ok, _other} ->
            {:noreply, assign(socket, picker: %{node: node, path: folder, entries: []})}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:picker, nil)
             |> refuse({"storage", node}, Ops.error_message(reason))}
        end
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, assign(socket, :picker, nil)}

  # A path the person picked: inside the ask, in the storage door's
  # spelling (`Prima.ComponentPath.door_path/1`), so the call it is meant
  # to cover matches it. It takes the place of what it narrows, the asked
  # folder it sits in.
  def handle_event("pick_path", %{"node" => node, "path" => path}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      asked = asked_values(socket.assigns.plan, node, "storage", "paths")
      picked = Prima.ComponentPath.door_path(path)

      if picked != nil and inside?(picked, asked) do
        granted = granted_values(socket, node, "storage", "paths")
        kept = Enum.reject(granted, &(&1 != picked and inside?(picked, [&1])))
        chosen = Enum.uniq(kept ++ [picked])
        subset = put_set(socket.assigns.subset, node, "storage", "paths", chosen, asked)

        {:noreply, socket |> assign(picker: nil, subset: subset) |> walk_again({"storage", node})}
      else
        {:noreply, socket}
      end
    end)
  end

  # Every choice previews the walk again and hands it to the layer. Called
  # inside the event's own guard, naming the control that made the choice
  # (`at`), beside which a refusal is shown.
  defp walk_again(socket, at), do: socket |> preview(at) |> tell_layer()

  # What the home last previewed: the choices and the preview of exactly
  # those, put back whole when it refuses a later choice.
  defp previewed(%{assigns: %{preview: %{} = preview}} = socket) do
    assign(socket, :previewed, %{
      decisions: socket.assigns.decisions,
      origins: socket.assigns.origins,
      subset: socket.assigns.subset,
      preview: preview
    })
  end

  defp previewed(socket), do: socket

  # A refusal beside the control that caused it, the walk left as it was.
  defp refuse(socket, at, message), do: assign(socket, :refusal, %{at: at, message: message})

  # ---------------------------------------------------------------------------
  # Narrowing
  # ---------------------------------------------------------------------------

  defp wildcard, do: Prima.ConsentPreview.Row.wildcard()

  defp ask_row(plan, kind, node),
    do: Enum.find(plan_rows(plan), &(&1["kind"] == kind and &1["node"] == node))

  defp plan_rows(%{rows: rows}) when is_list(rows), do: rows
  defp plan_rows(_plan), do: []

  defp asked_values(plan, node, kind, field) do
    case ask_row(plan, kind, node) do
      %{"values" => %{^field => values}} when is_list(values) -> values
      _none -> []
    end
  end

  defp asked_tools(plan, node), do: asked_values(plan, node, "tools", "tools")

  defp asked_limits(plan, node) do
    case ask_row(plan, "limits", node) do
      %{"values" => %{} = limits} -> limits
      _none -> nil
    end
  end

  defp granted_values(socket, node, kind, field) do
    case get_in(socket.assigns.subset, [node, kind, field]) do
      values when is_list(values) -> values
      nil -> asked_values(socket.assigns.plan, node, kind, field)
    end
  end

  defp granted_tools(socket, node) do
    case get_in(socket.assigns.subset, [node, "tools"]) do
      tools when is_list(tools) -> tools
      nil -> asked_tools(socket.assigns.plan, node)
    end
  end

  # A field narrowed back to its whole ask names nothing and is dropped,
  # so the decision is the same input as one that never narrowed it.
  defp put_set(subset, node, kind, field, chosen, asked) do
    record = get_in(subset, [node, kind]) || %{}

    record =
      if Enum.sort(chosen) == Enum.sort(asked),
        do: Map.delete(record, field),
        else: Map.put(record, field, chosen)

    put_record(subset, node, kind, record)
  end

  defp put_tools(subset, node, chosen, asked) do
    node_record = Map.get(subset, node, %{})

    node_record =
      if Enum.sort(chosen) == Enum.sort(asked),
        do: Map.delete(node_record, "tools"),
        else: Map.put(node_record, "tools", chosen)

    put_node(subset, node, node_record)
  end

  defp put_record(subset, node, kind, record) when record == %{},
    do: put_node(subset, node, Map.delete(Map.get(subset, node, %{}), kind))

  defp put_record(subset, node, kind, record),
    do: put_node(subset, node, Map.put(Map.get(subset, node, %{}), kind, record))

  defp put_node(subset, node, record) when record == %{}, do: Map.delete(subset, node)
  defp put_node(subset, node, record), do: Map.put(subset, node, record)

  # The limits the person lowered, each at most its ask; a field left at
  # its ask, or blank, is not sent.
  defp lowered(limits, asked) do
    limits
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {field, raw}, {:ok, acc} ->
      case lower(field, String.trim(to_string(raw)), asked) do
        :keep -> {:cont, {:ok, acc}}
        {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _sentence} = error -> {:halt, error}
      end
    end)
  end

  defp lower(_field, "", _asked), do: :keep

  defp lower(field, raw, asked) when field in @integer_limits do
    with {value, ""} <- Integer.parse(raw),
         ask when is_integer(ask) <- asked[field] do
      cond do
        value == ask -> :keep
        value > ask or value < 0 -> {:error, "#{limit_label(field)} can be at most #{ask}."}
        true -> {:ok, {field, value}}
      end
    else
      _ -> {:error, "#{limit_label(field)} must be a whole number."}
    end
  end

  defp lower(field, raw, asked) when field in @duration_limits do
    with {:ok, ms} <- Prima.Limits.parse_duration(raw),
         ask when is_binary(ask) <- asked[field],
         {:ok, ask_ms} <- Prima.Limits.parse_duration(ask) do
      cond do
        ms == ask_ms -> :keep
        ms > ask_ms -> {:error, "#{limit_label(field)} can be at most #{ask}."}
        true -> {:ok, {field, raw}}
      end
    else
      _ -> {:error, "#{limit_label(field)} must be a duration, like 30s or 5m."}
    end
  end

  defp lower("rate_requests", raw, %{"rate_limit" => %{"requests" => ask} = rate}) do
    case Integer.parse(raw) do
      {^ask, ""} ->
        :keep

      {value, ""} when value >= 0 and value < ask ->
        {:ok, {"rate_limit", %{rate | "requests" => value}}}

      {_value, ""} ->
        {:error, "The rate can be at most #{ask} requests."}

      _ ->
        {:error, "The rate must be a whole number of requests."}
    end
  end

  defp lower(_field, _raw, _asked), do: :keep

  defp inside?(path, asked), do: Prima.ComponentPath.path_granted?(path, asked)

  # ---------------------------------------------------------------------------
  # The walk
  # ---------------------------------------------------------------------------

  defp load_plan(socket) do
    args =
      %{"ref" => socket.assigns.ref}
      |> Prima.MapUtil.put_present("label", socket.assigns.label)

    case Ops.call_tool(socket, "profile/plan", args) do
      {:ok, plan} ->
        socket
        |> assign(plan: plan, error: nil)
        |> assign(:origins, socket.assigns.origins || origins_of(nil, plan))
        |> preview()

      {:error, reason} ->
        assign(socket, plan: nil, preview: nil, error: Ops.error_message(reason))
    end
  end

  # A plan whose closure is unresolved has nothing to preview: the preview
  # and the commit refuse it, and the sheet names what is missing instead.
  #
  # A choice the home refuses puts back the last walk that previewed, its
  # choices and its preview, and says why beside the control that made it
  # (`at`): the person keeps every control and chooses again, and the layer
  # is never left holding a preview of other choices than its own. Beyond
  # offering only what the ask names, the sheet checks nothing: what a
  # narrowing may be is the home's to decide.
  defp preview(socket, at \\ nil)
  defp preview(%{assigns: %{plan: nil}} = socket, _at), do: socket
  defp preview(%{assigns: %{plan: %{unresolved: %{}}}} = socket, _at), do: socket

  defp preview(socket, at) do
    case Ops.call_tool(socket, "profile/preview", %{"decisions" => decisions_payload(socket)}) do
      {:ok, preview} ->
        socket |> assign(preview: preview, error: nil, refusal: nil) |> previewed()

      {:error, reason} ->
        case {at, socket.assigns.previewed} do
          {at, %{} = last} when not is_nil(at) ->
            socket
            |> assign(
              decisions: last.decisions,
              origins: last.origins,
              subset: last.subset,
              preview: last.preview
            )
            |> refuse(at, Ops.error_message(reason))

          _nothing_previewed ->
            assign(socket, preview: nil, error: Ops.error_message(reason))
        end
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

    %{
      "ref" => socket.assigns.ref,
      "bindings" => bindings,
      "origins" => socket.assigns.origins || [@interactive]
    }
    |> Prima.MapUtil.put_present("label", socket.assigns.label)
    |> then(fn payload ->
      if socket.assigns.subset == %{},
        do: payload,
        else: Map.put(payload, "subset", socket.assigns.subset)
    end)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:shown, shown_rows(assigns.plan, assigns.preview))
      |> assign(:approving?, approving?(assigns.preview))
      |> assign(:extra_origins, @extra_origins)
      |> assign(:origins_now, assigns.origins || [@interactive])

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

      <section
        :if={unresolved(@plan)}
        class="consent-sheet__unresolved"
        role="alert"
        data-test="grant-unresolved"
      >
        <p class="font-medium">This app cannot be granted yet.</p>
        <p>{unresolved_sentence(unresolved(@plan))}</p>
      </section>

      <div :if={@plan && !unresolved(@plan)} class="space-y-3">
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

        <section
          :if={(@plan[:shape_diff] || []) != []}
          class="consent-sheet__delta"
          data-test="grant-delta"
        >
          <h4 class="font-medium">What changed since your grant</h4>
          <ul>
            <li :for={entry <- @plan.shape_diff}>
              <strong>{capability_label(entry.capability)}</strong>
              <span :if={entry.added != []}>
                asks for {Enum.join(entry.added, ", ")}, which your grant does not give
              </span>
              <span :if={entry.removed != []}>
                no longer asks for {Enum.join(entry.removed, ", ")}
              </span>
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
            <.refusal refusal={@refusal} at={{:need, need.need}} />
          </div>
        </section>

        <section class="consent-sheet__origins" data-test="grant-origins">
          <h4 class="font-medium">When it may run</h4>
          <label class="consent-sheet__origin flex items-center gap-2">
            <input type="checkbox" checked disabled data-origin="interactive" />
            When you use it (interactive)
          </label>
          <label
            :for={{origin, text} <- @extra_origins}
            class="consent-sheet__origin flex items-center gap-2"
          >
            <input
              type="checkbox"
              phx-click="toggle_origin"
              phx-target={@myself}
              phx-value-origin={origin}
              checked={origin in @origins_now}
              data-origin={origin}
            />
            {text} ({origin})
          </label>
          <.refusal refusal={@refusal} at={:origins} />
        </section>

        <section class="consent-sheet__rows space-y-2" data-test="grant-rows">
          <h4 class="font-medium">
            {if @approving?, do: "You are approving", else: "This app asks for"}
          </h4>
          <p :if={@shown == []} class="consent-sheet__empty">Nothing beyond its own limits.</p>
          <p :if={component_writes?(@shown)} class="consent-sheet__warning" role="note">
            Can rewrite this athanor's own (local) components — a rewritten component
            re-registers on the next scan and runs at the same version.
          </p>

          <div :for={{kind, rows} <- @shown} class="consent-sheet__kind" data-kind={kind}>
            <h5 class="text-xs font-semibold uppercase tracking-wider text-gray-400">
              {kind_heading(kind)}
            </h5>
            <.row
              :for={row <- rows}
              row={row}
              ask={ask_row(@plan, kind, row["node"])}
              myself={@myself}
              approving?={@approving?}
              refusal={@refusal}
            />
          </div>

          <p :if={@approving?} class="consent-sheet__admits" data-test="grant-admits">
            Admits runs started: {Enum.map_join(@preview.origins, ", ", &origin_label/1)}.
          </p>
          <p class="consent-sheet__note text-gray-400">
            Vault entries are sealed at rest. A component only ever receives the
            fields listed above.
          </p>
        </section>

        <section :if={@picker} class="consent-sheet__picker" data-test="grant-picker">
          <h4 class="font-medium">Choose inside {@picker.path}</h4>
          <ul>
            <li :for={entry <- @picker.entries} class="flex items-center gap-2">
              <span class="font-mono">{entry.name}{if entry.kind == :dir, do: "/"}</span>
              <button
                :if={entry.kind == :dir}
                type="button"
                phx-click="open_picker"
                phx-target={@myself}
                phx-value-node={@picker.node}
                phx-value-path={@picker.path <> entry.name <> "/"}
                class="consent-sheet__choice"
              >
                Open
              </button>
              <button
                type="button"
                phx-click="pick_path"
                phx-target={@myself}
                phx-value-node={@picker.node}
                phx-value-path={@picker.path <> entry.name <> if(entry.kind == :dir, do: "/", else: "")}
                class="consent-sheet__choice"
              >
                Choose
              </button>
            </li>
          </ul>
          <p :if={@picker.entries == []} class="consent-sheet__empty">This folder is empty.</p>
          <button
            type="button"
            phx-click="close_picker"
            phx-target={@myself}
            class="consent-sheet__choice"
          >
            Done
          </button>
        </section>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :ask, :map, default: nil
  attr :myself, :any, required: true
  attr :approving?, :boolean, required: true
  attr :refusal, :map, default: nil

  # One row, in the sheet's own words, every value it carries shown, with
  # the node it is for, and the home's refusal of a choice made on it.
  defp row(%{row: %{"kind" => "credential"}} = assigns) do
    ~H"""
    <div class="consent-sheet__row" data-row="credential" data-node={@row["node"]}>
      <span class="font-medium">{@row["values"]["name"]}</span>
      {edge_label(@row["node"], @row["values"]["edge"])}
      <span :if={@row["values"]["label"]}>
        — the key bound on its '{@row["values"]["label"]}' profile
      </span>
      <div>Fields: {list_label(@row["values"]["fields"], "none")}</div>
      <div>Scopes: {list_label(@row["values"]["scopes"], "none")}</div>
    </div>
    """
  end

  defp row(%{row: %{"kind" => kind}} = assigns) when kind in ["egress", "storage"] do
    assigns =
      assign(assigns,
        fields: Map.fetch!(@set_fields, kind),
        controls?: assigns.approving? and is_map(assigns.ask)
      )

    ~H"""
    <div class="consent-sheet__row" data-row={@row["kind"]} data-node={@row["node"]}>
      <.node_line row={@row} />
      <div :for={field <- @fields} class="consent-sheet__field" data-field={field}>
        <span class={if field == "private_ips", do: "font-semibold text-amber-300"}>
          {field_label(@row["kind"], field)}:
        </span>
        <span :if={choices(@row, @ask, field) == []}>none</span>
        <label :for={{value, on?} <- choices(@row, @ask, field)} class="consent-sheet__value">
          <input
            :if={@controls?}
            type="checkbox"
            phx-click="toggle_value"
            phx-target={@myself}
            phx-value-node={@row["node"]}
            phx-value-kind={@row["kind"]}
            phx-value-field={field}
            phx-value-value={value}
            checked={on?}
          />
          <span class="font-mono">{value}</span>
        </label>
        <span :if={@controls? and field == "paths"}>
          <button
            :for={folder <- folders(@ask)}
            type="button"
            phx-click="open_picker"
            phx-target={@myself}
            phx-value-node={@row["node"]}
            phx-value-path={folder}
            class="consent-sheet__choice"
          >
            Choose inside {folder}
          </button>
        </span>
      </div>
      <.refusal refusal={@refusal} at={{@row["kind"], @row["node"]}} />
    </div>
    """
  end

  defp row(%{row: %{"kind" => "tools"}} = assigns) do
    assigns =
      assign(assigns,
        controls?: assigns.approving? and is_map(assigns.ask),
        every?: wildcard_row?(assigns.ask) or wildcard_row?(assigns.row)
      )

    ~H"""
    <div class="consent-sheet__row" data-row="tools" data-node={@row["node"]}>
      <.node_line row={@row} />
      <div :if={@every?}>
        <label class="consent-sheet__value">
          <input
            :if={@controls?}
            type="checkbox"
            phx-click="toggle_every_tool"
            phx-target={@myself}
            phx-value-node={@row["node"]}
            checked={wildcard_row?(@row)}
          />
          <span>{if wildcard_row?(@row), do: "Every tool of the catalog (*)", else: "No tools"}</span>
        </label>
      </div>
      <div :if={not @every?}>
        <span :if={choices(@row, @ask, "tools") == []}>No tools</span>
        <label :for={{tool, on?} <- choices(@row, @ask, "tools")} class="consent-sheet__value">
          <input
            :if={@controls?}
            type="checkbox"
            phx-click="toggle_tool"
            phx-target={@myself}
            phx-value-node={@row["node"]}
            phx-value-value={tool}
            checked={on?}
          />
          <span class="font-mono">{tool}</span>
        </label>
      </div>
      <.refusal refusal={@refusal} at={{"tools", @row["node"]}} />
    </div>
    """
  end

  defp row(%{row: %{"kind" => "tool_servers"}} = assigns) do
    ~H"""
    <div class="consent-sheet__row" data-row="tool_servers" data-node={@row["node"]}>
      <.node_line row={@row} />
      <span class="font-medium">{@row["values"]["name"]}</span>
      <span class="font-mono text-xs text-gray-400">{@row["values"]["digest"]}</span>
      <div>Its tools matching: {list_label(@row["values"]["tool_patterns"], "none")}</div>
    </div>
    """
  end

  defp row(%{row: %{"kind" => "limits"}} = assigns) do
    assigns = assign(assigns, controls?: assigns.approving? and is_map(assigns.ask))

    ~H"""
    <div class="consent-sheet__row" data-row="limits" data-node={@row["node"]}>
      <.node_line row={@row} />
      <ul>
        <li :for={{field, value} <- limit_lines(@row["values"])} data-limit={field}>
          {limit_label(field)}: <span class="font-mono">{value}</span>
        </li>
      </ul>
      <form
        :if={@controls?}
        phx-submit="set_limits"
        phx-target={@myself}
        class="consent-sheet__limits"
      >
        <input type="hidden" name="node" value={@row["node"]} />
        <label :for={field <- lowerable(@ask)} class="block text-xs">
          {limit_label(field)} (at most {limit_value(field, @ask["values"])})
          <input
            type="text"
            name={"limits[#{field}]"}
            value={limit_value(field, @row["values"])}
            class="w-28 bg-transparent font-mono"
          />
        </label>
        <button type="submit" class="consent-sheet__choice">Lower the limits</button>
      </form>
      <.refusal refusal={@refusal} at={{"limits", @row["node"]}} />
    </div>
    """
  end

  defp row(%{row: %{"kind" => "frame"}} = assigns) do
    ~H"""
    <div class="consent-sheet__row" data-row="frame" data-node={@row["node"]}>
      <.node_line row={@row} />
      <div>May use: {list_label(@row["values"]["capabilities"], "no extra capability")}</div>
      <div>Placed: {@row["values"]["placement"] || "where the shell places it"}</div>
      <div>
        {if @row["values"]["background"],
          do: "Keeps running in the background when hidden",
          else: "Stops when hidden"}
      </div>
    </div>
    """
  end

  defp row(%{row: %{"kind" => "streams"}} = assigns) do
    ~H"""
    <div class="consent-sheet__row" data-row="streams" data-node={@row["node"]}>
      <.node_line row={@row} />
      <span class="font-mono">{@row["values"]["name"]}</span>
      {subject_label(@row["values"]["subject"])}
    </div>
    """
  end

  defp row(%{row: %{"kind" => "cards"}} = assigns) do
    ~H"""
    <div class="consent-sheet__row" data-row="cards" data-node={@row["node"]}>
      <.node_line row={@row} />
      <span class="font-medium">{@row["values"]["name"]}</span>
      <span :if={@row["values"]["component"]}>
        — from {@row["values"]["operation"]} of {@row["values"]["component"]} with
        <span class="font-mono">{Jason.encode!(@row["values"]["args"])}</span>
      </span>
      <span :if={!@row["values"]["component"]}>— static, from no component</span>
    </div>
    """
  end

  defp row(%{row: %{"kind" => "system_actions"}} = assigns) do
    ~H"""
    <div class="consent-sheet__row" data-row="system_actions" data-node={@row["node"]}>
      <.node_line row={@row} />
      <span class="font-mono">{Enum.join(@row["values"]["actions"], ", ")}</span>
    </div>
    """
  end

  attr :refusal, :map, default: nil
  attr :at, :any, required: true

  # The home's refusal of a choice, beside the control that made it.
  defp refusal(assigns) do
    ~H"""
    <p
      :if={match?(%{at: at} when at == @at, @refusal)}
      class="consent-sheet__refusal text-red-300"
      role="alert"
      data-test="grant-refusal"
    >
      {@refusal.message}
    </p>
    """
  end

  attr :row, :map, required: true

  defp node_line(assigns) do
    ~H"""
    <span class="text-xs text-gray-400">
      {@row["node"]}{if @row["narrowed"], do: " · narrowed by you"}
    </span>
    """
  end

  # The rows to draw, by kind in the preview's order: the preview's when
  # one is read, else the plan's ask; none for a plan that is unresolved.
  defp shown_rows(%{unresolved: %{}}, _preview), do: []

  defp shown_rows(plan, preview) do
    rows =
      case preview do
        %{rows: rows} when is_list(rows) -> rows
        _none -> plan_rows(plan)
      end

    kinds = Enum.map(Prima.ConsentPreview.kinds(), &Atom.to_string/1)

    rows
    |> Enum.group_by(& &1["kind"])
    |> Enum.sort_by(fn {kind, _rows} ->
      Enum.find_index(kinds, &(&1 == kind)) || length(kinds)
    end)
  end

  defp approving?(%{rows: rows}) when is_list(rows), do: true
  defp approving?(_preview), do: false

  # Each value the ask names, and each the grant holds, with whether the
  # grant holds it.
  defp choices(row, ask, field) do
    granted = row["values"][field] || []
    asked = (ask && ask["values"][field]) || []
    Enum.map(Enum.uniq(asked ++ granted), &{&1, &1 in granted})
  end

  defp folders(ask), do: Enum.filter(ask["values"]["paths"] || [], &String.ends_with?(&1, "/"))

  defp wildcard_row?(%{"values" => %{"tools" => tools}}), do: tools == wildcard()
  defp wildcard_row?(_row), do: false

  defp unresolved(%{unresolved: %{} = unresolved}), do: unresolved
  defp unresolved(_plan), do: nil

  defp unresolved_sentence(%{reason: "unresolvable_dependency", missing: ref})
       when is_binary(ref),
       do:
         "#{ref} is missing: it is not installed, or its dependencies cannot be read. " <>
           "Install it, then try again."

  defp unresolved_sentence(%{reason: "missing_release_digest", missing: ref}) when is_binary(ref),
    do: "#{ref} has no release digest. Publish it again, then try again."

  defp unresolved_sentence(%{reason: reason}),
    do: "Its dependencies cannot be resolved (#{reason}). Try again once they are installed."

  defp kind_heading("credential"), do: "Vault entries it receives"
  defp kind_heading("egress"), do: "Network"
  defp kind_heading("storage"), do: "Files"
  defp kind_heading("tools"), do: "Tools"
  defp kind_heading("tool_servers"), do: "Tool servers"
  defp kind_heading("limits"), do: "Limits"
  defp kind_heading("frame"), do: "Its frame"
  defp kind_heading("streams"), do: "Streams it listens to"
  defp kind_heading("cards"), do: "Cards it shares with the desktop"
  defp kind_heading("system_actions"), do: "System actions it may call"
  defp kind_heading(kind), do: kind

  # The edge a credential rides: its node's own key, or the key it lends
  # a dependency on that edge.
  defp edge_label(node, "@ingress"), do: "— for #{node}'s own calls"

  defp edge_label(node, edge) when is_binary(edge) do
    case String.split(edge, "|", parts: 2) do
      [dep, need] -> "— lent by #{node} to #{dep} for its #{need} need"
      [dep] -> "— lent by #{node} to #{dep}"
    end
  end

  defp edge_label(_node, _edge), do: ""

  defp subject_label("*"), do: "— any subject"
  defp subject_label(subject) when is_binary(subject), do: "— for #{subject}"
  defp subject_label(_none), do: "— its own"

  defp field_label("egress", "domains"), do: "Talks to"
  defp field_label("egress", "methods"), do: "Methods"
  defp field_label("egress", "schemes"), do: "Schemes"
  defp field_label("egress", "private_ips"), do: "Private networks"
  defp field_label("storage", "paths"), do: "Paths"
  defp field_label("storage", "actions"), do: "Actions"

  defp limit_lines(values) do
    for field <- Enum.map(Prima.Limits.fields(), &Atom.to_string/1),
        Map.has_key?(values, field),
        do: {field, limit_value(field, values)}
  end

  defp limit_value("rate_limit", %{"rate_limit" => %{"requests" => r, "window" => w}}),
    do: "#{r} per #{w}"

  defp limit_value("rate_requests", values), do: get_in(values, ["rate_limit", "requests"])
  defp limit_value(field, values), do: values[field] || "none"

  defp lowerable(%{"values" => values}) do
    fields =
      for field <- @duration_limits ++ @integer_limits,
          values[field] != nil,
          do: field

    if is_map(values["rate_limit"]), do: fields ++ ["rate_requests"], else: fields
  end

  defp limit_label("timeout"), do: "Timeout"
  defp limit_label("batch_timeout"), do: "Batch timeout"
  defp limit_label("max_memory_bytes"), do: "Memory (bytes)"
  defp limit_label("max_request_size"), do: "Request size (bytes)"
  defp limit_label("max_response_size"), do: "Response size (bytes)"
  defp limit_label("max_concurrent_tasks"), do: "Concurrent tasks"
  defp limit_label("rate_limit"), do: "Rate"
  defp limit_label("rate_requests"), do: "Requests per window"
  defp limit_label(field), do: field

  defp origin_label("interactive"), do: "when you use it (interactive)"
  defp origin_label("programmatic"), do: "by agents and scripts (programmatic)"
  defp origin_label("schedule"), do: "on a schedule (schedule)"
  defp origin_label("webhook"), do: "from webhooks (webhook)"
  defp origin_label(origin), do: origin

  defp capability_label("tools"), do: "Tools:"
  defp capability_label("egress." <> field), do: "Network #{field}:"
  defp capability_label("storage." <> field), do: "Files #{field}:"
  defp capability_label("policy." <> mode), do: "Agent policy #{mode}:"
  defp capability_label(capability), do: "#{capability}:"

  defp list_label([], none), do: none
  defp list_label(values, _none) when is_list(values), do: Enum.join(values, ", ")
  defp list_label(_values, none), do: none

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

  # A components/ write grant is code-mutation power on the local
  # namespace (pulled publishers are refused at the storage boundary) —
  # said in the sheet, so the operator grants it knowingly.
  defp component_writes?(shown) do
    for {"storage", rows} <- shown, row <- rows, reduce: false do
      acc ->
        paths = row["values"]["paths"] || []
        actions = row["values"]["actions"] || []

        acc or
          (Enum.any?(actions, &(&1 in ["write", "append", "delete"])) and
             Enum.any?(paths, &(&1 == "*" or String.starts_with?(&1, "components"))))
    end
  end

  defp warnings(plan), do: plan[:warnings] || plan["warnings"] || []
end
