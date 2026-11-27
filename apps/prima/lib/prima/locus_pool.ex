# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusPool do
  @moduledoc """
  The pool's fixed numbers: the one memory bound all of a machine's Locus
  work shares, what it keeps for the warm floor, and what each kind of work
  is charged and bounded at. Data only: no process, no file and no
  environment.

  The keeper (`cyfr-locus serve`) holds every spawn of every role under one
  group, `work`, bounded at W: the machine's memory less the reserve for
  CYFR itself (`LOCUS_CORE_RESERVE_BYTES`), or the container's own limit
  where that is less, less the services' share (`LOCUS_SERVICE_BYTES`),
  never below 0. Inside it every role's spawns but the runtime's are held
  under `rest`, at W less F, the floor's memory (`floor_bytes/0`), so
  builds and programs alone never reach the floor's runner.

  The keeper is the one admission of that work. Each place's kind has a
  class (`kinds/0`): a runner, a build or a session. A start is admitted
  when its class's allowance (`allowance_bytes/1`) fits what W leaves, in
  arrival order; it is charged at least that allowance until
  `allowance_ms/0` after its spawn, then its reading, and a place with no
  reading for `stale_ms/0` no less than its last charge. One that finds no
  room within `room_wait_ms/0`, the close's own wait, is refused. The
  keeper sets every spawn's bounds by its class, and no client names one: a
  build's memory is `build_cap_bytes/0`, a runner's and a session's half of
  W, never under `least_cap_bytes/1`, and each class's processors are
  `processors/1`.

  A runner's least is its allowance and the components' hard ceiling
  together (`Prima.Limits.Ceiling`'s compiled `max_memory_bytes`), so one
  component at any cap an administrator may allow fits beside its runner on
  every machine, and on a machine with room a chain of several fits too.
  A limit: a chain that runs several large components at once on a small
  machine ends at the runner's cap.

  A start refused for room carries what holds the pool (`t:held/0`), in
  one wire form every wire that passes it on speaks (`encode_held/1`,
  `read_held/1`): what the start needs and what was free, the charges of
  the asking place's own athanor's places, each with its `subject` only
  where the place is the asking role's, and everyone else's as one sum,
  `others_bytes`. No other athanor's name, subject or holding is in it.
  `refusal_sentence/2` is the one sentence a person reads of it, for
  every kind of start, built from `held` and the names CYFR read for its
  subjects.

  The keeper's Go reads this module's values from
  `tests/fixtures/locus_pool.json`, which `Prima.LocusPoolTest` holds to
  them.

  ## Who used what

  The keeper alone counts, once, what each place used (`t:counter/0`): by
  the role that made the place, the UTC day, athanor, kind and subject.
  Each successful reading adds the time since that place's previous one,
  at most `reading_gap_ms/0`, to `measured_ms`, and that time multiplied
  by the reading's bytes to `mib_ms`; the first reading adds nothing and a
  longer gap goes uncounted. A counter's `bytes` is the sum of its places'
  latest readings, real use and not a charge, so during a start's first
  `allowance_ms/0` it shows less than the start is charged; `peak_bytes`
  is the most it held. A kill for memory is counted at the release, once,
  in `cap`, `machine` or `either`, on the counter of whoever held the place
  then, whether or not a reading followed. A place moved to another kind,
  athanor or subject takes its bytes along, and at a day's end every live
  place's bytes move to that day's counter, so the day before goes to 0.
  Every change of a counter takes its role's next `rev`, one sequence per
  role for the keeper's boot. A counter goes `keep_ms/0` after its last
  change. At most `max_counters/0` are held: making another first drops
  the oldest counter of a past day that holds nothing, and when today's
  alone fill them the new one is not made and its use goes uncounted. A
  counter of today is never dropped.

  A role's report (`t:report/0`, `read_report/1`, `encode_report/1`) holds
  the counters of its own places alone, at most `report_counters/0` by
  rev after the one asked for, `next` naming the last when more follow,
  beside the machine's numbers: the keeper's `boot`, its `budget`, `work`
  (W), `floor` (F, where kept) and `used`, every charge outside the floor,
  the sum a refusal's `free` is taken from. The keeper's boot id is minted
  at its start, random: a restart of the keeper starts every counter and
  rev again under another boot; a restart of a role process keeps them.

  ## The pool wire

  Each Locus service, runtime, builds and backends, serves its role's
  report at `POST #{"/locus/v1/pool"}` (`route/0`). The body is
  `{"v": 1, "after": rev}` (`request_body/1`, `read_request_body/1`), read
  within `max_request_bytes/0`; the answer `{"v": 1, "report": report}`
  (`answer/1`, `read_answer/1`). A request is signed, carried in
  `x-cyfr-auth`, as `Prima.MacEnvelope` signs: the prefix
  `cyfr-locus/v1/<service>/pool`, the kind `pool`, the field `ts` and the
  body's hash, within `window_ms/0` of the listener's clock
  (`header/4`, `verify_header/4`, `verify_body/2`). No nonce is kept: the
  call reads only. The key is the **pool key**, derived over the same
  label from the key the service is given (`pool_key/2`): the builds
  service's `LOCUS_BUILDS_KEY`, through its request key
  (`Prima.BuilderProtocol.request_key/1`), which is all the builds service
  holds of it; the backends service's `LOCUS_BACKENDS_KEY`; a worker
  service's `LOCUS_RUNTIME_KEY` (`Prima.WorkerAuth.worker_key/2` of CYFR's
  root). CYFR and every test derive it from the given key with
  `pool_key/2`; each listener derives it from the key it holds with
  `held_pool_key/2`, the one definition `pool_key/2` takes its last step
  through.
  It signs and verifies this route at that one service and nothing else:
  no other verifier takes a key derived over a `/pool` label, and the key
  gives neither the service's own nor any other key derived from it. The
  label names the service, so a pool header of one service is refused by
  the two others even where all three were given the same key. The answer
  is plain, as every answer a Locus service gives CYFR is: CYFR reads it on
  the connection it made, so an attacker inside the island's network could
  feed CYFR a false report, as it could a false build.
  """

  @mib 1024 * 1024
  @floor_bytes 164 * @mib
  @kinds %{
    "warm" => :runner,
    "run" => :runner,
    "build" => :build,
    "program" => :session,
    "terminal" => :session
  }
  @allowance_bytes %{runner: @floor_bytes, build: 800 * @mib, session: 384 * @mib}
  @build_cap_bytes 1024 * @mib
  @least_cap_bytes %{
    runner: @allowance_bytes.runner + Prima.Limits.Ceiling.lowered(%{}).max_memory_bytes,
    session: @allowance_bytes.session
  }
  @processors %{runner: 1, build: 1, session: 2}
  @max_counters 16_384
  @report_counters 256
  @keep_ms 48 * 3_600_000
  @reading_gap_ms 2_000

  @version 1
  @poll_ms 5_000
  @route "/locus/v1/pool"
  @services [:runtime, :builds, :backends]
  @max_request_bytes 1_024
  @boot ~r/\A[0-9a-f]{32}\z/
  @max_integer 9_007_199_254_740_991

  @typedoc "What a place's kind is charged and bounded as."
  @type class :: :runner | :build | :session

  @typedoc """
  What holds a pool that refused a start for room, in bytes: what the start
  needs, what was free, each place of its own athanor by kind, with its
  subject where the place is the asking role's (else nil), and the sum of
  every other place.
  """
  @type held :: %{
          need: non_neg_integer(),
          free: non_neg_integer(),
          mine: [%{kind: String.t(), subject: String.t() | nil, bytes: non_neg_integer()}],
          others_bytes: non_neg_integer()
        }

  @typedoc """
  One counter of who used what: its role's `rev` at its last change, its
  UTC `day`, its athanor and subject or nil, its kind, the sum of its
  places' latest readings, its MiB-milliseconds and measured
  milliseconds, the most bytes it held, and its kills for memory by cause.
  """
  @type counter :: %{
          rev: pos_integer(),
          day: Date.t(),
          athanor: String.t() | nil,
          kind: String.t(),
          subject: String.t() | nil,
          bytes: non_neg_integer(),
          mib_ms: non_neg_integer(),
          measured_ms: non_neg_integer(),
          peak_bytes: non_neg_integer(),
          cap: non_neg_integer(),
          machine: non_neg_integer(),
          either: non_neg_integer()
        }

  @typedoc """
  A role's report: the keeper's boot id, the machine's budget, work, floor
  and used bytes, the role's counters after the rev asked for, and the
  last rev of the page when more follow.
  """
  @type report :: %{
          boot: String.t(),
          budget: non_neg_integer(),
          work: non_neg_integer(),
          floor: non_neg_integer(),
          used: non_neg_integer(),
          counters: [counter()],
          next: pos_integer() | nil
        }

  @typedoc "A service that serves the pool wire."
  @type service :: :runtime | :builds | :backends

  @doc "F, the memory the warm floor keeps from builds and programs: its one runner's allowance, 164 MiB."
  @spec floor_bytes() :: pos_integer()
  def floor_bytes, do: @floor_bytes

  @doc "How many fresh runners the warm floor keeps: one."
  @spec floor_runners() :: pos_integer()
  def floor_runners, do: 1

  @doc """
  How long a start waits for room before it is refused: the close's own
  wait (`Prima.LocusBackends.close_wait_ms/0`), so every client that waits
  for a start waits past it.
  """
  @spec room_wait_ms() :: pos_integer()
  def room_wait_ms, do: Prima.LocusBackends.close_wait_ms()

  @doc "How long after its spawn a place is charged at least its allowance."
  @spec allowance_ms() :: pos_integer()
  def allowance_ms, do: 10_000

  @doc "How long a place may go unread before it is charged no less than its last charge."
  @spec stale_ms() :: pos_integer()
  def stale_ms, do: 3_000

  @doc "Each place's kind and its class."
  @spec kinds() :: %{String.t() => class()}
  def kinds, do: @kinds

  @doc "What a start of the class needs and is charged at least for its first `allowance_ms/0`."
  @spec allowance_bytes(class()) :: pos_integer()
  def allowance_bytes(class), do: Map.fetch!(@allowance_bytes, class)

  @doc "A build's memory bound, 1 GiB."
  @spec build_cap_bytes() :: pos_integer()
  def build_cap_bytes, do: @build_cap_bytes

  @doc """
  The least memory bound of a runner and of a session, whose bound is half
  of W, never under it: a runner's its allowance and the components' hard
  ceiling together, a session's its allowance.
  """
  @spec least_cap_bytes(:runner | :session) :: pos_integer()
  def least_cap_bytes(class), do: Map.fetch!(@least_cap_bytes, class)

  @doc "The memory bound of a spawn of the class on a pool of work `work` bytes."
  @spec cap_bytes(class(), non_neg_integer()) :: pos_integer()
  def cap_bytes(:build, _work), do: @build_cap_bytes
  def cap_bytes(class, work), do: max(div(work, 2), least_cap_bytes(class))

  @doc "The processors of each spawn of the class."
  @spec processors(class()) :: pos_integer()
  def processors(class), do: Map.fetch!(@processors, class)

  @doc "The most counters the keeper holds."
  @spec max_counters() :: pos_integer()
  def max_counters, do: @max_counters

  @doc "The most counters one report carries."
  @spec report_counters() :: pos_integer()
  def report_counters, do: @report_counters

  @doc "How long a counter stays after its last change: 48 hours."
  @spec keep_ms() :: pos_integer()
  def keep_ms, do: @keep_ms

  @doc "The longest gap between a place's readings that is counted."
  @spec reading_gap_ms() :: pos_integer()
  def reading_gap_ms, do: @reading_gap_ms

  @doc """
  How often CYFR asks each service for its report (`Opus.Memory`), and
  how often a page showing the record reads it again: 5 seconds.
  """
  @spec poll_ms() :: pos_integer()
  def poll_ms, do: @poll_ms

  @doc """
  How long after its last answer an endpoint counts as answering: three
  polls. One that has not answered within it holds nothing now, joins no
  machine, and a refusal names no holder from it.
  """
  @spec fresh_ms() :: pos_integer()
  def fresh_ms, do: 3 * @poll_ms

  @doc "The name CYFR stamps the builds service's report with in its record."
  @spec builds_endpoint() :: String.t()
  def builds_endpoint, do: "builds"

  @doc "The pool wire's version, carried in every body and answer as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The pool wire's one route, on each service."
  @spec route() :: String.t()
  def route, do: @route

  @doc "The services that serve the pool wire."
  @spec services() :: [service()]
  def services, do: @services

  @doc "The most bytes a request body may be."
  @spec max_request_bytes() :: pos_integer()
  def max_request_bytes, do: @max_request_bytes

  @doc "How far a header's `ts` may be from the listener's clock: the builds wire's window."
  @spec window_ms() :: pos_integer()
  def window_ms, do: Prima.BuilderProtocol.window_ms()

  @doc "The label a service's pool key derives over and its headers sign under."
  @spec label(service()) :: String.t()
  def label(service) when service in @services, do: Prima.MacEnvelope.label(service) <> "/pool"

  @doc """
  The pool key of `service`, from the key the service is given: the
  builds service key (`LOCUS_BUILDS_KEY`, whose request key is taken
  first), the backends service key, or a worker service's key
  (`Prima.WorkerAuth.worker_key/2`).
  """
  @spec pool_key(service(), binary()) :: binary()
  def pool_key(:builds, given) when byte_size(given) == 32,
    do: held_pool_key(:builds, Prima.BuilderProtocol.request_key(given))

  def pool_key(service, given) when service in @services and byte_size(given) == 32,
    do: held_pool_key(service, given)

  @doc """
  The pool key of `service`, from the key that service holds: the builds
  service's request key (`Prima.BuilderProtocol.request_key/1`), the
  backends service key, or a worker service's key.
  """
  @spec held_pool_key(service(), binary()) :: binary()
  def held_pool_key(service, held) when service in @services and byte_size(held) == 32,
    do: Prima.MacEnvelope.derive(held, label(service))

  defp envelope(service),
    do: %Prima.MacEnvelope{prefix: label(service), kind: "pool", fields: [ts: :integer]}

  @doc "The `x-cyfr-auth` header of a request of `body` to `service` at `ts`, under its pool key."
  @spec header(service(), binary(), non_neg_integer(), binary()) :: String.t()
  def header(service, pool_key, ts, body)
      when service in @services and byte_size(pool_key) == 32 and is_binary(body) do
    {:ok, header} = Prima.MacEnvelope.header(envelope(service), pool_key, %{ts: ts}, body)
    header
  end

  @doc """
  The body hash a request's header names, once the header is a `v1`
  header of `service`'s pool envelope, its `ts` within `window_ms/0` of
  `now` and its MAC that of `service`'s pool key; otherwise the first of
  `:unknown_version`, `:malformed`, `:outside_window` and `:bad_mac`.
  """
  @spec verify_header(service(), binary(), term(), integer()) ::
          {:ok, String.t()} | {:error, :unknown_version | :malformed | :outside_window | :bad_mac}
  def verify_header(service, pool_key, header, now)
      when service in @services and byte_size(pool_key) == 32 and is_integer(now) do
    envelope = envelope(service)

    with {:ok, fields, mac} <- Prima.MacEnvelope.parse(envelope, header),
         :ok <- within_window(fields.ts, now),
         :ok <- authentic(Prima.MacEnvelope.verify_header(envelope, pool_key, fields, mac)) do
      {:ok, fields.body_hash}
    end
  end

  defp within_window(ts, now) do
    if abs(ts - now) <= window_ms(), do: :ok, else: {:error, :outside_window}
  end

  defp authentic(true), do: :ok
  defp authentic(false), do: {:error, :bad_mac}

  @doc "Whether `body` is the one a verified header hashed."
  @spec verify_body(String.t(), binary()) :: :ok | {:error, :bad_mac}
  def verify_body(body_hash, body) when is_binary(body_hash) and is_binary(body) do
    if Prima.MacEnvelope.verify_body(envelope(:builds), %{body_hash: body_hash}, body),
      do: :ok,
      else: {:error, :bad_mac}
  end

  @doc "A request's body: the rev the report follows."
  @spec request_body(non_neg_integer()) :: binary()
  def request_body(after_rev) when is_integer(after_rev) and after_rev in 0..@max_integer//1,
    do: Jason.encode!(Jason.OrderedObject.new([{"v", @version}, {"after", after_rev}]))

  @doc """
  The rev a request's body asks after: an object of exactly `v` and
  `after`, a whole number from 0 to 2^53 - 1. Another version, or none, is
  `{:error, :version}` before anything else is read; anything else
  `{:error, :malformed}`.
  """
  @spec read_request_body(binary()) :: {:ok, non_neg_integer()} | {:error, :version | :malformed}
  def read_request_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"v" => @version} = object} ->
        case object do
          %{"after" => rev}
          when map_size(object) == 2 and is_integer(rev) and rev in 0..@max_integer//1 ->
            {:ok, rev}

          _ ->
            {:error, :malformed}
        end

      {:ok, %{}} ->
        {:error, :version}

      _ ->
        {:error, :malformed}
    end
  end

  @doc "The answer carrying `report`."
  @spec answer(report()) :: binary()
  def answer(report),
    do:
      Jason.encode!(Jason.OrderedObject.new([{"v", @version}, {"report", encode_report(report)}]))

  @doc "The report an answer carries, read strictly (`read_report/1`), or `:error`."
  @spec read_answer(binary()) :: {:ok, report()} | :error
  def read_answer(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"v" => @version, "report" => report} = object} when map_size(object) == 2 ->
        read_report(report)

      _ ->
        :error
    end
  end

  @doc """
  `report` as every wire carries it: exactly `boot`, `budget`, `work`,
  `floor`, `used`, `counters` and, when more follow, `next`; each counter
  exactly its members, `day` as `YYYY-MM-DD`, and `athanor` and `subject`
  only where it has them.
  """
  @spec encode_report(report()) :: map()
  def encode_report(%{counters: counters, next: next} = report) do
    report
    |> Map.take([:boot, :budget, :work, :floor, :used])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("counters", Enum.map(counters, &counter_wire/1))
    |> put_present("next", next)
  end

  @counter_numbers ~w(rev bytes mib_ms measured_ms peak_bytes cap machine either)a

  defp counter_wire(counter) do
    counter
    |> Map.take(@counter_numbers ++ [:kind])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("day", Date.to_iso8601(counter.day))
    |> put_present("athanor", counter.athanor)
    |> put_present("subject", counter.subject)
  end

  defp put_present(map, _name, nil), do: map
  defp put_present(map, name, value), do: Map.put(map, name, value)

  @doc """
  `report` read strictly from its wire form (`encode_report/1`): exactly
  its members, every number a whole number from 0 to 2^53 - 1 (a `rev` and
  `next` from 1), `boot` 32 lowercase hexadecimal digits, at most
  `report_counters/0` counters in ascending `rev`, each `day` a date, each
  `kind` a place's kind (`kinds/0`), an `athanor` of the athanor grammar
  and a `subject` of the keeper's id grammar where present, none null;
  `:error` otherwise.
  """
  @spec read_report(term()) :: {:ok, report()} | :error
  def read_report(%{} = report) do
    members = Map.keys(report) -- ["next"]

    with true <- Enum.sort(members) == ~w(boot budget counters floor used work),
         true <- is_binary(report["boot"]) and Regex.match?(@boot, report["boot"]),
         true <- Enum.all?(~w(budget work floor used), &whole?(report[&1])),
         {:ok, next} <- read_next(report),
         {:ok, counters} <- read_counters(report["counters"]) do
      {:ok,
       %{
         boot: report["boot"],
         budget: report["budget"],
         work: report["work"],
         floor: report["floor"],
         used: report["used"],
         counters: counters,
         next: next
       }}
    else
      _ -> :error
    end
  end

  def read_report(_report), do: :error

  defp read_next(%{"next" => next}), do: if(rev?(next), do: {:ok, next}, else: :error)
  defp read_next(_report), do: {:ok, nil}

  defp read_counters(counters) when is_list(counters) and length(counters) <= @report_counters do
    read = Enum.map(counters, &read_counter/1)
    revs = Enum.map(read, &(match?({:ok, _}, &1) && elem(&1, 1).rev))

    if Enum.all?(revs) and revs == Enum.sort(Enum.uniq(revs)),
      do: {:ok, Enum.map(read, &elem(&1, 1))},
      else: :error
  end

  defp read_counters(_counters), do: :error

  defp read_counter(%{} = c) do
    numbers = Enum.map(@counter_numbers, &Atom.to_string/1)
    optional = Map.keys(c) -- (numbers ++ ~w(day kind))

    with true <- Enum.all?(numbers ++ ~w(day kind), &Map.has_key?(c, &1)),
         true <- optional -- ~w(athanor subject) == [],
         true <- Enum.all?(numbers, &whole?(c[&1])) and rev?(c["rev"]),
         true <- is_map_key(@kinds, c["kind"]),
         {:ok, day} <- read_day(c["day"]),
         {:ok, athanor} <- read_optional(c, "athanor", &athanor?/1),
         {:ok, subject} <- read_optional(c, "subject", &Prima.KeeperProtocol.id?/1) do
      {:ok,
       @counter_numbers
       |> Map.new(&{&1, c[Atom.to_string(&1)]})
       |> Map.merge(%{day: day, kind: c["kind"], athanor: athanor, subject: subject})}
    else
      _ -> :error
    end
  end

  defp read_counter(_counter), do: :error

  defp read_day(day) when is_binary(day) and byte_size(day) == 10, do: Date.from_iso8601(day)
  defp read_day(_day), do: :error

  defp read_optional(c, name, valid?) do
    case Map.fetch(c, name) do
      :error -> {:ok, nil}
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: :error
    end
  end

  defp athanor?(value),
    do: is_binary(value) and Regex.match?(Prima.RunnerControl.athanor_id_pattern(), value)

  defp whole?(value), do: is_integer(value) and value >= 0 and value <= @max_integer
  defp rev?(value), do: whole?(value) and value >= 1

  @doc """
  `held` as every wire carries it: an object of exactly `need`, `free`,
  `mine` and `others_bytes`, each holding of `mine` exactly `kind` and
  `bytes`, with `subject` only where it has one.
  """
  @spec encode_held(held()) :: map()
  def encode_held(%{need: need, free: free, mine: mine, others_bytes: others}) do
    %{
      "need" => need,
      "free" => free,
      "mine" => Enum.map(mine, &holding_wire/1),
      "others_bytes" => others
    }
  end

  defp holding_wire(%{kind: kind, subject: nil, bytes: bytes}),
    do: %{"kind" => kind, "bytes" => bytes}

  defp holding_wire(%{kind: kind, subject: subject, bytes: bytes}),
    do: %{"kind" => kind, "subject" => subject, "bytes" => bytes}

  @doc """
  `held` read strictly from its wire form (`encode_held/1`): exactly its
  members, every count of bytes a whole number from 0 to the keeper's
  largest reading, each holding's `kind` a place's kind (`kinds/0`) and
  its `subject`, where present, of the keeper's id grammar; `:error`
  otherwise. A holding's absent `subject` reads as nil; none is null.
  """
  @spec read_held(term()) :: {:ok, held()} | :error
  def read_held(%{} = held) do
    with true <- Enum.sort(Map.keys(held)) == ~w(free mine need others_bytes),
         true <- Enum.all?(~w(free need others_bytes), &bytes?(held[&1])),
         {:ok, mine} <- read_holdings(held["mine"]) do
      {:ok,
       %{need: held["need"], free: held["free"], mine: mine, others_bytes: held["others_bytes"]}}
    else
      _ -> :error
    end
  end

  def read_held(_held), do: :error

  defp read_holdings(mine) when is_list(mine) do
    Enum.reduce_while(mine, {:ok, []}, fn holding, {:ok, read} ->
      case read_holding(holding) do
        {:ok, h} -> {:cont, {:ok, [h | read]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      :error -> :error
    end
  end

  defp read_holdings(_mine), do: :error

  defp read_holding(%{"kind" => kind, "bytes" => bytes} = h) when is_map_key(@kinds, kind) do
    members = Map.keys(h) -- ~w(kind bytes)

    subject =
      case {members, h} do
        {[], _} -> {:ok, nil}
        {["subject"], %{"subject" => s}} when is_binary(s) -> subject(s)
        _ -> :error
      end

    with true <- bytes?(bytes), {:ok, subject} <- subject do
      {:ok, %{kind: kind, subject: subject, bytes: bytes}}
    else
      _ -> :error
    end
  end

  defp read_holding(_holding), do: :error

  defp subject(s), do: if(Prima.KeeperProtocol.id?(s), do: {:ok, s}, else: :error)

  defp bytes?(value),
    do: is_integer(value) and value >= 0 and value <= Prima.KeeperProtocol.max_measured_bytes()

  # What a person calls each kind of place, in the order a sentence names
  # them. A runner's two kinds are one word: a run.
  @kind_words [
    {"program", ["program"]},
    {"terminal", ["terminal"]},
    {"build", ["build"]},
    {"run", ["run", "warm"]}
  ]
  @stoppable ~w(program terminal)
  @withheld "This CYFR has not enough memory free. Stop one on the Programs page, or wait."

  @doc """
  The one sentence a person reads of a start refused for room, from what
  holds the pool (`held`) and the names CYFR read for its subjects
  (`names`, a subject to the name its row has, read under the person's
  own scope). It says that this CYFR has not enough memory free and what
  holds it: the person's own work, each holding whose subject `names`
  names by that name with its size (one name's holdings as one), every
  other by kind with a count and its size, and everyone else's as one
  sum, then what the person can do. No subject is spelled: a holding
  whose subject `names` does not name is counted by its kind, so no
  other person's name or row is in it. With nothing of the person's own
  in `held` it never says "others": it says what is under way uses the
  memory. A runner's place is no athanor's until its work is assigned,
  so a refused run's `held` holds nothing of the person's own; a caller
  that knows the person's holders from elsewhere hands them as `mine`
  with their subjects, and their names here. When the start needs more
  than everything held and free together, nothing anyone stops makes
  room: it says only that this CYFR has not enough memory for it, what
  it needs and what all its work can have, and gives no advice.

  `:withheld` in place of `held` is the sentence told to a caller that
  is told nothing of what holds the memory, a component in a chain among
  them: that this CYFR has not enough memory free, with no name, size or
  sum.
  """
  @spec refusal_sentence(held() | :withheld, %{String.t() => String.t()}) :: String.t()
  def refusal_sentence(held, names \\ %{})

  def refusal_sentence(:withheld, _names), do: @withheld

  def refusal_sentence(%{need: need, free: free, mine: mine, others_bytes: others} = held, names)
      when is_map(names) do
    case free + others + Enum.sum_by(mine, & &1.bytes) do
      0 ->
        "This CYFR has no memory free for it."

      all when need > all ->
        "This CYFR has not enough memory for it: it needs #{Prima.Bytes.format(need)}, " <>
          "and has #{Prima.Bytes.format(all)} for all its work."

      _stopping_helps ->
        room_held(held, names)
    end
  end

  defp room_held(%{mine: [], others_bytes: others}, _names),
    do:
      "This CYFR has not enough memory free. Work under way uses " <>
        "#{Prima.Bytes.format(others)}. Wait, or try again later."

  defp room_held(%{mine: mine, others_bytes: others}, names) do
    others = if others > 0, do: [" Others use #{Prima.Bytes.format(others)}."], else: []

    ending =
      if Enum.any?(mine, &(&1.kind in @stoppable)),
        do: " Stop one on the Programs page, or wait.",
        else: " Wait, or try again later."

    {named, unnamed} = Enum.split_with(mine, &is_map_key(names, &1.subject))

    IO.iodata_to_binary([
      "This CYFR has not enough memory free. Of yours, ",
      (by_name(named, names) ++ yours(unnamed)) |> joined(),
      ".",
      others,
      ending
    ])
  end

  # Each name once, its holdings' sizes together, the largest first and
  # then by name, so the sentence is the same for the same holdings.
  defp by_name(named, names) do
    named
    |> Enum.group_by(&Map.fetch!(names, &1.subject), & &1.bytes)
    |> Enum.map(fn {name, sizes} -> {name, Enum.sum(sizes)} end)
    |> Enum.sort_by(fn {name, bytes} -> {-bytes, name} end)
    |> Enum.map(fn {name, bytes} -> "#{name} uses #{Prima.Bytes.format(bytes)}" end)
  end

  defp yours(mine) do
    for {word, kinds} <- @kind_words,
        held = Enum.filter(mine, &(&1.kind in kinds)),
        held != [] do
      bytes = Prima.Bytes.format(Enum.sum_by(held, & &1.bytes))

      case length(held) do
        1 -> "a #{word} uses #{bytes}"
        n -> "#{n} #{word}s use #{bytes}"
      end
    end
  end

  @doc """
  What a start refused for room says of the person's own holders, from
  `holders`, the record's current holders of the person's athanor on the
  refusing endpoint's machine (`Arca.MemoryRecord.holders_now/2`): `held`
  with its `mine` taken from them and the names of their rows, for
  `refusal_sentence/2`.

  The holders are used only when they fit within what `held` says is
  held, the refusal's charges: `ΣR ≤ others_bytes + Σmine`. Then `mine` is
  them and `others_bytes` is `others_bytes + Σmine − ΣR`, never below 0,
  so what is held and free together is the refusal's own and the
  sentence's branches decide as they would on `held`. With none, or more
  than `held` holds (a holder ended since the record was read), `held` is
  answered as it came with no names.
  """
  @spec named_held(held(), [
          %{
            kind: String.t(),
            subject: String.t() | nil,
            name: String.t() | nil,
            bytes: non_neg_integer()
          }
        ]) :: {held(), %{String.t() => String.t()}}
  def named_held(%{} = held, []), do: {held, %{}}

  def named_held(%{mine: mine, others_bytes: others} = held, holders) when is_list(holders) do
    held_bytes = others + Enum.sum_by(mine, & &1.bytes)
    theirs = Enum.sum_by(holders, & &1.bytes)

    if theirs <= held_bytes do
      names =
        for %{subject: subject, name: name} <- holders,
            is_binary(subject) and is_binary(name),
            into: %{},
            do: {subject, name}

      {%{
         held
         | mine: Enum.map(holders, &Map.take(&1, [:kind, :subject, :bytes])),
           others_bytes: held_bytes - theirs
       }, names}
    else
      {held, %{}}
    end
  end

  defp joined([one]), do: one
  defp joined(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
