# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Platform.Settings.Roster do
  @moduledoc """
  Every name the `cyfr` boot reads from its environment, declared once.

  Two planes. A **deployment variable** is read before the repo opens, or
  decides how the box is reachable, or is a security posture a stolen
  operator session must not change: `deployment/0` lists them, and they
  stay in the environment. Everything else is a **platform setting**:
  `entries/0` declares each one with its store key, the application and
  configuration path it is written to today, its variable, type, default,
  validator, group, scope, stale policy, apply function and, for the API
  rate-limit pair, the mark that an absent value inherits the MCP pair.

  Precedence is the environment when its variable is set (the boot records
  that presence as a pin, `pinned/0`), then the stored row, then the
  default. Arca stores the rows and answers them through
  `Arca.PlatformSettings.effective/1`; the host hands it `defaults/0`,
  plain values, and keeps every validator here, so no function crosses
  downward.

  Two more classes complete the inventory. `compose_only/0` is the names
  `docker-compose.yml` interpolates that no release reads. `foreign/0` is
  the `CYFR_*` names other programs own (the CLI, the installer, the test
  harness), which a shell may export beside a server. `unknown/2` is the
  refusal: a `CYFR_*` name in the boot's `.env` files that none of the
  first three classes declares, or one in its process environment that
  none of the four declares, refuses the boot naming it. That is how a
  retired name is refused without a list of retired names.

  `config/runtime.exs` reads this module only on the `cyfr` boot: an island
  release carries no host module, and `Opus.Settings` and `Locus.Config`
  declare their own prefixes.
  """

  defmodule Entry do
    @moduledoc """
    One platform setting.

      * `key` — the store key (`platform_settings.key`), a string.
      * `app` and `config` — the application and the configuration path the
        boot writes the value to while a reader still takes it from there:
        `[key]` for a top-level key, `[key, subkey]` for an entry of a
        keyword the reader takes whole (the caps, the worker watch), `nil`
        for a setting no reader takes from the application environment.
      * `variable` — the `CYFR_*` name that pins it, or `nil`.
      * `type` — the value's shape: `:integer`, `:boolean`, `:string`,
        `:duration_s` (whole seconds), `:list`, `:keyword` or `:atom` (a
        name from a closed set, stored as its string).
      * `default` — the value when neither the environment nor a row sets it;
        `nil` is a value where the reader reads it as "none" (an unset cap,
        the hostname for the device label).
      * `validator` — `(term() -> {:ok, term()} | {:error, form})`: takes the
        environment's text or a typed value and answers the typed value, or
        the form it must take (`"must be …"`), for a message that names the
        variable. Run at boot and by every later write; never installed
        into Arca.
      * `group`, `scope` (`:live | :restart`), `stale` (`:refuse | :serve`).
      * `apply` — `{module, function, 1}` for a restart-scoped entry and the
        log level, `nil` for every other live entry.
      * `inherit` — `true` for the API rate-limit pair alone: absent, the
        pair takes the MCP pair's value.
    """

    @enforce_keys [:key, :app, :variable, :type, :default, :validator, :group, :scope, :stale]
    defstruct [
      :key,
      :app,
      :config,
      :variable,
      :type,
      :default,
      :validator,
      :group,
      :scope,
      :stale,
      apply: nil,
      inherit: false
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            app: :cyfr | :sanctum | :arca | :logger,
            config: [atom()] | nil,
            variable: String.t() | nil,
            type: :integer | :boolean | :string | :duration_s | :list | :keyword | :atom,
            default: term(),
            validator: (term() -> {:ok, term()} | {:error, String.t()}),
            group: atom(),
            scope: :live | :restart,
            stale: :refuse | :serve,
            apply: {module(), atom(), 1} | nil,
            inherit: boolean()
          }
  end

  @type getenv :: (String.t() -> String.t() | nil)

  # The Logger levels, most to least severe: the log level's closed set.
  @levels ~w(emergency alert critical error warning notice info debug)

  # The host step that applies a restart-scoped value, and the log level's
  # live apply, both run by the settings process.
  @apply_log_level {Cyfr.Platform.Settings, :apply_log_level, 1}
  @apply_execution_slots {Cyfr.Platform.Settings, :apply_execution_slots, 1}

  @deployment ~w(
    CYFR_AUTH_PROVIDER CYFR_AUTO_MIGRATE CYFR_BEHIND_PROXY CYFR_BIND_ADDRESS
    CYFR_CELL_COOKIE CYFR_CLUSTER CYFR_CLUSTER_DNS_QUERY CYFR_CLUSTER_NODE_BASENAME
    CYFR_CLUSTER_NODES CYFR_CORS_ALLOWED_ORIGINS CYFR_COSIGN_IDENTITY CYFR_COSIGN_ISSUER
    CYFR_COSIGN_KEY CYFR_COSIGN_PASSWORD CYFR_CRYPTO_KEYRING
    CYFR_CRYPTO_KEYRING_FINGERPRINT_ACCEPT CYFR_DATABASE CYFR_DATABASE_PATH
    CYFR_DATABASE_URL CYFR_DATA_PATH CYFR_DB_POOL_SIZE CYFR_DB_SSL CYFR_GITHUB_CLIENT_ID
    CYFR_GOOGLE_CLIENT_ID CYFR_GOOGLE_CLIENT_SECRET CYFR_HEADLESS CYFR_HOST
    CYFR_HOST_API_BIND CYFR_HOST_API_PORT CYFR_HOST_API_URL CYFR_LIVE_SALT
    CYFR_LOCUS_BACKENDS_KEY CYFR_LOCUS_BACKENDS_URL CYFR_LOCUS_BUILDS_KEY
    CYFR_LOCUS_BUILDS_URL CYFR_LOG_FORMAT CYFR_MCP_ALLOWED_ORIGINS CYFR_METRICS_TOKEN
    CYFR_OCI_REGISTRY_URL CYFR_OIDC_CLIENT_ID CYFR_OIDC_CLIENT_SECRET CYFR_OIDC_ISSUER
    CYFR_OPUS_KEY CYFR_OPUS_WORKERS CYFR_OTEL_ENABLED CYFR_PLATFORM_ADMIN_EMAILS
    CYFR_PORT CYFR_PRIVATE_EGRESS_TARGETS CYFR_PROMETHEUS_METRICS CYFR_PUBLIC_URL
    CYFR_REGISTRY_URL CYFR_REQUIRE_SIGNED_PULLS CYFR_S3_ACCESS_KEY_ID CYFR_S3_BUCKET
    CYFR_S3_ENDPOINT CYFR_S3_PATH_STYLE CYFR_S3_PREFIX CYFR_S3_RECEIVE_TIMEOUT_MS
    CYFR_S3_REGION CYFR_S3_SECRET_ACCESS_KEY CYFR_SECRET_KEY_BASE CYFR_SEED_PATH
    CYFR_SESSION_SALT CYFR_STORAGE CYFR_TRUSTED_PROXY_CIDRS CYFR_TRUSTED_PROXY_HOPS
    OTEL_EXPORTER_OTLP_ENDPOINT
  )

  # The `${…}` names docker-compose.yml interpolates that no release reads:
  # each container's CPU and memory limit, and Caddy's ACME address.
  @compose_only ~w(
    CADDY_ACME_EMAIL CYFR_CPU_LIMIT LOCUS_BUILDS_CPU_LIMIT LOCUS_BUILDS_MEMORY_LIMIT
    OPUS_CPU_LIMIT OPUS_MEMORY_LIMIT
  )

  # Names under the prefix that other programs own. A trailing `*` is a
  # prefix. Only the process environment may carry them: a `.env` file is
  # the server's, and one of these in it is a mistake the boot names.
  @foreign [
    {"CYFR_TOKEN", "the Codex CLI: the session token its non-interactive path signs in with"},
    {"CYFR_NO_UPDATE_CHECK", "the Codex CLI: turns off its release check"},
    {"CYFR_INSECURE_SKIP_VERIFY", "the Codex CLI: skips TLS verification of the server it calls"},
    {"CYFR_INSTALL_DIR", "the installer (scripts/install.sh): where it puts the CLI"},
    {"CYFR_VERSION", "the installer: the release it installs"},
    {"CYFR_IMAGE", "the installer: the image the stack it writes runs"},
    {"CYFR_POSTGRES_TEST_URL", "the test harness: the PostgreSQL server the suite runs on"},
    {"CYFR_TEST_*", "the test harness: its partition, run root and object-store fixtures"},
    {"CYFR_CLUSTER_DATABASE_URL", "the test harness: the cluster suite's shared database"},
    {"CYFR_GOLDEN_RECORD", "the test harness: rewrites the consent bootstrap's golden file"}
  ]

  @doc "Every platform setting, in the order the boot reads them."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      # ——— tenancy caps: each gates a creation, so each refuses stale ———
      cap(:max_athanors, "CYFR_MAX_ATHANORS", nil, "athanors"),
      cap(:max_groups_per_person, "CYFR_MAX_GROUPS_PER_PERSON", 50, "groups"),
      cap(:max_pairs_per_person, "CYFR_MAX_PAIRS_PER_PERSON", 200, "pairs"),
      cap(:max_members_per_group, "CYFR_MAX_MEMBERS_PER_GROUP", nil, "members"),
      cap(:max_threads_per_athanor, "CYFR_MAX_THREADS_PER_ATHANOR", 1000, "threads"),
      cap(:mint_per_hour, "CYFR_MINT_PER_HOUR", nil, "athanors"),
      %Entry{
        key: "athanor_storage_bytes",
        app: :sanctum,
        config: [:caps, :athanor_storage_bytes],
        variable: "CYFR_ATHANOR_STORAGE_BYTES",
        type: :integer,
        default: nil,
        validator: byte_count(0..1_125_899_906_842_624),
        group: :tenancy,
        scope: :live,
        stale: :refuse
      },

      # ——— execution slots, applied once at boot ———
      %Entry{
        key: "crucible_max_concurrent",
        app: :cyfr,
        config: [:crucible_max_concurrent],
        variable: "CYFR_CRUCIBLE_MAX_CONCURRENT",
        type: :integer,
        default: Prima.Slots.default_max(),
        # A quarter of the slots is the chain children's reserve, which must
        # hold a chain of the full authority depth (8): below 32 a deep
        # chain could wait on itself.
        validator: whole(32..1_000_000, "executions"),
        group: :execution,
        scope: :restart,
        stale: :serve,
        apply: @apply_execution_slots
      },
      %Entry{
        key: "crucible_max_concurrent_per_tenant",
        app: :cyfr,
        config: [:crucible_max_concurrent_per_tenant],
        variable: "CYFR_CRUCIBLE_MAX_CONCURRENT_PER_TENANT",
        type: :integer,
        default: Prima.Slots.default_key_max(),
        validator: whole(1..1_000_000, "executions"),
        group: :execution,
        scope: :restart,
        stale: :serve,
        apply: @apply_execution_slots
      },

      # ——— rate limits: served stale, so a store hiccup refuses nobody ———
      limit(:mcp_rate_limit_max, "CYFR_MCP_RATE_LIMIT_MAX", 120, requests(), :rate_limits),
      limit(
        :mcp_rate_limit_window_ms,
        "CYFR_MCP_RATE_LIMIT_WINDOW_MS",
        60_000,
        window(),
        :rate_limits
      ),
      %{
        limit(:api_rate_limit_max, "CYFR_API_RATE_LIMIT_MAX", nil, requests(), :rate_limits)
        | inherit: true
      },
      %{
        limit(
          :api_rate_limit_window_ms,
          "CYFR_API_RATE_LIMIT_WINDOW_MS",
          nil,
          window(),
          :rate_limits
        )
        | inherit: true
      },
      limit(
        :webhook_per_ip_rate_limit_max,
        "CYFR_WEBHOOK_PER_IP_RATE_LIMIT_MAX",
        6_000,
        requests(),
        :rate_limits
      ),

      # ——— per-member stream limits ———
      limit(
        :mcp_subscription_max_concurrent,
        "CYFR_MCP_SUBSCRIPTION_MAX_CONCURRENT",
        8,
        whole(1..1_000_000, "streams"),
        :streams
      ),
      limit(
        :mcp_subscription_max_ms,
        "CYFR_MCP_SUBSCRIPTION_MAX_MS",
        1_800_000,
        window(),
        :streams
      ),
      limit(
        :crucible_events_max_concurrent,
        "CYFR_CRUCIBLE_EVENTS_MAX_CONCURRENT",
        8,
        whole(1..1_000_000, "streams"),
        :streams
      ),
      limit(
        :crucible_events_max_ms,
        "CYFR_CRUCIBLE_EVENTS_MAX_MS",
        1_800_000,
        window(),
        :streams
      ),

      # ——— sessions and webhooks: security windows, refused stale ———
      %Entry{
        key: "session_ttl_hours",
        app: :sanctum,
        config: [:session_ttl_hours],
        variable: "CYFR_SESSION_TTL_HOURS",
        type: :integer,
        # 0 is a value: sessions that never idle out.
        default: 720,
        validator: whole(0..876_000, "hours"),
        group: :sessions,
        scope: :live,
        stale: :refuse
      },
      %Entry{
        key: "webhook_max_skew_seconds",
        app: :sanctum,
        config: [:webhook_max_skew_seconds],
        variable: "CYFR_WEBHOOK_MAX_SKEW_SECONDS",
        type: :duration_s,
        default: 300,
        validator: whole(1..86_400, "seconds"),
        group: :webhooks,
        scope: :live,
        stale: :refuse
      },
      %Entry{
        key: "webhook_idempotency_ttl_seconds",
        app: :cyfr,
        config: [:webhook_idempotency_ttl_seconds],
        variable: "CYFR_WEBHOOK_IDEMPOTENCY_TTL_SECONDS",
        type: :duration_s,
        default: 86_400,
        validator: whole(1..31_536_000, "seconds"),
        group: :webhooks,
        scope: :live,
        stale: :refuse
      },

      # ——— the rest of the host's knobs ———
      %Entry{
        key: "device_label",
        app: :cyfr,
        config: [:device_label],
        variable: "CYFR_DEVICE_LABEL",
        type: :string,
        # Unset is the hostname, which the reader asks for itself.
        default: nil,
        validator: &label/1,
        group: :registry,
        scope: :live,
        stale: :serve
      },
      limit(
        :health_ready_cache_ms,
        "CYFR_HEALTH_READY_CACHE_MS",
        5_000,
        whole(0..86_400_000, "milliseconds"),
        :health
      ),
      limit(
        :decision_retention_days,
        "CYFR_DECISION_RETENTION_DAYS",
        365,
        whole(1..36_500, "days"),
        :retention
      ),
      %Entry{
        key: "opus_watch_poll_ms",
        app: :cyfr,
        config: [:opus_watch, :poll_ms],
        variable: "CYFR_OPUS_WATCH_POLL_MS",
        type: :integer,
        default: 5_000,
        validator: whole(1_000..60_000, "milliseconds"),
        group: :workers,
        scope: :live,
        stale: :serve
      },
      %Entry{
        key: "opus_watch_misses",
        app: :cyfr,
        config: [:opus_watch, :misses],
        variable: "CYFR_OPUS_WATCH_MISSES",
        type: :integer,
        default: 3,
        validator: whole(1..100, "misses"),
        group: :workers,
        scope: :live,
        stale: :serve
      },
      limit(
        :locus_backends_lease_ms,
        "CYFR_LOCUS_BACKENDS_LEASE_MS",
        30_000,
        whole(1_000..60_000, "milliseconds"),
        :backends
      ),
      limit(
        :locus_backends_idle_ms,
        "CYFR_LOCUS_BACKENDS_IDLE_MS",
        900_000,
        whole(1_000..86_400_000, "milliseconds"),
        :backends
      ),
      %Entry{
        key: "log_level",
        app: :logger,
        config: [:level],
        variable: "CYFR_LOG_LEVEL",
        type: :atom,
        default: :info,
        validator: &level/1,
        group: :logging,
        scope: :live,
        stale: :serve,
        apply: @apply_log_level
      },

      # ——— the tincture credentials (read by Sanctum.TinctureAuth since C0) and the per-frame rate (read from C2b) ———
      unread(
        "asset_credential_window_s",
        "CYFR_ASSET_CREDENTIAL_WINDOW_S",
        :duration_s,
        3_600,
        whole(1..86_400, "seconds")
      ),
      unread(
        "frame_credential_deadline_s",
        "CYFR_FRAME_CREDENTIAL_DEADLINE_S",
        :duration_s,
        3_600,
        whole(1..86_400, "seconds")
      ),
      unread("frame_invocation_max", "CYFR_FRAME_INVOCATION_MAX", :integer, 120, requests()),
      unread(
        "frame_invocation_window_ms",
        "CYFR_FRAME_INVOCATION_WINDOW_MS",
        :integer,
        60_000,
        window()
      )
    ]
  end

  defp cap(key, variable, default, unit) do
    %Entry{
      key: Atom.to_string(key),
      app: :sanctum,
      config: [:caps, key],
      variable: variable,
      type: :integer,
      # 0 disables a defaulted cap, so it is a value, not "unset".
      default: default,
      validator: whole(0..1_000_000_000, unit),
      group: :tenancy,
      scope: :live,
      stale: :refuse
    }
  end

  defp limit(key, variable, default, validator, group) do
    %Entry{
      key: Atom.to_string(key),
      app: :cyfr,
      config: [key],
      variable: variable,
      type: :integer,
      default: default,
      validator: validator,
      group: group,
      scope: :live,
      stale: :serve
    }
  end

  defp unread(key, variable, type, default, validator) do
    %Entry{
      key: key,
      app: :cyfr,
      config: nil,
      variable: variable,
      type: type,
      default: default,
      validator: validator,
      group: :tinctures,
      scope: :live,
      stale: :serve
    }
  end

  defp requests, do: whole(1..1_000_000_000, "requests")
  defp window, do: whole(1..86_400_000, "milliseconds")

  # ---------------------------------------------------------------------------
  # Validators
  # ---------------------------------------------------------------------------

  # A whole number of `unit` in `range`, from the environment's text (read
  # by the strict reader the boot has always used, `Prima.EnvValue`) or as
  # an integer.
  defp whole(_first.._last//1 = range, unit) do
    bounded(range, unit, &Prima.EnvValue.whole_number(&1, "value", range, unit))
  end

  # A count of bytes, whose range reaches past what `whole/2` reads.
  defp byte_count(_first.._last//1 = range) do
    bounded(range, "bytes", &Prima.EnvValue.bytes(&1, "value", range))
  end

  defp bounded(first..last//1, unit, read) do
    form = "must be a whole number of #{unit} from #{first} to #{last}"

    fn
      value when is_integer(value) and value >= first and value <= last ->
        {:ok, value}

      text when is_binary(text) ->
        case read.(fn _name -> text end) do
          {:ok, value} when is_integer(value) -> {:ok, value}
          _blank_or_refused -> {:error, form}
        end

      _other ->
        {:error, form}
    end
  end

  defp level(value) when is_atom(value) and not is_nil(value), do: level(Atom.to_string(value))

  defp level(text) when is_binary(text) and text in @levels,
    do: {:ok, String.to_existing_atom(text)}

  defp level(_other), do: {:error, "must be a Logger level: #{Enum.join(@levels, ", ")}"}

  defp label(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed != "" and byte_size(trimmed) <= 255 and String.printable?(trimmed),
      do: {:ok, trimmed},
      else: {:error, "must be 1 to 255 bytes of printable text"}
  end

  defp label(_other), do: {:error, "must be 1 to 255 bytes of printable text"}

  # ---------------------------------------------------------------------------
  # The inventory
  # ---------------------------------------------------------------------------

  @doc "The entry stored under `key`."
  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(key) when is_binary(key) do
    case Enum.find(entries(), &(&1.key == key)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Every rostered setting's variable."
  @spec variables() :: [String.t()]
  def variables, do: for(%Entry{variable: v} <- entries(), v != nil, do: v)

  @doc """
  The deployment variables: read before the repo opens, deciding how the
  box is reachable, or a security posture a stolen operator session must
  not change. `OTEL_EXPORTER_OTLP_ENDPOINT` is not under the prefix and is
  listed so every name the boot reads has one home.
  """
  @spec deployment() :: [String.t()]
  def deployment, do: @deployment

  @doc """
  The names `docker-compose.yml` interpolates that no release reads: the
  containers' CPU and memory limits and Caddy's ACME address.
  """
  @spec compose_only() :: [String.t()]
  def compose_only, do: @compose_only

  @doc """
  The `CYFR_*` names other programs own, each with its owner; a name
  ending in `*` is a prefix. Tolerated in the process environment alone.
  """
  @spec foreign() :: [{String.t(), String.t()}]
  def foreign, do: @foreign

  @doc """
  The installed data Arca's accessor reads (`Arca.PlatformSettings.install_defaults!/1`):
  each key's default and stale policy, plain values.
  """
  @spec defaults() :: %{String.t() => %{default: term(), stale: :refuse | :serve}}
  def defaults, do: Map.new(entries(), &{&1.key, %{default: &1.default, stale: &1.stale}})

  @doc """
  The `{application, key}` pairs the entries are written under today: the
  head of each entry's configuration path. `Cyfr.Boundaries` classes these
  keys `:setting`.
  """
  @spec config_keys() :: [{atom(), atom()}]
  def config_keys do
    for %Entry{app: app, config: [key | _]} <- entries(), uniq: true, do: {app, key}
  end

  @doc """
  The settings this boot's environment pinned, as `config/runtime.exs`
  recorded them: `{key, value}`, sorted by key.
  """
  @spec pinned() :: [{String.t(), term()}]
  def pinned, do: Application.get_env(:cyfr, :deployment_pinned, [])

  # ---------------------------------------------------------------------------
  # The boot
  # ---------------------------------------------------------------------------

  @doc """
  `entry`'s value as `getenv` spells its variable: `{:ok, nil}` when unset
  or blank, the validated value when set, or the refusal naming the
  variable and the form it must take.
  """
  @spec read(Entry.t(), getenv()) :: {:ok, term()} | {:error, String.t()}
  def read(%Entry{variable: nil}, _getenv), do: {:ok, nil}

  def read(%Entry{variable: variable, validator: validator}, getenv)
      when is_function(getenv, 1) do
    case Prima.EnvValue.text(getenv, variable) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, text} ->
        case validator.(text) do
          {:ok, value} -> {:ok, value}
          {:error, form} -> {:error, "#{variable}=#{inspect(text)} #{form}."}
        end
    end
  end

  @doc """
  The `CYFR_*` names the boot must refuse: those in `file_names` (every
  name the `.env` files it sources assign) that no entry, deployment
  variable or compose-only name declares, and those in `process_names`
  (its process environment) that none of those nor `foreign/0` declares.
  Sorted, each once.
  """
  @spec unknown([String.t()], [String.t()]) :: [String.t()]
  def unknown(file_names, process_names) when is_list(file_names) and is_list(process_names) do
    declared = MapSet.new(variables() ++ deployment() ++ compose_only())

    from_files = Enum.filter(file_names, &undeclared?(&1, declared))

    from_process =
      Enum.filter(process_names, &(undeclared?(&1, declared) and not foreign?(&1)))

    Enum.sort(Enum.uniq(from_files ++ from_process))
  end

  @doc "The refusal the boot raises for `names`, as `unknown/2` answers them."
  @spec refusal([String.t(), ...]) :: String.t()
  def refusal([_ | _] = names) do
    "#{Enum.join(names, ", ")} #{if match?([_], names), do: "is", else: "are"} not a " <>
      "variable this server reads: no platform setting, deployment variable or " <>
      "compose-only name declares it. Remove it, or use the name `.env.example` gives."
  end

  defp undeclared?(name, declared),
    do: String.starts_with?(name, "CYFR_") and not MapSet.member?(declared, name)

  defp foreign?(name) do
    Enum.any?(@foreign, fn {declared, _owner} ->
      case String.split_at(declared, -1) do
        {prefix, "*"} -> String.starts_with?(name, prefix)
        _exact -> name == declared
      end
    end)
  end
end
