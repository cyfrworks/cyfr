# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SeedOffer do
  @moduledoc """
  The boot's seed offer: a new release may ship new seed media (bundle
  versions, a new AQUA template), and boot is when the estates that
  already exist are offered it — additively, never over anything they own
  (`Compendium.Provisioning.sync_seeds/0`).

  Optional work, and never a gate. It starts after `Cyfr.Bootstrap`'s
  checked success and after every child that admits work, runs once in
  `init/1`, and answers `:ignore` whatever happened: a failure is logged
  and the next boot, or the next sign-in's fill, tries again. It never
  stops the boot.

  The offer is the cell's, not each member's: it runs under the
  `seed_release` claim (`Arca.JobClaims`, key `"cell"`), and a member
  that finds a live peer holding it does not wait — the rows it writes are
  shared, so one member doing it covers the rest.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Arca.JobClaims
  alias Arca.Schemas.JobClaim

  @lease_ms :timer.minutes(5)

  @doc "Offer the seed media inside `init/1`, then answer `:ignore`. `opts` as for `run/1`."
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    _outcome = run(opts)
    :ignore
  end

  @doc """
  Take the `seed_release` claim, sync the seed media under it, and give
  it up. `:skipped` when a live peer holds it; `{:error, reason}` when the
  claim could not be read or the sync raised. Never raises.

  `opts`: `:key` (`"cell"` by default), `:owner` (this boot by default),
  `:lease_ms`, and `:sync`, the work itself
  (`Compendium.Provisioning.sync_seeds/0` by default).
  """
  @spec run(keyword()) :: :ok | :skipped | {:error, :database_error | :exception}
  def run(opts \\ []) when is_list(opts) do
    key = Keyword.get(opts, :key, JobClaim.cell_key())
    owner = Keyword.get(opts, :owner, Cyfr.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    sync = Keyword.get(opts, :sync, &Compendium.Provisioning.sync_seeds/0)

    case JobClaims.claim("seed_release", key, owner, lease_ms) do
      {:ok, claim} ->
        try do
          sync.()
          :ok
        after
          JobClaims.release(claim)
        end

      {:busy, %JobClaim{owner: peer}} ->
        Logger.info("[Cyfr.SeedOffer] the seed offer is #{peer}'s this boot")
        :skipped

      {:error, :database_error} ->
        Logger.error("[Cyfr.SeedOffer] the seed_release claim could not be read; skipping")
        {:error, :database_error}
    end
  rescue
    e ->
      Logger.error("[Cyfr.SeedOffer] seed offer failed: #{inspect(e.__struct__)}")
      {:error, :exception}
  catch
    kind, _reason ->
      Logger.error("[Cyfr.SeedOffer] seed offer failed: #{kind}")
      {:error, :exception}
  end
end
