# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Policy do
  @moduledoc """
  What a resolved call may do under the agent's effective policy: run at
  once, ask the person first, or be refused — and whether it may run
  beside others.

  The policy is `Aqua.ToolGrants.resolve/2`'s guest spelling
  (`"tool.action" => "auto" | "ask" | "deny"`, `"role.*" => "auto"`),
  already under the kind ceiling: a destructive or external action, or
  one declared to take no standing allow, is never `auto`, and the others
  only by the author's `auto` or a standing grant. A hand or catalog call
  reads its own key; a clone reads its role's glob; the `ui` event runs
  at once; an external server's tool always asks; a launch asks, whatever
  the agent's own policy or a standing answer says, since `Aqua.Launch` runs
  only a launch a person approved on its card: it is refused when its
  reference is no component, and denied when the agent's policy denies
  `execution.run` or names it not at all. Reads run beside each other;
  everything else runs alone.

  A launch naming an account (`connection`) has it resolved before it
  asks (`launch_account/2`), as account names compare: the entry the
  launched app's own profile binds under that name, and the name as the
  binding stores it, which the card shows and its approval binds. A name
  the profile does not bind ends the call as setup required, before any
  approval is read.

  A key that asks runs at once only when a standing allow covers this
  very call (`Sanctum.ToolGrants.admits?/2`): its lifecycle is the call's
  own execution, turn or schedule and still live, its deadline has not
  passed, the call's resource lies inside its constraint, and every
  outside source the turn has read is one the allow names, read from the
  rows and the turn's sources as they stand when the call is decided and
  again when it dispatches, never from the turn's start.

  `sources_of/3` names the sources a call's result carries into its
  turn: a catalog action's as its operation declares them
  (`Prima.Operation.result_sources/3`, an undeclared one outside),
  `files_by_grant` for a files or storage read, and an outside source
  named by its origin for an external server's tool, the HTTP hand and
  a launched component whose grant reaches the network; and a hand's
  child its own ledger, as its completion result carries it
  (`child_ledger/1`).

  A launch's card binds what the launch will carry (`launch_flow/3`): the
  turn's sources it seeds the launched root with, the consent revision
  of the grant the app roots at, and the classes of those sources that
  some exit of that grant's tree declares no flow for (`lets_flow/2`),
  which the person's approval lets flow to every exit of the tree. They
  are part of the proposal its digest hashes, so a source the turn reads
  after the card, or another grant, is not what was approved.

  `touched_refs/1` names the components a turn's closed write,
  destructive and execute calls reached, from their durable rows.
  """

  alias Aqua.Loop.Binding.Call
  alias Prima.Authority.{Blob, RootSelect}
  alias Prima.Authority.Blob.Edge

  @typedoc """
  A launch's account as its card binds it: the entry the name resolved to
  and the name as its binding stores it (`launch_account/2`).
  """
  @type account :: %{vault_entry: String.t(), name: String.t()}

  @typedoc """
  What a call does: run at once; ask, for a launch naming an account with
  the entry it resolved to; be denied or refused with a sentence; or, for
  a launch naming an account its app's profile does not bind, end the
  turn as setup required, naming the app, its credential need (nil: the
  one need, or one no binding tells) and the account.
  """
  @type decision ::
          :auto
          | :ask
          | {:ask, account()}
          | {:deny, String.t()}
          | {:refuse, String.t()}
          | {:setup_required, String.t(), {String.t() | nil, String.t()}}

  @doc """
  The decision for `call` under `policy`. `opts`: `:restricted?` (the
  turn holds a call whose outcome is unknown: only a replay-safe read
  runs, whatever the policy says), and where the call is made, which a
  standing allow is judged against and a launch's account is resolved
  under: `:ctx` (the member's context its rows are read under), `:agent`
  (the agent's name), `:thread_id`, `:turn_id` and `:execution_id` (the
  turn's root); the turn's sources are read from its row as the call is
  decided, unless `:sources` names them. Without them a key that asks,
  asks, and a launch naming an account is refused.
  """
  @spec decide(Call.t(), map(), keyword()) :: decision()
  def decide(%Call{} = call, policy, opts) do
    if Keyword.get(opts, :restricted?, false) and not replay_safe?(call),
      do:
        {:deny,
         "#{key(call)} may not run: an earlier call's outcome is unknown, and until a new turn " <>
           "starts only replay-safe reads run"},
      else: decide_open(call, policy, opts)
  end

  @doc """
  Whether `call` is reviewed as safe to run again after an uncertain
  outcome (`recovery: :replay_safe` on its action): a hand's read or a
  catalog read so declared; nothing else.
  """
  @spec replay_safe?(Call.t()) :: boolean()
  def replay_safe?(%Call{kind: :hand, tool: tool, action: action}),
    do: Sanctum.VirtualTools.recovery(tool, action) == :replay_safe

  def replay_safe?(%Call{kind: :catalog, tool: tool, action: action}),
    do: Aqua.Ops.replay_safe?(tool, action)

  def replay_safe?(%Call{}), do: false

  defp decide_open(%Call{kind: :ui}, _policy, _opts), do: :auto

  defp decide_open(%Call{kind: :clone, target: role}, policy, _opts) do
    if Map.get(policy, "#{role}.*") == "auto",
      do: :auto,
      else: {:deny, "the soul may not clone into #{role}: its policy does not allow it"}
  end

  defp decide_open(%Call{kind: :external}, _policy, _opts), do: :ask

  # A launch runs only from an approved card, so it asks whatever an
  # authored or standing allow says: an `auto` would reach a dispatch that
  # refuses it for want of an approval. A policy that denies
  # `execution.run`, or names it not at all, denies the launch.
  defp decide_open(%Call{kind: :launch, target: reference} = call, policy, opts) do
    cond do
      not component_ref?(reference) ->
        {:refuse, "#{inspect(reference)} is not a component reference"}

      Map.get(policy, key(call)) in ["auto", "ask"] ->
        ask_launch(call, Keyword.get(opts, :ctx))

      true ->
        deny(call)
    end
  end

  defp decide_open(%Call{} = call, policy, opts), do: by_key(call, policy, opts)

  @doc """
  Whether `policy` still grants `call` without asking.

  The narrow re-check a call makes against the member's live grants as it
  dispatches. It can only withdraw an `auto`, never widen one: a
  restricted turn has already had its say by the time a step runs, and a
  launch is never `auto`. `opts` are `decide/3`'s place of
  the call, so a call a bounded allow let run is asked again whether the
  allow still covers it (`Sanctum.ToolGrants.admits?/2`), from the rows
  as they stand now.
  """
  @spec auto?(Call.t(), map(), keyword()) :: boolean()
  def auto?(%Call{kind: :ui}, _policy, _opts), do: true
  def auto?(%Call{kind: :launch}, _policy, _opts), do: false

  def auto?(%Call{kind: :clone, target: role}, policy, _opts),
    do: Map.get(policy, "#{role}.*") == "auto"

  def auto?(%Call{} = call, policy, opts) do
    case Map.get(policy, key(call)) do
      "auto" -> true
      "ask" -> admitted?(call, opts)
      _ -> false
    end
  end

  defp by_key(call, policy, opts) do
    case Map.get(policy, key(call)) do
      "auto" -> :auto
      "ask" -> if admitted?(call, opts), do: :auto, else: :ask
      _ -> deny(call)
    end
  end

  # Whether a standing allow covers this very call, read fresh. Only a
  # hand or a catalog call runs under a standing answer; a call made
  # nowhere the rows can be read for asks, and so does one whose turn's
  # sources are not known.
  defp admitted?(%Call{kind: kind, tool: tool, action: action, args: args}, opts)
       when kind in [:hand, :catalog] and is_binary(action) do
    with %Sanctum.Context{} = ctx <- Keyword.get(opts, :ctx),
         agent when is_binary(agent) <- Keyword.get(opts, :agent),
         thread_id when is_binary(thread_id) <- Keyword.get(opts, :thread_id) do
      Sanctum.ToolGrants.admits?(ctx, %{
        agent_name: agent,
        thread_id: thread_id,
        tool: tool,
        action: action,
        args: args,
        execution_id: Keyword.get(opts, :execution_id),
        turn_id: Keyword.get(opts, :turn_id),
        sources: turn_sources(ctx, opts)
      })
    else
      _ -> false
    end
  end

  defp admitted?(_call, _opts), do: false

  # The turn's sources: those the place names, else the turn's row read
  # now, so a source a concurrent call joined counts. A turn whose row
  # cannot be read has unknown sources, which no allow covers.
  defp turn_sources(ctx, opts) do
    case Keyword.fetch(opts, :sources) do
      {:ok, sources} ->
        sources

      :error ->
        with turn_id when is_binary(turn_id) <- Keyword.get(opts, :turn_id),
             {:ok, %{sources: sources}} <- Aqua.Tape.turn(ctx, turn_id) do
          Prima.Source.decode(sources)
        else
          _unknown -> nil
        end
    end
  end

  defp deny(call), do: {:deny, "#{key(call)} is not in the agent's policy"}

  defp key(%Call{tool: tool, action: action}), do: "#{tool}.#{action}"

  @doc """
  Whether `call` may run beside other calls of the same batch: only a
  read does; a write, an execute, a destructive act and a clone run
  alone.
  """
  @spec overlap(Call.t()) :: :concurrent | :exclusive
  def overlap(%Call{kind: kind, tool: tool, action: action}) when kind in [:hand, :catalog] do
    if Aqua.Kinds.kind_for(tool, action) == :read, do: :concurrent, else: :exclusive
  end

  def overlap(%Call{}), do: :exclusive

  defp component_ref?(reference), do: match?({:ok, _}, Prima.ComponentRef.parse(reference))

  # A launch asks, with the entry its named account resolves to; an
  # account the app's profile does not bind is setup required, and an
  # account that cannot be read refuses the call, never a setup.
  defp ask_launch(%Call{} = call, ctx) do
    case launch_account(call, ctx) do
      {:ok, nil} ->
        :ask

      {:ok, %{entry_id: entry_id, name: stored}} ->
        {:ask, %{vault_entry: entry_id, name: stored}}

      {:error, :connection_not_granted} ->
        {:setup_required, call.target, {nil, call.args["connection"]}}

      {:error, reason} ->
        {:refuse,
         "the account #{inspect(call.args["connection"])} of #{call.target} could not be read: " <>
           Aqua.Ops.render_refusal(reason)}
    end
  end

  @doc """
  The entry a launch's named account resolves to, read under `ctx`, with
  the account's name as its binding stores it: the `connection` an
  `execution.run` names, resolved on the ingress of the profile the
  launch roots at (its `profile` argument, else the default owner
  profile) from that profile's stored head, as account names compare
  (`Sanctum.Consent.Accounts.resolve/4`). `{:ok, nil}` for a call that is
  no `execution.run` launch or names no account. A name the profile does
  not bind is `{:error, :connection_not_granted}`; a store that cannot
  answer is its own refusal; a launch naming an account with no context
  to read it under is `{:error, :no_context}`.

  The account an `execution.run_stream` names is never resolved: the
  action declares no `connection`, and the gate refuses it as an unknown
  argument.
  """
  @spec launch_account(Call.t(), Sanctum.Context.t() | nil) ::
          {:ok, %{entry_id: String.t(), name: String.t()} | nil} | {:error, term()}
  def launch_account(
        %Call{kind: :launch, action: "run", target: reference, args: %{"connection" => name}} =
          call,
        ctx
      )
      when is_binary(name) do
    case ctx do
      %Sanctum.Context{} ->
        Sanctum.Consent.Accounts.resolve(
          ctx,
          RootSelect.decode(call.args["profile"]),
          reference,
          name
        )

      _none ->
        {:error, :no_context}
    end
  end

  def launch_account(%Call{}, _ctx), do: {:ok, nil}

  @doc """
  The component references a turn's closed write, destructive and
  execute calls reached, from their `tool_call` payloads: an argument
  named `reference` or `ref`, and a `path` at or below a component version
  directory as the component path grammar reads one
  (`Compendium.parse_component_path/1`). Name level,
  so any version of a touched component counts.
  """
  @spec touched_refs([map()]) :: MapSet.t()
  def touched_refs(calls) when is_list(calls) do
    calls
    |> Enum.filter(fn call ->
      Aqua.Kinds.kind_for(call["tool"] || "", call["action"] || "") in [
        :write,
        :destructive,
        :execute
      ]
    end)
    |> Enum.flat_map(fn call ->
      args = call["arguments"] || %{}

      refs =
        [args["reference"], args["ref"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&name_level/1)

      refs ++ path_refs(args["path"])
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc """
  The card a call that asks becomes: today's intent shape, which the
  console card and the wire read — the proposal canonical, the kind and
  the standing from the catalog, never from the model. A launch's card
  takes no standing answer, and its proposal carries the account its
  call named as the binding stores it and the entry it resolved to
  (`opts[:account]`, `proposal/3`), so the approval binds the account the
  card showed. The card names the sources the turn has read
  (`opts[:sources]`, canonical JSON): a standing answer may follow only
  the outside ones it names. A launch's proposal also binds those
  sources, and what `opts[:launch]` (`launch_flow/3`) read of the
  launched grant: its consent revision and the classes the approval
  lets flow.
  """
  @spec card(Call.t(), keyword()) :: map()
  def card(%Call{} = call, opts \\ []) do
    sources = Keyword.get(opts, :sources, [])

    launch =
      case Keyword.get(opts, :launch) do
        %{consent_id: consent_id, classes: classes} ->
          %{sources: sources, consent_id: consent_id, classes: classes}

        nil ->
          %{sources: sources, consent_id: nil, classes: []}
      end

    proposal = proposal(call, Keyword.get(opts, :account), launch)

    %{
      "kind" => "request_approval",
      "id" => Keyword.get(opts, :id) || Prima.UUID7.generate_id("apr"),
      "title" => Keyword.get(opts, :title) || "#{call.tool}.#{call.action}",
      "summary" => Keyword.get(opts, :summary) || "",
      "action_kind" =>
        Atom.to_string(Aqua.Kinds.kind_for(call.tool, call.action || "") || :external),
      "standing" => standing(call),
      "proposal" => proposal,
      "sources" => Prima.Source.to_json_list(sources)
    }
  end

  @doc """
  What a launch of `call` binds of the grant its app roots at, read under
  `ctx` without running anything (`Aqua.Launch.authority/4`, the selector
  and account the call names): the grant's consent revision and the
  classes of `sources` its tree lets no exit take (`lets_flow/2`). A
  grant that cannot be loaded binds no revision and lets nothing flow.
  """
  @spec launch_flow(Call.t(), Sanctum.Context.t() | nil, [Prima.Source.t()]) ::
          %{consent_id: String.t() | nil, classes: [Prima.Source.class()]}
  def launch_flow(%Call{kind: :launch} = call, %Sanctum.Context{} = ctx, sources)
      when is_list(sources) do
    case Aqua.Launch.authority(ctx, call.target, call.action, call.args) do
      {:ok, %Prima.Authority{consent_id: consent_id, policy: policy}} ->
        %{consent_id: consent_id, classes: lets_flow(policy, sources)}

      {:error, _not_loaded} ->
        %{consent_id: nil, classes: []}
    end
  end

  def launch_flow(%Call{}, _ctx, _sources), do: %{consent_id: nil, classes: []}

  @doc """
  The classes of `sources` that some exit of the grant `policy` grants
  no flow for: an egress domain an edge allows, or a tool server it
  binds, that the edge's own flows (`Prima.Authority.Blob.Edge.flows/1`)
  leave a source uncovered at (`Prima.Flow.uncovered/3`, the one send
  decision). A launch's approval lets these flow to every exit of the
  tree, so an approval that names none widens nothing.
  """
  @spec lets_flow(Blob.t() | :none, [Prima.Source.t()]) :: [Prima.Source.class()]
  def lets_flow(%Blob{nodes: nodes}, sources) when is_list(sources) do
    uncovered =
      for {_ref, %Blob.Node{edges: edges}} <- nodes,
          {_key, %Edge{} = edge} <- edges,
          exit <- exits(edge),
          source <- Prima.Flow.uncovered(sources, exit, flows: Edge.flows(edge)),
          do: source

    Prima.Source.classes_of(uncovered)
  end

  def lets_flow(_policy, _sources), do: []

  # The exits a send through an edge is decided at: each egress domain as
  # the edge allows it, and each tool server it binds. A credential need
  # is an exit only of an attached request, which is decided at its host
  # too, and a need's flows only cover: what one leaves uncovered its
  # host's domain already does.
  defp exits(%Edge{tool_servers: servers} = edge) do
    Enum.map(Edge.domains(edge), &{:domain, &1}) ++
      for(%{server_name: name} when is_binary(name) <- servers, do: {:server, name})
  end

  @doc """
  What a model or hand child's answer says of its ledger: `{:carried,
  sources}` for a completion result carrying the ledger its terminal
  write left (`Opus.Close.complete/4`); `:nothing_ran` for a refusal the
  gate made at admission, before any attempt existed
  (`%Prima.Refusal{stage: :admission}`); `:unknown` for anything else —
  a failure, a death, an answer of another shape — whose ledger only the
  child's row can tell. Row absence never says nothing ran: retention
  may prune a terminal child before its step closes.
  """
  @spec child_ledger(term()) :: {:carried, [Prima.Source.t()]} | :nothing_ran | :unknown
  def child_ledger({:ok, %{sources: sources}}) when is_list(sources) do
    if Enum.all?(sources, &is_struct(&1, Prima.Source)),
      do: {:carried, sources},
      else: :unknown
  end

  def child_ledger({:error, %Prima.Refusal{stage: :admission}}), do: :nothing_ran
  def child_ledger(_answer), do: :unknown

  @doc """
  The sources `call`'s `result` carries into its turn, read under `ctx`,
  the context the call was dispatched under. A catalog action's are its
  operation's `sources:` declaration's, read from the caller's actor and
  the answer (`Prima.Operation.result_sources/3`): a success carries the
  declared classes or the answer's own provenance, an action that
  declares none is outside, a refusal the gate made at admission carries
  nothing, and any other failure every class the action may answer. An
  external server's tool is outside, named by its server; the HTTP hand
  is outside, named by the host its URL names; a files or storage read is
  `files_by_grant`. A hand also carries its child's ledger, as its
  completion result carries it (`child_ledger/1`; a hand's failure names
  none, and the loop reads its child's row). Any other call carries none
  here: a launched component's are judged from its tree's admitted
  egress and its result's ledger where its step closes
  (`Arca.TurnStorage.close_step/4`'s `:launched` and `:sources`).
  """
  @spec sources_of(Call.t(), term(), Sanctum.Context.t()) :: [Prima.Source.t()]
  def sources_of(%Call{kind: :external, target: target}, _result, _ctx),
    do: [Prima.Source.outside(server_of(target))]

  def sources_of(%Call{kind: :hand} = call, result, _ctx) do
    carried =
      case child_ledger(result) do
        {:carried, sources} -> sources
        _not_carried -> []
      end

    hand_sources(call) ++ carried
  end

  def sources_of(
        %Call{kind: :catalog, tool: tool, action: action},
        result,
        %Sanctum.Context{} = ctx
      ),
      do:
        Prima.Operation.result_sources(
          operation(tool, action),
          Sanctum.Context.actor(ctx),
          result
        )

  def sources_of(%Call{}, _result, _ctx), do: []

  # The catalogued operation a catalog call names, nil when none declares
  # it (`Prima.Operation.result_sources/3` reads that as outside), read
  # from the operation table as a chain's tool call reads it
  # (`Opus.Host.Children`).
  defp operation(tool, action) when is_binary(action) do
    case Map.get(Sanctum.Catalog.operations(), tool) do
      {_module, %{operations: operations}} when is_list(operations) ->
        Enum.find(operations, &(&1.action == action))

      _undeclared ->
        nil
    end
  end

  defp operation(_tool, _action), do: nil

  # What a hand's call names it read, whatever its child answered.
  defp hand_sources(%Call{tool: "http", args: args}),
    do: [Prima.Source.outside(host_of(args["url"]))]

  defp hand_sources(%Call{tool: tool, action: action}) when tool in ["files", "storage"] do
    if Aqua.Kinds.kind_for(tool, action) == :read,
      do: [Prima.Source.new(:files_by_grant)],
      else: []
  end

  defp hand_sources(%Call{}), do: []

  # `server:tool` is named by its server.
  defp server_of(target) when is_binary(target),
    do: target |> String.split(":", parts: 2) |> hd()

  defp server_of(_target), do: nil

  # A URL is named by its host, lowercased; one that names none is an
  # unnamed outside source.
  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp host_of(_url), do: nil

  # A launch is an external act, approved one card at a time.
  defp standing(%Call{kind: :launch}), do: Sanctum.Annotations.standing_to_wire(false)

  defp standing(%Call{} = call),
    do:
      Sanctum.Annotations.standing_to_wire(Aqua.Kinds.standing_for(call.tool, call.action || ""))

  @doc """
  The canonical proposal a card shows for `call`, and its digest hashes.
  With `account` (`t:account/0`), what a launch's named account resolved
  to when its card was drawn: its `connection` spelled as the binding
  stores the name, when the call names that account in any case
  (`Prima.Authority.Blob.same_account_name?/2`), and the entry beside
  the call (`vault_entry`). A launch's proposal also carries what its
  card binds of the run (`launch`, `Aqua.Launch.bind/1`; none bound
  when nil): the turn's sources, the launched grant's consent revision
  and the classes the approval lets flow, so its digest binds them.
  """
  @spec proposal(Call.t(), account() | nil, Aqua.Launch.binding() | nil) :: map()
  def proposal(call, account \\ nil, launch \\ nil)

  def proposal(%Call{} = call, account, launch) do
    %{"tool" => call.tool, "action" => call.action, "args" => account_args(call.args, account)}
    |> put_account(account)
    |> put_launch(call, launch)
  end

  defp account_args(args, %{name: stored}) do
    case args["connection"] do
      named when is_binary(named) ->
        if Prima.Authority.Blob.same_account_name?(named, stored),
          do: Map.put(args, "connection", stored),
          else: args

      _none ->
        args
    end
  end

  defp account_args(args, nil), do: args

  defp put_account(proposal, %{vault_entry: entry_id}),
    do: Map.put(proposal, "vault_entry", entry_id)

  defp put_account(proposal, nil), do: proposal

  defp put_launch(proposal, %Call{kind: :launch}, launch),
    do: Map.merge(proposal, Aqua.Launch.bind(launch))

  defp put_launch(proposal, %Call{}, _launch), do: proposal

  @doc "The digest a card is consumed by: the canonical proposal, hashed."
  @spec proposal_digest(map()) :: String.t()
  def proposal_digest(%{"proposal" => proposal}), do: proposal_digest(proposal)

  def proposal_digest(proposal) when is_map(proposal) do
    {:ok, digest} = Prima.JCS.hash(proposal)
    digest
  end

  defp name_level(reference), do: Aqua.Hands.name_level(reference)

  # A path names a component when the layout's one parser reads a version
  # directory in it, the same parser the unit locator and the `source` tool
  # read it with; any other path names none. Its segments are split as
  # every door that writes it splits them, empty ones dropped, so
  # `components//…` and `/components/…` name the unit the write lands in.
  defp path_refs(path) when is_binary(path) do
    case Compendium.parse_component_path(String.split(path, "/", trim: true)) do
      {:ok, %{type: type, publisher: publisher, name: name}} ->
        [Prima.ComponentRef.build(type, publisher, name)]

      :error ->
        []
    end
  end

  defp path_refs(_), do: []
end
