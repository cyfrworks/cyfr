# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bootstrap do
  @moduledoc """
  The boot's security reconciliation: before this member admits any work,
  the platform grants are the ones `CYFR_PLATFORM_ADMIN_EMAILS` names, and
  the sessions of everyone it no longer names are gone.

  A sign-in reconciles a person's grant against that list, but only for
  someone the door still admits; boot is the other moment the list is
  read, and the one that reaches a de-listed operator nobody signs in as.

  ## Checked success or no boot

  Every member takes the cell's `bootstrap` claim (`Arca.JobClaims`, key
  `"cell"`) and runs its own reconcile — idempotent, so running it after a
  peer did costs nothing, and a peer's success, a release or a timeout is
  never taken for this member's. A live peer holding the claim is waited
  for up to `:wait_ms` (30 s); past that the boot is refused as `:busy`.

  `Sanctum.reconcile_platform_admins/2` does the work in one transaction
  under this member's slot and the claim, and answers the renewed claim.
  This module then releases that claim, and verifies the slot is still
  this member's (`Arca.ControlPlane.verify_held/1`). Only that checked
  `:ok` lets `init/1` answer `:ignore`, which is what lets the supervisor
  start the children after it: every child that admits work, and the
  endpoint after them (`Cyfr.Application`). Anything else — no slot, a
  claim a peer kept, a lost slot or claim, a malformed operator list, a
  person missing behind a grant, a database that could not answer, a
  raise, a release that did not land — stops `init/1` with
  `{:bootstrap_refused, reason}`, the supervisor's start fails, and the
  application does not boot. There is no wait-and-continue.

  A refusal is logged by its class alone. Nothing it carries is a
  credential, and nothing is printed from an exception but its module.

  `run/1` and `start_link/1` always do the work: the one sanctioned skip
  is the test suite's sandboxed boot omitting this child altogether
  (`Cyfr.Application`), and nothing here reads it.

  The seed offer that used to ride along is `Cyfr.SeedOffer`: optional
  work under a claim of its own, started after everything this gates.
  """

  use GenServer, restart: :temporary

  require Logger
  require Arca.Repo.Errors

  alias Arca.JobClaims
  alias Arca.Schemas.JobClaim

  @lease_ms :timer.minutes(5)
  @wait_ms :timer.seconds(30)
  @poll_ms 250

  @typedoc "Why this member may not admit work."
  @type refusal ::
          :slot_not_held
          | :busy
          | :malformed_configuration
          | :slot_lost
          | :claim_taken
          | :claim_lapsed
          | :missing_user
          | :release_failed
          | :database_error
          | :exception

  @doc """
  Reconcile inside `init/1`, answering `:ignore` on checked success and
  stopping with `{:bootstrap_refused, reason}` otherwise. `opts` as for
  `run/1`.
  """
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    case run(opts) do
      :ok -> :ignore
      {:error, reason} -> {:stop, {:bootstrap_refused, reason}}
    end
  end

  @doc """
  Take the claim, reconcile under it, release it and verify the slot.

  `opts`: `:key` (the claim key, `"cell"` by default), `:owner` (this boot
  by default), `:lease_ms`, `:wait_ms` (how long a live peer's claim is
  waited for before the boot is refused as `:busy`), and `:reconcile`,
  the reconcile itself (`Sanctum.reconcile_platform_admins/2` by default;
  a test supplies one that pauses before calling it).
  """
  @spec run(keyword()) :: :ok | {:error, refusal()}
  def run(opts \\ []) when is_list(opts) do
    opts |> reconcile_for_boot() |> refused_unless_ok()
  rescue
    e in Arca.Repo.Errors.db_errors() -> refused_unless_ok({:error, {:database_error, e}})
    e -> refused_unless_ok({:error, {:exception, e}})
  catch
    kind, _reason -> refused_unless_ok({:error, {:exception, kind}})
  end

  defp reconcile_for_boot(opts) do
    key = Keyword.get(opts, :key, JobClaim.cell_key())
    owner = Keyword.get(opts, :owner, Cyfr.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    wait_ms = Keyword.get(opts, :wait_ms, @wait_ms)
    reconcile = Keyword.get(opts, :reconcile, &Sanctum.reconcile_platform_admins/2)

    with {:ok, slot} <- member_slot(),
         {:ok, claim} <- acquire(key, owner, lease_ms, wait_ms) do
      under_claim(claim, slot, lease_ms, reconcile)
    end
  end

  # The slot is read before anything else and without a query: a member
  # that should hold one and does not has nothing to reconcile under. A
  # deployment where no member claims a slot (`Arca.ControlPlane`'s
  # `:none`) has nothing to fence, and reconciles under the claim alone.
  defp member_slot do
    if Arca.ControlPlane.held?() do
      case Arca.ControlPlane.held() do
        {:ok, slot} -> {:ok, slot}
        :none -> if Arca.ControlPlane.generation() == :none, do: {:ok, :none}, else: not_held()
      end
    else
      not_held()
    end
  end

  defp not_held, do: {:error, :slot_not_held}

  defp acquire(key, owner, lease_ms, wait_ms) do
    claim_by(key, owner, lease_ms, System.monotonic_time(:millisecond) + max(wait_ms, 0), true)
  end

  defp claim_by(key, owner, lease_ms, deadline, first?) do
    case JobClaims.claim("bootstrap", key, owner, lease_ms) do
      {:ok, claim} ->
        {:ok, claim}

      {:busy, %JobClaim{owner: peer}} ->
        left = deadline - System.monotonic_time(:millisecond)

        if left <= 0 do
          {:error, :busy}
        else
          if first?, do: Logger.info("[Cyfr.Bootstrap] #{peer} holds the claim; waiting for it")
          Process.sleep(min(@poll_ms, left))
          claim_by(key, owner, lease_ms, deadline, false)
        end

      {:error, :database_error} ->
        {:error, :database_error}
    end
  end

  # A refusal gives up the claim this member took, so the next boot's
  # attempt is not held behind a lease nobody is using. Only the checked
  # path's own release decides success.
  defp under_claim(claim, slot, lease_ms, reconcile) do
    case checked(claim, slot, lease_ms, reconcile) do
      :ok ->
        :ok

      {:error, _reason} = refusal ->
        _ = JobClaims.release(claim)
        refusal
    end
  rescue
    e ->
      _ = JobClaims.release(claim)
      reraise e, __STACKTRACE__
  catch
    kind, reason ->
      _ = JobClaims.release(claim)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp checked(claim, slot, lease_ms, reconcile) do
    case reconcile.(claim, slot: slot, lease_ms: lease_ms) do
      {:ok, %JobClaim{} = renewed} ->
        with :ok <- release(renewed), do: still_held(slot)

      {:error, reason} when is_atom(reason) ->
        {:error, reason}
    end
  end

  defp release(renewed) do
    case JobClaims.release(renewed) do
      :ok -> :ok
      _taken_or_unreachable -> {:error, :release_failed}
    end
  end

  # After the release, and before anything downstream starts: the slot the
  # reconcile ran under is still this member's.
  defp still_held(:none), do: :ok

  defp still_held(slot) do
    case Arca.Repo.locking_transaction(fn -> Arca.ControlPlane.verify_held(slot) end) do
      {:ok, :ok} -> :ok
      {:ok, :lost} -> {:error, :slot_lost}
    end
  end

  defp refused_unless_ok(:ok), do: :ok

  defp refused_unless_ok({:error, {class, cause}}) when class in [:database_error, :exception] do
    Logger.error(
      "[Cyfr.Bootstrap] security reconcile refused: #{class} (#{cause_name(cause)}); " <>
        "this member admits no work"
    )

    {:error, class}
  end

  defp refused_unless_ok({:error, reason}) when is_atom(reason) do
    Logger.error(
      "[Cyfr.Bootstrap] security reconcile refused: #{reason}; this member admits no work"
    )

    {:error, reason}
  end

  defp cause_name(%{__exception__: true, __struct__: module}), do: inspect(module)
  defp cause_name(kind) when is_atom(kind), do: Atom.to_string(kind)
end
