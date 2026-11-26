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
end
