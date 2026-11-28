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
  | `LOCUS_BUILDS_CARGO_SEED` | `:cargo_seed` | a directory | none |
  | `LOCUS_LOG_LEVEL` | `:log_level` | a Logger level | `info` |
  | `LOCUS_LOG_FORMAT` | `:log_format` | `text` or `json` | `text` |
  | `LOCUS_BACKENDS_KEY` | `:backends_key` | 64 hexadecimal digits, the backends service key | none: the node serves no backends |
  | `LOCUS_BACKENDS_BIND` | `:backends_bind` | an IPv4 or IPv6 address | `0.0.0.0` |
  | `LOCUS_BACKENDS_PORT` | `:backends_port` | 1..65535 | 4101 |
  | `LOCUS_RUNTIME_SERVICE_ID` | `:runtime`, `:service_id` | `wrk_` and 1 to 64 letters, digits, `_` or `-` | `wrk_local` |
  | `LOCUS_RUNTIME_KEY` | `:runtime`, `:service_key` | 64 hexadecimal digits, the key derived for the service's id | none: the node serves no runtime |
  | `LOCUS_RUNTIME_HOST_API_URL` | `:runtime`, `:host_url` | an http or https URL with a host and no path | none |
  | `LOCUS_RUNTIME_BIND` | `:runtime`, `:bind` | an IPv4 or IPv6 address | `127.0.0.1` |
  | `LOCUS_RUNTIME_PORT` | `:runtime`, `:port` | 0..65535 | 4200 |
  | `LOCUS_RUNTIME_IDLE_TTL_MS` | `:runtime`, `:idle_ttl_ms` | 1..86400000 | 900000 |
  | `LOCUS_RUNTIME_WATCHDOG_GRACE_MS` | `:runtime`, `:watchdog_grace_ms` | 1..600000 | 5000 |
  | `LOCUS_RUNTIME_RELEASE_GRACE_MS` | `:runtime`, `:release_grace_ms` | 1..600000 | 2000 |
  | `LOCUS_RUNTIME_ATTACH_DIR` | `:runtime`, `:attach_dir` | a clean absolute directory path | the role's run folder (`KEEPER_RUN_DIR`) |

  An unset runtime identity or listener row takes the default above; a
  pool row is written only when its variable is set, so
  `Locus.Runtime.Settings`' defaults stand for the rest. Every role's
  bind is read as a pin's address is (`Prima.PinnedTarget.parse_ip/1`,
  through `Prima.EnvValue.bind/2`), and each of the runtime's whole
  numbers in at most 12 characters, a port's sign among them. With no attach directory set, the run folder
  `KEEPER_RUN_DIR` names is read as written and refused at the boot as
  an attach directory is.

  `tests/fixtures/locus_settings.json` holds the runtime's rows and the
  log's, their defaults, ranges, reads and refusals, for every language
  that reads them (`Locus.Runtime.SettingsTest` holds this module to it).

  A runner is no node of the release: it is the runner program
  (`apps/locus/runner`), which reads only the environment its service
  writes for it (`Locus.Runtime.Settings.runner_environment/1`), outside
  every prefix the keeper refuses in a spawn, and nothing of this roster.

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

  No setting bounds a build, a backend session or a runner, or admits one:
  cyfr-locus admits every spawn in its one pool and sets its memory and
  processors by its place's kind (`Prima.LocusPool`), and no spawn names
  its own.

  A node's logging is the release's one setting whichever role it serves:
  `:log_level` and `:log_format` become the logger's when a release node
  that serves a role starts (`Locus.Application`). A runner reads neither:
  it writes its own lines to standard error, which its keeper relays to
  the service's log under the runner's id.

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
  # of MB for minutes, so a builder accepts a couple at once.
  @defaults [
    bind: {0, 0, 0, 0},
    port: 4100,
    timeout_ms: @default_timeout_ms,
    max_concurrent: 2,
    cargo_seed: nil,
    log_level: :info,
    log_format: :text,
    backends_bind: {0, 0, 0, 0},
    backends_port: 4101
  ]

  # What the runtime falls back to when neither its environment nor the
  # caller's fallback names a value.
  @runtime_defaults [service_id: "wrk_local", bind: "127.0.0.1", port: 4200]

  @control_plane_only ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_LOCUS_RUNTIME_ROOT
                         CYFR_LOCUS_BUILDS_KEY CYFR_LOCUS_BACKENDS_KEY)

  # Every variable of the release, `{variable, role, key}`: the key its
  # role's reader answers it under (the flat `:locus` keys for builds,
  # backends and the release's log setting, the `:runtime` keyword's keys
  # for the runtime). A role's rows are
  # in its reader's order, so every answer keeps its order.
  @roster [
    {"LOCUS_BUILDS_KEY", :builds, :request_key},
    {"LOCUS_BUILDS_BIND", :builds, :bind},
    {"LOCUS_BUILDS_PORT", :builds, :port},
    {"LOCUS_BUILDS_TIMEOUT_MS", :builds, :timeout_ms},
    {"LOCUS_BUILDS_MAX_CONCURRENT", :builds, :max_concurrent},
    {"LOCUS_BUILDS_CARGO_SEED", :builds, :cargo_seed},
    {"LOCUS_LOG_LEVEL", :release, :log_level},
    {"LOCUS_LOG_FORMAT", :release, :log_format},
    {"LOCUS_BACKENDS_KEY", :backends, :backends_key},
    {"LOCUS_BACKENDS_BIND", :backends, :backends_bind},
    {"LOCUS_BACKENDS_PORT", :backends, :backends_port},
    {"LOCUS_RUNTIME_SERVICE_ID", :runtime, :service_id},
    {"LOCUS_RUNTIME_KEY", :runtime, :service_key},
    {"LOCUS_RUNTIME_HOST_API_URL", :runtime, :host_url},
    {"LOCUS_RUNTIME_BIND", :runtime, :bind},
    {"LOCUS_RUNTIME_PORT", :runtime, :port},
    {"LOCUS_RUNTIME_IDLE_TTL_MS", :runtime, :idle_ttl_ms},
    {"LOCUS_RUNTIME_WATCHDOG_GRACE_MS", :runtime, :watchdog_grace_ms},
    {"LOCUS_RUNTIME_RELEASE_GRACE_MS", :runtime, :release_grace_ms},
    {"LOCUS_RUNTIME_ATTACH_DIR", :runtime, :attach_dir}
  ]

  # The one prefix every name of a role carries.
  @prefixes %{
    builds: "LOCUS_BUILDS_",
    release: "LOCUS_LOG_",
    backends: "LOCUS_BACKENDS_",
    runtime: "LOCUS_RUNTIME_"
  }

  @variables Enum.map(@roster, &elem(&1, 0))

  # The variable each reader reads, by role and key.
  @variable Map.new(@roster, fn {variable, role, key} -> {{role, key}, variable} end)

  # The runtime's settings that are the service's credentials and
  # listener (`Locus.Runtime.Credentials`); the rest are its pool's
  # (`Locus.Runtime.Settings`).
  @credential_keys [:service_id, :service_key, :host_url, :bind, :port]

  @typedoc "A role of the release's roster: one prefix, and the rows its reader reads."
  @type role :: :runtime | :builds | :backends | :release

  @typedoc "The `:locus` application environment `from_env/2` writes."
  @type settings :: [
          request_key: binary() | nil,
          bind: :inet.ip_address(),
          port: :inet.port_number(),
          timeout_ms: pos_integer(),
          max_concurrent: pos_integer(),
          cargo_seed: String.t() | nil,
          log_level: Logger.level(),
          log_format: :text | :json,
          backends_key: binary() | nil,
          backends_bind: :inet.ip_address(),
          backends_port: :inet.port_number(),
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
         {:ok, cargo_seed} <- EnvValue.text(getenv, variable(:builds, :cargo_seed)) do
      {:ok,
       [
         request_key: key && Prima.BuilderProtocol.request_key(key),
         bind: bind || @defaults[:bind],
         port: port || @defaults[:port],
         timeout_ms: timeout_ms || @defaults[:timeout_ms],
         max_concurrent: max || @defaults[:max_concurrent],
         cargo_seed: cargo_seed
       ]}
    end
  end

  defp backends(getenv) do
    with {:ok, key} <- EnvValue.hex_key(getenv, variable(:backends, :backends_key)),
         {:ok, bind} <- EnvValue.bind(getenv, variable(:backends, :backends_bind)),
         {:ok, port} <- EnvValue.port(getenv, variable(:backends, :backends_port)) do
      {:ok,
       [
         backends_key: key,
         backends_bind: bind || @defaults[:backends_bind],
         backends_port: port || @defaults[:backends_port]
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
         {:ok, _pool} <- runtime_pool_refusal(pool, getenv) do
      {:ok, credentials ++ pool}
    end
  end

  defp runtime_port(port) when is_integer(port), do: {:ok, port}

  # At most 12 characters, as every whole number a role reads
  # (`Prima.EnvValue.whole_number/4`), its sign among them.
  defp runtime_port(text) when is_binary(text) do
    case byte_size(text) <= 12 and Integer.parse(text) do
      {port, ""} -> {:ok, port}
      _ -> runtime_named({:error, {:malformed, :port}})
    end
  end

  # The pool's settings as `Locus.Runtime.Settings.pool/2` reads them, the
  # run folder among them: an attach directory left unset is the folder
  # KEEPER_RUN_DIR names, as written, refused here as a set one is.
  defp runtime_pool_refusal(pool, getenv) do
    run_dir_env = Locus.Keeper.run_dir_env()
    run_dir = getenv.(run_dir_env)
    system = if is_binary(run_dir), do: %{run_dir_env => run_dir}, else: %{}

    case {Locus.Runtime.Settings.pool(pool, system), Keyword.has_key?(pool, :attach_dir)} do
      {{:error, {:malformed, :attach_dir}}, false} ->
        {:error, "#{run_dir_env} must be #{Locus.Runtime.Settings.expected(:attach_dir)}"}

      {answer, _set} ->
        runtime_named(answer)
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
      idle_ttl_ms: &EnvValue.milliseconds(&1, &2, 1..86_400_000),
      watchdog_grace_ms: &EnvValue.milliseconds(&1, &2, 1..600_000),
      release_grace_ms: &EnvValue.milliseconds(&1, &2, 1..600_000),
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

  defp get(key), do: Application.get_env(:locus, key, Keyword.fetch!(@defaults, key))
end
