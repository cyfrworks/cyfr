# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Settings do
  @moduledoc """
  What the runtime role of the `locus` release runs with, beside the
  service's credentials (`Locus.Runtime.Credentials`): the pool the
  service reads from `config :locus, :runtime`, and the environment it
  hands each runner. It reads no variable by name. `Locus.Config`
  declares and reads every variable of the release: the service's
  `LOCUS_RUNTIME_*` names (`Locus.Config.runtime_from_env/1`), which
  `config/locus_runtime.exs` turns into `config :locus, :runtime` on a
  node boot.

  ## The pool

  The service role reads its pool from `config :locus, :runtime`
  (`pool/2`): how long at most an idle runner is kept for its athanor
  (`:idle_ttl_ms`, 900 000: 15 minutes, the life of the components a
  runner has compiled, so a runner kept longer compiles them again on its
  next run; it gives way sooner when the keeper needs its memory or a
  spawn its uid, `Locus.Runtime.RunnerPool`), how far past its
  assignment's deadline the service lets a runner hold the subtree before
  it releases the runner (`:watchdog_grace_ms`, 5 000,
  `Locus.Runtime.WorkerService`), how long a
  released runner is given to report its open attempts before its
  process group is killed (`:release_grace_ms`, 2 000), which keeper
  starts its runners (`:keeper`, `:channel`: the `cyfr-locus` channel the
  image inherits; the test build alone also knows `:direct`,
  `Locus.Runtime.Keeper.direct_keeper/0`), where the keeper's relays
  attach (`:attach_dir`, the role's run folder as
  `Locus.Keeper.default_attach_dir/1` reads it); each default has one
  definition (`default/1`). How many fresh runners the pool keeps ahead,
  and the memory and processor of each runner, are no setting: the warm
  floor's one runner (`Prima.LocusPool.floor_runners/0`), and the bounds
  `cyfr-locus` sets by a runner's kind (`Prima.LocusPool`). Unset, the keeper is
  `:channel`, whatever the environment says: the service refuses to boot
  when no channel was inherited (`Locus.Runtime.Keeper.check!/3`), and
  never falls back to anything else. A value that is not a positive
  integer, or a keeper this build does not know (`keepers/0`), refuses
  the boot with the key named, and so does a `LOCUS_RUNTIME_*` name in
  the environment the pool is read under that `Locus.Config` does not
  declare (`pool!/0`, the only such check on a test boot).

  ## A runner

  A runner is the runner program at `runner_command/0`'s path, which the
  image installs. It holds no configuration of its own: the service
  passes it exactly the environment `runner_environment/1` writes (its
  ids) through the keeper's explicit environment, outside every prefix
  the keeper refuses in a spawn, and the keeper adds its control and
  relay descriptors (`tests/fixtures/runner_control.json`'s
  `environment`, which the program's crate reads too).
  """

  @pool_defaults %{
    idle_ttl_ms: 900_000,
    watchdog_grace_ms: 5_000,
    release_grace_ms: 2_000
  }

  @typedoc "The service role's pool settings."
  @type pool :: %{
          idle_ttl_ms: pos_integer(),
          watchdog_grace_ms: pos_integer(),
          release_grace_ms: pos_integer(),
          keeper: :channel | :direct,
          attach_dir: String.t()
        }

  @typedoc "What a keeper starts a runner with: its argv and the environment beside the keeper's own."
  @type command :: %{argv: [String.t()], env: %{String.t() => String.t()}}

  # Where the image installs the runner program (`Dockerfile.locus`).
  @runner_path "/usr/local/bin/cyfr-runner"

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
  unset: the one definition of each.
  """
  @spec default(:idle_ttl_ms | :watchdog_grace_ms | :release_grace_ms) :: pos_integer()
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
    with :ok <- no_unknown(system), do: pool_of(env, system)
  end

  defp pool_of(env, system) do
    with {:ok, idle} <- positive(env, :idle_ttl_ms),
         {:ok, watchdog} <- positive(env, :watchdog_grace_ms),
         {:ok, release} <- positive(env, :release_grace_ms),
         {:ok, keeper} <- keeper(Keyword.get(env, :keeper)),
         {:ok, attach_dir} <- attach_dir(Keyword.get(env, :attach_dir), system) do
      {:ok,
       %{
         idle_ttl_ms: idle,
         watchdog_grace_ms: watchdog,
         release_grace_ms: release,
         keeper: keeper,
         attach_dir: attach_dir
       }}
    end
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
  How a keeper starts a runner: the runner program at the path the image
  installs it at, with no argument and no environment of the service's
  (`t:command/0`), the pool adding `runner_environment/1`'s. The test
  build's keeper runs the program its checkout built in its place.
  """
  @spec runner_command() :: command()
  def runner_command, do: %{argv: [@runner_path], env: %{}}

  @doc """
  The environment a service gives a runner: the id it presents in its
  host calls (`runner_id`), and the worker service and boot it presents
  from, which an assignment must name (`service_id`, `boot`). Nothing
  else, so no name the keeper refuses in a spawn; the keeper adds the
  control and relay descriptors. No address of CYFR's is among them: the
  runner reaches CYFR only through its relay.
  """
  @spec runner_environment(%{runner_id: String.t(), service_id: String.t(), boot: String.t()}) ::
          %{String.t() => String.t()}
  def runner_environment(%{runner_id: runner_id, service_id: service_id, boot: boot}) do
    %{
      "RUNTIME_RUNNER_ID" => runner_id,
      "RUNTIME_SERVICE_ID" => service_id,
      "RUNTIME_BOOT_ID" => boot
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

  defp attach_dir(nil, system),
    do: attach_dir(Locus.Keeper.default_attach_dir(&Map.get(system, &1)), system)

  defp attach_dir(dir, _system) when is_binary(dir) do
    if Path.type(dir) == :absolute and dir == Path.expand(dir),
      do: {:ok, dir},
      else: {:error, {:malformed, :attach_dir}}
  end

  defp attach_dir(_dir, _system), do: {:error, {:malformed, :attach_dir}}

  @doc "What a well-formed value of the pool setting `key` is, for the message that refuses one."
  @spec expected(atom()) :: String.t()
  def expected(key) when key in [:idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms],
    do: "a positive integer"

  def expected(:keeper), do: "one of #{Enum.map_join(keepers(), ", ", &inspect/1)}"
  def expected(:attach_dir), do: "a clean absolute directory path"
end
