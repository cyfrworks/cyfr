# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Config do
  @moduledoc """
  Every environment variable of the `locus` release, declared, read and
  refused in one place: one roster of rows by role (`variables/0`,
  `variables/1`). The release carries no host module to declare its
  prefixes, so this module declares them, and refuses a `LOCUS_*` name
  the roster lacks (`unknown_names/1,2`, `unknown/1`).

  A node's settings are read from the release's environment by
  `config/locus_runtime.exs` (`from_env/2`), which writes them as the
  `:locus` application environment and nothing else, and read back
  through the accessors below, each with its default. The builds service
  reads the `LOCUS_BUILDS_*` rows, the backends service (`Locus.Backends`)
  the `LOCUS_BACKENDS_*` rows, and every role the `LOCUS_LOG_*` rows. The
  runtime role's `LOCUS_RUNTIME_*` rows are read into one keyword, written
  under the `:runtime` key (`runtime_from_env/1`), which
  `Locus.Runtime.Credentials` and `Locus.Runtime.Settings` read.

  | Variable | Setting | Accepted | Default |
  |---|---|---|---|
  | `LOCUS_BUILDS_KEY` | `:request_key` | 64 hexadecimal digits, the builds service key | none: the node serves no builds |
  | `LOCUS_BUILDS_BIND` | `:bind` | an IPv4 or IPv6 address | `0.0.0.0` |
  | `LOCUS_BUILDS_PORT` | `:port` | 1..65535 | 4100 |
  | `LOCUS_BUILDS_TIMEOUT_MS` | `:timeout_ms` | 1000..600000 | 270000 |
  | `LOCUS_BUILDS_MAX_CONCURRENT` | `:max_concurrent` | 1..1024 | 2 |
  | `LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT` | `:max_concurrent_per_tenant` | 1..1024 | 1 |
  | `LOCUS_BUILDS_MEMORY_BYTES` | `:memory_bytes` | 16777216..1099511627776 (16 MiB to 1 TiB) | 1073741824 (1 GiB) |
  | `LOCUS_BUILDS_CARGO_SEED` | `:cargo_seed` | a directory | none |
  | `LOCUS_LOG_LEVEL` | `:log_level` | a Logger level | `info` |
  | `LOCUS_LOG_FORMAT` | `:log_format` | `text` or `json` | `text` |
  | `LOCUS_BACKENDS_KEY` | `:backends_key` | 64 hexadecimal digits, the backends service key | none: the node serves no backends |
  | `LOCUS_BACKENDS_BIND` | `:backends_bind` | an IPv4 or IPv6 address | `0.0.0.0` |
  | `LOCUS_BACKENDS_PORT` | `:backends_port` | 1..65535 | 4101 |
  | `LOCUS_BACKENDS_MAX_IN_FLIGHT` | `:backends_max_in_flight` | 1..1024 | #{Prima.LocusBackends.max_in_flight()} |
  | `LOCUS_BACKENDS_INIT_TIMEOUT_MS` | `:backends_init_timeout_ms` | 1000..600000 | 15000 |
  | `LOCUS_BACKENDS_RPC_TIMEOUT_MS` | `:backends_rpc_timeout_ms` | 1000..600000 | 30000 |
  | `LOCUS_BACKENDS_MEMORY_BYTES` | `:backends_memory_bytes` | 16777216..1099511627776 (16 MiB to 1 TiB) | 536870912 (512 MiB) |
  | `LOCUS_RUNTIME_SERVICE_ID` | `:runtime`, `:service_id` | `wrk_` and 1 to 64 letters, digits, `_` or `-` | `wrk_local` |
  | `LOCUS_RUNTIME_KEY` | `:runtime`, `:service_key` | 64 hexadecimal digits, the key derived for the service's id | none: the node serves no runtime |
  | `LOCUS_RUNTIME_HOST_API_URL` | `:runtime`, `:host_url` | an http or https URL with a host and no path | none |
  | `LOCUS_RUNTIME_BIND` | `:runtime`, `:bind` | an IPv4 or IPv6 address | `127.0.0.1` |
  | `LOCUS_RUNTIME_PORT` | `:runtime`, `:port` | 0..65535 | 4200 |
  | `LOCUS_RUNTIME_POOL_SIZE` | `:runtime`, `:pool_size` | 1..1024 | 4 |
  | `LOCUS_RUNTIME_IDLE_TTL_MS` | `:runtime`, `:idle_ttl_ms` | 1..86400000 | 30000 |
  | `LOCUS_RUNTIME_WATCHDOG_GRACE_MS` | `:runtime`, `:watchdog_grace_ms` | 1..600000 | 5000 |
  | `LOCUS_RUNTIME_RELEASE_GRACE_MS` | `:runtime`, `:release_grace_ms` | 1..600000 | 2000 |
  | `LOCUS_RUNTIME_MEMORY_BYTES` | `:runtime`, `:runner_memory_bytes` | 16777216..1099511627776 (16 MiB to 1 TiB) | 402653184 (384 MiB) |
  | `LOCUS_RUNTIME_ATTACH_DIR` | `:runtime`, `:attach_dir` | a clean absolute directory path | `/run/locus` |

  An unset runtime identity or listener row takes the default above; a
  pool row is written only when its variable is set, so
  `Locus.Runtime.Settings`' defaults stand for the rest.

  A runner is no node: it reads the `RUNTIME_*` rows (`runner/1`), which
  its service writes for it outside every prefix the keeper refuses in a
  spawn (`Locus.Runtime.Settings.runner_environment/1`), and nothing else
  of the release. `RUNTIME_ROLE` is `runner` for one
  (`Locus.Runtime.Release.role/1`, `config/locus_runtime.exs`);
  `RUNTIME_RUNNER_ID` is the id it presents in its host calls,
  `RUNTIME_SERVICE_ID` and `RUNTIME_BOOT_ID` the worker service and boot
  it presents from, `RUNTIME_CONTROL_FD` the file descriptor its control
  channel is on (3 by default; 0 means the channel is its standard input
  and output), `RUNTIME_RELAY_SOCKET` the unix socket the test build's
  direct launcher gives it for its relay to the service in place of the
  file descriptor 4 cyfr-locus places it on (`Locus.Runtime.Relay.Runner`),
  and `RUNTIME_WATCHDOG_GRACE_MS` how far past its
  assignment's deadline it may live (`Locus.Runtime.Settings`' default
  when unset). A runner is given no address of CYFR's: it has no network,
  and every host call it makes leaves through its relay. A runner that
  can see `LOCUS_RUNTIME_KEY` was given the service's own key, which no
  runner holds, and refuses to start. `RUNTIME_*` names are never refused
  as unknown.

  A node serves the runtime when it holds the runtime's key, the builds
  service when it holds a builds key and the backends service when it
  holds a backends key (`Locus.Application`); the release must hold at
  least one, and a node holding the runtime's key holds no other.
  `:request_key` is the key build requests are verified with
  (`Prima.BuilderProtocol.request_key/1`), derived once here; the
  configured builds key itself is kept nowhere.
  `:backends_key` is the backends service key itself, decoded: every
  owner's key is derived from it per request
  (`Prima.LocusBackends.owner_key/2`). A set variable that does not parse,
  or none of the three keys, refuses the boot with a message naming the
  variable. So does the control plane's configuration in the node's
  environment, first, on every boot of every role
  (`refused_environment/1`): the database URL, the keyring, the
  runtime's root and the control plane's copies of the builds and
  backends keys are CYFR's, and a node that can see them was given more
  than it holds. And so does any `LOCUS_*` name the roster lacks.

  `:memory_bytes` is the bound every build's spawn asks cyfr-locus for
  (`Locus.Keeper`), `:backends_memory_bytes` the bound each backend's
  process is spawned under, and the runtime's `:runner_memory_bytes` the
  bound of each runner: the memory of the processes, what they write
  to their home and the kernel memory charged to them, together. Their
  range is the keeper's own for a spawn's `memory_bytes`
  (`memory_range/0`, from `Prima.KeeperProtocol`), so a value accepted
  here is one the keeper accepts. There is no value that means "no
  bound". `:backends_max_in_flight` is the calls that may await one
  backend at a time, and the two timeouts bound a backend's handshake and
  each call to it.

  A node's logging is the release's one setting whichever role it serves:
  `:log_level` and `:log_format` become the logger's when a release node
  that serves a role starts (`Locus.Application`). A runner reads neither:
  it logs at the default level, as plain text to standard error.

  Where the environment was never read — a development node, the test
  suite — every accessor answers its default and both keys are nil, so no
  request verifies, the node serves neither service and its logger stays
  the one its config files set (`Locus.Application`).
  """

  alias Prima.EnvValue

  # 30 s under the build tool's five-minute limit on a synchronous compile,
  # so a build that exhausts its budget ends here as timed out.
  @default_timeout_ms 270_000

  # A `cargo component build` or npm bundle occupies a CPU core and hundreds
  # of MB for minutes, so a builder accepts a couple at once, and one per
  # athanor: a single athanor must not be able to hold every slot.
  @defaults [
    bind: {0, 0, 0, 0},
    port: 4100,
    timeout_ms: @default_timeout_ms,
    max_concurrent: 2,
    max_concurrent_per_tenant: 1,
    memory_bytes: 1_073_741_824,
    cargo_seed: nil,
    log_level: :info,
    log_format: :text,
    backends_bind: {0, 0, 0, 0},
    backends_port: 4101,
    backends_max_in_flight: Prima.LocusBackends.max_in_flight(),
    backends_init_timeout_ms: 15_000,
    backends_rpc_timeout_ms: 30_000,
    backends_memory_bytes: 536_870_912
  ]

  # What the runtime falls back to when neither its environment nor the
  # caller's fallback names a value.
  @runtime_defaults [service_id: "wrk_local", bind: "127.0.0.1", port: 4200]

  @control_plane_only ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_LOCUS_RUNTIME_ROOT
                         CYFR_LOCUS_BUILDS_KEY CYFR_LOCUS_BACKENDS_KEY)

  # Every variable of the release, `{variable, role, key}`: the key its
  # role's reader answers it under (the flat `:locus` keys for builds,
  # backends and the release's log setting, the `:runtime` keyword's keys
  # for the runtime, a runner's settings for a runner). A role's rows are
  # in its reader's order, so every answer keeps its order.
  @roster [
    {"LOCUS_BUILDS_KEY", :builds, :request_key},
    {"LOCUS_BUILDS_BIND", :builds, :bind},
    {"LOCUS_BUILDS_PORT", :builds, :port},
    {"LOCUS_BUILDS_TIMEOUT_MS", :builds, :timeout_ms},
    {"LOCUS_BUILDS_MAX_CONCURRENT", :builds, :max_concurrent},
    {"LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT", :builds, :max_concurrent_per_tenant},
    {"LOCUS_BUILDS_MEMORY_BYTES", :builds, :memory_bytes},
    {"LOCUS_BUILDS_CARGO_SEED", :builds, :cargo_seed},
    {"LOCUS_LOG_LEVEL", :release, :log_level},
    {"LOCUS_LOG_FORMAT", :release, :log_format},
    {"LOCUS_BACKENDS_KEY", :backends, :backends_key},
    {"LOCUS_BACKENDS_BIND", :backends, :backends_bind},
    {"LOCUS_BACKENDS_PORT", :backends, :backends_port},
    {"LOCUS_BACKENDS_MAX_IN_FLIGHT", :backends, :backends_max_in_flight},
    {"LOCUS_BACKENDS_INIT_TIMEOUT_MS", :backends, :backends_init_timeout_ms},
    {"LOCUS_BACKENDS_RPC_TIMEOUT_MS", :backends, :backends_rpc_timeout_ms},
    {"LOCUS_BACKENDS_MEMORY_BYTES", :backends, :backends_memory_bytes},
    {"LOCUS_RUNTIME_SERVICE_ID", :runtime, :service_id},
    {"LOCUS_RUNTIME_KEY", :runtime, :service_key},
    {"LOCUS_RUNTIME_HOST_API_URL", :runtime, :host_url},
    {"LOCUS_RUNTIME_BIND", :runtime, :bind},
    {"LOCUS_RUNTIME_PORT", :runtime, :port},
    {"LOCUS_RUNTIME_POOL_SIZE", :runtime, :pool_size},
    {"LOCUS_RUNTIME_IDLE_TTL_MS", :runtime, :idle_ttl_ms},
    {"LOCUS_RUNTIME_WATCHDOG_GRACE_MS", :runtime, :watchdog_grace_ms},
    {"LOCUS_RUNTIME_RELEASE_GRACE_MS", :runtime, :release_grace_ms},
    {"LOCUS_RUNTIME_MEMORY_BYTES", :runtime, :runner_memory_bytes},
    {"LOCUS_RUNTIME_ATTACH_DIR", :runtime, :attach_dir},
    {"RUNTIME_ROLE", :runner, :role},
    {"RUNTIME_RUNNER_ID", :runner, :runner_id},
    {"RUNTIME_SERVICE_ID", :runner, :service_id},
    {"RUNTIME_BOOT_ID", :runner, :boot},
    {"RUNTIME_CONTROL_FD", :runner, :control_fd},
    {"RUNTIME_RELAY_SOCKET", :runner, :relay_socket},
    {"RUNTIME_WATCHDOG_GRACE_MS", :runner, :watchdog_grace_ms}
  ]

  # The one prefix every name of a role carries. The keeper refuses every
  # `CYFR_`, `LOCUS_` and `KEEPER_` name in a spawn, so a runner's is none
  # of those.
  @prefixes %{
    builds: "LOCUS_BUILDS_",
    release: "LOCUS_LOG_",
    backends: "LOCUS_BACKENDS_",
    runtime: "LOCUS_RUNTIME_",
    runner: "RUNTIME_"
  }

  @variables Enum.map(@roster, &elem(&1, 0))

  # The variable each reader reads, by role and key.
  @variable Map.new(@roster, fn {variable, role, key} -> {{role, key}, variable} end)

  # The runner's key of each runner variable, for the sentence that
  # refuses a malformed one.
  @runner_keys for {variable, :runner, key} <- @roster, into: %{}, do: {variable, key}

  # The runtime's settings that are the service's credentials and
  # listener (`Locus.Runtime.Credentials`); the rest are its pool's
  # (`Locus.Runtime.Settings`).
  @credential_keys [:service_id, :service_key, :host_url, :bind, :port]

  # A runner's ids: printable ASCII without spaces. The service's id is a
  # worker service id besides.
  @id ~r/\A[\x21-\x7E]{1,256}\z/
  @service_id ~r/\Awrk_[A-Za-z0-9_-]{1,64}\z/

  @typedoc "A role of the release's roster: one prefix, and the rows its reader reads."
  @type role :: :runtime | :builds | :backends | :release | :runner

  @typedoc "The `:locus` application environment `from_env/2` writes."
  @type settings :: [
          request_key: binary() | nil,
          bind: :inet.ip_address(),
          port: :inet.port_number(),
          timeout_ms: pos_integer(),
          max_concurrent: pos_integer(),
          max_concurrent_per_tenant: pos_integer(),
          memory_bytes: pos_integer(),
          cargo_seed: String.t() | nil,
          log_level: Logger.level(),
          log_format: :text | :json,
          backends_key: binary() | nil,
          backends_bind: :inet.ip_address(),
          backends_port: :inet.port_number(),
          backends_max_in_flight: pos_integer(),
          backends_init_timeout_ms: pos_integer(),
          backends_rpc_timeout_ms: pos_integer(),
          backends_memory_bytes: pos_integer(),
          runtime: keyword()
        ]

  @doc """
  The `:locus` settings the environment `getenv` spells, every one present
  with its default where unset, or the first refusal as a message naming
  the variable. `names` is every name that environment assigns, the
  process environment's by default: a `LOCUS_*` one the roster lacks
  refuses too. The runtime role's settings are present under `:runtime`
  only when the runtime's key is set (`runtime_from_env/1`).
  """
  @spec from_env(EnvValue.getenv(), [String.t()]) :: {:ok, settings()} | {:error, String.t()}
  def from_env(getenv, names \\ Map.keys(System.get_env()))
      when is_function(getenv, 1) and is_list(names) do
    with [] <- refused_environment(getenv),
         :ok <- no_unknown(names),
         {:ok, builds} <- builds(getenv),
         {:ok, backends} <- backends(getenv),
         {:ok, runtime} <- runtime_from_env(getenv),
         :ok <- some_key(builds, backends, runtime),
         {:ok, log_level} <- log_level(getenv),
         {:ok, log_format} <- log_format(getenv) do
      {:ok,
       builds ++
         [log_level: log_level, log_format: log_format] ++
         backends ++ if(runtime, do: [runtime: runtime], else: [])}
    else
      {:error, message} ->
        {:error, message}

      refused when is_list(refused) ->
        {:error,
         "the locus release must not see #{Enum.join(refused, ", ")}: the database, " <>
           "the keyring, the runtime's root and the control plane's builds and backends " <>
           "keys are CYFR's"}
    end
  end

  defp builds(getenv) do
    with {:ok, key} <- EnvValue.hex_key(getenv, variable(:builds, :request_key)),
         {:ok, bind} <- EnvValue.bind(getenv, variable(:builds, :bind)),
         {:ok, port} <- EnvValue.port(getenv, variable(:builds, :port)),
         {:ok, timeout_ms} <-
           EnvValue.milliseconds(getenv, variable(:builds, :timeout_ms), 1_000..600_000),
         {:ok, max} <-
           EnvValue.whole_number(getenv, variable(:builds, :max_concurrent), 1..1024, "builds"),
         {:ok, per_tenant} <-
           EnvValue.whole_number(
             getenv,
             variable(:builds, :max_concurrent_per_tenant),
             1..1024,
             "builds"
           ),
         {:ok, memory_bytes} <-
           EnvValue.bytes(getenv, variable(:builds, :memory_bytes), memory_range()),
         {:ok, cargo_seed} <- EnvValue.text(getenv, variable(:builds, :cargo_seed)) do
      {:ok,
       [
         request_key: key && Prima.BuilderProtocol.request_key(key),
         bind: bind || @defaults[:bind],
         port: port || @defaults[:port],
         timeout_ms: timeout_ms || @defaults[:timeout_ms],
         max_concurrent: max || @defaults[:max_concurrent],
         max_concurrent_per_tenant: per_tenant || @defaults[:max_concurrent_per_tenant],
         memory_bytes: memory_bytes || @defaults[:memory_bytes],
         cargo_seed: cargo_seed
       ]}
    end
  end

  defp backends(getenv) do
    with {:ok, key} <- EnvValue.hex_key(getenv, variable(:backends, :backends_key)),
         {:ok, bind} <- EnvValue.bind(getenv, variable(:backends, :backends_bind)),
         {:ok, port} <- EnvValue.port(getenv, variable(:backends, :backends_port)),
         {:ok, max_in_flight} <-
           EnvValue.whole_number(
             getenv,
             variable(:backends, :backends_max_in_flight),
             1..1024,
             "calls"
           ),
         {:ok, init_timeout_ms} <-
           EnvValue.milliseconds(
             getenv,
             variable(:backends, :backends_init_timeout_ms),
             1_000..600_000
           ),
         {:ok, rpc_timeout_ms} <-
           EnvValue.milliseconds(
             getenv,
             variable(:backends, :backends_rpc_timeout_ms),
             1_000..600_000
           ),
         {:ok, memory_bytes} <-
           EnvValue.bytes(getenv, variable(:backends, :backends_memory_bytes), memory_range()) do
      {:ok,
       [
         backends_key: key,
         backends_bind: bind || @defaults[:backends_bind],
         backends_port: port || @defaults[:backends_port],
         backends_max_in_flight: max_in_flight || @defaults[:backends_max_in_flight],
         backends_init_timeout_ms: init_timeout_ms || @defaults[:backends_init_timeout_ms],
         backends_rpc_timeout_ms: rpc_timeout_ms || @defaults[:backends_rpc_timeout_ms],
         backends_memory_bytes: memory_bytes || @defaults[:backends_memory_bytes]
       ]}
    end
  end

  # A release that holds none of the three keys would serve nothing.
  defp some_key(builds, backends, runtime) do
    if builds[:request_key] == nil and backends[:backends_key] == nil and runtime == nil do
      {:error,
       "LOCUS_RUNTIME_KEY, LOCUS_BUILDS_KEY and LOCUS_BACKENDS_KEY are all unset; a server " <>
         "serves the runtime with the first, builds with the second and backends with the " <>
         "third (64 hexadecimal digits each: the key `mix cyfr.locus.runtime_key` derives " <>
         "from CYFR_LOCUS_RUNTIME_ROOT, and the same key as CYFR_LOCUS_BUILDS_KEY or " <>
         "CYFR_LOCUS_BACKENDS_KEY on the server)."}
    else
      :ok
    end
  end

  @doc """
  The runtime role's `config :locus, :runtime` the environment `getenv`
  spells, or `{:ok, nil}` when `LOCUS_RUNTIME_KEY` is unset, so the node
  serves no runtime.

  A setting is the variable's value when set, else the service's default
  (`wrk_local`, `127.0.0.1`, port 4200); a pool setting
  is present only where its variable is set, so the code's defaults stand
  for the rest. The answer is in the shape `Locus.Runtime.Credentials` and
  `Locus.Runtime.Settings.pool/2` read: the key as hexadecimal text, the
  bind as a string, the port an integer. A value either refuses answers
  `{:error, message}` naming its variable; no message echoes the key.
  """
  @spec runtime_from_env(EnvValue.getenv()) :: {:ok, keyword() | nil} | {:error, String.t()}
  def runtime_from_env(getenv) when is_function(getenv, 1) do
    case EnvValue.text(getenv, variable(:runtime, :service_key)) do
      {:ok, nil} -> {:ok, nil}
      {:ok, key} -> runtime_service(getenv, key)
    end
  end

  defp runtime_service(getenv, key) do
    setting = fn name ->
      {:ok, text} = EnvValue.text(getenv, variable(:runtime, name))
      text || Keyword.get(@runtime_defaults, name)
    end

    with {:ok, port} <- runtime_port(setting.(:port)),
         credentials = [
           service_id: setting.(:service_id),
           service_key: key,
           host_url: setting.(:host_url),
           bind: setting.(:bind),
           port: port
         ],
         :ok <- credentials_refusal(credentials),
         {:ok, pool} <- runtime_pool(getenv),
         {:ok, _pool} <- runtime_named(Locus.Runtime.Settings.pool(pool, %{})) do
      {:ok, credentials ++ pool}
    end
  end

  defp runtime_port(port) when is_integer(port), do: {:ok, port}

  defp runtime_port(text) when is_binary(text) do
    case Integer.parse(text) do
      {port, ""} -> {:ok, port}
      _ -> runtime_named({:error, {:malformed, :port}})
    end
  end

  defp credentials_refusal(credentials) do
    case Locus.Runtime.Credentials.load(credentials) do
      {:ok, _credentials} -> :ok
      {:error, refusal} -> runtime_named({:error, refusal})
    end
  end

  # Only the set ones: each read strictly (`Prima.EnvValue`), so a value
  # that is not a whole number in its range refuses naming its variable.
  defp runtime_pool(getenv) do
    reads = [
      pool_size: &EnvValue.whole_number(&1, &2, 1..1_024, "runners"),
      idle_ttl_ms: &EnvValue.milliseconds(&1, &2, 1..86_400_000),
      watchdog_grace_ms: &EnvValue.milliseconds(&1, &2, 1..600_000),
      release_grace_ms: &EnvValue.milliseconds(&1, &2, 1..600_000),
      runner_memory_bytes: &EnvValue.bytes(&1, &2, memory_range()),
      attach_dir: &EnvValue.text(&1, &2)
    ]

    Enum.reduce_while(reads, {:ok, []}, fn {name, read}, {:ok, pool} ->
      case read.(getenv, variable(:runtime, name)) do
        {:ok, nil} -> {:cont, {:ok, pool}}
        {:ok, value} -> {:cont, {:ok, pool ++ [{name, value}]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # A refusal of a runtime setting, as the message naming the variable
  # that spells it.
  defp runtime_named({:error, {:missing, name}}),
    do: {:error, "#{variable(:runtime, name)} is not set"}

  defp runtime_named({:error, {:malformed, name}}),
    do: {:error, "#{variable(:runtime, name)} must be #{runtime_expected(name)}"}

  defp runtime_named(answer), do: answer

  defp runtime_expected(name) when name in @credential_keys,
    do: Locus.Runtime.Credentials.expected(name)

  defp runtime_expected(name), do: Locus.Runtime.Settings.expected(name)

  @doc """
  The runner settings `env` (a map of environment variables, a runner's
  process environment) spells, or the first variable that refuses: the
  service's key in sight is refused before anything else is read.
  """
  @spec runner(%{optional(String.t()) => String.t()}) ::
          {:ok, Locus.Runtime.Settings.runner()}
          | {:error, {:missing | :malformed | :refused, String.t()}}
  def runner(env) when is_map(env) do
    with :ok <- no_service_key(env),
         {:ok, runner_id} <- runner_id(env, :runner_id),
         {:ok, service_id} <- runner_service_id(env),
         {:ok, boot} <- runner_id(env, :boot),
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

  @doc "`runner/1` over the process environment, raising on a variable that refuses so the runner stops there."
  @spec runner!() :: Locus.Runtime.Settings.runner()
  def runner! do
    case runner(System.get_env()) do
      {:ok, runner} ->
        runner

      {:error, {:refused, name}} ->
        raise ArgumentError,
              "[Locus.Config] a runner must not see #{name}: the service's key never leaves the service"

      {:error, {:missing, name}} ->
        raise ArgumentError, "[Locus.Config] #{name} is not set"

      {:error, {:malformed, name}} ->
        raise ArgumentError, "[Locus.Config] #{name} is malformed: #{runner_expected(name)}"
    end
  end

  defp no_service_key(env) do
    key = variable(:runtime, :service_key)
    if is_map_key(env, key), do: {:error, {:refused, key}}, else: :ok
  end

  defp runner_id(env, key) do
    name = variable(:runner, key)

    case Map.get(env, name) do
      nil -> {:error, {:missing, name}}
      value -> if Regex.match?(@id, value), do: {:ok, value}, else: {:error, {:malformed, name}}
    end
  end

  defp runner_service_id(env) do
    with {:ok, value} <- runner_id(env, :service_id) do
      if Regex.match?(@service_id, value),
        do: {:ok, value},
        else: {:error, {:malformed, variable(:runner, :service_id)}}
    end
  end

  defp control_fd(env) do
    name = variable(:runner, :control_fd)

    case Integer.parse(Map.get(env, name, "3")) do
      {fd, ""} when fd >= 0 -> {:ok, fd}
      _ -> {:error, {:malformed, name}}
    end
  end

  # The descriptor cyfr-locus places every runner's relay on, 4, or the
  # unix socket the test build's direct launcher names in its place: an
  # absolute path, which wins when set.
  defp relay(env) do
    socket = variable(:runner, :relay_socket)

    case Map.fetch(env, socket) do
      {:ok, "/" <> _ = path} ->
        if Path.expand(path) == path,
          do: {:ok, {:socket, path}},
          else: {:error, {:malformed, socket}}

      {:ok, _path} ->
        {:error, {:malformed, socket}}

      :error ->
        {:ok, {:fd, 4}}
    end
  end

  defp grace(env) do
    name = variable(:runner, :watchdog_grace_ms)
    default = Integer.to_string(Locus.Runtime.Settings.default(:watchdog_grace_ms))

    case Integer.parse(Map.get(env, name, default)) do
      {ms, ""} when ms > 0 -> {:ok, ms}
      _ -> {:error, {:malformed, name}}
    end
  end

  # What a well-formed value of the runner variable `name` is, for the
  # message that refuses one.
  defp runner_expected(name) do
    case Map.fetch!(@runner_keys, name) do
      key when key in [:runner_id, :boot] -> "1 to 256 bytes of printable ASCII without spaces"
      :service_id -> Locus.Runtime.Credentials.expected(:service_id)
      :control_fd -> "a file descriptor number, 0 for standard input and output"
      :relay_socket -> "an absolute path to a unix socket"
      :watchdog_grace_ms -> "a positive integer of milliseconds"
    end
  end

  @doc "Every name the release reads: the roster's, role by role."
  @spec variables() :: [String.t()]
  def variables, do: @variables

  @doc "The names `role` reads, in its reader's order: every one carries the role's prefix."
  @spec variables(role()) :: [String.t()]
  def variables(role) when is_map_key(@prefixes, role),
    do: for({variable, ^role, _key} <- @roster, do: variable)

  @doc "The `LOCUS_*` names in `names` that the roster lacks, sorted, each once."
  @spec unknown_names([String.t()]) :: [String.t()]
  def unknown_names(names) when is_list(names), do: undeclared(names, "LOCUS_", @variables)

  @doc "The names in `names` under `role`'s prefix that `role` does not read, sorted, each once."
  @spec unknown_names([String.t()], role()) :: [String.t()]
  def unknown_names(names, role) when is_list(names) and is_map_key(@prefixes, role),
    do: undeclared(names, Map.fetch!(@prefixes, role), variables(role))

  defp undeclared(names, prefix, declared) do
    names
    |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 not in declared))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Why the undeclared names `names` refuse the boot, for the message that refuses it."
  @spec unknown([String.t(), ...]) :: String.t()
  def unknown([_ | _] = names) do
    "#{Enum.join(names, ", ")} #{if match?([_], names), do: "is", else: "are"} not a " <>
      "variable the locus release reads: remove it, or use the name .env.locus.example gives"
  end

  defp no_unknown(names) do
    case unknown_names(names) do
      [] -> :ok
      unknown -> {:error, unknown(unknown)}
    end
  end

  @doc """
  The names in the environment that only the control plane may hold, in
  the list's order: the database URL, the keyring, the runtime's root and
  the control plane's copies of the builds and backends keys. Empty for an
  environment a Locus node of any role may run in.
  """
  @spec refused_environment(EnvValue.getenv()) :: [String.t()]
  def refused_environment(getenv) when is_function(getenv, 1),
    do: Enum.filter(@control_plane_only, &(getenv.(&1) != nil))

  @doc """
  The least and the most a memory bound of the release may be, in bytes:
  the keeper's own range for a spawn's `memory_bytes`, 16 MiB to 1 TiB
  (`Prima.KeeperProtocol`).
  """
  @spec memory_range() :: Range.t()
  def memory_range,
    do: Prima.KeeperProtocol.min_memory_bytes()..Prima.KeeperProtocol.max_memory_bytes()//1

  defp log_level(getenv) do
    name_read = variable(:release, :log_level)

    case EnvValue.text(getenv, name_read) do
      {:ok, nil} ->
        {:ok, @defaults[:log_level]}

      {:ok, name} ->
        case Enum.find(Logger.levels(), &(Atom.to_string(&1) == name)) do
          nil ->
            {:error,
             "#{name_read}=#{inspect(name)} is not a Logger level; use one of " <>
               Enum.join(Logger.levels(), ", ") <> "."}

          level ->
            {:ok, level}
        end
    end
  end

  defp log_format(getenv) do
    name_read = variable(:release, :log_format)

    case EnvValue.text(getenv, name_read) do
      {:ok, nil} ->
        {:ok, @defaults[:log_format]}

      {:ok, "text"} ->
        {:ok, :text}

      {:ok, "json"} ->
        {:ok, :json}

      {:ok, other} ->
        {:error, "#{name_read}=#{inspect(other)} is not a log format; use text or json."}
    end
  end

  defp variable(role, key), do: Map.fetch!(@variable, {role, key})

  @doc "The key build requests are verified with, or nil where none was configured."
  @spec request_key() :: binary() | nil
  def request_key, do: Application.get_env(:locus, :request_key)

  @doc "The address the builder listens on."
  @spec bind() :: :inet.ip_address()
  def bind, do: get(:bind)

  @doc "The port the builder listens on."
  @spec port() :: :inet.port_number()
  def port, do: get(:port)

  @doc "A build's ceiling in milliseconds; a request's deadline may be sooner."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: get(:timeout_ms)

  @doc "Concurrent builds this builder runs in all."
  @spec max_concurrent() :: pos_integer()
  def max_concurrent, do: get(:max_concurrent)

  @doc "Concurrent builds this builder runs for one athanor."
  @spec max_concurrent_per_tenant() :: pos_integer()
  def max_concurrent_per_tenant, do: get(:max_concurrent_per_tenant)

  @doc "The memory bound every build's spawn asks cyfr-locus for, in bytes."
  @spec memory_bytes() :: pos_integer()
  def memory_bytes, do: get(:memory_bytes)

  @doc "The Cargo home whose registry cache a Rust build starts from, or nil."
  @spec cargo_seed() :: String.t() | nil
  def cargo_seed, do: get(:cargo_seed)

  @doc "The level the node logs at, whichever role it serves."
  @spec log_level() :: Logger.level()
  def log_level, do: get(:log_level)

  @doc "How the node's log lines are written: plain text, or JSON (`Prima.JsonFormatter`)."
  @spec log_format() :: :text | :json
  def log_format, do: get(:log_format)

  @doc "The `:logger` formatter `log_format/0` names: `Prima.JsonFormatter` for JSON, none for text."
  @spec log_formatter() :: {module(), atom()} | nil
  def log_formatter do
    case log_format() do
      :json -> {Prima.JsonFormatter, :format}
      :text -> nil
    end
  end

  @doc "The backends service key, decoded, or nil where none was configured."
  @spec backends_key() :: binary() | nil
  def backends_key, do: Application.get_env(:locus, :backends_key)

  @doc "The address the backends service listens on."
  @spec backends_bind() :: :inet.ip_address()
  def backends_bind, do: get(:backends_bind)

  @doc "The port the backends service listens on."
  @spec backends_port() :: :inet.port_number()
  def backends_port, do: get(:backends_port)

  @doc "The calls that may await one backend at a time."
  @spec backends_max_in_flight() :: pos_integer()
  def backends_max_in_flight, do: get(:backends_max_in_flight)

  @doc "The bound on each step of a backend's handshake, in milliseconds."
  @spec backends_init_timeout_ms() :: pos_integer()
  def backends_init_timeout_ms, do: get(:backends_init_timeout_ms)

  @doc "The bound on one call to a backend, in milliseconds."
  @spec backends_rpc_timeout_ms() :: pos_integer()
  def backends_rpc_timeout_ms, do: get(:backends_rpc_timeout_ms)

  @doc "The memory bound each backend's process is spawned under, in bytes."
  @spec backends_memory_bytes() :: pos_integer()
  def backends_memory_bytes, do: get(:backends_memory_bytes)

  defp get(key), do: Application.get_env(:locus, key, Keyword.fetch!(@defaults, key))
end
