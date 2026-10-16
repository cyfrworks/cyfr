# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Launch do
  @moduledoc """
  The one dispatcher of an approved launch. A `launch` step — an
  `execution.run` of something that is neither a hand nor an agent,
  approved by a member — becomes an external-plane `execution.run` as
  that member: the application roots its own consent, and the turn's
  pinned authority is never widened into it.

  The input is the durable step alone. The approver's context is rebuilt
  from the approval's `decided_by` (`Sanctum.Tenancy.continuation/3`), so
  a launch consumed after a restart runs as the person who decided it, or
  not at all: a person no longer seated refuses it. It carries the origin
  stored on the approved turn's row, never one inferred from the person
  approving: a programmatic turn's launch stays `programmatic`, and a
  turn whose row stores no origin launches nothing
  (`{:approver_unavailable, :no_origin}`). The loop marks the step
  dispatched before calling here, which is what makes a launch happen
  once.

  A launch naming an account (`connection`) runs under the account its
  card showed, or not at all. The card's proposal binds the account as
  its binding stored the name, and the entry it resolved to when the card
  was drawn (`vault_entry`); before anything runs the name is resolved
  again, as the approver, from the app's stored head
  (`Sanctum.Consent.Accounts.resolve/4`, the one read the assistant's
  policy resolves it by), and a different entry, a name the head no
  longer binds or now stores otherwise, or an account the card did not
  show is refused as a stale approval, a conflict that says to ask again.
  That check is the early refusal, not the guarantee. The run is asked
  for under the stored name and picks the named binding as its root's
  vault (`Opus.run_root/5`), and the account the card showed, its
  entry and its stored name, rides that one call on the approver's
  context (`Sanctum.Context`'s `approved_entry`): the root is admitted
  only on a binding that names that entry under that name, judged on the
  same read of the head that picks the binding (`Opus.Admission`). A
  head that moves after the check here, binding the name to another
  entry, storing it otherwise or dropping it, refuses there,
  `:approved_entry_moved`, before anything starts, and reads as the same
  stale approval.

  The card's proposal also binds what the launch carries (`bind/1`, as
  the assistant's policy draws it): the turn's sources, the
  consent revision of the grant the app roots at, and the classes the
  person lets flow to every exit of that grant's tree. Before anything
  runs the turn's sources are read again, and any the turn read since
  the card refuse the launch as stale (`:approved_sources_moved`'s
  sentence); the grant is loaded again as the approver, and another
  revision refuses it as stale (`:approved_grant_moved`'s). Then what
  the card bound rides the one call on the approver's context
  (`Sanctum.Context`'s `launch`): the root is admitted only at that
  revision, seeded with those sources, with those classes in its
  policy, under the step's pre-minted id (`Opus.Admission`), and a grant
  that moves after the check here refuses there as the same stale
  approval. A card drawn when no grant could be loaded bound none and
  lets nothing flow, so whatever grant the root loads decides its sends
  alone. The run's root never takes a seed, a class or an id from
  anything a caller sends.
  """

  alias Aqua.Tape
  alias Sanctum.Context

  @launch_actions ~w(run run_stream)

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

  @doc """
  Run the launch the step was approved for, as its approver (`run/2`).
  Answers the execution the application started (`execution_id` is nil
  when the answer names none) with the tool's whole result, or the
  refusal.
  """
  @spec dispatch(Context.t(), Tape.step()) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}} | {:error, term()}
  def dispatch(%Context{} = ctx, step) do
    case run(ctx, step) do
      {:refused, reason} -> {:error, reason}
      answered -> answered
    end
  end

  @doc """
  `dispatch/2`, telling a refusal made before the run's admission could
  write anything — by this dispatcher, by the gate's admission stage
  (`%Prima.Refusal{stage: :admission}`), or by the root's load finding
  the account or the grant the card showed moved
  (`:approved_entry_moved`, `:approved_grant_moved`) — as
  `{:refused, reason}`: nothing of the launch ran, and no row was or
  will be written under its id. `{:error, reason}` is any other ending,
  whose run only its row can tell. The loop reads the difference.
  """
  @spec run(Context.t(), Tape.step()) ::
          {:ok, %{execution_id: String.t() | nil, result: map()}}
          | {:refused, term()}
          | {:error, term()}
  def run(%Context{} = ctx, %{approval_id: approval_id} = step) when is_binary(approval_id) do
    case launchable(ctx, step, approval_id) do
      {:ok, launcher, args} -> launch(launcher, args)
      {:error, reason} -> {:refused, reason}
    end
  end

  def run(_ctx, _step), do: {:refused, :not_approved}

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

  # Everything the launch is held to before it is asked for, read as it
  # stands now, and the approver's context the one call is made under.
  defp launchable(ctx, step, approval_id) do
    with {:ok, approval} <- Tape.approval(ctx, approval_id),
         :ok <- approved_launch(approval),
         {:ok, card} <- Tape.message(ctx, approval.message_id),
         :ok <- card_approved(approval, card),
         {:ok, args} <- launch_args(card),
         {:ok, approver, turn} <- approver(ctx, approval),
         shown = bound(proposal_of(card)),
         {:ok, sources} <- sources_hold(turn, shown),
         :ok <- account_holds(approver, card, args),
         :ok <- grant_holds(approver, shown, args) do
      launcher =
        approver
        |> expecting(card, args)
        |> launching(sources, shown, step)

      {:ok, launcher, args}
    end
  end

  defp launch(launcher, args) do
    case Aqua.Ops.call_tool("execution", launcher, args) do
      {:ok, result} -> {:ok, %{execution_id: execution_id(result), result: result}}
      {:error, :approved_entry_moved} -> {:refused, stale(args["connection"])}
      {:error, :approved_grant_moved} -> {:refused, moved(:approved_grant_moved)}
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

  # The proposal the card carried, as the model wrote it and the person
  # saw it. The assistant itself is never launched, and a wrapped
  # catalyst is a hand, not a launch — both are decided again at this
  # last door, whatever the card said.
  defp launch_args(card) do
    case get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal"]) do
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

  # The account the card showed is the account the launch runs under: the
  # stored name its arguments carry still resolves, as the approver, to the
  # entry its proposal bound, under that name as the binding stores it. A
  # launch naming none runs under the default, and its card bound no entry.
  defp account_holds(approver, card, args) do
    stored = args["connection"]

    case {bound_entry(card), launch_account(approver, args)} do
      {nil, {:ok, nil}} -> :ok
      {entry_id, {:ok, %{entry_id: entry_id, name: ^stored}}} when is_binary(entry_id) -> :ok
      {_shown, {:error, reason}} when reason != :connection_not_granted -> {:error, reason}
      _another_account_or_none -> {:error, stale(stored)}
    end
  end

  # The turn's sources are the ones the card's proposal bound: the run is
  # seeded with them and the classes it lets flow were judged over them,
  # so a source the turn read after the card is not what was approved.
  # Answers the turn's sources as they stand.
  defp sources_hold(turn, %{sources: shown}) do
    current = Prima.Source.decode(turn.sources)

    if Prima.Source.set(current) == Prima.Source.set(shown),
      do: {:ok, current},
      else: {:error, moved(:approved_sources_moved)}
  end

  # The grant the app roots at is still the consent revision the card
  # showed, read again as the approver before anything runs: the classes
  # the card lets flow were judged against that grant's exits. A grant
  # gone, or another revision, is a stale approval; one that cannot be
  # read now is that refusal. This is the early refusal, not the
  # guarantee: the run's root is admitted only at the revision the card
  # showed (`Opus.Admission`), on the same read of the head that picks
  # it. A card that bound no revision let nothing flow (`launching/4`),
  # and holds whatever grant loads.
  defp grant_holds(_approver, %{consent_id: nil}, _args), do: :ok

  defp grant_holds(approver, %{consent_id: shown}, args) do
    case authority(approver, args["reference"], args["action"], args) do
      {:ok, %{consent_id: ^shown}} -> :ok
      {:error, reason} when reason != :no_profile -> {:error, reason}
      _another_grant_or_none -> {:error, moved(:approved_grant_moved)}
    end
  end

  # The entry the card's proposal bound, or nil for a launch naming none.
  defp bound_entry(card),
    do: get_in(Arca.ThreadStorage.payload(card), ["intent", "proposal", "vault_entry"])

  # The approver's context for the one call the launch is dispatched as,
  # carrying the account the card showed: the entry it bound and the name
  # its binding stored, which the arguments carry (`account_holds/3` has
  # held the two together). The run's root is admitted on that binding or
  # not at all. A card that bound no entry sets nothing.
  defp expecting(approver, card, args) do
    case {bound_entry(card), args["connection"]} do
      {entry_id, name} when is_binary(entry_id) and is_binary(name) ->
        %{approver | approved_entry: %{entry: entry_id, name: name}}

      _none ->
        approver
    end
  end

  # The approver's context also carries what the card bound for the run's
  # root (`Sanctum.Context.stamp_launch/2`, called here alone), never from
  # anything a caller sends: the turn's sources the root is seeded with
  # (`sources_hold/2` has held them to the card's), the classes the card
  # lets flow — only ever among those sources' own, and none for a card
  # that bound no grant to judge them against — the consent revision the
  # root must load at, and the root's id: the step's pre-minted child id,
  # so the loop can read the root's row whatever the launch answers.
  defp launching(approver, sources, %{classes: classes, consent_id: consent_id}, step) do
    held = if is_binary(consent_id), do: Prima.Source.classes_of(sources), else: []

    Sanctum.Context.stamp_launch(approver, %{
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

  defp stale(name) do
    account = if is_binary(name), do: "The account #{inspect(name)}", else: "The default account"

    {:conflict,
     account <>
       " is not the one this launch was approved for, so nothing ran: ask again to " <>
       "approve the account as it stands now"}
  end

  # A stale approval in the refusal table's own sentence for it.
  defp moved(reason), do: {:conflict, Prima.Refusal.message(reason)}

  # The approver continues the turn the approval was opened in, under the
  # origin that turn's row stores; the turn is answered as read.
  defp approver(%Context{} = ctx, %{decided_by: user_id, turn_id: turn_id})
       when is_binary(user_id) and is_binary(turn_id) do
    with {:ok, turn} <- Tape.turn(ctx, turn_id) do
      case Sanctum.Tenancy.continuation(user_id, Context.athanor!(ctx), turn.origin) do
        {:ok, approver} -> {:ok, approver, turn}
        {:error, reason} -> {:error, {:approver_unavailable, reason}}
      end
    end
  end

  defp approver(_ctx, _approval), do: {:error, {:approver_unavailable, :denied}}

  defp execution_id(%{execution_id: id}) when is_binary(id), do: id
  defp execution_id(%{"execution_id" => id}) when is_binary(id), do: id
  defp execution_id(_result), do: nil
end
