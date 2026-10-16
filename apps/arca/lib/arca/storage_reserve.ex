# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageReserve do
  @moduledoc """
  The home's storage-reserve latch, `ok` or `depleted`, as the layers that
  admit and write read it (`ARCHITECTURE.md` §6.9).

  The host's monitor (`Cyfr.StorageReserve`) is the one writer: it reads
  the free space of the filesystems this member writes to, keeps the
  reserve file, and sets the latch here. While it reads `depleted`,
  Arca's write gate refuses every new byte of an athanor's tree
  (`refusal/0`), the decision log refuses its appends rather than spend
  the freed reserve, and Sanctum's gate admits only reads, the operations
  declared `reduces_authority` and the confirmations they need. Deletes
  still reclaim space, and the cell's own lease, claim and shutdown writes
  are never refused.

  The latch is this member's, held in its `:persistent_term`: every write
  reads it, and it changes only when the monitor's reading crosses the
  mark. Before the monitor first derives it at boot it reads `ok`, so the
  steps before the gate, which admit no work, are never refused; the
  monitor derives it before the gate opens.
  """

  @key {__MODULE__, :latch}

  @typedoc "The latch's two states."
  @type state :: :ok | :depleted

  @doc "The latch as this member last set it, `ok` before any setting."
  @spec state() :: state()
  def state, do: :persistent_term.get(@key, :ok)

  @doc "Whether the latch reads `depleted`."
  @spec depleted?() :: boolean()
  def depleted?, do: state() == :depleted

  @doc """
  Set the latch: the monitor's alone (`Cyfr.StorageReserve`). An unchanged
  state writes nothing, so a steady reading costs no global collection of
  the term.
  """
  @spec put(state()) :: :ok
  def put(state) when state in [:ok, :depleted] do
    if :persistent_term.get(@key, nil) != state, do: :persistent_term.put(@key, state)
    :ok
  end

  @doc "The refusal of a write the depleted latch stops."
  @spec refusal() :: {:unavailable, :storage_reserve}
  def refusal, do: {:unavailable, :storage_reserve}

  @doc """
  The local filesystem roots this member's storage adapter writes: the
  storage root under the Local adapter, none under the object store, which
  is outside the reserve.
  """
  @spec local_roots() :: [Path.t()]
  def local_roots do
    if Arca.Storage.configured_adapter() == Arca.Adapters.Local,
      do: [Arca.Adapters.Local.base_path()],
      else: []
  end
end
