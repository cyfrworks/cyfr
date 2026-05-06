defmodule Sanctum.Context do
  @moduledoc """
  Execution context that flows through all CYFR service calls.

  Context represents whoever is using the instance — a user, an API key,
  a webhook receiver, a scheduled job, or the system itself. It carries
  the persistent identity (user_id, email, provider, permissions, org_id,
  project_id) plus per-request decoration (request_id, correlation_id,
  session_id, api_key_id, scope, auth_method, authenticated).

  `from_jwt/1` constructs Context from JWT claims (Arx). Tests construct
  permissive single-user contexts via `Sanctum.TestContext.local/0`
  (compiled only in `:test` and `:dev`).

  ## Usage

  Every service function takes context as its first argument:

      Opus.execute(ctx, reference, input)
      Locus.build(ctx, source, target)
      Arca.get(ctx, path)

  This enables multi-tenant-ready code from day one. When adding tenancy later,
  you change *how* context is constructed—not every function that uses it.
  """

  require Logger

  @type scope :: :org | :project | :platform
  @type auth_method :: :local | :oidc | :api_key | :scheduled | :webhook | nil
  @type api_key_type :: :application | :service | :admin | nil

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
          authenticated: boolean()
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
    authenticated: false
  ]

  @doc """
  Construct context from JWT token.

  Verifies the JWT signature using the configured signing key and extracts
  user information from the claims.

  ## Required Configuration

  Set the signing key via environment variable or config:

      # Environment variable
      export CYFR_JWT_SIGNING_KEY="your-256-bit-secret"

      # Or in config/runtime.exs
      config :cyfr, :jwt_signing_key, "your-256-bit-secret"

  ## Expected Claims

  The JWT should contain:
  - `sub` - User ID (required)
  - `org` - Organization ID (optional)
  - `permissions` - List of permission strings (optional)
  - `scope` - "org", "project", or "platform" (optional, defaults to "project")

  ## Examples

      # Generate a valid JWT
      key = Application.get_env(:cyfr, :jwt_signing_key)
      claims = %{"sub" => "user_123", "permissions" => ["execute", "read"]}
      {_, jwt} = JOSE.JWT.sign(JOSE.JWK.from_oct(key), claims) |> JOSE.JWS.compact()

      # Parse and verify
      {:ok, ctx} = Sanctum.Context.from_jwt(jwt)
      ctx.user_id
      #=> "user_123"

  """
  @spec from_jwt(String.t()) :: {:ok, t()} | {:error, term()}
  def from_jwt(token) when is_binary(token) do
    with {:ok, jwk} <- get_signing_key(),
         {:ok, claims} <- verify_and_decode(token, jwk) do
      build_context_from_claims(claims)
    end
  end

  def from_jwt(_), do: {:error, :invalid_token}

  @doc """
  Context for scheduled (cron) executions.

  Grants execute and storage permissions scoped to the originating user.
  """
  def for_scheduled(user_id, opts \\ []) do
    namespace =
      case Keyword.get(opts, :namespace) do
        ns when is_binary(ns) and ns != "" -> ns
        _ -> resolve_scheduled_namespace(user_id)
      end

    build(
      user_id: user_id,
      namespace: namespace,
      org_id: Keyword.get(opts, :org_id),
      project_id: Keyword.get(opts, :project_id, "default"),
      permissions: [:execute, :storage_read, :execution_write, :storage_write],
      scope: :project,
      auth_method: :scheduled,
      correlation_id: Keyword.get(opts, :correlation_id),
      authenticated: true
    )
  end

  # System / cron sentinels write to a "_system"-rooted path so audit and
  # retention tasks emitted under `user_id: "system"` don't fail tenant_segments
  # validation. Real users get their namespace looked up from CredentialStore.
  defp resolve_scheduled_namespace("system"), do: "_system"
  defp resolve_scheduled_namespace("cron:" <> _), do: "_system"
  defp resolve_scheduled_namespace(user_id), do: Sanctum.Namespace.lookup(user_id) || "_system"

  @doc """
  Centralized context constructor for all entry points.

  Builds a properly structured context from a keyword list or map of attributes.
  All entry points (auth providers, API keys, LiveView hooks) should use this
  to ensure consistent field population.

  ## Options

  - `:user_id` - User ID (required for authenticated contexts)
  - `:org_id` - Organization ID
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

  def build(attrs) when is_map(attrs) do
    scope = Map.get(attrs, :scope, :project)

    unless scope in @valid_scopes do
      raise ArgumentError,
            "invalid scope #{inspect(scope)}, must be one of #{inspect(@valid_scopes)}"
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

    # Authenticated, non-platform contexts must carry a real namespace.
    # The transient post-OAuth state (session created, namespace not yet
    # claimed) sets authenticated: false; system tasks use scope: :platform
    # with namespace "_system". Anything else with nil namespace is a bug
    # we want to catch at the construction site, not deep inside Arca.
    namespace = Map.get(attrs, :namespace)
    authenticated = Map.get(attrs, :authenticated, false)

    if authenticated and scope != :platform and (is_nil(namespace) or namespace == "") do
      raise ArgumentError,
            "Sanctum.Context.build/1: authenticated non-platform contexts require :namespace " <>
              "(user_id=#{inspect(Map.get(attrs, :user_id))} scope=#{inspect(scope)} " <>
              "auth_method=#{inspect(Map.get(attrs, :auth_method))}). " <>
              "Pre-claim transient contexts must use authenticated: false; " <>
              "system tasks must use scope: :platform."
    end

    permissions =
      case Map.get(attrs, :permissions, MapSet.new()) do
        %MapSet{} = ms -> ms
        list when is_list(list) -> MapSet.new(list)
        _ -> MapSet.new()
      end

    # Default project_id to "default" for non-platform contexts. This
    # guarantee lets the rest of the codebase rely on ctx.project_id
    # being non-nil whenever scope is not :platform.
    project_id =
      case Map.get(attrs, :project_id) do
        nil when scope != :platform -> "default"
        other -> other
      end

    %__MODULE__{
      user_id: Map.get(attrs, :user_id),
      email: Map.get(attrs, :email),
      provider: Map.get(attrs, :provider),
      namespace: Map.get(attrs, :namespace),
      org_id: Map.get(attrs, :org_id),
      project_id: project_id,
      permissions: permissions,
      scope: scope,
      auth_method: Map.get(attrs, :auth_method),
      api_key_type: Map.get(attrs, :api_key_type),
      request_id: Map.get(attrs, :request_id),
      correlation_id: Map.get(attrs, :correlation_id),
      session_id: Map.get(attrs, :session_id),
      api_key_id: Map.get(attrs, :api_key_id),
      authenticated: Map.get(attrs, :authenticated, false)
    }
  end

  # ============================================================================
  # Identity helpers
  # ============================================================================

  @doc """
  Build the canonical user id `"<provider>|<iss>|<subject>"`.

  Used by every Context construction site (OIDC claims, SimpleOAuth,
  DeviceFlow, Ueberauth callback) so the id shape stays consistent.
  """
  @spec build_id(String.t() | atom(), String.t(), String.t()) :: String.t()
  def build_id(provider, iss, sub) when is_atom(provider),
    do: build_id(Atom.to_string(provider), iss, sub)

  def build_id(provider, iss, sub)
      when is_binary(provider) and is_binary(iss) and is_binary(sub) do
    "#{provider}|#{iss}|#{sub}"
  end

  @doc """
  Hardcoded canonical `iss` (RFC 7519 issuer) for a provider atom.

  GitHub and Google have stable, well-known issuer URLs; SimpleOAuth and
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

  @doc """
  Construct a Context from OIDC claims (without permissions/membership —
  callers fill those in via subsequent resolver calls).

  The `id` is `"<provider>|<iss>|<subject>"` — pipe-delimited, scheme-prefixed
  issuer. Identical on Core and Arx so the same human via the same IdP
  resolves to the same id on both editions.

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
    cond do
      String.contains?(iss, "github.com") -> "github"
      String.contains?(iss, "accounts.google.com") -> "google"
      true -> "oidc"
    end
  end

  defp derive_provider(_), do: "oidc"

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

    if Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, slug), do: slug, else: nil
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

  # ============================================================================
  # JWT Private Functions
  # ============================================================================

  defp get_signing_key do
    case Application.get_env(:cyfr, :jwt_signing_key) do
      nil ->
        {:error, :no_signing_key_configured}

      key when is_binary(key) and byte_size(key) >= 32 ->
        {:ok, JOSE.JWK.from_oct(key)}

      key when is_binary(key) ->
        # Reject short keys in all environments - padding is a security risk
        Logger.warning(
          "JWT signing key is too short (#{byte_size(key)} bytes). " <>
            "Use at least 32 bytes for security."
        )

        {:error, {:jwt_key_too_short, byte_size(key)}}
    end
  end

  defp verify_and_decode(token, jwk) do
    case JOSE.JWT.verify_strict(jwk, ["HS256", "HS384", "HS512"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        {:ok, claims}

      {false, _, _} ->
        {:error, :invalid_signature}
    end
  rescue
    e in [ArgumentError, MatchError, FunctionClauseError, CaseClauseError, ErlangError] ->
      Logger.warning("[Context] JWT verification error: #{inspect(e)}")
      {:error, :invalid_token_format}
  end

  defp build_context_from_claims(claims) do
    # Validate required claims
    case claims do
      %{"sub" => user_id} when is_binary(user_id) and user_id != "" ->
        # Validate expiration if present
        with :ok <- validate_expiration(claims),
             :ok <- validate_session_not_revoked(claims),
             :ok <- validate_audience(claims),
             :ok <- validate_issuer(claims) do
          permissions =
            claims
            |> Map.get("permissions", [])
            |> Enum.map(&safe_to_atom/1)
            |> MapSet.new()

          scope =
            case Map.get(claims, "scope") do
              "org" -> {:ok, :org}
              "project" -> {:ok, :project}
              "platform" -> {:ok, :platform}
              nil -> {:ok, :project}
              unknown -> {:error, {:invalid_scope, unknown}}
            end

          case scope do
            {:ok, scope_atom} ->
              {:ok,
               build(%{
                 user_id: user_id,
                 email: Map.get(claims, "email"),
                 namespace: Map.get(claims, "namespace"),
                 org_id: Map.get(claims, "org"),
                 project_id: Map.get(claims, "project_id"),
                 permissions: permissions,
                 scope: scope_atom,
                 auth_method: :oidc,
                 correlation_id: Map.get(claims, "correlation_id"),
                 session_id: Map.get(claims, "session_id"),
                 authenticated: true
               })}

            {:error, _} = error ->
              error
          end
        end

      _ ->
        {:error, :missing_sub_claim}
    end
  end

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)
    clock_skew = get_clock_skew_seconds()

    if exp + clock_skew >= now do
      :ok
    else
      {:error, :token_expired}
    end
  end

  # No exp claim - token doesn't expire (or we don't enforce expiration)
  defp validate_expiration(_claims), do: :ok

  # Maximum allowed clock skew to prevent security issues with overly permissive JWT validation
  @max_clock_skew_seconds 300

  defp get_clock_skew_seconds do
    configured = Application.get_env(:cyfr, :jwt_clock_skew_seconds, 60)
    min(configured, @max_clock_skew_seconds)
  end

  defp validate_session_not_revoked(%{"session_id" => session_id}) when is_binary(session_id) do
    if Sanctum.Session.revoked?(session_id) do
      {:error, :session_revoked}
    else
      :ok
    end
  end

  # No session_id claim - skip revocation check
  defp validate_session_not_revoked(_claims), do: :ok

  # Validate JWT audience claim when configured.
  # Prevents tokens intended for other services from being accepted.
  defp validate_audience(%{"aud" => aud}) do
    case Application.get_env(:cyfr, :jwt_audience) do
      nil ->
        :ok

      expected when is_binary(expected) ->
        cond do
          aud == expected -> :ok
          is_list(aud) and expected in aud -> :ok
          true -> {:error, {:invalid_audience, aud}}
        end
    end
  end

  defp validate_audience(_claims), do: :ok

  # Validate JWT issuer claim when configured.
  # Prevents tokens from untrusted issuers from being accepted.
  defp validate_issuer(%{"iss" => iss}) do
    case Application.get_env(:cyfr, :jwt_issuer) do
      nil ->
        :ok

      expected when is_binary(expected) ->
        if iss == expected, do: :ok, else: {:error, {:invalid_issuer, iss}}
    end
  end

  defp validate_issuer(_claims), do: :ok

  defp safe_to_atom(value), do: Sanctum.Atoms.safe_to_permission_atom(value)

  @doc """
  Check if context has a specific permission.

  The wildcard permission `:*` grants all permissions.

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
  Require permission, returning `{:error, message}` if missing.

  Used by MCP tool handlers in `with` chains.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.require_permission(ctx, :execute)
      :ok

  """
  @spec require_permission(t(), atom()) :: :ok | {:error, String.t()}
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
  Require permission, raises `Sanctum.UnauthorizedError` if missing.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.require_permission!(ctx, :execute)
      :ok

  """
  def require_permission!(ctx, permission) do
    unless has_permission?(ctx, permission) do
      raise Sanctum.UnauthorizedError, permission: permission
    end

    :ok
  end

  # ============================================================================
  # Unified Authorization API
  # ============================================================================

  @doc """
  Unified authorization check for action + resource combinations.

  Returns `:ok` if authorized, `{:error, reason}` if not.

  ## Authorization Modes

  - **Permission-only**: `authorize(ctx, :execute, nil)` — checks permission
  - **Ownership**: `authorize(ctx, :read, {:execution, record})` — checks ownership
  - **Admin override**: Admin contexts (wildcard permissions) bypass ownership checks

  ## Core Mode Short-Circuit

  In Core mode (`:local` auth_method with wildcard permissions), authorization
  is always granted immediately to preserve zero-overhead single-user behavior.

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

  # Core mode short-circuit: local + wildcard = always authorized
  def authorize(%__MODULE__{auth_method: :local, permissions: perms}, _action, _resource) do
    if MapSet.member?(perms, :*) do
      :ok
    else
      {:error, "Unauthorized: local context missing wildcard permissions"}
    end
  end

  # Unauthenticated contexts are never authorized
  def authorize(%__MODULE__{authenticated: false}, _action, _resource) do
    {:error, "Unauthorized: authentication required"}
  end

  # Permission-only check (no resource to verify ownership of)
  def authorize(%__MODULE__{} = ctx, action, nil) do
    permission = action_to_permission(action)

    if has_permission?(ctx, permission) do
      :ok
    else
      log_denial(ctx, action, nil)
      {:error, "Unauthorized: missing required permission '#{permission}'"}
    end
  end

  # Ownership check for execution records (with tenant verification)
  def authorize(%__MODULE__{} = ctx, action, {:execution, %{user_id: owner_id} = record}) do
    permission = action_to_permission(action)

    with :ok <- require_permission(ctx, permission),
         :ok <- verify_tenant(ctx, record) do
      if ctx.user_id == owner_id or has_permission?(ctx, :admin) or has_permission?(ctx, :*) do
        :ok
      else
        log_denial(ctx, action, {:execution, owner_id})
        {:error, "Unauthorized: not the owner of this execution"}
      end
    end
  end

  # Ownership check for generic resources with user_id
  def authorize(%__MODULE__{} = ctx, action, {:owned, %{user_id: owner_id}}) do
    permission = action_to_permission(action)

    with :ok <- require_permission(ctx, permission) do
      if ctx.user_id == owner_id or has_permission?(ctx, :admin) or has_permission?(ctx, :*) do
        :ok
      else
        log_denial(ctx, action, {:owned, owner_id})
        {:error, "Unauthorized: not the owner of this resource"}
      end
    end
  end

  # Fallback: permission check only
  def authorize(%__MODULE__{} = ctx, action, _resource) do
    authorize(ctx, action, nil)
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

  # Tenant boundary check for resource access.
  # Platform scope bypasses. Core mode (nil org_id) matches "" sentinel.
  # Delegates to the configured tenant policy. Core uses Sanctum.PermissiveTenantPolicy
  # (allows nil org_id, requires equality otherwise); Arx swaps in Arx.Sanctum.TenantPolicy
  # (rejects nil org_id, then delegates equality check back to Permissive).
  defp verify_tenant(%__MODULE__{} = ctx, record) do
    Application.fetch_env!(:cyfr, :tenant_policy).verify(ctx, record)
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
end
