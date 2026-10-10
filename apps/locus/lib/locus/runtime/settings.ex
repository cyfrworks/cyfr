# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Settings do
  @moduledoc """
  What the runtime role of the `locus` release runs with, beside the
  service's credentials (`Locus.Runtime.Credentials`): the pool the
  service reads from `config :locus, :runtime`, and the environment it
  hands each runner. It reads no variable by name. `Locus.Config`
  declares and reads every variable of the release: the service's
  `LOCUS_RUNTIME_*` names (`Locus.Config.runtime_from_env/2`), which
  `config/locus_runtime.exs` turns into `config :locus, :runtime` on a
  node boot and `config/runtime.exs` on a `mix` boot that runs the
  runtime beside CYFR, and a runner's `RUNTIME_*` names
  (`Locus.Config.runner/1`).

  ## The pool

  The service role reads its pool from `config :locus, :runtime`
  (`pool/2`): how many fresh runners to keep spawned ahead (`:pool_size`,
  4), how long an idle runner is kept for its athanor (`:idle_ttl_ms`,
  30 000), how far past its assignment's deadline a runner may live
  before it halts itself (`:watchdog_grace_ms`, 5 000), how long a
  released runner is given to report its open attempts before its
  process group is killed (`:release_grace_ms`, 2 000), which keeper
  starts its runners (`:keeper`, `:channel`: the `cyfr-locus` channel the
  image inherits; the test build alone also knows `:direct`,
  `Locus.Runtime.Keeper.direct_keeper/0`), where the keeper's relays
  attach (`:attach_dir`, `/run/locus`), and the memory bound of every
  runner `cyfr-locus` starts (`:runner_memory_bytes`, 384 MiB); each
  default has one definition (`default/1`). Unset, the keeper is
  `:channel`, whatever the environment says: the service refuses to boot
  when no channel was inherited (`Locus.Runtime.Keeper.check!/3`), and
  never falls back to anything else. A value that is not a positive
  integer, or a keeper this build does not know (`keepers/0`), refuses
  the boot with the key named, and so does a `LOCUS_RUNTIME_*` name in
  the environment the pool is read under that `Locus.Config` does not
  declare (`pool!/0`, the only such check on a test boot).

  `:runner_memory_bytes` is what `Locus.Runtime.Keeper.Channel` asks
  `cyfr-locus` to hold each runner to (`runner_memory_bytes/1`): a cgroup
  of the runner's own at that many bytes for its VM, every guest's linear
  memory, the pages of its home and the kernel memory charged to it,
  together. A runner that reaches it is killed whole by the kernel and
  never reused. Its range is the keeper's own for a spawn's
  `memory_bytes`, 16 MiB to 1 TiB (`Locus.Config.memory_range/0`), so a
  value accepted here is never refused there; a value outside it, or not
  an integer, refuses the boot. There is no value that asks for no bound.
  The test build's `:direct` keeper applies none: it has no cgroup to
  give a runner. The default is 1.8 times the largest peak of a runner
  under the seed components, rounded up
  (`tests/locus-runtime-image/memory.py --measure` repeats the
  measurement). The runner's own VM is most of that peak, so the default
  leaves a subtree's guests room for two or three at the default 64 MiB
  of linear memory at once, not for one at the platform ceiling's
  256 MiB: a deployment that consents to more raises this bound with it.

  ## A runner

  A runner holds no configuration of its own: the service passes it
  exactly the environment `runner_environment/1` writes (its role, its
  ids and its watchdog grace) through the keeper's explicit environment,
  outside every prefix the keeper refuses in a spawn, and the keeper adds
  its control and relay descriptors. The runner reads them through
  `Locus.Config.runner!/0` and nothing else of the release.
  """

  @pool_defaults %{
    pool_size: 4,
    idle_ttl_ms: 30_000,
    watchdog_grace_ms: 5_000,
    release_grace_ms: 2_000,
    attach_dir: "/run/locus",
    runner_memory_bytes: 402_653_184
  }

  @typedoc "The service role's pool settings."
  @type pool :: %{
          pool_size: pos_integer(),
          idle_ttl_ms: pos_integer(),
          watchdog_grace_ms: pos_integer(),
          release_grace_ms: pos_integer(),
          keeper: :channel | :direct,
          attach_dir: String.t(),
          runner_memory_bytes: pos_integer()
        }

  @typedoc "The runner role's settings, as its environment spells them (`Locus.Config.runner/1`)."
  @type runner :: %{
          runner_id: String.t(),
          service_id: String.t(),
          boot: String.t(),
          control_fd: non_neg_integer(),
          relay: {:fd, pos_integer()} | {:socket, String.t()},
          watchdog_grace_ms: pos_integer()
        }

  @doc """
  The keepers this build knows: `:channel` in every build, and `:direct`
  where the test build has its direct keeper (`Locus.Runtime.Keeper.direct_keeper/0`).
  """
  @spec keepers() :: [atom()]
  def keepers,
    do: if(Locus.Runtime.Keeper.direct_keeper(), do: [:channel, :direct], else: [:channel])

  @typedoc "Why the pool's settings refuse the boot."
  @type pool_refusal :: {:malformed, atom()} | {:unknown, [String.t(), ...]}

  @doc "The runtime role's settings: `config :locus, :runtime`, a keyword."
  @spec env() :: keyword()
  def env, do: Application.get_env(:locus, :runtime, [])

  @doc """
  What the pool setting `key` is when `config :locus, :runtime` leaves it
  unset, and the watchdog grace a runner takes when its environment
  names none (`Locus.Config.runner/1`): the one definition of each.
  """
  @spec default(
          :pool_size
          | :idle_ttl_ms
          | :watchdog_grace_ms
          | :release_grace_ms
          | :attach_dir
          | :runner_memory_bytes
        ) :: pos_integer() | String.t()
  def default(key), do: Map.fetch!(@pool_defaults, key)

  @doc "The pool settings `config :locus, :runtime` spells, or the first key that refuses."
  @spec pool() :: {:ok, pool()} | {:error, pool_refusal()}
  def pool, do: pool(env(), System.get_env())

  @doc """
  The pool settings `env` (the `:runtime` keyword of the `:locus`
  application environment) spells, under the environment `system` (the
  process environment, or what a boot read), which must set no
  `LOCUS_RUNTIME_*` name `Locus.Config` does not declare for the runtime.
  """
  @spec pool(keyword(), %{optional(String.t()) => String.t()}) ::
          {:ok, pool()} | {:error, pool_refusal()}
  def pool(env, system) when is_list(env) and is_map(system) do
    with :ok <- no_unknown(system), do: pool_of(env)
  end

  defp pool_of(env) do
    with {:ok, size} <- positive(env, :pool_size),
         {:ok, idle} <- positive(env, :idle_ttl_ms),
         {:ok, watchdog} <- positive(env, :watchdog_grace_ms),
         {:ok, release} <- positive(env, :release_grace_ms),
         {:ok, keeper} <- keeper(Keyword.get(env, :keeper)),
         {:ok, attach_dir} <- attach_dir(Keyword.get(env, :attach_dir)),
         {:ok, memory_bytes} <- runner_memory_bytes(env) do
      {:ok,
       %{
         pool_size: size,
         idle_ttl_ms: idle,
         watchdog_grace_ms: watchdog,
         release_grace_ms: release,
         keeper: keeper,
         attach_dir: attach_dir,
         runner_memory_bytes: memory_bytes
       }}
    end
  end

  @doc """
  The memory bound `env` (the `:runtime` keyword of the `:locus`
  application environment) gives every runner `cyfr-locus` starts: its
  `:runner_memory_bytes`, or the default when unset. A value that is not
  an integer in `Locus.Config.memory_range/0`, 16 MiB to 1 TiB, refuses.
  """
  @spec runner_memory_bytes(keyword()) ::
          {:ok, pos_integer()} | {:error, {:malformed, :runner_memory_bytes}}
  def runner_memory_bytes(env) when is_list(env) do
    bytes = Keyword.get(env, :runner_memory_bytes, default(:runner_memory_bytes))

    if is_integer(bytes) and bytes in Locus.Config.memory_range(),
      do: {:ok, bytes},
      else: {:error, {:malformed, :runner_memory_bytes}}
  end

  @doc "`pool/0`, raising on a value that refuses so the boot stops there."
  @spec pool!() :: pool()
  def pool! do
    case pool() do
      {:ok, pool} ->
        pool

      {:error, {:malformed, key}} ->
        raise ArgumentError,
              "[Locus.Runtime.Settings] config :locus, :runtime, #{inspect(key)} is malformed: " <>
                expected(key)

      {:error, {:unknown, names}} ->
        raise ArgumentError, "[Locus.Runtime.Settings] " <> Locus.Config.unknown(names)
    end
  end

  @doc """
  The environment a service gives a runner for `settings` (`t:runner/0`
  minus what the keeper decides): every `RUNTIME_*` variable a runner
  reads (`Locus.Config.runner/1`) that its service decides, and nothing
  else, so no name the keeper refuses in a spawn. The keeper adds the
  control and relay descriptors. No address of CYFR's is among them: the
  runner reaches CYFR only through its relay.
  """
  @spec runner_environment(map()) :: %{String.t() => String.t()}
  def runner_environment(%{runner_id: runner_id, service_id: service_id, boot: boot} = settings) do
    %{
      "RUNTIME_ROLE" => "runner",
      "RUNTIME_RUNNER_ID" => runner_id,
      "RUNTIME_SERVICE_ID" => service_id,
      "RUNTIME_BOOT_ID" => boot,
      "RUNTIME_WATCHDOG_GRACE_MS" => Integer.to_string(Map.fetch!(settings, :watchdog_grace_ms))
    }
  end

  defp positive(env, key) do
    case Keyword.get(env, key, default(key)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:malformed, key}}
    end
  end

  # Unset is the channel keeper in every build: an environment without a
  # channel refuses the boot where the pool starts, and never selects a
  # keeper that isolates nothing.
  defp keeper(nil), do: {:ok, :channel}

  defp keeper(keeper) when is_atom(keeper) do
    if keeper in keepers(), do: {:ok, keeper}, else: {:error, {:malformed, :keeper}}
  end

  defp keeper(_keeper), do: {:error, {:malformed, :keeper}}

  defp no_unknown(system) do
    case Locus.Config.unknown_names(Map.keys(system), :runtime) do
      [] -> :ok
      names -> {:error, {:unknown, names}}
    end
  end

  defp attach_dir(nil), do: {:ok, default(:attach_dir)}

  defp attach_dir(dir) when is_binary(dir) do
    if Path.type(dir) == :absolute and dir == Path.expand(dir),
      do: {:ok, dir},
      else: {:error, {:malformed, :attach_dir}}
  end

  defp attach_dir(_dir), do: {:error, {:malformed, :attach_dir}}

  @doc "What a well-formed value of the pool setting `key` is, for the message that refuses one."
  @spec expected(atom()) :: String.t()
  def expected(key) when key in [:pool_size, :idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms],
    do: "a positive integer"

  def expected(:keeper), do: "one of #{Enum.map_join(keepers(), ", ", &inspect/1)}"
  def expected(:attach_dir), do: "a clean absolute directory path"

  def expected(:runner_memory_bytes) do
    first..last//1 = Locus.Config.memory_range()
    "a whole number of bytes from #{first} (16 MiB) to #{last} (1 TiB)"
  end
end
