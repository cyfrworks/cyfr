# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Launch do
  @moduledoc """
  The one dispatcher of a launch: an `execution.run` of something that is
  neither a hand nor an agent, which becomes an external-plane
  `execution.run` as a person, so the application roots its own consent
  and the turn's pinned authority is never widened into it. A launch runs
  in one of two ways, by one pipeline (`run/3`):

    * **Approved**, on a card a member decided: as that approver, holding
      the run to what the card bound.
    * **Decided**, with no card: one the agent's policy let run under
      `auto` because the grant its app roots at covered what the turn had
      read (`Aqua.Loop.Policy`), as the turn's person, holding the run to
      what that decision read (`t:decided/0`). A run stands on the grant
      of the person it acts as, whoever started it; this is the
      assistant starting one.

  The input is the durable step, with the decision for a decided one. The
  person's context is rebuilt from the approval's `decided_by`, or for a
  decided launch from the turn's `requested_by`
  (`Sanctum.Tenancy.continuation/3`), so a launch consumed after a
  restart runs as that person, or not at all: an athanor no longer the
  person's refuses it. It carries the origin stored on the turn's row,
  never one inferred from the person: a programmatic turn's launch stays
  `programmatic`, and a turn whose row stores an origin outside the
  vocabulary, damage a hand-edited or restored row can carry, launches
  nothing (`{:approver_unavailable, :no_origin}`). The loop marks the
  step dispatched before calling here, which is what makes a launch
  happen once.

  What the launch runs is a proposal: the card's for an approved one, and
  for a decided one the proposal its card would have carried, made from
  the step's recorded call (the `tool_call` row the loop recalls a call
  from) and the decision (`Aqua.Loop.Policy.proposal/3`). Its arguments
  are held to the same rules either way: the assistant itself is never
  launched, a wrapped catalyst is a hand, and a caller's lineage is
  dropped.

  A launch naming an account (`connection`) runs under the account its
  proposal bound, or not at all: the account its name resolved to when
  the card was drawn or the run was decided (`vault_entry`) and the name
  as its binding stored it. Before anything runs the name is resolved
  again, as the person, from the app's stored head
  (`Sanctum.Consent.Accounts.resolve/4`, the one read the assistant's
  policy resolves it by), and a different entry, a name the head no
  longer binds or now stores otherwise, or an account the proposal did
  not bind is refused as stale, a conflict that says to ask or propose
  again. That check is the early refusal, not the guarantee. The run is
  asked for under the stored name and picks the named binding as its
  root's vault (`Opus.run_root/5`), and the account the proposal bound,
  its entry and its stored name, rides that one call on the person's
  context (`Sanctum.Context`'s `approved_entry`): the root is admitted
  only on a binding that names that entry under that name, judged on the
  same read of the head that picks the binding (`Opus.Admission`). A head
  that moves after the check here, binding the name to another entry,
  storing it otherwise or dropping it, refuses there,
  `:approved_entry_moved`, before anything starts, and reads as the same
  stale launch.

  The proposal also binds what the launch carries (`bind/1`): the turn's
  sources, the consent revision of the grant the app roots at, and the
  classes let flow to every exit of that grant's tree — those the person
  let flow on a card, none for a decided launch, whose grant already
  covered every source. Before anything runs the turn's sources are read
  again, and any the turn read since refuse the launch as stale; the
  grant is loaded again as the person, and another revision refuses it as
  stale, as does, for a decided launch, a grant that now loads where the
  decision found none. Then what the proposal bound rides the one call on
  the person's context (`Sanctum.Context`'s `launch`): the root is
  admitted only at that revision, seeded with those sources, with those
  classes in its policy, under the step's pre-minted id
  (`Opus.Admission`), and a grant that moves after the check here refuses
  there as the same stale launch. A proposal that bound no revision lets
  nothing flow, so whatever grant the root loads decides its sends alone;
  for a component with no grant the gate answers `consent_required`. The
  run's root never takes a seed, a class or an id from anything a caller
  sends.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @typedoc """
  What a launch's card binds of the run it approves: the turn's sources
  the launched root is seeded with, the consent revision of the grant the
  app roots at (nil when none could be loaded as the card was drawn), and
  the classes the person lets flow to every exit of that grant's tree.
  """
  @type binding :: %{
          sources: [Prima.Source.t()],
          consent_id: String.t() | nil,
          classes: [Prima.Source.class()]
        }

  @typedoc """
  What the decision that let a launch run with no card read of it
  (`Aqua.Loop.Policy.decide/3`'s `{:auto, decided}`), which the run is
  held to as it dispatches: the account its call names as it resolved
  then (nil for a launch naming none), and the binding the run stands on:
  the turn's sources, the revision of the grant its app roots at, which
  covered them (nil for a component with no grant), and no class let
  flow. It lives in the loop from the decision to the dispatch and is
  stored nowhere: a turn continued from its rows decides its steps again.
  """
  @type decided :: %{
          account: %{vault_entry: String.t(), name: String.t()} | nil,
          binding: %{sources: [Prima.Source.t()], consent_id: String.t() | nil, classes: []}
        }

  @launch_actions ~w(run run_stream)

  @doc """
  Whether `tool.action` launches what it names when that is a component:
  `execution.run` and `execution.run_stream`.
  """
  @spec launch_action?(String.t(), String.t()) :: boolean()
  def launch_action?("execution", action), do: action in @launch_actions
  def launch_action?(_tool, _action), do: false

  @doc """
  Run the launch (`run/3`): the one the step was approved for, as its
  approver, or with `decided` the one its decision let run with no card,
  as the turn's person. Answers the execution the application started
  (`execution_id` is nil when the answer names none) with the tool's
  whole result, or the refusal.
  """
  @spec dispatch(Context.t(), Tape.step(), decided() | nil) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}} | {:error, term()}
  def dispatch(%Context{} = ctx, step, decided \\ nil) do
    case run(ctx, step, decided) do
      {:refused, reason} -> {:error, reason}
      answered -> answered
    end
  end

  @doc """
  Run a launch. With no `decided`, the step's approved card is what runs,
  as its approver; a step with no approval runs nothing
  (`{:refused, :not_approved}`). With `decided`, what the decision read
  is what runs, as the turn's person, with no card and no class let flow.

  Tells a refusal made before the run's admission could write anything —
  by this dispatcher, by the gate's admission stage
  (`%Prima.Refusal{stage: :admission}`), or by the root's load finding
  the account or the grant the launch was held to moved
  (`:approved_entry_moved`, `:approved_grant_moved`) — as
  `{:refused, reason}`: nothing of the launch ran, and no row was or
  will be written under its id. `{:error, reason}` is any other ending,
  whose run only its row can tell. The loop reads the difference.
  """
  @spec run(Context.t(), Tape.step(), decided() | nil) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}}
          | {:refused, term()}
          | {:error, term()}
  def run(ctx, step, decided \\ nil)

  def run(%Context{} = ctx, step, %{account: _, binding: %{classes: []}} = decided) do
    case decided_launch(ctx, step, decided) do
      {:ok, launcher, args} -> launch(launcher, args, :decided)
      {:error, reason} -> {:refused, reason}
    end
  end

  def run(%Context{} = ctx, %{approval_id: approval_id} = step, nil)
      when is_binary(approval_id) do
    case launchable(ctx, step, approval_id) do
      {:ok, launcher, args} -> launch(launcher, args, :approved)
      {:error, reason} -> {:refused, reason}
    end
  end

  def run(_ctx, _step, _decided), do: {:refused, :not_approved}

  @doc """
  The proposal fields a launch's card binds `binding` under, its digest's
  part of the proposal: the sources as canonical JSON (`sources`), the
  classes it lets flow (`lets_flow`) and the grant's consent revision
  (`consent_id`). The digest's canonical form carries no null, so a
  source's absent name and a revision no grant gave are left out. Nil
  binds no source, no class and no revision.
  """
  @spec bind(binding() | nil) :: map()
  def bind(nil), do: bind(%{sources: [], consent_id: nil, classes: []})

  def bind(%{sources: sources, consent_id: consent_id, classes: classes}) do
    %{
      "sources" =>
        for(
          json <- Prima.Source.to_json_list(sources),
          do: Map.reject(json, &is_nil(elem(&1, 1)))
        ),
      "lets_flow" =>
        for(class <- Prima.Source.classes(), class in classes, do: Atom.to_string(class))
    }
    |> Prima.MapUtil.put_present("consent_id", consent_id)
  end

  @doc """
  What a launch card's `proposal` bound (`bind/1`). A proposal that
  bound none of it reads as having bound no source, no revision and no
  class.
  """
  @spec bound(map()) :: binding()
  def bound(proposal) when is_map(proposal) do
    sources =
      case proposal["sources"] do
        list when is_list(list) ->
          list |> Enum.map(&Prima.Source.from_json/1) |> Prima.Source.set()

        _none ->
          []
      end

    classes =
      case proposal["lets_flow"] do
        list when is_list(list) ->
          Enum.filter(Prima.Source.classes(), &(Atom.to_string(&1) in list))

        _none ->
          []
      end

    consent_id =
      case proposal["consent_id"] do
        id when is_binary(id) -> id
        _none -> nil
      end

    %{sources: sources, consent_id: consent_id, classes: classes}
  end

  @doc """
  The root authority a launch of `reference` with `action` and `args`
  would run under, loaded as `ctx` without running anything
  (`Opus.authority_for/4`): the profile its `profile` argument selects,
  else the default owner profile, under the account an `execution.run`
  names. What a launch's card is drawn against and what this dispatcher
  reads again before the launch runs.
  """
  @spec authority(Context.t(), String.t(), String.t() | nil, map()) ::
          {:ok, Prima.Authority.t()} | {:error, term()}
  def authority(%Context{} = ctx, reference, action, args)
      when is_binary(reference) and is_map(args) do
    opts =
      case {action, args["connection"]} do
        {"run", name} when is_binary(name) -> [connection: name]
        _none -> []
      end

    Opus.authority_for(ctx, Prima.Authority.RootSelect.decode(args["profile"]), reference, opts)
  end

  # Everything an approved launch is held to before it is asked for, read
  # as it stands now, and the approver's context the one call is made
  # under.
  defp launchable(ctx, step, approval_id) do
    with {:ok, approval} <- Tape.approval(ctx, approval_id),
         :ok <- approved_launch(approval),
         {:ok, card} <- Tape.message(ctx, approval.message_id),
         :ok <- card_approved(approval, card),
         {:ok, approver, turn} <- approver(ctx, approval) do
      held(approver, turn, proposal_of(card), step, :approved)
    end
  end

  # What a decided launch is held to: the proposal its card would have
  # carried, made from the step's recorded call and what the decision
  # read, run as the turn's person.
  defp decided_launch(ctx, step, %{account: account, binding: binding}) do
    with {:ok, call} <- recorded_call(ctx, step),
         {:ok, person, turn} <- person(ctx, step) do
      held(person, turn, Aqua.Loop.Policy.proposal(call, account, binding), step, :decided)
    end
  end

  # The one pipeline both heads hold a launch to: its arguments, the
  # turn's sources, the account and the grant, each against what the
  # proposal bound, then the person's context for the one call.
  defp held(caller, turn, proposal, step, head) do
    shown = bound(proposal)

    with {:ok, args} <- launch_args(proposal),
         {:ok, sources} <- sources_hold(turn, shown, head),
         :ok <- account_holds(caller, proposal, args, head),
         :ok <- grant_holds(caller, shown, args, head) do
      launcher =
        caller
        |> expecting(proposal, args)
        |> launching(sources, shown, step)

      {:ok, launcher, args}
    end
  end

  defp launch(launcher, args, head) do
    case Aqua.Ops.call_tool("execution", launcher, args) do
      {:ok, result} -> {:ok, %{execution_id: execution_id(result), result: result}}
      {:error, :approved_entry_moved} -> {:refused, stale(head, args["connection"])}
      {:error, :approved_grant_moved} -> {:refused, moved(head, :grant)}
      {:error, %Prima.Refusal{stage: :admission} = refused} -> {:refused, refused}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approved_launch(%{status: "approved", resolution_kind: "launch"}), do: :ok
  defp approved_launch(_approval), do: {:error, :not_approved}

  # The launch runs what the approval was opened for, or nothing.
  defp card_approved(approval, card) do
    proposal = get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal"])

    if Aqua.Approvals.proposal?(approval, proposal),
      do: :ok,
      else: {:error, {:invalid_argument, "the card no longer matches its approval"}}
  end

  # The call a decided launch's step recorded, from its `tool_call` row,
  # resolved as the loop resolves it: a launch, or nothing runs.
  defp recorded_call(ctx, %{kind: "launch", message_id: message_id})
       when is_binary(message_id) do
    with {:ok, row} <- Tape.message(ctx, message_id) do
      payload = Arca.ThreadStorage.payload(row)

      case Aqua.Loop.Binding.resolve(payload["name"] || "", payload["arguments"] || %{}) do
        {:ok, %Aqua.Loop.Binding.Call{kind: :launch} = call} -> {:ok, call}
        {:ok, _not_a_launch} -> {:error, {:invalid_argument, "the step's call is not a launch"}}
        {:error, message} -> {:error, {:invalid_argument, message}}
      end
    end
  end

  defp recorded_call(_ctx, _step), do: {:error, {:invalid_argument, "the step records no launch"}}

  # The proposal, as the model wrote it and the person saw it or the
  # decision read it. The assistant itself is never launched, and a
  # wrapped catalyst is a hand, not a launch — both are decided again at
  # this last door, whatever the proposal said.
  defp launch_args(proposal) do
    case proposal do
      %{"tool" => "execution", "action" => action, "args" => args}
      when action in @launch_actions and is_map(args) ->
        reference = args["reference"]

        cond do
          not is_binary(reference) ->
            {:error, {:invalid_argument, "execution.#{action} needs a reference"}}

          Prima.AgentRef.agent_ref?(reference) ->
            {:error, {:invalid_argument, "an agent is not a tool to run"}}

          Aqua.Hands.hand_catalyst?(reference) ->
            {:error, {:invalid_argument, "#{reference} is a hand, not a launch"}}

          true ->
            {:ok,
             args
             |> Map.put("action", action)
             |> Map.drop(["parent_execution_id", "root_execution_id", "thread_id"])}
        end

      _ ->
        {:error, {:invalid_argument, "the card carries no launch"}}
    end
  end

  # The account the proposal bound is the account the launch runs under:
  # the stored name its arguments carry still resolves, as the person, to
  # the entry the proposal bound, under that name as the binding stores
  # it. A launch naming none runs under the default, and bound no entry.
  defp account_holds(caller, proposal, args, head) do
    stored = args["connection"]

    case {bound_entry(proposal), launch_account(caller, args)} do
      {nil, {:ok, nil}} -> :ok
      {entry_id, {:ok, %{entry_id: entry_id, name: ^stored}}} when is_binary(entry_id) -> :ok
      {_shown, {:error, reason}} when reason != :connection_not_granted -> {:error, reason}
      _another_account_or_none -> {:error, stale(head, stored)}
    end
  end

  # The turn's sources are the ones the proposal bound: the run is seeded
  # with them and the classes it lets flow, or the grant's cover, were
  # judged over them, so a source the turn read after the card or the
  # decision is not what was approved or decided. Answers the turn's
  # sources as they stand.
  defp sources_hold(turn, %{sources: shown}, head) do
    current = Prima.Source.decode(turn.sources)

    if Prima.Source.set(current) == Prima.Source.set(shown),
      do: {:ok, current},
      else: {:error, moved(head, :sources)}
  end

  # The grant the app roots at is still the consent revision the proposal
  # bound, read again as the person before anything runs: the classes a
  # card lets flow, and a decision's cover, were judged against that
  # grant's exits. A grant gone, or another revision, is stale; one that
  # cannot be read now is that refusal. This is the early refusal, not the
  # guarantee: the run's root is admitted only at the revision bound
  # (`Opus.Admission`), on the same read of the head that picks it. A card
  # that bound no revision let nothing flow (`launching/4`), and holds
  # whatever grant loads; a decision that found no grant holds only while
  # there is still none, for the gate to answer, so a grant made since is
  # decided again on what it covers.
  defp grant_holds(_approver, %{consent_id: nil}, _args, :approved), do: :ok

  defp grant_holds(person, %{consent_id: nil}, args, :decided) do
    case authority(person, args["reference"], args["action"], args) do
      {:error, :no_profile} -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, _granted_since} -> {:error, moved(:decided, :grant)}
    end
  end

  defp grant_holds(caller, %{consent_id: shown}, args, head) do
    case authority(caller, args["reference"], args["action"], args) do
      {:ok, %{consent_id: ^shown}} -> :ok
      {:error, reason} when reason != :no_profile -> {:error, reason}
      _another_grant_or_none -> {:error, moved(head, :grant)}
    end
  end

  # The entry the proposal bound, or nil for a launch naming none.
  defp bound_entry(proposal), do: proposal["vault_entry"]

  # The person's context for the one call the launch is dispatched as,
  # carrying the account the proposal bound: the entry and the name its
  # binding stored, which the arguments carry (`account_holds/4` has held
  # the two together). The run's root is admitted on that binding or not
  # at all. A proposal that bound no entry sets nothing.
  defp expecting(caller, proposal, args) do
    case {bound_entry(proposal), args["connection"]} do
      {entry_id, name} when is_binary(entry_id) and is_binary(name) ->
        %{caller | approved_entry: %{entry: entry_id, name: name}}

      _none ->
        caller
    end
  end

  # The person's context also carries what the proposal bound for the
  # run's root (`Sanctum.Context.stamp_launch/2`, called here alone), never
  # from anything a caller sends: the turn's sources the root is seeded
  # with (`sources_hold/3` has held them to the proposal's), the classes it
  # lets flow — only ever among those sources' own, none for a proposal
  # that bound no grant to judge them against, and none for a decided
  # launch — the consent revision the root must load at, and the root's
  # id: the step's pre-minted child id, so the loop can read the root's
  # row whatever the launch answers.
  defp launching(caller, sources, %{classes: classes, consent_id: consent_id}, step) do
    held = if is_binary(consent_id), do: Prima.Source.classes_of(sources), else: []

    Sanctum.Context.stamp_launch(caller, %{
      sources: sources,
      classes: Enum.filter(classes, &(&1 in held)),
      consent_id: consent_id,
      execution_id: root_id(step)
    })
  end

  defp root_id(%{child_execution_id: id}) when is_binary(id), do: id
  defp root_id(_step), do: Prima.UUID7.execution_id()

  defp proposal_of(card) do
    case get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal"]) do
      %{} = proposal -> proposal
      _none -> %{}
    end
  end

  # The entry the account an `execution.run` names resolves to on the
  # app's own profile, by the one read of it; none for a launch naming no
  # account, and for a stream, which declares none and is refused naming
  # one by the gate.
  defp launch_account(approver, %{"action" => "run", "connection" => name} = args)
       when is_binary(name) do
    Sanctum.Consent.Accounts.resolve(
      approver,
      Prima.Authority.RootSelect.decode(args["profile"]),
      args["reference"],
      name
    )
  end

  defp launch_account(_approver, _args), do: {:ok, nil}

  # A stale launch in its head's words: an approved one is asked again, a
  # decided one proposed again, deciding it on what stands now.
  defp stale(:approved, name) do
    {:conflict,
     account(name) <>
       " is not the one this launch was approved for, so nothing ran: ask again to " <>
       "approve the account as it stands now"}
  end

  defp stale(:decided, name) do
    {:conflict,
     account(name) <>
       " is not the one this run was decided on, so nothing ran: propose it again to run " <>
       "it on the account as it stands now"}
  end

  defp account(name) when is_binary(name), do: "The account #{inspect(name)}"
  defp account(_none), do: "The default account"

  # An approved launch that moved, in the refusal table's own sentence for
  # it; a decided one in this dispatcher's.
  defp moved(:approved, :sources), do: {:conflict, Prima.Refusal.message(:approved_sources_moved)}
  defp moved(:approved, :grant), do: {:conflict, Prima.Refusal.message(:approved_grant_moved)}

  defp moved(:decided, :sources),
    do:
      {:conflict,
       "This turn read more since the run was decided, so nothing ran: propose it again to " <>
         "decide it on what the turn has read now."}

  defp moved(:decided, :grant),
    do:
      {:conflict,
       "The component's grant changed since the run was decided, so nothing ran: propose it " <>
         "again to decide it on the grant as it stands now."}

  # The approver continues the turn the approval was opened in, under the
  # origin that turn's row stores; the turn is answered as read.
  defp approver(%Context{} = ctx, %{decided_by: user_id, turn_id: turn_id})
       when is_binary(user_id) and is_binary(turn_id) do
    with {:ok, turn} <- Tape.turn(ctx, turn_id), do: continuing(ctx, user_id, turn)
  end

  defp approver(_ctx, _approval), do: {:error, {:approver_unavailable, :denied}}

  # A decided launch runs as the turn's person, the one who asked for it
  # (`requested_by`), under the origin the turn's row stores.
  defp person(%Context{} = ctx, %{turn_id: turn_id}) when is_binary(turn_id) do
    case Tape.turn(ctx, turn_id) do
      {:ok, %{requested_by: user_id} = turn} when is_binary(user_id) ->
        continuing(ctx, user_id, turn)

      {:ok, _no_person} ->
        {:error, {:approver_unavailable, :denied}}

      {:error, _} = error ->
        error
    end
  end

  defp person(_ctx, _step), do: {:error, {:approver_unavailable, :denied}}

  defp continuing(ctx, user_id, turn) do
    case Sanctum.Tenancy.continuation(user_id, Context.athanor!(ctx), turn.origin) do
      {:ok, caller} -> {:ok, caller, turn}
      {:error, reason} -> {:error, {:approver_unavailable, reason}}
    end
  end

  defp execution_id(%{execution_id: id}) when is_binary(id), do: id
  defp execution_id(_result), do: nil
end
