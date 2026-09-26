# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Settings do
  @moduledoc """
  What each role of the `opus` release runs with, beside the service's
  credentials (`Opus.Credentials`).

  The service role reads its pool from `config :opus` (`pool/1`): how many
  fresh runners to keep spawned ahead (`:pool_size`, 4), how long an idle
  runner is kept for its athanor (`:idle_ttl_ms`, 30 000), how far past
  its assignment's deadline a runner may live before it halts itself
  (`:watchdog_grace_ms`, 5 000), how long a released runner is given to
  report its open attempts before its process group is killed
  (`:release_grace_ms`, 2 000), which keeper starts its runners
  (`:keeper`, `:channel`: the `cyfr-keeper` channel the image inherits;
  the test build alone also knows `:direct`, `Opus.Keeper.direct_keeper/0`),
  where the keeper's relays attach (`:attach_dir`, `/run/opus`), and the
  memory bound of every runner `cyfr-keeper` starts
  (`:runner_memory_bytes`, 384 MiB). Unset, the keeper is `:channel`,
  whatever the environment says: the service refuses to boot when no
  channel was inherited (`Opus.Keeper.check!/3`), and never falls back to
  anything else. A value that is not a positive integer, or a keeper this
  build does not know (`keepers/0`), refuses the boot with the key named.
  `OPUS_KEEPER`, which once chose the keeper, is retired: an environment
  that sets it, blank or not, refuses the boot naming it, since the keeper
  channel is the only launcher. So does any other `OPUS_*` name the release
  does not read (`variables/0`) and compose does not interpolate
  (`compose_only/0`): this module declares the prefix, because the release
  carries no host module to declare it.

  `:runner_memory_bytes` is what `Opus.Keeper.Channel` asks `cyfr-keeper` to
  hold each runner to (`runner_memory_bytes/1`): a cgroup of the runner's
  own at that many bytes for its VM, every guest's linear memory, the
  pages of its home and the kernel memory charged to it, together. A
  runner that reaches it is killed whole by the kernel and never reused.
  Its range is the keeper's own for a spawn's `memory_bytes`, 16 MiB to
  1 TiB, so a value accepted here is never refused there; a value outside
  it, or not an integer, refuses the boot. There is no value that asks
  for no bound. The test build's `:direct` keeper applies none: it has no
  cgroup to give a runner. The default is 1.8 times the largest peak of a
  runner under the seed components, rounded up (`tests/worker-image/memory.py
  --measure` repeats the measurement). The runner's own VM is most of
  that peak, so the default leaves a subtree's guests room for two or
  three at the default 64 MiB of linear memory at once, not for one at
  the platform ceiling's 256 MiB: a deployment that consents to more
  raises this bound with it.

  The runner role reads its settings from the process environment alone
  (`runner/1`): the service passed exactly these through the keeper's
  explicit environment, and a runner holds no configuration of its own.
  `OPUS_RUNNER_ID` is the id it presents in its host calls, `OPUS_SERVICE_ID`
  and `OPUS_BOOT_ID` the worker service and boot it presents from,
  `OPUS_HOST_URL` the base URL of CYFR's host API, `OPUS_CONTROL_FD` the
  file descriptor its control channel is on (3 by default; 0 means the
  channel is its standard input and output), and `OPUS_WATCHDOG_GRACE_MS`
  the grace above. A runner that can see `OPUS_SERVICE_KEY` was given the
  service's own key, which no runner holds, and refuses to start.
  """

  @service_id ~r/\Awrk_[A-Za-z0-9_-]{1,64}\z/
  @id ~r/\A[\x21-\x7E]{1,256}\z/

  @channel_env "KEEPER_CHANNEL"
  @retired_keeper_env "OPUS_KEEPER"

  # Every `OPUS_*` name the release reads, in either role: the role itself
  # (`Opus.Release.role/1`), the service's credentials and listener
  # (`Opus.Credentials`, read by `config/runtime.exs`), its pool (`pool/2`)
  # and the runner's environment (`runner/1`).
  @variables ~w(OPUS_ROLE OPUS_SERVICE_ID OPUS_SERVICE_KEY OPUS_HOST_URL OPUS_BIND OPUS_PORT
                OPUS_POOL_SIZE OPUS_IDLE_TTL_MS OPUS_WATCHDOG_GRACE_MS OPUS_RELEASE_GRACE_MS
                OPUS_RUNNER_MEMORY_BYTES OPUS_ATTACH_DIR OPUS_RUNNER_ID OPUS_BOOT_ID
                OPUS_CONTROL_FD)

  # The opus container's limits, which docker-compose.yml interpolates from
  # the project .env and no release reads. A development boot sources that
  # file, so a name in it is compose's, not a stray one.
  @compose_only ~w(OPUS_MEMORY_LIMIT OPUS_CPU_LIMIT)

  # cyfr-keeper's range for a spawn's `memory_bytes`
  # (`apps/keeper/internal/protocol`: MinMemoryBytes, MaxMemoryBytes).
  @runner_memory_range 16_777_216..1_099_511_627_776

  @pool_defaults %{
    pool_size: 4,
    idle_ttl_ms: 30_000,
    watchdog_grace_ms: 5_000,
    release_grace_ms: 2_000,
    attach_dir: "/run/opus",
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

  @typedoc "The runner role's settings, as its environment spells them."
  @type runner :: %{
          runner_id: String.t(),
          service_id: String.t(),
          boot: String.t(),
          host_url: String.t(),
          control_fd: non_neg_integer(),
          watchdog_grace_ms: pos_integer()
        }

  @doc """
  The keepers this build knows: `:channel` in every build, and `:direct`
  where the test build has its direct keeper (`Opus.Keeper.direct_keeper/0`).
  """
  @spec keepers() :: [atom()]
  def keepers, do: if(Opus.Keeper.direct_keeper(), do: [:channel, :direct], else: [:channel])

  @doc "The environment variable the keeper sets to name the inherited channel."
  @spec channel_env() :: String.t()
  def channel_env, do: @channel_env

  @doc "Whether this process inherited a keeper channel (`KEEPER_CHANNEL` is set)."
  @spec channel_inherited?() :: boolean()
  def channel_inherited?, do: channel_inherited?(System.get_env())

  @doc false
  def channel_inherited?(env) when is_map(env) do
    case Map.get(env, @channel_env) do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  @typedoc "Why the pool's settings refuse the boot."
  @type pool_refusal ::
          {:malformed, atom()} | {:retired, String.t()} | {:unknown, [String.t(), ...]}

  @doc "The pool settings `config :opus` spells, or the first key that refuses."
  @spec pool() :: {:ok, pool()} | {:error, pool_refusal()}
  def pool, do: pool(Application.get_all_env(:opus), System.get_env())

  @doc """
  The pool settings `env` (the `:opus` application environment) spells,
  under the environment `system` (the process environment and whatever
  files the boot sourced), which must not set the retired `OPUS_KEEPER`
  nor any other `OPUS_*` name the release does not declare.
  """
  @spec pool(keyword(), %{optional(String.t()) => String.t()}) ::
          {:ok, pool()} | {:error, pool_refusal()}
  def pool(env, system) when is_list(env) and is_map(system) do
    with :ok <- no_retired_keeper(system),
         :ok <- no_unknown(system),
         {:ok, size} <- positive(env, :pool_size),
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
  The memory bound `env` (the `:opus` application environment) gives
  every runner `cyfr-keeper` starts: its `:runner_memory_bytes`, or the
  default when unset. A value that is not an integer from 16 MiB to 1 TiB
  refuses.
  """
  @spec runner_memory_bytes(keyword()) ::
          {:ok, pos_integer()} | {:error, {:malformed, :runner_memory_bytes}}
  def runner_memory_bytes(env) when is_list(env) do
    case Keyword.get(env, :runner_memory_bytes, @pool_defaults.runner_memory_bytes) do
      bytes when is_integer(bytes) and bytes in @runner_memory_range -> {:ok, bytes}
      _ -> {:error, {:malformed, :runner_memory_bytes}}
    end
  end

  @doc "The least and the most a runner's memory bound may be, in bytes: `cyfr-keeper`'s range."
  @spec runner_memory_range() :: Range.t()
  def runner_memory_range, do: @runner_memory_range

  @doc "`pool/0`, raising on a value that refuses so the boot stops there."
  @spec pool!() :: pool()
  def pool! do
    case pool() do
      {:ok, pool} ->
        pool

      {:error, {:malformed, key}} ->
        raise ArgumentError,
              "[Opus.Settings] config :opus, #{inspect(key)} is malformed: #{expected(key)}"

      {:error, {:retired, name}} ->
        raise ArgumentError, "[Opus.Settings] " <> retired(name)

      {:error, {:unknown, names}} ->
        raise ArgumentError, "[Opus.Settings] " <> unknown(names)
    end
  end

  @doc "Every `OPUS_*` name the release reads, in either role."
  @spec variables() :: [String.t()]
  def variables, do: @variables

  @doc "The `OPUS_*` names docker-compose.yml interpolates and no release reads."
  @spec compose_only() :: [String.t()]
  def compose_only, do: @compose_only

  @doc """
  The `OPUS_*` names `system` sets that the release neither reads nor
  compose interpolates, sorted. The retired `OPUS_KEEPER` is refused with a
  message of its own (`retired/1`) and is not among them.
  """
  @spec unknown_names(%{optional(String.t()) => String.t()}) :: [String.t()]
  def unknown_names(system) when is_map(system) do
    declared = [@retired_keeper_env | @variables ++ @compose_only]

    system
    |> Map.keys()
    |> Enum.filter(&(String.starts_with?(&1, "OPUS_") and &1 not in declared))
    |> Enum.sort()
  end

  @doc "Why the undeclared names `names` refuse the boot, for the message that refuses it."
  @spec unknown([String.t(), ...]) :: String.t()
  def unknown([_ | _] = names) do
    "#{Enum.join(names, ", ")} #{if match?([_], names), do: "is", else: "are"} not a " <>
      "variable the opus release reads: remove it, or use the name .env.opus.example gives"
  end

  @doc "Why the retired variable `name` refuses the boot, for the message that refuses it."
  @spec retired(String.t()) :: String.t()
  def retired(@retired_keeper_env) do
    "#{@retired_keeper_env} is retired and must not be set: the keeper channel " <>
      "cyfr-keeper starts the service with (#{@channel_env}) is the only launcher of runners"
  end

  @doc "The runner settings the process environment spells, or the first variable that refuses."
  @spec runner() :: {:ok, runner()} | {:error, {:missing | :malformed | :refused, String.t()}}
  def runner, do: runner(System.get_env())

  @doc "The runner settings `env` (a map of environment variables) spells."
  @spec runner(%{optional(String.t()) => String.t()}) ::
          {:ok, runner()} | {:error, {:missing | :malformed | :refused, String.t()}}
  def runner(env) when is_map(env) do
    with :ok <- no_service_key(env),
         {:ok, runner_id} <- id(env, "OPUS_RUNNER_ID"),
         {:ok, service_id} <- service_id(env),
         {:ok, boot} <- id(env, "OPUS_BOOT_ID"),
         {:ok, host_url} <- host_url(env),
         {:ok, control_fd} <- control_fd(env),
         {:ok, grace} <- grace(env) do
      {:ok,
       %{
         runner_id: runner_id,
         service_id: service_id,
         boot: boot,
         host_url: host_url,
         control_fd: control_fd,
         watchdog_grace_ms: grace
       }}
    end
  end

  @doc "`runner/0`, raising on a variable that refuses so the runner stops there."
  @spec runner!() :: runner()
  def runner! do
    case runner() do
      {:ok, runner} ->
        runner

      {:error, {:refused, name}} ->
        raise ArgumentError,
              "[Opus.Settings] a runner must not see #{name}: the service's key never leaves the service"

      {:error, {:missing, name}} ->
        raise ArgumentError, "[Opus.Settings] #{name} is not set"

      {:error, {:malformed, name}} ->
        raise ArgumentError, "[Opus.Settings] #{name} is malformed: #{expected(name)}"
    end
  end

  @doc """
  The environment a service gives a runner for `settings` (`t:runner/0`
  minus what the keeper decides): every `OPUS_*` variable `runner/1`
  reads, and nothing else. The keeper adds the control descriptor.
  """
  @spec runner_environment(map()) :: %{String.t() => String.t()}
  def runner_environment(%{runner_id: runner_id, service_id: service_id, boot: boot} = settings) do
    %{
      "OPUS_ROLE" => "runner",
      "OPUS_RUNNER_ID" => runner_id,
      "OPUS_SERVICE_ID" => service_id,
      "OPUS_BOOT_ID" => boot,
      "OPUS_HOST_URL" => Map.fetch!(settings, :host_url),
      "OPUS_WATCHDOG_GRACE_MS" => Integer.to_string(Map.fetch!(settings, :watchdog_grace_ms))
    }
  end

  defp positive(env, key) do
    case Keyword.get(env, key, Map.fetch!(@pool_defaults, key)) do
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
    case unknown_names(system) do
      [] -> :ok
      names -> {:error, {:unknown, names}}
    end
  end

  defp no_retired_keeper(system) do
    if is_map_key(system, @retired_keeper_env),
      do: {:error, {:retired, @retired_keeper_env}},
      else: :ok
  end

  defp attach_dir(nil), do: {:ok, @pool_defaults.attach_dir}

  defp attach_dir(dir) when is_binary(dir) do
    if Path.type(dir) == :absolute and dir == Path.expand(dir),
      do: {:ok, dir},
      else: {:error, {:malformed, :attach_dir}}
  end

  defp attach_dir(_dir), do: {:error, {:malformed, :attach_dir}}

  defp no_service_key(env) do
    if is_map_key(env, "OPUS_SERVICE_KEY"),
      do: {:error, {:refused, "OPUS_SERVICE_KEY"}},
      else: :ok
  end

  defp id(env, name) do
    case Map.get(env, name) do
      nil -> {:error, {:missing, name}}
      value -> if Regex.match?(@id, value), do: {:ok, value}, else: {:error, {:malformed, name}}
    end
  end

  defp service_id(env) do
    with {:ok, value} <- id(env, "OPUS_SERVICE_ID") do
      if Regex.match?(@service_id, value),
        do: {:ok, value},
        else: {:error, {:malformed, "OPUS_SERVICE_ID"}}
    end
  end

  defp host_url(env) do
    case Map.get(env, "OPUS_HOST_URL") do
      nil ->
        {:error, {:missing, "OPUS_HOST_URL"}}

      url ->
        case Prima.WorkerWire.base_url(url) do
          {:ok, base} -> {:ok, base}
          :error -> {:error, {:malformed, "OPUS_HOST_URL"}}
        end
    end
  end

  defp control_fd(env) do
    case Map.get(env, "OPUS_CONTROL_FD", "3") do
      text ->
        case Integer.parse(text) do
          {fd, ""} when fd >= 0 -> {:ok, fd}
          _ -> {:error, {:malformed, "OPUS_CONTROL_FD"}}
        end
    end
  end

  defp grace(env) do
    case Map.get(
           env,
           "OPUS_WATCHDOG_GRACE_MS",
           Integer.to_string(@pool_defaults.watchdog_grace_ms)
         ) do
      text ->
        case Integer.parse(text) do
          {ms, ""} when ms > 0 -> {:ok, ms}
          _ -> {:error, {:malformed, "OPUS_WATCHDOG_GRACE_MS"}}
        end
    end
  end

  @doc "What a well-formed value of `key` is, for the message that refuses one."
  @spec expected(atom() | String.t()) :: String.t()
  def expected(key) when key in [:pool_size, :idle_ttl_ms, :watchdog_grace_ms, :release_grace_ms],
    do: "a positive integer"

  def expected(:keeper), do: "one of #{Enum.map_join(keepers(), ", ", &inspect/1)}"
  def expected(:attach_dir), do: "a clean absolute directory path"

  def expected(:runner_memory_bytes) do
    first..last//1 = @runner_memory_range
    "a whole number of bytes from #{first} (16 MiB) to #{last} (1 TiB)"
  end

  def expected("OPUS_RUNNER_ID"), do: "1 to 256 bytes of printable ASCII without spaces"
  def expected("OPUS_BOOT_ID"), do: "1 to 256 bytes of printable ASCII without spaces"
  def expected("OPUS_SERVICE_ID"), do: Opus.Credentials.expected(:service_id)
  def expected("OPUS_HOST_URL"), do: Opus.Credentials.expected(:host_url)
  def expected("OPUS_CONTROL_FD"), do: "a file descriptor number, 0 for standard input and output"
  def expected("OPUS_WATCHDOG_GRACE_MS"), do: "a positive integer of milliseconds"
end
