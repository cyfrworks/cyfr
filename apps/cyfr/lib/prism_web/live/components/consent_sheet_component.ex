# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponent do
  @moduledoc """
  The consent walk a grant prompt shows: the body of the system layer's
  `:grant` prompt (`PrismWeb.SystemLayer`), drawn nowhere else, since only
  the system layer is never covered.

  It draws the typed rows of a `Prima.ConsentPreview` itself, grouped by
  kind in its own words: every row the preview answers, of every kind, a
  tincture's frame, streams and system actions included, and never
  a sentence the home wrote. Before a preview is read it draws the plan's
  rows, the ask. A plan whose closure is unresolved is drawn as that,
  naming what is missing, or the dependency stored damaged, with no rows
  and nothing to commit. Beneath the rows, before the person confirms,
  it lists each binding of the
  profile's head the preview says the grant removes: the need it was
  bound for ("a binding of this app's calls" where that cannot be told),
  its account or "default", and its entry's name, else its id or the
  label of the profile that lent it.

  ## Credentials

  Each credential need, the app's own and each dependency's, is a row of
  its own: what it is and the hosts it calls, and what can meet it — the
  entries the plan names as its candidates, each with where it may go
  and, for one matched through a `*.` host, how wide that host is, a
  profile of the dependency that lends its key, or the configuration the
  app's publisher provides, which takes no choice. A need with a
  suggested or chosen entry names it as the entry already held for its
  hosts.

  The chosen entry's field map is shown pair by pair where a field the
  component reads comes from an entry field of another name. Where the
  plan has no automatic map for the entry, the sheet asks once which of
  the entry's fields the component reads as each of its own, the entry
  field of the same name preselected, and holds the grant — no preview,
  so nothing to confirm — until each has one. The map the person chose,
  or the head's re-sent on a re-grant, goes in the decision
  (`Prism.ConsentChoices.mapped/2`), so the preview shows it and the
  commit digest covers it; a head's map naming a field the entry no
  longer holds is asked again.
  The entry the plan suggests is preselected for a required need
  (`Prism.ConsentChoices.initial_choices/2`, which the grant prompt
  opens with), shown as the pressed choice with a "Change" control when
  there is another; an
  optional need shows its suggestion as a choice one click away, unbound;
  the slot of a manifest declaring no needs is never bound unasked. A
  re-grant opens instead on what its head binds, the entry and its
  lifetime, never wider than the head. The candidates open unasked only
  where the plan says a choice is required.
  A need nothing can meet offers "Connect your <provider> account" where
  it takes an API key: the layer's credential-entry prompt, prefilled from
  the need, in front of the grant, whose sheet comes back with the new
  entry bound. A need the component reads itself says when the entries
  for its hosts are attach-only (the plan's `attach_only_held`), and,
  with a newer version shipped, links to the Components page to update
  it.

  Each previewed credential is one sentence: who uses it, the entry and
  whose it is, the account, where it may go and whether the component
  reads the value. Beside it, how long the binding lives — until revoked
  (preselected), five minutes, one hour, this session (until the
  earlier of the session's end and 24 hours on, named by the time it
  ends), or once — each `until` computed once, when the person chooses,
  and sent to the preview and the commit alike; and, where the head's
  `once` binding of that key was used, "Grant once again", which renews
  it. A binding that reopens with the head's `until` still ahead shows
  that time beside the five, pressed ("Until <time>, as granted"), and
  sends the head's own `until` until one of the five replaces it. One
  whose `until` has passed opens with no lifetime pressed and says why;
  it is no decision until the person chooses one.

  ## Named accounts

  An edge whose default is an entry, the app's own calls or a
  dependency's, may bind further accounts beside it, each under a name of
  its own: "Add another account" adds a row with a name to give (an
  account name, distinct from the edge's others, compared by Unicode's
  full lowercase mapping), the need's candidates with none pressed, and
  the five lifetimes, standing pressed. A dependency's default a profile
  lends is first switched to the entry that profile lends, pressed, and
  the row says it is now chosen here; where the dependency's need for that
  entry cannot be told, no account is added and the row says why. Each
  account the head binds reopens as its own row, its name fixed, its entry
  pressed and its lifetime as a re-grant's is: a `once` stays `once`, an
  `until` still ahead keeps its time, and one that has passed opens with
  nothing pressed. "Remove" drops a row. A row whose name is missing,
  invalid or taken, or with no entry or no lifetime pressed, is no
  decision, so the grant is narrower than the head, never wider.

  A grant opened for an account (the walk's `account`, which
  `PrismWeb.SystemLayer.grant_prompt/4` places) opens with that account's
  row: as held when the head already binds the name, else a new row of
  that fixed name beside the default as the grant otherwise opens it. An
  account whose edge or need the plan does not have opens the grant
  without it, saying why.

  ## The decisions

  The person's choices are submitted exactly, never as a category
  (`decisions/5`):

    * `bindings` — the entry each need of the app is bound to, with its
      lifetime and `renew`, and each named account of the app's own calls
      under its `name`;
    * `selections` — the entry, or the lending profile's label, each
      dependency's edge takes, with its lifetime and `renew`, and each
      named account of the edge under its `name`;
    * narrowing, per node, for each kind its enforcement point can check:
      the egress domains, methods, schemes and private ranges and the
      storage actions as exact values, the storage paths through a picker
      over `file.list` inside each asked folder, the tools per action (a
      wildcard ask whole or none), the limits, each capped at the ask
      and sent only when lowered, and the flows to each exit, one class at
      a time, removed or kept again but never one the ask does not name
      (`Prism.ConsentChoices.toggle_flow/4`). Where a catalyst's network
      ask names methods beside GET and HEAD, one control narrows it to the
      GET and HEAD it asks for, named by those methods;
    * the origins the grant admits: `interactive` is always named, and
      "also for agents and scripts" (`programmatic`), "also on a
      schedule" and "also from webhooks" are each a visible choice,
      unticked on a first grant. A re-grant starts from the origins its
      head admits, so it never quietly drops one.

  What changed since the head (the plan's `shape_diff`) is worded against
  the head as the person narrowed it: what the component asks for that
  the grant does not give, and what it no longer asks for. The person's
  own narrowing never reads as the component widening. It is grouped by
  node, the app's own first: each dependency under its ref, one the head
  never held as "New dependency <ref>" with what it asks, and one the
  release dropped as "No longer used: <ref>" with what the head granted
  it.

  It starts from the walk the prompt arrived with (`walk`: the plan as
  `profile.plan` answers it, its preview and the decisions, and the
  session's end `session/whoami` answered), so opening it reads nothing;
  given none, it plans `ref` itself. A walk marked `replan` (a grant come
  back from a credential entry) plans its choices again, and presses the
  lifetimes the sheet held when it handed the walk on (`held`). A walk
  that opened with nothing bound because the home refused to preview the
  plan's suggestions (`suggestion_refused`) shows the home's sentence for
  that refusal beside the needs, until a choice of the person's previews.
  Each walk it makes goes to its layer (`layer`, the prompt `prompt_id`)
  as `walk:` — the plan, the preview of exactly the decisions it holds
  (`nil` while one is read or when none could be), those decisions, and
  the choices behind them (`held`). When the person confirms, the layer
  asks the sheet (`confirm: prompt_id`), and the sheet hands it the walk
  as it stands then, after every choice that came before the confirm, as
  `commit:`: that is the walk the layer commits. Told to plan again
  (`replan: true`), after a commit that consumed the plan's token or a
  credential entered from it, it plans again: over the same ask it
  previews the same choices again, and over an ask that moved it opens
  again on the grant as it stands and says so (`reopen_if_moved/3`).
  """

  use PrismWeb, :live_component

  alias PrismWeb.Ops

  import Prism.ConsentChoices,
    only: [
      account_default: 3,
      account_head: 3,
      account_problem: 2,
      accounts_on: 2,
      answer_map: 5,
      asked_flows: 2,
      candidates_of: 1,
      choices_of: 2,
      decisions: 5,
      declared?: 1,
      dep_row: 3,
      field: 2,
      held_choices: 4,
      in_order: 1,
      initial_choices: 2,
      label_of: 1,
      lifetime_of: 3,
      limit_label: 1,
      lowerable: 1,
      lowered: 3,
      map_pending?: 1,
      mapped: 2,
      new_choice: 3,
      origins_of: 2,
      row_needs: 1,
      session_end_of: 1,
      session_until: 2,
      subset_of: 1,
      suggested: 1,
      toggle_flow: 4,
      walk_account: 4
    ]

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

  @read_methods ~w(GET HEAD)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       plan: nil,
       preview: nil,
       choices: %{},
       opened: MapSet.new(),
       origins: nil,
       subset: %{},
       label: nil,
       picker: nil,
       error: nil,
       previewed: nil,
       refusal: nil,
       account_refusal: nil,
       layer: nil,
       session_end: nil,
       started: false,
       moved: false
     )}
  end

  @impl true
  def update(%{replan: true}, socket) do
    {:noreply, socket} =
      CyfrWeb.ContextGuard.guard(socket, fn socket ->
        was = socket.assigns.plan

        {:noreply, socket |> assign(plan: nil, preview: nil) |> load_plan(was) |> tell_layer()}
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
        socket = socket |> assign(:started, true) |> from_walk(plan, walk)

        if Map.get(walk, :replan) == true do
          {:noreply, socket} =
            CyfrWeb.ContextGuard.guard(socket, fn socket ->
              {:noreply, socket |> load_plan(plan) |> tell_layer()}
            end)

          {:ok, socket}
        else
          # A map still to be chosen holds the grant: the layer is told
          # the walk has no preview to confirm.
          if is_nil(socket.assigns.preview) and Map.get(walk, :preview) != nil,
            do: tell_layer(socket)

          {:ok, socket}
        end

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
  # need and each dependency was bound to, the origins and narrowing it
  # was previewed with, and the session's end.
  defp from_walk(socket, plan, walk) do
    decisions = Map.get(walk, :decisions) || %{}
    held = Map.get(walk, :held)
    now = DateTime.utc_now()
    choices = held_choices(choices_of(decisions, plan), held, plan, now)

    # The account a grant was opened for is placed once, on the walk the
    # grant opens with; a walk drawn again holds the sheet's own rows.
    {choices, account_refusal} =
      if is_map(held), do: {choices, nil}, else: walk_account(plan, choices, walk, now)

    choices = mapped(choices, plan)

    socket
    |> assign(
      plan: plan,
      preview: if(maps_pending?(choices), do: nil, else: Map.get(walk, :preview)),
      choices: choices,
      origins: origins_of(decisions["origins"], plan),
      subset: subset_of(decisions["subset"]),
      label: label_of(decisions["label"]) || socket.assigns.label,
      session_end: session_end_of(Map.get(walk, :session_expires_at)),
      refusal: suggestion_refusal(Map.get(walk, :suggestion_refused)),
      account_refusal: account_refusal,
      error: nil
    )
    |> previewed()
  end

  # Why the grant opened with nothing bound: the home refused to preview
  # the plan's suggestions, in its own sentence, shown until a choice of
  # the person's previews.
  defp suggestion_refusal(sentence) when is_binary(sentence) and sentence != "",
    do: %{at: :suggestion, message: "The suggested entries were not bound: " <> sentence}

  defp suggestion_refusal(_none), do: nil

  # ---------------------------------------------------------------------------
  # The credential choices
  # ---------------------------------------------------------------------------

  # A slot as an event names it, and back: the only slots taken are the
  # shapes the sheet draws.
  defp slot_token({:need, need, name}), do: Jason.encode!(["need", need, name])
  defp slot_token({:dep, from, dep}), do: Jason.encode!(["dep", from, dep])

  defp slot_token({:account, {:need, need}, ref}),
    do: Jason.encode!(["account", "need", need, nil, ref])

  defp slot_token({:account, {:dep, from, dep}, ref}),
    do: Jason.encode!(["account", "dep", from, dep, ref])

  defp slot_of(token) when is_binary(token) do
    case Jason.decode(token) do
      {:ok, ["need", need, name]} when is_binary(need) and (is_binary(name) or is_nil(name)) ->
        {:ok, {:need, need, name}}

      {:ok, ["dep", from, dep]} when is_binary(from) and is_binary(dep) ->
        {:ok, {:dep, from, dep}}

      {:ok, ["account", "need", need, nil, ref]} when is_binary(need) and is_binary(ref) ->
        {:ok, {:account, {:need, need}, ref}}

      {:ok, ["account", "dep", from, dep, ref]}
      when is_binary(from) and is_binary(dep) and is_binary(ref) ->
        {:ok, {:account, {:dep, from, dep}, ref}}

      _other ->
        :error
    end
  end

  defp slot_of(_token), do: :error

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("pick_entry", %{"need" => need} = params, socket) when is_binary(need) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case picked(params) do
        {:ok, source, id} ->
          slot = {:need, need, nil}

          {:noreply,
           socket
           |> choose(slot, source, id, nil)
           |> walk_again({:need, need})}

        :error ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("pick_dep", %{"from" => from, "dep" => dep} = params, socket)
      when is_binary(from) and is_binary(dep) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case {picked(params), dep_row(socket.assigns.plan, from, dep)} do
        {{:ok, source, id}, %{} = row} ->
          need =
            if source != "label" and length(row_needs(row)) > 1, do: params["need"]

          {:noreply,
           socket
           |> choose({:dep, from, dep}, source, id, need)
           |> walk_again({:dep, from, dep})}

        _not_offered ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("clear_entry", %{"need" => need}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:choices, Map.delete(socket.assigns.choices, {:need, need, nil}))
       |> walk_again({:need, need})}
    end)
  end

  def handle_event("clear_dep", %{"from" => from, "dep" => dep}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:choices, Map.delete(socket.assigns.choices, {:dep, from, dep}))
       |> walk_again({:dep, from, dep})}
    end)
  end

  # The candidates of a slot, opened or closed again: a choice the person
  # asked to change. Reads nothing.
  def handle_event("change", %{"slot" => token}, socket) do
    case slot_of(token) do
      {:ok, slot} ->
        opened = socket.assigns.opened

        opened =
          if MapSet.member?(opened, slot),
            do: MapSet.delete(opened, slot),
            else: MapSet.put(opened, slot)

        {:noreply, assign(socket, :opened, opened)}

      :error ->
        {:noreply, socket}
    end
  end

  # How long a bound credential lives: one of the five, an until computed
  # now, once, and sent to the preview and the commit alike.
  def handle_event("set_lifetime", %{"slot" => token, "lifetime" => lifetime}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, slot} <- slot_of(token),
           %{} = held <- Map.get(socket.assigns.choices, slot),
           {:ok, wire} <- lifetime_of(lifetime, socket.assigns.session_end, DateTime.utc_now()) do
        choice = %{held | lifetime: wire, choice: lifetime, renew: false}

        {:noreply,
         socket
         |> assign(:choices, Map.put(socket.assigns.choices, slot, choice))
         |> walk_again({:lifetime, slot})}
      else
        _not_offered -> {:noreply, socket}
      end
    end)
  end

  # A head binding used once, granted once again: `once`, renewed.
  def handle_event("renew", %{"slot" => token}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, slot} <- slot_of(token),
           %{} = held <- Map.get(socket.assigns.choices, slot) do
        choice = %{held | lifetime: %{"kind" => "once"}, choice: "once", renew: true}

        {:noreply,
         socket
         |> assign(:choices, Map.put(socket.assigns.choices, slot, choice))
         |> walk_again({:lifetime, slot})}
      else
        _not_held -> {:noreply, socket}
      end
    end)
  end

  # "Add another account" beside an edge's default: a row of its own, with
  # a name to give, no entry pressed and standing pressed, which is no
  # decision until it is whole. A default a profile lends is first
  # switched to the entry that profile lends; where that cannot be done
  # the row says why and nothing is added.
  def handle_event("add_account", %{"slot" => token}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, slot} <- slot_of(token),
           {:ok, edge} <- default_edge(slot) do
        case account_default(socket.assigns.plan, socket.assigns.choices, edge) do
          {:ok, choices, need} ->
            ref = "row:" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
            seq = System.unique_integer([:positive, :monotonic])
            account = Map.merge(new_choice(nil, nil, need), %{name: "", fixed: false, seq: seq})

            {:noreply,
             socket
             |> assign(:choices, Map.put(choices, {:account, edge, ref}, account))
             |> walk_again({:add_account, edge})}

          {:error, sentence} ->
            {:noreply, refuse(socket, {:add_account, edge}, sentence)}
        end
      else
        _not_an_edge -> {:noreply, socket}
      end
    end)
  end

  # The name an added account rides under, as the person types it; the
  # name of an account the walk already held is fixed.
  def handle_event("name_account", %{"slot" => token, "name" => name}, socket)
      when is_binary(name) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, {:account, _edge, _ref} = slot} <- slot_of(token),
           %{fixed: false} = held <- Map.get(socket.assigns.choices, slot) do
        {:noreply,
         socket
         |> assign(:choices, Map.put(socket.assigns.choices, slot, %{held | name: name}))
         |> walk_again({:lifetime, slot})}
      else
        _not_named_here -> {:noreply, socket}
      end
    end)
  end

  # The entry an account binds: one of its need's candidates.
  def handle_event("pick_account", %{"slot" => token} = params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, {:account, _edge, _ref} = slot} <- slot_of(token),
           %{} = held <- Map.get(socket.assigns.choices, slot),
           {:ok, source, id} when source in ["own", "instance"] <- picked(params),
           true <- {source, id} in candidate_picks(account_need(socket.assigns.plan, slot, held)) do
        choice = held |> rebound(source, id) |> Map.merge(%{source: source, id: id, renew: false})

        {:noreply,
         socket
         |> assign(:choices, Map.put(socket.assigns.choices, slot, choice))
         |> walk_again({:lifetime, slot})}
      else
        _not_offered -> {:noreply, socket}
      end
    end)
  end

  # The person's answer to the map question: which of the chosen entry's
  # fields the component reads as one of its own.
  def handle_event(
        "map_field",
        %{"slot" => token, "need_field" => need_field, "entry_field" => entry_field},
        socket
      )
      when is_binary(need_field) and is_binary(entry_field) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, slot} <- slot_of(token),
           {:ok, choices} <-
             answer_map(
               socket.assigns.choices,
               socket.assigns.plan,
               slot,
               need_field,
               entry_field
             ) do
        {:noreply, socket |> assign(:choices, choices) |> walk_again(map_refusal(slot))}
      else
        _not_asked -> {:noreply, socket}
      end
    end)
  end

  def handle_event("remove_account", %{"slot" => token}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case slot_of(token) do
        {:ok, {:account, edge, _ref} = slot} ->
          {:noreply,
           socket
           |> assign(:choices, Map.delete(socket.assigns.choices, slot))
           |> walk_again({:add_account, edge})}

        _other ->
          {:noreply, socket}
      end
    end)
  end

  # "Connect your <provider> account": the layer's credential-entry prompt
  # for an API key the need takes, prefilled from it, in front of this
  # grant, which comes back with the entry bound.
  def handle_event("connect", %{"slot" => token, "need" => need_name}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with %{layer: layer, prompt_id: prompt_id} when is_binary(layer) and is_binary(prompt_id) <-
             socket.assigns,
           {:ok, slot} <- slot_of(token),
           %{} = need <- slot_need(socket.assigns.plan, slot, need_name),
           true <- connectable?(need) do
        send_update(PrismWeb.SystemLayer,
          id: layer,
          connect: connect_request(prompt_id, slot, need)
        )
      end

      {:noreply, socket}
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
  #
  # The value rides in `choice`, never `value`: for a checkbox LiveView
  # sends the box's own value under `value`, overwriting any attribute
  # naming that key, and sends no `value` at all for a box unticked, so
  # a choice carried there would reach the home as nothing while the box
  # shows it changed.
  def handle_event(
        "toggle_value",
        %{"node" => node, "kind" => kind, "field" => field, "choice" => value},
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

  # A catalyst's network methods narrowed to the GET and HEAD it asks for,
  # or back to its whole ask: offered only where it asks for others too.
  def handle_event("get_head_only", %{"node" => node}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      asked = asked_values(socket.assigns.plan, node, "egress", "methods")

      case get_and_head(node, asked) do
        [_ | _] = kept ->
          granted = granted_values(socket, node, "egress", "methods")
          chosen = if Enum.sort(granted) == Enum.sort(kept), do: asked, else: kept
          subset = put_set(socket.assigns.subset, node, "egress", "methods", chosen, asked)
          {:noreply, socket |> assign(:subset, subset) |> walk_again({"egress", node})}

        [] ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("toggle_tool", %{"node" => node, "choice" => value}, socket) do
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

  # One class's flow to one exit, removed or kept again; never a flow the
  # ask does not name.
  def handle_event(
        "toggle_flow",
        %{"node" => node, "exit" => exit, "choice" => class},
        socket
      ) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      asked = asked_flows(plan_rows(socket.assigns.plan), node)
      flow = %{"from" => class, "to" => exit}

      if flow in asked do
        subset = toggle_flow(socket.assigns.subset, node, asked, flow)
        {:noreply, socket |> assign(:subset, subset) |> walk_again({"exits", node})}
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
      current = get_in(socket.assigns.subset, [node, "limits"]) || %{}

      with %{} = asked <- asked_limits(socket.assigns.plan, node),
           {:ok, record} <- lowered(limits, asked, current) do
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

  # ---------------------------------------------------------------------------
  # Named accounts
  # ---------------------------------------------------------------------------

  # The edge a default's slot sits on.
  defp default_edge({:need, need, nil}), do: {:ok, {:need, need}}
  defp default_edge({:dep, from, dep}), do: {:ok, {:dep, from, dep}}
  defp default_edge(_slot), do: :error

  # The need an account's entry meets: the app's need its edge names, or
  # the dependency's, the one it names where there are several.
  defp account_need(plan, {:account, {:need, need}, _ref}, _held),
    do: slot_need(plan, {:need, need, nil}, need)

  defp account_need(plan, {:account, {:dep, from, dep}, _ref}, held) do
    with %{} = row <- dep_row(plan, from, dep) do
      case row_needs(row) do
        [one] -> one
        needs -> Enum.find(needs, &(field(&1, :need) == held.need))
      end
    end
  end

  defp candidate_picks(nil), do: []

  defp candidate_picks(need),
    do: need |> candidates_of() |> Enum.map(&candidate_pick/1) |> Enum.reject(&is_nil/1)

  # The accounts a need's row draws, each with what its row shows: its
  # control's token, the entry pressed, why it is no decision yet, and
  # whether the head's `once` of it was used.
  defp account_rows(plan, choices, edge, keep) do
    for {slot, choice} <- accounts_on(choices, edge), keep.(choice) do
      %{
        slot: slot,
        token: slot_token(slot),
        choice: choice,
        pick: if(is_binary(choice.id), do: {choice.source, choice.id}),
        why: account_problem(slot, choices),
        renewable?: plan |> account_head(edge, choice.name) |> once_used?()
      }
    end
  end

  # The id of an account's name form, one per rendered sheet and account,
  # so the page can recover the form after a reconnect: the sheet's id
  # and the account's slot token, encoded to characters an id carries
  # anywhere.
  defp account_form_id(sheet, token),
    do: "consent-sheet-#{sheet}-account-#{Base.url_encode64(token, padding: false)}"

  # The accounts a dependency's need draws: all of the edge's when the
  # dependency declares one need; else those for this need, and the first
  # need draws any that names none.
  defp dep_accounts(plan, choices, row, need, index) do
    several? = length(row_needs(row)) > 1

    account_rows(plan, choices, {:dep, row.from, row.dep}, fn choice ->
      not several? or choice.need == field(need, :need) or (is_nil(choice.need) and index == 0)
    end)
  end

  # What a pick names: an entry of the athanor, an instance entry, or a
  # lending profile's label.
  defp picked(%{"entry_id" => id}) when is_binary(id) and id != "", do: {:ok, "own", id}

  defp picked(%{"instance_entry_id" => id}) when is_binary(id) and id != "",
    do: {:ok, "instance", id}

  defp picked(%{"label" => label}) when is_binary(label) and label != "",
    do: {:ok, "label", label}

  defp picked(_params), do: :error

  # A slot bound to what the person picked, keeping the lifetime they gave
  # it, and its field map only while the entry is the same; the
  # candidates close once chosen.
  defp choose(socket, slot, source, id, need) do
    choice =
      case Map.get(socket.assigns.choices, slot) do
        %{} = held ->
          held
          |> rebound(source, id)
          |> Map.merge(%{source: source, id: id, need: need, renew: false})

        nil ->
          new_choice(source, id, need)
      end

    assign(socket,
      choices: Map.put(socket.assigns.choices, slot, choice),
      opened: MapSet.delete(socket.assigns.opened, slot)
    )
  end

  # A map was chosen for one entry: another entry is asked again.
  defp rebound(%{source: source, id: id} = held, source, id), do: held
  defp rebound(held, _source, _id), do: Map.drop(held, [:fields, :unmapped])

  # Every choice previews the walk again, each entry chosen held to its
  # field map, and hands it to the layer. Called inside the event's own
  # guard, naming the control that made the choice (`at`), beside which a
  # refusal is shown.
  defp walk_again(socket, at) do
    socket
    |> assign(:choices, mapped(socket.assigns.choices, socket.assigns.plan))
    |> preview(at)
    |> tell_layer()
  end

  # Where a refusal of a map answer is shown: on the need, or on the
  # account's row.
  defp map_refusal({:account, _edge, _ref} = slot), do: {:lifetime, slot}
  defp map_refusal(slot), do: slot_refusal(slot)

  defp maps_pending?(choices),
    do: Enum.any?(choices, fn {_slot, choice} -> map_pending?(choice) end)

  # What the home last previewed: the choices and the preview of exactly
  # those, put back whole when it refuses a later choice.
  defp previewed(%{assigns: %{preview: %{} = preview}} = socket) do
    assign(socket, :previewed, %{
      choices: socket.assigns.choices,
      origins: socket.assigns.origins,
      subset: socket.assigns.subset,
      preview: preview
    })
  end

  defp previewed(socket), do: socket

  # A refusal beside the control that caused it, the walk left as it was.
  defp refuse(socket, at, message), do: assign(socket, :refusal, %{at: at, message: message})

  # ---------------------------------------------------------------------------
  # Lifetimes
  # ---------------------------------------------------------------------------

  # The five choices, each named by what it does; "this session" by the
  # time it ends, never by signing out, since an until is fixed once
  # committed.
  #
  # A binding that reopens with the time its head was granted until, still
  # ahead, shows that time too, pressed: the until it keeps unless the
  # person chooses again.
  defp lifetime_options(choice, session_end, now) do
    session =
      case session_until(session_end, now) do
        %DateTime{} = at -> [{"session", "This session, until #{time_words(at, now)}"}]
        nil -> []
      end

    kept =
      with %{choice: nil, lifetime: %{"kind" => "until", "until" => until}} <- choice,
           {:ok, at, _offset} <- DateTime.from_iso8601(until) do
        [{"kept", "Until #{time_words(at, now)}, as granted"}]
      else
        _none -> []
      end

    kept ++
      [{"standing", "Until revoked"}, {"5m", "5 minutes"}, {"1h", "1 hour"}] ++
      session ++ [{"once", "Once (one run)"}]
  end

  defp time_words(%DateTime{} = at, %DateTime{} = now) do
    clock = Calendar.strftime(at, "%H:%M UTC")

    case Date.diff(DateTime.to_date(at), DateTime.to_date(now)) do
      0 -> clock
      1 -> clock <> " tomorrow"
      _days -> clock <> " on " <> Date.to_iso8601(DateTime.to_date(at))
    end
  end

  defp chosen_lifetime(%{choice: choice}) when is_binary(choice), do: choice
  defp chosen_lifetime(%{lifetime: %{"kind" => kind}}) when kind in ["standing", "once"], do: kind
  defp chosen_lifetime(%{lifetime: %{"kind" => "until"}}), do: "kept"
  defp chosen_lifetime(_choice), do: nil

  attr :choice, :map, required: true
  attr :token, :string, required: true
  attr :session_end, :any, default: nil
  attr :now, :any, required: true
  attr :myself, :any, required: true

  # The lifetime choices of one binding, the one it lives by pressed.
  defp lifetime_buttons(assigns) do
    ~H"""
    <button
      :for={{value, text} <- lifetime_options(@choice, @session_end, @now)}
      type="button"
      phx-click="set_lifetime"
      phx-target={@myself}
      phx-value-slot={@token}
      phx-value-lifetime={value}
      aria-pressed={to_string(chosen_lifetime(@choice) == value)}
      data-lifetime={value}
      class={choice_class(chosen_lifetime(@choice) == value)}
    >
      {text}
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Narrowing
  # ---------------------------------------------------------------------------

  defp wildcard, do: Prima.ConsentPreview.Row.wildcard()

  defp ask_row(plan, kind, node),
    do: Enum.find(plan_rows(plan), &(&1["kind"] == kind and &1["node"] == node))

  # The ask a row is drawn against: its node's row of its kind, and for an
  # exit, its node's row of that exit.
  defp row_ask(plan, %{"kind" => "exits", "node" => node, "values" => %{"exit" => exit}}) do
    Enum.find(
      plan_rows(plan),
      &(&1["kind"] == "exits" and &1["node"] == node and get_in(&1, ["values", "exit"]) == exit)
    )
  end

  defp row_ask(plan, row), do: ask_row(plan, row["kind"], row["node"])

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

  # The GET and HEAD a catalyst's method ask names, when it names others
  # too: what "GET and HEAD only" keeps. Nothing for any other node.
  defp get_and_head("catalyst:" <> _ = _node, asked) do
    kept = Enum.filter(@read_methods, &(&1 in asked))
    if kept != [] and length(kept) < length(asked), do: kept, else: []
  end

  defp get_and_head(_node, _asked), do: []

  # A narrowing named by the methods it keeps, never as "read only": a GET
  # can still disclose.
  defp methods_only_label(methods), do: Enum.join(methods, " and ") <> " only"

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

  defp inside?(path, asked), do: Prima.ComponentPath.path_granted?(path, asked)

  # ---------------------------------------------------------------------------
  # The walk
  # ---------------------------------------------------------------------------

  defp load_plan(socket, was \\ nil) do
    args =
      %{"ref" => socket.assigns.ref}
      |> Prima.MapUtil.put_present("label", socket.assigns.label)

    case Ops.call_tool(socket, "profile/plan", args) do
      {:ok, plan} ->
        socket = reopen_if_moved(socket, was, plan)

        socket
        |> assign(plan: plan, error: nil, choices: mapped(socket.assigns.choices, plan))
        |> assign(:origins, socket.assigns.origins || origins_of(nil, plan))
        |> preview()

      {:error, reason} ->
        assign(socket, plan: nil, preview: nil, error: Ops.error_message(reason))
    end
  end

  # A plan made again while the sheet is open answers for the grant and the
  # ask as they stand now. When either moved since the plan the sheet held
  # (`was`) — a release landed (another shape), or another client committed
  # (another head revision, which a refused commit's `stale_plan` names) —
  # nothing the sheet holds was chosen against them: not its narrowing, its
  # origins, its accounts nor its lifetimes. So it opens again exactly as a
  # prompt opening now would (`head_narrowing`, `head_origins`, the plan's
  # own choices), never carrying the old head's grant over the new one, and
  # says so. Only a plan made again over the same ask and the same head
  # keeps what the person chose.
  #
  # Both ways a sheet plans again pass the plan it held (`was`): a refused
  # commit (`update/2`'s `replan`) and a walk returned with a credential
  # entered (`replan` on the walk). The notice is true only of the reopen
  # it names, so a plan made again over what the sheet holds clears it, and
  # the walk last previewed goes with a reopen, never to be put back.
  defp reopen_if_moved(socket, was, plan) when is_map(was) do
    if shape_of(was) != shape_of(plan) or head_of(was) != head_of(plan) do
      assign(socket,
        subset: subset_of(plan[:head_narrowing]),
        origins: origins_of(nil, plan),
        choices: initial_choices(plan, DateTime.utc_now()),
        moved: true,
        previewed: nil,
        refusal: nil,
        account_refusal: nil
      )
    else
      assign(socket, :moved, false)
    end
  end

  defp reopen_if_moved(socket, _first_plan, _plan), do: socket

  defp head_of(plan), do: plan[:expected_consent_revision]

  defp shape_of(plan), do: plan[:shape_digest]

  # A plan whose closure is unresolved has nothing to preview: the preview
  # and the commit refuse it, and the sheet names what is missing instead.
  #
  # A choice the home refuses puts back the last walk that previewed, its
  # choices and its preview, and says why beside the control that made it
  # (`at`): the person keeps every control and chooses again, and the layer
  # is never left holding a preview of other choices than its own. Beyond
  # offering only what the ask names, the sheet checks nothing: what a
  # narrowing may be is the home's to decide.
  #
  # A field map still to be chosen holds the grant: nothing is previewed,
  # so there is nothing to confirm, until each field has an entry field.
  # A refusal of a choice with no walk previewed before it is shown beside
  # that choice too, with nothing to confirm.
  defp preview(socket, at \\ nil)
  defp preview(%{assigns: %{plan: nil}} = socket, _at), do: socket
  defp preview(%{assigns: %{plan: %{unresolved: %{}}}} = socket, _at), do: socket

  defp preview(socket, at) do
    if maps_pending?(socket.assigns.choices) do
      assign(socket, preview: nil, error: nil, refusal: nil)
    else
      read_preview(socket, at)
    end
  end

  defp read_preview(socket, at) do
    case Ops.call_tool(socket, "profile/preview", %{"decisions" => decisions_payload(socket)}) do
      {:ok, preview} ->
        socket |> assign(preview: preview, error: nil, refusal: nil) |> previewed()

      {:error, reason} ->
        case {at, socket.assigns.previewed} do
          {nil, _previewed} ->
            assign(socket, preview: nil, error: Ops.error_message(reason))

          {at, %{} = last} ->
            socket
            |> assign(
              choices: last.choices,
              origins: last.origins,
              subset: last.subset,
              preview: last.preview
            )
            |> refuse(at, Ops.error_message(reason))

          {at, nil} ->
            socket |> assign(:preview, nil) |> refuse(at, Ops.error_message(reason))
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
      decisions: decisions_payload(socket),
      held: socket.assigns.choices
    }
  end

  defp decisions_payload(socket) do
    decisions(
      socket.assigns.ref,
      socket.assigns.label,
      socket.assigns.origins || [@interactive],
      socket.assigns.subset,
      socket.assigns.choices
    )
  end

  # ---------------------------------------------------------------------------
  # The plan's needs
  # ---------------------------------------------------------------------------

  # The need a slot's event names: one of the app's, or one of the
  # dependency's on that edge.
  defp slot_need(plan, {:need, _need, _name}, name),
    do: plan |> field(:needs) |> List.wrap() |> Enum.find(&(field(&1, :need) == name))

  defp slot_need(plan, {:dep, from, dep}, name) do
    case dep_row(plan, from, dep) do
      nil -> nil
      row -> Enum.find(row_needs(row), &(field(&1, :need) == name))
    end
  end

  defp candidate_pick(candidate) do
    case candidate do
      %{entry_id: id} when is_binary(id) -> {"own", id}
      %{instance_entry_id: id} when is_binary(id) -> {"instance", id}
      _other -> nil
    end
  end

  # The component reads the value itself: a disclose-only need, a need
  # declaring disclosure, or the slot of a manifest declaring no needs.
  defp reads_itself?(need),
    do:
      not declared?(need) or field(need, :disclose_only) == true or
        field(need, :disclose) == true

  # Only an API key is entered through the layer's credential prompt.
  defp connectable?(need),
    do: field(need, :kind) == "api_key" and field(need, :source) != "provided"

  defp connect_request(prompt_id, slot, need) do
    return =
      case slot do
        {:need, _need, _name} -> %{prompt: prompt_id, need: field(need, :need)}
        {:dep, from, dep} -> %{prompt: prompt_id, from: from, dep: dep, need: field(need, :need)}
      end

    %{
      provider: field(need, :provider),
      field: one_field(field(need, :fields)),
      hosts: field(need, :hosts) || [],
      paths: field(need, :paths) || [],
      disclose_needed: reads_itself?(need),
      return: return
    }
  end

  defp one_field([name]) when is_binary(name), do: name
  defp one_field(_none_or_several), do: PrismWeb.SystemLayer.Prompt.default_field()

  # Whether no credential need is declared by the app or any dependency.
  defp asks_no_credentials?(plan) do
    not Enum.any?(List.wrap(field(plan, :needs)), &declared?/1) and
      List.wrap(field(plan, :dependency_needs)) == []
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
      |> assign(:now, DateTime.utc_now())

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

        <p :if={@moved} role="alert" class="text-sm text-amber-400" data-test="grant-moved">
          This app or its grant changed while this was open, so it opens again on the grant as
          it stands now — review it before you confirm.
        </p>

        <section
          :if={(@plan[:shape_diff] || []) != []}
          class="consent-sheet__delta"
          data-test="grant-delta"
        >
          <h4 class="font-medium">What changed since your grant</h4>
          <div
            :for={group <- delta_groups(@plan, @plan[:source_ref] || @ref)}
            data-test="grant-delta-node"
            data-node={group.node}
          >
            <h5 :if={group.heading} class="font-medium" data-test="grant-delta-heading">
              {group.heading}
            </h5>
            <ul>
              <li :for={entry <- group.entries}>
                <strong>{capability_label(entry.capability)}</strong>
                <span :if={entry.added != []}>
                  asks for {Enum.join(entry.added, ", ")}, which your grant does not give
                </span>
                <span :if={entry.removed != []}>
                  no longer asks for {Enum.join(entry.removed, ", ")}
                </span>
              </li>
            </ul>
          </div>
        </section>

        <section class="consent-sheet__needs space-y-2" data-test="grant-needs">
          <h4 class="font-medium">Vault entries</h4>
          <.refusal refusal={@refusal} at={:suggestion} />
          <.refusal refusal={@account_refusal} at={:account} />
          <p :if={asks_no_credentials?(@plan)} class="consent-sheet__empty">
            This app asks for no credentials.
          </p>

          <.need
            :for={need <- List.wrap(@plan[:needs])}
            sheet={@id}
            slot_key={{:need, need.need, nil}}
            need={need}
            component={@plan[:source_ref] || @ref}
            from={@plan[:source_ref] || @ref}
            choice={Map.get(@choices, {:need, need.need, nil})}
            opened={MapSet.member?(@opened, {:need, need.need, nil})}
            several={false}
            lenders={[]}
            edge={{:need, need.need}}
            edge_label="@ingress"
            accounts={account_rows(@plan, @choices, {:need, need.need}, fn _ -> true end)}
            myself={@myself}
            athanor_route={assigns[:athanor_route]}
            refusal={@refusal}
            session_end={@session_end}
            now={@now}
          />

          <div
            :for={row <- List.wrap(@plan[:dependency_needs])}
            class="consent-sheet__dep space-y-1"
            data-dep={row.dep}
            data-from={row.from}
          >
            <p class="text-xs text-gray-400">{row.dep}, called by {row.from}</p>
            <.need
              :for={{need, index} <- Enum.with_index(row.needs)}
              sheet={@id}
              slot_key={{:dep, row.from, row.dep}}
              need={need}
              component={row.dep}
              from={row.from}
              choice={Map.get(@choices, {:dep, row.from, row.dep})}
              opened={MapSet.member?(@opened, {:dep, row.from, row.dep})}
              several={length(row.needs) > 1}
              lenders={if index == 0, do: List.wrap(row[:candidates]), else: []}
              edge={{:dep, row.from, row.dep}}
              edge_label={row.dep}
              accounts={dep_accounts(@plan, @choices, row, need, index)}
              myself={@myself}
              athanor_route={assigns[:athanor_route]}
              refusal={@refusal}
              session_end={@session_end}
              now={@now}
            />
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
              ask={row_ask(@plan, row)}
              myself={@myself}
              approving?={@approving?}
              refusal={@refusal}
              slot_key={row_slot(row, @choices)}
              choices={@choices}
              head={head_binding(@plan, row)}
              session_end={@session_end}
              now={@now}
            />
          </div>

          <div
            :if={@approving? and removed(@preview) != []}
            class="consent-sheet__removed"
            data-test="grant-removed"
          >
            <h5 class="text-xs font-semibold uppercase tracking-wider text-gray-400">
              What this grant removes
            </h5>
            <p
              :for={item <- removed(@preview)}
              class="consent-sheet__removal"
              data-binding={item["binding_key"]}
            >
              {removal_line(item)}
            </p>
          </div>

          <p :if={@approving?} class="consent-sheet__admits" data-test="grant-admits">
            Admits runs started: {Enum.map_join(@preview.origins, ", ", &origin_label/1)}.
          </p>
          <p class="consent-sheet__note text-gray-400">
            Vault entries are sealed at rest. A component never holds a vault entry's value
            unless its row says the value is disclosed to it.
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

  attr :sheet, :string, required: true
  attr :slot_key, :any, required: true
  attr :need, :map, required: true
  attr :component, :string, required: true
  attr :from, :string, required: true
  attr :choice, :map, default: nil
  attr :opened, :boolean, default: false
  attr :several, :boolean, default: false
  attr :lenders, :list, default: []
  attr :edge, :any, required: true
  attr :edge_label, :string, required: true
  attr :accounts, :list, default: []
  attr :myself, :any, required: true
  attr :athanor_route, :any, default: nil
  attr :refusal, :map, default: nil
  attr :session_end, :any, default: nil
  attr :now, :any, required: true

  # One credential need and what can meet it. The chosen entry is the
  # pressed choice; the others open on "Change", or unasked where the plan
  # says a choice is required. A need the publisher's configuration fills
  # takes no choice at all. Beneath it, each named account of its edge, and
  # "Add another account" where its default is an entry, or a key a
  # profile lends, which adding one switches to that entry.
  defp need(assigns) do
    need = assigns.need
    candidates = candidates_of(need)
    chosen = chosen_pick(assigns.choice, need, assigns.several)
    suggestion = suggested_pick(need)
    lender = chosen_lender(assigns.choice)
    open? = assigns.opened or (field(need, :choice_required) == true and is_nil(assigns.choice))
    provided? = field(need, :source) == "provided"

    shown =
      cond do
        open? -> candidates
        chosen != nil -> Enum.filter(candidates, &(candidate_pick(&1) == chosen))
        lender != nil -> []
        suggestion != nil -> Enum.filter(candidates, &(candidate_pick(&1) == suggestion))
        true -> candidates
      end

    # A lending profile is shown when the person asks, when it is the
    # choice, or when no entry can meet the need.
    lenders_shown =
      if open? or lender != nil or candidates == [], do: assigns.lenders, else: []

    options = length(candidates) + length(assigns.lenders)
    chosen_candidate = chosen && Enum.find(candidates, &(candidate_pick(&1) == chosen))

    # The entry the need already has: the one chosen, else the one the plan
    # suggests while no profile's key is chosen instead.
    held_entry =
      chosen_candidate ||
        (is_nil(lender) && suggestion &&
           Enum.find(candidates, &(candidate_pick(&1) == suggestion)))

    assigns =
      assign(assigns,
        provided?: provided?,
        held_entry: held_entry,
        chosen_candidate: chosen_candidate,
        candidates: candidates,
        shown: shown,
        lenders_shown: lenders_shown,
        chosen: chosen,
        lender: lender,
        changeable?: not open? and options > length(shown) + length(lenders_shown),
        nothing?: candidates == [] and assigns.lenders == [],
        token: slot_token(assigns.slot_key),
        events: slot_events(assigns.slot_key),
        addable?:
          not provided? and declared?(need) and
            (chosen != nil or (lender != nil and assigns.lenders != [])),
        lent_by: if(chosen != nil, do: lent_by(assigns.choice))
      )

    ~H"""
    <div
      class="consent-sheet__need"
      data-need={field(@need, :need)}
      data-test="grant-need"
    >
      <div class="consent-sheet__need-reason">{field(@need, :reason)}</div>
      <div class="consent-sheet__need-what text-xs text-gray-400">{need_words(@need)}</div>

      <p
        :if={(not @provided? and @held_entry) && hosts_words(@need) != ""}
        class="consent-sheet__held"
        data-test="grant-held"
      >
        You already have an entry for {hosts_words(@need)}: {@held_entry.name}
      </p>

      <p :if={@provided?} class="consent-sheet__provided" data-test="grant-provided">
        Provided by {publisher(@from)}, the app's public configuration, sent only to <span class="font-mono">{destination_label(field(@need, :destination))}</span>.
      </p>

      <div :if={not @provided?} class="consent-sheet__choices flex flex-wrap gap-2">
        <button
          :for={candidate <- @shown}
          type="button"
          phx-click={@events.pick}
          phx-target={@myself}
          {@events.values}
          phx-value-need={field(@need, :need)}
          {pick_values(candidate)}
          aria-pressed={to_string(candidate_pick(candidate) == @chosen)}
          data-test="grant-pick"
          class={choice_class(candidate_pick(candidate) == @chosen)}
        >
          {candidate.name}
          <span class="consent-sheet__fields">
            {candidate_words(candidate)}
          </span>
        </button>

        <button
          :for={lender <- @lenders_shown}
          type="button"
          phx-click={@events.pick}
          phx-target={@myself}
          {@events.values}
          phx-value-label={lender.label}
          aria-pressed={to_string(@lender == lender.label)}
          data-test="grant-pick"
          class={choice_class(@lender == lender.label)}
        >
          {lender.entry_name}
          <span class="consent-sheet__fields">
            {lender_words(@component, lender)}
          </span>
        </button>

        <button
          :if={@changeable?}
          type="button"
          phx-click="change"
          phx-target={@myself}
          phx-value-slot={@token}
          data-test="grant-change"
          class="consent-sheet__choice"
        >
          Change
        </button>

        <button
          :if={@candidates != [] or @lenders != []}
          type="button"
          phx-click={@events.clear}
          phx-target={@myself}
          {@events.values}
          phx-value-need={field(@need, :need)}
          aria-pressed={to_string(is_nil(@choice))}
          class="consent-sheet__choice"
        >
          No entry
        </button>
      </div>

      <.field_map
        :if={(not @provided? and @chosen_candidate) && declared?(@need)}
        form={map_form_id(@sheet, @token)}
        token={@token}
        candidate={@chosen_candidate}
        need={@need}
        component={@component}
        choice={@choice}
        myself={@myself}
      />

      <p
        :if={not @provided? and field(@need, :attach_only_held) == true}
        class="consent-sheet__why"
        data-test="grant-why"
      >
        {@component} reads the value itself, so only an entry you let it read can meet this
        need: your entries for {hosts_words(@need)} are attach-only, and it never holds their
        value.
      </p>

      <button
        :if={not @provided? and @nothing? and connectable?(@need)}
        type="button"
        phx-click="connect"
        phx-target={@myself}
        phx-value-slot={@token}
        phx-value-need={field(@need, :need)}
        data-test="grant-connect"
        class="consent-sheet__choice"
      >
        Connect your {field(@need, :provider)} account
      </button>

      <p
        :if={not @provided? and @nothing? and declared?(@need) and not connectable?(@need)}
        class="consent-sheet__empty"
      >
        <.link
          :if={@athanor_route}
          navigate={PrismWeb.Focus.path(@athanor_route, "/vault")}
          class="consent-sheet__link underline"
        >
          Add a vault entry
        </.link>
        <span :if={!@athanor_route}>Add a vault entry</span>
        for {hosts_words(@need)} first.
      </p>

      <p :if={is_binary(field(@need, :newer_shipped))} class="consent-sheet__update">
        <.link
          :if={@athanor_route}
          navigate={components_path(@athanor_route, @component)}
          data-test="grant-update"
          class="consent-sheet__link underline"
        >
          Update {@component} to {field(@need, :newer_shipped)}
        </.link>
        <span :if={!@athanor_route} data-test="grant-update">
          Update {@component} to {field(@need, :newer_shipped)} on the Components page
        </span>
      </p>

      <div
        :if={
          is_map(@choice) and is_nil(@choice.lifetime) and
            (@chosen != nil or (@lender != nil and @lenders != []))
        }
        class="consent-sheet__lifetime flex flex-wrap items-center gap-2"
        data-test="grant-lifetime-pending"
      >
        <span class="text-xs text-gray-400">
          The time this was granted until has passed. Choose how long it lives:
        </span>
        <.lifetime_buttons
          choice={@choice}
          token={@token}
          session_end={@session_end}
          now={@now}
          myself={@myself}
        />
        <.refusal refusal={@refusal} at={{:lifetime, @slot_key}} />
      </div>

      <.refusal refusal={@refusal} at={slot_refusal(@slot_key)} />

      <p :if={@lent_by} class="consent-sheet__note" data-test="grant-lent-switched">
        The default is now chosen here, not lent by {@lent_by}.
      </p>

      <div
        :for={account <- @accounts}
        class="consent-sheet__account space-y-1"
        data-test="grant-account"
        data-edge={@edge_label}
        data-account={account.choice.name}
      >
        <span :if={account.choice.fixed} class="font-medium" data-test="grant-account-name">
          {account.choice.name}
        </span>
        <form
          :if={!account.choice.fixed}
          id={account_form_id(@sheet, account.token)}
          phx-change="name_account"
          phx-submit="name_account"
          phx-target={@myself}
          class="consent-sheet__account-name"
        >
          <input type="hidden" name="slot" value={account.token} />
          <label class="text-xs">
            Account name
            <input
              type="text"
              name="name"
              value={account.choice.name}
              phx-debounce="300"
              data-test="grant-account-name"
              class="bg-transparent"
            />
          </label>
        </form>
        <p :if={account.why} class="consent-sheet__why" data-test="grant-account-why">
          {account.why}
        </p>

        <div class="consent-sheet__choices flex flex-wrap gap-2">
          <button
            :for={candidate <- @candidates}
            type="button"
            phx-click="pick_account"
            phx-target={@myself}
            phx-value-slot={account.token}
            {pick_values(candidate)}
            aria-pressed={to_string(candidate_pick(candidate) == account.pick)}
            data-test="grant-account-pick"
            class={choice_class(candidate_pick(candidate) == account.pick)}
          >
            {candidate.name}
            <span class="consent-sheet__fields">{candidate_words(candidate)}</span>
          </button>
        </div>

        <.field_map
          :if={account.pick != nil}
          form={map_form_id(@sheet, account.token)}
          token={account.token}
          candidate={Enum.find(@candidates, &(candidate_pick(&1) == account.pick))}
          need={@need}
          component={@component}
          choice={account.choice}
          myself={@myself}
        />

        <div
          class="consent-sheet__lifetime flex flex-wrap items-center gap-2"
          data-test="grant-account-lifetime"
        >
          <span :if={is_nil(account.choice.lifetime)} class="text-xs text-gray-400">
            The time this was granted until has passed. Choose how long it lives:
          </span>
          <span :if={is_map(account.choice.lifetime)} class="text-xs text-gray-400">
            How long it lives:
          </span>
          <.lifetime_buttons
            choice={account.choice}
            token={account.token}
            session_end={@session_end}
            now={@now}
            myself={@myself}
          />
          <button
            :if={account.renewable?}
            type="button"
            phx-click="renew"
            phx-target={@myself}
            phx-value-slot={account.token}
            aria-pressed={to_string(account.choice.renew)}
            data-test="grant-renew"
            class={choice_class(account.choice.renew)}
          >
            Grant once again
          </button>
        </div>

        <button
          type="button"
          phx-click="remove_account"
          phx-target={@myself}
          phx-value-slot={account.token}
          data-test="grant-account-remove"
          class="consent-sheet__choice"
        >
          Remove
        </button>
        <.refusal refusal={@refusal} at={{:lifetime, account.slot}} />
      </div>

      <button
        :if={@addable?}
        type="button"
        phx-click="add_account"
        phx-target={@myself}
        phx-value-slot={@token}
        data-test="grant-add-account"
        data-edge={@edge_label}
        class="consent-sheet__choice"
      >
        Add another account
      </button>
      <.refusal refusal={@refusal} at={{:add_account, @edge}} />
    </div>
    """
  end

  defp lent_by(%{lent_by: label}) when is_binary(label), do: label
  defp lent_by(_choice), do: nil

  attr :form, :string, required: true
  attr :token, :string, required: true
  attr :candidate, :map, default: nil
  attr :need, :map, required: true
  attr :component, :string, required: true
  attr :choice, :map, default: nil
  attr :myself, :any, required: true

  # The chosen entry's field map: each pair of the map it is bound under
  # whose names differ, and, where the plan has no automatic map or the
  # choice waits on an answer (a held map naming a field the entry no
  # longer holds), the question, asked once: one select per field the need
  # reads over the entry's fields, its answer selected.
  defp field_map(assigns) do
    candidate = assigns.candidate
    fields = (is_map(assigns.choice) && Map.get(assigns.choice, :fields)) || nil
    automatic = candidate && field(candidate, :fields)

    assigns =
      assign(assigns,
        asked:
          if(
            candidate &&
              (is_nil(automatic) or (is_map(assigns.choice) and map_pending?(assigns.choice))),
            do: List.wrap(field(assigns.need, :fields)),
            else: []
          ),
        answers: fields || %{},
        names: List.wrap(candidate && field(candidate, :field_names)),
        pairs:
          for(
            {need_field, entry_field} <- Enum.sort(fields || automatic || %{}),
            is_map(automatic) and need_field != entry_field,
            do: {need_field, entry_field}
          ),
        due?: is_map(assigns.choice) and map_pending?(assigns.choice)
      )

    ~H"""
    <div :if={@candidate} class="consent-sheet__map text-xs" data-test="grant-map">
      <p :for={{need_field, entry_field} <- @pairs} data-test="grant-map-pair">
        {need_field} comes from {entry_field}
      </p>
      <form
        :for={{need_field, index} <- Enum.with_index(@asked)}
        id={"#{@form}-#{index}"}
        phx-change="map_field"
        phx-submit="map_field"
        phx-target={@myself}
        data-test="grant-map-question"
        data-field={need_field}
      >
        <input type="hidden" name="slot" value={@token} />
        <input type="hidden" name="need_field" value={need_field} />
        <label>
          Which of {@candidate.name}'s fields does {@component} read as {need_field}?
          <select name="entry_field" class="bg-transparent">
            <option :if={!Map.has_key?(@answers, need_field)} value="" selected disabled></option>
            <option
              :for={name <- @names}
              value={name}
              selected={Map.get(@answers, need_field) == name}
            >
              {name}
            </option>
          </select>
        </label>
      </form>
      <p :if={@due?} class="text-amber-400" data-test="grant-map-due">
        Choose a field for each name before granting.
      </p>
    </div>
    """
  end

  # The id of a map question's forms, one per rendered sheet and slot, as
  # an account's name form is (`account_form_id/2`).
  defp map_form_id(sheet, token),
    do: "consent-sheet-#{sheet}-map-#{Base.url_encode64(token, padding: false)}"

  defp slot_events({:need, _need, _name}),
    do: %{pick: "pick_entry", clear: "clear_entry", values: %{}}

  defp slot_events({:dep, from, dep}),
    do: %{
      pick: "pick_dep",
      clear: "clear_dep",
      values: %{"phx-value-from" => from, "phx-value-dep" => dep}
    }

  defp slot_refusal({:need, need, _name}), do: {:need, need}
  defp slot_refusal({:dep, _from, _dep} = slot), do: slot

  defp pick_values(candidate) do
    case candidate_pick(candidate) do
      {"own", id} -> %{"phx-value-entry_id" => id}
      {"instance", id} -> %{"phx-value-instance_entry_id" => id}
      nil -> %{}
    end
  end

  # The entry a slot holds for this need, as a candidate's pick.
  defp chosen_pick(%{source: source, id: id} = choice, need, several)
       when source in ["own", "instance"] do
    if not several or Map.get(choice, :need) in [nil, field(need, :need)],
      do: {source, id}
  end

  defp chosen_pick(_choice, _need, _several), do: nil

  defp chosen_lender(%{source: "label", id: label}), do: label
  defp chosen_lender(_choice), do: nil

  defp suggested_pick(need) do
    case suggested(need) do
      %{entry_id: id} -> {"own", id}
      %{instance_entry_id: id} -> {"instance", id}
      nil -> nil
    end
  end

  defp components_path(route, component) do
    PrismWeb.Focus.path(
      route,
      "/components?" <> URI.encode_query(%{"ref" => component, "setup" => "true"})
    )
  end

  attr :row, :map, required: true
  attr :ask, :map, default: nil
  attr :myself, :any, required: true
  attr :approving?, :boolean, required: true
  attr :refusal, :map, default: nil
  attr :slot_key, :any, default: nil
  attr :choices, :map, default: %{}
  attr :head, :map, default: nil
  attr :session_end, :any, default: nil
  attr :now, :any, required: true

  # One row, in the sheet's own words, every value it carries shown, with
  # the node it is for, and the home's refusal of a choice made on it.
  # A credential row is one binding in one sentence — who uses it, whose
  # entry, the account, where its value may go and whether the component
  # reads it — then how long it lives, which the person chooses here.
  defp row(%{row: %{"kind" => "credential"}} = assigns) do
    choice = assigns.slot_key && Map.get(assigns.choices, assigns.slot_key)

    assigns =
      assign(assigns,
        choice: choice,
        controls?: assigns.approving? and is_map(choice),
        token: assigns.slot_key && slot_token(assigns.slot_key),
        renewable?: once_used?(assigns.head)
      )

    ~H"""
    <div class="consent-sheet__row" data-row="credential" data-node={@row["node"]}>
      <p class="consent-sheet__sentence">{credential_sentence(@row["node"], @row["values"])}</p>
      <div>Lifetime: {lifetime_label(@row["values"]["lifetime"])}</div>
      <div :if={@row["values"]["suggested"] == true}>Suggested</div>
      <div :if={@row["values"]["choice_required"] == true}>Choose which entry to use</div>
      <div>Fields: {field_map_label(@row["values"]["fields"], "none")}</div>
      <div>Scopes: {list_label(@row["values"]["scopes"], "none")}</div>
      <div class="font-mono text-xs">Binding: {@row["values"]["binding_key"]}</div>

      <div
        :if={@controls?}
        class="consent-sheet__lifetime flex flex-wrap items-center gap-2"
        data-test="grant-lifetime"
      >
        <span class="text-xs text-gray-400">How long it lives:</span>
        <.lifetime_buttons
          choice={@choice}
          token={@token}
          session_end={@session_end}
          now={@now}
          myself={@myself}
        />
        <button
          :if={@renewable?}
          type="button"
          phx-click="renew"
          phx-target={@myself}
          phx-value-slot={@token}
          aria-pressed={to_string(@choice.renew)}
          data-test="grant-renew"
          class={choice_class(@choice.renew)}
        >
          Grant once again
        </button>
      </div>
      <.refusal :if={@slot_key} refusal={@refusal} at={{:lifetime, @slot_key}} />
    </div>
    """
  end

  defp row(%{row: %{"kind" => kind}} = assigns) when kind in ["egress", "storage"] do
    controls? = assigns.approving? and is_map(assigns.ask)

    narrowing =
      if controls? and kind == "egress",
        do: get_and_head(assigns.row["node"], asked_methods(assigns.ask)),
        else: []

    assigns =
      assign(assigns,
        fields: Map.fetch!(@set_fields, kind),
        controls?: controls?,
        narrowing: narrowing
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
            phx-value-choice={value}
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
      <button
        :if={@narrowing != []}
        type="button"
        phx-click="get_head_only"
        phx-target={@myself}
        phx-value-node={@row["node"]}
        aria-pressed={to_string(Enum.sort(@row["values"]["methods"] || []) == Enum.sort(@narrowing))}
        data-test="grant-get-head-only"
        class={choice_class(Enum.sort(@row["values"]["methods"] || []) == Enum.sort(@narrowing))}
      >
        {methods_only_label(@narrowing)}
      </button>
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
            phx-value-choice={tool}
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
      <div>{placement_label(@row["values"]["placement"])}</div>
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

  # One exit and the classes its flows let reach it. Approving, each class
  # the ask lets reach it is a box: unticking removes that flow, ticking
  # keeps it again, and nothing adds a flow the ask does not name.
  defp row(%{row: %{"kind" => "exits"}} = assigns) do
    assigns =
      assign(assigns,
        controls?: assigns.approving? and is_map(assigns.ask),
        classes: choices(assigns.row, assigns.ask, "flows")
      )

    ~H"""
    <div
      class="consent-sheet__row"
      data-row="exits"
      data-node={@row["node"]}
      data-exit={@row["values"]["exit"]}
    >
      <.node_line row={@row} />
      <div>
        <span class="font-mono">{@row["values"]["exit"]}</span> — {exit_label(@row["values"]["exit"])}
      </div>
      <div class="consent-sheet__field" data-field="flows">
        <span>May carry what it read from:</span>
        <span :if={@classes == []}>nothing it reads</span>
        <label :for={{class, on?} <- @classes} class="consent-sheet__value">
          <input
            :if={@controls?}
            type="checkbox"
            phx-click="toggle_flow"
            phx-target={@myself}
            phx-value-node={@row["node"]}
            phx-value-exit={@row["values"]["exit"]}
            phx-value-choice={class}
            checked={on?}
          />
          <span class="font-mono">{class}</span>
        </label>
      </div>
      <.refusal refusal={@refusal} at={{"exits", @row["node"]}} />
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

  # The slot a previewed credential row binds: the default of the app's own
  # calls, or of the dependency's edge it rides. A named account's row is
  # chosen on its own row among the needs, so its preview row offers no
  # second control.
  defp row_slot(%{"kind" => "credential", "values" => %{"connection" => name}}, _choices)
       when is_binary(name),
       do: nil

  defp row_slot(%{"kind" => "credential", "node" => node, "values" => values}, choices) do
    case values["edge"] do
      "@ingress" ->
        Enum.find_value(choices, fn
          {{:need, _need, nil} = slot, _choice} -> slot
          _other -> nil
        end)

      edge when is_binary(edge) ->
        [dep | _need] = String.split(edge, "|", parts: 2)
        slot = {:dep, node, dep}
        if Map.has_key?(choices, slot), do: slot

      _none ->
        nil
    end
  end

  defp row_slot(_row, _choices), do: nil

  # What the profile's head holds at a previewed row's binding key.
  defp head_binding(plan, %{"kind" => "credential", "values" => %{"binding_key" => key}}) do
    plan
    |> field(:head_bindings)
    |> List.wrap()
    |> Enum.find(&(field(&1, :binding_key) == key))
  end

  defp head_binding(_plan, _row), do: nil

  # A head binding that lived once and was used: what "Grant once again"
  # renews.
  defp once_used?(%{} = head) do
    field(head, :consumed) == true and field(field(head, :lifetime), :kind) == "once"
  end

  defp once_used?(_head), do: false

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

  # The bindings of the profile's head the previewed grant removes.
  defp removed(preview), do: List.wrap(field(preview, :removed))

  # One removed binding in one line: the need it was bound for (on a
  # dependency's edge, of which dependency and from which node), its
  # account or the default, and its entry by name, else by its id or the
  # label of the profile that lent it.
  defp removal_line(item) do
    "Removes #{removed_need(item)} #{removed_slot(item)}: #{removed_entry(item)}"
  end

  defp removed_need(%{"edge" => "@ingress", "need" => need}),
    do: need || "a binding of this app's calls"

  defp removed_need(%{"edge" => edge, "node" => node, "need" => need}) do
    [dep | _need] = String.split(edge, "|", parts: 2)
    "#{need || "a binding"} of #{dep} from #{node}"
  end

  defp removed_slot(%{"connection" => name}) when is_binary(name), do: "account '#{name}'"
  defp removed_slot(_item), do: "default"

  defp removed_entry(%{"name" => name}) when is_binary(name), do: name
  defp removed_entry(%{"entry_id" => id}), do: id
  defp removed_entry(%{"instance_entry_id" => id}), do: id
  defp removed_entry(%{"via" => label}), do: "the key its '#{label}' profile lent"

  # Each value the ask names, and each the grant holds, with whether the
  # grant holds it.
  defp choices(row, ask, field) do
    granted = row["values"][field] || []
    asked = (ask && ask["values"][field]) || []
    Enum.map(Enum.uniq(asked ++ granted), &{&1, &1 in granted})
  end

  defp asked_methods(%{"values" => %{"methods" => methods}}) when is_list(methods), do: methods
  defp asked_methods(_ask), do: []

  defp folders(ask), do: Enum.filter(ask["values"]["paths"] || [], &String.ends_with?(&1, "/"))

  # What kind of place an exit is, in the person's words.
  defp exit_label("need:" <> need), do: "where its #{need} credential goes"
  defp exit_label("server:" <> server), do: "the tool server #{server}"
  defp exit_label(_domain), do: "a network destination"

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

  # A dependency whose stored manifest does not decode: damage, never a
  # component to install, and nothing can be granted over it.
  defp unresolved_sentence(%{reason: "corrupt_manifest", missing: ref}) when is_binary(ref),
    do: "The dependency #{ref} is stored damaged and cannot be granted."

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
  defp kind_heading("system_actions"), do: "System actions it may call"
  defp kind_heading("exits"), do: "Where what it reads may go"
  defp kind_heading(kind), do: kind

  # One binding in one sentence: the app or the dependency that uses it,
  # the entry and whose it is, the account, where its value may go and
  # whether the component reads it.
  defp credential_sentence(node, values) do
    name = values["name"]
    source = source_words(values["source"], node)

    used =
      case values["edge"] do
        "@ingress" ->
          "#{node} uses #{name}, #{source}, for its own calls"

        edge when is_binary(edge) ->
          {dep, need} =
            case String.split(edge, "|", parts: 2) do
              [dep, need] -> {dep, need}
              [dep] -> {dep, nil}
            end

          head =
            case values["label"] do
              label when is_binary(label) ->
                "#{dep} will use #{name}, #{source}, through its '#{label}' profile"

              _none ->
                "#{dep} uses #{name}, #{source}"
            end

          head <> ", from #{node}" <> if(need, do: " for its #{need} need", else: "")

        _none ->
          "#{node} uses #{name}, #{source}"
      end

    used =
      case values["connection"] do
        connection when is_binary(connection) -> used <> ", as the account '#{connection}'"
        _none -> used
      end

    account =
      case values["provider"] do
        provider when is_binary(provider) -> "a #{provider} account, "
        _none -> ""
      end

    "#{used}: #{account}sent only to #{destination_label(values["destination"])}. " <>
      disclosure_label(values["disclosed"])
  end

  # Whose credential a binding is: the athanor's own entry, an entry the
  # instance offers, or the public configuration the app's publisher
  # ships.
  defp source_words("own", _node), do: "an entry of this athanor"
  defp source_words("instance", _node), do: "provided by this instance"

  defp source_words("provided", node),
    do: "provided by #{publisher(node)}, the app's public configuration"

  defp source_words(source, _node), do: to_string(source)

  # The namespace that publishes a component.
  defp publisher(node) do
    case Prima.ComponentRef.parse(node || "") do
      {:ok, %{namespace: namespace}} when is_binary(namespace) -> namespace
      _unreadable -> "its publisher"
    end
  end

  defp need_words(need) do
    if declared?(need) do
      "#{field(need, :kind)} for #{hosts_words(need)}" <>
        if(field(need, :required) == true, do: ", required", else: ", optional") <>
        if(reads_itself?(need), do: "; the component reads the value itself", else: "")
    else
      "Any entry it reads itself, optional"
    end
  end

  # The hosts a need calls, as it declares them.
  defp hosts_words(need), do: need |> field(:hosts) |> List.wrap() |> Enum.join(", ")

  # Whose an entry is and where it may go; one that meets the need only
  # through a `*.` host says how wide each such host is.
  defp candidate_words(candidate) do
    whose = source_words(field(candidate, :source), nil)

    case field(candidate, :destination) do
      %{} = destination ->
        "#{whose}, sent only to #{destination_label(destination)}" <>
          breadth_words(field(candidate, :fit), destination)

      _none ->
        whose
    end
  end

  defp breadth_words("wildcard", destination) do
    for "*." <> base <- List.wrap(destination["hosts"]), into: "" do
      " (any name under #{base})"
    end
  end

  defp breadth_words(_fit, _destination), do: ""

  defp lender_words(dep, lender) do
    scopes = List.wrap(field(lender, :scopes))
    fields = field(lender, :fields)

    lends =
      cond do
        scopes != [] -> "scopes #{Enum.join(scopes, ", ")}"
        is_map(fields) and fields != %{} -> field_map_label(fields, "")
        true -> "its key"
      end

    "#{dep} uses it through its '#{field(lender, :label)}' profile, which lends #{lends}"
  end

  # Where a credential may go: its scheme and hosts, its port, and the
  # methods and path prefixes it is limited to, when it is.
  defp destination_label(%{} = destination) do
    [
      "#{destination["scheme"]}://#{list_label(destination["hosts"], "no host")}",
      if(destination["port"], do: " port #{destination["port"]}"),
      if(destination["methods"], do: ", methods #{list_label(destination["methods"], "")}"),
      if(destination["paths"], do: ", paths #{list_label(destination["paths"], "")}")
    ]
    |> Enum.join()
  end

  defp destination_label(_destination), do: ""

  # A value not disclosed to the component is one CYFR attaches to the
  # requests bound for the entry's destination, and the component never
  # holds it.
  defp disclosure_label(true), do: "The component reads the value itself."

  defp disclosure_label(_not_disclosed),
    do: "CYFR attaches the value and the component never holds it."

  defp lifetime_label(%{"kind" => "standing"}), do: "until revoked"
  defp lifetime_label(%{"kind" => "until", "until" => until}), do: "until #{until}"
  defp lifetime_label(%{"kind" => "once"}), do: "one run"
  defp lifetime_label(_lifetime), do: ""

  defp subject_label("*"), do: "— any subject"
  defp subject_label(subject) when is_binary(subject), do: "— for #{subject}"
  defp subject_label(_none), do: "— its own"

  # A canvas is read by what it reads: its streams are the rows below.
  defp placement_label("canvas"), do: "Can be a canvas, which reads the streams listed here"
  defp placement_label(placement) when is_binary(placement), do: "Placed: #{placement}"
  defp placement_label(_none), do: "Placed: where the shell places it"

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

  defp origin_label("interactive"), do: "when you use it (interactive)"
  defp origin_label("programmatic"), do: "by agents and scripts (programmatic)"
  defp origin_label("schedule"), do: "on a schedule (schedule)"
  defp origin_label("webhook"), do: "from webhooks (webhook)"
  defp origin_label(origin), do: origin

  # What changed since the head, by node: the app's own first, unheaded,
  # then each dependency under its ref, a new one as a new dependency and
  # one the release dropped as no longer used.
  defp delta_groups(plan, app) do
    {own, others} =
      (plan[:shape_diff] || [])
      |> Enum.group_by(&(&1[:node] || app))
      |> Map.split([app])

    own_group =
      for {node, entries} <- own, do: %{node: node, heading: nil, entries: entries}

    other_groups =
      for {node, entries} <- Enum.sort(others),
          do: %{node: node, heading: delta_heading(node, entries), entries: entries}

    own_group ++ other_groups
  end

  defp delta_heading(node, entries) do
    cond do
      Enum.any?(entries, & &1[:new]) -> "New dependency #{node}"
      Enum.any?(entries, & &1[:dropped]) -> "No longer used: #{node}"
      true -> node
    end
  end

  defp capability_label("tools"), do: "Tools:"
  defp capability_label("egress." <> field), do: "Network #{field}:"
  defp capability_label("storage." <> field), do: "Files #{field}:"
  defp capability_label("policy." <> mode), do: "Agent policy #{mode}:"
  defp capability_label(capability), do: "#{capability}:"

  # Each field the component reads and the entry field that answers it.
  defp field_map_label(fields, _none) when is_map(fields) and map_size(fields) > 0 do
    fields
    |> Enum.sort()
    |> Enum.map_join(", ", fn {need_field, entry_field} -> "#{need_field} from #{entry_field}" end)
  end

  defp field_map_label(_fields, none), do: none

  defp list_label([], none), do: none
  defp list_label(values, _none) when is_list(values), do: Enum.join(values, ", ")
  defp list_label(_values, none), do: none

  defp title(nil), do: "Loading…"
  defp title(%{expected_consent_revision: 0}), do: "Grant this app"
  defp title(%{expected_consent_revision: n}), do: "Update this grant (consent rev #{n})"
  defp title(_plan), do: "Grant this app"

  defp choice_class(true), do: "consent-sheet__choice consent-sheet__choice--selected"
  defp choice_class(_unselected), do: "consent-sheet__choice"

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

  defp warnings(plan), do: plan[:warnings] || []
end
