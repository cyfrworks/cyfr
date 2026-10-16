# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Policy do
  @moduledoc """
  What a resolved call may do under the agent's effective policy: run at
  once, ask the person first, or be refused — and whether it may run
  beside others.

  The policy is `Aqua.ToolGrants.resolve/2`'s guest spelling
  (`"tool.action" => "auto" | "ask" | "deny"`, `"role.*" => "auto"`),
  already under the kind ceiling: a destructive or external action is
  never `auto` without a standing grant. A hand or catalog call reads its
  own key; a clone reads its role's glob; the `ui` event runs at once; an
  external server's tool always asks; a launch asks, whatever the
  agent's own policy or a standing answer says, since `Aqua.Launch` runs
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

  `sources_of/2` names the sources a call's result carries into its
  turn: `filed` and the notes' own provenance for a notes read,
  `files_by_grant` for a files or storage read and a component's source,
  and an outside source named by its origin for an external server's
  tool, the HTTP hand and a feed's results, and a launched component
  whose grant reaches the network.

  `touched_refs/1` names the components a turn's closed write,
  destructive and execute calls reached, from their durable rows.
  """

  alias Aqua.Loop.Binding.Call
  alias Prima.Authority.RootSelect

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
  (`opts[:account]`, `proposal/2`), so the approval binds the account the
  card showed. The card names the sources the turn has read
  (`opts[:sources]`, canonical JSON): a standing answer may follow only
  the outside ones it names.
  """
  @spec card(Call.t(), keyword()) :: map()
  def card(%Call{} = call, opts \\ []) do
    proposal = proposal(call, Keyword.get(opts, :account))

    %{
      "kind" => "request_approval",
      "id" => Keyword.get(opts, :id) || Prima.UUID7.generate_id("apr"),
      "title" => Keyword.get(opts, :title) || "#{call.tool}.#{call.action}",
      "summary" => Keyword.get(opts, :summary) || "",
      "action_kind" =>
        Atom.to_string(Aqua.Kinds.kind_for(call.tool, call.action || "") || :external),
      "standing" => standing(call),
      "proposal" => proposal,
      "sources" => Prima.Source.to_json_list(Keyword.get(opts, :sources, []))
    }
  end

  @doc """
  The sources `call`'s `result` carries into its turn. A notes read is
  `filed`, joined by the provenance of every note it answered; a files or
  storage read and a component's source are `files_by_grant`; an
  external server's tool is outside, named by its server; the HTTP hand
  is outside, named by the host its URL names; a feed's listing is
  outside, named by each feed whose result it carries. Any other call
  carries none here: a launched component's are judged from its tree's
  admitted egress where its step closes (`Arca.TurnStorage.close_step/4`'s
  `:launched`). A result is joined whatever its outcome: an error body is
  read too.
  """
  @spec sources_of(Call.t(), term()) :: [Prima.Source.t()]
  def sources_of(%Call{kind: :external, target: target}, _result),
    do: [Prima.Source.outside(server_of(target))]

  def sources_of(%Call{kind: :hand, tool: "http", args: args}, _result),
    do: [Prima.Source.outside(host_of(args["url"]))]

  def sources_of(%Call{kind: :hand, tool: tool, action: action}, _result)
      when tool in ["files", "storage"] do
    if Aqua.Kinds.kind_for(tool, action) == :read,
      do: [Prima.Source.new(:files_by_grant)],
      else: []
  end

  def sources_of(%Call{kind: :catalog, tool: "source", action: action}, _result) do
    if Aqua.Kinds.kind_for("source", action) == :read,
      do: [Prima.Source.new(:files_by_grant)],
      else: []
  end

  def sources_of(%Call{kind: :catalog, tool: "notes", action: action}, result)
      when action in ["read", "list", "search"],
      do: [Prima.Source.new(:filed) | Aqua.Notes.sources_of_answer(result)]

  def sources_of(%Call{kind: :catalog, tool: "feed", action: "list"}, result),
    do: feed_sources(result)

  def sources_of(%Call{}, _result), do: []

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

  # Each feed whose result the listing carries, by its binding; a listing
  # that cannot be read is an unnamed outside source.
  defp feed_sources({:ok, %{feeds: feeds}}) when is_list(feeds) do
    for %{binding_id: id} = feed <- feeds, Map.get(feed, :result) != nil do
      Prima.Source.outside("feed:#{id}")
    end
  end

  defp feed_sources({:ok, _other}), do: [Prima.Source.outside(nil)]
  defp feed_sources(_failed), do: []

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
  the call (`vault_entry`).
  """
  @spec proposal(Call.t(), account() | nil) :: map()
  def proposal(call, account \\ nil)

  def proposal(%Call{} = call, nil),
    do: %{"tool" => call.tool, "action" => call.action, "args" => call.args}

  def proposal(%Call{args: args} = call, %{vault_entry: entry_id, name: stored}) do
    args =
      case args["connection"] do
        named when is_binary(named) ->
          if Prima.Authority.Blob.same_account_name?(named, stored),
            do: Map.put(args, "connection", stored),
            else: args

        _none ->
          args
      end

    %{"tool" => call.tool, "action" => call.action, "args" => args, "vault_entry" => entry_id}
  end

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
