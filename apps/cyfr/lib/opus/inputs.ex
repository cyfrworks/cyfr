# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Inputs do
  @moduledoc """
  The invocation-scoped port by which whoever starts an invocation hands
  it further input while it runs (ARCHITECTURE.md §4.2): for a model call,
  the messages that arrive after the call began, which its catalyst writes
  into its harness's running session (`Prima.Model`, `cyfr:model/inputs`).

  The caller of `Opus.run_child/5` names a supplier, a process, with
  `:inputs`, for that one invocation; Opus holds it with the invocation's
  attempt and names nothing above it. Only the invocation's own runner,
  under its verified host-call header and its live attempt, reaches the
  supplier (`Opus.Host.Inputs`), and the supplier hears the invocation's
  trusted identity (`t:invocation/0`) with every ask, never anything the
  guest chose but the id it reports.

  ## The supplier's messages

    * `{Opus.Inputs, :next, invocation, reply_to}`: answer
      `reply(reply_to, {:ok, input})` with the invocation's next input not
      yet reported sent (`t:Prima.Model.input/0`, string keys, as the wire
      carries it), or `reply(reply_to, :none)`.
    * `{Opus.Inputs, :sent, invocation, id, reply_to}`: record that the
      invocation handed the input `id` on, then `reply(reply_to, :ok)`;
      or refuse it, `reply(reply_to, {:error, reason})`, recording
      nothing.

  Each is answered within `answer_ms/0`. `:none` is the only answer that
  reads as no input; one answered later, one that is none of these, or
  a supplier that is gone, is no answer, and the runner is told
  `unavailable`, for `next` as for `sent`. A supplier's input is held to
  `Prima.Model.check_input/1` before the runner is handed it.

  ## The supplier's contract

    * `next` never dequeues or moves past an unreported input: a repeated
      read answers the same identity and content until it is reported, so
      a read whose answer was lost is read again.
    * `sent` marks, idempotently, only an input that was offered to that
      same invocation, and only while the invocation still holds its
      attempt, checked with `held!/1` inside the transaction that commits
      the mark, so a stored mark cannot commit past a cancel that
      committed first. The port's own tests hold the check with a supplier
      that keeps its marks in memory, which proves no stored mark's race
      with a cancel: a supplier that stores its marks proves that itself.
      A replacement attempt may be offered an earlier unreported input,
      whose bytes the old attempt may already have handed on, so it can
      arrive and be acted on twice; the old attempt can never acknowledge
      the replacement's delivery, since its calls are `lost`.
    * Attachments are the supplier's to resolve: it joins their sources to
      the invocation's run, and checks their removal and authority, before
      it returns their bytes. Nothing an input carries is a path or an
      address for anyone to fetch.

  An input handed over cannot be recalled: once `next` has answered it to
  the runner, its bytes may reach the harness whatever happens after,
  a cancel included. What an input carries is never logged, never in a
  diagnostic, and never in the attempt's status; a refusal names at most
  the member that broke it.
  """

  @answer_ms 5_000

  @typedoc """
  The trusted identity of an invocation, from its attempt: its athanor,
  execution, attempt and fence, and the grant it was admitted under, which
  `held!/1` checks.
  """
  @type invocation :: %{
          athanor_id: String.t(),
          execution_id: String.t(),
          attempt: String.t(),
          fence: pos_integer(),
          grant: Prima.ExecutionGrant.t()
        }

  @typedoc "Where a supplier's answer goes (`reply/2`): one answer, once."
  @opaque reply_to :: reference()

  @doc "How long Opus waits for a supplier's answer, in milliseconds: #{@answer_ms}."
  @spec answer_ms() :: pos_integer()
  def answer_ms, do: @answer_ms

  @doc "Answer an ask the supplier was sent. An answer that comes too late is dropped."
  @spec reply(reply_to(), {:ok, Prima.Model.input()} | :none | :ok | {:error, term()}) :: :ok
  def reply(reply_to, answer) when is_reference(reply_to) do
    send(reply_to, {reply_to, answer})
    :ok
  end

  @doc """
  Whether the invocation still holds its attempt: its grant stands, and
  the attempt is running and current for its running execution. Called
  inside the supplier's own locking transaction, it takes the attempt
  row's lock as a child's admission holds its parent's
  (`Arca.ExecutionAttempts.hold_for_child!/4`), so a close, cancel, lapse
  or takeover of the attempt either committed first and this answers
  false, or waits for the supplier's transaction to commit. A mark it
  answers false for is rolled back by the supplier.
  """
  @spec held!(invocation()) :: boolean()
  def held!(%{athanor_id: athanor_id, execution_id: execution_id, attempt: attempt, grant: grant})
      when is_binary(athanor_id) and is_binary(execution_id) and is_binary(attempt) do
    Sanctum.ExecutionStanding.verify(grant) == :ok and
      Arca.ExecutionAttempts.hold_for_child!(
        Prima.Actor.in_athanor(athanor_id),
        execution_id,
        attempt,
        grant
      ) == 1
  end

  @doc false
  # Ask `supplier` for the invocation's next input: what it answered, or
  # `:none` when it is gone or silent (`Opus.Host.Inputs` reads that, and
  # an answer that is none of the port's, as `unavailable`).
  @spec next(pid(), invocation()) :: {:ok, term()} | :none
  def next(supplier, invocation) when is_pid(supplier),
    do: ask(supplier, &{__MODULE__, :next, invocation, &1})

  @doc false
  # Tell `supplier` the invocation handed `id` on: what it answered, or
  # `:none` when it is gone or silent.
  @spec sent(pid(), invocation(), String.t()) :: {:ok, term()} | :none
  def sent(supplier, invocation, id) when is_pid(supplier) and is_binary(id),
    do: ask(supplier, &{__MODULE__, :sent, invocation, id, &1})

  # The answer goes to an alias that takes one message and is dropped once
  # the wait ends, so an answer that comes too late reaches no one and is
  # never read as a later ask's.
  defp ask(supplier, message) do
    monitor = Process.monitor(supplier)
    reply_to = Process.alias([:reply])
    send(supplier, message.(reply_to))

    receive do
      {^reply_to, answer} ->
        Process.demonitor(monitor, [:flush])
        {:ok, answer}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        Process.unalias(reply_to)
        :none
    after
      @answer_ms ->
        Process.unalias(reply_to)
        Process.demonitor(monitor, [:flush])

        receive do
          {^reply_to, _late} -> :none
        after
          0 -> :none
        end
    end
  end
end
