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
  2. **Runtime accessors**, such as `cookie_secure?/0`,
     provide shared defaults for settings read by multiple modules.
  """

  @type getenv :: (String.t() -> String.t() | nil)

  # The worker vocabulary `CYFR_LOCUS_RUNTIME_WORKERS` and the host API listener take
  # their defaults from: a local runtime service, reached and reaching back
  # over loopback.
  @default_workers "wrk_local=http://127.0.0.1:4200"
  @default_host_api_bind {127, 0, 0, 1}
  @default_host_api_port 4300
  @service_id ~r/\Awrk_[A-Za-z0-9_-]{1,64}\z/

  # The fewest bytes a key base holds: what Plug's cookie store requires
  # of the endpoint's, held for every use of it (`check_secret_key_base/1`).
  @secret_key_base_bytes 64

  # The storage reserve's default and ceiling: 64 MiB holds a revocation's
  # rows and the log or WAL growth it causes on either adapter, and 1 TiB
  # is past any reserve a home would keep.
  @default_storage_reserve_bytes 64 * 1024 * 1024
  @max_storage_reserve_bytes 1024 * 1024 * 1024 * 1024

  @doc """
  Resolve the auth provider module from the environment.

  - unset `CYFR_AUTH_PROVIDER` → the built-in device flows: a GitHub or
    Google client present ⇒ `Sanctum.Auth.OAuth`, otherwise `nil` (the
    no-sign-in default).
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

      "oidc" ->
        case oidc_config(getenv) do
          {:ok, _} -> {:ok, Sanctum.Auth.OIDC}
          {:error, _} = err -> err
        end

      other ->
        {:error,
         ~s(Unknown CYFR_AUTH_PROVIDER="#{other}"; expected "oidc", or unset for the ) <>
           "built-in GitHub and Google device flows."}
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
  Browser cross-origin allowlist: `config/config.exs` configures the empty
  one, which admits no cross-origin browser caller, and
  `CYFR_CORS_ALLOWED_ORIGINS` replaces it. Read by both the CORS plug
  (enforcement) and the boot guard (which refuses a wildcard once an auth
  provider is configured), so the two never disagree about what it holds.
  """
  @spec cors_allowed_origins() :: [String.t()]
  def cors_allowed_origins, do: Application.fetch_env!(:cyfr, :cors_allowed_origins)

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
  The most bytes of a webhook's body read (`:webhook_max_body_bytes`):
  `{:ok, bytes}`, the shared 1 MiB default
  (`Prima.Limits.default_max_request_size/0`) when unset, or
  `{:error, message}` for a value that is not an integer from 1 to a host
  call's body (`Prima.HostAPI.max_body_bytes/0`): a webhook's sender is
  not authenticated before its body is read, so no larger cap holds.
  `Cyfr.Application` refuses the boot on the error, and
  `CyfrWeb.Plugs.RawBodyReader` refuses the read.
  """
  @spec webhook_max_body_bytes() :: {:ok, pos_integer()} | {:error, String.t()}
  def webhook_max_body_bytes do
    max = Prima.HostAPI.max_body_bytes()

    case Application.get_env(
           :cyfr,
           :webhook_max_body_bytes,
           Prima.Limits.default_max_request_size()
         ) do
      bytes when is_integer(bytes) and bytes in 1..max//1 ->
        {:ok, bytes}

      other ->
        got =
          if is_integer(other),
            do: Integer.to_string(other),
            else: Prima.LoggerContext.shape(other)

        {:error,
         ":webhook_max_body_bytes must be an integer from 1 to #{max} bytes " <>
           "(a host call's body), got #{got}"}
    end
  end

  @doc """
  Whether this node is headless (`CYFR_HEADLESS`): the API, MCP and public
  tinctures are served and every browser route answers 404 — a Codex-only
  node. Read at request time by `CyfrWeb.Plugs.Headless`.
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

  @doc "Whether the Prometheus /metrics endpoint is enabled."
  @spec prometheus_metrics_enabled?() :: boolean()
  def prometheus_metrics_enabled?,
    do: Application.fetch_env!(:cyfr, :prometheus_metrics_enabled)

  @doc """
  Whether unsigned OCI components are refused. Read at both ends of a
  component's life — `Compendium.OCI.Client` refuses the pull, and
  `Opus.Admission` refuses to run a row that carries no verified
  signature (a component pulled before the knob was set).
  """
  @spec require_signed_pulls?() :: boolean()
  def require_signed_pulls?, do: Application.get_env(:cyfr, :require_signed_pulls, false)

  @doc """
  The home's origin (`Sanctum.origin/0`), as the console reads it: its
  surface names no root `Sanctum` module (`Cyfr.Boundaries`), so the
  host's glue carries this one value to it.
  """
  @spec origin() :: String.t()
  defdelegate origin(), to: Sanctum

  @doc """
  MCP Origin-header allowlist (DNS-rebinding guard), read by the Origin
  plug: the origins the home's access settings resolve to
  (`:mcp_allowed_origins`, `config/runtime.exs`), followed by the
  `CYFR_MCP_ALLOWED_ORIGINS` extras (`:mcp_extra_origins`), which extend
  it rather than replace it.
  """
  @spec mcp_allowed_origins() :: [String.t()]
  def mcp_allowed_origins do
    Application.fetch_env!(:cyfr, :mcp_allowed_origins) ++
      Application.fetch_env!(:cyfr, :mcp_extra_origins)
  end

  @doc "The default per-window tincture invocation budget, per client address."
  @spec tincture_default_invoke_max() :: pos_integer()
  def tincture_default_invoke_max, do: 120

  @doc "The rate window (ms) both tincture ingress surfaces share."
  @spec tincture_rate_window_ms() :: pos_integer()
  def tincture_rate_window_ms, do: 60_000

  @doc """
  Check a key base: `CYFR_SECRET_KEY_BASE` as `config/runtime.exs` reads
  it, and the configured `:sanctum, :secret_key_base` the at-rest keyring
  derives from. Refused when missing, blank after trimming, or shorter
  than #{@secret_key_base_bytes} bytes, the least Plug's cookie store
  accepts. The length is `byte_size` of the value as given, never
  trimmed: the keyring and the salts hash its exact bytes. The message
  names the variable and the reason, never the value.
  """
  @spec check_secret_key_base(term()) :: :ok | {:error, String.t()}
  def check_secret_key_base(key_base) when is_binary(key_base) do
    cond do
      String.trim(key_base) == "" ->
        {:error, secret_key_base_refusal("is blank")}

      byte_size(key_base) < @secret_key_base_bytes ->
        {:error, secret_key_base_refusal("is shorter than #{@secret_key_base_bytes} bytes")}

      true ->
        :ok
    end
  end

  def check_secret_key_base(_missing), do: {:error, secret_key_base_refusal("is missing")}

  defp secret_key_base_refusal(reason),
    do: "CYFR_SECRET_KEY_BASE #{reason}; generate one with `openssl rand -base64 48`"

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
  Resolve the storage reserve (`Cyfr.StorageReserve`) for a deployment
  whose database is `database` (`Arca.adapter_facts/0`'s `adapter`) and
  whose SQLite file, under SQLite, is `database_path`:

    * `CYFR_STORAGE_RESERVE_BYTES` — the mark and the reserve file's size,
      a whole number of bytes from 1 to 1 TiB (default 64 MiB). 0 is
      refused: a home with no reserve has no room left to revoke in, a
      security bound rather than a capacity ceiling.
    * `CYFR_STORAGE_RESERVE_PATH` — the directory holding the reserve file,
      whose filesystem the reserve guards. Under SQLite it defaults to the
      database's directory; under PostgreSQL it has no default, and unset
      no file is kept.

  Whether the path exists, is writable and reports its free space is the
  boot's check on the host it runs on (`Cyfr.StorageReserve`). Returns
  `{:ok, %{bytes: _, path: path | nil}}` or `{:error, message}`.
  """
  @spec resolve_storage_reserve(getenv, :sqlite | :postgres, Path.t()) ::
          {:ok, %{bytes: pos_integer(), path: Path.t() | nil}} | {:error, String.t()}
  def resolve_storage_reserve(getenv, database, database_path)
      when is_function(getenv, 1) and database in [:sqlite, :postgres] and
             is_binary(database_path) do
    with {:ok, bytes} <-
           Prima.EnvValue.bytes(
             getenv,
             "CYFR_STORAGE_RESERVE_BYTES",
             1..@max_storage_reserve_bytes
           ),
         {:ok, path} <- storage_reserve_path(getenv, database, database_path) do
      {:ok, %{bytes: bytes || @default_storage_reserve_bytes, path: path}}
    end
  end

  defp storage_reserve_path(getenv, database, database_path) do
    case getenv.("CYFR_STORAGE_RESERVE_PATH") do
      nil when database == :sqlite -> {:ok, Path.dirname(Path.expand(database_path))}
      nil -> {:ok, nil}
      _set -> path_var(getenv, "CYFR_STORAGE_RESERVE_PATH", nil)
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
  `config :arca, :s3`), or `{:error, _}`.
  """
  @spec resolve_storage(getenv) ::
          {:ok, :local} | {:ok, {:s3, keyword()}} | {:error, String.t()}
  def resolve_storage(getenv) when is_function(getenv, 1) do
    case (getenv.("CYFR_STORAGE") || "local") |> String.trim() |> String.downcase() do
      "" -> {:ok, :local}
      "local" -> {:ok, :local}
      "s3" -> s3_config(getenv)
      other -> {:error, ~s(Unknown CYFR_STORAGE="#{other}"; expected "local" or "s3".)}
    end
  end

  @doc """
  Resolve and validate the S3 adapter options.

  Required: bucket, region, access key id, secret access key. Optional:
  endpoint, key prefix, path-style addressing. Keys match what
  `Arca.Adapters.S3` reads from `config :arca, :s3`.

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
         {:ok, path_style} <- Prima.EnvValue.switch(getenv, "CYFR_S3_PATH_STYLE", false) do
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
  Resolve Postgres connection options for `config :arca, Arca.Repo`.

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
             {:ok, ssl} <- Prima.EnvValue.switch(getenv, "CYFR_DB_SSL", false) do
          {:ok, [url: url, pool_size: pool_size, ssl: ssl]}
        end
    end
  end

  @doc """
  Resolve the worker services runs are dispatched to from `CYFR_LOCUS_RUNTIME_WORKERS`:
  comma-separated `<service_id>=<url>` entries, default
  `wrk_local=http://127.0.0.1:4200`. A service id is `wrk_` followed by 1
  to 64 letters, digits, `_` or `-`, the id its key derives over
  (`Prima.WorkerAuth.worker_key/2`), and a URL is the base URL of its
  listener (`Prima.WorkerWire.base_url/1`). Answers the
  `t:Prima.WorkerAPI.endpoint/0` entries in order, each running any
  component; a malformed entry or a repeated id is an error naming it.
  """
  @spec resolve_workers(getenv) :: {:ok, [Prima.WorkerAPI.endpoint()]} | {:error, String.t()}
  def resolve_workers(getenv) when is_function(getenv, 1) do
    entries =
      (blank_to_nil(getenv.("CYFR_LOCUS_RUNTIME_WORKERS")) || @default_workers)
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case worker_entry(entry) do
        {:ok, %{id: id} = endpoint} ->
          if Enum.any?(acc, &(&1.id == id)),
            do:
              {:halt,
               {:error, "CYFR_LOCUS_RUNTIME_WORKERS names the service #{inspect(id)} twice."}},
            else: {:cont, {:ok, acc ++ [endpoint]}}

        :error ->
          {:halt,
           {:error,
            "CYFR_LOCUS_RUNTIME_WORKERS entry #{inspect(entry)} is not <service_id>=<url>: a service id " <>
              "is `wrk_` followed by 1 to 64 letters, digits, `_` or `-`, and a URL is " <>
              "http or https with a host and no path."}}
      end
    end)
  end

  defp worker_entry(entry) do
    with [id, url] <- String.split(entry, "=", parts: 2),
         id = String.trim(id),
         true <- Regex.match?(@service_id, id),
         {:ok, base} <- Prima.WorkerWire.base_url(String.trim(url)) do
      {:ok, %{id: id, url: base, components: nil}}
    else
      _ -> :error
    end
  end

  @doc """
  Resolve the `libcluster` topology the cell's members find each other
  through, for `CYFR_CLUSTER=on`. Two shapes, and nothing else:

    * `CYFR_CLUSTER_NODES` — a comma-separated list of the members' node
      names (`cyfr@10.0.0.1,cyfr@10.0.0.2`), polled over EPMD.
    * `CYFR_CLUSTER_DNS_QUERY` with `CYFR_CLUSTER_NODE_BASENAME` — the
      headless service whose A records are the members, and the name every
      member's node is `<basename>@<address>`.

  `{:ok, []}` when neither is set, which `Cyfr.Cell` refuses under the
  cluster flag: a cell that never forms is a set of members that each
  believe they are a cell. A half-set DNS pair is an error naming the
  missing half, never a topology that discovers nothing.
  """
  @spec resolve_cluster_topology(getenv) :: {:ok, keyword()} | {:error, String.t()}
  def resolve_cluster_topology(getenv) when is_function(getenv, 1) do
    nodes = blank_to_nil(getenv.("CYFR_CLUSTER_NODES"))
    query = blank_to_nil(getenv.("CYFR_CLUSTER_DNS_QUERY"))
    basename = blank_to_nil(getenv.("CYFR_CLUSTER_NODE_BASENAME"))

    cond do
      nodes && (query || basename) ->
        {:error,
         "CYFR_CLUSTER_NODES and CYFR_CLUSTER_DNS_QUERY name two ways to find the same " <>
           "cluster; set one."}

      nodes ->
        case node_names(nodes) do
          [] ->
            {:error, "CYFR_CLUSTER_NODES is set but names no server."}

          hosts ->
            {:ok, [cyfr: [strategy: Cluster.Strategy.Epmd, config: [hosts: hosts]]]}
        end

      query && basename ->
        {:ok,
         [
           cyfr: [
             strategy: Cluster.Strategy.DNSPoll,
             config: [polling_interval: 5_000, query: query, node_basename: basename]
           ]
         ]}

      query ->
        {:error,
         "CYFR_CLUSTER_DNS_QUERY is set without CYFR_CLUSTER_NODE_BASENAME; a server's " <>
           "Erlang name is <basename>@<address> and discovery cannot guess the basename."}

      basename ->
        {:error,
         "CYFR_CLUSTER_NODE_BASENAME is set without CYFR_CLUSTER_DNS_QUERY; there is no " <>
           "service to resolve the servers from."}

      true ->
        {:ok, []}
    end
  end

  defp node_names(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  @doc """
  Resolve the cell's own distribution cookie from `CYFR_CELL_COOKIE`:
  `{:ok, nil}` when unset, `{:ok, cookie}` at 32 characters or more, and
  an error naming its length below that.

  A cookie bounds exactly one cell, and 32 characters is the point below
  which it is guessable. An ambient `~/.erlang.cookie` is the machine's,
  not the cell's, which is why `Cyfr.Cell` also refuses a member whose
  distribution cookie is not this one.
  """
  @spec resolve_cell_cookie(getenv) :: {:ok, String.t() | nil} | {:error, String.t()}
  def resolve_cell_cookie(getenv) when is_function(getenv, 1) do
    case blank_to_nil(getenv.("CYFR_CELL_COOKIE")) do
      nil ->
        {:ok, nil}

      cookie when byte_size(cookie) >= 32 ->
        {:ok, cookie}

      short ->
        {:error,
         "CYFR_CELL_COOKIE is #{byte_size(short)} characters; a cluster cookie is at least " <>
           "32. Generate one with `openssl rand -hex 32`."}
    end
  end

  @doc """
  Resolve where CYFR's host API listener binds (`Opus.HostListener`)
  and the address this member is reached at: `CYFR_HOST_API_BIND`, an IPv4
  or IPv6 address (default `127.0.0.1`), `CYFR_HOST_API_PORT`, a port from
  1 to 65535 (default 4300), and `CYFR_HOST_API_URL`, the base URL a
  worker service reaches this member's host API at. Set-or-default: a set
  value that is none of those is an error naming it.

  `CYFR_HOST_API_URL` has no default, because a member cannot discover the
  name a worker reaches it by: a bind address says which interfaces it
  answers on, never which address anything else routes to. Unset, the
  assignments this member issues carry no address and a worker posts their
  host calls to the address it is configured with (`LOCUS_RUNTIME_HOST_API_URL`) — one
  member, one address, which is what a single-member deployment has. A
  cell refuses to boot without it (`Cyfr.Cell.refusals/1`), because there
  the configured address names one member and the others lose their work.
  """
  @spec resolve_host_api(getenv) ::
          {:ok, %{bind: :inet.ip_address(), port: :inet.port_number(), url: String.t() | nil}}
          | {:error, String.t()}
  def resolve_host_api(getenv) when is_function(getenv, 1) do
    with {:ok, bind} <- host_api_bind(blank_to_nil(getenv.("CYFR_HOST_API_BIND"))),
         {:ok, port} <- host_api_port(blank_to_nil(getenv.("CYFR_HOST_API_PORT"))),
         {:ok, url} <- host_api_url(blank_to_nil(getenv.("CYFR_HOST_API_URL"))) do
      {:ok, %{bind: bind, port: port, url: url}}
    end
  end

  defp host_api_url(nil), do: {:ok, nil}

  defp host_api_url(text) do
    case Prima.WorkerWire.base_url(text) do
      {:ok, url} ->
        {:ok, url}

      :error ->
        {:error,
         "CYFR_HOST_API_URL=#{inspect(text)} is not an http or https URL with a host and " <>
           "no path (the address a worker service reaches this server's host API at, such " <>
           "as http://cyfr:4300)."}
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
    with {:ok, url} <- Prima.EnvValue.url(getenv, "CYFR_LOCUS_BUILDS_URL"),
         {:ok, key} <- Prima.EnvValue.hex_key(getenv, "CYFR_LOCUS_BUILDS_KEY") do
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

  @doc """
  The base URL a worker service reaches this member's host API at
  (`CYFR_HOST_API_URL`), which every assignment this member issues names,
  or `nil` when the deployment has not been told one.
  """
  @spec host_api_url() :: String.t() | nil
  def host_api_url, do: Application.get_env(:cyfr, :host_api_url)

  # ── access ─────────────────────────────────────────────────────────────────

  @typedoc """
  What the boot read, for `resolve_access/1`: the names and values the
  release read from `.env` itself (`Cyfr.EnvFiles.source!/2` with
  `side_effect: false`), or `nil` when it read none, as in the compose
  container, where `.env` arrives through `env_file`; the environment as
  `config/runtime.exs` merges it; and whether this is a release, or a dev
  or test run, where an unset mode is `local`.
  """
  @type access_input :: %{
          file: %{optional(String.t()) => String.t()} | nil,
          process: %{optional(String.t()) => String.t()},
          release?: boolean()
        }

  @type access_head :: %{optional(String.t()) => String.t() | pos_integer() | [String.t()]}

  @type access :: %{
          mode: :local | :tailnet | :public,
          head: access_head(),
          canonical: String.t(),
          digest: String.t(),
          origin: String.t(),
          listeners: %{
            loopback: {String.t(), pos_integer()},
            proxy: {String.t(), pos_integer()} | :none
          },
          trust: :none | {:cidrs, [String.t()]} | {:hops, 0..16},
          hsts: :none | :endpoint_on_proxy | :caddy,
          check_origins: [String.t()],
          assertion: :absent | :process
        }

  @type access_refusal :: %{code: atom(), class: Prima.Refusal.class(), payload: map()}

  # Every name the resolver reads. A name `.env` and the merged environment
  # assign differently is a source conflict; the compose file's assertion
  # has its own rule.
  @access_keys ~w(CADDY_ACME_EMAIL CYFR_BIND_ADDRESS CYFR_HOST CYFR_LOCUS_BUILDS_URL
                 CYFR_PORT CYFR_PROXY_BIND_ADDRESS CYFR_PROXY_PORT CYFR_PUBLIC_URL CYFR_ACCESS
                 CYFR_TAILNET_NODE_ID CYFR_TRUSTED_PROXY_CIDRS CYFR_TRUSTED_PROXY_HOPS)
  @assertion "CYFR_LOCAL_INGRESS_ASSERTED"

  @default_port 4000
  @default_bind "127.0.0.1"
  @default_proxy_port 4001
  @default_proxy_hops 1
  @builds_service "locus-builds"

  @dns_label ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
  @node_id ~r/\A[A-Za-z0-9._-]{1,128}\z/
  @digits ~r/\A[0-9]{1,5}\z/

  # A builds service's URL: http or https, a host (a DNS name, an IPv4
  # address or a bracketed IPv6 address), an optional port and nothing
  # after but one slash. `tests/fixtures/access_modes.json` holds the
  # grammar's answers, which the access engine's twin of it gives too.
  @builds_url ~r/\A(?:http|https):\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*)(?::([0-9]{1,5}))?\/?\z/

  @doc """
  Resolve how this home is reached from what the boot read
  (`t:access_input/0`): `{:ok, access}`, or `{:error, %{code, class,
  payload}}`, a `Prima.Refusal` row whose sentence
  (`Prima.Refusal.message({code, payload})`) the boot prints after
  `[Cyfr] FATAL:`. Blank values count as unset.

  A value that is not UTF-8, in `.env` or the merged environment, is
  refused first, by the first such name in byte order and without its
  value, since no other rule can read it. Then, when several refusals
  apply, the first in this order is answered: a source conflict (the
  first such name in byte order), the assertion assigned in `.env`, the
  mode (unset in a release, then unknown), the host, the node id, the
  public URL, a key outside its mode (the email before the node id), a
  malformed port, builds URL, address, assertion or proxy trust, a proxy
  listener on the loopback listener's port at an address it overlaps, and
  the loopback listener's bind. `tests/fixtures/access_modes.json`
  holds the answers; the access engine reads the same file.
  """
  @spec resolve_access(access_input()) :: {:ok, access()} | {:error, access_refusal()}
  def resolve_access(%{file: file, process: process, release?: release?})
      when (is_map(file) or is_nil(file)) and is_map(process) and is_boolean(release?) do
    get = fn key -> blank_to_nil(Map.get(process, key)) end

    result =
      with :ok <- access_encoding(file || %{}, process),
           :ok <- access_sources(file || %{}, process),
           {:ok, mode} <- access_mode(get.("CYFR_ACCESS"), release?),
           {:ok, head} <- access_head(mode, get),
           {:ok, settings} <- access_settings(mode, head["port"], get),
           :ok <- access_bind(settings) do
        %{canonical: canonical, digest: digest} = access_digest(head)

        {:ok,
         %{
           mode:
             Map.fetch!(%{"local" => :local, "tailnet" => :tailnet, "public" => :public}, mode),
           head: head,
           canonical: canonical,
           digest: digest,
           origin: access_origin(head),
           listeners: %{loopback: settings.bind, proxy: settings.proxy},
           trust: settings.trust,
           hsts:
             Map.fetch!(
               %{"local" => :none, "tailnet" => :endpoint_on_proxy, "public" => :caddy},
               mode
             ),
           check_origins: access_check_origins(head),
           assertion: settings.assertion
         }}
      end

    case result do
      {:error, {code, payload}} ->
        {:error,
         %{code: code, class: Prima.Refusal.classify({code, payload}).class, payload: payload}}

      ok ->
        ok
    end
  end

  @doc """
  A head's complete compose selection, sorted: the mode's proxy profile,
  and `locus-builds` exactly when `builds_url`'s host is that compose
  service.
  """
  @spec access_profiles(String.t(), String.t() | nil) :: [String.t()]
  def access_profiles(mode, builds_url) when mode in ["local", "tailnet", "public"] do
    proxy = if mode == "local", do: [], else: [mode]

    builds =
      case builds_url && builds_host(builds_url) do
        @builds_service -> [@builds_service]
        _ -> []
      end

    Enum.sort(proxy ++ builds)
  end

  @doc """
  Whether `url` is a builds service's URL: `http` or `https`, a host (a
  DNS name, an IPv4 address or a bracketed IPv6 address), an optional
  port from 1 to 65535, and nothing after but one slash: no path, query,
  fragment or credentials.
  """
  @spec builds_url?(String.t()) :: boolean()
  def builds_url?(url) when is_binary(url), do: builds_host(url) != nil

  # The URL's host, lowercased, or nil when it is no builds URL.
  defp builds_host(url) do
    with true <- String.valid?(url),
         [_, host | port] <- Regex.run(@builds_url, url),
         true <- builds_port?(port),
         true <- not String.starts_with?(host, "[") or bracketed_ipv6?(host) do
      String.downcase(host)
    else
      _ -> nil
    end
  end

  defp builds_port?([]), do: true
  defp builds_port?([port]), do: String.to_integer(port) in 1..65_535

  defp bracketed_ipv6?(host) do
    address = host |> String.trim_leading("[") |> String.trim_trailing("]")
    String.contains?(address, ":") and ip_literal(address) != nil
  end

  @doc """
  An access head's canonical JSON (`Prima.JCS`) and its digest,
  `Prima.JCS.hash/1`'s form. A head carries only the keys that hold a value.
  """
  @spec access_digest(access_head()) :: %{canonical: String.t(), digest: String.t()}
  def access_digest(head) when is_map(head) do
    {:ok, canonical} = Prima.JCS.encode(head)
    %{canonical: canonical, digest: Prima.Digest.sha256(canonical)}
  end

  @doc "Whether `name` is a tailnet machine name, `<machine>.<tailnet>.ts.net`, in lowercase."
  @spec tailnet_name?(String.t()) :: boolean()
  def tailnet_name?(name) when is_binary(name) do
    case String.split(name, ".") do
      [machine, tailnet, "ts", "net"] -> dns_label?(machine) and dns_label?(tailnet)
      _ -> false
    end
  end

  @doc """
  Whether `id` is a node id this home stores: 1 to 128 bytes of
  `[A-Za-z0-9._-]`, compared byte for byte. Tailscale's stable node id has
  no format of its own, so the grammar is CYFR's.
  """
  @spec tailnet_node_id?(String.t()) :: boolean()
  def tailnet_node_id?(id) when is_binary(id), do: Regex.match?(@node_id, id)

  @doc """
  Whether `host` is a public domain name: at most 253 bytes of two or more
  lowercase DNS labels, the last not all digits, and neither localhost,
  a `.localhost` name nor a `ts.net` name.
  """
  @spec public_domain?(String.t()) :: boolean()
  def public_domain?(host) when is_binary(host) do
    labels = String.split(host, ".")
    last = List.last(labels)

    byte_size(host) <= 253 and length(labels) >= 2 and Enum.all?(labels, &dns_label?/1) and
      not Regex.match?(~r/\A[0-9]+\z/, last) and last != "localhost" and
      not String.ends_with?("." <> host, ".ts.net")
  end

  defp dns_label?(label), do: Regex.match?(@dns_label, label)

  # Every value either map holds for a name the resolver reads is UTF-8,
  # or the first name in byte order that holds one that is not is refused.
  defp access_encoding(file, process) do
    unreadable =
      Enum.find(Enum.sort([@assertion | @access_keys]), fn key ->
        Enum.any?([file[key], process[key]], &(is_binary(&1) and not String.valid?(&1)))
      end)

    if unreadable,
      do: {:error, {:access_setting_invalid, %{key: unreadable}}},
      else: :ok
  end

  # `.env` against the merged environment: a name `.env` assigns that the
  # merged read holds otherwise was overridden by the process, and the
  # compose file's assertion never comes from `.env`.
  defp access_sources(file, process) do
    conflict =
      Enum.find(@access_keys, fn key ->
        assigned = blank_to_nil(file[key])
        assigned != nil and assigned != blank_to_nil(process[key])
      end)

    cond do
      conflict ->
        {:error,
         {:access_source_conflict,
          %{
            key: conflict,
            file_value: blank_to_nil(file[conflict]),
            process_value: blank_to_nil(process[conflict]) || ""
          }}}

      Map.has_key?(file, @assertion) ->
        {:error, {:access_assertion_from_file, %{}}}

      true ->
        :ok
    end
  end

  defp access_mode(nil, true), do: {:error, {:access_missing, %{}}}
  defp access_mode(nil, false), do: {:ok, "local"}
  defp access_mode(mode, _) when mode in ["local", "tailnet", "public"], do: {:ok, mode}
  defp access_mode(other, _), do: {:error, {:access_unknown_mode, %{value: other}}}

  # The head the mode's settings make, once each is the one the mode allows.
  defp access_head(mode, get) do
    host = get.("CYFR_HOST")
    node_id = get.("CYFR_TAILNET_NODE_ID")
    url = get.("CYFR_PUBLIC_URL")
    email = get.("CADDY_ACME_EMAIL")
    builds_url = get.("CYFR_LOCUS_BUILDS_URL")

    with :ok <- access_host(mode, host),
         :ok <- access_node_id(mode, node_id),
         :ok <- access_url(mode, host, url),
         :ok <- access_outside(mode, "CADDY_ACME_EMAIL", email, "public"),
         :ok <- access_outside(mode, "CYFR_TAILNET_NODE_ID", node_id, "tailnet"),
         {:ok, port} <- access_port(get, "CYFR_PORT", @default_port),
         :ok <- access_builds_url(builds_url) do
      head =
        %{
          "mode" => mode,
          "host" => host || "localhost",
          "port" => port,
          "node_id" => node_id,
          "public_url" => url,
          "acme_email" => email,
          "builds_url" => builds_url,
          "profiles" => access_profiles(mode, builds_url)
        }
        |> reject_nil()

      {:ok, head}
    end
  end

  defp access_builds_url(nil), do: :ok

  defp access_builds_url(url) do
    if builds_url?(url),
      do: :ok,
      else: {:error, {:access_setting_invalid, %{key: "CYFR_LOCUS_BUILDS_URL", value: url}}}
  end

  defp access_host("local", host) when host in [nil, "localhost"], do: :ok

  defp access_host("local", host),
    do: {:error, {:access_local_mismatch, %{key: "CYFR_HOST", value: host}}}

  defp access_host("tailnet", host) do
    if is_binary(host) and tailnet_name?(host),
      do: :ok,
      else: {:error, {:access_tailnet_host_invalid, reject_nil(%{host: host})}}
  end

  defp access_host("public", host) do
    if is_binary(host) and public_domain?(host),
      do: :ok,
      else: {:error, {:access_public_host_invalid, reject_nil(%{host: host})}}
  end

  defp access_node_id("tailnet", id) do
    if is_binary(id) and tailnet_node_id?(id),
      do: :ok,
      else: {:error, {:access_tailnet_node_invalid, reject_nil(%{value: id})}}
  end

  defp access_node_id(_mode, _id), do: :ok

  defp access_url("local", _host, nil), do: :ok

  defp access_url("local", _host, url),
    do: {:error, {:access_local_mismatch, %{key: "CYFR_PUBLIC_URL", value: url}}}

  defp access_url(mode, host, url) do
    expected = "https://" <> host

    if url == expected,
      do: :ok,
      else:
        {:error,
         {:access_public_url_mismatch, reject_nil(%{mode: mode, expected: expected, value: url})}}
  end

  defp access_outside(mode, _key, _value, mode), do: :ok
  defp access_outside(_mode, _key, nil, _needs), do: :ok

  defp access_outside(mode, key, _value, needs),
    do: {:error, {:access_key_outside_mode, %{key: key, mode: mode, needs: needs}}}

  # The listeners, the assertion and the proxy trust, each strictly read.
  defp access_settings(mode, port, get) do
    proxied? = mode != "local"

    with {:ok, bind} <- access_address(get, "CYFR_BIND_ADDRESS", @default_bind),
         {:ok, assertion} <- access_assertion(get.(@assertion)),
         {:ok, proxy_bind} <- access_address(get, "CYFR_PROXY_BIND_ADDRESS", @default_bind),
         {:ok, proxy_port} <- access_port(get, "CYFR_PROXY_PORT", @default_proxy_port),
         {:ok, trust} <- access_trust(get),
         :ok <- access_listeners_apart(proxied?, {bind, port}, {proxy_bind, proxy_port}) do
      {:ok,
       %{
         bind: {bind, port},
         assertion: assertion,
         proxy: if(proxied?, do: {proxy_bind, proxy_port}, else: :none),
         trust: if(proxied?, do: trust, else: :none)
       }}
    end
  end

  # The proxy listener cannot take the loopback listener's port on an
  # address the loopback listener's overlaps: the same address (an
  # IPv4-mapped IPv6 address is the IPv4 address it maps), or an
  # unspecified one that takes it too (0.0.0.0 every IPv4 address, :: every
  # address), where the second listener would fail to bind.
  defp access_listeners_apart(false, _loopback, _proxy), do: :ok

  defp access_listeners_apart(true, {bind, port}, {proxy_bind, proxy_port}) do
    if port == proxy_port and
         overlapping?(unmapped(ip_literal(bind)), unmapped(ip_literal(proxy_bind))),
       do:
         {:error,
          {:access_setting_invalid,
           %{
             key: "CYFR_PROXY_PORT",
             value: Integer.to_string(proxy_port),
             address: proxy_bind,
             bind: bind,
             port: Integer.to_string(port)
           }}},
       else: :ok
  end

  defp unmapped({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}

  defp unmapped(ip), do: ip

  defp overlapping?(same, same), do: true
  defp overlapping?({0, 0, 0, 0, 0, 0, 0, 0}, _other), do: true
  defp overlapping?(_other, {0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp overlapping?({0, 0, 0, 0}, {_, _, _, _}), do: true
  defp overlapping?({_, _, _, _}, {0, 0, 0, 0}), do: true
  defp overlapping?(_a, _b), do: false

  defp access_bind(%{bind: {address, _port}, assertion: assertion}) do
    if assertion == :process or loopback?(address),
      do: :ok,
      else: {:error, {:access_bind_not_loopback, %{address: address}}}
  end

  # Only the compose file asserts its address local, and it asserts true.
  defp access_assertion(nil), do: {:ok, :absent}
  defp access_assertion("true"), do: {:ok, :process}

  defp access_assertion(other),
    do: {:error, {:access_setting_invalid, %{key: @assertion, value: other}}}

  defp access_port(get, key, default) do
    case get.(key) do
      nil ->
        {:ok, default}

      text ->
        if Regex.match?(@digits, text) and String.to_integer(text) in 1..65_535,
          do: {:ok, String.to_integer(text)},
          else: {:error, {:access_setting_invalid, %{key: key, value: text}}}
    end
  end

  defp access_address(get, key, default) do
    text = get.(key) || default

    if ip_literal(text),
      do: {:ok, text},
      else: {:error, {:access_setting_invalid, %{key: key, value: text}}}
  end

  # The proxies whose forwarded headers are trusted: the listed addresses
  # and CIDRs when there are any, otherwise a count of hops (default 1).
  defp access_trust(get) do
    case get.("CYFR_TRUSTED_PROXY_CIDRS") do
      nil ->
        case get.("CYFR_TRUSTED_PROXY_HOPS") do
          nil ->
            {:ok, {:hops, @default_proxy_hops}}

          text ->
            if Regex.match?(@digits, text) and String.to_integer(text) in 0..16,
              do: {:ok, {:hops, String.to_integer(text)}},
              else:
                {:error,
                 {:access_setting_invalid, %{key: "CYFR_TRUSTED_PROXY_HOPS", value: text}}}
        end

      text ->
        entries =
          text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        if entries != [] and Enum.all?(entries, &cidr?/1),
          do: {:ok, {:cidrs, entries}},
          else:
            {:error, {:access_setting_invalid, %{key: "CYFR_TRUSTED_PROXY_CIDRS", value: text}}}
    end
  end

  defp cidr?(entry) do
    case String.split(entry, "/") do
      [address] ->
        ip_literal(address) != nil

      [address, prefix] ->
        case ip_literal(address) do
          nil ->
            false

          ip ->
            max = if tuple_size(ip) == 4, do: 32, else: 128
            Regex.match?(~r/\A[0-9]{1,3}\z/, prefix) and String.to_integer(prefix) <= max
        end

      _ ->
        false
    end
  end

  # An IP literal, strictly: dotted quads in full, no zone. `nil` otherwise.
  defp ip_literal(text) do
    with false <- String.contains?(text, "%"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(text)) do
      ip
    else
      _ -> nil
    end
  end

  defp loopback?(text) do
    case ip_literal(text) do
      {127, _, _, _} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      _ -> false
    end
  end

  defp access_origin(%{"mode" => "local", "port" => port}), do: "http://localhost:#{port}"
  defp access_origin(%{"public_url" => url}), do: url

  # The loopback origins on the home's port, and its own address when it
  # has a public one.
  defp access_check_origins(%{"port" => port} = head) do
    own = if head["mode"] == "local", do: [], else: ["https://#{head["host"]}"]

    own ++
      for host <- ["localhost", "127.0.0.1", "[::1]"],
          scheme <- ["http", "https"],
          do: "#{scheme}://#{host}:#{port}"
  end

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

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
