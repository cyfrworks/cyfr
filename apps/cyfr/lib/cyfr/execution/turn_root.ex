# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.TurnRoot do
  @moduledoc """
  The logical root a host loop holds for a turn: an `executions` row of
  kind `turn`, its attempt and reservation, and a `:root` slot on the
  calling process — admitted like a WASM root, without a guest.

  The calling process is the slot holder for the turn's life: it claims
  here, and pauses, resumes or releases from the same pid. It waits on no
  child itself: every child is dispatched from a worker of its own, the
  child's waiter, so a child that is stopped or times out ends that
  worker and never the holder. A pause suspends the keeper, moves the
  turn, its attempt and its root out of `running` in one transaction
  (`Arca.TurnStorage.pause/3`), and only then stops the keeper and gives
  the slot back, so a crash between leaves a paused row and a slot the
  execution slots' monitor releases — never a running row with no holder.
  A pause whose rows did not move resumes the same keeper, so the claim's
  keeper is always the one a later pause or release stops. A resume takes
  the slot first and moves the rows only once it holds one.

  The slot is one of the execution slots (`Cyfr.Slots`, the instance
  `Cyfr.Execution.Slots`), keyed by the athanor. It is taken together with
  the registry entry that lets a cancel find the holder
  (`Cyfr.Execution.Dispatch.stop/2`), and both are given back together.
  """

  alias Cyfr.Execution.{Admission, LeaseWatch, Record}
  alias Cyfr.Slots
  alias Sanctum.Context

  @slots Cyfr.Execution.Slots
  @slot_wait_ms 30_000

  @typedoc """
  What the holder gives back when it lets the root go: its slot, and
  whether this process registered the execution in
  `Cyfr.Execution.Registry` (a process registered already keeps its entry).
  """
  @type token :: %{slot: reference(), registered: boolean(), execution_id: String.t()}

  @type claim :: %{
          execution_id: String.t(),
          attempt: String.t(),
          authority: Cyfr.Authority.t(),
          activation_digest: String.t() | nil,
          lease_until: DateTime.t(),
          budget_id: String.t(),
          token: token(),
          keeper: pid()
        }

  @doc """
  Claim the root for `agent_ref` under the profile `opts[:profile]`
  selects (`:default` when absent): load the authority, admit the row
  with its attempt and reservation, take the `:root` slot on the calling
  process, start the keeper. `opts` also: `:turn_id`, `:thread_id`,
  `:envelope` (the input the row's envelope describes), `:timeout_ms`
  (the slot wait), `:tick_ms` (the keeper's period).
  """
  @spec claim(Context.t(), String.t(), keyword()) :: {:ok, claim()} | {:error, term()}
  def claim(%Context{} = ctx, agent_ref, opts \\ []) do
    with {:ok, %{authority: authority, stamp: stamp}} <-
           Admission.authority_and_stamp_for(
             ctx,
             Keyword.get(opts, :profile, :default),
             agent_ref,
             Keyword.take(opts, [:consent_source, :ceiling, :live_shape_digest])
           ),
         record = build_record(ctx, agent_ref, authority, stamp, opts),
         :ok <- Record.write_started(record),
         {:ok, token} <- claim_slot(ctx, record) do
      {:ok, keeper} =
        LeaseWatch.start(self(), record.id, record.attempt, Keyword.take(opts, [:tick_ms]))

      {:ok,
       %{
         execution_id: record.id,
         attempt: record.attempt,
         authority: authority,
         activation_digest: record.activation_digest,
         lease_until: Record.lease_until(),
         budget_id: authority.budget.id,
         token: token,
         keeper: keeper
       }}
    end
  end

  @doc """
  Pause the turn root from the holder: the keeper is suspended, the turn,
  its attempt and its root leave `running` together, then the keeper
  stops and the slot is released. A move that fails answers its error
  with the claim unchanged: its keeper renews again and its slot is held.
  `opts`: `:claim`, `:turn_id`, `:fence`, `:reason`, `:launch_step_id`,
  `:uncertain`. Answers the paused turn.
  """
  @spec pause(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pause(%Context{} = ctx, _execution_id, opts) do
    claim = Keyword.fetch!(opts, :claim)
    LeaseWatch.suspend(claim.keeper)
    turn_id = Keyword.fetch!(opts, :turn_id)

    moved =
      case Keyword.get(opts, :uncertain) do
        # A call whose outcome is unknown: the step's mark, the covering
        # aborted row and the pause are one transaction.
        %{step_id: _} = uncertain ->
          Arca.TurnStorage.pause_uncertain(
            ctx,
            turn_id,
            Map.put(uncertain, :fence, Keyword.get(opts, :fence))
          )

        nil ->
          with {:ok, turn} <-
                 Arca.TurnStorage.pause(ctx, turn_id, %{
                   fence: Keyword.get(opts, :fence),
                   reason: Keyword.get(opts, :reason, "approval"),
                   launch_step_id: Keyword.get(opts, :launch_step_id)
                 }),
               do: {:ok, %{turn: turn, aborted: nil}}
      end

    case moved do
      {:ok, %{turn: turn, aborted: aborted}} ->
        LeaseWatch.stop(claim.keeper)
        give_back(claim.token)
        {:ok, %{turn: turn, execution_id: turn.root_execution_id, aborted: aborted}}

      {:error, _} = error ->
        # The rows did not move: the turn still runs, and the claim's own
        # keeper renews its lease again.
        LeaseWatch.resume(claim.keeper)
        error
    end
  end

  @doc """
  Resume a paused turn root from the process that will hold it: the slot
  first (a refusal leaves everything paused), then the rows, then a
  keeper. `opts`: `:turn_id`, `:fence`, `:timeout_ms`, `:tick_ms`.
  Answers the claim the loop keeps.
  """
  @spec resume(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume(%Context{} = ctx, execution_id, opts) do
    with {:ok, token} <-
           take_slot(ctx, execution_id, Keyword.get(opts, :timeout_ms, @slot_wait_ms)) do
      until = Record.lease_until()

      case Arca.TurnStorage.resume(ctx, Keyword.fetch!(opts, :turn_id), %{
             fence: Keyword.get(opts, :fence),
             lease_until: until
           }) do
        {:ok, turn} ->
          {:ok, keeper} =
            LeaseWatch.start(
              self(),
              execution_id,
              turn.attempt,
              [until: until] ++ Keyword.take(opts, [:tick_ms])
            )

          {:ok,
           %{
             execution_id: execution_id,
             attempt: turn.attempt,
             lease_until: until,
             token: token,
             keeper: keeper,
             turn: turn
           }}

        {:error, _} = error ->
          give_back(token)
          error
      end
    end
  end

  @doc """
  Adopt a root whose successor attempt a takeover already opened
  (`Arca.TurnStorage.takeover/3`): the slot and a keeper for
  `opts[:attempt]`, nothing else. `opts`: `:attempt`, `:timeout_ms`,
  `:tick_ms`.
  """
  @spec adopt(Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def adopt(%Context{} = ctx, execution_id, opts) do
    attempt = Keyword.fetch!(opts, :attempt)

    with {:ok, token} <-
           take_slot(ctx, execution_id, Keyword.get(opts, :timeout_ms, @slot_wait_ms)) do
      {:ok, keeper} =
        LeaseWatch.start(self(), execution_id, attempt, Keyword.take(opts, [:tick_ms]))

      {:ok,
       %{
         execution_id: execution_id,
         attempt: attempt,
         lease_until: Record.lease_until(),
         token: token,
         keeper: keeper
       }}
    end
  end

  @doc """
  Local cleanup once the turn's terminal write landed
  (`Arca.TurnStorage.finish/4`): the keeper stops and the slot is
  released. `opts`: `:claim`; `:failed` — a sentence — closes a root
  still open as failed first, for a turn that ended before it carried
  its root (a row the turn's own terminal write could not reach).
  """
  @spec release(Context.t(), String.t(), keyword()) :: :ok
  def release(%Context{} = ctx, execution_id, opts) do
    case Keyword.get(opts, :claim) do
      %{keeper: keeper, token: token} = claim ->
        LeaseWatch.stop(keeper)

        case Keyword.get(opts, :failed) do
          error when is_binary(error) -> fail_open_root(ctx, execution_id, claim.attempt, error)
          _ -> :ok
        end

        give_back(token)

      _ ->
        :ok
    end

    :ok
  end

  # A row the turn's terminal write already closed matches nothing here.
  defp fail_open_root(ctx, execution_id, attempt, error) do
    _ =
      Arca.Execution.record_end(
        ctx,
        execution_id,
        "failed",
        %{completed_at: DateTime.utc_now(), duration_ms: 0, error_message: error},
        attempt
      )

    :ok
  end

  defp build_record(ctx, agent_ref, authority, stamp, opts) do
    record =
      Record.new(ctx, agent_ref, Keyword.get(opts, :envelope, %{}),
        component_type: :agent,
        kind: "turn",
        turn_id: Keyword.get(opts, :turn_id),
        profile_id: authority.profile_id,
        reservation: %{budget_id: authority.budget.id, cap: authority.budget.cap},
        retention_class: "chat_step"
      )

    case stamp do
      %{activation_digest: digest, activation_graph: graph} ->
        case Compendium.Activation.encode_graph(graph) do
          {:ok, encoded} -> %{record | activation_digest: digest, activation_graph: encoded}
          {:error, _} -> %{record | activation_digest: digest}
        end

      _ ->
        record
    end
  end

  # A refused slot fails the row it would have held: the claim is over
  # before it began, and the row says so.
  defp claim_slot(ctx, record) do
    case take_slot(ctx, record.id, @slot_wait_ms) do
      {:ok, token} ->
        {:ok, token}

      {:error, sentence} ->
        _ = Record.write_failed(Record.fail(record, sentence))
        {:error, {:slot_refused, sentence}}
    end
  end

  # The `:root` slot on the calling process, waiting at most `wait_ms`,
  # and the registry entry a cancel finds the holder by, taken together;
  # a refusal is the sentence it means to the caller.
  defp take_slot(ctx, execution_id, wait_ms) do
    case Slots.acquire(@slots, ctx.athanor_id, :root, wait_ms: wait_ms) do
      {:ok, ref} ->
        {:ok, %{slot: ref, registered: register(execution_id), execution_id: execution_id}}

      {:error, reason} ->
        {:error, Slots.refusal(reason)}
    end
  end

  # Give the slot back and drop the registration, from the holding process.
  defp give_back(%{slot: ref, registered: registered?, execution_id: execution_id}) do
    Slots.release(@slots, ref)
    if registered?, do: Registry.unregister(Cyfr.Execution.Registry, execution_id)
    :ok
  end

  # Register the holder for cancellation. An existing registration by the
  # same process (a background task that registered before it ran) is kept
  # as that process's, and is not dropped with the slot.
  defp register(execution_id) do
    case Registry.register(Cyfr.Execution.Registry, execution_id, :running) do
      {:ok, _} -> true
      {:error, {:already_registered, _}} -> false
    end
  end
end
