# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Context do
  @moduledoc """
  Execution context that flows through all CYFR service calls.

  Context represents whoever is using the instance — a user, an API key,
  a webhook receiver, a scheduled job, or the system itself. It carries
  the persistent identity (user_id, email, provider, permissions, org_id,
  project_id) plus per-request decoration (request_id, correlation_id,
  session_id, api_key_id, scope, auth_method, authenticated).

  Tests construct permissive single-user contexts via
  `Sanctum.TestContext.local/0` (compiled only in `:test` and `:dev`).

  ## Usage

  Every service function takes context as its first argument:

      Opus.execute(ctx, reference, input)
      Locus.build(ctx, source, target)
      Arca.get(ctx, path)

  Context carries optional tenant coordinates (`org_id`, `project_id`,
  `scope`). Only *how* a context is constructed varies by deployment
  configuration — never the functions that consume it.
  """

  require Logger

  @type scope :: :org | :project | :platform
  @type auth_method ::
          :oidc | :api_key | :scheduled | :webhook | :tincture | :system | :session | nil
  @type api_key_type :: :application | :service | :admin | nil
  @type plane :: :external | :guest

  @type t :: %__MODULE__{
          user_id: String.t(),
          email: String.t() | nil,
          provider: String.t() | nil,
          namespace: String.t() | nil,
          org_id: String.t() | nil,
          project_id: String.t() | nil,
          permissions: MapSet.t(atom()),
          scope: scope(),
          auth_method: auth_method(),
          api_key_type: api_key_type(),
          request_id: String.t() | nil,
          correlation_id: String.t() | nil,
          session_id: String.t() | nil,
          api_key_id: String.t() | nil,
          authenticated: boolean(),
          anonymous: boolean(),
          plane: plane()
        }

  defstruct [
    :user_id,
    :email,
    :provider,
    :namespace,
    :org_id,
    :project_id,
    :permissions,
    :scope,
    :auth_method,
    :api_key_type,
    :request_id,
    :correlation_id,
    :session_id,
    :api_key_id,
    authenticated: false,
    # True when the ORIGINATING caller presented no credentials (public
    # tincture invocation). Ingress adapters may still mint an authenticated
    # execution context for such a caller, but the credential plane
    # (Sanctum.VaultReader) denies anonymous contexts — an anonymous internet
    # caller must never reach operator credentials.
    anonymous: false,
    # Which authorization plane this context is on. :external is every real
    # ingress; :guest is stamped one-way by enter_guest/1 when a context
    # enters a WASM closure (Opus.Executor before a guest run, AquaLive before an
    # approved in-chain call), and require_permission/2 fails closed on it — a
    # context that has entered a guest closure can never authorize an
    # external-plane call.
    plane: :external
  ]

  @doc """
  Context for scheduled (cron) executions.

  Grants execute and storage permissions scoped to the originating user.
  """
  def for_scheduled(user_id, opts \\ []) do
    # Delegates to the single builder; cron's only divergence from the
    # `:system` default is the `:scheduled` provenance tag. namespace is pure
    # identity (not path-bearing), so an absent one is fine — the schedule's
    # org_id/project_id determine where its files land.
    #
    # Permissions are stated explicitly rather than inherited from
    # internal/1's defaults, so what a schedule runs with is visible here
    # and can't silently widen if the internal default ever changes.
    internal(
      user_id: user_id,
      namespace: Keyword.get(opts, :namespace),
      org_id: Keyword.get(opts, :org_id),
      project_id: Keyword.get(opts, :project_id, Arca.Tenant.default_project()),
      scope: :project,
      auth_method: :scheduled,
      permissions: [:execute, :storage_read, :storage_write, :execution_write],
      correlation_id: Keyword.get(opts, :correlation_id)
    )
  end

  @doc """
  Centralized context constructor for all entry points.

  Builds a properly structured context from a keyword list or map of attributes.
  All entry points (auth providers, API keys, LiveView hooks) should use this
  to ensure consistent field population.

  ## Options

  - `:user_id` - User ID (required for authenticated contexts)
  - `:org_id` - Organization ID (defaults to the seeded `"local"` org for
    non-platform scopes; `nil` only for `:platform`)
  - `:project_id` - Project ID (defaults to "default" for local auth)
  - `:permissions` - List or MapSet of permission atoms
  - `:scope` - Scope atom (:org, :project, :platform)
  - `:auth_method` - Authentication method atom
  - `:api_key_type` - API key type atom
  - `:api_key_id` - API key identifier
  - `:request_id` - MCP request ID
  - `:correlation_id` - Cross-request correlation ID
  - `:session_id` - Session ID
  - `:authenticated` - Boolean (default: false)

  ## Examples

      iex> Sanctum.Context.build(user_id: "user_1", permissions: [:execute], auth_method: :oidc, authenticated: true)
      %Sanctum.Context{user_id: "user_1", permissions: MapSet.new([:execute]), auth_method: :oidc, authenticated: true}

  """
  @spec build(keyword() | map()) :: t()
  def build(attrs) when is_list(attrs) do
    attrs |> Map.new() |> build()
  end

  @valid_scopes [:org, :project, :platform]

  # Mirrors the `auth_method()` type. Guarded at the construction site so a
  # typo or a removed value (e.g. the old `:local`) can't enter a Context and
  # silently bypass auth_method-keyed logic.
  @valid_auth_methods [:oidc, :api_key, :scheduled, :webhook, :tincture, :system, :session, nil]

  # Mirrors the `plane()` type, guarded for the same reason.
  @valid_planes [:external, :guest]

  def build(attrs) when is_map(attrs) do
    scope = Map.get(attrs, :scope, :project)

    unless scope in @valid_scopes do
      raise ArgumentError,
            "invalid scope #{inspect(scope)}, must be one of #{inspect(@valid_scopes)}"
    end

    auth_method = Map.get(attrs, :auth_method)

    unless auth_method in @valid_auth_methods do
      raise ArgumentError,
            "invalid auth_method #{inspect(auth_method)}, must be one of " <>
              "#{inspect(@valid_auth_methods)}"
    end

    plane = Map.get(attrs, :plane, :external)

    unless plane in @valid_planes do
      raise ArgumentError,
            "invalid plane #{inspect(plane)}, must be one of #{inspect(@valid_planes)}"
    end

    for field <- [
          :user_id,
          :email,
          :provider,
          :namespace,
          :org_id,
          :project_id,
          :request_id,
          :correlation_id,
          :session_id,
          :api_key_id
        ] do
      val = Map.get(attrs, field)

      unless is_nil(val) or is_binary(val) do
        raise ArgumentError, "#{field} must be a string or nil, got: #{inspect(val)}"
      end
    end

    authenticated = Map.get(attrs, :authenticated, false)

    # An authenticated context must name its principal — every real producer
    # sets user_id (system tasks use "system"). A nil here is a construction
    # bug; catch it before it reaches authz/storage. namespace is NOT required:
    # it is a pure identity field (attribution/tincture tokens), not a storage
    # primitive — an absent namespace is valid (e.g. a user who hasn't claimed
    # a cyfr.run slug yet).
    if authenticated and is_nil(Map.get(attrs, :user_id)) do
      raise ArgumentError,
            "Sanctum.Context.build/1: authenticated contexts require :user_id " <>
              "(scope=#{inspect(scope)} auth_method=#{inspect(auth_method)})."
    end

    permissions =
      case Map.get(attrs, :permissions, MapSet.new()) do
        %MapSet{} = ms -> ms
        list when is_list(list) -> MapSet.new(list)
        _ -> MapSet.new()
      end

    # Default project_id to the seeded sentinel for non-platform contexts. This
    # guarantee lets the rest of the codebase rely on ctx.project_id
    # being non-nil whenever scope is not :platform. An empty string is never a
    # valid project id — coerce it to the sentinel (only "" is invalid; an
    # explicit nil is the transient pre-resolution state and is preserved).
    project_id =
      case Map.get(attrs, :project_id) do
        nil when scope != :platform -> Arca.Tenant.default_project()
        "" -> Arca.Tenant.default_project()
        other -> other
      end

    # org_id resolution. The invariant: a service-bound context always carries
    # a concrete org; `""` is never valid, and `nil` survives only as the
    # transient pre-resolution auth state.
    #   * empty string → the seeded sentinel ("" is an invalid value, not a
    #     tenant; never let it propagate).
    #   * key present (incl. an explicit `org_id: nil`) → used as-is. Auth
    #     paths pass `org_id: nil` to start org-less, then resolve the real org
    #     from memberships via `Sanctum.Tenancy.resolve_into/2`; an unresolved
    #     non-platform context is rejected by the tenant gate.
    #   * key absent, `:platform` → nil (direct platform builds; the sanctioned
    #     system path `internal/1` supplies the sentinel explicitly).
    #   * key absent, non-platform → the seeded sentinel workspace.
    org_id =
      cond do
        Map.get(attrs, :org_id) == "" -> Arca.Tenant.local_org()
        Map.has_key?(attrs, :org_id) -> Map.get(attrs, :org_id)
        scope == :platform -> nil
        true -> Arca.Tenant.local_org()
      end

    ctx = %__MODULE__{
      user_id: Map.get(attrs, :user_id),
      email: Map.get(attrs, :email),
      provider: Map.get(attrs, :provider),
      namespace: Map.get(attrs, :namespace),
      org_id: org_id,
      project_id: project_id,
      permissions: permissions,
      scope: scope,
      auth_method: Map.get(attrs, :auth_method),
      api_key_type: Map.get(attrs, :api_key_type),
      request_id: Map.get(attrs, :request_id),
      correlation_id: Map.get(attrs, :correlation_id),
      session_id: Map.get(attrs, :session_id),
      api_key_id: Map.get(attrs, :api_key_id),
      authenticated: Map.get(attrs, :authenticated, false),
      anonymous: Map.get(attrs, :anonymous, false) == true,
      plane: plane
    }

    # Audit every platform-scope construction. `:platform` bypasses ALL tenant
    # checks, so there must be a record of who creates it. The sanctioned path
    # (`internal/1` / `system_context/0`) sets the private `__platform_ok__`
    # marker; a direct `Context.build(scope: :platform, ...)` is still allowed
    # (many legitimate test fixtures rely on it) but is logged as unsanctioned
    # so it is observable rather than silent.
    maybe_audit_platform(ctx, Map.get(attrs, :__platform_ok__, false) == true)
    ctx
  end

  @doc """
  The single builder for server-constructed, no-external-credential contexts.

  Every non-interactive context — secret-store bootstrap, execution-record
  write-back, filesystem scans, sweepers, health checks, retention, audit
  fan-out, and cron (via `for_scheduled/2`) — flows through here so there is
  exactly one construction path. `auth_method` records provenance only (audit/
  telemetry); it does not grant access.

  Options (all optional):

    * `:user_id`        — default `"system"`
    * `:namespace`      — default `"_system"`
    * `:org_id`         — default the seeded sentinel (`Arca.Tenant.local_org/0`)
    * `:project_id`     — default the seeded sentinel (`Arca.Tenant.default_project/0`)
    * `:permissions`    — default `[:execute, :storage_read, :execution_write, :storage_write]`
    * `:scope`          — default `:platform`
    * `:auth_method`    — default `:system`; cron passes `:scheduled`
    * `:correlation_id` — default `nil`

  `authenticated:` is always `true`.

  ## Examples

      iex> ctx = Sanctum.Context.internal()
      iex> {ctx.auth_method, ctx.scope, ctx.user_id, ctx.namespace}
      {:system, :platform, "system", nil}

  """
  @spec internal(keyword()) :: t()
  def internal(opts \\ []) do
    build(
      user_id: Keyword.get(opts, :user_id, "system"),
      namespace: Keyword.get(opts, :namespace),
      org_id: Keyword.get(opts, :org_id, Arca.Tenant.local_org()),
      project_id: Keyword.get(opts, :project_id, Arca.Tenant.default_project()),
      permissions:
        Keyword.get(opts, :permissions, [
          :execute,
          :storage_read,
          :execution_write,
          :storage_write
        ]),
      scope: Keyword.get(opts, :scope, :platform),
      auth_method: Keyword.get(opts, :auth_method, :system),
      correlation_id: Keyword.get(opts, :correlation_id),
      authenticated: true,
      # Marks this as the single sanctioned platform-construction path so the
      # audit in build/1 records it as sanctioned (no warning).
      __platform_ok__: true
    )
  end

  # ============================================================================
  # Identity helpers
  # ============================================================================

  @doc """
  Build the canonical user id `"<provider>|<iss>|<subject>"`.

  Used by every Context construction site (OIDC claims, OAuth,
  DeviceFlow, Ueberauth callback) so the id shape stays consistent.
  """
  @spec build_id(String.t() | atom(), String.t(), String.t()) :: String.t()
  def build_id(provider, iss, sub) when is_atom(provider),
    do: build_id(Atom.to_string(provider), iss, sub)

  def build_id(provider, iss, sub)
      when is_binary(provider) and is_binary(iss) and is_binary(sub) and
             provider != "" and iss != "" and sub != "" do
    "#{provider}|#{iss}|#{sub}"
  end

  # Reject empty components. An empty iss/sub produced a degenerate id like
  # "github||" that can collide across users and normalize unexpectedly — an
  # identity must have all three parts.
  def build_id(provider, iss, sub) do
    raise ArgumentError,
          "invalid identity components: " <>
            "provider=#{inspect(provider)} iss=#{inspect(iss)} sub=#{inspect(sub)}"
  end

  @doc """
  Hardcoded canonical `iss` (RFC 7519 issuer) for a provider atom.

  GitHub and Google have stable, well-known issuer URLs; OAuth and
  DeviceFlow don't receive an iss from their userinfo endpoints, so they
  use these constants to build user ids in the same format as OIDC-claim
  logins produce.

  ## Examples

      iex> Sanctum.Context.provider_iss(:github)
      "https://github.com"

      iex> Sanctum.Context.provider_iss(:google)
      "https://accounts.google.com"

  """
  @spec provider_iss(atom() | String.t()) :: String.t()
  def provider_iss(:github), do: "https://github.com"
  def provider_iss(:google), do: "https://accounts.google.com"
  def provider_iss("github"), do: "https://github.com"
  def provider_iss("google"), do: "https://accounts.google.com"

  # Explicit failure (vs. a FunctionClauseError) if a third built-in provider
  # is ever added without a canonical issuer registered here.
  def provider_iss(other) do
    raise ArgumentError, "no canonical issuer registered for provider #{inspect(other)}"
  end

  @doc """
  Construct a Context from OIDC claims (without permissions/membership —
  callers fill those in via subsequent resolver calls).

  The `id` is `"<provider>|<iss>|<subject>"` — pipe-delimited, scheme-prefixed
  issuer. Deterministic for a given IdP identity, so the same human via the
  same IdP always resolves to the same id regardless of deployment
  configuration.

  ## Examples

      iex> claims = %{"sub" => "12345", "email" => "alice@example.com", "iss" => "https://github.com"}
      iex> ctx = Sanctum.Context.from_oidc_claims(claims)
      iex> ctx.email
      "alice@example.com"
      iex> ctx.user_id
      "github|https://github.com|12345"

  """
  @spec from_oidc_claims(map()) :: t()
  def from_oidc_claims(claims) do
    iss = claims["iss"]
    sub = claims["sub"]
    provider = claims["provider"] || derive_provider(iss)

    build(
      user_id: build_id(provider, iss, sub),
      email: claims["email"],
      provider: iss
    )
  end

  defp derive_provider(iss) when is_binary(iss) do
    # Match on the normalized HOST, not a substring. `String.contains?` would
    # also match a look-alike like `https://github.com.attacker.example/` or
    # `https://evil-github.com/`.
    case normalized_issuer_host(iss) do
      "github.com" -> "github"
      "accounts.google.com" -> "google"
      _ -> "oidc"
    end
  end

  defp derive_provider(_), do: "oidc"

  @doc false
  # Lowercased host of an issuer string, tolerant of a missing scheme and a
  # trailing slash/port. Returns "" when no host can be determined.
  def normalized_issuer_host(iss) when is_binary(iss) do
    trimmed = iss |> String.trim() |> String.trim_trailing("/")
    with_scheme = if String.contains?(trimmed, "://"), do: trimmed, else: "https://" <> trimmed

    case URI.parse(with_scheme) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> ""
    end
  end

  def normalized_issuer_host(_), do: ""

  @doc """
  Normalize a free-text handle (email local-part, provider login) into a
  cyfr.run personal-slug candidate.

  Personal slugs must match `^[a-z0-9]+(-[a-z0-9]+)*$` (1–39 chars; GitHub-style).
  Email local-parts routinely contain `.`, `+`, uppercase, underscores — all of
  which the server rejects with 400 `INVALID_USERNAME`. This helper applies the
  same normalization the server expects so a pre-filled suggestion doesn't
  doom-submit.

  Returns `nil` when no non-empty valid slug can be derived (e.g. input is
  `nil`, empty, or all punctuation).

  ## Examples

      iex> Sanctum.Context.suggest_slug("alice@example.com")
      "alice"

      iex> Sanctum.Context.suggest_slug("alice.smith+tag@example.com")
      "alice-smith-tag"

      iex> Sanctum.Context.suggest_slug("ALICE@example.com")
      "alice"

      iex> Sanctum.Context.suggest_slug(nil)
      nil

      iex> Sanctum.Context.suggest_slug("@@@")
      nil

  """
  @spec suggest_slug(String.t() | nil) :: String.t() | nil
  def suggest_slug(nil), do: nil

  def suggest_slug(raw) when is_binary(raw) do
    local =
      case String.split(raw, "@", parts: 2) do
        [local, _domain] -> local
        [local] -> local
      end

    slug =
      local
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 39)
      |> String.trim_trailing("-")

    if Sanctum.ComponentRef.valid_personal_slug?(slug), do: slug, else: nil
  end

  def suggest_slug(_), do: nil

  @doc """
  Derives the active scope for authorization decisions.

  Returns the most specific scope that applies given the context's fields.
  This is a derived value — NOT stored — to avoid staleness.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.active_scope(ctx)
      :project

      iex> ctx = %Sanctum.Context{scope: :org, org_id: "org_1"}
      iex> Sanctum.Context.active_scope(ctx)
      :org

  """
  @spec active_scope(t()) :: scope()
  def active_scope(%__MODULE__{} = ctx) do
    cond do
      ctx.scope == :platform -> :platform
      ctx.scope == :org and is_binary(ctx.org_id) and ctx.org_id != "" -> :org
      ctx.project_id != nil -> :project
      ctx.org_id != nil -> :org
      true -> :project
    end
  end

  @doc """
  Check if context has a specific permission.

  The wildcard permission `:*` grants all permissions.

  This is the raw identity-membership predicate and deliberately ignores
  `plane` — in-chain authorization needs it as its identity conjunct
  (identity permission AND Authority resource). It is never sufficient
  authorization on its own; gates use `require_permission/2`, which fails
  closed on the guest plane.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.has_permission?(ctx, :execute)
      true
      iex> Sanctum.Context.has_permission?(ctx, :any_permission)
      true

  """
  def has_permission?(%__MODULE__{permissions: perms}, permission) do
    MapSet.member?(perms, :*) or MapSet.member?(perms, permission)
  end

  @doc """
  One-way transition onto the guest plane, taken when a context is closed
  into a WASM execution.

  Deliberately a struct update, not `build/1` — a rebuild would re-run
  defaulting and could launder the field back to `:external`. There is no
  inverse: once a context has entered a guest closure, nothing turns it
  back into an external-plane context.
  """
  @spec enter_guest(t()) :: t()
  def enter_guest(%__MODULE__{} = ctx), do: %{ctx | plane: :guest}

  @doc """
  Require permission, returning `{:error, message}` if missing.

  Used by MCP tool handlers in `with` chains.

  Fails closed on guest-plane contexts regardless of permissions — even a
  `:*` wildcard: a context inside a WASM closure never authorizes an
  external-plane call. In-chain operations are authorized by the current
  `Sanctum.Authority`, with `has_permission?/2` as the identity conjunct.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.require_permission(ctx, :execute)
      :ok

  """
  @spec require_permission(t(), atom()) :: :ok | {:error, String.t()}
  def require_permission(%__MODULE__{plane: :guest}, permission) do
    {:error,
     "Unauthorized: guest-plane context cannot authorize '#{permission}' " <>
       "(external plane required)"}
  end

  def require_permission(%__MODULE__{} = ctx, permission) do
    if has_permission?(ctx, permission) do
      :ok
    else
      hint =
        if ctx.auth_method == :api_key do
          " (API key does not include this scope — recreate with --scope #{permission})"
        else
          ""
        end

      {:error, "Unauthorized: missing required permission '#{permission}'#{hint}"}
    end
  end

  @doc """
  The identity half of the in-chain authorization conjunction.

  An in-chain operation is authorized by the chain's authority **and** the
  caller's identity; the authority conjunct is applied at the dispatch
  chokepoint before any provider runs, so the provider's identity check
  must not re-refuse the guest plane — that would make in-chain calls
  unauthorizable by construction. This is the one sanctioned way for a
  gate to serve a guest-planed context, and it never applies to
  external-plane callers, who keep the fail-closed `require_permission/2`.
  """
  @spec require_identity_permission(t(), atom()) :: :ok | {:error, String.t()}
  def require_identity_permission(%__MODULE__{} = ctx, permission) do
    if has_permission?(ctx, permission) do
      :ok
    else
      {:error, "Unauthorized: missing required permission '#{permission}'"}
    end
  end

  @doc """
  Plane-aware permission gate — the one sanctioned shim for an MCP tool provider.

  Guest-planed callers get the identity conjunct (`require_identity_permission/2`),
  because the authority conjunct was already applied at the dispatch chokepoint;
  external-plane callers keep the fail-closed `require_permission/2`. Providers
  call this instead of hand-rolling the two-clause shim, so the rule lives in one
  place and cannot drift between them.
  """
  @spec require_permission_for_plane(t(), atom()) :: :ok | {:error, String.t()}
  def require_permission_for_plane(%__MODULE__{plane: :guest} = ctx, permission),
    do: require_identity_permission(ctx, permission)

  def require_permission_for_plane(%__MODULE__{} = ctx, permission),
    do: require_permission(ctx, permission)

  @doc """
  Require permission, raises `Sanctum.UnauthorizedError` if missing.

  Fails closed on guest-plane contexts, like `require_permission/2`.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.require_permission!(ctx, :execute)
      :ok

  """
  def require_permission!(%__MODULE__{plane: :guest}, permission) do
    raise Sanctum.UnauthorizedError, permission: permission
  end

  def require_permission!(ctx, permission) do
    unless has_permission?(ctx, permission) do
      raise Sanctum.UnauthorizedError, permission: permission
    end

    :ok
  end

  @doc """
  Enforce that a tenant-scoped operation has a resolved tenant.

  Delegates to `Sanctum.TenantPolicy.require_org/1` and raises
  `Sanctum.UnauthorizedError` when it reports no resolved org — so an org-less
  context can never reach a tenant-scoped store and silently land in the
  shared sentinel bucket. `:platform` scope is exempt; otherwise a non-empty
  resolved org_id is required.

  Returns the context unchanged on success (chainable).
  """
  @spec require_tenant!(t()) :: t()
  def require_tenant!(%__MODULE__{} = ctx) do
    case tenant_gate(ctx) do
      :ok -> ctx
      {:error, _} -> raise Sanctum.UnauthorizedError, action: :tenant_required
    end
  end

  @doc """
  Tuple form of the tenant presence-gate: `:ok | {:error, :missing_tenant}`.

  Use this at boundary entry points (plugs, controllers, API-key auth) that
  need to map an unresolved tenant to an HTTP response rather than raise.
  Same gate as `require_tenant!/1` — never let the two drift.
  """
  @spec tenant_ok(t()) :: :ok | {:error, :missing_tenant}
  def tenant_ok(%__MODULE__{} = ctx) do
    case tenant_gate(ctx) do
      :ok -> :ok
      {:error, _} -> {:error, :missing_tenant}
    end
  end

  # The single tenant presence-gate. `:platform` scope is exempt — system /
  # scheduled tasks legitimately cross tenant boundaries (retention, audit
  # fan-out, the registry CredentialStore that backs
  # `Sanctum.Namespace.lookup/1`), symmetric with `verify_tenant/2` and
  # `Arca.Storage.tenant_segments/1`. Otherwise requires a resolved org_id.
  defp tenant_gate(%__MODULE__{scope: :platform}), do: :ok
  defp tenant_gate(%__MODULE__{} = ctx), do: Sanctum.TenantPolicy.require_org(ctx)

  # ============================================================================
  # Unified Authorization API
  # ============================================================================

  @doc """
  Unified authorization check for action + resource combinations.

  Returns `:ok` if authorized, `{:error, reason}` if not.

  This is the **authoritative** tenant + permission check. A resource that
  carries a tenant identity must be passed as one of the recognized tuples so
  its tenant is verified here, via `Sanctum.TenantPolicy`:

  - `{:execution, record}` / `{:owned, record}` — permission + per-record
    `verify_tenant` + ownership (`ctx.user_id == record.user_id`, or an
    admin/`:*` wildcard).
  - `{:tenant, record}` — permission + per-record `verify_tenant` (no owner).
  - `nil` / a shape with no tenant identity — permission + tenant *presence*
    only. The storage primitive (`Arca.QueryHelpers.where_org_id/3`,
    `Arca.Storage.tenant_segments/1`) is a fail-closed **backstop** for these,
    not the primary control — so a tenant-bearing record must use a tuple
    above rather than rely on storage scoping.

  ## Authorization Modes

  - **Permission-only**: `authorize(ctx, :execute, nil)` — checks permission
  - **Ownership**: `authorize(ctx, :read, {:execution, record})` — checks ownership
  - **Admin override**: Admin contexts (wildcard permissions) bypass ownership checks

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.authorize(ctx, :execute, nil)
      :ok

      iex> ctx = Sanctum.Context.build(user_id: "u1", permissions: [:execute], authenticated: true)
      iex> record = %{user_id: "u1"}
      iex> Sanctum.Context.authorize(ctx, :read, {:execution, record})
      :ok

  """
  @spec authorize(t(), atom(), term()) :: :ok | {:error, String.t()}
  def authorize(%__MODULE__{} = ctx, action), do: authorize(ctx, action, nil)

  # Unauthenticated contexts are never authorized. This MUST precede the
  # generic clause so an unauthenticated context is never authorized.
  def authorize(%__MODULE__{authenticated: false}, _action, _resource) do
    {:error, "Unauthorized: authentication required"}
  end

  def authorize(%__MODULE__{} = ctx, action, resource) do
    do_authorize(ctx, action, resource)
  end

  # Permission-only check (no resource to verify ownership of). Also
  # enforce the tenant scope (via `Sanctum.TenantPolicy`) so an org-less
  # context is rejected centrally rather than relying on storage-layer scoping.
  defp do_authorize(%__MODULE__{} = ctx, action, nil) do
    permission = action_to_permission(action)

    with :ok <- require_permission(ctx, permission),
         :ok <- require_tenant_scope(ctx) do
      :ok
    else
      {:error, _} = err ->
        log_denial(ctx, action, nil)
        err
    end
  end

  # Tenant-bearing resources authorize identically: permission + per-record
  # (org,project) equality via verify_tenant. Members of a project are
  # interchangeable — there is NO owner gate; user_id stays on records for
  # attribution only. :execution/:owned still require a :user_id key so a tag
  # that promises an owner but carries none fails closed in the malformed
  # clause below (rather than passing on tenant presence alone).
  defp do_authorize(%__MODULE__{} = ctx, action, {tag, %{user_id: _} = record})
       when tag in [:execution, :owned] do
    verify_tenant_resource(ctx, action, record)
  end

  defp do_authorize(%__MODULE__{} = ctx, action, {:tenant, %{} = record}) do
    verify_tenant_resource(ctx, action, record)
  end

  # A tagged owner/tenant resource that did not structurally match the typed
  # clauses above — e.g. `{:execution|:owned, record}` with no `:user_id`, or a
  # `{:tenant, non_map}` — is caller misuse. Fail closed rather than fall
  # through to the permission + tenant-presence-only path below, which would
  # silently skip the ownership and per-record tenant checks the tag implies.
  defp do_authorize(%__MODULE__{} = ctx, action, {tag, _})
       when tag in [:execution, :owned, :tenant] do
    log_denial(ctx, action, {tag, :malformed_resource})
    {:error, "Unauthorized: malformed #{tag} resource (missing tenant/owner identity)"}
  end

  # Fallback: a resource shape that carries no tenant identity — `nil`, or an
  # untagged value (a plain map, struct, id, …). The contract is explicit:
  # `authorize/3` enforces permission + tenant *presence* here; a resource
  # that DOES carry a tenant must be passed as `{:execution|:owned|:tenant,
  # record}` so it is tenant-checked authoritatively above (a malformed such
  # tuple now fails closed in the clause directly above, not here). The storage
  # primitive (`Arca.QueryHelpers.where_org_id/3` / `Arca.Storage.tenant_segments/1`)
  # remains a fail-closed *backstop* — it scopes every query by org/project
  # and rejects an org-less tenant context — but it is no longer the control
  # for any caller that passes a tenant-bearing record.
  defp do_authorize(%__MODULE__{} = ctx, action, _resource) do
    do_authorize(ctx, action, nil)
  end

  # Shared body for tenant-bearing resources: permission + per-record
  # (org,project) equality. The single authorization path for
  # {:execution|:owned|:tenant}. verify_tenant (Sanctum.TenantPolicy) logs any
  # tenant mismatch, so this does not re-log.
  defp verify_tenant_resource(%__MODULE__{} = ctx, action, record) do
    with :ok <- require_permission(ctx, action_to_permission(action)),
         :ok <- verify_tenant(ctx, record) do
      :ok
    end
  end

  @doc """
  Like `authorize/3` but raises `Sanctum.UnauthorizedError` on failure.
  """
  @spec authorize!(t(), atom(), term()) :: :ok
  def authorize!(%__MODULE__{} = ctx, action), do: authorize!(ctx, action, nil)

  def authorize!(%__MODULE__{} = ctx, action, resource) do
    case authorize(ctx, action, resource) do
      :ok -> :ok
      {:error, _reason} -> raise Sanctum.UnauthorizedError, action: action
    end
  end

  # Tenant boundary check for resource access. Platform scope bypasses;
  # otherwise `Sanctum.TenantPolicy` rejects nil/"" org and, when both context
  # and record carry an org/project, requires equality.
  defp verify_tenant(%__MODULE__{} = ctx, record) do
    Sanctum.TenantPolicy.verify(ctx, record)
  end

  # Tenant-scope gate for the resource-less / fallback authorize paths.
  # Same chokepoint as `require_tenant!/1` (via `tenant_gate/1`); only the
  # failure shape differs — `authorize/3` returns `{:error, String.t()}`.
  defp require_tenant_scope(%__MODULE__{} = ctx) do
    case tenant_gate(ctx) do
      :ok -> :ok
      {:error, _} -> {:error, "Unauthorized: organization membership required"}
    end
  end

  # Map actions to the permission atoms they require.
  # Common actions map to existing permission names.
  defp action_to_permission(:execute), do: :execute
  defp action_to_permission(:run), do: :execute
  defp action_to_permission(:cancel), do: :execute
  defp action_to_permission(:read), do: :storage_read
  defp action_to_permission(:list), do: :storage_read
  defp action_to_permission(:write), do: :storage_write
  defp action_to_permission(:delete), do: :admin
  defp action_to_permission(:admin), do: :admin
  defp action_to_permission(action) when is_atom(action), do: action

  defp log_denial(%__MODULE__{} = ctx, action, resource) do
    Logger.warning(
      "[Sanctum.Context] Authorization denied: " <>
        "user=#{ctx.user_id} action=#{action} resource=#{inspect(resource)} " <>
        "auth_method=#{ctx.auth_method} scope=#{ctx.scope}"
    )
  end

  # Audit/telemetry for platform-scope construction (see build/1).
  defp maybe_audit_platform(%__MODULE__{scope: :platform} = ctx, sanctioned?) do
    caller = platform_caller()

    Sanctum.Telemetry.platform_context_event(%{
      user_id: ctx.user_id,
      auth_method: ctx.auth_method,
      namespace: ctx.namespace,
      sanctioned: sanctioned?,
      caller: caller
    })

    unless sanctioned? do
      Logger.warning(
        "[Sanctum.Context] platform-scope context built directly (not via " <>
          "Sanctum.Context.internal/1 / Sanctum.system_context/0): " <>
          "user=#{ctx.user_id} auth_method=#{ctx.auth_method} caller=#{caller}"
      )
    end

    :ok
  end

  defp maybe_audit_platform(_ctx, _sanctioned?), do: :ok

  # First stacktrace frame outside this module — cheap; the platform path is
  # low-frequency (system / cron / bootstrap), not per-request.
  defp platform_caller do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, frames} ->
        frames
        |> Enum.drop_while(fn {mod, _f, _a, _l} -> mod in [__MODULE__, Process, :erlang] end)
        |> List.first()
        |> format_frame()

      _ ->
        "unknown"
    end
  end

  defp format_frame({mod, fun, arity, loc}) do
    "#{inspect(mod)}.#{fun}/#{arity} (#{Keyword.get(loc, :file, "?")}:#{Keyword.get(loc, :line, 0)})"
  end

  defp format_frame(_), do: "unknown"
end
