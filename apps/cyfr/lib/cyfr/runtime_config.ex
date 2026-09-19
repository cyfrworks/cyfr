# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeConfig do
  @moduledoc """
  Pure resolvers that turn deployment environment variables into validated
  configuration, used by `config/runtime.exs`.

  The contract is **set-or-default, never silent fallback**: an unset variable
  takes the documented default, but a *set* variable that is incomplete or
  unrecognized returns `{:error, message}` so the caller can fail the boot
  loudly. This avoids footguns like `CYFR_AUTH_PROVIDER=oidc` quietly degrading
  to no authentication.

  Every function takes a `getenv` reader — `(String.t() -> String.t() | nil)` —
  so it is exercised directly in tests without touching the real environment.
  `config/runtime.exs` passes a reader backed by `Dotenvy.env!/3`.

  This module holds two jobs, deliberately:

  1. **Boot-time parsers** take environment values and return validated
     configuration, evaluated once by `runtime.exs`.
  2. **Runtime accessors**, such as `auth_provider/0` and `cookie_secure?/0`,
     provide shared defaults for settings read by multiple modules.
  """

  @type getenv :: (String.t() -> String.t() | nil)

  # The worker vocabulary `CYFR_WORKERS` and the host API listener take
  # their defaults from: a local Opus service, reached and reaching back
  # over loopback.
  @default_workers "wrk_local=http://127.0.0.1:4200"
  @default_host_api_bind {127, 0, 0, 1}
  @default_host_api_port 4300
  @service_id ~r/\Awrk_[A-Za-z0-9_-]{1,64}\z/

  @doc """
  Resolve the auth provider module from the environment.

  - unset `CYFR_AUTH_PROVIDER` → auto-detect: GitHub/Google client present ⇒
    `Sanctum.Auth.OAuth`, otherwise `nil` (the no-sign-in default).
  - `"oauth"` → `Sanctum.Auth.OAuth`, requires a GitHub or Google client.
  - `"oidc"` → `Sanctum.Auth.OIDC`, requires the full OIDC trio.
  - anything else → `{:error, _}`.
  """
  @spec resolve_auth_provider(getenv) :: {:ok, module() | nil} | {:error, String.t()}
  def resolve_auth_provider(getenv) when is_function(getenv, 1) do
    github? = present?(getenv.("CYFR_GITHUB_CLIENT_ID"))
    google? = present?(getenv.("CYFR_GOOGLE_CLIENT_ID"))

    case blank_to_nil(getenv.("CYFR_AUTH_PROVIDER")) do
      nil ->
        if github? or google?, do: {:ok, Sanctum.Auth.OAuth}, else: {:ok, nil}

      "oauth" ->
        if github? or google? do
          {:ok, Sanctum.Auth.OAuth}
        else
          {:error,
           "CYFR_AUTH_PROVIDER=oauth but neither CYFR_GITHUB_CLIENT_ID nor " <>
             "CYFR_GOOGLE_CLIENT_ID is set."}
        end

      "oidc" ->
        case oidc_config(getenv) do
          {:ok, _} -> {:ok, Sanctum.Auth.OIDC}
          {:error, _} = err -> err
        end

      other ->
        {:error, ~s(Unknown CYFR_AUTH_PROVIDER=#{inspect(other)}; expected "oauth" or "oidc".)}
    end
  end

  @doc """
  Resolve and validate the generic-OIDC configuration trio.

  Returns `{:ok, %{issuer:, client_id:, client_secret:}}` or an error naming the
  missing variables.
  """
  @spec oidc_config(getenv) ::
          {:ok, %{issuer: String.t(), client_id: String.t(), client_secret: String.t()}}
          | {:error, String.t()}
  def oidc_config(getenv) when is_function(getenv, 1) do
    fields = [
      {"CYFR_OIDC_ISSUER", :issuer},
      {"CYFR_OIDC_CLIENT_ID", :client_id},
      {"CYFR_OIDC_CLIENT_SECRET", :client_secret}
    ]

    resolved = for {var, key} <- fields, into: %{}, do: {key, blank_to_nil(getenv.(var))}
    missing = for {var, key} <- fields, is_nil(resolved[key]), do: var

    case missing do
      [] -> {:ok, resolved}
      _ -> {:error, "CYFR_AUTH_PROVIDER=oidc requires #{Enum.join(missing, ", ")}."}
    end
  end

  @doc """
  The compiled repo adapter (`config :cyfr, :repo_adapter`, set at compile
  time from CYFR_DATABASE). One accessor with one default so runtime.exs and
  the application's DB setup cannot disagree about what was built.
  """
  @spec repo_adapter() :: module()
  def repo_adapter, do: Application.get_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3)

  @doc """
  The configured auth provider module, or `nil` when the deployment runs
  without sign-in.
  """
  @spec auth_provider() :: module() | nil
  def auth_provider, do: Application.get_env(:cyfr, :auth_provider)

  @doc """
  Browser cross-origin allowlist. Unset means the wildcard default — the
  single source of that default, read by both the CORS plug (enforcement)
  and the boot guard (which refuses a wildcard once an auth provider is
  configured). The two must never disagree about what "unset" means.
  """
  @spec cors_allowed_origins() :: [String.t()]
  def cors_allowed_origins,
    do: Application.get_env(:cyfr, :cors_allowed_origins, ["*"])

  @doc """
  Whether cookies carry the `Secure` attribute.

  `config/runtime.exs` sets it true under `:prod`; everywhere else it is
  false so a plain-HTTP dev host still receives its session. One reader,
  because a security default spelled out at four call sites is four
  chances to spell it differently.
  """
  @spec cookie_secure?() :: boolean()
  def cookie_secure?, do: Application.get_env(:cyfr, :cookie_secure, false)

  @doc """
  Whether this node is headless (`CYFR_HEADLESS`): the API, MCP and public
  tinctures are served and every browser route answers 404 — a Codex-only
  node. Read at request time by `EmissaryWeb.Plugs.Headless`.
  """
  @spec headless?() :: boolean()
  def headless?, do: Application.get_env(:cyfr, :headless, false) == true

  @doc "Whether this node runs as an OTP release (RELEASE_ROOT is set)."
  @spec release?() :: boolean()
  def release?, do: System.get_env("RELEASE_ROOT") != nil

  @doc """
  Whether this server builds components: it does exactly when a builds
  service is configured, its URL and its key both (`locus_builds_url/0`,
  `locus_builds_key/0`). A server without one refuses every build and
  runs no toolchain of its own.
  """
  @spec builds_enabled?() :: boolean()
  def builds_enabled?, do: is_binary(locus_builds_url()) and is_binary(locus_builds_key())

  @doc """
  The base URL of the Locus builds service (`CYFR_LOCUS_BUILDS_URL`), as
  `resolve_locus_builds/1` answers it, or nil when none is configured.
  """
  @spec locus_builds_url() :: String.t() | nil
  def locus_builds_url do
    case Application.get_env(:cyfr, :locus_builds_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @doc """
  The builds service key (`CYFR_LOCUS_BUILDS_KEY`), its 32 bytes as
  `resolve_locus_builds/1` answers them, or nil when none is configured.
  `Compendium.Builds.Client` derives the key it signs requests with from
  it; nothing else reads it, and it is never logged.
  """
  @spec locus_builds_key() :: <<_::256>> | nil
  def locus_builds_key do
    case Application.get_env(:cyfr, :locus_builds_key) do
      <<_::256>> = key -> key
      _ -> nil
    end
  end

  @doc "The consent-proof store module (default: the DB store)."
  @spec consent_proof_store() :: module()
  def consent_proof_store,
    do: Application.get_env(:cyfr, :consent_proof_store, Sanctum.Consent.Proof.DB)

  @doc "The configured OIDC issuer URL, or nil."
  @spec oidc_issuer() :: String.t() | nil
  def oidc_issuer, do: Application.get_env(:cyfr, :oidc_issuer)

  @doc "Whether the Prometheus /metrics endpoint is enabled."
  @spec prometheus_metrics_enabled?() :: boolean()
  def prometheus_metrics_enabled?,
    do: Application.get_env(:cyfr, :prometheus_metrics_enabled, false)

  @doc """
  Whether unsigned OCI components are refused. Read at both ends of a
  component's life — `Compendium.OCI.Client` refuses the pull, and
  `Cyfr.Execution.Admission` refuses to run a row that carries no verified
  signature (a component pulled before the knob was set).
  """
  @spec require_signed_pulls?() :: boolean()
  def require_signed_pulls?, do: Application.get_env(:cyfr, :require_signed_pulls, false)

  @doc """
  The resolved crypto keyring. Raises when read before boot resolution —
  a sealed row must never be touched with a guessed key.
  """
  @spec crypto_keyring!() :: map()
  def crypto_keyring!, do: Application.fetch_env!(:cyfr, :crypto_keyring)

  @doc """
  The externally reachable base URL of this instance, without a trailing
  slash, or `nil` when the operator has not declared one.

  Only the operator knows it: behind a proxy or a tunnel it is neither the
  bind address nor the `Host` of any particular request.
  """
  @spec public_url() :: String.t() | nil
  def public_url do
    case Application.get_env(:cyfr, :public_url) do
      url when is_binary(url) ->
        case String.trim_trailing(String.trim(url), "/") do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns `public_url/0` when configured, otherwise an HTTP development
  origin built from the endpoint’s configured host and port.
  TLS deployments must set CYFR_PUBLIC_URL.
  """
  @spec origin() :: String.t()
  def origin do
    public_url() || dev_origin()
  end

  defp dev_origin do
    endpoint = Application.get_env(:cyfr, EmissaryWeb.Endpoint, [])
    host = get_in(endpoint, [:url, :host]) || "localhost"
    port = get_in(endpoint, [:http, :port]) || 4000
    "http://#{host}:#{port}"
  end

  # DNS-rebinding guard: unset means localhost-only.
  @mcp_default_origins [
    "http://localhost",
    "https://localhost",
    "http://127.0.0.1",
    "https://127.0.0.1",
    "http://[::1]",
    "https://[::1]"
  ]

  @doc """
  MCP Origin-header allowlist (DNS-rebinding guard). Unset means the
  localhost-only default — single source, read by the Origin plug and the
  boot-time divergence warning. The `CYFR_MCP_ALLOWED_ORIGINS` extras
  (`:mcp_extra_origins`, set in every env) are appended rather than baked
  into the base list, so setting them in dev EXTENDS the localhost default
  instead of replacing it.
  """
  @spec mcp_allowed_origins() :: [String.t()]
  def mcp_allowed_origins do
    Application.get_env(:cyfr, :mcp_allowed_origins, @mcp_default_origins) ++
      Application.get_env(:cyfr, :mcp_extra_origins, [])
  end

  @doc """
  SQLite busy timeout, used both as the Repo connection option and in the
  boot-time PRAGMA — one constant so the two mechanisms stay in step.
  """
  @spec sqlite_busy_timeout_ms() :: pos_integer()
  def sqlite_busy_timeout_ms, do: 5_000

  @doc """
  Returns the default per-window tincture invocation budget. HTTP uses
  per-IP buckets; the console shell uses separate per-person buckets.
  """
  @spec tincture_default_invoke_max() :: pos_integer()
  def tincture_default_invoke_max, do: 120

  @doc "The effective invoke budget: the operator's override if set, else the default."
  @spec tincture_invoke_max() :: pos_integer()
  def tincture_invoke_max,
    do: Application.get_env(:cyfr, :tincture_rate_limit_max) || tincture_default_invoke_max()

  @doc "The rate window (ms) both tincture ingress surfaces share."
  @spec tincture_rate_window_ms() :: pos_integer()
  def tincture_rate_window_ms, do: 60_000

  @doc """
  Resolve the filesystem roots from the environment (release runtime):

    * `CYFR_DATA_PATH` — the one runtime storage root (default `"data"`)
    * `CYFR_SEED_PATH` — the seed tree every athanor is provisioned from:
      the component bundle under `components/` and the AQUA template under
      `aqua/`
      (default `"seed"`)
    * `CYFR_DATABASE_PATH` — the SQLite file (default `cyfr.db` under the
      data root; ignored on Postgres)

  Every path comes back expanded. Set-or-default, never silent fallback: an
  unset variable takes its default, a set-but-blank one fails the boot.
  Returns `{:ok, %{base_path: _, seed_path: _, database_path: _}}` or
  `{:error, message}`.
  """
  @spec resolve_paths(getenv) :: {:ok, map()} | {:error, String.t()}
  def resolve_paths(getenv) when is_function(getenv, 1) do
    with {:ok, base} <- path_var(getenv, "CYFR_DATA_PATH", "data"),
         {:ok, seed} <- path_var(getenv, "CYFR_SEED_PATH", "seed"),
         {:ok, db} <- path_var(getenv, "CYFR_DATABASE_PATH", Path.join(base, "cyfr.db")) do
      {:ok, %{base_path: base, seed_path: seed, database_path: db}}
    end
  end

  defp path_var(getenv, var, default) do
    case getenv.(var) do
      nil ->
        {:ok, Path.expand(default)}

      value ->
        case String.trim(value) do
          "" -> {:error, "#{var} is set but blank; unset it or give it a path."}
          path -> {:ok, Path.expand(path)}
        end
    end
  end

  @doc """
  Resolve `CYFR_DB_POOL_SIZE` (default 20, must be a positive integer) —
  one parser for both database adapters, so the same value cannot boot one
  and refuse the other.
  """
  @spec resolve_pool_size(getenv) :: {:ok, pos_integer()} | {:error, String.t()}
  def resolve_pool_size(getenv) when is_function(getenv, 1),
    do: parse_pool_size(getenv.("CYFR_DB_POOL_SIZE"))

  @doc """
  Resolve the storage backend from `CYFR_STORAGE` (`local` default | `s3`).

  Returns `{:ok, :local}`, `{:ok, {:s3, opts}}` (a keyword list shaped for
  `config :cyfr, :s3`), or `{:error, _}`.
  """
  @spec resolve_storage(getenv) ::
          {:ok, :local} | {:ok, {:s3, keyword()}} | {:error, String.t()}
  def resolve_storage(getenv) when is_function(getenv, 1) do
    case (getenv.("CYFR_STORAGE") || "local") |> String.trim() |> String.downcase() do
      "" -> {:ok, :local}
      "local" -> {:ok, :local}
      "s3" -> s3_config(getenv)
      other -> {:error, ~s(Unknown CYFR_STORAGE=#{inspect(other)}; expected "local" or "s3".)}
    end
  end

  @doc """
  Resolve and validate the S3 adapter options.

  Required: bucket, region, access key id, secret access key. Optional:
  endpoint, key prefix, path-style addressing. Keys match what
  `Arca.Adapters.S3` reads from `config :cyfr, :s3`.

  > #### Secret handling {: .warning}
  >
  > The returned opts carry `:secret_access_key`. Never `inspect/1`, log, or
  > echo these opts (the error path here names only missing env *vars*, never
  > values). Callers must keep them out of telemetry and crash reports.
  """
  @spec s3_config(getenv) :: {:ok, {:s3, keyword()}} | {:error, String.t()}
  def s3_config(getenv) when is_function(getenv, 1) do
    required = [
      {"CYFR_S3_BUCKET", :bucket},
      {"CYFR_S3_REGION", :region},
      {"CYFR_S3_ACCESS_KEY_ID", :access_key_id},
      {"CYFR_S3_SECRET_ACCESS_KEY", :secret_access_key}
    ]

    resolved = for {var, key} <- required, into: %{}, do: {key, blank_to_nil(getenv.(var))}
    missing = for {var, key} <- required, is_nil(resolved[key]), do: var

    with [] <- missing,
         # Use the configured receive timeout for object-store requests.
         {:ok, receive_timeout_ms} <-
           positive_int(getenv.("CYFR_S3_RECEIVE_TIMEOUT_MS"), "CYFR_S3_RECEIVE_TIMEOUT_MS"),
         {:ok, path_style} <- Cyfr.EnvValue.switch(getenv, "CYFR_S3_PATH_STYLE", false) do
      opts =
        [
          bucket: resolved.bucket,
          region: resolved.region,
          access_key_id: resolved.access_key_id,
          secret_access_key: resolved.secret_access_key,
          endpoint: blank_to_nil(getenv.("CYFR_S3_ENDPOINT")),
          prefix: blank_to_nil(getenv.("CYFR_S3_PREFIX")),
          path_style: path_style,
          receive_timeout_ms: receive_timeout_ms
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, {:s3, opts}}
    else
      {:error, message} -> {:error, message}
      _missing -> {:error, "CYFR_STORAGE=s3 requires #{Enum.join(missing, ", ")}."}
    end
  end

  @doc """
  Resolve Postgres connection options for `config :cyfr, Arca.Repo`.

  Postgres builds carry no connection config from `config.exs`, so a
  `CYFR_DATABASE_URL` is required — its absence is a hard error rather than a
  silent attempt against a default localhost. `pool_size` and `ssl` are
  optional overrides.
  """
  @spec resolve_postgres(getenv) :: {:ok, keyword()} | {:error, String.t()}
  def resolve_postgres(getenv) when is_function(getenv, 1) do
    case blank_to_nil(getenv.("CYFR_DATABASE_URL")) do
      nil ->
        {:error,
         "CYFR_DATABASE=postgres requires CYFR_DATABASE_URL " <>
           "(e.g. postgres://user:pass@host:5432/dbname)."}

      url ->
        with {:ok, pool_size} <- parse_pool_size(getenv.("CYFR_DB_POOL_SIZE")),
             {:ok, ssl} <- Cyfr.EnvValue.switch(getenv, "CYFR_DB_SSL", false) do
          {:ok, [url: url, pool_size: pool_size, ssl: ssl]}
        end
    end
  end

  @doc """
  Resolve the worker services runs are dispatched to from `CYFR_WORKERS`:
  comma-separated `<service_id>=<url>` entries, default
  `wrk_local=http://127.0.0.1:4200`. A service id is `wrk_` followed by 1
  to 64 letters, digits, `_` or `-`, the id its key derives over
  (`Cyfr.WorkerAuth.worker_key/2`), and a URL is the base URL of its
  listener (`Cyfr.WorkerWire.base_url/1`). Answers the
  `t:Cyfr.WorkerAPI.endpoint/0` entries in order, each running any
  component; a malformed entry or a repeated id is an error naming it.
  """
  @spec resolve_workers(getenv) :: {:ok, [Cyfr.WorkerAPI.endpoint()]} | {:error, String.t()}
  def resolve_workers(getenv) when is_function(getenv, 1) do
    entries =
      (blank_to_nil(getenv.("CYFR_WORKERS")) || @default_workers)
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case worker_entry(entry) do
        {:ok, %{id: id} = endpoint} ->
          if Enum.any?(acc, &(&1.id == id)),
            do: {:halt, {:error, "CYFR_WORKERS names the service #{inspect(id)} twice."}},
            else: {:cont, {:ok, acc ++ [endpoint]}}

        :error ->
          {:halt,
           {:error,
            "CYFR_WORKERS entry #{inspect(entry)} is not <service_id>=<url>: a service id " <>
              "is `wrk_` followed by 1 to 64 letters, digits, `_` or `-`, and a URL is " <>
              "http or https with a host and no path."}}
      end
    end)
  end

  defp worker_entry(entry) do
    with [id, url] <- String.split(entry, "=", parts: 2),
         id = String.trim(id),
         true <- Regex.match?(@service_id, id),
         {:ok, base} <- Cyfr.WorkerWire.base_url(String.trim(url)) do
      {:ok, %{id: id, url: base, components: nil}}
    else
      _ -> :error
    end
  end

  @doc """
  Resolve where CYFR's host API listener binds (`Cyfr.Execution.HostListener`):
  `CYFR_HOST_API_BIND`, an IPv4 or IPv6 address (default `127.0.0.1`), and
  `CYFR_HOST_API_PORT`, a port from 1 to 65535 (default 4300). Set-or-default:
  a set value that is neither is an error naming it.
  """
  @spec resolve_host_api(getenv) ::
          {:ok, %{bind: :inet.ip_address(), port: :inet.port_number()}} | {:error, String.t()}
  def resolve_host_api(getenv) when is_function(getenv, 1) do
    with {:ok, bind} <- host_api_bind(blank_to_nil(getenv.("CYFR_HOST_API_BIND"))),
         {:ok, port} <- host_api_port(blank_to_nil(getenv.("CYFR_HOST_API_PORT"))) do
      {:ok, %{bind: bind, port: port}}
    end
  end

  defp host_api_bind(nil), do: {:ok, @default_host_api_bind}

  defp host_api_bind(text) do
    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        {:error, "CYFR_HOST_API_BIND=#{inspect(text)} is not an IPv4 or IPv6 address."}
    end
  end

  defp host_api_port(nil), do: {:ok, @default_host_api_port}

  defp host_api_port(text) do
    case Integer.parse(text) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> {:error, "CYFR_HOST_API_PORT=#{inspect(text)} is not a port from 1 to 65535."}
    end
  end

  @doc """
  Resolve the worker watch's bounds (`Cyfr.Execution.WorkerWatch`):
  `CYFR_WORKER_WATCH_POLL_MS`, the interval between its status polls of
  each worker service, a whole number of milliseconds from 1000 to 60000
  (default 5000), and `CYFR_WORKER_WATCH_MISSES`, the misses in a row
  after which the boot last heard from has its running attempts lapsed,
  from 1 to 100 (default 3). Answers the keyword `config :cyfr,
  :worker_watch` takes with only the set bounds, so the code's defaults
  stand for the rest; a set value outside its range, or not a whole
  number, is an error naming it.
  """
  @spec resolve_worker_watch(getenv) :: {:ok, keyword()} | {:error, String.t()}
  def resolve_worker_watch(getenv) when is_function(getenv, 1) do
    with {:ok, poll_ms} <-
           Cyfr.EnvValue.milliseconds(getenv, "CYFR_WORKER_WATCH_POLL_MS", 1_000..60_000),
         {:ok, misses} <-
           Cyfr.EnvValue.whole_number(getenv, "CYFR_WORKER_WATCH_MISSES", 1..100, "misses") do
      {:ok,
       Enum.reject([poll_ms: poll_ms, misses: misses], fn {_key, value} -> is_nil(value) end)}
    end
  end

  @doc """
  Resolve the Locus builds service this server sends its builds to
  (`Compendium.Builds.Client`): `CYFR_LOCUS_BUILDS_URL`, the base URL of
  its listener (http or https with a host and no path), and
  `CYFR_LOCUS_BUILDS_KEY`, the service's key as 64 hexadecimal digits, the
  same key as `LOCUS_BUILDS_KEY` on the service. Answers `{:ok, nil}`
  when neither is set — this server builds nothing — and
  `{:ok, %{url: url, key: key}}`, the values `config :cyfr,
  :locus_builds_url` and `:locus_builds_key` take, when both are. One
  without the other, or a value of another form, is an error naming the
  variable and never the key's text.
  """
  @spec resolve_locus_builds(getenv) ::
          {:ok, %{url: String.t(), key: <<_::256>>} | nil} | {:error, String.t()}
  def resolve_locus_builds(getenv) when is_function(getenv, 1) do
    with {:ok, url} <- Cyfr.EnvValue.url(getenv, "CYFR_LOCUS_BUILDS_URL"),
         {:ok, key} <- Cyfr.EnvValue.hex_key(getenv, "CYFR_LOCUS_BUILDS_KEY") do
      case {url, key} do
        {nil, nil} ->
          {:ok, nil}

        {url, key} when is_binary(url) and is_binary(key) ->
          {:ok, %{url: url, key: key}}

        {nil, _key} ->
          {:error,
           "CYFR_LOCUS_BUILDS_KEY is set but CYFR_LOCUS_BUILDS_URL is not; set both to " <>
             "build on a Locus builds service, or neither to build nothing."}

        {_url, nil} ->
          {:error,
           "CYFR_LOCUS_BUILDS_URL is set but CYFR_LOCUS_BUILDS_KEY is not; every build " <>
             "request is signed with it (64 hexadecimal digits, the same key as " <>
             "LOCUS_BUILDS_KEY on the builds service)."}
      end
    end
  end

  @doc "The address the host API listener binds (`CYFR_HOST_API_BIND`, default loopback)."
  @spec host_api_bind() :: :inet.ip_address()
  def host_api_bind, do: Application.get_env(:cyfr, :host_api_bind, @default_host_api_bind)

  @doc """
  The port the host API listener binds (`CYFR_HOST_API_PORT`, default 4300).
  The suite binds 0 and asks the listener which port it was given.
  """
  @spec host_api_port() :: :inet.port_number()
  def host_api_port, do: Application.get_env(:cyfr, :host_api_port, @default_host_api_port)

  # ── helpers ────────────────────────────────────────────────────────────────

  defp present?(value), do: not is_nil(blank_to_nil(value))

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Optional positive integer: unset means "the reader's own default", but a
  # value the operator set and got wrong fails the boot rather than silently
  # reverting to it.
  defp positive_int(raw, var) do
    case blank_to_nil(raw) do
      nil ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{var} must be a positive integer, got #{inspect(trimmed)}."}
        end
    end
  end

  # Set-or-default, never silent fallback: an unset variable takes the
  # default, but a variable the operator set and got wrong fails the boot.
  # Quietly serving 20 connections to someone who asked for 200 is a
  # capacity incident discovered under load.
  defp parse_pool_size(nil), do: {:ok, 20}

  defp parse_pool_size(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n > 0 ->
        {:ok, n}

      _ ->
        {:error, "CYFR_DB_POOL_SIZE must be a positive integer, got #{inspect(raw)}."}
    end
  end
end
