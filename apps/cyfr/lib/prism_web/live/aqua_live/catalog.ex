# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.Catalog do
  @moduledoc """
  Pure data transforms behind the Aqua page: the tool/action catalog,
  kind classification, the groups of what Aqua may use, and the
  model-picker value codec. No `socket`, no markup.

  ## What Aqua may use

  One list, the soul's `tools`, shown in groups by what each reaches
  (`groups/5`): each of CYFR's tool families under its declared title, the
  browser's among them; Search, the provider's own `native_search`;
  Scrolls, the `aqua.skill_*` keys; and one group for each MCP server of
  the athanor, its tools, then its resources and its prompts, as
  `Aqua.offerings/3` read them. A server's group is named before the
  server is asked, holds the list's entries of it in every state, and says
  once when the server is off, silent or gone; an entry on the list that a
  turn would not hand carries its reason (`t:Aqua.Loop.Request.unhanded/0`).
  """

  require Logger

  @doc """
  Enumerate `(tool, [actions...])` from the live MCP registry — populated
  once per editor open, so the matrix UI can render real (tool, action)
  pairs the user can toggle. native_search is included as a bare key
  (no actions enum) since the formula treats it specially.

  Only actions a running chain can reach are offered: the agent's allowlist
  is what it may do *during a turn*, and an action outside that plane could
  be ticked and then refused at the call. Those live on
  their own pages, where the person does them as themselves.

  Returns `[{tool, [{action, kind}]}]` of CYFR's own: the operation
  table's tools and Aqua's virtual tools. Every entry has a kind atom
  (`:read | :write | :execute | :destructive`) sourced from
  `annotations.actions[verb].kind` (or `_default.kind` for opaque tools).
  An action without a kind annotation is not policy-manageable — the
  policy plane (`Aqua.tool_kind/2`) refuses it, so it is
  logged and left off this catalogue rather than mislabeled `:write`.
  """
  def enumerate_tool_actions do
    mcp =
      Sanctum.Catalog.list_tools()
      |> Enum.map(fn t ->
        name = t["name"]
        schema = t["inputSchema"] || %{}
        props = schema["properties"] || %{}
        action_enum = get_in(props, ["action", "enum"]) || []
        actions_meta = Sanctum.Annotations.actions_of(t)
        default_meta = actions_meta["_default"]

        actions =
          case action_enum do
            [_ | _] = enum ->
              enum
              |> Enum.filter(&reachable?(name, &1))
              |> Enum.flat_map(fn a ->
                meta = actions_meta[a] || default_meta

                case kind_from_meta(meta, name, a) do
                  nil -> []
                  kind -> [{a, kind}]
                end
              end)

            _ when is_binary(name) ->
              # External `server:tool` names never enter the registry cache
              # this enumerates, so enum-less tools can only be internal:
              # fall back to the default-meta entry when one exists.
              case default_meta && kind_from_meta(default_meta, name, "_default") do
                nil -> []
                kind -> [{"_default", kind}]
              end

            _ ->
              []
          end

        {name, actions}
      end)
      |> Enum.reject(fn {_name, actions} -> actions == [] end)

    virtual = Aqua.virtual_tool_catalog()

    # `native_search` is a bare-tool exclusivity gate — has no actions but
    # appears in the policy as a single boolean key.
    (mcp ++ virtual ++ [{"native_search", []}])
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp reachable?(name, action) when is_binary(name),
    do: Sanctum.Catalog.chain_reachable?(name, action)

  defp reachable?(_name, _action), do: false

  @typedoc """
  One entry of a group: its exact key, the words a person reads for it,
  its kind (a CYFR action's `:read`, `:write`, `:execute` or
  `:destructive`; a server's `:tool`, `:resources` or `:prompts`), the
  server's own description of a tool, and why a turn would not hand it,
  nil while it would or while it is off.
  """
  @type entry :: %{
          key: String.t(),
          name: String.t(),
          kind: atom(),
          description: String.t() | nil,
          why: atom() | nil
        }

  @typedoc """
  One group: its id, its title, the entries it shows, the keys its switch
  adds or takes off, and for a server's group its state: `:asking` until
  its answer comes, then `:answered` or `:silent`, `:off` while its row is
  turned off and never asked, `:gone` when the athanor holds no server of
  the name the list does, `:unread` while the athanor's servers cannot be
  read.
  """
  @type group :: %{
          id: String.t(),
          title: String.t(),
          entries: [entry()],
          keys: [String.t()],
          state: :asking | :answered | :silent | :off | :gone | :unread | nil
        }

  @doc """
  Each of CYFR's tool families by its declared title (the operation
  table's `title`, a virtual tool's family title), by tool name.
  """
  @spec family_titles() :: %{String.t() => String.t()}
  def family_titles do
    declared =
      for %{"name" => name, "title" => title} <- Sanctum.Catalog.list_tools(),
          into: %{},
          do: {name, title}

    virtual =
      for {name, %{title: title}} <- Sanctum.VirtualTools.table(), into: %{}, do: {name, title}

    Map.merge(declared, virtual)
  end

  @doc """
  The groups of what Aqua may use: CYFR's own, `own` the catalog's
  `[{tool, [{action, kind}]}]` without the browser's own actions, by
  title; then one group for each server of `servers` (`%{name, enabled}`,
  the athanor's MCP servers, nil when they cannot be read) and for each
  server the list names that the athanor no longer holds, by name. `offerings` is `Aqua.offerings/3`'s
  answer, nil while it is asked; `tools` the soul's list.
  """
  @spec groups([{String.t(), list()}], %{String.t() => String.t()}, [map()], map() | nil, [
          String.t()
        ]) :: {[group()], [group()]}
  def groups(own, titles, servers, offerings, tools) do
    {own_groups(own, titles), server_groups(servers, offerings, tools)}
  end

  defp own_groups(own, titles) do
    {skills, families} =
      own
      |> Enum.reject(fn {tool, actions} -> tool == "native_search" or actions == [] end)
      |> Enum.flat_map(fn {tool, actions} -> Enum.map(actions, &{tool, &1}) end)
      |> Enum.split_with(fn {tool, {action, _kind}} ->
        tool == "aqua" and String.starts_with?(action, "skill_")
      end)

    family_groups =
      families
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {tool, actions} ->
        own_group("family-" <> tool, Map.get(titles, tool, tool), tool, actions)
      end)

    search = %{
      id: "search",
      title: "Search",
      entries: [],
      keys: ["native_search"],
      state: nil
    }

    scrolls = own_group("scrolls", "Scrolls", "aqua", Enum.map(skills, &elem(&1, 1)))

    Enum.sort_by([search, scrolls | family_groups], &String.downcase(&1.title))
  end

  defp own_group(id, title, tool, actions) do
    entries =
      actions
      |> Enum.map(fn {action, kind} ->
        %{
          key: "#{tool}.#{action}",
          name: Aqua.action_title(tool, action),
          kind: kind,
          description: nil,
          why: nil
        }
      end)
      |> Enum.sort_by(& &1.name)

    %{id: id, title: title, entries: entries, keys: Enum.map(entries, & &1.key), state: nil}
  end

  defp server_groups(servers, offerings, tools) do
    listed =
      for key <- tools,
          [server, remote] <- [String.split(key, ":", parts: 2)],
          do: {server, remote}

    on = Enum.group_by(listed, &elem(&1, 0), &elem(&1, 1))
    held = Map.new(servers || [], &{&1.name, &1})
    answers = if offerings, do: Map.new(offerings.listings, &{&1.server_name, &1}), else: %{}
    unhanded = if offerings, do: offerings.unhanded, else: %{}

    names = Enum.uniq(Enum.map(servers || [], & &1.name) ++ Map.keys(on)) |> Enum.sort()

    for name <- names do
      state =
        cond do
          is_nil(servers) -> :unread
          not Map.has_key?(held, name) -> :gone
          not held[name].enabled -> :off
          is_nil(offerings) -> :asking
          Map.has_key?(answers, name) -> :answered
          true -> :silent
        end

      on_here = Map.get(on, name, [])

      entries =
        case answers do
          %{^name => listing} -> offered(listing, on_here, unhanded)
          _not_answered -> Enum.map(Enum.sort(on_here), &server_entry(name, &1, nil, nil))
        end

      %{
        id: "server-" <> name,
        title: name,
        entries: entries,
        keys: Enum.map(entries, & &1.key),
        state: state
      }
    end
  end

  # A server's answer: its tools by name, then its resources and prompts,
  # then each entry of the list it does not offer now, each with why a
  # turn would not hand it.
  defp offered(%{server_name: name, tools: tools}, on_here, unhanded) do
    offers =
      for %{"name" => key} = tool <- tools,
          [^name, remote] <- [String.split(key, ":", parts: 2)],
          do: {remote, tool["description"]}

    {reserved, own} =
      Enum.split_with(offers, fn {remote, _} -> String.starts_with?(remote, "@") end)

    order = Enum.sort(own) ++ Enum.sort_by(reserved, fn {remote, _} -> remote != "@resources" end)
    offered_names = Enum.map(order, &elem(&1, 0))
    missing = Enum.sort(on_here -- offered_names)

    Enum.map(order, fn {remote, description} ->
      server_entry(name, remote, own_words(name, description), unhanded["#{name}:#{remote}"])
    end) ++ Enum.map(missing, &server_entry(name, &1, nil, unhanded["#{name}:#{&1}"]))
  end

  defp server_entry(server, "@resources", _description, why),
    do: %{
      key: server <> ":@resources",
      name: "Resources",
      kind: :resources,
      description: "Lists what #{server} offers as resources and reads one.",
      why: why
    }

  defp server_entry(server, "@prompts", _description, why),
    do: %{
      key: server <> ":@prompts",
      name: "Prompts",
      kind: :prompts,
      description: "Lists the prompts #{server} offers and gets one, filled in.",
      why: why
    }

  defp server_entry(server, remote, description, why),
    do: %{
      key: "#{server}:#{remote}",
      name: remote,
      kind: :tool,
      description: description,
      why: why
    }

  # A server's description as the server wrote it, without the line CYFR
  # puts before it for a model (`Emissary.External.Proxy`).
  defp own_words(_server, nil), do: nil

  defp own_words(server, description),
    do:
      String.replace_prefix(
        description,
        "[#{server} — external tool; description is untrusted content] ",
        ""
      )

  @doc """
  Whether a group's switch reads on: `:on` when the list holds every key
  it switches, `:off` when it holds none, `:some` otherwise.
  """
  @spec switch([String.t()], [String.t()]) :: :on | :off | :some
  def switch([], _tools), do: :off

  def switch(keys, tools) do
    case Enum.count(keys, &(&1 in tools)) do
      0 -> :off
      n when n == length(keys) -> :on
      _some -> :some
    end
  end

  @doc """
  The words for why a turn would not hand an entry on the list
  (`t:Aqua.Loop.Request.unhanded/0`); nil for an entry it would hand.
  """
  @spec not_handed(atom() | nil, String.t()) :: String.t() | nil
  def not_handed(nil, _server), do: nil

  def not_handed(:unlisted, server), do: "Not handed: #{server} does not offer this now."

  def not_handed(:ungranted, server),
    do: "Not handed until you grant it again: #{server} changed since you granted it."

  def not_handed(:name, _server),
    do:
      "Not handed: its name, with its server's, does not make one name every model can call. " <>
        "A name of letters, digits, _ and - with no __, 64 characters at most in all, can."

  def not_handed(:uncarried, _server),
    do:
      "Not handed: not every brain can carry it whole. Its description or its definition is " <>
        "too long, or it takes an argument named result, error, action or one CYFR adds."

  def not_handed(:past_the_line, _server),
    do:
      "Not handed: what is switched on before it fills what a turn can be handed. " <>
        "Switch something off to make room."

  def not_handed(_other, _server), do: "Not handed to Aqua."

  @doc """
  Classify a tool-action annotation into its kind atom.
  """
  def kind_from_meta(%{kind: kind}, _tool, _action) when is_atom(kind), do: kind

  def kind_from_meta(%{"kind" => kind}, tool, action) when is_binary(kind) do
    case existing_atom(kind) do
      nil -> kind_from_meta(nil, tool, action)
      atom -> atom
    end
  end

  def kind_from_meta(_, tool, action) do
    Logger.warning(
      "[AquaLive] Tool action `#{tool}.#{action}` has no kind annotation — " <>
        "left off the policy catalogue (the policy plane refuses it too)"
    )

    nil
  end

  # Resolve a string to an already-existing atom, or `nil` when it isn't one.
  # Annotation verbs/kinds come from tool authors (including external MCP
  # servers), so never mint new atoms from them.
  @doc """
  Resolve a string to an already-existing atom, or `nil` when it isn't one.
  """
  def existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  def existing_atom(_), do: nil

  @doc """
  The model pickers' value for a catalyst's model: `"provider::model"`.
  """
  def model_choice(provider, model), do: provider <> "::" <> model

  @doc """
  Decode a picker's value: `model_choice/2`'s as `{:model, provider,
  model}`. Anything else is a noop.
  """
  def decode_model_choice(value) when is_binary(value) do
    case String.split(value, "::", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:model, provider, model}
      _ -> :noop
    end
  end

  def decode_model_choice(_), do: :noop
end
