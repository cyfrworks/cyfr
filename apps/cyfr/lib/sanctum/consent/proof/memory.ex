# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Proof.Memory do
  @moduledoc """
  Node-local proof store: a GenServer owning a private ETS table.

  Both mint and consume go through the server. Consent is human-scale
  traffic, so serializing costs nothing, and it buys the property that
  matters: take-and-verify is atomic, so two concurrent commits carrying
  the same token cannot both succeed. A public table with caller-side reads
  could not promise that — the OAuth pending-state store, which reads then
  deletes, has exactly that race.

  Expired rows are swept periodically; expiry is also checked on read, so a
  token is never accepted late even if the sweep has not run.
  """

  use GenServer

  @behaviour Sanctum.Consent.Proof

  alias Sanctum.Consent.Proof

  require Logger

  @table __MODULE__
  @sweep_interval_ms 60_000
  @token_bytes 32

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Sanctum.Consent.Proof
  def mint(bindings, ttl_ms) do
    GenServer.call(__MODULE__, {:mint, bindings, ttl_ms})
  end

  @impl Sanctum.Consent.Proof
  def consume(token, bindings) do
    GenServer.call(__MODULE__, {:consume, token, bindings})
  end

  @doc "Outstanding (unconsumed, unexpired) proof count — for tests and observability."
  @spec outstanding() :: non_neg_integer()
  def outstanding, do: GenServer.call(__MODULE__, :outstanding)

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl GenServer
  def init(_opts) do
    # Private: no other process may read a live proof, not even to count.
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :private, :set])
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:mint, bindings, ttl_ms}, _from, state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    :ets.insert(@table, {token, bindings, expires_at})

    {:reply, {:ok, token}, state}
  end

  @impl GenServer
  def handle_call({:consume, token, presented}, _from, state) do
    # Take first: a mismatched attempt burns the token rather than
    # revealing, over repeated tries, which binding was wrong.
    case :ets.take(@table, token) do
      [{^token, minted, expires_at}] ->
        if expires_at > System.monotonic_time(:millisecond) do
          {:reply, Proof.compare(minted, presented), state}
        else
          {:reply, {:error, :expired}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_call(:outstanding, _from, state) do
    now = System.monotonic_time(:millisecond)
    live = :ets.select_count(@table, [{{:_, :_, :"$1"}, [{:>, :"$1", now}], [true]}])
    {:reply, live, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("[Consent.Proof.Memory] unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
