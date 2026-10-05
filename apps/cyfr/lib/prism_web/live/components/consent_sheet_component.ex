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
  naming what is missing, with no rows and nothing to commit. Beneath the
  rows, before the person confirms, it lists each binding of the
  profile's head the preview says the grant removes: the need it was
  bound for ("a binding of this app's calls" where that cannot be told),
  its account or "default", and its entry's name, else its id or the
  label of the profile that lent it.

  ## Credentials

  Each credential need, the app's own and each dependency's, is a row of
  its own: what it is, and what can meet it — the entries the plan names
  as its candidates, a profile of the dependency that lends its key, or
  the configuration the app's publisher provides, which takes no choice.
  The entry the plan suggests is preselected for a required need
  (`initial_choices/1`, which the grant prompt opens with), shown as the
  pressed choice with a "Change" control when there is another; an
  optional need shows its suggestion as a choice one click away, unbound;
  the slot of a manifest declaring no needs is never bound unasked. A
  re-grant opens instead on what its head binds, the entry and its
  lifetime, never wider than the head. The candidates open unasked only
  where the plan says a choice is required.
  A need nothing can meet offers "Connect your <provider> account" where
  it takes an API key: the layer's credential-entry prompt, prefilled from
  the need, in front of the grant, whose sheet comes back with the new
  entry bound. A need the component reads itself, with a newer version
  shipped, links to the Components page to update it.

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
  account name, distinct from the edge's others, compared case-folded),
  the need's candidates with none pressed, and the five lifetimes,
  standing pressed. A dependency's default a profile lends is first
  switched to the entry that profile lends, pressed, and the row says it
  is now chosen here; where the dependency's need for that entry cannot
  be told, no account is added and the row says why. Each account the
  head binds reopens as its own row, its name fixed, its entry pressed and
  its lifetime as a re-grant's is: a `once` stays `once`, an `until` still
  ahead keeps its time, and one that has passed opens with nothing
  pressed. "Remove" drops a row. A row whose name is missing, invalid or
  taken, or with no entry or no lifetime pressed, is no decision, so the
  grant is narrower than the head, never wider.

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
      wildcard ask whole or none), and the limits, each capped at the ask
      and sent only when lowered. Where a catalyst's network ask names
      methods beside GET and HEAD, one control narrows it to the GET and
      HEAD it asks for, named by those methods;
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
  (`replan: true`), after a commit that consumed the plan's token, it
  plans and previews the same choices again.
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

  # The needs an entry meets; any other names a component.
  @credential_kinds ~w(api_key oauth bundle)
  # The furthest an until-lifetime reaches: the home refuses one more
  # than 24 hours after its commit.
  @horizon_s 24 * 3600
  @spans %{"5m" => 300, "1h" => 3600}
  @read_methods ~w(GET HEAD)

  @typedoc "An edge a credential rides: the app's own calls for a need, or a dependency's edge."
  @type edge :: {:need, String.t()} | {:dep, String.t(), String.t()}

  @typedoc """
  A credential slot: the default of one of the app's needs, the default
  of a dependency's edge, or a named account on an edge, told apart from
  the edge's other accounts by its row's reference (`"name:<name>"` for an
  account the walk already held, `"row:<n>"` for one added here, whose
  name the person may still change).
  """
  @type slot ::
          {:need, String.t(), String.t() | nil}
          | {:dep, String.t(), String.t()}
          | {:account, edge(), String.t()}

  @typedoc """
  What a slot is bound to: an entry of the athanor (`"own"`), an instance
  entry (`"instance"`) or a lending profile's label (`"label"`); the
  dependency's need it is for, where it must be named; its lifetime as
  the wire spells it, the person's choice that made it, and `renew`. A
  named account also carries its `name`, whether that name is `fixed`,
  and the order it was added in (`seq`); its entry may not be chosen yet.
  A default switched from a lending profile names that profile
  (`lent_by`).
  """
  @type choice :: %{
          required(:source) => String.t() | nil,
          required(:id) => String.t() | nil,
          required(:need) => String.t() | nil,
          required(:lifetime) => map() | nil,
          required(:choice) => String.t() | nil,
          required(:renew) => boolean(),
          optional(:name) => String.t(),
          optional(:fixed) => boolean(),
          optional(:seq) => non_neg_integer(),
          optional(:lent_by) => String.t()
        }

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
        socket = socket |> assign(:started, true) |> from_walk(plan, walk)

        if Map.get(walk, :replan) == true do
          {:noreply, socket} =
            CyfrWeb.ContextGuard.guard(socket, fn socket ->
              {:noreply, socket |> load_plan() |> tell_layer()}
            end)

          {:ok, socket}
        else
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
    choices = held_choices(choices_of(decisions, plan), held, plan)

    # The account a grant was opened for is placed once, on the walk the
    # grant opens with; a walk drawn again holds the sheet's own rows.
    {choices, account_refusal} =
      if is_map(held), do: {choices, nil}, else: walk_account(plan, choices, walk)

    socket
    |> assign(
      plan: plan,
      preview: Map.get(walk, :preview),
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

  # The walk's account placed among its choices. The grant previewed its
  # default already switched from a lending profile, where it was one: that
  # default is marked as switched, as the person's own adding marks it.
  defp walk_account(plan, choices, %{account: %{name: _} = account}) do
    case open_account(plan, choices, account) do
      {:ok, placed} ->
        {mark_switched(placed, plan, account), nil}

      {:error, sentence} ->
        {choices, %{at: :account, message: sentence}}
    end
  end

  defp walk_account(_plan, choices, _walk), do: {choices, nil}

  defp mark_switched(choices, plan, account) do
    with {:ok, initial} <- open_account(plan, initial_choices(plan), account),
         {slot, %{lent_by: label} = switched} <-
           Enum.find(initial, fn {_slot, choice} -> Map.has_key?(choice, :lent_by) end),
         %{source: source, id: id} = held when source == switched.source and id == switched.id <-
           Map.get(choices, slot) do
      Map.put(choices, slot, Map.put(held, :lent_by, label))
    else
      _not_switched -> choices
    end
  end

  # The choices a walk's decisions hold, as the sheet held them when it
  # last handed the walk on (`held`): a sheet drawn again, as after a
  # credential entry, starts from them, so the lifetime the person pressed
  # for a binding the decisions hold unchanged stays pressed, an until
  # included, a binding whose lifetime is yet to be chosen, which no
  # decision carries, is still offered, and every named account's row is
  # the sheet's own, complete or not. A walk the grant opens with holds
  # none: its only such bindings are the head's whose time has passed.
  defp held_choices(decided, held, plan) do
    {base, decided} =
      if is_map(held),
        do: {held, Map.reject(decided, fn {slot, _choice} -> account_slot?(slot) end)},
        else: {pending(initial_choices(plan)), decided}

    named =
      Map.new(decided, fn {slot, choice} ->
        case Map.get(base, slot) do
          %{source: source, id: id, lifetime: lifetime, choice: name}
          when source == choice.source and id == choice.id and lifetime == choice.lifetime ->
            {slot, %{choice | choice: name}}

          _other ->
            {slot, choice}
        end
      end)

    accounts = if is_map(held), do: Map.filter(held, &account_slot?(elem(&1, 0))), else: %{}

    base |> pending() |> Map.merge(named) |> Map.merge(accounts)
  end

  defp pending(choices),
    do: Map.filter(choices, fn {_slot, choice} -> is_nil(choice.lifetime) end)

  # Why the grant opened with nothing bound: the home refused to preview
  # the plan's suggestions, in its own sentence, shown until a choice of
  # the person's previews.
  defp suggestion_refusal(sentence) when is_binary(sentence) and sentence != "",
    do: %{at: :suggestion, message: "The suggested entries were not bound: " <> sentence}

  defp suggestion_refusal(_none), do: nil

  defp origins_of(origins, _plan) when is_list(origins) and origins != [], do: in_order(origins)
  defp origins_of(_none, %{head_origins: [_ | _] = origins}), do: in_order(origins)
  defp origins_of(_none, _plan), do: [@interactive]

  defp subset_of(subset) when is_map(subset), do: subset
  defp subset_of(_none), do: %{}

  defp label_of(label) when is_binary(label) and label != "", do: label
  defp label_of(_none), do: nil

  defp session_end_of(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  defp session_end_of(%DateTime{} = at), do: at
  defp session_end_of(_none), do: nil

  # The origins named, `interactive` always among them, in the enum's order.
  defp in_order(origins) do
    named = [@interactive | Enum.map(origins, &to_string/1)]
    Enum.filter(Prima.Origin.spellings(), &(&1 in named))
  end

  # ---------------------------------------------------------------------------
  # The credential choices
  # ---------------------------------------------------------------------------

  @doc """
  The choices a grant opens with, by slot. A re-grant never opens wider
  than its head: an edge the head binds (`head_bindings`) reopens on what
  the head bound there, each named account on its own row under its
  fixed name, with its lifetime — a `once` stays `once`, an
  `until` still ahead keeps its time, and one that has passed reopens
  with no lifetime (`lifetime: nil`), which no decision carries until the
  person chooses one. A head binding whose need cannot be told (its entry
  is no need's candidate and there are several) leaves its edge unbound,
  and no suggestion takes its place. Any other edge takes the plan's
  suggestion: for the app, its first required declared credential need
  that has one, and for each dependency edge the app's configuration does
  not fill, the first required need of the dependency that has one — an
  edge carries one need's credentials, the app's own and a dependency's
  alike — each standing until revoked. An optional need, and the slot of
  a manifest that declares no needs, is bound by no one but the person.
  """
  @spec initial_choices(map()) :: %{slot() => choice()}
  def initial_choices(plan) when is_map(plan) do
    {held, held_edges} = head_choices(plan)

    source =
      if MapSet.member?(held_edges, :source) do
        %{}
      else
        plan
        |> field(:needs)
        |> List.wrap()
        |> Enum.find(&(declared?(&1) and field(&1, :required) == true and suggested(&1) != nil))
        |> case do
          nil -> %{}
          need -> %{{:need, field(need, :need), nil} => suggested_choice(suggested(need), nil)}
        end
      end

    suggested =
      for row <- List.wrap(field(plan, :dependency_needs)),
          slot <- [{:dep, field(row, :from), field(row, :dep)}],
          not MapSet.member?(held_edges, slot),
          not provided_edge?(row),
          need <- [
            Enum.find(row_needs(row), &(field(&1, :required) == true and suggested(&1) != nil))
          ],
          need != nil,
          into: source do
        named = if length(row_needs(row)) > 1, do: field(need, :need)

        {slot, suggested_choice(suggested(need), named)}
      end

    Map.merge(suggested, held)
  end

  # What the head binds, by the slot each binding reopens, and the edges
  # the head binds anything on (`:source` for the app's own calls), where
  # a suggestion then adds nothing. A binding whose need cannot be told is
  # left unbound: narrower than the head, never wider.
  defp head_choices(plan) do
    source_ref = field(plan, :source_ref)
    now = DateTime.utc_now()

    keyed =
      for head <- List.wrap(field(plan, :head_bindings)),
          {:ok, key} <- [Prima.Authority.Blob.parse_binding_key(field(head, :binding_key))],
          {_source, _id} = identity <- [head_identity(head)],
          do: {key, identity, head}

    held_edges =
      MapSet.new(keyed, fn
        {{^source_ref, "@ingress", _name}, _identity, _head} -> :source
        {{node, edge, _name}, _identity, _head} -> {:dep, node, edge_dep(edge)}
      end)

    held =
      for {key, {source, id} = identity, head} <- keyed,
          {slot, need} <- [head_slot(plan, source_ref, key, identity)],
          into: %{} do
        {lifetime, choice} = head_lifetime(field(head, :lifetime), now)

        held = %{
          source: source,
          id: id,
          need: need,
          lifetime: lifetime,
          choice: choice,
          renew: false
        }

        case slot do
          {:account, _edge, "name:" <> name} -> {slot, fixed_account(held, name)}
          _default -> {slot, held}
        end
      end

    {held, held_edges}
  end

  # A named account the walk already holds: its name is fixed.
  defp fixed_account(choice, name), do: Map.merge(choice, %{name: name, fixed: true, seq: 0})

  # What a head binding binds, as its `consent_vault_refs` row holds it.
  defp head_identity(head) do
    cond do
      is_binary(field(head, :entry_id)) -> {"own", field(head, :entry_id)}
      is_binary(field(head, :instance_entry_id)) -> {"instance", field(head, :instance_entry_id)}
      is_binary(field(head, :label)) -> {"label", field(head, :label)}
      true -> nil
    end
  end

  defp edge_dep(edge) do
    case Prima.Authority.Blob.edge_target(edge) do
      {:ok, dep} -> dep
      :ingress -> nil
    end
  end

  # The slot a head binding reopens: the app's own calls, for the need
  # whose candidates hold its entry (the one need, when the app has one);
  # or the dependency edge it sits on, naming the dependency's need where
  # it declares several. A binding whose need cannot be told, or whose
  # edge the plan no longer has or the app's configuration now fills,
  # reopens nowhere.
  defp head_slot(plan, source_ref, {source_ref, "@ingress", name}, {source, id})
       when source != "label" do
    needs = List.wrap(field(plan, :needs))

    case {Enum.filter(needs, &holds?(&1, id)), needs} do
      {[need], _needs} -> {named_slot({:need, field(need, :need)}, name), nil}
      {_none_or_several, [only]} -> {named_slot({:need, field(only, :need)}, name), nil}
      _unknown -> nil
    end
  end

  defp head_slot(plan, _source_ref, {node, edge, name}, {source, _id} = identity)
       when edge != "@ingress" and (is_nil(name) or source != "label") do
    with dep when is_binary(dep) <- edge_dep(edge),
         %{} = row <- dep_row(plan, node, dep),
         false <- provided_edge?(row),
         {:ok, need} <- edge_need(row_needs(row), edge, identity) do
      {named_slot({:dep, node, dep}, name), need}
    else
      _elsewhere -> nil
    end
  end

  defp head_slot(_plan, _source_ref, _key, _identity), do: nil

  # The slot of an edge's default (no name), or of the account it names.
  defp named_slot({:need, need}, nil), do: {:need, need, nil}
  defp named_slot({:dep, node, dep}, nil), do: {:dep, node, dep}
  defp named_slot(edge, name), do: {:account, edge, "name:" <> name}

  # The dependency's need a head binding on its edge is for: none to name
  # where the dependency declares one need or a profile lends; else the
  # need the edge names, or the one need whose candidates hold the entry.
  defp edge_need(needs, _edge, {source, _id}) when source == "label" or length(needs) <= 1,
    do: {:ok, nil}

  defp edge_need(needs, edge, {_source, id}) do
    case {String.split(edge, "|", parts: 2), Enum.filter(needs, &holds?(&1, id))} do
      {[_dep, named], _holding} ->
        if Enum.any?(needs, &(field(&1, :need) == named)), do: {:ok, named}, else: :unknown

      {_bare, [need]} ->
        {:ok, field(need, :need)}

      _unknown ->
        :unknown
    end
  end

  defp holds?(need, id) do
    Enum.any?(candidates_of(need), fn candidate ->
      field(candidate, :entry_id) == id or field(candidate, :instance_entry_id) == id
    end)
  end

  # A head binding's lifetime as it reopens: as it stands, or none when
  # the time it was granted until has passed.
  defp head_lifetime(lifetime, now) do
    case {field(lifetime, :kind), field(lifetime, :until)} do
      {"until", until} when is_binary(until) ->
        case DateTime.from_iso8601(until) do
          {:ok, at, _offset} ->
            if DateTime.compare(at, now) == :gt,
              do: {%{"kind" => "until", "until" => until}, nil},
              else: {nil, nil}

          _unreadable ->
            {nil, nil}
        end

      {kind, _until} when kind in ["standing", "once"] ->
        {%{"kind" => kind}, kind}

      _unknown ->
        {nil, nil}
    end
  end

  @doc """
  The decisions payload of a walk: the ref, the app's bindings and the
  dependencies' selections with their entries, lifetimes and `renew`, each
  edge's default first and then its named accounts under their names, the
  origins, and the label and narrowing when there are any, as
  `profile.preview` and `profile.commit` take them.
  """
  @spec decisions(String.t(), String.t() | nil, [String.t()], map(), %{slot() => choice()}) ::
          map()
  def decisions(ref, label, origins, subset, choices) do
    # A binding whose lifetime the person has yet to choose is no decision,
    # nor an account with no entry chosen or no name it can carry.
    sorted =
      choices
      |> Enum.filter(fn {slot, choice} -> decided?(slot, choice, choices) end)
      |> Enum.sort()

    accounts =
      Enum.sort_by(for({{:account, _, _}, _} = held <- sorted, do: held), &account_order/1)

    bindings =
      for({{:need, need, name}, choice} <- sorted, do: binding(need, name, choice)) ++
        for {{:account, {:need, need}, _ref}, choice} <- accounts,
            do: binding(need, choice.name, choice)

    selections =
      for({{:dep, from, dep}, choice} <- sorted, do: selection(from, dep, choice)) ++
        for {{:account, {:dep, from, dep}, _ref}, choice} <- accounts,
            do: Map.put(selection(from, dep, choice), "name", choice.name)

    %{"ref" => ref, "bindings" => bindings, "origins" => origins}
    |> then(&if selections == [], do: &1, else: Map.put(&1, "selections", selections))
    |> Prima.MapUtil.put_present("label", label)
    |> then(&if subset == %{}, do: &1, else: Map.put(&1, "subset", subset))
  end

  # Whether a choice is sent: a binding with a lifetime, and an account
  # with its entry, its lifetime and a name it can carry.
  defp decided?({:account, _edge, _ref} = slot, choice, choices) do
    is_map(choice.lifetime) and choice.source in ["own", "instance"] and is_binary(choice.id) and
      is_nil(account_problem(slot, choices))
  end

  defp decided?(_slot, choice, _choices), do: is_map(choice.lifetime)

  # The order accounts are sent in: by edge, then by name.
  defp account_order({{:account, edge, _ref}, choice}), do: {edge, choice.name}

  # The order an edge's accounts are drawn and judged in: those the walk
  # held first, then each as it was added.
  defp row_order({{:account, _edge, ref}, choice}),
    do: {if(Map.get(choice, :fixed), do: 0, else: 1), Map.get(choice, :seq, 0), ref}

  defp account_slot?({:account, _edge, _ref}), do: true
  defp account_slot?(_slot), do: false

  # The accounts on `edge`, in their rows' order.
  defp accounts_on(choices, edge) do
    choices
    |> Enum.filter(&match?({{:account, ^edge, _ref}, _choice}, &1))
    |> Enum.sort_by(&row_order/1)
  end

  # Why an account's name keeps its row out of the grant, or nil: a name
  # to give, one the binding key can carry, and one no earlier row of its
  # edge holds, compared case-folded as the home compares them.
  defp account_problem({:account, edge, _ref} = slot, choices) do
    name = Map.fetch!(choices, slot).name

    cond do
      name == "" ->
        "Name this account to grant it."

      not Prima.Authority.Blob.valid_account_name?(name) ->
        "An account's name is 1 to 128 bytes of text without a | or a control character."

      earlier = earlier_namesake(slot, name, accounts_on(choices, edge)) ->
        "Another account on this edge is named #{earlier}; each names its own."

      true ->
        nil
    end
  end

  defp earlier_namesake(slot, name, rows) do
    folded = String.downcase(name)

    rows
    |> Enum.take_while(fn {other, _choice} -> other != slot end)
    |> Enum.find_value(fn {_other, choice} ->
      if String.downcase(choice.name) == folded, do: choice.name
    end)
  end

  @doc """
  `decisions` with the entry `entry_id`, made through a credential-entry
  prompt raised for a need (`return: %{need}`) or a dependency
  (`return: %{from, dep, need}`), bound there standing: the need's
  default binding, the app's bindings of any other need dropped (the
  app's own calls carry one need's credentials), or the dependency's
  edge's default, its named accounts kept.
  """
  @spec bind_entered(map(), map(), String.t()) :: map()
  def bind_entered(%{} = decisions, %{dep: dep, from: from} = return, entry_id) do
    kept =
      decisions
      |> Map.get("selections", [])
      |> Enum.reject(&(&1["dep"] == dep and (&1["from"] || from) == from and is_nil(&1["name"])))

    selection =
      selection(from, dep, %{
        source: "own",
        id: entry_id,
        need: Map.get(return, :need),
        lifetime: %{"kind" => "standing"},
        renew: false
      })

    Map.put(decisions, "selections", kept ++ [selection])
  end

  def bind_entered(%{} = decisions, %{need: need}, entry_id) do
    kept =
      decisions
      |> Map.get("bindings", [])
      |> Enum.filter(&(&1["need"] == need and is_binary(&1["name"])))

    binding =
      binding(need, nil, %{
        source: "own",
        id: entry_id,
        lifetime: %{"kind" => "standing"},
        renew: false
      })

    Map.put(decisions, "bindings", [binding | kept])
  end

  defp binding(need, name, choice) do
    %{"need" => need, id_key(choice.source) => choice.id, "lifetime" => choice.lifetime}
    |> Prima.MapUtil.put_present("name", name)
    |> put_renew(choice)
  end

  defp selection(from, dep, choice) do
    %{
      "dep" => dep,
      "from" => from,
      id_key(choice.source) => choice.id,
      "lifetime" => choice.lifetime
    }
    |> then(fn item ->
      if choice.source != "label" and is_binary(Map.get(choice, :need)),
        do: Map.put(item, "need", choice.need),
        else: item
    end)
    |> put_renew(choice)
  end

  defp id_key("instance"), do: "instance_entry_id"
  defp id_key("label"), do: "label"
  defp id_key(_own), do: "entry_id"

  defp put_renew(item, %{renew: true}), do: Map.put(item, "renew", true)
  defp put_renew(item, _choice), do: item

  defp suggested_choice(%{entry_id: id}, need), do: new_choice("own", id, need)
  defp suggested_choice(%{instance_entry_id: id}, need), do: new_choice("instance", id, need)

  defp new_choice(source, id, need) do
    %{
      source: source,
      id: id,
      need: need,
      lifetime: %{"kind" => "standing"},
      choice: "standing",
      renew: false
    }
  end

  # The choices a walk's decisions hold, by slot, each named account on
  # its own row under its fixed name.
  defp choices_of(decisions, plan) do
    source_ref = field(plan, :source_ref)

    bindings =
      for %{"need" => need} = item <- List.wrap(decisions["bindings"]),
          {source, id} <- [held_id(item)],
          into: %{},
          do: held_slot({:need, need}, item, held_choice(item, source, id, nil))

    for %{"dep" => dep} = item <- List.wrap(decisions["selections"]),
        {source, id} <- [held_id(item) || {"label", "default"}],
        into: bindings,
        do:
          held_slot(
            {:dep, item["from"] || source_ref, dep},
            item,
            held_choice(item, source, id, item["need"])
          )
  end

  defp held_slot(edge, %{"name" => name}, choice) when is_binary(name),
    do: {named_slot(edge, name), fixed_account(choice, name)}

  defp held_slot(edge, _item, choice), do: {named_slot(edge, nil), choice}

  defp held_id(%{"entry_id" => id}) when is_binary(id), do: {"own", id}
  defp held_id(%{"instance_entry_id" => id}) when is_binary(id), do: {"instance", id}
  defp held_id(%{"label" => label}) when is_binary(label), do: {"label", label}
  defp held_id(_item), do: nil

  defp held_choice(item, source, id, need) do
    lifetime =
      case item["lifetime"] do
        %{"kind" => "until", "until" => until} when is_binary(until) ->
          %{"kind" => "until", "until" => until}

        %{"kind" => kind} when kind in ["standing", "once"] ->
          %{"kind" => kind}

        _standing ->
          %{"kind" => "standing"}
      end

    %{
      source: source,
      id: id,
      need: need,
      lifetime: lifetime,
      choice: if(lifetime["kind"] == "until", do: nil, else: lifetime["kind"]),
      renew: item["renew"] == true
    }
  end

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
        {:noreply,
         socket
         |> assign(
           :choices,
           Map.put(socket.assigns.choices, slot, %{held | source: source, id: id, renew: false})
         )
         |> walk_again({:lifetime, slot})}
      else
        _not_offered -> {:noreply, socket}
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

  # ---------------------------------------------------------------------------
  # Named accounts
  # ---------------------------------------------------------------------------

  @doc """
  `choices` with the named account `account` placed
  (`%{name, dep, from, need}`, as `PrismWeb.SystemLayer.grant_prompt/4`
  passes it: `dep` nil for the app's own calls, `from` nil for the
  grant's source, `need` nil for the edge's one credential need): as held
  when its edge already holds an account of that name, compared
  case-folded; otherwise a new row of that fixed name, no entry pressed
  and standing pressed, beside the edge's default as the grant otherwise
  opens it, a default a profile lends first switched to the entry it
  lends. `{:error, sentence}` when the plan has no edge or need for it,
  or the lent default cannot be switched.
  """
  @spec open_account(map(), %{slot() => choice()}, map()) ::
          {:ok, %{slot() => choice()}} | {:error, String.t()}
  def open_account(plan, choices, %{name: name} = account) when is_binary(name) do
    with {:ok, edge, need} <- account_edge(plan, account),
         {:ok, choices, _default_need} <- account_default(plan, choices, edge) do
      folded = String.downcase(name)

      if Enum.any?(accounts_on(choices, edge), &(String.downcase(elem(&1, 1).name) == folded)),
        do: {:ok, choices},
        else:
          {:ok,
           Map.put(
             choices,
             named_slot(edge, name),
             fixed_account(new_choice(nil, nil, need), name)
           )}
    end
  end

  # The edge and need a named account sits on, as the plan has them.
  defp account_edge(plan, %{name: name, dep: nil} = account) do
    source = field(plan, :source_ref)
    needs = plan |> field(:needs) |> List.wrap() |> Enum.filter(&declared?/1)

    case {Map.get(account, :need), needs} do
      {nil, [one]} ->
        {:ok, {:need, field(one, :need)}, nil}

      {nil, []} ->
        no_place(name, "#{source}'s own calls take no credential")

      {nil, _several} ->
        no_place(
          name,
          "#{source}'s own calls declare several credential needs, and it names none of them"
        )

      {need, needs} ->
        if Enum.any?(needs, &(field(&1, :need) == need)),
          do: {:ok, {:need, need}, nil},
          else: no_place(name, "#{source} declares no credential need #{need}")
    end
  end

  defp account_edge(plan, %{name: name, dep: dep} = account) when is_binary(dep) do
    from = Map.get(account, :from) || field(plan, :source_ref)

    case dep_row(plan, from, dep) do
      nil ->
        no_place(name, "#{dep} is no dependency #{from} calls in this grant")

      row ->
        needs = row_needs(row)
        need = Map.get(account, :need)

        cond do
          provided_edge?(row) ->
            no_place(name, "this app provides #{dep}'s credential")

          is_binary(need) and not Enum.any?(needs, &(field(&1, :need) == need)) ->
            no_place(name, "#{dep} declares no credential need #{need}")

          is_binary(need) ->
            {:ok, {:dep, from, dep}, if(length(needs) > 1, do: need)}

          length(needs) == 1 ->
            {:ok, {:dep, from, dep}, nil}

          true ->
            no_place(name, "#{dep} declares several credential needs, and it names none of them")
        end
    end
  end

  defp account_edge(_plan, %{name: name}), do: no_place(name, "it names no edge of this grant")

  defp no_place(name, why),
    do: {:error, "The account #{name} is not added to this grant: #{why}."}

  # The default an account sits beside: the app's need's, as it stands; a
  # dependency's, which a profile lending its key is first switched to the
  # entry that profile lends, since an account sits beside an entry
  # chosen here. Answers the choices and the default's need.
  defp account_default(_plan, choices, {:need, _need}), do: {:ok, choices, nil}

  defp account_default(plan, choices, {:dep, from, dep}) do
    slot = {:dep, from, dep}

    case Map.get(choices, slot) do
      %{source: "label", id: label} = default ->
        with {:ok, source, id, need} <- switch_lent(dep_row(plan, from, dep), dep, label) do
          switched =
            %{default | source: source, id: id, need: need, renew: false}
            |> Map.put(:lent_by, label)

          {:ok, Map.put(choices, slot, switched), need}
        end

      %{need: need} ->
        {:ok, choices, need}

      nil ->
        {:ok, choices, nil}
    end
  end

  # The entry the `label` profile lends, as the plan's lender candidate
  # names it, and the dependency's need it fills: none to name where the
  # dependency declares one need, else the one need whose candidates hold
  # it.
  defp switch_lent(row, dep, label) do
    lender =
      row |> field(:candidates) |> List.wrap() |> Enum.find(&(field(&1, :label) == label))

    with %{} <- lender,
         id when is_binary(id) <- field(lender, :entry_id),
         source when source in ["own", "instance"] <- field(lender, :source) do
      case {row_needs(row), Enum.filter(row_needs(row), &holds?(&1, id))} do
        {[_one], _holding} ->
          {:ok, source, id, nil}

        {_several, [need]} ->
          {:ok, source, id, field(need, :need)}

        _cannot_tell ->
          {:error,
           "No account is added: none of #{dep}'s needs can be told for the key its #{label} " <>
             "profile lends, which an account would sit beside."}
      end
    else
      _unread ->
        {:error,
         "No account is added: the key #{dep}'s #{label} profile lends cannot be read here, and " <>
           "an account sits beside a key chosen here."}
    end
  end

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

  # The accounts a dependency's need draws: all of the edge's when the
  # dependency declares one need; else those for this need, and the first
  # need draws any that names none.
  defp dep_accounts(plan, choices, row, need, index) do
    several? = length(row_needs(row)) > 1

    account_rows(plan, choices, {:dep, row.from, row.dep}, fn choice ->
      not several? or choice.need == field(need, :need) or (is_nil(choice.need) and index == 0)
    end)
  end

  # The head's binding of the account `name` on `edge`.
  defp account_head(plan, edge, name) do
    source_ref = field(plan, :source_ref)

    plan
    |> field(:head_bindings)
    |> List.wrap()
    |> Enum.find(fn head ->
      case {edge, Prima.Authority.Blob.parse_binding_key(field(head, :binding_key))} do
        {{:need, _need}, {:ok, {^source_ref, "@ingress", ^name}}} -> true
        {{:dep, from, dep}, {:ok, {node, key, ^name}}} -> node == from and edge_dep(key) == dep
        _other -> false
      end
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
  # it; the candidates close once chosen.
  defp choose(socket, slot, source, id, need) do
    choice =
      case Map.get(socket.assigns.choices, slot) do
        %{} = held -> %{held | source: source, id: id, need: need, renew: false}
        nil -> new_choice(source, id, need)
      end

    assign(socket,
      choices: Map.put(socket.assigns.choices, slot, choice),
      opened: MapSet.delete(socket.assigns.opened, slot)
    )
  end

  # Every choice previews the walk again and hands it to the layer. Called
  # inside the event's own guard, naming the control that made the choice
  # (`at`), beside which a refusal is shown.
  defp walk_again(socket, at), do: socket |> preview(at) |> tell_layer()

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

  # The lifetime a choice sends, computed now: standing and once as they
  # are; five minutes and an hour from now; this session, the earlier of
  # the session's end and 24 hours from now, offered only while there is
  # a session end ahead.
  defp lifetime_of(choice, _session_end, _now) when choice in ["standing", "once"],
    do: {:ok, %{"kind" => choice}}

  defp lifetime_of(choice, _session_end, now) when is_map_key(@spans, choice),
    do: {:ok, until(DateTime.add(now, Map.fetch!(@spans, choice), :second))}

  defp lifetime_of("session", session_end, now) do
    case session_until(session_end, now) do
      %DateTime{} = at -> {:ok, until(at)}
      nil -> :error
    end
  end

  defp lifetime_of(_choice, _session_end, _now), do: :error

  defp until(%DateTime{} = at),
    do: %{"kind" => "until", "until" => at |> DateTime.truncate(:second) |> DateTime.to_iso8601()}

  defp session_until(%DateTime{} = session_end, %DateTime{} = now) do
    if DateTime.compare(session_end, now) == :gt do
      horizon = DateTime.add(now, @horizon_s, :second)
      if DateTime.compare(session_end, horizon) == :lt, do: session_end, else: horizon
    end
  end

  defp session_until(_none, _now), do: nil

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
              choices: last.choices,
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

  # A plan answered through `PrismWeb.Ops` is atom-keyed; a field read
  # here takes either spelling.
  defp field(nil, _key), do: nil
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp declared?(need), do: field(need, :kind) in @credential_kinds

  defp suggested(need) do
    case field(need, :suggested) do
      %{entry_id: id} = suggested when is_binary(id) -> suggested
      %{instance_entry_id: id} = suggested when is_binary(id) -> suggested
      %{"entry_id" => id} when is_binary(id) -> %{entry_id: id}
      %{"instance_entry_id" => id} when is_binary(id) -> %{instance_entry_id: id}
      _none -> nil
    end
  end

  defp row_needs(row), do: List.wrap(field(row, :needs))

  defp provided_edge?(row), do: Enum.any?(row_needs(row), &(field(&1, :source) == "provided"))

  defp dep_row(plan, from, dep) do
    plan
    |> field(:dependency_needs)
    |> List.wrap()
    |> Enum.find(&(field(&1, :from) == from and field(&1, :dep) == dep))
  end

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

  defp candidates_of(need), do: List.wrap(field(need, :candidates))

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

  # The athanor holds an entry of the need's kind and provider that the
  # component may not read: why a need it reads itself has no candidate.
  defp attach_only_held?(plan, need) do
    Enum.any?(List.wrap(field(plan, :candidates)), fn entry ->
      field(entry, :attach_only) == true and field(entry, :kind) == field(need, :kind) and
        field(entry, :provider_hint) == field(need, :provider)
    end)
  end

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

        <section class="consent-sheet__needs space-y-2" data-test="grant-needs">
          <h4 class="font-medium">Vault entries</h4>
          <.refusal refusal={@refusal} at={:suggestion} />
          <.refusal refusal={@account_refusal} at={:account} />
          <p :if={asks_no_credentials?(@plan)} class="consent-sheet__empty">
            This app asks for no credentials.
          </p>

          <.need
            :for={need <- List.wrap(@plan[:needs])}
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
            plan={@plan}
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
              plan={@plan}
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
              ask={ask_row(@plan, kind, row["node"])}
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
  attr :plan, :map, required: true
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

    assigns =
      assign(assigns,
        provided?: provided?,
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

      <p
        :if={
          not @provided? and @candidates == [] and reads_itself?(@need) and declared?(@need) and
            attach_only_held?(@plan, @need)
        }
        class="consent-sheet__why"
        data-test="grant-why"
      >
        {@component} reads the value itself, so only an entry you let it read can meet this
        need: your {field(@need, :provider)} entries are attach-only, and it never holds their
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
        for {field(@need, :provider)} first.
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
      <div>Fields: {list_label(@row["values"]["fields"], "none")}</div>
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
      "#{field(need, :kind)} for #{field(need, :provider)}" <>
        if(field(need, :required) == true, do: ", required", else: ", optional") <>
        if(reads_itself?(need), do: "; the component reads the value itself", else: "")
    else
      "Any entry it reads itself, optional"
    end
  end

  defp candidate_words(candidate) do
    whose = source_words(field(candidate, :source), nil)

    case field(candidate, :destination) do
      %{} = destination -> "#{whose}, sent only to #{destination_label(destination)}"
      _none -> whose
    end
  end

  defp lender_words(dep, lender) do
    scopes = List.wrap(field(lender, :scopes))
    fields = List.wrap(field(lender, :fields))

    lends =
      cond do
        scopes != [] -> "scopes #{Enum.join(scopes, ", ")}"
        fields != [] -> Enum.join(fields, ", ")
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

  defp warnings(plan), do: plan[:warnings] || plan["warnings"] || []
end
