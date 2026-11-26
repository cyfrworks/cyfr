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
  """
  @spec refusal_sentence(held(), %{String.t() => String.t()}) :: String.t()
  def refusal_sentence(
        %{need: need, free: free, mine: mine, others_bytes: others} = held,
        names \\ %{}
      )
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

  defp joined([one]), do: one
  defp joined(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
