# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Memory do
  @moduledoc """
  Who used what: CYFR's record of the memory each person's work used on
  each machine, asked of every Locus endpoint it reaches, and its one read
  (`read/2`).

  ## The endpoints

  Each worker service of `config :cyfr, :locus_runtime_workers`, under
  its service id; the builds service, under `builds`, when this CYFR has
  one; and the backends service its programs box speaks to, under
  `Opus.Programs.local/0`, when it has one and runs no cluster. Each
  answers its own role's report over the pool wire (`Prima.LocusPool`),
  under a key of its own: `Opus.WorkerClient.pool/2`,
  `Compendium.builds_pool/1` and `Opus.Programs.Box.pool/3`. A failed ask
  is asked again at the next poll; an endpoint that starts failing is
  logged once, by its name and reason alone: no key, header or answer
  reaches a log.

  ## The poller

  Every `poll_ms/0` one member of the cell asks every endpoint: the
  member that holds its slot (`Arca.ControlPlane.held?/0`), is the cell's
  proposed owner of `memory:cell` (`Cyfr.Cell.mine?/1`) and holds the
  cell's `memory` claim (`Arca.JobClaims`), leased for three polls. It
  asks after the rev the endpoint's row last stored and pages by rev, at
  most `Prima.LocusPool.max_counters/0` counters of one endpoint in one
  poll, and stores each page under the claim and its slot
  (`Arca.MemoryRecord.store/7`): a lost claim or slot stores and advances
  nothing, and the poll stops there. A page of another boot asked with an
  old cursor stores nothing and starts the endpoint's boot again from 0.
  A counter of a day outside the `memory_retention_days` setting's window
  (before its first day, or after tomorrow) is dropped. Each poll first
  forgets the endpoints it no longer asks (`Arca.MemoryRecord.forget/3`),
  so one taken out of the configuration is no machine of the read.

  Before a page is stored the names of its programs and terminals are
  read from their rows, each in its own athanor's scope
  (`Arca.McpServerStorage.list/1` under `Prima.Actor.in_athanor/1`): a
  row's name, and whether a person reads it as a program, the browser
  (`Opus.Programs.Definition.browser?/1`) or a tool. A counter whose row
  is gone keeps what was read of it before.

  ## The read

  `read(ctx, :mine)` is the person's, for a context scoped to their
  athanor alone: their own athanor's holders and days, and every other
  person's current use on each machine only as one sum, `others`.
  `read(ctx, :everyone)` is the platform administrator's, for a person's
  own context, never a key's, their standing read again from their row
  (`Sanctum.Tenancy.revalidate/1`): every person's holders and days, each
  by the athanor's owner, kind and program name, never a thread or
  content, and `others` 0. These two are the widening across athanors
  ARCHITECTURE.md §5.1 names beside a share. A machine is the endpoints
  that answered within `fresh_ms/0` on one keeper boot, named by its
  worker service's id, else by the backends service's name, else
  `builds`; that boot's holders are what it holds now. An endpoint that
  has not answered within it holds nothing now and joins no machine: the
  read names it under `unanswered` with when it last answered, and a
  machine's `others` is then the others' use at the services that did
  answer. A counter of
  no athanor (the warm floor's fresh runners) was never stored, so a
  machine's holders need not add up to its `used`. A day is a UTC day,
  counted at the keeper.
  """

  use GenServer

  require Logger
  require Prima.TestSeam

  alias Arca.{JobClaims, MemoryRecord}

  @poll_ms 5_000
  @kind "memory"
  @lease_ms 3 * @poll_ms
  @fresh_ms 3 * @poll_ms
  @builds "builds"
  @kinds %{
    "run" => :run,
    "build" => :build,
    "program" => :program,
    "terminal" => :terminal,
    "browser" => :browser,
    "tool" => :tool
  }

  @typedoc "One endpoint: its name, its service and how it is asked for a page."
  @type endpoint :: %{
          name: String.t(),
          service: Prima.LocusPool.service(),
          ask: (non_neg_integer() -> {:ok, Prima.LocusPool.report()} | {:error, term()})
        }

  @typedoc "Whose a holder or a day is: the athanor and the name its person goes by here."
  @type person :: %{athanor: String.t(), name: String.t() | nil}

  @typedoc "What a person reads a holder as."
  @type kind :: :run | :build | :program | :terminal | :browser | :tool

  @type holder :: %{
          person: person(),
          kind: kind(),
          name: String.t() | nil,
          bytes: non_neg_integer()
        }

  @type machine :: %{
          machine: String.t(),
          boot: String.t(),
          budget: non_neg_integer(),
          work: non_neg_integer(),
          floor: non_neg_integer(),
          used: non_neg_integer(),
          others: non_neg_integer(),
          heard_at: DateTime.t(),
          holders: [holder()]
        }

  @typedoc "An endpoint that has not answered within `fresh_ms/0`, and when it last did."
  @type unanswered :: %{endpoint: String.t(), heard_at: DateTime.t()}

  @type day :: %{
          day: Date.t(),
          person: person(),
          kind: kind(),
          name: String.t() | nil,
          mib_ms: non_neg_integer(),
          measured_ms: non_neg_integer(),
          peak_bytes: non_neg_integer(),
          ended: %{cap: non_neg_integer(), machine: non_neg_integer(), either: non_neg_integer()}
        }

  @doc "How often the record is asked of every endpoint, and how often a page reading it reads again."
  @spec poll_ms() :: pos_integer()
  def poll_ms, do: @poll_ms

  @doc """
  How long after its last answer an endpoint counts as answering: three
  polls. One that has not answered within it holds nothing "now" and joins
  no machine, and a refusal names no holder from it.
  """
  @spec fresh_ms() :: pos_integer()
  def fresh_ms, do: @fresh_ms

  @doc """
  The record as `ctx` may read it: `:mine`, the person's own with
  everyone else's as one sum, or `:everyone`, the platform
  administrator's. `machines` are the endpoints that answered within
  `fresh_ms/0`, joined by keeper boot; `unanswered` the others, each by
  its name and when it last answered, holding nothing now.

  `:mine` reads only a context scoped to one athanor, and only that
  athanor's rows: any other is `{:error, :forbidden}`. `:everyone` reads
  only a person's own context, never one bound to a key, and reads the
  person's standing from their row at the call
  (`Sanctum.Tenancy.revalidate/1`): `{:error, :forbidden}` for anyone not
  the platform administrator, `{:error, :unavailable}` when the store
  cannot say.
  """
  @spec read(Sanctum.Context.t(), :mine | :everyone) ::
          {:ok, %{machines: [machine()], days: [day()], unanswered: [unanswered()]}}
          | {:error, term()}
  def read(%Sanctum.Context{scope: :athanor, athanor_id: athanor_id}, :mine)
      when is_binary(athanor_id) and athanor_id != "" do
    actor = Prima.Actor.in_athanor(athanor_id)

    with {:ok, endpoints} <- MemoryRecord.endpoints(actor),
         {:ok, counters} <- MemoryRecord.counters(actor),
         {:ok, others} <- MemoryRecord.others_bytes(actor) do
      {:ok, shape(endpoints, counters, others)}
    end
  end

  def read(%Sanctum.Context{}, :mine), do: {:error, :forbidden}

  def read(%Sanctum.Context{user_id: user_id} = ctx, :everyone)
      when is_binary(user_id) and user_id != "" do
    with false <- Sanctum.Context.key_bound?(ctx),
         {:ok, %Sanctum.Context{platform_admin: true}} <- Sanctum.Tenancy.revalidate(ctx) do
      system = Prima.Actor.system()

      with {:ok, endpoints} <- MemoryRecord.endpoints(system),
           {:ok, counters} <- MemoryRecord.counters(system) do
        {:ok, shape(endpoints, counters, %{})}
      end
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _not_the_administrator -> {:error, :forbidden}
    end
  end

  def read(%Sanctum.Context{}, :everyone), do: {:error, :forbidden}

  # ---------------------------------------------------------------------------
  # The read's shape
  # ---------------------------------------------------------------------------

  defp shape(endpoints, counters, others) do
    people = people(counters)
    now = DateTime.utc_now()

    {answering, silent} =
      Enum.split_with(endpoints, &(DateTime.diff(now, &1.heard_at, :millisecond) <= @fresh_ms))

    %{
      machines: machines(answering, counters, others, people),
      days: days(counters, people),
      unanswered: for(e <- silent, do: %{endpoint: e.endpoint, heard_at: e.heard_at})
    }
  end

  defp people(counters) do
    ids = counters |> Enum.map(& &1.athanor_id) |> Enum.uniq()

    # A record holds a handful of people; each athanor is read once.
    Map.new(ids, fn id ->
      name =
        case Sanctum.Tenancy.Athanors.get(id) do
          {:ok, athanor} -> Map.get(athanor, :slug)
          {:error, _reason} -> nil
        end

      {id, %{athanor: id, name: name}}
    end)
  end

  # The answering endpoints of one keeper boot are one machine.
  defp machines(endpoints, counters, others, people) do
    endpoints
    |> Enum.group_by(& &1.boot)
    |> Enum.map(fn {boot, group} ->
      names = Enum.map(group, & &1.endpoint)
      latest = Enum.max_by(group, & &1.heard_at, DateTime)

      %{
        machine: machine_name(names),
        boot: boot,
        budget: latest.budget,
        work: latest.work,
        floor: latest.floor,
        used: latest.used,
        others: names |> Enum.map(&Map.get(others, &1, 0)) |> Enum.sum(),
        heard_at: latest.heard_at,
        holders: holders(counters, names, boot, people)
      }
    end)
    |> Enum.sort_by(& &1.machine)
  end

  defp machine_name(names) do
    Enum.find(names, &(&1 not in [Opus.Programs.local(), @builds])) ||
      Enum.find(names, &(&1 == Opus.Programs.local())) || @builds
  end

  defp holders(counters, names, boot, people) do
    for c <- counters, c.endpoint in names, c.boot == boot, c.bytes > 0 do
      %{
        person: Map.fetch!(people, c.athanor_id),
        kind: Map.fetch!(@kinds, c.shown),
        name: c.name,
        bytes: c.bytes
      }
    end
    |> Enum.sort_by(&{-&1.bytes, &1.person.athanor, &1.name || ""})
  end

  # A day's counters of one person, kind and subject, across machines and
  # boots, as one: what they used and were measured summed, the most any
  # one held, and the kills for memory by cause.
  defp days(counters, people) do
    counters
    |> Enum.group_by(&{&1.day, &1.athanor_id, &1.shown, &1.subject})
    |> Enum.map(fn {{day, athanor, shown, _subject}, group} ->
      %{
        day: day,
        person: Map.fetch!(people, athanor),
        kind: Map.fetch!(@kinds, shown),
        name: Enum.find_value(Enum.sort_by(group, & &1.rev, :desc), & &1.name),
        mib_ms: sum(group, :mib_ms),
        measured_ms: sum(group, :measured_ms),
        peak_bytes: group |> Enum.map(& &1.peak_bytes) |> Enum.max(),
        ended: %{
          cap: sum(group, :cap),
          machine: sum(group, :machine),
          either: sum(group, :either)
        }
      }
    end)
    |> Enum.sort_by(
      &{Date.to_gregorian_days(&1.day) * -1, &1.person.athanor, &1.kind, &1.name || ""}
    )
  end

  defp sum(group, field), do: group |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()

  # ---------------------------------------------------------------------------
  # The poller
  # ---------------------------------------------------------------------------

  @doc """
  Start the poller. `opts`: `:programs` (`Opus.Programs.start_link/1`'s
  options, whose local box's URL and key it asks unless it runs a
  cluster), `:endpoints` (the endpoints a test asks instead of the
  configured ones), `:owner` (default `Prima.Boot.id/0`) and `:name`. It
  starts only when `:memory_enabled` (default true) or `:endpoints` is
  given.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    # Timer-driven writes from a permanent process poison the test
    # sandbox; a test starts the poller with the endpoints it serves.
    if Keyword.has_key?(opts, :endpoints) or enabled?() do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc """
  One poll, as the poller makes it, under `claim` and the member's
  `slot`: the endpoints it no longer asks forgotten, then every endpoint
  asked and its pages stored until its last, or until the claim or slot
  is lost. Answers each endpoint's outcome by name: the `after` it
  reached, or why it stopped.
  """
  @spec poll([endpoint()], JobClaims.held(), map() | :none) :: %{String.t() => term()}
  def poll(endpoints, %{} = claim, slot) when is_list(endpoints) do
    case MemoryRecord.forget(claim, slot, Enum.map(endpoints, & &1.name)) do
      {:ok, _forgotten} ->
        keep_days = retention_days()

        Enum.reduce_while(endpoints, %{}, fn endpoint, acc ->
          case poll_endpoint(endpoint, claim, slot, keep_days) do
            {:lost, why} -> {:halt, Map.put(acc, endpoint.name, {:lost, why})}
            outcome -> {:cont, Map.put(acc, endpoint.name, outcome)}
          end
        end)

      lost ->
        Map.new(endpoints, &{&1.name, lost_as(lost)})
    end
  end

  defp lost_as(lost) when lost in [:taken, :lapsed], do: {:lost, lost}
  defp lost_as({:error, :not_owner}), do: {:lost, :not_owner}
  defp lost_as({:error, reason}), do: {:unstored, reason}

  defp retention_days do
    {:ok, days} = Arca.PlatformSettings.effective("memory_retention_days")
    days
  end

  @doc """
  The endpoints the poller asks, from the configuration: each worker
  service of `config :cyfr, :locus_runtime_workers` under its id; the
  builds service under `builds` when this CYFR has one
  (`Cyfr.RuntimeConfig.locus_builds_url/0` and `locus_builds_key/0`); and
  the backends service `programs` names (`Opus.Programs.start_link/1`'s
  options) under `Opus.Programs.local/0`, unless this boot runs as a
  cluster.
  """
  @spec endpoints(keyword()) :: [endpoint()]
  def endpoints(programs) when is_list(programs) do
    workers =
      for %{id: id, url: url} = worker <- Application.get_env(:cyfr, :locus_runtime_workers, []),
          is_binary(id) and is_binary(url) do
        %{name: id, service: :runtime, ask: &Opus.WorkerClient.pool(worker, &1)}
      end

    workers ++ builds() ++ backends(programs)
  end

  defp builds do
    if Cyfr.RuntimeConfig.locus_builds_url() && Cyfr.RuntimeConfig.locus_builds_key(),
      do: [%{name: @builds, service: :builds, ask: &Compendium.builds_pool/1}],
      else: []
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :poll)

    {:ok,
     %{
       endpoints:
         Keyword.get_lazy(opts, :endpoints, fn -> endpoints(Keyword.get(opts, :programs, [])) end),
       owner: Keyword.get(opts, :owner, Prima.Boot.id()),
       claim: nil,
       failing: %{}
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    state = tick(state)
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A clean stop gives the claim up, so a successor takes it at once. A
  # stop while an ask is open waits for it no longer than the supervisor's
  # bound: past it the poller is killed without this, and the claim waits
  # out its lease of three polls.
  @impl true
  def terminate(_reason, %{claim: %{} = claim}) do
    _ = JobClaims.release(claim)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp tick(state) do
    with true <- Arca.ControlPlane.held?(),
         true <- Cyfr.Cell.mine?(@kind <> ":" <> JobClaims.cell_key()),
         {:ok, claim} <- claim(state.owner),
         {:ok, slot} <- Arca.ControlPlane.member_slot() do
      outcomes = poll(state.endpoints, claim, slot)
      %{state | claim: claim, failing: failing(outcomes, state.failing)}
    else
      _not_this_member -> %{state | claim: nil}
    end
  end

  # An endpoint that stops answering is logged once, by its name and the
  # reason alone, and again only when the reason changes after it answered
  # or failed otherwise: a service that is down is asked every poll.
  defp failing(outcomes, before) do
    for {name, {:unasked, reason}} <- outcomes, into: %{} do
      if Map.get(before, name) != reason do
        Logger.warning(
          "[Opus.Memory] #{name} did not report who used what: " <>
            Prima.LoggerContext.shape(reason)
        )
      end

      {name, reason}
    end
  end

  # The claim, its lease moved three polls on: a live claim of this owner
  # answers itself unchanged, so it is renewed here.
  defp claim(owner) do
    with {:ok, claim} <- JobClaims.claim(@kind, JobClaims.cell_key(), owner, @lease_ms) do
      JobClaims.renew(claim, @lease_ms)
    end
  end

  defp poll_endpoint(endpoint, claim, slot, keep_days) do
    after_rev = stored_after(endpoint.name)
    pages = div(Prima.LocusPool.max_counters(), Prima.LocusPool.report_counters())
    page(%{endpoint: endpoint, claim: claim, slot: slot, keep_days: keep_days}, after_rev, pages)
  end

  defp page(_poll, after_rev, 0), do: {:ok, after_rev}

  defp page(poll, after_rev, pages) do
    with {:ok, report} <- ask(poll.endpoint, after_rev),
         {:ok, stored} <- store(poll, after_rev, report) do
      case stored do
        %{boot: :new} -> page(poll, 0, pages - 1)
        %{after: next} when report.next != nil -> page(poll, next, pages - 1)
        %{after: next} -> {:ok, next}
      end
    end
  end

  defp ask(endpoint, after_rev) do
    case endpoint.ask.(after_rev) do
      {:ok, report} -> {:ok, report}
      {:error, reason} -> {:unasked, reason}
    end
  end

  defp store(poll, after_rev, report) do
    %{endpoint: endpoint, claim: claim, slot: slot, keep_days: keep_days} = poll

    case MemoryRecord.store(
           claim,
           slot,
           endpoint.name,
           after_rev,
           report,
           names(report),
           keep_days
         ) do
      {:ok, stored} -> {:ok, stored}
      lost when lost in [:taken, :lapsed] -> {:lost, lost}
      {:error, :not_owner} -> {:lost, :not_owner}
      {:error, reason} -> {:unstored, reason}
    end
  end

  defp stored_after(name) do
    with {:ok, rows} <- MemoryRecord.endpoints(Prima.Actor.system()),
         %{after: after_rev} <- Enum.find(rows, &(&1.endpoint == name)) do
      after_rev
    else
      _none -> 0
    end
  end

  # The names of the page's programs and terminals, each read from its
  # row in its own athanor's scope.
  defp names(report) do
    report.counters
    |> Enum.filter(
      &(&1.kind in ~w(program terminal) and is_binary(&1.athanor) and is_binary(&1.subject))
    )
    |> Enum.group_by(& &1.athanor, & &1.subject)
    |> Enum.flat_map(fn {athanor, subjects} ->
      case Arca.McpServerStorage.list(Prima.Actor.in_athanor(athanor)) do
        {:ok, rows} ->
          for row <- rows, row.id in subjects do
            {{athanor, row.id}, %{name: row.name, shown: shown(row)}}
          end

        {:error, _reason} ->
          []
      end
    end)
    |> Map.new()
  end

  defp shown(row) do
    cond do
      Opus.Programs.Definition.browser?(row) -> "browser"
      row.mark == "mcp" -> "tool"
      true -> "program"
    end
  end

  defp backends(programs) do
    url = Keyword.get(programs, :url)
    root = Keyword.get(programs, :root)

    if is_binary(url) and url != "" and is_binary(root) and byte_size(root) == 32 and
         Keyword.get(programs, :cluster) != true,
       do: [
         %{
           name: Opus.Programs.local(),
           service: :backends,
           ask: &Opus.Programs.Box.pool(url, root, &1)
         }
       ],
       else: []
  end

  defp enabled? do
    Prima.TestSeam.value(true, fn -> Application.get_env(:cyfr, :memory_enabled, true) end)
  end
end
