# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Config do
  @moduledoc """
  The builder's settings: read from the `locus` release's environment by
  `config/locus_runtime.exs` (`from_env/1`), which writes them as the
  `:locus` application environment and nothing else, and read back by the
  builder through the accessors below, each with its default.

  | Variable | Setting | Accepted | Default |
  |---|---|---|---|
  | `LOCUS_BUILDS_KEY` | `:request_key` | 64 hexadecimal digits, the builds service key; required | none: the boot refuses |
  | `LOCUS_BUILDS_BIND` | `:bind` | an IPv4 or IPv6 address | `0.0.0.0` |
  | `LOCUS_BUILDS_PORT` | `:port` | 1..65535 | 4100 |
  | `LOCUS_BUILDS_TIMEOUT_MS` | `:timeout_ms` | 1000..600000 | 270000 |
  | `LOCUS_BUILDS_MAX_CONCURRENT` | `:max_concurrent` | 1..1024 | 2 |
  | `LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT` | `:max_concurrent_per_tenant` | 1..1024 | 1 |
  | `LOCUS_BUILDS_CARGO_SEED` | `:cargo_seed` | a directory | none |
  | `LOCUS_BUILDS_LOG_LEVEL` | `:log_level` | a Logger level | `info` |
  | `LOCUS_BUILDS_LOG_FORMAT` | `:log_format` | `text` or `json` | `text` |

  `:request_key` is the key requests are verified with
  (`Cyfr.BuilderProtocol.request_key/1`), derived once here; the
  configured key itself is kept nowhere. A set variable that does not
  parse, or a missing key, refuses the boot with a message naming the
  variable. So does the control plane's configuration in the builder's
  environment (`refused_environment/1`): the database URL, the keyring,
  the worker root and the bridge key are CYFR's, and a builder that can
  see them was given more than a builder holds.

  Where the environment was never read — a development node, the test
  suite — every accessor answers its default and `request_key/0` is nil,
  so no build request verifies.
  """

  alias Cyfr.EnvValue

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
    cargo_seed: nil,
    log_level: :info,
    log_format: :text
  ]

  @control_plane_only ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_WORKER_KEY CYFR_MCP_BRIDGE_KEY)

  @typedoc "The `:locus` application environment `from_env/1` writes."
  @type settings :: [
          request_key: binary(),
          bind: :inet.ip_address(),
          port: :inet.port_number(),
          timeout_ms: pos_integer(),
          max_concurrent: pos_integer(),
          max_concurrent_per_tenant: pos_integer(),
          cargo_seed: String.t() | nil,
          log_level: Logger.level(),
          log_format: :text | :json
        ]

  @doc """
  The `:locus` settings the environment `getenv` spells, every one present
  with its default where unset, or the first refusal as a message naming
  the variable.
  """
  @spec from_env(EnvValue.getenv()) :: {:ok, settings()} | {:error, String.t()}
  def from_env(getenv) when is_function(getenv, 1) do
    with [] <- refused_environment(getenv),
         {:ok, key} <- key(getenv),
         {:ok, bind} <- EnvValue.bind(getenv, "LOCUS_BUILDS_BIND"),
         {:ok, port} <- EnvValue.port(getenv, "LOCUS_BUILDS_PORT"),
         {:ok, timeout_ms} <-
           EnvValue.milliseconds(getenv, "LOCUS_BUILDS_TIMEOUT_MS", 1_000..600_000),
         {:ok, max} <-
           EnvValue.whole_number(getenv, "LOCUS_BUILDS_MAX_CONCURRENT", 1..1024, "builds"),
         {:ok, per_tenant} <-
           EnvValue.whole_number(
             getenv,
             "LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT",
             1..1024,
             "builds"
           ),
         {:ok, cargo_seed} <- EnvValue.text(getenv, "LOCUS_BUILDS_CARGO_SEED"),
         {:ok, log_level} <- log_level(getenv),
         {:ok, log_format} <- log_format(getenv) do
      {:ok,
       [
         request_key: Cyfr.BuilderProtocol.request_key(key),
         bind: bind || @defaults[:bind],
         port: port || @defaults[:port],
         timeout_ms: timeout_ms || @defaults[:timeout_ms],
         max_concurrent: max || @defaults[:max_concurrent],
         max_concurrent_per_tenant: per_tenant || @defaults[:max_concurrent_per_tenant],
         cargo_seed: cargo_seed,
         log_level: log_level,
         log_format: log_format
       ]}
    else
      {:error, message} ->
        {:error, message}

      refused when is_list(refused) ->
        {:error,
         "the locus release must not see #{Enum.join(refused, ", ")}: the database, " <>
           "the keyring, the worker root and the bridge key are CYFR's"}
    end
  end

  @doc """
  The names in the environment that only the control plane may hold: the
  database URL, the keyring, the worker root and the bridge key. Empty for
  an environment a builder may run in.
  """
  @spec refused_environment(EnvValue.getenv()) :: [String.t()]
  def refused_environment(getenv) when is_function(getenv, 1),
    do: Enum.filter(@control_plane_only, &(getenv.(&1) != nil))

  defp key(getenv) do
    case EnvValue.hex_key(getenv, "LOCUS_BUILDS_KEY") do
      {:ok, nil} ->
        {:error,
         "LOCUS_BUILDS_KEY is not set; the builder verifies every build request with it " <>
           "(64 hexadecimal digits, the same key as CYFR_LOCUS_BUILDS_KEY on the server)."}

      other ->
        other
    end
  end

  defp log_level(getenv) do
    case EnvValue.text(getenv, "LOCUS_BUILDS_LOG_LEVEL") do
      {:ok, nil} ->
        {:ok, @defaults[:log_level]}

      {:ok, name} ->
        case Enum.find(Logger.levels(), &(Atom.to_string(&1) == name)) do
          nil ->
            {:error,
             "LOCUS_BUILDS_LOG_LEVEL=#{inspect(name)} is not a Logger level; use one of " <>
               Enum.join(Logger.levels(), ", ") <> "."}

          level ->
            {:ok, level}
        end
    end
  end

  defp log_format(getenv) do
    case EnvValue.text(getenv, "LOCUS_BUILDS_LOG_FORMAT") do
      {:ok, nil} ->
        {:ok, @defaults[:log_format]}

      {:ok, "text"} ->
        {:ok, :text}

      {:ok, "json"} ->
        {:ok, :json}

      {:ok, other} ->
        {:error,
         "LOCUS_BUILDS_LOG_FORMAT=#{inspect(other)} is not a log format; use text or json."}
    end
  end

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

  @doc "The Cargo home whose registry cache a Rust build starts from, or nil."
  @spec cargo_seed() :: String.t() | nil
  def cargo_seed, do: get(:cargo_seed)

  @doc "The level the builder logs at."
  @spec log_level() :: Logger.level()
  def log_level, do: get(:log_level)

  @doc "How the builder's log lines are written: plain text, or JSON (`Cyfr.JsonFormatter`)."
  @spec log_format() :: :text | :json
  def log_format, do: get(:log_format)

  @doc "The `:logger` formatter `log_format/0` names: `Cyfr.JsonFormatter` for JSON, none for text."
  @spec log_formatter() :: {module(), atom()} | nil
  def log_formatter do
    case log_format() do
      :json -> {Cyfr.JsonFormatter, :format}
      :text -> nil
    end
  end

  defp get(key), do: Application.get_env(:locus, key, Keyword.fetch!(@defaults, key))
end
