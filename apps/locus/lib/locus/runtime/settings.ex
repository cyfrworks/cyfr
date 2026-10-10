# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Settings do
  @moduledoc """
  What the runtime role of the `locus` release runs with, beside the
  service's credentials (`Locus.Runtime.Credentials`), and the one place
  its environment variables are declared.

  ## The environment

  The service reads the `LOCUS_RUNTIME_*` names (`from_env/2`), which
  `config/locus_runtime.exs` turns into `config :locus, :runtime` on a
  node boot, and `config/runtime.exs` on a `mix` boot that runs the
  runtime beside CYFR. Those are the service's credentials and listener
  (`LOCUS_RUNTIME_SERVICE_ID`, `LOCUS_RUNTIME_KEY`,
  `LOCUS_RUNTIME_HOST_API_URL`, `LOCUS_RUNTIME_BIND`,
  `LOCUS_RUNTIME_PORT`) and its pool (`LOCUS_RUNTIME_POOL_SIZE`,
  `LOCUS_RUNTIME_IDLE_TTL_MS`, `LOCUS_RUNTIME_WATCHDOG_GRACE_MS`,
  `LOCUS_RUNTIME_RELEASE_GRACE_MS`, `LOCUS_RUNTIME_MEMORY_BYTES`,
  `LOCUS_RUNTIME_ATTACH_DIR`). A runner reads the `RUNTIME_*` names
  (`runner/1`), which the service writes for it (`runner_environment/1`)
  outside every prefix the keeper refuses in a spawn. `variables/0` is
  both lists. Any other `LOCUS_RUNTIME_*` name refuses the boot
  (`unknown_names/1`): this module declares the prefix, because the
  release carries no host module to declare it.

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
  runner `cyfr-locus` starts (`:runner_memory_bytes`, 384 MiB). Unset,
  the keeper is `:channel`, whatever the environment says: the service
  refuses to boot when no channel was inherited
  (`Locus.Runtime.Keeper.check!/3`), and never falls back to anything
  else. A value that is not a positive integer, or a keeper this build
  does not know (`keepers/0`), refuses the boot with the key named.

  `:runner_memory_bytes` is what `Locus.Runtime.Keeper.Channel` asks
  `cyfr-locus` to hold each runner to (`runner_memory_bytes/1`): a cgroup
  of the runner's own at that many bytes for its VM, every guest's linear
  memory, the pages of its home and the kernel memory charged to it,
  together. A runner that reaches it is killed whole by the kernel and
  never reused. Its range is the keeper's own for a spawn's
  `memory_bytes`, 16 MiB to 1 TiB, so a value accepted here is never
  refused there; a value outside it, or not an integer, refuses the boot.
  There is no value that asks for no bound. The test build's `:direct`
  keeper applies none: it has no cgroup to give a runner. The default is
  1.8 times the largest peak of a runner under the seed components,
  rounded up (`tests/locus-runtime-image/memory.py --measure` repeats the
  measurement). The runner's own VM is most of that peak, so the default
  leaves a subtree's guests room for two or three at the default 64 MiB
  of linear memory at once, not for one at the platform ceiling's
  256 MiB: a deployment that consents to more raises this bound with it.

  ## A runner

  The runner role reads its settings from the process environment alone
  (`runner/1`): the service passed exactly these through the keeper's
  explicit environment, and a runner holds no configuration of its own.
  `RUNTIME_RUNNER_ID` is the id it presents in its host calls,
  `RUNTIME_SERVICE_ID` and `RUNTIME_BOOT_ID` the worker service and boot
  it presents from, `RUNTIME_CONTROL_FD` the file descriptor its control
  channel is on (3 by default; 0 means the channel is its standard input
  and output), `RUNTIME_RELAY_FD` the file descriptor its relay to the
  service is on (4 by default, `Locus.Runtime.Relay.Runner`), or
  `RUNTIME_RELAY_SOCKET` the unix socket the test build's direct launcher
  gives it in its place, and `RUNTIME_WATCHDOG_GRACE_MS` the grace above.
  A runner is given no address of CYFR's: it has no network, and every
  host call it makes leaves through its relay, whose service end posts
  it. A runner that can see `LOCUS_RUNTIME_KEY` was given the service's
  own key, which no runner holds, and refuses to start.
  """

  alias Prima.EnvValue

  @service_id ~r/\Awrk_[A-Za-z0-9_-]{1,64}\z/
  @id ~r/\A[\x21-\x7E]{1,256}\z/

  # The prefix this module declares for the service.
  @prefix "LOCUS_RUNTIME_"

  # Every `LOCUS_RUNTIME_*` name the service reads (`from_env/2`): its
  # credentials and listener (`Locus.Runtime.Credentials`) and its pool
  # (`pool/2`).
  @service_variables ~w(LOCUS_RUNTIME_SERVICE_ID LOCUS_RUNTIME_KEY LOCUS_RUNTIME_HOST_API_URL
                        LOCUS_RUNTIME_BIND LOCUS_RUNTIME_PORT LOCUS_RUNTIME_POOL_SIZE
                        LOCUS_RUNTIME_IDLE_TTL_MS LOCUS_RUNTIME_WATCHDOG_GRACE_MS
                        LOCUS_RUNTIME_RELEASE_GRACE_MS LOCUS_RUNTIME_MEMORY_BYTES
                        LOCUS_RUNTIME_ATTACH_DIR)

  # Every `RUNTIME_*` name a runner reads: the role itself
  # (`Locus.Runtime.Release.role/1`) and the runner's environment
  # (`runner/1`), which the service writes (`runner_environment/1`). The
  # keeper refuses every `CYFR_`, `LOCUS_` and `KEEPER_` name in a spawn,
  # so none of these carries one of those prefixes.
  @runner_variables ~w(RUNTIME_ROLE RUNTIME_RUNNER_ID RUNTIME_SERVICE_ID RUNTIME_BOOT_ID
                       RUNTIME_CONTROL_FD RUNTIME_RELAY_FD RUNTIME_RELAY_SOCKET
                       RUNTIME_WATCHDOG_GRACE_MS)

  # The variable each setting `from_env/2` reads is spelled by.
  @setting_variables %{
    service_id: "LOCUS_RUNTIME_SERVICE_ID",
    service_key: "LOCUS_RUNTIME_KEY",
    host_url: "LOCUS_RUNTIME_HOST_API_URL",
    bind: "LOCUS_RUNTIME_BIND",
    port: "LOCUS_RUNTIME_PORT",
    pool_size: "LOCUS_RUNTIME_POOL_SIZE",
    idle_ttl_ms: "LOCUS_RUNTIME_IDLE_TTL_MS",
    watchdog_grace_ms: "LOCUS_RUNTIME_WATCHDOG_GRACE_MS",
    release_grace_ms: "LOCUS_RUNTIME_RELEASE_GRACE_MS",
    runner_memory_bytes: "LOCUS_RUNTIME_MEMORY_BYTES",
    attach_dir: "LOCUS_RUNTIME_ATTACH_DIR"
  }

  # What a service boot falls back to when neither its environment nor
  # the caller's fallback names a value.
  @service_defaults [service_id: "wrk_local", bind: "127.0.0.1", port: 4200]

  # cyfr-locus's range for a spawn's `memory_bytes`
  # (`apps/locus/keeper/internal/protocol`: MinMemoryBytes, MaxMemoryBytes).
  @runner_memory_range 16_777_216..1_099_511_627_776

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

  @typedoc "The runner role's settings, as its environment spells them."
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

  @doc "The pool settings `config :locus, :runtime` spells, or the first key that refuses."
  @spec pool() :: {:ok, pool()} | {:error, pool_refusal()}
  def pool, do: pool(env(), System.get_env())

  @doc """
  The pool settings `env` (the `:runtime` keyword of the `:locus`
  application environment) spells, under the environment `system` (the
  process environment, or what a boot read), which must set no
  `LOCUS_RUNTIME_*` name the service does not declare.
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
  an integer from 16 MiB to 1 TiB refuses.
  """
  @spec runner_memory_bytes(keyword()) ::
          {:ok, pos_integer()} | {:error, {:malformed, :runner_memory_bytes}}
  def runner_memory_bytes(env) when is_list(env) do
    case Keyword.get(env, :runner_memory_bytes, @pool_defaults.runner_memory_bytes) do
      bytes when is_integer(bytes) and bytes in @runner_memory_range -> {:ok, bytes}
      _ -> {:error, {:malformed, :runner_memory_bytes}}
    end
  end

  @doc "The least and the most a runner's memory bound may be, in bytes: `cyfr-locus`'s range."
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
              "[Locus.Runtime.Settings] config :locus, :runtime, #{inspect(key)} is malformed: " <>
                expected(key)

      {:error, {:unknown, names}} ->
        raise ArgumentError, "[Locus.Runtime.Settings] " <> unknown(names)
    end
  end

  @doc """
  Every name the runtime role reads: the service's `LOCUS_RUNTIME_*` names,
  then the runner's `RUNTIME_*` names.
  """
  @spec variables() :: [String.t()]
  def variables, do: @service_variables ++ @runner_variables

  @doc """
  The `LOCUS_RUNTIME_*` names in `names` (a list of names, or a map of
  environment variables) that the service does not read, sorted, each once.
  """
  @spec unknown_names([String.t()] | %{optional(String.t()) => String.t()}) :: [String.t()]
  def unknown_names(system) when is_map(system), do: unknown_names(Map.keys(system))

  def unknown_names(names) when is_list(names) do
    names
    |> Enum.filter(&(String.starts_with?(&1, @prefix) and &1 not in @service_variables))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Why the undeclared names `names` refuse the boot, for the message that refuses it."
  @spec unknown([String.t(), ...]) :: String.t()
  def unknown([_ | _] = names) do
    "#{Enum.join(names, ", ")} #{if match?([_], names), do: "is", else: "are"} not a " <>
      "variable the locus release reads: remove it, or use the name .env.locus.example gives"
  end

  @doc """
  The runtime role's `config :locus, :runtime` the environment `getenv`
  spells over `fallback`, or `{:ok, nil}` when no service key is held:
  `LOCUS_RUNTIME_KEY` is unset and `fallback` names no `:service_key`, so
  the node serves no runtime.

  A setting is the variable's value when set, else `fallback`'s, else the
  service's default (`wrk_local`, `127.0.0.1`, port 4200); a pool setting
  is present only where its variable is set, so the code's defaults stand
  for the rest. The answer is in the shape `Locus.Runtime.Credentials` and
  `pool/2` read: the key as hexadecimal text, the bind as a string, the
  port an integer. A value either refuses answers `{:error, message}`
  naming its variable; no message echoes the key.
  """
  @spec from_env(EnvValue.getenv(), keyword()) :: {:ok, keyword() | nil} | {:error, String.t()}
  def from_env(getenv, fallback \\ []) when is_function(getenv, 1) and is_list(fallback) do
    {:ok, key} = EnvValue.text(getenv, "LOCUS_RUNTIME_KEY")

    case key || Keyword.get(fallback, :service_key) do
      nil -> {:ok, nil}
      key -> service_from_env(getenv, fallback, key)
    end
  end

  defp service_from_env(getenv, fallback, key) do
    setting = fn name ->
      {:ok, text} = EnvValue.text(getenv, Map.fetch!(@setting_variables, name))
      text || Keyword.get(fallback, name) || Keyword.get(@service_defaults, name)
    end

    with {:ok, port} <- port_setting(setting.(:port)),
         credentials = [
           service_id: setting.(:service_id),
           service_key: key,
           host_url: setting.(:host_url),
           bind: setting.(:bind),
           port: port
         ],
         :ok <- credentials_refusal(credentials),
         {:ok, pool} <- pool_from_env(getenv),
         {:ok, _pool} <- named(pool_of(pool)) do
      {:ok, credentials ++ pool}
    end
  end

  defp port_setting(port) when is_integer(port), do: {:ok, port}

  defp port_setting(text) when is_binary(text) do
    case Integer.parse(text) do
      {port, ""} -> {:ok, port}
      _ -> named({:error, {:malformed, :port}})
    end
  end

  defp credentials_refusal(credentials) do
    case Locus.Runtime.Credentials.load(credentials) do
      {:ok, _credentials} -> :ok
      {:error, refusal} -> named({:error, refusal})
    end
  end

  # Only the set ones: each read strictly (`Prima.EnvValue`), so a value
  # that is not a whole number in its range refuses naming its variable.
  defp pool_from_env(getenv) do
    reads = [
      pool_size: &EnvValue.whole_number(&1, &2, 1..1_024, "runners"),
      idle_ttl_ms: &EnvValue.milliseconds(&1, &2, 1..86_400_000),
      watchdog_grace_ms: &EnvValue.milliseconds(&1, &2, 1..600_000),
      release_grace_ms: &EnvValue.milliseconds(&1, &2, 1..600_000),
      runner_memory_bytes: &EnvValue.bytes(&1, &2, @runner_memory_range),
      attach_dir: &EnvValue.text(&1, &2)
    ]

    Enum.reduce_while(reads, {:ok, []}, fn {name, read}, {:ok, pool} ->
      case read.(getenv, Map.fetch!(@setting_variables, name)) do
        {:ok, nil} -> {:cont, {:ok, pool}}
        {:ok, value} -> {:cont, {:ok, pool ++ [{name, value}]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # A refusal of a setting, as the message naming the variable that spells it.
  defp named({:error, {:missing, name}}),
    do: {:error, "#{Map.fetch!(@setting_variables, name)} is not set"}

  defp named({:error, {:malformed, name}}),
    do: {:error, "#{Map.fetch!(@setting_variables, name)} must be #{setting_expected(name)}"}

  defp named(other), do: other

  defp setting_expected(name) when name in [:service_id, :service_key, :host_url, :bind, :port],
    do: Locus.Runtime.Credentials.expected(name)

  defp setting_expected(name), do: expected(name)

  @doc "The runner settings the process environment spells, or the first variable that refuses."
  @spec runner() :: {:ok, runner()} | {:error, {:missing | :malformed | :refused, String.t()}}
  def runner, do: runner(System.get_env())

  @doc "The runner settings `env` (a map of environment variables) spells."
  @spec runner(%{optional(String.t()) => String.t()}) ::
          {:ok, runner()} | {:error, {:missing | :malformed | :refused, String.t()}}
  def runner(env) when is_map(env) do
    with :ok <- no_service_key(env),
         {:ok, runner_id} <- id(env, "RUNTIME_RUNNER_ID"),
         {:ok, service_id} <- service_id(env),
         {:ok, boot} <- id(env, "RUNTIME_BOOT_ID"),
         {:ok, control_fd} <- control_fd(env),
         {:ok, relay} <- relay(env),
         {:ok, grace} <- grace(env) do
      {:ok,
       %{
         runner_id: runner_id,
         service_id: service_id,
         boot: boot,
         control_fd: control_fd,
         relay: relay,
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
              "[Locus.Runtime.Settings] a runner must not see #{name}: the service's key never leaves the service"

      {:error, {:missing, name}} ->
        raise ArgumentError, "[Locus.Runtime.Settings] #{name} is not set"

      {:error, {:malformed, name}} ->
        raise ArgumentError, "[Locus.Runtime.Settings] #{name} is malformed: #{expected(name)}"
    end
  end

  @doc """
  The environment a service gives a runner for `settings` (`t:runner/0`
  minus what the keeper decides): every `RUNTIME_*` variable `runner/1`
  reads, and nothing else, so no name the keeper refuses in a spawn. The keeper adds the control and relay
  descriptors. No address of CYFR's is among them: the runner reaches
  CYFR only through its relay.
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

  defp attach_dir(nil), do: {:ok, @pool_defaults.attach_dir}

  defp attach_dir(dir) when is_binary(dir) do
    if Path.type(dir) == :absolute and dir == Path.expand(dir),
      do: {:ok, dir},
      else: {:error, {:malformed, :attach_dir}}
  end

  defp attach_dir(_dir), do: {:error, {:malformed, :attach_dir}}

  defp no_service_key(env) do
    if is_map_key(env, "LOCUS_RUNTIME_KEY"),
      do: {:error, {:refused, "LOCUS_RUNTIME_KEY"}},
      else: :ok
  end

  defp id(env, name) do
    case Map.get(env, name) do
      nil -> {:error, {:missing, name}}
      value -> if Regex.match?(@id, value), do: {:ok, value}, else: {:error, {:malformed, name}}
    end
  end

  defp service_id(env) do
    with {:ok, value} <- id(env, "RUNTIME_SERVICE_ID") do
      if Regex.match?(@service_id, value),
        do: {:ok, value},
        else: {:error, {:malformed, "RUNTIME_SERVICE_ID"}}
    end
  end

  defp control_fd(env) do
    case Map.get(env, "RUNTIME_CONTROL_FD", "3") do
      text ->
        case Integer.parse(text) do
          {fd, ""} when fd >= 0 -> {:ok, fd}
          _ -> {:error, {:malformed, "RUNTIME_CONTROL_FD"}}
        end
    end
  end

  # The keeper's descriptor 4, or the unix socket the test build's direct
  # launcher names in its place: an absolute path, which wins when set.
  defp relay(env) do
    case Map.fetch(env, "RUNTIME_RELAY_SOCKET") do
      {:ok, "/" <> _ = path} ->
        if Path.expand(path) == path,
          do: {:ok, {:socket, path}},
          else: {:error, {:malformed, "RUNTIME_RELAY_SOCKET"}}

      {:ok, _other} ->
        {:error, {:malformed, "RUNTIME_RELAY_SOCKET"}}

      :error ->
        case Integer.parse(Map.get(env, "RUNTIME_RELAY_FD", "4")) do
          {fd, ""} when fd > 2 -> {:ok, {:fd, fd}}
          _ -> {:error, {:malformed, "RUNTIME_RELAY_FD"}}
        end
    end
  end

  defp grace(env) do
    case Map.get(
           env,
           "RUNTIME_WATCHDOG_GRACE_MS",
           Integer.to_string(@pool_defaults.watchdog_grace_ms)
         ) do
      text ->
        case Integer.parse(text) do
          {ms, ""} when ms > 0 -> {:ok, ms}
          _ -> {:error, {:malformed, "RUNTIME_WATCHDOG_GRACE_MS"}}
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

  def expected("RUNTIME_RUNNER_ID"), do: "1 to 256 bytes of printable ASCII without spaces"
  def expected("RUNTIME_BOOT_ID"), do: "1 to 256 bytes of printable ASCII without spaces"
  def expected("RUNTIME_SERVICE_ID"), do: Locus.Runtime.Credentials.expected(:service_id)

  def expected("RUNTIME_CONTROL_FD"),
    do: "a file descriptor number, 0 for standard input and output"

  def expected("RUNTIME_RELAY_FD"), do: "a file descriptor number above 2"
  def expected("RUNTIME_RELAY_SOCKET"), do: "an absolute path to a unix socket"
  def expected("RUNTIME_WATCHDOG_GRACE_MS"), do: "a positive integer of milliseconds"
end
