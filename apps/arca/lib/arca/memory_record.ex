# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MemoryRecord do
  @moduledoc """
  The record of who used what: what each Locus service's keeper counted
  of each athanor's work (`Prima.LocusPool`, "Who used what"), as CYFR
  asked each endpoint for it (`Opus.Memory`). It holds a person's
  athanor, the kind of work, the name of the program it ran and the UTC
  day, and no content. Each counter is its athanor's row; the two reads
  across athanors (`counters/1` for a platform actor, `others_bytes/1`)
  are the widening ARCHITECTURE.md §5.1 names beside a share.

  ## The rows

  A counter (`memory_counters`) is its athanor's row, keyed by the
  athanor first, then the endpoint that reported it, the keeper's boot,
  the day, the keeper's kind and its subject (the empty string for none).
  `rev` is its role's at the counter's last change; `shown` is what a
  person reads it as (`shown/0`) and `name` the subject's row's name,
  both as CYFR read them when it stored the counter and kept after the
  row is gone. An endpoint (`memory_endpoints`) is the host's own row: the
  boot it last answered for, the rev the next ask follows (`after`) and
  the machine's numbers and wall its last answer carried.

  ## Storing a page

  `store/7` writes one page of one endpoint's report in one locking
  transaction, under the poller's member's slot and its claim: the slot
  verified live as every holder-only write is (`Arca.Repo.owned/3`), then
  the claim held (`Arca.JobClaims.hold/1`) and judged on the clock read
  after its lock was won. A lost claim or slot stores and advances
  nothing. Then the endpoint's row, locked:

    * A page asked after the row's own `after`, of the row's own boot, is
      stored. One asked after 0 is stored whatever boot the row names, and
      so is the first page an endpoint ever answers.
    * A page of another boot asked after a rev of the old one stores no
      counter: the old cursor means nothing in the new boot, whose
      counters past that number would be taken for later ones. The row
      takes the new boot and `after` 0, so the next ask reads the boot
      from its start.
    * A page asked after another `after` than the row's is another
      writer's, and stores nothing (`{:error, :moved}`).

  A counter with no athanor, of an athanor this CYFR does not hold, or of
  a day outside the retention's window (before the first of its last
  `keep_days` days on the database's clock, or after tomorrow) is
  dropped, so nothing escapes the purge and a re-read from 0 cannot store
  a purged day again. Any other replaces the stored counter of its key only with a
  higher `rev`; a lower or equal one changes nothing. Every counter of
  the page moves `after`, dropped or not, and the endpoint's row takes
  the machine's numbers, its wall and the database's time it was heard at.

  ## Reading

  `endpoints/2` answers every endpoint's row, to any caller: a machine's
  numbers are the same a refusal's `held` already shows. `counters/1`
  answers an athanor actor's own counters, and every athanor's only to a
  platform actor. `others_bytes/1` answers, for each endpoint, what every
  other athanor's counters of its current boot hold now, as one sum and
  nothing else. `purge/2` deletes the counters of days before a day, in
  every athanor, for a platform actor alone. `forget/3` deletes, under
  the poller's claim and slot, the endpoints it no longer asks.
  """

  import Ecto.Query

  alias Arca.Repo.Errors
  alias Arca.Schemas.{Athanor, MemoryCounter, MemoryEndpoint}

  @none ""
  @shown %{
    "warm" => "run",
    "run" => "run",
    "build" => "build",
    "program" => "program",
    "terminal" => "terminal"
  }
  @shown_names ~w(run build program terminal browser tool)
  @numbers ~w(bytes mib_ms measured_ms peak_bytes cap machine either)a

  defguardp resolved(athanor_id) when is_binary(athanor_id) and athanor_id != ""
  defguardp platform(actor) when is_struct(actor, Prima.Actor) and actor.scope == :platform

  @typedoc """
  What CYFR read of a subject's row when it stored the counter: its name
  and what a person reads it as, keyed by athanor and subject.
  """
  @type names :: %{{String.t(), String.t()} => %{name: String.t(), shown: String.t()}}

  @typedoc "A stored counter, as `counters/1` answers it."
  @type counter :: %{
          athanor_id: String.t(),
          endpoint: String.t(),
          boot: String.t(),
          day: Date.t(),
          kind: String.t(),
          subject: String.t() | nil,
          rev: pos_integer(),
          shown: String.t(),
          name: String.t() | nil,
          bytes: non_neg_integer(),
          mib_ms: non_neg_integer(),
          measured_ms: non_neg_integer(),
          peak_bytes: non_neg_integer(),
          cap: non_neg_integer(),
          machine: non_neg_integer(),
          either: non_neg_integer()
        }

  @typedoc "An endpoint's row, as `endpoints/2` answers it."
  @type endpoint :: %{
          endpoint: String.t(),
          boot: String.t(),
          after: non_neg_integer(),
          budget: non_neg_integer(),
          work: non_neg_integer(),
          floor: non_neg_integer(),
          used: non_neg_integer(),
          wall: Prima.LocusPool.wall(),
          heard_at: DateTime.t(),
          answering: boolean()
        }

  @doc "What a person may read a counter as: a run, a build, a program, a terminal, the browser or a tool."
  @spec shown() :: [String.t()]
  def shown, do: @shown_names

  @doc """
  Store `report`, the page `endpoint` answered to an ask after `after`,
  under `claim` and the member's `slot`, with `names` for the subjects
  CYFR read rows of. Answers the `after` the next ask follows and how
  many counters were stored and dropped; `boot: :new` when the page was
  of another boot than an old cursor's and stored nothing. `:taken` and
  `:lapsed` mean the claim is no longer this poller's, and
  `{:error, :not_owner}` that the member lost its slot, each with nothing
  written; `{:error, :moved}` that another writer moved the cursor.
  """
  @spec store(
          Arca.JobClaims.held(),
          map() | :none,
          String.t(),
          non_neg_integer(),
          Prima.LocusPool.report(),
          names(),
          pos_integer()
        ) ::
          {:ok,
           %{after: non_neg_integer(), stored: non_neg_integer(), dropped: non_neg_integer()}}
          | {:ok, %{after: 0, boot: :new}}
          | Arca.JobClaims.lost()
          | {:error, :not_owner | :moved | :database_error}
  def store(%{} = claim, slot, endpoint, after_rev, %{boot: boot} = report, names, keep_days)
      when is_binary(endpoint) and endpoint != "" and is_integer(after_rev) and after_rev >= 0 and
             is_binary(boot) and is_map(names) and is_integer(keep_days) and keep_days > 0 do
    # The member's slot first, as every holder-only write is fenced
    # (`Arca.Repo.owned/3`), then the claim, judged on the clock read after
    # its row's lock was won.
    "Arca.MemoryRecord.store"
    |> Arca.Repo.owned(slot, fn ->
      store!(claim, endpoint, after_rev, report, names, keep_days)
    end)
    |> case do
      {:ok, stored} -> {:ok, stored}
      {:error, lost} when lost in [:taken, :lapsed] -> lost
      {:error, reason} -> {:error, reason}
    end
  end

  # arca:db-raise-ok a step inside the store's own transaction; a refusal rolls it back.
  defp store!(claim, endpoint, after_rev, report, names, keep_days) do
    with {:ok, _held} <- Arca.JobClaims.hold(claim) do
      now = Arca.ServerMetaStorage.now!()
      today = DateTime.to_date(now)
      window = Date.range(Date.add(today, -(keep_days - 1)), Date.add(today, 1))

      case cursor(locked_endpoint(endpoint), report.boot, after_rev) do
        :store ->
          {stored, dropped} = put_counters!(endpoint, report, names, window)
          next = report.counters |> Enum.map(& &1.rev) |> Enum.max(fn -> after_rev end)
          put_endpoint!(endpoint, report, next, now)
          {:ok, %{after: next, stored: stored, dropped: dropped}}

        :new_boot ->
          put_endpoint!(endpoint, report, 0, now)
          {:ok, %{after: 0, boot: :new}}

        :moved ->
          {:error, :moved}
      end
    else
      lost when lost in [:taken, :lapsed] -> {:error, lost}
    end
  end

  # arca:unscoped-ok the host's own row of one endpoint, which no athanor holds.
  defp locked_endpoint(endpoint) do
    from(e in MemoryEndpoint, where: e.endpoint == ^endpoint)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp cursor(_row, _boot, 0), do: :store
  defp cursor(nil, _boot, _after), do: :moved
  defp cursor(%{boot: boot, after: after_rev}, boot, after_rev), do: :store
  defp cursor(%{boot: boot}, boot, _after), do: :moved
  defp cursor(%{}, _another_boot, _after), do: :new_boot

  defp put_counters!(endpoint, report, names, window) do
    known = held_athanors(report.counters)

    Enum.reduce(report.counters, {0, 0}, fn counter, {stored, dropped} ->
      if MapSet.member?(known, counter.athanor) and counter.day in window do
        put_counter!(endpoint, report.boot, counter, names)
        {stored + 1, dropped}
      else
        {stored, dropped + 1}
      end
    end)
  end

  # The athanors of the page this CYFR holds. A counter with none, or of
  # one it does not hold, is dropped.
  # arca:unscoped-ok an existence check over the page's own athanor ids, reading nothing of any athanor's rows.
  defp held_athanors(counters) do
    ids = for %{athanor: id} <- counters, resolved(id), uniq: true, do: id

    if ids == [],
      do: MapSet.new(),
      else:
        from(a in Athanor, where: a.id in ^ids, select: a.id) |> Arca.Repo.all() |> MapSet.new()
  end

  defp put_counter!(endpoint, boot, counter, names) do
    subject = counter.subject || @none
    key = [counter.athanor, endpoint, boot, counter.day, counter.kind, subject]
    read = Map.get(names, {counter.athanor, subject})

    case stored_rev(key) do
      nil ->
        row =
          %{
            athanor_id: counter.athanor,
            endpoint: endpoint,
            boot: boot,
            day: counter.day,
            kind: counter.kind,
            subject: subject,
            rev: counter.rev,
            shown: shown(read, counter.kind),
            name: read && read.name
          }
          |> Map.merge(Map.take(counter, @numbers))

        {1, _} = Arca.Repo.insert_all(MemoryCounter, [row])

      rev when rev >= counter.rev ->
        :ok

      # What CYFR read of the row is kept when the row is gone.
      _lower ->
        set =
          [rev: counter.rev] ++
            Map.to_list(Map.take(counter, @numbers)) ++
            if(read, do: [shown: shown(read, counter.kind), name: read.name], else: [])

        {1, _} = key |> counter_query() |> Arca.Repo.update_all(set: set)
    end

    :ok
  end

  defp shown(%{shown: shown}, kind) when kind in ~w(program terminal) and shown in @shown_names,
    do: if(kind == "terminal", do: "terminal", else: shown)

  defp shown(_read, kind), do: Map.fetch!(@shown, kind)

  defp stored_rev(key) do
    key
    |> counter_query()
    |> select([c], c.rev)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp counter_query([athanor_id, endpoint, boot, day, kind, subject]) do
    from(c in MemoryCounter,
      where:
        c.endpoint == ^endpoint and c.boot == ^boot and c.day == ^day and c.kind == ^kind and
          c.subject == ^subject
    )
    |> Arca.QueryHelpers.where_athanor(athanor_id)
  end

  # arca:unscoped-ok the host's own row of one endpoint, which no athanor holds.
  defp put_endpoint!(endpoint, report, after_rev, now) do
    row = %{
      endpoint: endpoint,
      boot: report.boot,
      after: after_rev,
      budget: report.budget,
      work: report.work,
      floor: report.floor,
      used: report.used,
      wall: report.wall,
      heard_at: now
    }

    Arca.Repo.insert_all(MemoryEndpoint, [row],
      on_conflict: {:replace, ~w(boot after budget work floor used wall heard_at)a},
      conflict_target: [:endpoint]
    )
  end

  @doc """
  Delete, under `claim` and the member's `slot` as `store/7` writes, every
  endpoint's row whose name is not in `asked`: the endpoints the poller no
  longer asks, so none of them is read as a machine. Their counters stay
  as their days, until the purge. Answers how many went, or the claim or
  slot lost, with nothing deleted.
  """
  @spec forget(Arca.JobClaims.held(), map() | :none, [String.t()]) ::
          {:ok, non_neg_integer()}
          | Arca.JobClaims.lost()
          | {:error, :not_owner | :database_error}
  def forget(%{} = claim, slot, asked) when is_list(asked) do
    "Arca.MemoryRecord.forget"
    |> Arca.Repo.owned(slot, fn -> forget!(claim, asked) end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, lost} when lost in [:taken, :lapsed] -> lost
      {:error, reason} -> {:error, reason}
    end
  end

  # arca:unscoped-ok the host's own rows of the endpoints the poller no longer asks.
  defp forget!(claim, asked) do
    with {:ok, _held} <- Arca.JobClaims.hold(claim) do
      {count, _} =
        Arca.Repo.delete_all(from(e in MemoryEndpoint, where: e.endpoint not in ^asked))

      {:ok, count}
    else
      lost when lost in [:taken, :lapsed] -> {:error, lost}
    end
  end

  @doc """
  Every endpoint's row: the machine's numbers its last answer carried,
  the boot it was of, when it was heard, and whether it answered within
  `bound_ms` (`answering`), judged on the database's clock, the one that
  stamped `heard_at`, never a member's. A machine's numbers are the whole
  machine's, as a refusal's `held` shows them to anyone, so any resolved
  actor reads them.
  """
  @spec endpoints(Prima.Actor.t(), pos_integer()) ::
          {:ok, [endpoint()]} | {:error, :no_athanor | term()}
  def endpoints(%Prima.Actor{} = actor, bound_ms)
      when (platform(actor) or resolved(actor.athanor_id)) and is_integer(bound_ms) and
             bound_ms > 0 do
    Errors.with_db_rescue("Arca.MemoryRecord.endpoints", fn ->
      {:ok, judged_endpoints(bound_ms)}
    end)
  end

  def endpoints(%Prima.Actor{}, _bound_ms), do: {:error, :no_athanor}

  # Every endpoint's row with whether it answered within `bound_ms`: the
  # one comparison of an answer's age, on the database's clock.
  # arca:unscoped-ok the host's own rows of its endpoints, which no athanor holds.
  defp judged_endpoints(bound_ms) do
    since = DateTime.add(Arca.ServerMetaStorage.now!(), -bound_ms, :millisecond)

    from(e in MemoryEndpoint, order_by: e.endpoint)
    |> Arca.Repo.all()
    |> Enum.map(fn row ->
      row |> endpoint_map() |> Map.put(:answering, DateTime.compare(row.heard_at, since) != :lt)
    end)
  end

  @doc """
  The counters an actor may read: an athanor actor's own, every
  athanor's to a platform actor.
  """
  @spec counters(Prima.Actor.t()) :: {:ok, [counter()]} | {:error, :no_athanor | term()}
  def counters(%Prima.Actor{} = actor) when platform(actor) do
    Errors.with_db_rescue("Arca.MemoryRecord.counters", fn ->
      # arca:unscoped-ok a platform actor reads every athanor's counters, the administrator's
      # widening ARCHITECTURE.md §5.1 names; `Opus.Memory.read/2` builds one only for a person
      # whose standing as the administrator it read from their row at the call.
      {:ok, from(c in MemoryCounter, order_by: [desc: c.day]) |> Arca.Repo.all() |> rows()}
    end)
  end

  def counters(%Prima.Actor{athanor_id: athanor_id}) when resolved(athanor_id) do
    Errors.with_db_rescue("Arca.MemoryRecord.counters", fn ->
      rows =
        from(c in MemoryCounter, order_by: [desc: c.day])
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, rows(rows)}
    end)
  end

  def counters(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  For each endpoint, the bytes every athanor but the actor's holds now on
  its current boot, as one sum: no athanor, kind, subject or name of
  theirs.
  """
  @spec others_bytes(Prima.Actor.t()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, :no_athanor | term()}
  def others_bytes(%Prima.Actor{athanor_id: athanor_id}) when resolved(athanor_id) do
    Errors.with_db_rescue("Arca.MemoryRecord.others_bytes", fn ->
      # arca:unscoped-ok one sum per endpoint of every other athanor's current bytes, a person's
      # widening ARCHITECTURE.md §5.1 names: no other athanor's row leaves it.
      sums =
        from(c in MemoryCounter,
          join: e in MemoryEndpoint,
          on: e.endpoint == c.endpoint and e.boot == c.boot,
          where: c.athanor_id != ^athanor_id,
          group_by: c.endpoint,
          select: {c.endpoint, sum(c.bytes)}
        )
        |> Arca.Repo.all()

      {:ok, Map.new(sums, fn {endpoint, sum} -> {endpoint, whole(sum)} end)}
    end)
  end

  def others_bytes(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  Delete the counters of days before `before`, in every athanor, and the
  endpoints last heard before that day began, answering how many rows
  went. Platform scope only.
  """
  @spec purge(Prima.Actor.t(), Date.t()) ::
          {:ok, non_neg_integer()} | {:error, :cross_tenant | term()}
  # arca:unscoped-ok the record's days, purged by age alone: a day past retention is no athanor's to keep.
  def purge(actor, %Date{} = before) when platform(actor) do
    Errors.with_db_rescue("Arca.MemoryRecord.purge", fn ->
      since = DateTime.new!(before, ~T[00:00:00.000000], "Etc/UTC")
      {counters, _} = Arca.Repo.delete_all(from(c in MemoryCounter, where: c.day < ^before))
      {endpoints, _} = Arca.Repo.delete_all(from(e in MemoryEndpoint, where: e.heard_at < ^since))
      {:ok, counters + endpoints}
    end)
  end

  def purge(%Prima.Actor{}, %Date{}), do: {:error, :cross_tenant}

  defp rows(rows), do: Enum.map(rows, &counter_map/1)

  defp counter_map(%MemoryCounter{} = c) do
    c
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Map.update!(:subject, fn
      @none -> nil
      subject -> subject
    end)
  end

  defp endpoint_map(%MemoryEndpoint{} = e), do: e |> Map.from_struct() |> Map.delete(:__meta__)

  # A sum is a decimal on PostgreSQL and an integer on SQLite.
  defp whole(%Decimal{} = sum), do: Decimal.to_integer(sum)
  defp whole(sum) when is_integer(sum), do: sum
  defp whole(nil), do: 0
end
