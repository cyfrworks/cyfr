# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Launch do
  @moduledoc """
  The one dispatcher of a launch: an `execution.run` of something that is
  neither a hand nor an agent, which becomes an external-plane
  `execution.run` as a person, so the application roots its own consent
  and the turn's pinned authority is never widened into it. A launch is
  one a member in `auto` called (`Aqua.Loop.Policy`), run (`run/3`) as
  the turn's person and held to what that decision read (`t:decided/0`).
  A run stands on the grant of the person it acts as, whoever started
  it; this is the assistant starting one.

  The input is the durable step and its decision. The person's context
  is rebuilt from the turn's `requested_by`
  (`Sanctum.Tenancy.continuation/3`), so a launch consumed after a
  restart runs as that person, or not at all: an athanor no longer the
  person's refuses it. It carries the origin stored on the turn's row,
  never one inferred from the person: a programmatic turn's launch stays
  `programmatic`, and a turn whose row stores an origin outside the
  vocabulary, damage a hand-edited or restored row can carry, launches
  nothing (`{:approver_unavailable, :no_origin}`). The loop marks the
  step dispatched before calling here, which is what makes a launch
  happen once.

  What the launch runs is a proposal (`proposal/4`, its one definition),
  made from the step's own row and what the decision read. The
  dispatcher reads the step's recorded call itself — the action the step
  was recorded for and the arguments its `tool_call` row holds — runs
  what the row says, and refuses, with nothing run, a decision made on
  any other call. Its arguments are held to rules of their own: the
  assistant itself is never launched, a wrapped catalyst is a hand, and
  a caller's lineage is dropped.

  A launch naming an account (`connection`) runs under the account its
  proposal bound, or not at all: the account its name resolved to when
  the run was decided (`vault_entry`) and the name as its binding stored
  it. Before anything runs the name is resolved again, as the person,
  from the app's stored head (`Sanctum.Consent.Accounts.resolve/4`, the
  one read the assistant's policy resolves it by), and a different
  entry, a name the head no longer binds or now stores otherwise, or an
  account the proposal did not bind is refused as stale, a conflict that
  says to propose again. That check is the early refusal, not the
  guarantee. The run is asked for under the stored name and picks the
  named binding as its root's vault (`Opus.run_root/5`), and the account
  the proposal bound, its entry and its stored name, rides that one call
  on the person's context (`Sanctum.Context`'s `approved_entry`): the
  root is admitted only on a binding that names that entry under that
  name, judged on the same read of the head that picks the binding
  (`Opus.Admission`). A head that moves after the check here, binding the
  name to another entry, storing it otherwise or dropping it, refuses
  there, `:approved_entry_moved`, before anything starts, and reads as
  the same stale launch.

  The proposal also binds what the launch carries (`bind/1`): the turn's
  sources, and no grant revision and no class let flow. Before anything
  runs the turn's sources are read again, and any the turn read since
  refuse the launch as stale. Then what the proposal bound rides the one
  call on the person's context (`Sanctum.Context`'s `launch`): the root
  is admitted seeded with those sources under the step's pre-minted id
  (`Opus.Admission`), and whatever grant it loads decides its sends
  alone; for a component with no grant the gate answers
  `consent_required`. The run's root never takes a seed, a class or an id
  from anything a caller sends.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @typedoc """
  What a launch's proposal binds of the run: the turn's sources the
  launched root is seeded with, the consent revision of the grant the app
  roots at, and the classes let flow to every exit of that grant's tree;
  a decided launch binds no revision and no class.
  """
  @type binding :: %{
          sources: [Prima.Source.t()],
          consent_id: String.t() | nil,
          classes: [Prima.Source.class()]
        }

  @typedoc """
  An account a proposal binds: the entry its name resolved to and the
  name as its binding stores it.
  """
  @type account :: %{vault_entry: String.t(), name: String.t()}

  @typedoc """
  What the decision that let a launch run read of it (the assistant's
  policy's `{:run, decided}`), which the run is held to as it
  dispatches: the call it decided, its action and its arguments as the
  model wrote them; the account that call names as it resolved then (nil
  for a launch naming none); and the binding the run stands on: the
  turn's sources, no grant revision and no class let flow. It lives in
  the loop from the decision to the dispatch and is stored nowhere: a
  turn continued from its rows decides its steps again.
  """
  @type decided :: %{
          call: %{action: String.t(), args: map()},
          account: account() | nil,
          binding: %{sources: [Prima.Source.t()], consent_id: nil, classes: []}
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
  Run a launch: what `decided` read is what runs, as the turn's person,
  with no class let flow and on whatever grant the root loads. A step
  with no decision runs nothing (`{:refused, :not_approved}`). Answers
  the execution the application started (`execution_id` is nil when the
  answer names none) with the tool's whole result.

  Tells a refusal made before the run's admission could write anything —
  by this dispatcher, by the gate's admission stage
  (`%Prima.Refusal{stage: :admission}`), or by the root's load finding
  the account the launch was held to moved (`:approved_entry_moved`) —
  as `{:refused, reason}`: nothing of the launch ran, and no row was or
  will be written under its id. `{:error, reason}` is any other ending,
  whose run only its row can tell. The loop reads the difference.
  """
  @spec run(Context.t(), Tape.step(), decided() | nil) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}}
          | {:refused, term()}
          | {:error, term()}
  def run(ctx, step, decided \\ nil)

  def run(
        %Context{} = ctx,
        step,
        %{call: _, account: _, binding: %{consent_id: nil, classes: []}} = decided
      ) do
    case decided_launch(ctx, step, decided) do
      {:ok, launcher, args} -> launch(launcher, args)
      {:error, reason} -> {:refused, reason}
    end
  end

  def run(_ctx, _step, _decided), do: {:refused, :not_approved}

  @doc """
  The canonical proposal of a launch of `action` with `args`, which the
  launch is held to. With `account` (`t:account/0`), what a named account
  resolved to: its `connection` spelled as the binding stores the name,
  when the call names that account in any case
  (`Prima.Authority.Blob.same_account_name?/2`), and the entry beside the
  call (`vault_entry`). It also carries what the launch binds of the run
  (`bind/1`; none bound when nil): the turn's sources, the launched
  grant's consent revision and the classes let flow.
  """
  @spec proposal(String.t(), map(), account() | nil, binding() | nil) :: map()
  def proposal(action, args, account, binding) when is_binary(action) and is_map(args) do
    %{"tool" => "execution", "action" => action, "args" => account_args(args, account)}
    |> put_account(account)
    |> Map.merge(bind(binding))
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

  @doc """
  The proposal fields a launch binds `binding` under: the sources as
  canonical JSON (`sources`), the classes it lets flow (`lets_flow`) and
  the grant's consent revision (`consent_id`). The canonical form carries
  no null, so a source's absent name and a revision no grant gave are
  left out. Nil binds no source, no class and no revision.
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
  What a launch's `proposal` bound (`bind/1`). A proposal that bound none
  of it reads as having bound no source, no revision and no class.
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

  # What a launch is held to: the proposal made from the step's own row
  # and what the decision read, run as the turn's person. The row is the
  # last word on what runs: a decision made on another call runs nothing.
  defp decided_launch(ctx, step, %{call: handed, account: account, binding: binding}) do
    with {:ok, %{action: action, args: args} = recorded} <- recorded_call(ctx, step),
         :ok <- decided_on(recorded, handed),
         {:ok, person, turn} <- person(ctx, step) do
      held(person, turn, proposal(action, args, account, binding), step)
    end
  end

  # Its arguments, the turn's sources and the account, each held to what
  # the proposal bound, then the person's context for the one call.
  defp held(caller, turn, proposal, step) do
    shown = bound(proposal)

    with {:ok, args} <- launch_args(proposal),
         {:ok, sources} <- sources_hold(turn, shown),
         :ok <- account_holds(caller, proposal, args) do
      launcher =
        caller
        |> expecting(proposal, args)
        |> launching(sources, shown, step, turn)

      {:ok, launcher, args}
    end
  end

  defp launch(launcher, args) do
    case Aqua.Ops.call_tool("execution", launcher, args) do
      {:ok, result} -> {:ok, %{execution_id: execution_id(result), result: result}}
      {:error, :approved_entry_moved} -> {:refused, stale(args["connection"])}
      {:error, %Prima.Refusal{stage: :admission} = refused} -> {:refused, refused}
      {:error, reason} -> {:error, reason}
    end
  end

  # The call a launch step records: the action the step was recorded for
  # and the arguments its `tool_call` row holds, as the model wrote them.
  # A step recorded for anything but a launch records none.
  defp recorded_call(ctx, %{
         kind: "launch",
         tool: "execution",
         action: action,
         message_id: message_id
       })
       when action in @launch_actions and is_binary(message_id) do
    with {:ok, row} <- Tape.message(ctx, message_id) do
      case Arca.ThreadStorage.payload(row)["arguments"] do
        %{} = args -> {:ok, %{action: action, args: args}}
        _none -> {:ok, %{action: action, args: %{}}}
      end
    end
  end

  defp recorded_call(_ctx, _step), do: {:error, {:invalid_argument, "the step records no launch"}}

  # The call the run was decided on is the step's own, compared as data:
  # the same action, and the same arguments but for an `action` key, which
  # a launch's own action replaces (`launch_args/1`).
  defp decided_on(%{action: action, args: recorded}, %{action: action, args: handed})
       when is_map(handed) do
    if Map.delete(recorded, "action") == Map.delete(handed, "action"),
      do: :ok,
      else: {:error, not_decided()}
  end

  defp decided_on(_recorded, _handed), do: {:error, not_decided()}

  defp not_decided,
    do:
      {:invalid_argument,
       "the call this run was decided on is not the one its step recorded, so nothing ran"}

  # The proposal, as the model wrote it and the decision read it. The
  # assistant itself is never launched, and a wrapped catalyst is a hand,
  # not a launch — both are decided again at this last door, whatever the
  # proposal said.
  defp launch_args(%{"tool" => "execution", "action" => action, "args" => args})
       when action in @launch_actions and is_map(args) do
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
  end

  # The account the proposal bound is the account the launch runs under:
  # the stored name its arguments carry still resolves, as the person, to
  # the entry the proposal bound, under that name as the binding stores
  # it. A launch naming none runs under the default, and bound no entry.
  defp account_holds(caller, proposal, args) do
    stored = args["connection"]

    case {bound_entry(proposal), launch_account(caller, args)} do
      {nil, {:ok, nil}} -> :ok
      {entry_id, {:ok, %{entry_id: entry_id, name: ^stored}}} when is_binary(entry_id) -> :ok
      {_shown, {:error, reason}} when reason != :connection_not_granted -> {:error, reason}
      _another_account_or_none -> {:error, stale(stored)}
    end
  end

  # The turn's sources are the ones the proposal bound: the run is seeded
  # with them, so a source the turn read after the decision is not what
  # was decided. Answers the turn's sources as they stand.
  defp sources_hold(turn, %{sources: shown}) do
    current = Prima.Source.decode(turn.sources)

    if Prima.Source.set(current) == Prima.Source.set(shown),
      do: {:ok, current},
      else: {:error, moved()}
  end

  # The entry the proposal bound, or nil for a launch naming none.
  defp bound_entry(proposal), do: proposal["vault_entry"]

  # The person's context for the one call the launch is dispatched as,
  # carrying the account the proposal bound: the entry and the name its
  # binding stored, which the arguments carry (`account_holds/3` has held
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
  # with (`sources_hold/2` has held them to the proposal's), the classes it
  # lets flow — only ever among those sources' own, and none for a
  # proposal that bound no grant to judge them against — the consent
  # revision the root must load at, the root's id: the step's pre-minted
  # child id, so the loop can read the root's row whatever the launch
  # answers, and the name of the agent whose turn launched it, which the
  # root records as its caller.
  defp launching(caller, sources, %{classes: classes, consent_id: consent_id}, step, turn) do
    held = if is_binary(consent_id), do: Prima.Source.classes_of(sources), else: []

    Sanctum.Context.stamp_launch(caller, %{
      sources: sources,
      classes: Enum.filter(classes, &(&1 in held)),
      consent_id: consent_id,
      execution_id: root_id(step),
      agent: turn.agent
    })
  end

  defp root_id(%{child_execution_id: id}) when is_binary(id), do: id
  defp root_id(_step), do: Prima.UUID7.execution_id()

  # The entry the account an `execution.run` names resolves to on the
  # app's own profile, by the one read of it; none for a launch naming no
  # account, and for a stream, which declares none and is refused naming
  # one by the gate.
  defp launch_account(person, %{"action" => "run", "connection" => name} = args)
       when is_binary(name) do
    Sanctum.Consent.Accounts.resolve(
      person,
      Prima.Authority.RootSelect.decode(args["profile"]),
      args["reference"],
      name
    )
  end

  defp launch_account(_person, _args), do: {:ok, nil}

  # A stale launch is proposed again, deciding it on what stands now.
  defp stale(name) do
    {:conflict,
     account(name) <>
       " is not the one this run was decided on, so nothing ran: propose it again to run " <>
       "it on the account as it stands now"}
  end

  defp account(name) when is_binary(name), do: "The account #{inspect(name)}"
  defp account(_none), do: "The default account"

  # A source the turn read since the decision.
  defp moved,
    do:
      {:conflict,
       "This turn read more since the run was decided, so nothing ran: propose it again to " <>
         "decide it on what the turn has read now."}

  # A launch runs as the turn's person, the one who asked for it
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
