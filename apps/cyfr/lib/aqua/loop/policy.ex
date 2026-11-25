# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Policy do
  @moduledoc """
  What a resolved call may do: run, or be refused with a sentence — and
  whether it may run beside others.

  A call is decided in this order, and nothing is ever asked:

    1. **Shown, not run.** The `ui` event and `request_setup.open` run:
       they only show the person something.
    2. **Not offered.** A call whose key the turn's offered set
       (`Aqua.Offered`) does not hold is refused; a browser action the
       person's browser setting turned off is refused in the browser's
       own words. A launch is offered by `execution.run` or
       `execution.run_stream`, an outside server's tool by its
       `server:tool`.
    3. **Run.** Every offered call runs. A crew member's access is its
       harness's own setting (`Opus.Brain`), never a step here.

  A launch is refused when its reference names no component, and a
  launch naming an account (`connection`) has it
  resolved first (`launch_account/2`), as account names compare: the
  entry the launched app's own profile binds under that name, and the
  name as the binding stores it. A name the profile does not bind ends
  the call as setup required. A launch that runs is decided `{:run,
  decided}`: the call and its account, which `Aqua.Launch` holds the run
  to as it dispatches (`t:Aqua.Launch.decided/0`).
  It pins no grant: the grant the app roots at when it runs decides its
  sends, and a component with none is answered `consent_required` by the
  gate.

  `answer_of/1` says what a call's answer is to the model that asked:
  a scroll, CYFR's own words, or outside data, which the loop frames its
  result row by (`Aqua.Reader`).

  `threads_of/3` names the threads whose posts a call's result carries
  into its turn: a catalog action's as its operation declares them
  (`Prima.Operation.read_threads/3`), and a hand's child's read threads,
  as its completion result carries them (`child_threads/1`).
  """

  alias Aqua.Loop.Binding.Call
  alias Prima.Authority.RootSelect

  @typedoc """
  A launch's account as its decision binds it: the entry the name
  resolved to and the name as its binding stores it (`launch_account/2`).
  """
  @type account :: %{vault_entry: String.t(), name: String.t()}

  @typedoc """
  What a call does: run, a launch with what its decision read; be denied
  or refused, with a sentence; or, for a launch naming an account its app's profile does not bind, end the turn
  as setup required, naming the app, its credential need (nil: the one
  need, or one no binding tells) and the account.
  """
  @type decision ::
          :run
          | {:run, Aqua.Launch.decided()}
          | {:deny, String.t()}
          | {:refuse, String.t()}
          | {:setup_required, String.t(), {String.t() | nil, String.t()}}

  @doc """
  The decision for `call` among the `offered` set. A restricted turn's
  calls reach here only when replay-safe (`Aqua.Loop` denies the rest
  first). Every member is offered the same set on every job.
  `opts`: `:host_start` (true for the turn's own start of its program
  brain, which is no call of its job), `:title` (the member's title, which
  a refusal names) and `:ctx` (the member's context a launch's account is
  resolved under). Without a context a launch naming an account is
  refused.
  """
  @spec decide(Call.t(), Aqua.Offered.t(), keyword()) :: decision()
  def decide(%Call{} = call, offered, opts) when is_map(offered) do
    cond do
      call.kind == :ui -> :run
      Keyword.get(opts, :host_start) == true -> :run
      true -> decide_offered(call, offered, opts)
    end
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

  @doc """
  Whether `call` waits as long as it takes (`waits: true` on its action,
  read from the operation's one definition): a catalog call so declared;
  nothing else. A post answers such a call early (`Aqua.Loop`).
  """
  @spec waits?(Call.t()) :: boolean()
  def waits?(%Call{kind: :catalog, tool: tool, action: action}),
    do: Aqua.Ops.waits?(tool, action)

  def waits?(%Call{}), do: false

  @doc """
  The one call a note flush before a summary may make, `notes.keep`, by
  its tool and action: the flush's request offers it alone, and an ask of
  a flush's step runs only if it is this one (`Aqua.Loop`).
  """
  @spec flush_call() :: {String.t(), String.t()}
  def flush_call, do: {"notes", "keep"}

  defp decide_offered(%Call{} = call, offered, opts) do
    case Map.get(offered, offered_key(call)) do
      "offered" -> offered(call, opts)
      "off" -> {:deny, Aqua.Providers.Browser.turned_off()}
      nil -> {:deny, "#{name(call)} is not among the tools #{title(opts)} is offered"}
    end
  end

  # A launch is refused when it names no component.
  defp offered(%Call{kind: :launch, target: reference} = call, opts) do
    if component_ref?(reference),
      do: launch(call, opts),
      else: {:refuse, "#{inspect(reference)} is not a component reference"}
  end

  defp offered(%Call{}, _opts), do: :run

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
  What a model or hand child's answer says of its read threads:
  `{:carried, threads}` for a completion result carrying those its
  terminal write left (`Opus.Close.complete/3`); `:nothing_ran` for a
  refusal the gate made at admission, before any attempt existed
  (`%Prima.Refusal{stage: :admission}`); `:unknown` for anything else —
  a failure, a death, an answer of another shape — whose read threads
  only the child's row can tell. Row absence never says nothing ran:
  retention may prune a terminal child before its step closes.
  """
  @spec child_threads(term()) :: {:carried, [String.t()]} | :nothing_ran | :unknown
  def child_threads({:ok, %{read_threads: threads}}) when is_list(threads) do
    if Enum.all?(threads, &(is_binary(&1) and &1 != "")),
      do: {:carried, threads},
      else: :unknown
  end

  def child_threads({:error, %Prima.Refusal{stage: :admission}}), do: :nothing_ran
  def child_threads(_answer), do: :unknown

  # The families whose answers are CYFR's own words: its records of the
  # athanor's agents, notes, crew, threads, schedules, layout, shares and
  # system. Every other family is outside until it is named here.
  @own_families ~w(aqua notes crew thread threads workspace schedule layout share system)

  @doc """
  What `call`'s answer is: `:scroll` for a scroll read by name
  (`aqua.skill_get`); `:own` for a family whose answers are CYFR's own
  words, and the `ui` and `request_setup` calls; `:outside` for every
  other, an outside server's tool, a launch and a family not named among
  them, whose answer is what an outside source returned.
  """
  @spec answer_of(Call.t()) :: :scroll | :own | :outside
  def answer_of(%Call{kind: kind}) when kind in [:external, :launch], do: :outside
  def answer_of(%Call{kind: :ui}), do: :own
  def answer_of(%Call{tool: "aqua", action: "skill_get"}), do: :scroll
  def answer_of(%Call{tool: tool}) when tool in @own_families, do: :own
  def answer_of(%Call{}), do: :outside

  @doc """
  The threads whose posts `call`'s `result` carries into its turn, read
  under `ctx`, the context the call was dispatched under. A catalog
  action's are its operation's `threads:` declaration's, read from the
  caller's actor and the answer (`Prima.Operation.read_threads/3`). A
  hand carries its child's read threads, as its completion result
  carries them (`child_threads/1`; a hand's failure names none, and the
  loop reads its child's row). Any other call carries none here: a
  launched component's join where its step closes.
  """
  @spec threads_of(Call.t(), term(), Sanctum.Context.t()) :: [String.t()]
  def threads_of(%Call{kind: :hand}, result, _ctx) do
    case child_threads(result) do
      {:carried, threads} -> threads
      _not_carried -> []
    end
  end

  def threads_of(
        %Call{kind: :catalog, tool: tool, action: action},
        result,
        %Sanctum.Context{} = ctx
      ),
      do:
        Prima.Operation.read_threads(operation(tool, action), Sanctum.Context.actor(ctx), result)

  def threads_of(%Call{}, _result, _ctx), do: []

  # The catalogued operation a catalog call names, nil when none declares
  # it, read from the operation table as a chain's tool call reads it
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
end
