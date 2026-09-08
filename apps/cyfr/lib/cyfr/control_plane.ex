# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlane do
  @moduledoc """
  Which boot owns this database's control plane.

  Much of the tree assumes one control plane per database: the
  conversation registry, the overlay's single-writer lock, the OAuth
  refresh lock, the budget table and the retention sweep are all
  node-local. That was remembered, not enforced — two processes pointed at
  one database both boot, both run every sweep, and both accept turns. A
  node NAME is no signal (a named single-node release has one and an empty
  `Node.list/0`; two undistributed processes both have an empty list), so
  ownership is a lease row in the database (`Arca.ServerMetaStorage`),
  claimed at boot and renewed while this boot runs.

  * A second live claimant refuses to boot, unless `CYFR_CLUSTER=1` says
    the nodes share the database by design (then nothing is claimed and
    every node owns the plane — the posture the multi-node work lifts).
  * A boot whose renewal keeps failing stops accepting and authorizing
    work once the lease it last held lapses: the endpoint answers 503
    (`EmissaryWeb.Plugs.ControlPlaneOwnership`), readiness reports it, and
    no turn or execution is admitted (`assert_owner/0`) until the claim is
    won back. A successor cannot take over while the holder still writes.
  """

  use GenServer

  require Logger

  alias Cyfr.ControlPlane.Claim

  @lease_ms 60_000
  @renew_ms 20_000
  @owner_key {__MODULE__, :owner?}

  @doc "Whether this boot currently owns the control plane."
  @spec owner?() :: boolean()
  def owner?, do: :persistent_term.get(@owner_key, true)

  @doc "`:ok` to admit work, `{:error, :control_plane_lost}` to refuse it."
  @spec assert_owner() :: :ok | {:error, :control_plane_lost}
  def assert_owner, do: if(owner?(), do: :ok, else: {:error, :control_plane_lost})

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    renew_ms = Keyword.get(opts, :renew_ms, @renew_ms)
    cluster? = Keyword.get(opts, :cluster, Application.get_env(:cyfr, :cluster, false)) == true
    me = Cyfr.Boot.id()

    refuse_foreign_nodes!(cluster?)

    state = %{me: me, lease_ms: lease_ms, renew_ms: renew_ms, cluster?: cluster?, expires_at: nil}

    cond do
      cluster? ->
        mark(true)
        {:ok, state}

      true ->
        case Claim.claim(me, lease_ms) do
          {:ok, expires_at} ->
            mark(true)
            Process.send_after(self(), :renew, renew_ms)
            {:ok, %{state | expires_at: expires_at}}

          {:error, {:held, owner, until}} ->
            raise "[Cyfr] FATAL: another control plane (#{owner}) holds this database until " <>
                    "#{DateTime.to_iso8601(until)}. Two servers on one database each run every " <>
                    "sweep and accept every turn. Stop the other one, or set CYFR_CLUSTER=1 only " <>
                    "for nodes that share the database by design."

          {:error, reason} ->
            raise "[Cyfr] FATAL: the control-plane claim could not be written (#{inspect(reason)})."
        end
    end
  end

  @impl true
  def handle_info(:renew, state) do
    state =
      case Claim.renew(state.me, state.lease_ms) do
        {:ok, expires_at} ->
          unless owner?(), do: Logger.warning("[Cyfr.ControlPlane] ownership regained")
          mark(true)
          %{state | expires_at: expires_at}

        :lost ->
          # Still inside the lease this boot last held: the store may merely
          # be slow. Past it, the row may be another boot's — stop.
          if DateTime.compare(DateTime.utc_now(), state.expires_at) == :lt do
            state
          else
            if owner?() do
              Logger.error(
                "[Cyfr.ControlPlane] lease lapsed unrenewed — refusing work until the claim is won back"
              )
            end

            mark(false)
            reclaim(state)
          end
      end

    Process.send_after(self(), :renew, state.renew_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Cyfr.UnexpectedMessage.log(__MODULE__, msg)
    {:noreply, state}
  end

  # A lost lease is retaken only through the same claim a boot makes: an
  # absent or expired row, never a live one another boot holds.
  defp reclaim(state) do
    case Claim.claim(state.me, state.lease_ms) do
      {:ok, expires_at} ->
        Logger.warning("[Cyfr.ControlPlane] ownership regained")
        mark(true)
        %{state | expires_at: expires_at}

      _ ->
        state
    end
  end

  defp mark(owner?), do: :persistent_term.put(@owner_key, owner?)

  defp refuse_foreign_nodes!(true), do: :ok

  defp refuse_foreign_nodes!(false) do
    case Node.list() do
      [] ->
        :ok

      others ->
        raise "[Cyfr] FATAL: this node is connected to #{inspect(others)} but CYFR_CLUSTER is not " <>
                "set. A cluster of control planes needs the multi-node work; a single one must " <>
                "not be distributed."
    end
  end
end
