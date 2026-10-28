# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.ConsentChoices do
  @moduledoc """
  The consent sheet's choices, as pure functions over the plan's typed
  rows (`Sanctum.Consent.Plan`) and an explicit `now`: the choices a
  grant opens with and a walk reopens on, the decisions they serialize
  to as `profile.preview` and `profile.commit` take them, a binding's
  lifetime, a narrowed limit and the flows kept to a node's exits. They read no clock, socket, store or
  process and call nothing but Prima's grammars; what a head binding
  binds, where it sits and the need it was bound for are the plan's
  (`head_bindings`), never told here again. `PrismWeb.ConsentSheetComponent`
  renders the walk, takes its events and does its I/O, and
  `PrismWeb.SystemLayer` opens a grant's first walk from here.

  A choice is keyed by its slot: the default of one of the app's needs,
  the default of a dependency's edge, or a named account on an edge.

  A choice of an entry carries the field map it is bound under where one
  is sent (`mapped/2`): the map the person chose, or the head's re-sent
  on a re-grant. Where the entry's candidate has no automatic map, the
  need fields still to be mapped keep the choice out of the decisions
  until each has an entry field (`answer_map/5`).
  """

  @interactive "interactive"
  @integer_limits ~w(max_memory_bytes max_request_size max_response_size max_concurrent_tasks)
  @duration_limits ~w(timeout batch_timeout)

  # The needs an entry meets; any other names a component.
  @credential_kinds Prima.CredentialKinds.all()
  # The furthest an until-lifetime reaches: the home refuses one more
  # than 24 hours after its commit.
  @horizon_s 24 * 3600
  @spans %{"5m" => 300, "1h" => 3600}

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
  (`lent_by`). A choice of an entry may carry the map it sends, from each
  field the need reads to the entry field that answers it (`fields`),
  and, while the person has yet to map some of them, those need fields
  (`unmapped`), `fields` then holding the ones mapped so far.
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
          optional(:lent_by) => String.t(),
          optional(:fields) => %{optional(String.t()) => String.t()},
          optional(:unmapped) => [String.t(), ...]
        }

  # The walk's account placed among its choices. The grant previewed its
  # default already switched from a lending profile, where it was one: that
  # default is marked as switched, as the person's own adding marks it.
  def walk_account(plan, choices, %{account: %{name: _} = account}, now) do
    case open_account(plan, choices, account) do
      {:ok, placed} ->
        {mark_switched(placed, plan, account, now), nil}

      {:error, sentence} ->
        {choices, %{at: :account, message: sentence}}
    end
  end

  def walk_account(_plan, choices, _walk, _now), do: {choices, nil}

  defp mark_switched(choices, plan, account, now) do
    with {:ok, initial} <- open_account(plan, initial_choices(plan, now), account),
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
  # decision carries, is still offered, as is one whose field map the
  # person has yet to choose, and every named account's row is the
  # sheet's own, complete or not. A walk the grant opens with holds none:
  # its only such bindings are the head's whose time has passed and those
  # whose map is still to be chosen.
  def held_choices(decided, held, plan, now) do
    {base, decided} =
      if is_map(held),
        do: {held, Map.reject(decided, fn {slot, _choice} -> account_slot?(slot) end)},
        else: {pending(initial_choices(plan, now)), decided}

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
    do:
      Map.filter(choices, fn {_slot, choice} ->
        is_nil(choice.lifetime) or map_pending?(choice)
      end)

  def origins_of(origins, _plan) when is_list(origins) and origins != [], do: in_order(origins)
  def origins_of(_none, %{head_origins: [_ | _] = origins}), do: in_order(origins)
  def origins_of(_none, _plan), do: [@interactive]

  def subset_of(subset) when is_map(subset), do: subset
  def subset_of(_none), do: %{}

  def label_of(label) when is_binary(label) and label != "", do: label
  def label_of(_none), do: nil

  def session_end_of(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  def session_end_of(%DateTime{} = at), do: at
  def session_end_of(_none), do: nil

  # The origins named, `interactive` always among them, in the enum's order.
  def in_order(origins) do
    named = [@interactive | Enum.map(origins, &to_string/1)]
    Enum.filter(Prima.Origin.spellings(), &(&1 in named))
  end

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
  Each choice is held to its field map (`mapped/2`): a head binding
  re-sends the map its head holds while the entry still holds every
  field it names, and asks again where it does not.
  """
  @spec initial_choices(map(), DateTime.t()) :: %{slot() => choice()}
  def initial_choices(plan, %DateTime{} = now) when is_map(plan) do
    {held, held_edges} = head_choices(plan, now)

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

    suggested |> Map.merge(held) |> mapped(plan)
  end

  # What the head binds, by the slot each binding reopens, and the edges
  # the head binds anything on (`:source` for the app's own calls), where
  # a suggestion then adds nothing. A binding whose need cannot be told is
  # left unbound: narrower than the head, never wider.
  defp head_choices(plan, now) do
    source_ref = field(plan, :source_ref)

    placed =
      for head <- List.wrap(field(plan, :head_bindings)),
          {:ok, place} <- [placed(head)],
          do: {place, head}

    held_edges =
      MapSet.new(placed, fn
        {%{node: ^source_ref, edge: "@ingress"}, _head} -> :source
        {%{node: node, dep: dep}, _head} -> {:dep, node, dep}
      end)

    held =
      for {place, head} <- placed,
          {slot, need} <- [head_slot(plan, source_ref, place)],
          into: %{} do
        {lifetime, choice} = head_lifetime(field(head, :lifetime), now)

        held =
          put_fields(
            %{
              source: place.source,
              id: place.id,
              need: need,
              lifetime: lifetime,
              choice: choice,
              renew: false
            },
            field(head, :fields)
          )

        case slot do
          {:account, _edge, "name:" <> name} -> {slot, fixed_account(held, name)}
          _default -> {slot, held}
        end
      end

    {held, held_edges}
  end

  # A named account the walk already holds: its name is fixed.
  defp fixed_account(choice, name), do: Map.merge(choice, %{name: name, fixed: true, seq: 0})

  # A head binding as the plan places it (`Sanctum.Consent.Plan`, whose
  # head rows `Sanctum.Consent.Commit` reads): what it binds, where it
  # sits — its node, edge, the dependency the edge reaches and its
  # account's name — and the need it was bound for, nil where that cannot
  # be told. A row the plan could not place reopens nowhere.
  defp placed(head) do
    with source when source in ["own", "instance", "label"] <- field(head, :source),
         id when is_binary(id) <- field(head, id_field(source)),
         node when is_binary(node) <- field(head, :node),
         edge when is_binary(edge) <- field(head, :edge) do
      {:ok,
       %{
         source: source,
         id: id,
         node: node,
         edge: edge,
         dep: field(head, :dep),
         name: field(head, :connection),
         need: field(head, :need)
       }}
    else
      _unplaced -> :error
    end
  end

  defp id_field("own"), do: :entry_id
  defp id_field("instance"), do: :instance_entry_id
  defp id_field("label"), do: :label

  # The slot a head binding reopens: the app's own calls, for the need it
  # was bound for; or the dependency edge it sits on, naming the
  # dependency's need where it declares several. A binding whose need
  # cannot be told, or whose edge the plan no longer has or the app's
  # configuration now fills, reopens nowhere.
  defp head_slot(plan, source_ref, %{node: source_ref, edge: "@ingress", source: source} = place)
       when source != "label" do
    needs = List.wrap(field(plan, :needs))

    if is_binary(place.need) and Enum.any?(needs, &(field(&1, :need) == place.need)),
      do: {named_slot({:need, place.need}, place.name), nil}
  end

  defp head_slot(plan, _source_ref, %{edge: edge, dep: dep, name: name, source: source} = place)
       when edge != "@ingress" and is_binary(dep) and (is_nil(name) or source != "label") do
    with %{} = row <- dep_row(plan, place.node, dep),
         false <- provided_edge?(row),
         {:ok, need} <- edge_need(row_needs(row), place) do
      {named_slot({:dep, place.node, dep}, name), need}
    else
      _elsewhere -> nil
    end
  end

  defp head_slot(_plan, _source_ref, _place), do: nil

  # The dependency's need a head binding on its edge is for: none to name
  # where the dependency declares one need or a profile lends; else the
  # need it was bound for, one the dependency still declares.
  defp edge_need(needs, %{source: source}) when source == "label" or length(needs) <= 1,
    do: {:ok, nil}

  defp edge_need(needs, %{need: need}) do
    if is_binary(need) and Enum.any?(needs, &(field(&1, :need) == need)),
      do: {:ok, need},
      else: :unknown
  end

  @doc """
  The head's binding of the account `name` on `edge`, as the plan places
  it, or nil.
  """
  @spec account_head(map(), edge(), String.t()) :: map() | nil
  def account_head(plan, edge, name) do
    source_ref = field(plan, :source_ref)

    plan
    |> field(:head_bindings)
    |> List.wrap()
    |> Enum.find(fn head ->
      case {edge, placed(head)} do
        {{:need, _need}, {:ok, %{node: ^source_ref, edge: "@ingress", name: ^name}}} ->
          true

        {{:dep, from, dep}, {:ok, %{node: node, dep: held, name: ^name}}} ->
          node == from and held == dep

        _other ->
          false
      end
    end)
  end

  # The slot of an edge's default (no name), or of the account it names.
  def named_slot({:need, need}, nil), do: {:need, need, nil}
  def named_slot({:dep, node, dep}, nil), do: {:dep, node, dep}
  def named_slot(edge, name), do: {:account, edge, "name:" <> name}

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
  dependencies' selections with their entries, lifetimes, `renew` and the
  field map an entry is bound under where the choice holds one
  (`fields`; a lending profile's label never sends one), each edge's
  default first and then its named accounts under their names, the
  origins, and the label and narrowing when there are any, as
  `profile.preview` and `profile.commit` take them.
  """
  @spec decisions(String.t(), String.t() | nil, [String.t()], map(), %{slot() => choice()}) ::
          map()
  def decisions(ref, label, origins, subset, choices) do
    # A binding whose lifetime or field map the person has yet to choose is
    # no decision, nor an account with no entry chosen or no name it can
    # carry.
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

  # Whether a choice is sent: a binding with a lifetime and every field it
  # reads mapped, and an account with its entry, its lifetime, its map and
  # a name it can carry.
  defp decided?({:account, _edge, _ref} = slot, choice, choices) do
    is_map(choice.lifetime) and choice.source in ["own", "instance"] and is_binary(choice.id) and
      not map_pending?(choice) and is_nil(account_problem(slot, choices))
  end

  defp decided?(_slot, choice, _choices),
    do: is_map(choice.lifetime) and not map_pending?(choice)

  # The order accounts are sent in: by edge, then by name.
  defp account_order({{:account, edge, _ref}, choice}), do: {edge, choice.name}

  # The order an edge's accounts are drawn and judged in: those the walk
  # held first, then each as it was added.
  defp row_order({{:account, _edge, ref}, choice}),
    do: {if(Map.get(choice, :fixed), do: 0, else: 1), Map.get(choice, :seq, 0), ref}

  def account_slot?({:account, _edge, _ref}), do: true
  def account_slot?(_slot), do: false

  # The accounts on `edge`, in their rows' order.
  def accounts_on(choices, edge) do
    choices
    |> Enum.filter(&match?({{:account, ^edge, _ref}, _choice}, &1))
    |> Enum.sort_by(&row_order/1)
  end

  # Why an account's name keeps its row out of the grant, or nil: a name
  # to give, one the binding key can carry, and one no earlier row of its
  # edge holds, compared by Unicode's full lowercase mapping as the home
  # compares them (`Prima.Authority.Blob.same_account_name?/2`).
  def account_problem({:account, edge, _ref} = slot, choices) do
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
    rows
    |> Enum.take_while(fn {other, _choice} -> other != slot end)
    |> Enum.find_value(fn {_other, choice} ->
      if Prima.Authority.Blob.same_account_name?(choice.name, name), do: choice.name
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
    |> put_map(choice)
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
    |> put_map(choice)
    |> put_renew(choice)
  end

  defp id_key("instance"), do: "instance_entry_id"
  defp id_key("label"), do: "label"
  defp id_key(_own), do: "entry_id"

  defp put_renew(item, %{renew: true}), do: Map.put(item, "renew", true)
  defp put_renew(item, _choice), do: item

  # The map a choice of an entry is bound under, when it holds one; a
  # lending profile's label lends its lender's map and names none.
  defp put_map(item, %{source: source, fields: %{} = fields}) when source in ["own", "instance"],
    do: Map.put(item, "fields", fields)

  defp put_map(item, _choice), do: item

  defp put_fields(choice, %{} = fields), do: Map.put(choice, :fields, fields)
  defp put_fields(choice, _none), do: choice

  defp suggested_choice(%{entry_id: id}, need), do: new_choice("own", id, need)
  defp suggested_choice(%{instance_entry_id: id}, need), do: new_choice("instance", id, need)

  def new_choice(source, id, need) do
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
  def choices_of(decisions, plan) do
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

    put_fields(
      %{
        source: source,
        id: id,
        need: need,
        lifetime: lifetime,
        choice: if(lifetime["kind"] == "until", do: nil, else: lifetime["kind"]),
        renew: item["renew"] == true
      },
      if(source != "label", do: item["fields"])
    )
  end

  @doc """
  `choices` with each choice of an entry held to the field map it is
  bound under, against the need and the entry's candidate the plan
  answers (`Sanctum.Consent.Plan`'s `field_names` and `fields`). A map the
  choice holds, the person's or the head's, is kept while it names each
  field the need reads once and only fields the entry holds. Otherwise a
  choice holding no map, of a candidate with an automatic map, sends none,
  and the commit takes that one. Any other asks: each answer held that the
  entry still holds is kept, a need field with no held answer is
  preselected to the entry field of its own name where the entry holds
  one, and the rest, a held answer naming a field the entry no longer
  holds among them, are `unmapped`, so a stale map is asked again whatever
  the candidate's automatic map. A choice already waiting on the person
  keeps waiting on the same fields however often it is held to the plan
  again, with the answers the entry still holds. A lending profile's label, and the slot of a
  manifest declaring no needs, whose map is the entry's own field names,
  carry none. A choice whose entry or need the plan does not name keeps
  a whole map it holds, drops a half-answered one and asks nothing, for
  the home to judge.
  """
  @spec mapped(%{slot() => choice()}, map()) :: %{slot() => choice()}
  def mapped(choices, plan) do
    Map.new(choices, fn {slot, choice} -> {slot, map_choice(plan, slot, choice)} end)
  end

  defp map_choice(plan, slot, choice) do
    case map_target(plan, slot, choice) do
      {:ok, need, candidate} ->
        need_fields = need_fields(need)
        names = List.wrap(field(candidate, :field_names))
        held = Map.get(choice, :fields)

        cond do
          # A choice waiting on the person keeps what it waits for: its
          # answers the entry still holds, and nothing guessed for the rest,
          # however often the choices are held to the plan.
          map_pending?(choice) ->
            settle(choice, need_fields, held_answers(held, need_fields, names))

          total_map?(held, need_fields, names) ->
            choice

          held in [nil, %{}] and is_map(field(candidate, :fields)) ->
            unmap(choice)

          true ->
            settle(choice, need_fields, preselected(held, need_fields, names))
        end

      :no_map ->
        unmap(choice)

      # No question can be shown for an entry the plan no longer offers,
      # so none is left waiting on one.
      :unknown ->
        if map_pending?(choice), do: unmap(choice), else: choice
    end
  end

  @doc """
  `choices` with the person's answer to the map question of `slot`: the
  need field `need_field` read from the entry field `entry_field`.
  `:error` unless the question is asked (the slot's entry is a candidate
  with no automatic map, or its choice waits on an answer), the need reads
  `need_field` and the entry holds `entry_field`.
  """
  @spec answer_map(%{slot() => choice()}, map(), slot(), String.t(), String.t()) ::
          {:ok, %{slot() => choice()}} | :error
  def answer_map(choices, plan, slot, need_field, entry_field) do
    with %{} = choice <- Map.get(choices, slot),
         {:ok, need, candidate} <- map_target(plan, slot, choice),
         true <- is_nil(field(candidate, :fields)) or map_pending?(choice),
         true <- need_field in need_fields(need),
         true <- entry_field in List.wrap(field(candidate, :field_names)) do
      fields = choice |> Map.get(:fields, %{}) |> Map.put(need_field, entry_field)
      {:ok, Map.put(choices, slot, settle(choice, need_fields(need), fields))}
    else
      _not_asked -> :error
    end
  end

  @doc "Whether a choice waits on the person to map a field its need reads."
  @spec map_pending?(choice()) :: boolean()
  def map_pending?(choice), do: Map.has_key?(choice, :unmapped)

  # The declared need a choice of an entry on `slot` meets and the entry's
  # candidate for it, as the plan answers them; `:no_map` for a lending
  # profile's label, a slot with no entry chosen and the slot of a
  # manifest declaring no needs; `:unknown` when the plan names no such
  # need or candidate.
  defp map_target(plan, slot, %{source: source, id: id} = choice)
       when source in ["own", "instance"] and is_binary(id) do
    case choice_need(plan, slot, choice) do
      nil ->
        :unknown

      need ->
        if declared?(need) do
          case Enum.find(candidates_of(need), &(candidate_id(&1) == {source, id})) do
            nil -> :unknown
            candidate -> {:ok, need, candidate}
          end
        else
          :no_map
        end
    end
  end

  defp map_target(_plan, _slot, _choice), do: :no_map

  # The need a slot's choice meets: the app's need its slot names, or the
  # dependency's, the one the choice names where it declares several.
  defp choice_need(plan, {:need, need, _name}, _choice), do: app_need(plan, need)
  defp choice_need(plan, {:account, {:need, need}, _ref}, _choice), do: app_need(plan, need)
  defp choice_need(plan, {:dep, from, dep}, choice), do: dep_need(plan, from, dep, choice)

  defp choice_need(plan, {:account, {:dep, from, dep}, _ref}, choice),
    do: dep_need(plan, from, dep, choice)

  defp app_need(plan, need),
    do: plan |> field(:needs) |> List.wrap() |> Enum.find(&(field(&1, :need) == need))

  defp dep_need(plan, from, dep, choice) do
    case plan |> dep_row(from, dep) |> row_needs() do
      [one] -> one
      needs -> Enum.find(needs, &(field(&1, :need) == Map.get(choice, :need)))
    end
  end

  defp candidate_id(candidate) do
    case candidate do
      %{entry_id: id} when is_binary(id) -> {"own", id}
      %{instance_entry_id: id} when is_binary(id) -> {"instance", id}
      _other -> nil
    end
  end

  defp need_fields(need), do: need |> field(:fields) |> List.wrap() |> Enum.uniq()

  # A map naming each field the need reads once and only fields the entry
  # holds, as the commit holds a decision's map.
  defp total_map?(fields, need_fields, names) when is_map(fields) do
    Enum.sort(Map.keys(fields)) == Enum.sort(need_fields) and
      Enum.all?(fields, fn {_need_field, entry_field} -> entry_field in names end)
  end

  defp total_map?(_fields, _need_fields, _names), do: false

  # The question's answers to start from: each answer held that the entry
  # still holds; for a need field with no held answer, the entry field of
  # its own name. A held answer the entry no longer holds is asked again,
  # never replaced by a guess.
  defp preselected(held, need_fields, names) do
    held = if is_map(held), do: held, else: %{}

    for need_field <- need_fields,
        answer = Map.get(held, need_field, need_field),
        answer in names,
        into: %{},
        do: {need_field, answer}
  end

  defp held_answers(held, need_fields, names) when is_map(held),
    do:
      Map.filter(held, fn {need_field, entry_field} ->
        need_field in need_fields and entry_field in names
      end)

  defp held_answers(_held, _need_fields, _names), do: %{}

  defp settle(choice, need_fields, fields) do
    case Enum.reject(need_fields, &Map.has_key?(fields, &1)) do
      [] -> choice |> Map.delete(:unmapped) |> Map.put(:fields, fields)
      unmapped -> Map.merge(choice, %{fields: fields, unmapped: unmapped})
    end
  end

  defp unmap(choice), do: Map.drop(choice, [:fields, :unmapped])

  @doc """
  `choices` with the named account `account` placed
  (`%{name, dep, from, need}`, as `PrismWeb.SystemLayer.grant_prompt/4`
  passes it: `dep` nil for the app's own calls, `from` nil for the
  grant's source, `need` nil for the edge's one credential need): as held
  when its edge already holds an account of that name, compared by
  Unicode's full lowercase mapping; otherwise a new row of that fixed
  name, no entry pressed and standing pressed, beside the edge's default
  as the grant otherwise opens it, a default a profile lends first
  switched to the entry it lends. `{:error, sentence}` when the plan has
  no edge or need for it, or the lent default cannot be switched.
  """
  @spec open_account(map(), %{slot() => choice()}, map()) ::
          {:ok, %{slot() => choice()}} | {:error, String.t()}
  def open_account(plan, choices, %{name: name} = account) when is_binary(name) do
    with {:ok, edge, need} <- account_edge(plan, account),
         {:ok, choices, _default_need} <- account_default(plan, choices, edge) do
      if Enum.any?(
           accounts_on(choices, edge),
           &Prima.Authority.Blob.same_account_name?(elem(&1, 1).name, name)
         ),
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
  # entry that profile lends, under the field map that profile binds it
  # with, since an account sits beside an entry chosen here. Answers the
  # choices and the default's need.
  def account_default(_plan, choices, {:need, _need}), do: {:ok, choices, nil}

  def account_default(plan, choices, {:dep, from, dep}) do
    slot = {:dep, from, dep}

    case Map.get(choices, slot) do
      %{source: "label", id: label} = default ->
        with {:ok, source, id, need, fields} <-
               switch_lent(dep_row(plan, from, dep), dep, label) do
          switched =
            %{default | source: source, id: id, need: need, renew: false}
            |> Map.put(:lent_by, label)
            |> put_fields(fields)

          {:ok, Map.put(choices, slot, switched), need}
        end

      %{need: need} ->
        {:ok, choices, need}

      nil ->
        {:ok, choices, nil}
    end
  end

  # The entry the `label` profile lends, as the plan's lender candidate
  # names it, the field map it lends it under, and the dependency's need
  # it fills: none to name where the dependency declares one need, else
  # the one need whose candidates hold it.
  defp switch_lent(row, dep, label) do
    lender =
      row |> field(:candidates) |> List.wrap() |> Enum.find(&(field(&1, :label) == label))

    with %{} <- lender,
         id when is_binary(id) <- field(lender, :entry_id),
         source when source in ["own", "instance"] <- field(lender, :source) do
      fields = field(lender, :fields)

      case {row_needs(row), Enum.filter(row_needs(row), &holds?(&1, id))} do
        {[_one], _holding} ->
          {:ok, source, id, nil, fields}

        {_several, [need]} ->
          {:ok, source, id, field(need, :need), fields}

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

  # The lifetime a choice sends, computed now: standing and once as they
  # are; five minutes and an hour from now; this session, the earlier of
  # the session's end and 24 hours from now, offered only while there is
  # a session end ahead.
  def lifetime_of(choice, _session_end, _now) when choice in ["standing", "once"],
    do: {:ok, %{"kind" => choice}}

  def lifetime_of(choice, _session_end, now) when is_map_key(@spans, choice),
    do: {:ok, until(DateTime.add(now, Map.fetch!(@spans, choice), :second))}

  def lifetime_of("session", session_end, now) do
    case session_until(session_end, now) do
      %DateTime{} = at -> {:ok, until(at)}
      nil -> :error
    end
  end

  def lifetime_of(_choice, _session_end, _now), do: :error

  defp until(%DateTime{} = at),
    do: %{"kind" => "until", "until" => at |> DateTime.truncate(:second) |> DateTime.to_iso8601()}

  def session_until(%DateTime{} = session_end, %DateTime{} = now) do
    if DateTime.compare(session_end, now) == :gt do
      horizon = DateTime.add(now, @horizon_s, :second)
      if DateTime.compare(session_end, horizon) == :lt, do: session_end, else: horizon
    end
  end

  def session_until(_none, _now), do: nil

  # The limits the person lowered, each at most its ask; a field left at
  # its ask, or blank, is not sent.
  # The node's limits as they stand (`current`, the narrowing the walk
  # holds, a re-grant's head narrowing among it) changed only by what the
  # form sent: a field lowered below the ask is narrowed to it, one sent at
  # the ask is the ask again, and one left empty or not on the form keeps
  # what it held. A narrowing the form cannot show, such as a rate's
  # window longer than the ask's, is never dropped by lowering another.
  def lowered(limits, asked, current) do
    limits
    |> Enum.sort()
    |> Enum.reduce_while({:ok, current}, fn {field, raw}, {:ok, acc} ->
      case lower(field, String.trim(to_string(raw)), asked, acc) do
        :unchanged -> {:cont, {:ok, acc}}
        {:ask, key} -> {:cont, {:ok, Map.delete(acc, key)}}
        {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _sentence} = error -> {:halt, error}
      end
    end)
  end

  defp lower(_field, "", _asked, _current), do: :unchanged

  defp lower(field, raw, asked, _current) when field in @integer_limits do
    with {value, ""} <- Integer.parse(raw),
         ask when is_integer(ask) <- asked[field] do
      cond do
        value == ask -> {:ask, field}
        value > ask or value < 0 -> {:error, "#{limit_label(field)} can be at most #{ask}."}
        true -> {:ok, {field, value}}
      end
    else
      _ -> {:error, "#{limit_label(field)} must be a whole number."}
    end
  end

  defp lower(field, raw, asked, _current) when field in @duration_limits do
    with {:ok, ms} <- Prima.Limits.parse_duration(raw),
         ask when is_binary(ask) <- asked[field],
         {:ok, ask_ms} <- Prima.Limits.parse_duration(ask) do
      cond do
        ms == ask_ms -> {:ask, field}
        ms > ask_ms -> {:error, "#{limit_label(field)} can be at most #{ask}."}
        true -> {:ok, {field, raw}}
      end
    else
      _ -> {:error, "#{limit_label(field)} must be a duration, like 30s or 5m."}
    end
  end

  # The count the form shows is lowered in the window the node holds now:
  # the ask's, or a longer one a re-grant's head narrowing kept (the
  # overlap of the head's rate and the ask's). The rate is the ask again
  # only when both its count and its window are the ask's.
  defp lower("rate_requests", raw, %{"rate_limit" => %{"requests" => ask} = asked}, current) do
    ask_window = asked["window"]
    window = get_in(current, ["rate_limit", "window"]) || ask_window

    case Integer.parse(raw) do
      {^ask, ""} when window == ask_window ->
        {:ask, "rate_limit"}

      {value, ""} when value >= 0 and value <= ask ->
        {:ok, {"rate_limit", %{"requests" => value, "window" => window}}}

      {_value, ""} ->
        {:error, "The rate can be at most #{ask} requests."}

      _ ->
        {:error, "The rate must be a whole number of requests."}
    end
  end

  defp lower(_field, _raw, _asked, _current), do: :unchanged

  # A plan answered through `PrismWeb.Ops` is atom-keyed (`Sanctum.Consent.Plan`),
  # and so is every map in it a field is read from here.
  def field(nil, _key), do: nil
  def field(map, key) when is_map(map), do: Map.get(map, key)

  def declared?(need), do: field(need, :kind) in @credential_kinds

  def suggested(need) do
    case field(need, :suggested) do
      %{entry_id: id} = suggested when is_binary(id) -> suggested
      %{instance_entry_id: id} = suggested when is_binary(id) -> suggested
      _none -> nil
    end
  end

  def row_needs(row), do: List.wrap(field(row, :needs))

  def provided_edge?(row), do: Enum.any?(row_needs(row), &(field(&1, :source) == "provided"))

  def dep_row(plan, from, dep) do
    plan
    |> field(:dependency_needs)
    |> List.wrap()
    |> Enum.find(&(field(&1, :from) == from and field(&1, :dep) == dep))
  end

  def candidates_of(need), do: List.wrap(field(need, :candidates))

  @doc """
  The flows a node's exits ask, as the plan's typed rows name them: one
  `%{"from" => class, "to" => exit}` per class an exits row of the node
  lets reach its exit, in the rows' order.
  """
  @spec asked_flows([map()], String.t()) :: [%{String.t() => String.t()}]
  def asked_flows(rows, node) when is_list(rows) do
    for %{"kind" => "exits", "node" => ^node, "values" => %{"exit" => exit, "flows" => classes}} <-
          rows,
        class <- List.wrap(classes),
        do: %{"from" => class, "to" => exit}
  end

  @doc """
  The narrowing `subset` with one asked flow of `node` toggled: a flow
  the grant keeps is removed, and one it dropped is kept again. A person
  only removes flows, so a flow `asked` does not name changes nothing.
  The flows kept are the node's `exits` narrowing, which names nothing
  while it keeps every flow asked, and an empty list once it keeps none.
  """
  @spec toggle_flow(map(), String.t(), [map()], map()) :: map()
  def toggle_flow(subset, node, asked, %{"from" => _, "to" => _} = flow)
      when is_map(subset) and is_list(asked) do
    if flow in asked do
      granted = get_in(subset, [node, "exits"]) || asked

      chosen =
        if flow in granted,
          do: List.delete(granted, flow),
          else: Enum.filter(asked, &(&1 in [flow | granted]))

      record = Map.get(subset, node, %{})

      record =
        if Enum.sort(chosen) == Enum.sort(asked),
          do: Map.delete(record, "exits"),
          else: Map.put(record, "exits", chosen)

      if record == %{}, do: Map.delete(subset, node), else: Map.put(subset, node, record)
    else
      subset
    end
  end

  @doc "The limits of a limits row the person can lower, the rate's count among them."
  @spec lowerable(map()) :: [String.t()]
  def lowerable(%{"values" => values}) do
    fields =
      for field <- @duration_limits ++ @integer_limits,
          values[field] != nil,
          do: field

    if is_map(values["rate_limit"]), do: fields ++ ["rate_requests"], else: fields
  end

  def limit_label("timeout"), do: "Timeout"
  def limit_label("batch_timeout"), do: "Batch timeout"
  def limit_label("max_memory_bytes"), do: "Memory (bytes)"
  def limit_label("max_request_size"), do: "Request size (bytes)"
  def limit_label("max_response_size"), do: "Response size (bytes)"
  def limit_label("max_concurrent_tasks"), do: "Concurrent tasks"
  def limit_label("rate_limit"), do: "Rate"
  def limit_label("rate_requests"), do: "Requests per window"
  def limit_label(field), do: field
end
