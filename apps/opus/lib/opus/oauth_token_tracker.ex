# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthTokenTracker do
  @moduledoc """
  Owns the ETS table of OAuth access tokens dispensed to WASM guests during
  execution, so `Cyfr.SecretMasker` can redact them from stored output.

  The table is `:private` and owned by this supervised process — plaintext
  access tokens are never held in a `:public` table readable by any process on
  the node; every read and write is mediated by this process. Writes go through
  a synchronous `call`: the dispensing host-function closure is already blocked
  awaiting its return value, so the call is free, and it gives an ordering a
  `cast` could not — a token dispensed microseconds before an execution
  finalizes cannot arrive after the drain and leak.

  A periodic sweep drops tokens for executions that never reached one of the
  drain sites (finalize / timeout / failure), bounding residency for a crashed
  or abandoned run.
  """

  use GenServer

  require Logger

  @table :opus_oauth_dispensed_tokens
  # Longer than any execution can run (the platform ceiling timeout is 30m); a
  # row still present after this is from a run that never drained.
  @ttl_ms :timer.hours(1)
  @sweep_interval_ms :timer.minutes(5)
  # Headroom above the execution ceiling before a row may be swept: the
  # finalize/failure drain sites run after the wall clock stops.
  @drain_margin_ms :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record a dispensed token for later masking. Synchronous so a last-instant
  dispense cannot race the drain.

  Fails CLOSED: an unreachable tracker answers `{:error, :untracked}` and
  the caller must not hand the token out — an untracked token can never be
  masked from output, events or audit rows afterwards.
  """
  @spec put(String.t(), String.t()) :: :ok | {:error, :untracked}
  def put(execution_id, token) when is_binary(execution_id) and is_binary(token) do
    GenServer.call(__MODULE__, {:put, execution_id, token})
  catch
    :exit, reason ->
      Logger.warning(
        "[OAuthTokenTracker] put unreachable (#{inspect(reason)}) — refusing the dispense"
      )

      {:error, :untracked}
  end

  @doc """
  Collect and delete all dispensed tokens for an execution. Returns the token
  strings for `Cyfr.SecretMasker`. Safe to call multiple times (second call
  returns `[]`).
  """
  @spec collect(String.t() | nil) :: [String.t()]
  def collect(nil), do: []

  def collect(execution_id) when is_binary(execution_id) do
    GenServer.call(__MODULE__, {:collect, execution_id})
  catch
    :exit, reason ->
      # Nothing to recover — the table died with the tracker — but the
      # masking skip must be visible, not silent.
      Logger.warning(
        "[OAuthTokenTracker] collect unreachable (#{inspect(reason)}) — " <>
          "dispensed tokens for #{execution_id} cannot be masked"
      )

      []
  end

  @doc """
  The tokens dispensed to an execution so far, left in place for the
  drain. An unreachable tracker answers `[]`, logged.
  """
  @spec peek(String.t() | nil) :: [String.t()]
  def peek(nil), do: []

  def peek(execution_id) when is_binary(execution_id) do
    GenServer.call(__MODULE__, {:peek, execution_id})
  catch
    :exit, reason ->
      Logger.warning(
        "[OAuthTokenTracker] peek unreachable (#{inspect(reason)}) — " <>
          "dispensed tokens for #{execution_id} cannot be masked"
      )

      []
  end

  @doc "Run one sweep synchronously and return the count deleted (test seam)."
  @spec sweep_now() :: non_neg_integer()
  def sweep_now, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(_opts) do
    # Guard the create so a supervisor restart (which would otherwise find the
    # named table already owned) does not crash init.
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :private, :bag])
      _ref -> @table
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, execution_id, token}, _from, state) do
    :ets.insert(@table, {execution_id, token, now_ms()})
    {:reply, :ok, state}
  end

  def handle_call({:peek, execution_id}, _from, state) do
    {:reply, @table |> :ets.lookup(execution_id) |> Enum.map(&elem(&1, 1)), state}
  end

  def handle_call({:collect, execution_id}, _from, state) do
    tokens = @table |> :ets.lookup(execution_id) |> Enum.map(&elem(&1, 1))
    :ets.delete(@table, execution_id)
    {:reply, tokens, state}
  end

  def handle_call(:sweep, _from, state), do: {:reply, do_sweep(), state}

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  defp do_sweep do
    cutoff = now_ms() - ttl_ms()
    deleted = :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    if deleted > 0 do
      Logger.warning("[Opus.OAuthTokenTracker] swept #{deleted} undrained dispensed token(s)")
    end

    deleted
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)

  # Floored at the platform execution ceiling plus drain margin: a
  # configured TTL below the ceiling swept tokens while their execution
  # still ran, so the finalize-time `collect` answered `[]` and the
  # dispensed token reached stored output and events UNMASKED. The config
  # may lengthen residency, never shorten it below what masking needs.
  defp ttl_ms do
    configured = Application.get_env(:cyfr, :oauth_token_ttl_ms, @ttl_ms)
    max(configured, ceiling_timeout_ms() + @drain_margin_ms)
  end

  defp ceiling_timeout_ms do
    with %{timeout: timeout} <- Sanctum.Policy.Ceiling.platform_ceiling(),
         {:ok, ms} <- Cyfr.Limits.parse_duration(timeout) do
      ms
    else
      # An unparseable ceiling is a bug upstream; take the widest value the
      # ceiling could mean rather than a TTL that sweeps early.
      _ -> :timer.minutes(30)
    end
  end
end
