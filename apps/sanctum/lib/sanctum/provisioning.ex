# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Provisioning do
  @moduledoc """
  An athanor's half of being filled: who may hold it while it is filled,
  what it is allowed to run once it is, and what the row says went wrong.

  A person's own athanor is minted at admission (`after_sign_in/1`): a
  person needs no registry, no namespace and no claim to have one, and its
  slug is their namespace only when that is already known and free. A
  group is minted as a bare row (`Sanctum.Tenancy.Athanors.create_group/3`)
  and filled the first time something reads its bundle
  (`start_provisioning/1`). Provisioning is idempotent — `provisioned_at`
  marks completion and every step tolerates being repeated — and loud: a
  failure leaves the row unprovisioned with the reason in its settings,
  and the next sign-in tries again.

  ## What this module does, and what it does not

  Copying the seed bundle in, scanning it into rows, pulling the published
  closure, checking the shipped AQUA tree and indexing the estate's agents
  are the component domain's work, not identity's — `Compendium.Provisioning`
  owns them. This module owns the estate's **claim**, the **consent
  bootstrap** the fill mints, the **readiness and failure writes** on the
  row, and the **tenancy writes** that mint a person their own athanor. It
  announces that an estate needs filling
  (`[:cyfr, :sanctum, :provisioning, :fill_requested]`) and the component
  domain reacts; nothing here names it.

  ## Entry points

  Everything that fills or heals an estate holds the estate's one claim
  row (`Arca.ProvisioningClaims`) while it works: an owner — this boot and
  the attempt's own token, so a restarted boot never resumes another's
  claim — an entry kind, a lease a keeper task renews on a tick, and a
  fence. What differs per entry point is what it does when the claim is
  held:

    * `after_sign_in/1`'s personal fill (`sign_in`): the row and the seat
      are written on the sign-in; the fill is announced and runs in the
      background under its own claim. A held claim means someone is
      filling already, and the sign-in adds nothing. The group retries are
      announced the same way. No backoff.
    * `start_provisioning/1`, `ready/1` and `status/1` (`first_need`):
      readers never claim and never wait. They read the claim once and
      answer — filled, filling, failed — and announce a fill only when
      nothing holds the claim and no fill failed within the last minute.
      Readers that announce at once coalesce on the claim.
    * `provision/2`, behind the explicit `athanor.provision`
      (`provision`): announces an attempt and answers where the estate
      stands once it has run. No backoff: a person who asks is never told
      to wait out a failure, and a claim another attempt holds answers
      `{:error, :provisioning_busy}` rather than queueing behind it.
    * `Compendium.Provisioning`'s `install_shipped/2` (`install_shipped`)
      and `sync_seeds/0` (`seed_sync`) take the claim through
      `under_claim/3` and `await_claim/5` here.

  An attempt settles its claim `ready` or `failed`; an install, a sync and
  an attempt that found the estate filled release it. Every write that
  speaks for the attempt is fenced by the claim: readiness is marked only
  after the claim settled `ready`, a failure is recorded only after it
  settled `failed`, and the consent mint and the agent index check the
  claim still reads this owner and fence before they write. An attempt
  whose lease ran out and whose claim a successor took writes none of
  them and answers `{:error, :provisioning_busy}`.

  ## Giving the estate back

  A claim is given back by the attempt that holds it, or — for an attempt
  killed where it stands, which runs no `after` — by its keeper, which
  monitors it. With the keeper gone too nothing releases it and the lease
  is the bound: one minute from the write that last stood for it.

  Either releaser stops what the attempt started beside itself first, and
  waits for it to have stopped (`bounded_work/3`). A release is never what
  discovers that a pull is still running: an estate handed to a successor
  while its predecessor still writes to it is the race the claim exists to
  prevent, so work that will not stop leaves the claim to its lease
  instead.
  """

  require Logger

  alias Arca.ProvisioningClaims, as: Claims
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Caps, Members, Users}

  # How long a claim stands without its keeper renewing it, and how often
  # the keeper does. A claim nobody renews is takeable one lease after the
  # write that last stood for it, which is the bound on an estate whose
  # attempt died with its keeper.
  @lease_ms 60_000
  @renew_ms 20_000

  # How long the keeper waits for work the attempt started beside itself
  # to stop. Past it the claim is NOT given back: a successor taking an
  # estate its predecessor may still be writing to is the one outcome a
  # release must never cause, and the lease is the honest bound.
  @quiesce_ms 10_000

  # The keeper this process's attempt answers to. Process-local because
  # the attempt is: one task fills several estates in turn, each under a
  # claim of its own, and a keeper is that claim's for the length of its
  # own `fun`.
  @keeper_key {__MODULE__, :keeper}

  @typedoc "The claim an attempt holds while it fills an estate."
  @type claim :: Arca.Schemas.ProvisioningClaim.t()

  @doc """
  Called once the person is admitted, and again whenever their namespace
  is recorded (`Sanctum.SignIn.record_namespace/2`): mints their own
  athanor if they have none, and announces a retry for any group of theirs
  whose provisioning failed earlier. Admission is enough — a person needs
  no registry, no namespace and no claim to have a furnace of their own.
  """
  @spec after_sign_in(String.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()} | :pending
  def after_sign_in(user_id) when is_binary(user_id) do
    case Users.get(user_id) do
      {:ok, user} ->
        retry_groups(user_id)
        ensure_personal_athanor(user)

      {:error, :not_found} ->
        :pending

      {:error, _} = err ->
        err
    end
  end

  @doc """
  The person's own athanor: the one their `users` row records, else a
  fresh one (kind person, a slug of this server's — their namespace when
  they have one and it is free, otherwise derived from their name — the
  person its only member), announced for filling if not yet filled, and
  recorded on the row. Idempotent.
  """
  @spec ensure_personal_athanor(Arca.Schemas.User.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def ensure_personal_athanor(%{id: user_id} = user) do
    with {:ok, athanor} <- find_or_create_personal(user),
         {:ok, _} <- Members.ensure(user_id, scope: "athanor", athanor_id: athanor.id),
         {:ok, _} <- record_personal(user, athanor) do
      # The row and its seat are the sign-in's business and are written
      # here; filling it is not, and a sign-in must not wait on a
      # registry. A failure lands on the row and the next read retries.
      fill_after_sign_in(athanor, person_ctx(user_id, athanor.id))
      {:ok, athanor}
    end
  end

  defp fill_after_sign_in(%{provisioned_at: %DateTime{}}, _ctx), do: :ok

  defp fill_after_sign_in(athanor, ctx), do: request_fill(athanor, ctx, "sign_in")

  @doc """
  Whether the context's athanor has been filled.

  The cheap read every consumer of the bundle makes before it reads the
  bundle itself.
  """
  @spec provisioned?(Context.t()) :: boolean()
  def provisioned?(%Context{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    match?({:ok, %{provisioned_at: %DateTime{}}}, Athanors.get(athanor_id))
  end

  def provisioned?(_ctx), do: false

  @doc """
  Ask for the context's athanor to be filled if nothing has yet, and
  answer at once — the first-need hook.

  Never waits: filling walks the seed overlay and may pull a dependency
  closure over the network, and no request path may hold a page open for
  that. The work is single-flighted per athanor, so a second caller
  finding it already running adds nothing.
  """
  @spec start_provisioning(Context.t()) :: :ok
  def start_provisioning(%Context{athanor_id: athanor_id} = ctx)
      when is_binary(athanor_id) and athanor_id != "" do
    case Athanors.get(athanor_id) do
      {:ok, %{provisioned_at: %DateTime{}}} ->
        :ok

      {:ok, athanor} ->
        if fill_state(athanor) == :unfilled, do: request_fill(athanor, ctx, "first_need")
        :ok

      _ ->
        :ok
    end
  end

  def start_provisioning(_ctx), do: :ok

  @doc """
  Where the context's athanor stands, read once and answered at once —
  nothing is started and nothing is waited for.

    * `:ready` — filled.
    * `:filling` — an attempt holds the estate's claim.
    * `:failed` — a fill failed within the last minute; no automatic fill
      starts until the minute is out.
    * `:unfilled` — not filled, and nothing in the way of a fill.
    * `:unavailable` — the claim could not be read, or there is no athanor.
  """
  @spec status(Context.t()) :: :ready | :filling | :failed | :unfilled | :unavailable
  def status(%Context{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "" do
    case Athanors.get(athanor_id) do
      {:ok, %{provisioned_at: %DateTime{}}} -> :ready
      {:ok, athanor} -> fill_state(athanor)
      _ -> :unavailable
    end
  end

  def status(_ctx), do: :unavailable

  # How long an automatic fill stays out of the way after one failed.
  @retry_after_failure_ms :timer.minutes(1)

  # An unfilled estate, by its claim. A reader never takes the claim: the
  # fill it asks for does, from its own task.
  defp fill_state(%{id: athanor_id} = athanor) do
    case Claims.current(actor(athanor_id)) do
      {:ok, claim} ->
        cond do
          Claims.live?(claim) -> :filling
          recently_failed?(athanor, claim) -> :failed
          true -> :unfilled
        end

      {:error, :not_found} ->
        if recently_failed?(athanor, nil), do: :failed, else: :unfilled

      {:error, _} ->
        :unavailable
    end
  end

  # A fill that failed recorded why on the row, and recording it announces
  # the row changed — which is what a console page reloads on. Without this
  # the reload's reads would start another attempt, fail the same way, and
  # announce again: a loop nobody asked for, from one failure.
  #
  # Only automatic fills back off. `athanor.provision` reaches `provision/2`
  # directly, so a person who asks is never told to wait.
  defp recently_failed?(_athanor, %{outcome: "failed"} = claim),
    do: Claims.age_ms(claim) < @retry_after_failure_ms

  defp recently_failed?(%{provisioning_failed_at: %DateTime{} = failed_at}, _claim),
    do: DateTime.diff(DateTime.utc_now(), failed_at, :millisecond) < @retry_after_failure_ms

  defp recently_failed?(_athanor, _claim), do: false

  @doc """
  Ask for the fill if needed, and say whether the estate can run a turn
  yet.

  `:ok` when the athanor is filled, `{:error, :not_provisioned}` while it
  is not — with the work asked for, so an estate first touched over the
  wire fills without a console ever opening it.

  Reads of the bundle do not use this: the tree reads through the seed
  overlay from the moment the row exists, so a roster is real straight
  away. What a fill adds is the baseline consent a turn pins, which is why
  `Aqua.Runner` is what waits.
  """
  @spec ready(Context.t()) :: :ok | {:error, :not_provisioned}
  def ready(%Context{} = ctx) do
    if provisioned?(ctx) do
      :ok
    else
      start_provisioning(ctx)
      {:error, :not_provisioned}
    end
  end

  @doc """
  Fill an athanor, behind the explicit `athanor.provision`: ask for an
  attempt now — no backoff, since a person asked — and answer where the
  estate stands once it has run.

  `acting_ctx` is the person's context focused on the athanor (their pull
  credential); `nil` provisions as the server (anonymous pulls). The
  filler runs the attempt in this process, so this answers for the
  attempt it asked for: an attempt another caller holds is
  `{:error, :provisioning_busy}` at once, one that failed says where and
  why, and the outcome is on the row either way. A deployment with no
  filler attached answers `{:error, :unavailable}` — an estate nothing
  can fill is neither busy nor failed.
  """
  @spec provision(Arca.Schemas.Athanor.t(), Context.t() | nil) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def provision(%{provisioned_at: %DateTime{}} = athanor, _ctx), do: {:ok, athanor}

  def provision(athanor, acting_ctx) do
    ref = make_ref()
    request_fill(athanor, acting_ctx, "provision", %{reply_to: self(), ref: ref})

    # The filler runs this attempt in the asking process — that is what
    # makes the explicit verb synchronous, exactly as it was when this
    # module ran the attempt itself — so its answer is already in the
    # mailbox when the announcement returns. A deployment with no filler
    # attached has an estate nothing can fill, which is neither busy nor
    # failed.
    receive do
      {:provisioning_filled, ^ref, outcome} -> outcome
    after
      0 -> {:error, :unavailable}
    end
  end

  # ---- the estate's filler ---------------------------------------------------

  @fill_event [:cyfr, :sanctum, :provisioning, :fill_requested]

  @doc """
  The event this module announces an estate needs filling with. Named
  here so the component domain attaches to one spelling.
  """
  @spec fill_event() :: [atom(), ...]
  def fill_event, do: @fill_event

  # An estate needs filling. A foundation below the host announces and
  # never calls up: the component domain attaches to this event and does
  # the work — in the background for the hooks, in the caller's process
  # for the explicit verb, which is what makes `provision/2` answer for
  # the attempt it asked for.
  defp request_fill(athanor, acting_ctx, entry_kind, extra \\ %{}) do
    :telemetry.execute(
      @fill_event,
      %{count: 1},
      Map.merge(
        %{
          athanor: athanor,
          athanor_id: athanor.id,
          acting_ctx: acting_ctx,
          entry_kind: entry_kind
        },
        extra
      )
    )

    :ok
  end

  # ---- the claim -------------------------------------------------------------

  # The owner a claim is taken under: this boot, and a token of the
  # attempt's own — never another boot's, and never another attempt's.
  defp owner, do: Cyfr.Boot.id() <> "/" <> Cyfr.UUID7.generate_id("own")

  @doc """
  The actor a claim on `athanor_id` is taken under. The claim is the
  athanor's, whoever acts: the actor names the tenant and nothing else.
  """
  @spec actor(String.t()) :: Cyfr.Actor.t()
  def actor(athanor_id), do: Context.actor(seed_ctx(athanor_id))

  @doc """
  Try the estate's claim once and run `fun` holding it. A held claim is
  answered as in progress at once, never waited out.
  """
  @spec under_claim(String.t(), String.t(), (claim() -> result)) ::
          result | {:error, :provisioning_busy} | {:error, term()}
        when result: term()
  def under_claim(athanor_id, entry_kind, fun) when is_function(fun, 1) do
    case take_claim(athanor_id, entry_kind) do
      {:ok, claim} -> hold(athanor_id, claim, fun)
      {:error, _} = error -> error
    end
  end

  @doc """
  Take the estate's claim without holding it, for a filler that hands the
  work to another process: the claim is taken here, so a reader arriving
  straight after already finds the estate being filled, and `hold/3` runs
  where the work does. A claim nothing released is `release/2`'s to give
  back.
  """
  @spec take_claim(String.t(), String.t()) ::
          {:ok, claim()} | {:error, :provisioning_busy} | {:error, term()}
  def take_claim(athanor_id, entry_kind) do
    case Claims.claim(actor(athanor_id), owner(), entry_kind, @lease_ms) do
      {:ok, claim} -> {:ok, claim}
      {:busy, _claim} -> {:error, :provisioning_busy}
      {:error, _} = error -> error
    end
  end

  @doc """
  Run `fun` under a claim this process now answers for: a keeper renews
  the lease while it runs, and whatever `fun` did not settle is released
  when it ends.
  """
  @spec hold(String.t(), claim(), (claim() -> result)) :: result when result: term()
  def hold(athanor_id, claim, fun) when is_function(fun, 1),
    do: held(actor(athanor_id), claim, fun)

  @doc "Give a taken claim back with no verdict on readiness."
  @spec release(String.t(), claim()) :: :ok | :stale | {:error, term()}
  def release(athanor_id, claim),
    do: Claims.release(actor(athanor_id), claim.owner, claim.fence)

  @doc """
  Wait out an attempt in progress, within `wait_ms`, then run `fun`
  holding the estate's claim. The boot's seed sync has no one to answer
  to, so it waits — but one held estate must not keep the boot from the
  next, which is what the bound is for.
  """
  @spec await_claim(String.t(), String.t(), non_neg_integer(), pos_integer(), (claim() -> result)) ::
          result | {:error, :provisioning_busy} | {:error, term()}
        when result: term()
  def await_claim(athanor_id, entry_kind, wait_ms, poll_ms, fun) when is_function(fun, 1) do
    actor = actor(athanor_id)

    case wait_for_claim(actor, owner(), entry_kind, now_ms() + wait_ms, poll_ms) do
      {:ok, claim} -> held(actor, claim, fun)
      {:error, _} = error -> error
    end
  end

  defp wait_for_claim(actor, owner, entry_kind, deadline, poll_ms) do
    case Claims.claim(actor, owner, entry_kind, @lease_ms) do
      {:ok, claim} ->
        {:ok, claim}

      {:busy, _claim} ->
        if now_ms() < deadline do
          Process.sleep(poll_ms)
          wait_for_claim(actor, owner, entry_kind, deadline, poll_ms)
        else
          {:error, :provisioning_busy}
        end

      {:error, _} = error ->
        error
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Run `fun` beside the attempt, cut at `budget_ms`, as a child of
  `supervisor` — work the estate's claim answers for.

  An attempt's own process is what a caller holds open, so work that may
  stall — a registry pull — runs elsewhere and is cut at a budget. Such
  work is deliberately not linked to the attempt: a pull that crashes or
  is cut must take down neither the fill nor a boot's seed sync. That
  leaves it able to outlive the attempt, and a pull still writing into an
  estate a successor already holds is the race a claim exists to prevent.

  So the claim's **keeper** starts it. The keeper knows of the work from
  the instant it exists, rather than from a message a dying attempt might
  never have sent, and it stops it and waits for it to have stopped
  before it gives the claim back. Answers `{:ok, result}`, `:timeout` past
  the budget, or `{:exit, reason}` for work that ended by itself.

  Called by a process holding no claim — no keeper was started — the work
  runs from here under the same budget. Nothing renews or releases such a
  claim either, so its lease is what bounds both.
  """
  @spec bounded_work(atom(), pos_integer(), (-> result)) ::
          {:ok, result} | :timeout | {:exit, term()}
        when result: term()
  def bounded_work(supervisor, budget_ms, fun)
      when is_atom(supervisor) and is_integer(budget_ms) and budget_ms > 0 and
             is_function(fun, 0) do
    run_bounded(Process.get(@keeper_key), supervisor, budget_ms, fun)
  end

  defp run_bounded(keeper, supervisor, budget_ms, fun) when is_pid(keeper) do
    tag = make_ref()
    keeper_ref = Process.monitor(keeper)
    send(keeper, {:start_work, self(), tag, supervisor, fun})

    receive do
      {^tag, :started, worker} ->
        Process.demonitor(keeper_ref, [:flush])
        await_work(tag, worker, budget_ms)

      {^tag, :not_started, reason} ->
        Process.demonitor(keeper_ref, [:flush])
        {:exit, reason}

      {:DOWN, ^keeper_ref, :process, ^keeper, _reason} ->
        # The keeper is gone, so this attempt no longer answers for the
        # estate and has nothing to start work under.
        {:exit, :claim_lost}
    end
  end

  defp run_bounded(_no_keeper, supervisor, budget_ms, fun) do
    task = Task.Supervisor.async_nolink(supervisor, fun)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:exit, reason}
      nil -> :timeout
    end
  end

  # The attempt waits for its work, and past the budget cuts it and waits
  # for the cut to land: the step after this one must not run beside work
  # this one gave up on.
  defp await_work(tag, worker, budget_ms) do
    ref = Process.monitor(worker)

    receive do
      {^tag, :result, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^worker, reason} ->
        {:exit, reason}
    after
      budget_ms ->
        Process.exit(worker, :kill)
        _ = await_down(%{ref => worker}, now_ms() + @quiesce_ms)
        Process.demonitor(ref, [:flush])
        cut_result(tag)
    end
  end

  # A result that landed while the cut was in flight is still this
  # attempt's answer; anything else is the budget's verdict.
  defp cut_result(tag) do
    receive do
      {^tag, :result, result} -> {:ok, result}
    after
      0 -> :timeout
    end
  end

  # Run `fun` under a claim this process now answers for: a keeper renews
  # the lease while it runs, and whatever `fun` did not settle is released
  # when it ends — when the attempt ends, not when the process does, since
  # one task fills several estates in turn (a sign-in retries a person's
  # groups).
  #
  # The keeper is stopped before the release, and stopping it is what
  # quiesces whatever the attempt started beside itself, so the release
  # never discovers work still running: by then there is none.
  defp held(actor, claim, fun) do
    keeper = keep(actor, claim)
    previous = Process.put(@keeper_key, keeper)

    try do
      fun.(claim)
    after
      restore_keeper(previous)

      case stop_keeper(keeper) do
        :ok ->
          Claims.release(actor, claim.owner, claim.fence)

        :timeout ->
          Logger.error(
            "[Provisioning] #{claim.athanor_id}: work this attempt started has not stopped; " <>
              "the claim is left to its lease rather than given back"
          )
      end
    end
  end

  defp restore_keeper(nil) do
    Process.delete(@keeper_key)
    :ok
  end

  defp restore_keeper(keeper) do
    Process.put(@keeper_key, keeper)
    :ok
  end

  # The keeper renews the lease on a tick, holds what the attempt started
  # beside itself, and watches the attempt: an attempt killed where it
  # stands runs no `after`, so the keeper is what stops that work and
  # releases the claim — in that order, and only in that order. A renewal
  # refused as stale means a successor holds the estate: what this attempt
  # started must stop writing to it, and there is nothing left to keep.
  defp keep(actor, claim) do
    attempt = self()

    case Task.Supervisor.start_child(Sanctum.ProvisioningSupervisor, fn ->
           # A timer, not a receive timeout: the renewal is due when the
           # lease says, and a message the attempt sends must not put it
           # off.
           Process.send_after(self(), :renew, @renew_ms)
           keep_loop(actor, claim, Process.monitor(attempt), [])
         end) do
      {:ok, keeper} ->
        keeper

      {:error, reason} ->
        Logger.warning("[Provisioning] lease keeper not started: #{inspect(reason)}")
        nil
    end
  end

  defp keep_loop(actor, claim, ref, started) do
    receive do
      :renew ->
        case Claims.renew(actor, claim.owner, claim.fence, @lease_ms) do
          :ok ->
            Process.send_after(self(), :renew, @renew_ms)
            keep_loop(actor, claim, ref, started)

          _stale_or_unreadable ->
            stop_started(started)
        end

      {:stop, attempt} ->
        # The attempt finished on its own feet and is waiting to release:
        # it is answered once what it started has stopped, and not before.
        answer = stop_started(started)
        send(attempt, {:stopped, self(), answer})
        :ok

      {:start_work, attempt, tag, supervisor, fun} ->
        keep_loop(actor, claim, ref, start_work(attempt, tag, supervisor, fun, started))

      {:DOWN, ^ref, :process, _attempt, _reason} ->
        case stop_started(started) do
          :ok ->
            Claims.release(actor, claim.owner, claim.fence)

          :timeout ->
            Logger.error(
              "[Provisioning] #{claim.athanor_id}: work the dead attempt started has not " <>
                "stopped; the claim is left to its lease rather than given back"
            )
        end
    end
  end

  defp start_work(attempt, tag, supervisor, fun, started) do
    case Task.Supervisor.start_child(supervisor, fn -> send(attempt, {tag, :result, fun.()}) end) do
      {:ok, worker} ->
        send(attempt, {tag, :started, worker})
        [worker | started]

      {:error, reason} ->
        send(attempt, {tag, :not_started, reason})
        started
    end
  end

  # Stop every process this attempt started beside itself, and wait for
  # each to have stopped. Work that already ended answers at once: a
  # monitor on a process that is gone reports it immediately.
  defp stop_started([]), do: :ok

  defp stop_started(workers) do
    refs =
      Map.new(workers, fn worker ->
        ref = Process.monitor(worker)
        Process.exit(worker, :kill)
        {ref, worker}
      end)

    await_down(refs, now_ms() + @quiesce_ms)
  end

  defp await_down(refs, _deadline) when map_size(refs) == 0, do: :ok

  defp await_down(refs, deadline) do
    receive do
      {:DOWN, ref, :process, _worker, _reason} when is_map_key(refs, ref) ->
        await_down(Map.delete(refs, ref), deadline)
    after
      max(deadline - now_ms(), 0) -> :timeout
    end
  end

  # The attempt's side of the same handshake. A keeper that has already
  # stopped stopped its attempt's work with it, so its absence is an
  # answer.
  defp stop_keeper(nil), do: :ok

  defp stop_keeper(keeper) do
    ref = Process.monitor(keeper)
    send(keeper, {:stop, self()})

    receive do
      {:stopped, ^keeper, answer} ->
        Process.demonitor(ref, [:flush])
        answer

      {:DOWN, ^ref, :process, ^keeper, _reason} ->
        :ok
    after
      @quiesce_ms ->
        Process.demonitor(ref, [:flush])
        :timeout
    end
  end

  @doc """
  Whether the estate's claim still reads this attempt's owner and fence,
  asked before a write the claim's own settle cannot carry.
  """
  @spec holding(String.t(), claim()) :: :ok | {:error, :claim_lost}
  def holding(athanor_id, claim) when is_binary(athanor_id),
    do: holding_actor(actor(athanor_id), claim)

  defp holding_actor(actor, claim) do
    case Claims.current(actor) do
      {:ok, %{owner: owner, fence: fence, outcome: nil}}
      when owner == claim.owner and fence == claim.fence ->
        :ok

      _ ->
        {:error, :claim_lost}
    end
  end

  @doc """
  The claim's own verdict, written only while this attempt still holds
  it. What follows a verdict — the mark, the failure record — is written
  only once it landed.
  """
  @spec settle(String.t(), claim(), String.t(), String.t() | nil) ::
          :ok | {:error, :claim_lost} | {:error, term()}
  def settle(athanor_id, claim, outcome, detail) when is_binary(athanor_id) do
    case Claims.settle(actor(athanor_id), claim.owner, claim.fence, outcome, detail) do
      :ok -> :ok
      :stale -> {:error, :claim_lost}
      {:error, _} = error -> error
    end
  end

  @doc """
  An attempt whose claim a successor took: it marks nothing and records
  nothing, and the estate is the successor's — in progress, not failed.
  """
  @spec lost(String.t()) :: {:error, :provisioning_busy}
  def lost(athanor_id) do
    Logger.warning("[Provisioning] #{athanor_id}: claim lost to a later attempt; nothing written")
    {:error, :provisioning_busy}
  end

  # ---- what a fill asks this module for --------------------------------------

  @doc """
  The athanor row, for a filler that holds only its id. Reading tenancy
  rows is this domain's; the component domain never queries them.
  """
  @spec athanor(String.t()) :: {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  defdelegate athanor(athanor_id), to: Athanors, as: :get

  @doc """
  Every filled athanor a boot's seed sync offers new media to — active,
  and already provisioned.
  """
  @spec filled_athanors() :: [Arca.Schemas.Athanor.t()]
  def filled_athanors do
    for athanor <- Athanors.list_active(), not is_nil(athanor.provisioned_at), do: athanor
  end

  @doc """
  The baseline consents for everything the fill registered, minted under
  the attempt's claim. `:ok` when every vouched local source holds one;
  `{:unminted, refs}` names what did not mint and why.

  A skip for "already bootstrapped" or "not vouched" (a member-authored
  or edited source) is not a provisioning failure: those consent through
  the walk. An agent whose closure the bundle does not resolve is
  re-minted by a later sync once it does.
  """
  @spec bootstrap_consents(Context.t(), claim()) ::
          {:ok, Sanctum.Consent.Bootstrap.result()}
          | {:unminted, [{String.t(), term()}]}
          | {:error, term()}
  def bootstrap_consents(%Context{} = ctx, claim) do
    with {:ok, bootstrap} <- Sanctum.Consent.Bootstrap.run(ctx, claim),
         :ok <- all_minted(bootstrap) do
      {:ok, bootstrap}
    end
  end

  @doc """
  The consents a single install answers for: its own. The walk covers
  every source in the athanor, so a skip belonging to another one is that
  source's business.
  """
  @spec bootstrap_consents_for(Context.t(), claim(), String.t()) :: :ok | {:error, term()}
  def bootstrap_consents_for(%Context{} = ctx, claim, component_ref) do
    case bootstrap_consents(ctx, claim) do
      {:ok, _bootstrap} ->
        :ok

      {:unminted, unminted} ->
        if Enum.any?(unminted, fn {skipped_ref, _reason} ->
             same_component?(skipped_ref, component_ref)
           end),
           do: {:error, {:consent_not_minted, component_ref}},
           else: :ok

      {:error, _} = error ->
        error
    end
  end

  defp all_minted(%{skipped: skipped}) do
    case Enum.reject(skipped, fn {ref, reason} ->
           reason in [:already_bootstrapped, :not_vouched] or Cyfr.AgentRef.agent_ref?(ref)
         end) do
      [] -> :ok
      unminted -> {:unminted, unminted}
    end
  end

  defp same_component?(a, b) do
    with {:ok, a_name} <- Cyfr.ComponentRef.to_name_ref(a),
         {:ok, b_name} <- Cyfr.ComponentRef.to_name_ref(b) do
      a_name == b_name
    else
      _ -> a == b
    end
  end

  @doc """
  Mark the estate filled and tell its subscribers. Called only once the
  claim settled `ready`: announcing a fill that did not finish would have
  every listener read the bundle again and ask for another attempt.
  """
  @spec mark_filled(Arca.Schemas.Athanor.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def mark_filled(athanor) do
    case Athanors.mark_provisioned(athanor) do
      {:ok, filled} ->
        # The estate's own topic, the kind every console subscriber already
        # re-reads the row on: a page rendering "still being prepared" clears
        # itself rather than waiting for a reload.
        Sanctum.Notify.broadcast(filled.id, :athanor_changed, %{name: filled.name})
        {:ok, filled}

      {:error, _} = error ->
        Logger.error("[Provisioning] #{athanor.id} filled but not marked: #{inspect(error)}")
        error
    end
  end

  @doc """
  Record where a fill stopped. The claim settles `failed` first, and the
  row records the failure only once that landed: an attempt whose claim a
  successor took leaves the successor's record alone.
  """
  @spec record_failure(claim(), Arca.Schemas.Athanor.t(), atom(), term()) :: {:error, term()}
  def record_failure(claim, athanor, step, detail) do
    case settle(athanor.id, claim, "failed", "#{step}: #{inspect(detail)}") do
      :ok ->
        Logger.warning(
          "[Provisioning] #{athanor.id} not provisioned at #{step}: #{inspect(detail)}"
        )

        :telemetry.execute([:cyfr, :sanctum, :provisioning, :failed], %{count: 1}, %{
          athanor_id: athanor.id,
          step: step
        })

        Athanors.record_provisioning_failure(athanor, step, inspect(detail))

        {:error, {:provisioning_failed, step, detail}}

      {:error, :claim_lost} ->
        lost(athanor.id)

      {:error, reason} ->
        # The claim could not be read, so whether this attempt still holds
        # it is unknown: the row is left as it is.
        Logger.error(
          "[Provisioning] #{athanor.id} not provisioned at #{step} (#{inspect(detail)}), " <>
            "and the failure not recorded: #{inspect(reason)}"
        )

        {:error, {:provisioning_failed, step, detail}}
    end
  end

  # ---- contexts --------------------------------------------------------------

  @doc """
  The person's context, focused on the athanor: their pull credential,
  their attribution on the minted consents.

  Permissions are stated explicitly per `Context.for_scheduled/2`'s
  convention — never `[:*]`, so what provisioning runs with is visible
  here and cannot silently widen. The path performs storage acts only
  (the seed scan, registration rows, registry pulls into `components/`);
  it never executes a component, and the consent bootstrap mints via
  `granted_via: "bootstrap"`, not through the consent surface gates.
  `auth_method: :oidc` records provenance honestly — this context exists
  because of the person's OIDC sign-in; no gate on this path requires
  the interactive class.
  """
  @spec person_ctx(String.t(), String.t()) :: Context.t()
  def person_ctx(user_id, athanor_id) do
    Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: [:storage_read, :storage_write],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  @doc "The server's own context inside `athanor_id` — what a fill runs as."
  @spec seed_ctx(String.t()) :: Context.t()
  def seed_ctx(athanor_id) do
    Sanctum.internal_context(user_id: "_seed", athanor_id: athanor_id, scope: :athanor)
  end

  # ---- the person's own athanor ----------------------------------------------

  # A person's unprovisioned groups are retried with their credential — the
  # announcement is what starts them, and a fill may pull from the registry,
  # so a sign-in never hangs on an unreachable one. Bounded per sign-in; a
  # failure lands on the group's row and the next sign-in (or a member's
  # `athanor.provision`) tries again.
  @retry_groups_per_sign_in 5

  defp retry_groups(user_id) do
    Athanors.list_for_user(user_id)
    |> Enum.filter(&match?(%{kind: "group", provisioned_at: nil}, &1))
    |> Enum.take(@retry_groups_per_sign_in)
    |> Enum.each(fn group -> request_fill(group, person_ctx(user_id, group.id), "sign_in") end)

    :ok
  end

  # One personal athanor per owner is the store's invariant, so the owner
  # is the lookup; a person with none yet is minted one. The slug is an
  # address on this server, never an identity: the namespace is only a
  # hint for it.
  defp find_or_create_personal(%{id: user_id} = user) do
    case Athanors.get_by_owner(user_id) do
      {:ok, athanor} -> {:ok, athanor}
      {:error, :not_found} -> mint_personal(user)
      {:error, _} = err -> err
    end
  end

  # An operator's own athanor is minted past the server caps
  # (`Athanors.create_for_operator/1`): they are named in
  # `CYFR_PLATFORM_ADMIN_EMAILS` rather than arriving, and a server at
  # capacity must still admit the person who can act on it. Everyone else
  # is a stranger arriving and is capped — `CYFR_MINT_PER_HOUR` is exactly
  # how fast that may happen, and `mint_allowed/0` is its only enforcement,
  # so a refusal here must reach the door rather than being swallowed.
  defp mint_personal(%{id: user_id} = user) do
    name = personal_name(user)

    attrs_for = fn slug ->
      %{kind: "person", name: name, slug: slug, owner_user_id: user_id, created_by: user_id}
    end

    if Sanctum.Tenancy.platform_admin?(user_id) do
      with {:ok, slug} <- Athanors.person_slug(user.namespace, name) do
        Athanors.create_for_operator(attrs_for.(slug))
      end
    else
      with :ok <- mint_allowed(),
           {:ok, slug} <- Athanors.person_slug(user.namespace, name) do
        Athanors.create(attrs_for.(slug))
      end
    end
  end

  # What the athanor is called: the person's screen name, else the
  # address's local part, else the namespace, else a plain word.
  defp personal_name(user) do
    cond do
      is_binary(user.display_name) and String.trim(user.display_name) != "" ->
        String.trim(user.display_name)

      is_binary(user.email) and String.contains?(user.email, "@") ->
        user.email |> String.split("@") |> hd()

      is_binary(user.namespace) ->
        user.namespace

      true ->
        "Me"
    end
  end

  defp record_personal(%{personal_athanor_id: id} = user, %{id: id}), do: {:ok, user}
  defp record_personal(user, athanor), do: Users.set_personal_athanor(user, athanor.id)

  # The mint rate is a per-server cap on personal athanors minted per
  # hour. `check_counted/2` counts only while the cap is on, and refuses
  # (never admits) when the count cannot be answered.
  defp mint_allowed do
    Caps.check_counted(:mint_per_hour, fn ->
      Athanors.count_created_since(DateTime.add(DateTime.utc_now(), -3600))
    end)
  end
end
