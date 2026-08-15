# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuildLimiter do
  @moduledoc """
  Fixed cap on concurrent toolchain builds.

  A `cargo component build` or npm bundle occupies a CPU core and hundreds
  of MB for minutes; nothing else bounded how many a node would accept at
  once. Locus is a library app with no process tree, so the counter is a
  node-local `:atomics` ref parked in `:persistent_term` —
  `Cyfr.Application` calls `init/0` at boot so the ref is minted exactly
  once, never lazily from racing callers.

  A caller past the cap is rejected, not queued — mirroring
  `Opus.ExecutionSemaphore`'s per-tenant posture: a backlog of
  multi-minute builds behind a synchronous tool call helps nobody.
  """

  @key {__MODULE__, :counter}
  @default_max 2

  @doc "Mint the shared counter. Called once from the application boot path."
  def init do
    :persistent_term.put(@key, :atomics.new(1, signed: true))
    :ok
  end

  @doc """
  Take a build slot. `{:error, :busy}` past the cap — callers surface a
  retryable message rather than queueing.
  """
  @spec acquire() :: :ok | {:error, :busy}
  def acquire do
    ref = counter()

    if :atomics.add_get(ref, 1, 1) > max_builds() do
      :atomics.sub(ref, 1, 1)
      {:error, :busy}
    else
      :ok
    end
  end

  @doc "Return a slot. Callers pair this with `acquire/0` in an `after`."
  @spec release() :: :ok
  def release do
    :atomics.sub(counter(), 1, 1)
    :ok
  end

  @doc "The configured cap (`:cyfr, :max_concurrent_builds`, default #{@default_max})."
  def max_builds, do: Application.get_env(:cyfr, :max_concurrent_builds, @default_max)

  defp counter do
    case :persistent_term.get(@key, nil) do
      nil ->
        # Boot path missed (e.g. a bare script) — mint one late. Worst case
        # of the race is a briefly split counter, and only before any build
        # has ever run.
        init()
        :persistent_term.get(@key)

      ref ->
        ref
    end
  end
end
