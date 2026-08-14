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
  """

  @type getenv :: (String.t() -> String.t() | nil)

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
  boot-time divergence warning.
  """
  @spec mcp_allowed_origins() :: [String.t()]
  def mcp_allowed_origins,
    do: Application.get_env(:cyfr, :mcp_allowed_origins, @mcp_default_origins)

  @doc """
  SQLite busy timeout, used both as the Repo connection option and in the
  boot-time PRAGMA — one constant so the two mechanisms stay in step.
  """
  @spec sqlite_busy_timeout_ms() :: pos_integer()
  def sqlite_busy_timeout_ms, do: 5_000

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

    case missing do
      [] ->
        opts =
          [
            bucket: resolved.bucket,
            region: resolved.region,
            access_key_id: resolved.access_key_id,
            secret_access_key: resolved.secret_access_key,
            endpoint: blank_to_nil(getenv.("CYFR_S3_ENDPOINT")),
            prefix: blank_to_nil(getenv.("CYFR_S3_PREFIX")),
            path_style: getenv.("CYFR_S3_PATH_STYLE") in ["true", "1"]
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, {:s3, opts}}

      _ ->
        {:error, "CYFR_STORAGE=s3 requires #{Enum.join(missing, ", ")}."}
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
        case parse_pool_size(getenv.("CYFR_DB_POOL_SIZE")) do
          {:ok, pool_size} ->
            {:ok,
             [
               url: url,
               pool_size: pool_size,
               ssl: getenv.("CYFR_DB_SSL") == "true"
             ]}

          {:error, _} = err ->
            err
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
