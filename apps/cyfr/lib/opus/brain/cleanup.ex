# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Brain.Cleanup do
  @moduledoc """
  The `brain_cleanup` consumer of `brain_forget` records
  (`Prima.OutboxRecord.brain_forget/1`): the removal of a program's
  native session from its row's kept folder, owed by every transaction
  that cleared or deleted a thread's `brain_session` a program may have
  held (`Arca.ThreadStorage`).

  It works an athanor's pending records under its job claim
  (`Arca.JobClaims`, kind `brain_cleanup`, keyed by the athanor id), so of
  the members that hear of the same work exactly one does it. It drains
  when it is told the athanor owes removals (`wake/1`, after a forgetting
  transaction commits), at boot, and on a tick, which is how a record
  owed while the box was away is tried again once it answers. Each record
  is sent to the holder's cleanup path (`Opus.Brain.forget/1`), which
  reads it again from the store and asks the row's driver to forget that
  one session; the receipt (`Arca.ConsumerReceipts`) is written after the
  answer, under the claim and this member's slot:

    * `applied` — the driver answered `forgot`: the session's transcript
      is gone from the folder, or was proved absent. A forget repeated
      after a receipt that did not land answers the same, so a try that
      dies before its receipt is safe to try again. It speaks for the
      harness's configuration directory as the row's environment names
      it now: a row whose environment moved that directory
      (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) moved where its sessions'
      records are kept and where a forget looks, and records under the
      directory it named before stay until the folder is reset or the row
      is removed, a stated limit.
    * `superseded` — the thread holds that session again under a later
      generation, a successor's, which is never removed; or the row is
      gone, and the removal passes to the retirement of the row's whole
      home: the receipt says the reconciler owns it now
      (`Opus.Programs.home/3` on the row's deletion, and the sweep of kept
      homes no row keeps, `Emissary.External.Reconciler.sweep_homes/0`,
      for a deletion whose word was lost), not that the bytes are gone.

  Anything else leaves the record owed, tried again at the next drain:
  the driver's `refused` (a folder it could not inspect, or the session
  running there), a box that is away or does not answer, a lost answer, a
  row disabled, a row whose command names no driver (one that still runs
  the bare harness, which nothing answers the wire in, so nothing is
  opened until the row names a driver again), and a holder running under
  the thread's key that is a successor's or runs on another row, until it
  ends. It never removes a session the record does not
  name, and no folder is ever reset here; a whole-home reset stays the
  person's own operation. A record left owed costs each tick of its
  athanor the outbox's reads, the claim taken, renewed and given up, and
  the record's own reads (the record, its row; the thread too once the
  row names a driver), and nothing of the box's.

  `:brain_cleanup_enabled` false leaves it unstarted: under the test
  sandbox a drain on a tick would work another test's records on the
  connection that test lent, so the suite turns it off and the tests that
  need a consumer call `drain/2`.
  """

  use GenServer

  require Logger
  require Prima.TestSeam

  alias Arca.{ConsumerReceipts, JobClaims}

  @consumer "brain_cleanup"
  @kind "brain_forget"
  # A claim outlives one record's removal, a driver's open and answer
  # included, and is renewed after each.
  @lease_ms 180_000
  @tick_ms 30_000

  @doc "The consumer's name, as its receipts and its claim name it."
  @spec consumer() :: String.t()
  def consumer, do: @consumer

  @doc false
  def start_link(opts \\ []) do
    if Prima.TestSeam.value(true, fn ->
         Application.get_env(:cyfr, :brain_cleanup_enabled, true)
       end) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "The athanor owes removals: drain it now. Nothing when the consumer does not run."
  @spec wake(String.t()) :: :ok
  def wake(athanor_id) when is_binary(athanor_id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:wake, athanor_id})
    end
  end

  @impl true
  def init(opts) do
    send(self(), :drain_all)
    {:ok, %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}}
  end

  @impl true
  def handle_cast({:wake, athanor_id}, state) do
    _ = drain(athanor_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:drain_all, state) do
    _ = drain_all()
    Process.send_after(self(), :drain_all, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc "Drain every athanor that owes a removal. Never raises."
  @spec drain_all() :: %{String.t() => term()}
  def drain_all do
    case Arca.Outbox.pending_athanors(@consumer, @kind) do
      {:ok, athanors} ->
        Map.new(athanors, &{&1, drain(&1)})

      {:error, reason} ->
        Logger.warning("[Brain.Cleanup] pending records not read: #{inspect(reason)}")
        %{}
    end
  catch
    # A tick has no caller to answer to: a read that raises must not take
    # the consumer down, since one restarted ticks again at once.
    kind, reason ->
      Logger.warning(
        "[Brain.Cleanup] pending records not read: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      %{}
  end

  @doc """
  Work `athanor_id`'s pending records under the consumer's claim on it,
  oldest first. Answers the count of each receipt outcome written and of
  the records left `owed`; `:busy` when another holder has the claim;
  `{:stopped, reason}` when the claim or the slot was lost, after the
  outcomes before it. The claim is given up when the drain ends. Never
  raises.

  `opts`: `:owner`, the claim's owner, this boot by default.
  """
  @spec drain(String.t(), keyword()) ::
          {:ok, %{String.t() => non_neg_integer()}}
          | :busy
          | {:stopped, term()}
          | {:error, term()}
  def drain(athanor_id, opts \\ []) when is_binary(athanor_id) and athanor_id != "" do
    owner = Keyword.get(opts, :owner, Prima.Boot.id())
    actor = Prima.Actor.in_athanor(athanor_id)

    with {:ok, [_ | _]} <- Arca.Outbox.pending(actor, @consumer, @kind),
         {:ok, claim} <- JobClaims.claim(@consumer, athanor_id, owner, @lease_ms) do
      under_claim(actor, claim)
    else
      {:ok, []} -> {:ok, %{}}
      {:busy, _claim} -> :busy
      {:error, _} = refused -> refused
    end
  catch
    kind, reason ->
      Logger.warning(
        "[Brain.Cleanup] the removals of #{athanor_id} were not drained: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      {:error, :crashed}
  end

  # The newest claim is given up at the end, whatever the drain did.
  defp under_claim(actor, claim) do
    {answer, last} =
      try do
        worked(actor, claim)
      catch
        kind, reason ->
          _ = JobClaims.release(claim)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    _ = JobClaims.release(last)
    answer
  end

  defp worked(actor, claim) do
    case Arca.Outbox.pending(actor, @consumer, @kind) do
      {:ok, records} ->
        Enum.reduce_while(records, {{:ok, %{}}, claim}, fn record, {{:ok, counts}, claim} ->
          case work(actor, record, claim) do
            {:ok, outcome} ->
              counts = Map.update(counts, outcome, 1, &(&1 + 1))

              case JobClaims.renew(claim, @lease_ms) do
                {:ok, renewed} -> {:cont, {{:ok, counts}, renewed}}
                lost -> {:halt, {{:stopped, lost}, claim}}
              end

            {:stop, reason} ->
              {:halt, {{:stopped, reason}, claim}}
          end
        end)

      {:error, _} = refused ->
        {refused, claim}
    end
  end

  # `{:ok, outcome}`: a receipt's outcome once it is written, or `"owed"`
  # for a record left for the next drain; `{:stop, reason}` when the
  # receipt could not be written under the claim and the slot.
  defp work(actor, record, claim) do
    case Opus.Brain.forget(record) do
      :forgot -> receipted(actor, record, claim, "applied")
      {:error, :successor} -> receipted(actor, record, claim, "superseded")
      # The row's home goes whole, and its retirement is the reconciler's,
      # found again by its sweep when the deletion's word was lost: this
      # receipt hands the removal on, it does not prove the bytes gone.
      {:error, :row_gone} -> receipted(actor, record, claim, "superseded")
      {:error, _not_now} -> {:ok, "owed"}
    end
  end

  defp receipted(actor, record, claim, outcome) do
    receipt =
      record
      |> Prima.OutboxRecord.source()
      |> Map.merge(%{consumer: @consumer, outcome: outcome})

    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         :ok <- ConsumerReceipts.record(actor, claim, slot, receipt) do
      {:ok, outcome}
    else
      {:error, :receipted} -> {:ok, outcome}
      lost when lost in [:taken, :lapsed] -> {:stop, lost}
      {:error, reason} -> {:stop, reason}
    end
  end
end
