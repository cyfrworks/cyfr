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

  @doc """
  Read an on/off switch from the environment.

  Unset or blank values use `default`. Accepts `on`/`off`, `true`/`false`,
  `yes`/`no`, and `1`/`0`, ignoring case. Other values return `{:error, message}`.
  """
  @spec switch(getenv, String.t(), boolean()) :: {:ok, boolean()} | {:error, String.t()}
  def switch(getenv, key, default) when is_function(getenv, 1) and is_boolean(default) do
    case getenv.(key) do
      nil ->
        {:ok, default}

      raw when is_binary(raw) ->
        case raw |> String.trim() |> String.downcase() do
          "" -> {:ok, default}
          on when on in ["on", "true", "yes", "1"] -> {:ok, true}
          off when off in ["off", "false", "no", "0"] -> {:ok, false}
          _ -> {:error, "#{key}=#{inspect(raw)} is not a switch; use on or off."}
        end
    end
  end

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

  @doc "Whether this server builds components (`CYFR_BUILDS`, default true)."
  @spec builds_enabled?() :: boolean()
  def builds_enabled?, do: Application.get_env(:cyfr, :builds_enabled, true) == true

  @doc "The builder container's URL (`CYFR_BUILDER_URL`), or nil for in-process builds."
  @spec builder_url() :: String.t() | nil
  def builder_url, do: Application.get_env(:cyfr, :builder_url)

  @doc """
  Whether the operator accepted in-process builds on a hosted server
  (`CYFR_ALLOW_IN_PROCESS_BUILDS`). Read by the boot guard only.
  """
  @spec allow_in_process_builds?() :: boolean()
  def allow_in_process_builds?,
    do: Application.get_env(:cyfr, :allow_in_process_builds, false) == true

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
         {:ok, path_style} <- switch(getenv, "CYFR_S3_PATH_STYLE", false) do
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
             {:ok, ssl} <- switch(getenv, "CYFR_DB_SSL", false) do
          {:ok, [url: url, pool_size: pool_size, ssl: ssl]}
        end
    end
  end

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
