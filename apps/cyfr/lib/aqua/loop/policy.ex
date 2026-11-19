# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Policy do
  @moduledoc """
  What a resolved call may do under its member's mode: run, or be
  refused with a sentence — and whether it may run beside others.

  A call is decided in this order, and nothing is ever asked:

    1. **Outside the job.** A call outside the tools a crew request
       narrowed its job to is refused (`within?/2`).
    2. **Shown, not run.** The `ui` event and `request_setup.open` run:
       they only show the person something.
    3. **Not offered.** A call whose key the turn's offered set
       (`Aqua.Offered`) does not hold is refused; a browser action the
       person's browser setting turned off is refused in the browser's
       own words. A launch is offered by `execution.run` or
       `execution.run_stream`, an outside server's tool by its
       `server:tool`.
    4. **The mode.** `auto` runs every offered call. `read-only` runs a
       call whose action's declared kind is `:read` (`Aqua.Kinds`) and the
       turn's own start of its program brain, which the holder starts
       read-only (`Opus.Brain`); it refuses every other call, a launch and
       an outside server's tool among them, with `read_only_sentence/1`.

  A launch is refused before the mode when its reference names no
  component, and a launch naming an account (`connection`) has it
  resolved first (`launch_account/2`), as account names compare: the
  entry the launched app's own profile binds under that name, and the
  name as the binding stores it. A name the profile does not bind ends
  the call as setup required. A launch that runs is decided `{:run,
  decided}`: the call and its account, which `Aqua.Launch` holds the run
  to as it dispatches (`t:Aqua.Launch.decided/0`).
  It pins no grant: the grant the app roots at when it runs decides its
  sends, and a component with none is answered `consent_required` by the
  gate.

  `sources_of/3` names the sources a call's result carries into its
  turn: a catalog action's as its operation declares them
  (`Prima.Operation.result_sources/3`, an undeclared one outside),
  `files_by_grant` for a files or storage read, and an outside source
  named by its origin for an external server's tool and the HTTP hand;
  and a hand's child its own ledger, as its completion result carries it
  (`child_ledger/1`).
  """

  alias Aqua.Loop.Binding.Call
  alias Prima.Authority.RootSelect

  @typedoc """
  A launch's account as its decision binds it: the entry the name
  resolved to and the name as its binding stores it (`launch_account/2`).
  """
  @type account :: %{vault_entry: String.t(), name: String.t()}

  @typedoc """
  What a call does: run, a launch with what its decision read; be denied,
  refused, or refused by a read-only mode, with a sentence; or, for a
  launch naming an account its app's profile does not bind, end the turn
  as setup required, naming the app, its credential need (nil: the one
  need, or one no binding tells) and the account.
  """
  @type decision ::
          :run
          | {:run, Aqua.Launch.decided()}
          | {:deny, String.t()}
          | {:refuse, String.t()}
          | {:read_only, String.t()}
          | {:setup_required, String.t(), {String.t() | nil, String.t()}}

  @doc """
  The decision for `call` among the `offered` set under `mode`
  (`read-only` or `auto`, `Compendium.AquaAgent`). A restricted turn's
  calls reach here only when replay-safe (`Aqua.Loop` denies the rest
  first). `opts`: `:narrowed` (the tools a crew request narrowed the job
  to, nil for none), `:host_start` (true for the turn's own start of its
  program brain), `:title` (the member's title, which a read-only
  refusal names) and `:ctx` (the member's context a launch's account is
  resolved under). Without a context a launch naming an account is
  refused.
  """
  @spec decide(Call.t(), Aqua.Offered.t(), String.t(), keyword()) :: decision()
  def decide(%Call{} = call, offered, mode, opts) when is_map(offered) do
    cond do
      not within?(call, Keyword.get(opts, :narrowed)) -> {:deny, outside(call)}
      call.kind == :ui -> :run
      Keyword.get(opts, :host_start) == true -> :run
      true -> decide_offered(call, offered, mode, opts)
    end
  end

  @doc """
  Whether `call` is among the tools a crew request narrowed its job to
  (`names`, each a tool or a `tool.action`; nil when nothing was
  narrowed): a bound on every kind of call, hands, catalog actions,
  external tools and launches alike, judged when the call is decided and
  again when it dispatches. The `ui` event and `request_setup` are the
  console's and are never narrowed away.
  """
  @spec within?(Call.t(), [String.t()] | nil) :: boolean()
  def within?(_call, nil), do: true
  def within?(%Call{kind: :ui}, _names), do: true

  def within?(%Call{kind: :external, tool: tool}, names) when is_list(names),
    do: tool in names

  def within?(%Call{tool: tool} = call, names) when is_list(names),
    do: tool in names or key(call) in names

  @doc "The sentence a call outside its job's tools is refused with."
  @spec outside(Call.t()) :: String.t()
  def outside(%Call{kind: :external, tool: tool}),
    do: "#{tool} is outside the tools this job was narrowed to"

  def outside(%Call{} = call), do: "#{key(call)} is outside the tools this job was narrowed to"

  @doc """
  The sentence a read-only member's refused call answers, and the line
  the thread is given once per turn: the member by its title, and the one
  way to let it. The refused step shows in the thread in its own words.
  """
  @spec read_only_sentence(String.t()) :: String.t()
  def read_only_sentence(title) when is_binary(title) do
    "#{title} is read-only, so it refused a step that does more than read. " <>
      "To let it, switch #{title} to auto on the Aqua page."
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

  defp decide_offered(%Call{} = call, offered, mode, opts) do
    case Map.get(offered, offered_key(call)) do
      "offered" -> by_mode(call, mode, opts)
      "off" -> {:deny, Aqua.Providers.Browser.turned_off()}
      nil -> {:deny, "#{name(call)} is not among the tools #{title(opts)} is offered"}
    end
  end

  # A launch is refused first when it names no component; then the mode.
  defp by_mode(%Call{kind: :launch, target: reference} = call, mode, opts) do
    cond do
      not component_ref?(reference) ->
        {:refuse, "#{inspect(reference)} is not a component reference"}

      mode == "auto" ->
        launch(call, opts)

      true ->
        {:read_only, read_only_sentence(title(opts))}
    end
  end

  defp by_mode(%Call{}, "auto", _opts), do: :run

  defp by_mode(%Call{kind: kind, tool: tool, action: action}, _read_only, opts) do
    if kind in [:hand, :catalog] and Aqua.Kinds.kind_for(tool, action) == :read,
      do: :run,
      else: {:read_only, read_only_sentence(title(opts))}
  end

  # The key a call is offered under: an outside server's tool by its
  # `server:tool`, anything else by its `tool.action`.
  defp offered_key(%Call{kind: :external, tool: tool}), do: tool
  defp offered_key(%Call{} = call), do: key(call)

  defp name(%Call{kind: :external, tool: tool}), do: tool
  defp name(%Call{} = call), do: key(call)

  defp title(opts), do: Keyword.get(opts, :title) || "Aqua"

  # A launch that runs binds what its decision read: its call and the
  # account it names as resolved now.
  defp launch(%Call{} = call, opts) do
    with {:ok, account} <- decided_account(call, Keyword.get(opts, :ctx)) do
      {:run, %{call: %{action: call.action, args: call.args}, account: account}}
    end
  end

  defp key(%Call{tool: tool, action: action}), do: "#{tool}.#{action}"

  @doc """
  Whether `call` may run beside other calls of the same batch: only a
  read does; a write, an execute and a destructive act run alone.
  """
  @spec overlap(Call.t()) :: :concurrent | :exclusive
  def overlap(%Call{kind: kind, tool: tool, action: action}) when kind in [:hand, :catalog] do
    if Aqua.Kinds.kind_for(tool, action) == :read, do: :concurrent, else: :exclusive
  end

  def overlap(%Call{}), do: :exclusive

  @doc """
  A batch of dispatch items split into the groups the loop runs in order:
  consecutive reads gather into one `{:concurrent, items}` group, and
  anything else stands alone as `{:exclusive, item}`, or as `{:launch,
  item}` for a launch step. A non-read flushes the reads waiting before it
  and stands alone, so no read after it joins it. Which calls share a
  group decides what runs beside what.
  """
  @spec group([map()]) :: [{:concurrent, [map()]} | {:exclusive | :launch, map()}]
  def group(items) when is_list(items) do
    {groups, pending} =
      Enum.reduce(items, {[], []}, fn item, {groups, reads} ->
        cond do
          launch?(item) -> {[{:launch, item} | gather(reads, groups)], []}
          concurrent?(item) -> {groups, [item | reads]}
          true -> {[{:exclusive, item} | gather(reads, groups)], []}
        end
      end)

    pending |> gather(groups) |> Enum.reverse()
  end

  defp gather([], groups), do: groups
  defp gather(reads, groups), do: [{:concurrent, Enum.reverse(reads)} | groups]

  defp launch?(%{step: %{kind: "launch"}}), do: true
  defp launch?(_item), do: false

  defp concurrent?(%{call: {:ok, %Call{} = call}}), do: overlap(call) == :concurrent
  defp concurrent?(_item), do: false

  defp component_ref?(reference), do: match?({:ok, _}, Prima.ComponentRef.parse(reference))

  # The account a launch names, resolved as its decision binds it; nil
  # for one naming none.
  defp decided_account(%Call{} = call, ctx) do
    case launch_account(call, ctx) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{entry_id: entry_id, name: stored}} ->
        {:ok, %{vault_entry: entry_id, name: stored}}

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
  What a model or hand child's answer says of its ledger: `{:carried,
  sources}` for a completion result carrying the ledger its terminal
  write left (`Opus.Close.complete/3`); `:nothing_ran` for a refusal the
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
end
