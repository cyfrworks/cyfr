# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ControlPlane do
  @moduledoc """
  Which boot owns this database's control plane.

  Claims one control plane per database using an Arca.ServerMetaStorage
  lease. Ownership is claimed at boot, renewed while running, and released
  on shutdown. This coordinates admission for services with node-local state.

  * A second live claimant refuses boot. An expired lease may be claimed
    after one bounded wait. `CYFR_CLUSTER=1` disables exclusive claiming.
  * `owner?/0` requires an unexpired local lease deadline. After expiry,
    the endpoint returns 503, readiness reports the loss, and turn,
    execution, and catalog admission stop until ownership is restored.
  * Before claiming, the boot owns nothing. Setting
    `control_plane_claim_enabled: false` disables these ownership checks.
  """

  use GenServer

  require Logger

  alias Cyfr.ControlPlane.Claim

  @lease_ms 60_000
  @renew_ms 20_000
  # How much longer than a dead holder's own deadline a boot waits for it,
  # and the ceiling on that wait relative to this boot's lease.
  @wait_slack_ms 250
  @ownership_key {__MODULE__, :ownership}

  @typedoc """
  What this boot holds: a lease until a deadline, the plane outright (a
  cluster node), nothing after a lapse, or nothing yet.
  """
  @type ownership :: {:held, DateTime.t() | :forever} | :lost | :unclaimed

  @doc "Whether this boot currently owns the control plane."
  @spec owner?() :: boolean()
  def owner? do
    case :persistent_term.get(@ownership_key, :unclaimed) do
      {:held, :forever} -> true
      {:held, %DateTime{} = until} -> DateTime.compare(DateTime.utc_now(), until) == :lt
      :lost -> false
      :unclaimed -> not claim_enabled?()
    end
  end

  @doc """
  Run one unit of background work only while this boot owns the control
  plane: answers `fun.()`, or `:not_owner` without calling it. A background
  worker asks on every tick, so its work stops when ownership lapses and
  goes on when ownership is regained.
  """
  @spec when_owner((-> result)) :: result | :not_owner when result: var
  def when_owner(fun) when is_function(fun, 0), do: if(owner?(), do: fun.(), else: :not_owner)

  @doc "`:ok` to admit work, `{:error, :control_plane_lost}` to refuse it."
  @spec assert_owner() :: :ok | {:error, :control_plane_lost}
  def assert_owner, do: if(owner?(), do: :ok, else: {:error, :control_plane_lost})

  @doc false
  # The process-wide ownership record. Public so a test can put a boot in a
  # given state without a lease; the server is its only production writer.
  @spec mark(ownership()) :: :ok
  def mark(ownership), do: :persistent_term.put(@ownership_key, ownership)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Stopped by its supervisor, the server releases the lease it holds
    # (`terminate/2`), so the next boot claims at once instead of waiting
    # out a row nobody renews.
    Process.flag(:trap_exit, true)

    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    renew_ms = Keyword.get(opts, :renew_ms, @renew_ms)
    cluster? = Keyword.get(opts, :cluster, Application.get_env(:cyfr, :cluster, false)) == true
    me = Cyfr.Boot.id()

    refuse_foreign_nodes!(cluster?)

    state = %{me: me, lease_ms: lease_ms, renew_ms: renew_ms, cluster?: cluster?, expires_at: nil}

    cond do
      cluster? ->
        mark({:held, :forever})
        {:ok, state}

      true ->
        case claim_or_wait(me, lease_ms) do
          {:ok, expires_at} ->
            mark({:held, expires_at})
            Process.send_after(self(), :renew, renew_ms)
            {:ok, %{state | expires_at: expires_at}}

          {:error, {:held, owner, until}} ->
            raise "[Cyfr] FATAL: another control plane (#{owner}) holds this database until " <>
                    "#{DateTime.to_iso8601(until)} and is renewing it. Two servers on one " <>
                    "database each run every sweep and accept every turn. Stop the other one. " <>
                    "CYFR_CLUSTER lifts this claim, and nothing replaces it: turn ownership, " <>
                    "provisioning and the singletons are node-local, so both nodes would own " <>
                    "the same turn and fill the same estate."

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
          mark({:held, expires_at})
          %{state | expires_at: expires_at}

        :lost ->
          # Still inside the lease this boot last held: the store may merely
          # be slow, and `owner?/0` lapses on its own at the deadline. Past
          # it, the row may be another boot's — record the loss and try to
          # win the row back.
          if DateTime.compare(DateTime.utc_now(), state.expires_at) == :lt do
            state
          else
            if owner?() do
              Logger.error(
                "[Cyfr.ControlPlane] lease lapsed unrenewed — refusing work until the claim is won back"
              )
            end

            mark(:lost)
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

  @impl true
  def terminate(_reason, %{cluster?: true}), do: :ok

  def terminate(_reason, state) do
    mark(:lost)

    case Claim.release(state.me) do
      :ok ->
        :ok

      :not_held ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.ControlPlane] lease not released at stop (#{inspect(reason)}); " <>
            "the next boot waits it out"
        )
    end

    :ok
  end

  # A held row belongs to a live boot or a dead one, and only time tells:
  # a live holder renews before its deadline, a dead one never will. Wait
  # for that deadline once — never longer than a lease of our own — and
  # claim again; a row that was renewed meanwhile is a live server's and
  # is refused.
  defp claim_or_wait(me, lease_ms) do
    case Claim.claim(me, lease_ms) do
      {:error, {:held, owner, until}} = held ->
        wait_ms = DateTime.diff(until, DateTime.utc_now(), :millisecond)

        if wait_ms > 0 and wait_ms <= lease_ms + @wait_slack_ms do
          Logger.warning(
            "[Cyfr.ControlPlane] #{owner} holds the control plane until " <>
              "#{DateTime.to_iso8601(until)}; waiting #{wait_ms} ms for it to renew or lapse"
          )

          Process.sleep(wait_ms + @wait_slack_ms)
          Claim.claim(me, lease_ms)
        else
          held
        end

      other ->
        other
    end
  end

  # A lost lease is retaken only through the same claim a boot makes: an
  # absent or expired row, never a live one another boot holds.
  defp reclaim(state) do
    case Claim.claim(state.me, state.lease_ms) do
      {:ok, expires_at} ->
        Logger.warning("[Cyfr.ControlPlane] ownership regained")
        mark({:held, expires_at})
        %{state | expires_at: expires_at}

      _ ->
        state
    end
  end

  defp claim_enabled?, do: Application.get_env(:cyfr, :control_plane_claim_enabled, true)

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
