# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.WorkerWatch do
  @moduledoc """
  Hears from each configured worker service, and lapses what a boot the
  cell stopped hearing from, or saw replaced, was running.

  Every poll interval (`config :cyfr, :worker_watch`, `poll_ms`, 5 s by
  default) the watch asks each worker service of `config :cyfr, :workers`
  for its status (`Cyfr.Execution.WorkerClient.status/1`), every entry at
  once, each poll bounded by the client. A status of the contract's shape
  (`Cyfr.WorkerAPI.valid_status?/1`) that names the entry's configured id
  is heard. Anything else is a miss for the entry: an answer the transport
  lost, a worker service it could not reach, a refusal, a status of
  another shape or one naming another service.

  ## Reading is free; writing is claimed

  Every member of the cell polls every worker service, because polling is
  how `fresh_boot/2` saves dispatch a status round trip and how a member
  learns which attempts a worker holds. What is claimed is the right to
  *write*: the `job_claims` row `(kind: "worker_watch", key: <service id>)`
  (`Arca.JobClaims`), leased for twice the poll interval — 10 s at the
  default 5 s poll.

  The fault this closes: a watch that was every member's would let a
  member partitioned from a worker lapse a HEALTHY PEER'S running
  attempts, because it stopped hearing a boot that its peers can still
  hear. Ownership of the watch moves away from a member that cannot see,
  so what it cannot see it cannot settle.

  Three rules do it, and the second is the mechanism:

    1. **A heard status takes and renews the claim.** A member that hears
       the service takes the row when it is free — no row, or a row whose
       lease ran out — and renews it, writing `misses: 0`. Hearing the
       worker is what resets the count, so the count only ever survives
       members that could not hear.
    2. **A miss does not renew.** It writes `misses: n + 1` through
       `Arca.JobClaims.record/2`, which lands while the row still names
       this member at this fence — lease or no lease, because evidence a
       takeover throws away is evidence never worth writing — and leaves
       the lease exactly where it was. So a member that stops hearing a
       worker loses the watch within one lease, and a member that can
       hear takes it over and inherits `misses` from `detail`.
    3. **A miss raises the count only under a live lease.** Past it, the
       member stops counting and waits out a whole further lease before
       taking its own row back. That grace is what a peer that can hear
       the worker uses: it polls at least once per poll interval, and one
       poll interval is half the grace.

  A member partitioned from a worker its peers can reach therefore cannot
  reach the threshold. Its lease stands for at most one poll after its
  last heard status, so at most two of its misses are counted; the third
  falls past the lease, where it counts nothing; and before its grace is
  out, a peer that hears the worker has taken the row and written
  `misses: 0`. Its next miss is answered `:taken` and it stops.

  A worker nobody can reach is still lapsed, which is the point of the
  grace: no peer takes the row, so the last member that heard the service
  takes its own row back after the grace, inherits the count and goes on
  raising it until the threshold.

  ## What a lapse is, and what it is narrowed to

  A boot is gone in one of two ways. Misses in a row up to the configured
  count (`misses`, three by default) mean the service is not answering:
  the running attempts of the boot the claim records are lapsed
  (`Cyfr.Execution.Lapse.boot/3`), and the attempt process open for each
  is stopped without closing its run
  (`Cyfr.Execution.Attempt.stop_unclosed/2`), so its waiter answers the
  lapsed row. Further misses lapse nothing more until a status names a
  boot again. A status naming a boot other than the one the claim records
  means the service restarted: the old boot's running attempts are lapsed
  once, and then the new boot is recorded; the same status again lapses
  nothing.

  The attempts a lapse is asked over are those this member's own last
  status reported together with those open on this member
  (`Cyfr.Execution.Attempt`); the lapse narrows them to the ones
  dispatched to that service on that boot and still running, whichever
  runner claimed them, so an attempt started since the last status is
  covered and an attempt of another boot is never touched. Every member
  polls, so a member that takes the watch over has a status list of its
  own to offer. A lapse the store could not perform is tried again on the
  next miss, or on the next status naming the new boot.

  ## What the claim carries

  `detail` is JSON: the boot the watch records, the consecutive misses
  against it, whether they were already lapsed, and when a status was
  last heard. A takeover leaves `detail` as it found it, so a successor
  inherits the count rather than starting it again and never reaching the
  threshold.

  ## The two clocks

  Whether a lease stands is decided on the cell's clock
  (`Arca.ServerMetaStorage.now!/0`), because two members could disagree
  about it and both would write. The poll interval and the freshness of
  the `fresh_boot/2` entry are bounded local timers on
  `System.monotonic_time/1`, because they only decide how long one member
  waits before asking again.

  ## Publishing what a member heard

  The boot heard within the last poll interval is published for
  `Cyfr.Execution.Dispatch` (`fresh_boot/2`): a start addressed to it
  needs no status of its own first. This is the member's own reading, so
  every member publishes; a miss withdraws it, as does a boot change
  until the claim records the new boot.

  A tick polls only while this member holds its slot in the cell
  (`Arca.ControlPlane.held?/0`), and an answer landing after that standing
  lapsed counts for nothing: the rows are the holder's to settle.

  Started by `Cyfr.Application` with no options, the watch reads its
  worker services from `config :cyfr, :workers` and its bounds from
  `config :cyfr, :worker_watch` (`poll_ms` and `misses`, positive
  integers; any other value refuses the start with the reason), and
  starts only when `config :cyfr, :worker_watch_enabled` is true. That
  key defaults to `config :cyfr, :execution_sweeper_enabled` (itself true
  by default): both are timer-driven detectors that write rows, and a
  configuration that turns off one turns off the other. Started with
  `:workers`, as a test starts it, the watch polls those endpoints
  whatever the gate says; `:poll_ms`, `:misses`, `:lease_ms`, `:owner`
  (the member the claim is taken for, this boot by default) and `:name`
  (an atom, the process's and its table's) override the rest.
  """

  use GenServer

  require Logger

  alias Arca.JobClaims
  alias Cyfr.Execution.{Attempt, Lapse, WorkerClient}
  alias Cyfr.WorkerAPI

  @kind "worker_watch"
  @defaults [poll_ms: 5_000, misses: 3]

  @typedoc """
  The watch's view of one worker service.

    * `boot`, `misses` and `lapsed` are the CELL'S, read from the claim's
      `detail`: the boot the watch records (nil before any member has
      heard one), the consecutive misses against it, and whether they
      were already lapsed. They are what the threshold is measured on.
    * `attempts` and `unheard` are THIS MEMBER'S: the attempts its last
      heard status reported, and how many answers in a row it did not
      hear. `unheard` decides nothing — a member that holds no claim
      counts its own misses and writes none of them.
    * `claimed` is whether this member holds the watch.
  """
  @type seen :: %{
          boot: String.t() | nil,
          attempts: [String.t()],
          misses: non_neg_integer(),
          lapsed: boolean(),
          unheard: non_neg_integer(),
          claimed: boolean()
        }

  @doc """
  Start the watch. `opts`: `:workers` (the endpoints to poll; default
  `config :cyfr, :workers`, and then only when the watch is enabled),
  `:poll_ms` and `:misses` (default `config :cyfr, :worker_watch`, then
  5 000 and 3), `:lease_ms` (default twice the poll interval; see the
  module doc for why the width is what makes a partitioned member
  harmless), `:owner` (default `Cyfr.Boot.id/0`) and `:name` (default
  this module). `{:error, reason}` names the setting that refused the
  start.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    # Timer-driven DB writes from a permanent process poison the test
    # sandbox, the sweeper's reason for its gate; a test starts the watch
    # with the endpoints it serves.
    if Keyword.has_key?(opts, :workers) or enabled?() do
      case settings(opts) do
        {:ok, settings} -> GenServer.start_link(__MODULE__, settings, name: settings.name)
        {:error, _reason} = refused -> refused
      end
    else
      :ignore
    end
  end

  @doc """
  The boot of the worker service at `endpoint` as the watch `name` heard
  it within the last poll interval, or `:unknown`: no watch runs under
  that name, it has not heard from that endpoint, the endpoint's last
  answer was a miss, its boot changed, or the boot it heard is older than
  one interval.
  """
  @spec fresh_boot(WorkerAPI.endpoint(), atom()) :: {:ok, String.t()} | :unknown
  def fresh_boot(%{id: id, url: url}, name \\ __MODULE__) when is_atom(name) do
    case :ets.lookup(name, id) do
      [{^id, ^url, boot, heard_at, poll_ms}] ->
        if System.monotonic_time(:millisecond) - heard_at <= poll_ms,
          do: {:ok, boot},
          else: :unknown

      _other ->
        :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc "The watch's view of each configured worker service (`t:seen/0`), by its id."
  @spec seen(GenServer.server()) :: %{optional(String.t()) => seen()}
  def seen(name \\ __MODULE__), do: GenServer.call(name, :seen)

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(settings) do
    # The claims this watch holds are given up at a clean stop, so a
    # successor takes them at once rather than waiting out a lease.
    Process.flag(:trap_exit, true)

    # Read by dispatch without a call, so a lapse in progress delays no
    # start; owned here, it goes with the watch.
    :ets.new(settings.name, [:named_table, :protected, :set, read_concurrency: true])
    send(self(), :poll)

    {:ok,
     Map.merge(settings, %{
       seen: Map.new(settings.workers, fn {id, _endpoint} -> {id, unheard()} end),
       polls: %{}
     })}
  end

  @impl true
  def handle_call(:seen, _from, state), do: {:reply, state.seen, state}

  @impl true
  def handle_info(:poll, state) do
    state = if Arca.ControlPlane.held?(), do: poll(state), else: state
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info({:polled, poller, answer}, state) do
    case Map.pop(state.polls, poller) do
      {nil, _polls} -> {:noreply, state}
      {id, polls} -> {:noreply, landed(%{state | polls: polls}, id, answer)}
    end
  end

  # A poller's exit follows its answer; one still in flight crashed.
  def handle_info({:DOWN, _ref, :process, poller, reason}, state) do
    case Map.pop(state.polls, poller) do
      {nil, _polls} ->
        {:noreply, state}

      {id, polls} ->
        Logger.error("[Cyfr.Execution.WorkerWatch] the poll of #{id} crashed: #{inspect(reason)}")

        {:noreply, landed(%{state | polls: polls}, id, {:error, :crashed})}
    end
  end

  def handle_info(msg, state) do
    Cyfr.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # A clean stop gives up every watch this member holds, so a successor
  # takes it at once instead of waiting a lease out. `detail` is left
  # exactly as it stands, which is what the successor inherits.
  @impl true
  def terminate(_reason, state) do
    for {id, seen} <- state.seen, seen.claimed do
      with {:ok, %{owner: owner} = claim} <- JobClaims.read(@kind, id),
           true <- owner == state.owner do
        JobClaims.release(claim)
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Polling
  # ---------------------------------------------------------------------------

  # One poller per worker service, in a process of its own so a service
  # that answers slowly delays no other; none for a service whose last poll
  # is still in flight, since the client bounds it and it lands on its own.
  defp poll(state) do
    in_flight = state.polls |> Map.values() |> MapSet.new()
    watch = self()

    Enum.reduce(state.workers, state, fn {id, endpoint}, acc ->
      if MapSet.member?(in_flight, id) do
        acc
      else
        {poller, _monitor} =
          spawn_monitor(fn -> send(watch, {:polled, self(), WorkerClient.status(endpoint)}) end)

        %{acc | polls: Map.put(acc.polls, poller, id)}
      end
    end)
  end

  defp landed(state, id, answer) do
    cond do
      not Arca.ControlPlane.held?() -> state
      heard?(answer, id) -> heard(state, id, elem(answer, 1))
      true -> missed(state, id)
    end
  end

  defp heard?({:ok, status}, id), do: WorkerAPI.valid_status?(status) and status.service == id
  defp heard?(_answer, _id), do: false

  # ---------------------------------------------------------------------------
  # A status this member heard
  # ---------------------------------------------------------------------------

  defp heard(state, id, %{boot: boot, attempts: attempts}) do
    state = put_seen(state, id, %{seen(state, id) | unheard: 0})

    with {:ok, now} <- cell_now(),
         {:ok, row} <- row(id) do
      case take(state, row, id, now) do
        {:ok, claim} -> write_heard(state, id, claim, boot, attempts, now, 1)
        {:busy, claim} -> state |> adopt(id, claim) |> heard_locally(id, boot, attempts)
        _unavailable -> state
      end
    else
      # The store could not answer. Nothing is written and nothing is
      # published: the `fresh_boot/2` entry ages out on its own interval.
      _unavailable -> state
    end
  end

  # The claim to write this status under: the one this member already
  # holds, or a row that is free — no row, or one whose lease ran out.
  # A live claim of a peer is not taken.
  defp take(state, nil, id, _now), do: JobClaims.claim(@kind, id, state.owner, state.lease_ms)

  defp take(state, %{owner: owner} = row, id, now) do
    cond do
      owner == state.owner and live?(row, now) -> {:ok, row}
      live?(row, now) -> {:busy, row}
      true -> JobClaims.claim(@kind, id, state.owner, state.lease_ms)
    end
  end

  # Under the claim, with `retries` attempts left at a lease that ran out
  # between the read and the write (`:lapsed` — nobody took the row, so it
  # is asked for again rather than extended).
  defp write_heard(state, id, claim, boot, attempts, now, retries) do
    recorded = %{detail(claim) | heard_at: DateTime.to_iso8601(now)}

    detail =
      if recorded.boot == nil or recorded.boot == boot,
        do: %{recorded | boot: boot, misses: 0, lapsed: false},
        else: %{recorded | misses: 0}

    case JobClaims.renew(claim, state.lease_ms, detail: encode(detail)) do
      {:ok, held} ->
        state
        |> adopt(id, held)
        |> settle_boot(id, held, recorded, boot, attempts)

      :lapsed when retries > 0 ->
        case JobClaims.claim(@kind, id, state.owner, state.lease_ms) do
          {:ok, again} -> write_heard(state, id, again, boot, attempts, now, retries - 1)
          {:busy, peer} -> state |> adopt(id, peer) |> heard_locally(id, boot, attempts)
          _unavailable -> state
        end

      # A peer holds the row. Nothing issued under the old claim may land,
      # and asking again would take it from a live holder.
      _taken_or_unavailable ->
        state |> drop(id) |> heard_locally(id, boot, attempts)
    end
  end

  # The status is recorded. What is left is the boot change: a status
  # naming a boot other than the one the claim recorded means the service
  # restarted, and the old boot's running attempts lapse once before the
  # new boot is recorded. A lapse the store refused leaves the old boot
  # recorded, so the next status tries again, and no start is addressed to
  # either boot meanwhile.
  defp settle_boot(state, id, held, recorded, boot, attempts) do
    if recorded.boot == nil or recorded.boot == boot do
      state |> heard_locally(id, boot, attempts)
    else
      state = withdraw(state, id)

      if recorded.lapsed or
           lapse_boot(id, recorded.boot, seen(state, id).attempts, "was replaced by #{boot}") do
        case JobClaims.record(held, encode(%{recorded | boot: boot, misses: 0, lapsed: false})) do
          {:ok, done} -> state |> adopt(id, done) |> heard_locally(id, boot, attempts)
          _taken_or_unavailable -> state |> put_attempts(id, attempts)
        end
      else
        put_attempts(state, id, attempts)
      end
    end
  end

  # What this member learned by hearing, whoever holds the claim: the
  # attempts the status reported, and the boot published for dispatch. The
  # boot is published only once the claim records it, so a start is never
  # addressed across an unsettled restart.
  defp heard_locally(state, id, boot, attempts) do
    state = put_attempts(state, id, attempts)
    recorded = seen(state, id).boot

    if recorded == nil or recorded == boot,
      do: publish(state, id, boot),
      else: withdraw(state, id)
  end

  # ---------------------------------------------------------------------------
  # An answer this member did not hear
  # ---------------------------------------------------------------------------

  defp missed(state, id) do
    seen = seen(state, id)
    state = state |> put_seen(id, %{seen | unheard: seen.unheard + 1}) |> withdraw(id)

    with {:ok, now} <- cell_now(),
         {:ok, row} <- row(id) do
      count(state, id, row, now)
    else
      _unavailable -> state
    end
  end

  # A miss never takes a watch this member does not already hold: taking
  # one is what a member that CAN hear the worker does, and a member that
  # took the watch on a miss could count against a peer that is hearing
  # the worker perfectly well.
  defp count(state, id, nil, _now), do: drop(state, id)

  defp count(state, id, %{owner: owner} = row, now) do
    cond do
      owner != state.owner ->
        # The watch is a peer's. Its count is the cell's; this member's
        # own unheard answers are its own business.
        adopt(state, id, row)

      live?(row, now) ->
        bump(state, id, row)

      # Past the lease, and past a whole further lease of grace. No peer
      # that can hear this worker has taken the row in two poll intervals,
      # so there is none: this member takes its own row back, inherits the
      # count from `detail` and goes on raising it. Without this a worker
      # nobody can reach would never be lapsed.
      past_grace?(row, now, state.lease_ms) ->
        case JobClaims.claim(@kind, id, state.owner, state.lease_ms) do
          {:ok, again} -> bump(state, id, again)
          {:busy, peer} -> adopt(state, id, peer)
          _unavailable -> state
        end

      # Past the lease, inside the grace: the count stands still. This is
      # what a peer that can hear the worker uses to take the row over and
      # reset it, and it is why a partitioned member cannot reach the
      # threshold.
      true ->
        adopt(state, id, row)
    end
  end

  # One more consecutive miss against the recorded boot, written without
  # renewing: `record/2` lands while the row still names this member at
  # this fence, so the count survives a takeover, and the lease stays
  # where it was, so the watch moves away from a member that misses.
  defp bump(state, id, claim) do
    recorded = detail(claim)
    misses = recorded.misses + 1
    counted = %{recorded | misses: misses}

    case JobClaims.record(claim, encode(counted)) do
      {:ok, held} ->
        state = adopt(state, id, held)

        if misses >= state.misses and not recorded.lapsed and is_binary(recorded.boot) do
          lapse_recorded(state, id, held, counted)
        else
          state
        end

      _taken_or_unavailable ->
        drop(state, id)
    end
  end

  defp lapse_recorded(state, id, held, counted) do
    why = "answered no status in #{counted.misses} polls"

    if lapse_boot(id, counted.boot, seen(state, id).attempts, why) do
      case JobClaims.record(held, encode(%{counted | lapsed: true})) do
        {:ok, done} -> adopt(state, id, done)
        _taken_or_unavailable -> state
      end
    else
      state
    end
  end

  # ---------------------------------------------------------------------------
  # The lapse
  # ---------------------------------------------------------------------------

  # Lapse the running attempts of `boot` on the service `id`, and stop the
  # attempt process open for each. Answers whether they were lapsed.
  defp lapse_boot(id, boot, reported, why) do
    case Lapse.boot(id, boot, Enum.uniq(reported ++ open_attempts())) do
      {:ok, lapsed} ->
        holder = %{service_id: id, boot_id: boot, runner: nil}
        Enum.each(lapsed, &Attempt.stop_unclosed(&1.attempt, holder))

        Logger.warning(
          "[Cyfr.Execution.WorkerWatch] #{id}: boot #{boot} #{why}; " <>
            "#{length(lapsed)} running attempt(s) lapsed"
        )

        true

      {:error, :unavailable} ->
        Logger.error(
          "[Cyfr.Execution.WorkerWatch] #{id}: boot #{boot} #{why}; its running attempts " <>
            "could not be lapsed"
        )

        false
    end
  end

  # The attempts open on this member: `Cyfr.Execution.Attempt` registers
  # each under its execution's id, with the attempt's id as the value.
  defp open_attempts do
    Attempt.Registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
  end

  # ---------------------------------------------------------------------------
  # The claim row
  # ---------------------------------------------------------------------------

  defp row(id) do
    case JobClaims.read(@kind, id) do
      {:ok, claim} -> {:ok, claim}
      {:error, :not_found} -> {:ok, nil}
      {:error, :database_error} -> :unavailable
    end
  end

  # The cell's clock, which decides whose lease stands. A store that
  # cannot answer it stops this tick: a lease decision taken on a clock
  # that could not be read is the one thing that must not happen quietly.
  defp cell_now do
    {:ok, Arca.ServerMetaStorage.now!()}
  rescue
    _exception -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp live?(%{lease_until: until}, now), do: DateTime.compare(until, now) == :gt

  defp past_grace?(%{lease_until: until}, now, lease_ms),
    do: DateTime.compare(now, DateTime.add(until, lease_ms, :millisecond)) == :gt

  defp detail(%{detail: nil}), do: recorded()

  defp detail(%{detail: json}) do
    case Jason.decode(json) do
      {:ok, %{"misses" => misses} = map} when is_integer(misses) and misses >= 0 ->
        %{
          boot: boot_of(map),
          misses: misses,
          lapsed: Map.get(map, "lapsed") == true,
          heard_at: Map.get(map, "heard_at")
        }

      _other ->
        recorded()
    end
  end

  defp boot_of(%{"boot" => boot}) when is_binary(boot), do: boot
  defp boot_of(_map), do: nil

  defp recorded, do: %{boot: nil, misses: 0, lapsed: false, heard_at: nil}

  # `heard_at` is evidence for whoever reads the row — an operator, or a
  # successor deciding how old the count it inherited is. Nothing compares
  # it, so it is not a lease decision and carries no clock rule of its own.
  defp encode(%{boot: boot, misses: misses, lapsed: lapsed, heard_at: heard_at}) do
    Jason.encode!(%{
      "boot" => boot,
      "misses" => misses,
      "lapsed" => lapsed,
      "heard_at" => heard_at
    })
  end

  # ---------------------------------------------------------------------------
  # This member's view
  # ---------------------------------------------------------------------------

  defp seen(state, id), do: Map.fetch!(state.seen, id)

  defp put_seen(state, id, seen), do: %{state | seen: Map.put(state.seen, id, seen)}

  defp put_attempts(state, id, attempts),
    do: put_seen(state, id, %{seen(state, id) | attempts: attempts})

  # The cell's record of this service, as the row reads now.
  defp adopt(state, id, claim) do
    recorded = detail(claim)

    put_seen(state, id, %{
      seen(state, id)
      | boot: recorded.boot,
        misses: recorded.misses,
        lapsed: recorded.lapsed,
        claimed: claim.owner == state.owner
    })
  end

  # This member holds no claim, and knows nothing of the cell's record.
  defp drop(state, id), do: put_seen(state, id, %{seen(state, id) | claimed: false})

  defp publish(state, id, boot) do
    %{url: url} = Map.fetch!(state.workers, id)

    :ets.insert(
      state.name,
      {id, url, boot, System.monotonic_time(:millisecond), state.poll_ms}
    )

    state
  end

  defp withdraw(state, id) do
    :ets.delete(state.name, id)
    state
  end

  defp unheard,
    do: %{boot: nil, attempts: [], misses: 0, lapsed: false, unheard: 0, claimed: false}

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  defp enabled? do
    Application.get_env(
      :cyfr,
      :worker_watch_enabled,
      Application.get_env(:cyfr, :execution_sweeper_enabled, true)
    )
  end

  defp settings(opts) do
    with {:ok, name} <- name(Keyword.fetch!(opts, :name)),
         {:ok, configured} <- configured_bounds(),
         bounds = Keyword.merge(configured, Keyword.take(opts, [:poll_ms, :misses, :lease_ms])),
         {:ok, poll_ms} <- bound(bounds, :poll_ms),
         {:ok, misses} <- bound(bounds, :misses),
         {:ok, lease_ms} <- lease(bounds, poll_ms),
         {:ok, workers} <-
           workers(
             Keyword.get_lazy(opts, :workers, fn -> Application.get_env(:cyfr, :workers, []) end)
           ) do
      {:ok,
       %{
         name: name,
         poll_ms: poll_ms,
         misses: misses,
         lease_ms: lease_ms,
         owner: Keyword.get_lazy(opts, :owner, &Cyfr.Boot.id/0),
         workers: workers
       }}
    end
  end

  defp name(name) when is_atom(name) and not is_nil(name), do: {:ok, name}
  defp name(other), do: {:error, "worker watch: the name must be an atom, got #{inspect(other)}"}

  defp configured_bounds do
    case Application.get_env(:cyfr, :worker_watch, []) do
      bounds when is_list(bounds) ->
        if Keyword.keyword?(bounds),
          do: {:ok, bounds},
          else: {:error, "worker watch: config :cyfr, :worker_watch must be a keyword list"}

      other ->
        {:error,
         "worker watch: config :cyfr, :worker_watch must be a keyword list, got #{inspect(other)}"}
    end
  end

  defp bound(bounds, key) do
    case Keyword.get(bounds, key, Keyword.fetch!(@defaults, key)) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      other ->
        {:error, "worker watch: #{key} must be a positive integer, got #{inspect(other)}"}
    end
  end

  # Twice the poll interval, so a member that hears the worker renews with
  # a whole poll of headroom and a member that stops hearing loses the
  # watch after two polls at the most. See the module doc.
  defp lease(bounds, poll_ms) do
    case Keyword.get(bounds, :lease_ms, poll_ms * 2) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      other ->
        {:error, "worker watch: lease_ms must be a positive integer, got #{inspect(other)}"}
    end
  end

  # The endpoints by id, each as `Cyfr.Execution.Dispatch` reads it.
  defp workers(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{id: id, url: url} = entry, {:ok, acc} when is_binary(id) and is_binary(url) ->
        if Map.has_key?(acc, id),
          do: {:halt, {:error, "worker watch: two worker entries name the service #{id}"}},
          else: {:cont, {:ok, Map.put(acc, id, Map.put_new(entry, :components, nil))}}

      other, _acc ->
        {:halt, {:error, "worker watch: a worker entry is not an endpoint: #{inspect(other)}"}}
    end)
  end

  defp workers(other),
    do: {:error, "worker watch: the worker list must be a list, got #{inspect(other)}"}
end
