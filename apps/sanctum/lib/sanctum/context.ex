# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Context do
  @moduledoc """
  Execution context that flows through all CYFR service calls.

  Context represents whoever is using the server — a user, an API key,
  a webhook receiver, a scheduled job, or the system itself. It carries
  the persistent identity (user_id, email, provider, permissions,
  athanor_id) plus per-request decoration (request_id, api_key_id, scope,
  auth_method, authenticated).

  `request_id` is the ingress request and the only correlation key. It
  survives into a WASM closure unchanged, so every call a running component
  makes is attributable to the request that started it — which is what lets
  `Arca.McpLog` show a chain as one group.

  Tests construct permissive single-user contexts via
  `Sanctum.TestContext.local/0`, which lives in test support and so is
  compiled only in `:test`.

  ## Usage

  Every service function takes the context as its first argument, and the
  persistence layer takes the actor it projects (`actor/1`):

      Sanctum.Context.authorize(ctx, :storage_read, path)
      Arca.get(Sanctum.Context.actor(ctx), path)

  Context carries the tenant coordinate `athanor_id` and its `scope`. Every
  request context is `:athanor` — it works inside one athanor, the one its
  session or `focus/2` named. `:platform` is the server itself: the internal
  contexts `internal/1` builds for sweepers, retention, health probes and
  seeding, which cross athanors by nature. A platform admin (the operator)
  is a person like any other, focused on one athanor at a time; the
  capability rides on the context as `platform_admin: true`, is re-derived
  from the membership row whenever the context is established (behind
  `Sanctum.Caller`'s short memo, which revocation invalidates), and is what
  the `door.*` verbs and the audited "open another athanor" check — never a
  widened scope.
  Only *how* a context is constructed varies by deployment configuration —
  never the functions that consume it.
  """

  require Logger

  # The vocabulary is `Cyfr.TenancyScope`'s, where the actor and the
  # stored membership row read it too.
  @type scope :: Cyfr.TenancyScope.t()
  @type auth_method ::
          :oidc | :api_key | :scheduled | :webhook | :tincture | :system | :session | nil
  @type api_key_type :: :application | :service | :admin | nil
  @type plane :: :external | :guest

  @typedoc """
  What a credential this context holds was issued against, read when the
  context was established: which credential (`source_kind`, `source_id`),
  which membership authorized its focus (`focus_basis`: the membership
  row id, `:key` for an athanor's key, or nil where no row does), and the
  person's and the focused estate's standing generations. A freshly
  admitted sign-in, which holds no credential yet, carries
  `source_kind: :identity` and `source_id: nil`.

  Issuing a credential from this context locks those rows and refuses
  unless they still stand at these generations
  (`Arca.SecurityTransitions.Issuance`), so a context read before a
  retirement cannot issue after the restore.
  """
  @type credential_binding :: %{
          source_kind: :identity | :session | :api_key,
          source_id: String.t() | nil,
          focus_basis: String.t() | :key | nil,
          user_generation: pos_integer(),
          athanor_generation: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          email: String.t() | nil,
          provider: String.t() | nil,
          namespace: String.t() | nil,
          athanor_id: String.t() | nil,
          permissions: MapSet.t(atom()),
          scope: scope(),
          auth_method: auth_method(),
          api_key_type: api_key_type(),
          request_id: String.t() | nil,
          api_key_id: String.t() | nil,
          session_token_hash: binary() | nil,
          credential_binding: credential_binding() | nil,
          credential_deadline: DateTime.t() | nil,
          validated_at: DateTime.t() | nil,
          authenticated: boolean(),
          anonymous: boolean(),
          platform_admin: boolean(),
          plane: plane()
        }

  defstruct [
    :user_id,
    :email,
    :provider,
    :namespace,
    :athanor_id,
    :permissions,
    :scope,
    :auth_method,
    :api_key_type,
    :request_id,
    :api_key_id,
    # The session row's key, when a Sanctum session token authenticated the
    # request. It is the SHA-256 of the token, so it addresses the row
    # without being usable to authenticate as it — the same class of
    # identifier as :api_key_id, and what `session.logout` needs to retire
    # exactly the session that called it.
    :session_token_hash,
    # What this context's credential was issued against and the
    # generations it read (`t:credential_binding/0`). Stamped together
    # with `:session_token_hash` or `:api_key_id` by the one assembly path
    # of each credential (`Sanctum.Session`, `Sanctum.ApiKey`), and by
    # `Sanctum.Tenancy.resolve_status/2` for an admitted sign-in.
    :credential_binding,
    # The absolute instant this context's authority ends when a parent
    # credential bounds it, or nil when only its own source does.
    :credential_deadline,
    # When this context's credential and standing were last read from the
    # store (`Sanctum.Caller.establish/2`, `revalidate_session/1`), or nil
    # for a context no one validated. A holder that keeps a context past
    # the freshness bound (`Sanctum.Caller.fresh?/1`) revalidates before
    # acting on it; reusing a context never moves this instant.
    :validated_at,
    # The caller's resolved address, where the ingress knew one
    # (`Sanctum.ClientIp`). It is not identity and authorizes nothing — it
    # is what an anonymous, per-action budget can be charged to. Without
    # it the `/mcp` device flows had no address of their own and rode the
    # transport's shared 120/min bucket, so several addresses could still
    # exhaust the global sign-in ceiling between them.
    :client_ip,
    authenticated: false,
    # True when the ORIGINATING caller presented no credentials (public
    # tincture invocation). Ingress adapters may still mint an authenticated
    # execution context for such a caller, but the credential plane
    # (Sanctum.VaultReader) denies anonymous contexts — an anonymous internet
    # caller must never reach operator credentials.
    anonymous: false,
    # The server's operator: a platform-scope membership row grants it. It is
    # a capability, not a scope — the context still works inside one athanor.
    platform_admin: false,
    # Which authorization plane this context is on. :external is every real
    # ingress; :guest is stamped one-way by enter_guest/1 when a context
    # enters a WASM closure (an execution's attempt for its guest's calls, the thread
    # runner before an approved in-chain call), and require_permission/2 fails closed on it — a
    # context that has entered a guest closure can never authorize an
    # external-plane call.
    plane: :external
  ]

  @doc """
  Context for scheduled (cron) executions.

  Grants execute and storage permissions inside the schedule's athanor,
  attributed to the originating user. `:athanor_id` is required.
  """
  def for_scheduled(user_id, opts \\ []) do
    # Delegates to the single builder; cron's only divergence from the
    # `:system` default is the `:scheduled` provenance tag. namespace is pure
    # identity (not path-bearing), so an absent one is fine — the schedule's
    # athanor determines where its files land.
    #
    # Permissions are stated explicitly rather than inherited from
    # internal/1's defaults, so what a schedule runs with is visible here
    # and can't silently widen if the internal default ever changes.
    internal(
      user_id: user_id,
      namespace: Keyword.get(opts, :namespace),
      athanor_id: Keyword.fetch!(opts, :athanor_id),
      scope: :athanor,
      auth_method: :scheduled,
      permissions: [:execute, :storage_read, :storage_write]
    )
  end

  @doc """
  Centralized context constructor for all entry points.

  Builds a properly structured context from a keyword list or map of attributes.
  All entry points (auth providers, API keys, LiveView hooks) should use this
  to ensure consistent field population.

  ## Options

  - `:user_id` - User ID (required for authenticated contexts)
  - `:athanor_id` - The athanor the context works in. Taken as given, never
    coerced: `""` is rejected; `nil` is the transient state before the
    caller's athanor is resolved (or a platform context working in none) and
    is refused downstream by the tenant gate
  - `:permissions` - List or MapSet of permission atoms
  - `:scope` - Scope atom (`:athanor` default; `:platform` only through `internal/1`)
  - `:platform_admin` - Boolean (default: false); the operator capability
  - `:auth_method` - Authentication method atom
  - `:api_key_type` - API key type atom
  - `:api_key_id` - API key identifier
  - `:session_token_hash` - session row key (SHA-256 of the session token)
  - `:request_id` - MCP request ID
  - `:authenticated` - Boolean (default: false)

  ## Examples

      iex> Sanctum.Context.build(user_id: "user_1", permissions: [:execute], auth_method: :oidc, authenticated: true)
      %Sanctum.Context{user_id: "user_1", permissions: MapSet.new([:execute]), auth_method: :oidc, authenticated: true}
  """
  @spec build(keyword() | map()) :: t()
  def build(attrs) when is_list(attrs) do
    attrs |> Map.new() |> build()
  end

  @valid_scopes Sanctum.Atoms.scope_atoms()

  # Validate auth_method against its declared vocabulary at context construction.
  @valid_auth_methods [:oidc, :api_key, :scheduled, :webhook, :tincture, :system, :session, nil]

  # Mirrors the `plane()` type, guarded for the same reason.
  @valid_planes [:external, :guest]

  def build(attrs) when is_map(attrs) do
    scope = Map.get(attrs, :scope, :athanor)

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
          :athanor_id,
          :request_id,
          :api_key_id,
          :client_ip
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

    # The athanor is taken as given. There is no sentinel to coerce into:
    # `""` is an invalid value, not a tenant, and is rejected here; `nil` is
    # the transient state before the caller's athanor is resolved (auth paths
    # start there and `Sanctum.Tenancy.resolve_status/2` fills it) or a
    # platform context working in no athanor — the tenant gate refuses it
    # wherever an athanor is required.
    athanor_id =
      case Map.get(attrs, :athanor_id) do
        "" ->
          raise ArgumentError,
                "Sanctum.Context.build/1: athanor_id must be a resolved id or nil, got \"\""

        other ->
          other
      end

    ctx = %__MODULE__{
      user_id: Map.get(attrs, :user_id),
      email: Map.get(attrs, :email),
      provider: Map.get(attrs, :provider),
      namespace: Map.get(attrs, :namespace),
      athanor_id: athanor_id,
      permissions: permissions,
      scope: scope,
      auth_method: Map.get(attrs, :auth_method),
      api_key_type: Map.get(attrs, :api_key_type),
      request_id: Map.get(attrs, :request_id),
      api_key_id: Map.get(attrs, :api_key_id),
      session_token_hash: Map.get(attrs, :session_token_hash),
      credential_binding: binding!(Map.get(attrs, :credential_binding)),
      credential_deadline: deadline!(Map.get(attrs, :credential_deadline)),
      validated_at: validated_at!(Map.get(attrs, :validated_at)),
      client_ip: Map.get(attrs, :client_ip),
      authenticated: Map.get(attrs, :authenticated, false),
      anonymous: Map.get(attrs, :anonymous, false) == true,
      platform_admin: Map.get(attrs, :platform_admin, false) == true,
      plane: plane
    }

    # Gate every platform-scope construction. `:platform` bypasses ALL tenant
    # checks, so it has exactly one construction path: `internal/1` (and its
    # `system_context/0` facade), which sets the private `__platform_ok__`
    # marker. A direct `Context.build(scope: :platform, ...)` is refused —
    # a log line is not a gate. Telemetry still records every construction.
    # Test fixtures use `Sanctum.TestContext.platform/1`.
    audit_platform!(ctx, Map.get(attrs, :__platform_ok__, false) == true)
    ctx
  end

  @binding_sources [:identity, :session, :api_key]

  # A binding is data the issuance check trusts, so a malformed one is a
  # construction bug caught here rather than a refusal found later.
  defp binding!(nil), do: nil

  defp binding!(
         %{
           source_kind: kind,
           source_id: source_id,
           focus_basis: basis,
           user_generation: user_generation,
           athanor_generation: athanor_generation
         } = binding
       )
       when kind in @binding_sources and (is_binary(source_id) or is_nil(source_id)) and
              (is_binary(basis) or basis in [:key, nil]) and is_integer(user_generation) and
              user_generation > 0 and
              (is_nil(athanor_generation) or
                 (is_integer(athanor_generation) and athanor_generation > 0)),
       do: binding

  defp binding!(other),
    do: raise(ArgumentError, "credential_binding is malformed: #{inspect(other)}")

  defp deadline!(nil), do: nil
  defp deadline!(%DateTime{} = deadline), do: deadline

  defp deadline!(other),
    do:
      raise(
        ArgumentError,
        "credential_deadline must be a DateTime or nil, got: #{inspect(other)}"
      )

  defp validated_at!(nil), do: nil
  defp validated_at!(%DateTime{} = at), do: at

  defp validated_at!(other),
    do: raise(ArgumentError, "validated_at must be a DateTime or nil, got: #{inspect(other)}")

  @doc """
  The single builder for server-constructed, no-external-credential contexts.

  Every non-interactive context — secret-store bootstrap, execution-record
  write-back, filesystem scans, sweepers, health checks, retention, audit
  fan-out, and cron (via `for_scheduled/2`) — flows through here so there is
  exactly one construction path. `auth_method` records provenance only (audit/
  telemetry); it does not grant access.

  Options (all optional):

    * `:user_id`        — default `"system"`
    * `:namespace`      — default `nil`
    * `:athanor_id`     — default `nil`; a task that touches one athanor's
      rows or files passes it, together with `scope: :athanor`
    * `:permissions`    — default `[:execute, :storage_read, :storage_write]`
    * `:scope`          — default `:platform`
    * `:auth_method`    — default `:system`; cron passes `:scheduled`

  `authenticated:` is always `true`.

  ## Examples

      iex> ctx = Sanctum.Context.internal()
      iex> {ctx.auth_method, ctx.scope, ctx.user_id, ctx.athanor_id}
      {:system, :platform, "system", nil}
  """
  @spec internal(keyword()) :: t()
  def internal(opts \\ []) do
    build(
      user_id: Keyword.get(opts, :user_id, "system"),
      namespace: Keyword.get(opts, :namespace),
      athanor_id: Keyword.get(opts, :athanor_id),
      permissions:
        Keyword.get(opts, :permissions, [
          :execute,
          :storage_read,
          :storage_write
        ]),
      scope: Keyword.get(opts, :scope, :platform),
      auth_method: Keyword.get(opts, :auth_method, :system),
      authenticated: true,
      # Marks this as the single sanctioned platform-construction path so the
      # audit in build/1 records it as sanctioned (no warning).
      __platform_ok__: true
    )
  end

  @doc """
  Check if context has a specific permission.

  The wildcard permission `:*` grants all permissions; no sign-in path
  mints it — a person holds the explicit `person_permissions/0`.

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

  @doc "The permissions a signed-in person holds; see `Sanctum.Atoms.person_permissions/0`."
  @spec person_permissions() :: [atom()]
  defdelegate person_permissions(), to: Sanctum.Atoms

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
  The actor this context projects: a `Cyfr.Actor` with `athanor_id`,
  `plane`, `anonymous`, `user_id`, `request_id`, `authenticated` and
  `client_ip` copied one field each, with the meanings they carry here. The
  context stays the owner of those fields and stores no duplicate `:actor`;
  the actor is the projection every Arca facade and bus topic takes, and
  this is the only construction path for that use — a facade accepts no
  actor assembled by hand.

  Two of the actor's fields are read off this context rather than copied
  from a field of the same name, because they are what the layers below
  authorize on. `scope` travels as it stands — a `:platform` context reads
  rows across every athanor, an `:athanor` one reads its own. `system` is
  `auth_method == :system`, the provenance that lets the server's own work
  mutate seed, global and tenant-reserved paths; every other
  `auth_method` records where a caller came from and grants nothing, so it
  projects `system: false`. Neither crosses the wire (`Cyfr.Actor`).

  A context whose athanor is unresolved projects `athanor_id: nil`, never a
  sentinel: the facade refuses it before any query, and it stays
  distinguishable from `anonymous: true`, which is a caller that has a
  tenant and no credentials of its own.
  """
  @spec actor(t()) :: Cyfr.Actor.t()
  def actor(%__MODULE__{} = ctx) do
    %Cyfr.Actor{
      athanor_id: ctx.athanor_id,
      plane: ctx.plane,
      anonymous: ctx.anonymous,
      user_id: ctx.user_id,
      request_id: ctx.request_id,
      authenticated: ctx.authenticated,
      client_ip: ctx.client_ip,
      scope: ctx.scope,
      system: ctx.auth_method == :system
    }
  end

  @doc """
  The one permission gate, which takes the plane the CALL is on.

  Used by MCP tool handlers in `with` chains.

  An `:external` call (the default) never authorizes from inside a WASM
  closure — a guest-planed context is refused regardless of permissions,
  even a `:*` wildcard. An `:in_chain` call is authorized by the chain's
  authority **and** the caller's identity: the authority conjunct is
  applied at the dispatch chokepoint before any provider runs, so here
  only the identity conjunct is checked, for a guest-planed context and an
  external one alike.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.require_permission(ctx, :execute)
      :ok
  """
  @spec require_permission(t(), atom(), :external | :in_chain) ::
          :ok | {:error, Sanctum.Unauthorized.reason()}
  def require_permission(ctx, permission, plane \\ :external)

  def require_permission(%__MODULE__{plane: :guest}, permission, :external) do
    {:error, {:guest_plane, permission}}
  end

  def require_permission(%__MODULE__{} = ctx, permission, plane)
      when plane in [:external, :in_chain] do
    if has_permission?(ctx, permission) do
      :ok
    else
      {:error, {:missing_permission, permission}}
    end
  end

  @doc """
  Enforce that a tenant-scoped operation has a resolved tenant.

  Delegates to `Sanctum.TenantPolicy.require_athanor/1` and raises
  `Sanctum.UnauthorizedError` when it reports no resolved athanor — so an
  athanor-less context can never reach a tenant-scoped store. `:platform`
  scope is exempt; otherwise a non-empty resolved athanor_id is required.

  Returns the context unchanged on success (chainable).
  """
  @spec require_tenant!(t()) :: t()
  def require_tenant!(%__MODULE__{} = ctx) do
    case tenant_gate(ctx) do
      :ok -> ctx
      {:error, _} -> raise Sanctum.UnauthorizedError, reason: :missing_tenant
    end
  end

  @doc """
  The athanor this context works in.

  Raises `Sanctum.UnauthorizedError` when unresolved — platform scope
  included. `require_tenant!/1` exempts platform contexts because a system
  task may legitimately cross athanors; a tenant-bearing *store* never runs
  without one, so its verbs read the athanor through here.
  """
  @spec athanor!(t()) :: String.t()
  def athanor!(%__MODULE__{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: athanor_id

  def athanor!(%__MODULE__{}), do: raise(Sanctum.UnauthorizedError, reason: :missing_tenant)

  @doc """
  Focus the context on an athanor: the one narrowing entry every LiveView
  mount, `session.use` and the operator's "open another athanor" run through.

  A member of the athanor may focus it. A platform admin may focus any
  athanor — an audited act (`Sanctum.Telemetry.platform_context_event/1`),
  never a widened scope: the result works inside that athanor exactly as a
  member's context does. An archived athanor cannot be focused by anyone.
  """
  @spec focus(t(), Arca.Schemas.Athanor.t() | String.t()) ::
          {:ok, t()} | {:error, :not_found | :archived | :not_member}
  def focus(%__MODULE__{} = ctx, athanor_id) when is_binary(athanor_id) do
    case Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, athanor} -> focus(ctx, athanor)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  def focus(%__MODULE__{}, %Arca.Schemas.Athanor{status: "archived"}), do: {:error, :archived}

  def focus(%__MODULE__{} = ctx, %Arca.Schemas.Athanor{id: id} = athanor) do
    case Sanctum.Tenancy.Members.active_seat(ctx.user_id, id) do
      {:ok, seat} ->
        {:ok, refocused(ctx, athanor, seat.id)}

      :none when ctx.platform_admin ->
        Sanctum.Telemetry.platform_context_event(%{
          caller: :focus,
          user_id: ctx.user_id,
          athanor_id: id,
          auth_method: ctx.auth_method
        })

        {:ok, refocused(ctx, athanor, platform_basis(ctx))}

      _none_or_unreadable ->
        {:error, :not_member}
    end
  end

  # A new focus is a new standing read: the binding follows it, naming the
  # estate's generation as read now and the membership that authorized
  # it. An athanor's key keeps `:key` — its standing is the key's, not a
  # seat's.
  defp refocused(%__MODULE__{credential_binding: nil} = ctx, %{id: id}, _basis),
    do: %{ctx | athanor_id: id, scope: :athanor}

  defp refocused(%__MODULE__{credential_binding: binding} = ctx, athanor, basis) do
    basis = if binding.focus_basis == :key, do: :key, else: basis
    ctx = %{ctx | athanor_id: athanor.id, scope: :athanor}

    %{
      ctx
      | credential_binding: %{
          binding
          | focus_basis: basis,
            athanor_generation: athanor.security_generation
        }
    }
  end

  defp platform_basis(%__MODULE__{credential_binding: nil}), do: nil

  defp platform_basis(%__MODULE__{user_id: user_id}) do
    case Sanctum.Tenancy.Members.platform_seat(user_id) do
      {:ok, seat} -> seat.id
      _none -> nil
    end
  end

  @doc """
  Focuses the caller on another athanor for domain reads or writes after
  checking membership and archive status. Archived-athanor management uses
  `Sanctum.MCP.AthanorTool.resolve/3`, which permits get and unarchive.

  A user context goes through `focus/2` whole: membership or the audited
  operator open, and an archived athanor refused. A **system** context
  (`auth_method: :system`) crosses tenants by design — recovery resolving
  a stored agent from its owner's tree has no member to speak as — but an
  archived athanor is still refused; the platform plane gets no door into
  a closed furnace either.
  """
  @spec refocus(t(), String.t()) ::
          {:ok, t()} | {:error, :not_found | :archived | :not_member}
  def refocus(%__MODULE__{auth_method: :system} = ctx, athanor_id)
      when is_binary(athanor_id) do
    case Sanctum.Tenancy.Athanors.get(athanor_id) do
      {:ok, %{status: "archived"}} -> {:error, :archived}
      {:ok, _} -> {:ok, %{ctx | athanor_id: athanor_id, scope: :athanor}}
      {:error, _} -> {:error, :not_found}
    end
  end

  # No athanor is nothing to open — the spec's `:not_found`, not a clause
  # error from a caller that read an id off a record that had none.
  def refocus(%__MODULE__{}, nil), do: {:error, :not_found}

  def refocus(%__MODULE__{} = ctx, athanor_id), do: focus(ctx, athanor_id)

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

  # The single tenant presence-gate. `:platform` scope is exempt — system
  # tasks legitimately cross tenant boundaries (retention, audit fan-out, the
  # users row that backs `Sanctum.Namespace.lookup/1`),
  # symmetric with `verify_tenant/2`. Otherwise requires a resolved athanor_id.
  defp tenant_gate(%__MODULE__{scope: :platform}), do: :ok
  defp tenant_gate(%__MODULE__{} = ctx), do: Sanctum.TenantPolicy.require_athanor(ctx)

  # ============================================================================
  # Unified Authorization API
  # ============================================================================

  @doc """
  Unified authorization check for action + resource combinations.

  Returns `:ok` if authorized, `{:error, reason}` if not.

  This is the **authoritative** tenant + permission check. A resource that
  carries a tenant identity must be passed as one of the recognized tuples so
  its tenant is verified here, via `Sanctum.TenantPolicy`:

  - `{:execution, record}` — permission + per-record
    `verify_tenant`; the record must carry `:user_id` (attribution) and
    `:athanor_id`. There is no owner gate: members of an athanor are
    interchangeable.
  - `{:tenant, record}` — permission + per-record `verify_tenant`.
  - `nil` / a shape with no tenant identity — permission + tenant *presence*
    only. The storage primitive (`Arca.QueryHelpers.where_tenant/2`,
    `Arca.Storage.tenant_segments/1`) is a fail-closed **backstop** for these,
    not the primary control — so a tenant-bearing record must use a tuple
    above rather than rely on storage scoping.

  ## Authorization Modes

  - **Permission-only**: `authorize(ctx, :execute, nil)` — checks permission
  - **Tenant-bearing record**: `authorize(ctx, :storage_read, {:execution, record})` —
    checks permission and that the record's athanor is the context's

  The permission argument is a `Sanctum.Atoms` permission atom, not an
  action verb — there is no alias mapping.

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> Sanctum.Context.authorize(ctx, :execute, nil)
      :ok

      iex> ctx = Sanctum.Context.build(user_id: "u1", athanor_id: "ath_1", permissions: [:storage_read], authenticated: true)
      iex> record = %{user_id: "u1", athanor_id: "ath_1"}
      iex> Sanctum.Context.authorize(ctx, :storage_read, {:execution, record})
      :ok
  """
  @spec authorize(t(), atom(), term()) :: :ok | {:error, Sanctum.Unauthorized.reason()}
  def authorize(%__MODULE__{} = ctx, action), do: authorize(ctx, action, nil)

  # Unauthenticated contexts are never authorized. This MUST precede the
  # generic clause so an unauthenticated context is never authorized.
  def authorize(%__MODULE__{authenticated: false}, _action, _resource) do
    {:error, :unauthenticated}
  end

  def authorize(%__MODULE__{} = ctx, action, resource) do
    do_authorize(ctx, action, resource)
  end

  # Permission-only check (no resource to verify ownership of). Also
  # enforce the tenant scope (via `Sanctum.TenantPolicy`) so an athanor-less
  # context is rejected centrally rather than relying on storage-layer scoping.
  defp do_authorize(%__MODULE__{} = ctx, action, nil) do
    permission = action_to_permission(action)

    with :ok <- require_permission(ctx, permission),
         :ok <- tenant_ok(ctx) do
      :ok
    else
      {:error, _} = err ->
        log_denial(ctx, action, nil)
        err
    end
  end

  # Tenant-bearing resources authorize identically: permission + per-record
  # athanor equality via verify_tenant. Members of an athanor are
  # interchangeable — there is NO owner gate; user_id stays on records for
  # attribution only. :execution still requires a :user_id key so a tag
  # that promises an owner but carries none fails closed in the malformed
  # clause below (rather than passing on tenant presence alone).
  defp do_authorize(%__MODULE__{} = ctx, action, {:execution, %{user_id: _} = record}) do
    verify_tenant_resource(ctx, action, record)
  end

  defp do_authorize(%__MODULE__{} = ctx, action, {:tenant, %{} = record}) do
    verify_tenant_resource(ctx, action, record)
  end

  # A tagged owner/tenant resource that did not structurally match the typed
  # clauses above — e.g. `{:execution, record}` with no `:user_id`, or a
  # `{:tenant, non_map}` — is caller misuse. Fail closed rather than fall
  # through to the permission + tenant-presence-only path below, which would
  # silently skip the ownership and per-record tenant checks the tag implies.
  defp do_authorize(%__MODULE__{} = ctx, action, {tag, _})
       when tag in [:execution, :tenant] do
    log_denial(ctx, action, {tag, :malformed_resource})
    {:error, {:malformed_resource, tag}}
  end

  # An UNTAGGED value that visibly carries a tenant identity is the same
  # misuse, mechanically refused: the contract below says a tenant-bearing
  # record must arrive tagged so its athanor is checked authoritatively —
  # falling through would silently skip exactly that check.
  defp do_authorize(%__MODULE__{} = ctx, action, %{athanor_id: _}) do
    log_denial(ctx, action, {:untagged_tenant_resource, :refused})
    {:error, :untagged_tenant_resource}
  end

  defp do_authorize(%__MODULE__{} = ctx, action, %{"athanor_id" => _}) do
    log_denial(ctx, action, {:untagged_tenant_resource, :refused})
    {:error, :untagged_tenant_resource}
  end

  # For resources without tenant identity, enforce permission and tenant
  # presence. Pass tenant-owned records as {:execution | :tenant, record}
  # for ownership checks. Storage queries also enforce the context's athanor.
  defp do_authorize(%__MODULE__{} = ctx, action, _resource) do
    do_authorize(ctx, action, nil)
  end

  # Shared body for tenant-bearing resources: permission + per-record
  # athanor equality. The single authorization path for
  # {:execution|:tenant}. verify_tenant (Sanctum.TenantPolicy) logs any
  # tenant mismatch, so this does not re-log.
  defp verify_tenant_resource(%__MODULE__{} = ctx, action, record) do
    with :ok <- require_permission(ctx, action_to_permission(action)),
         :ok <- verify_tenant(ctx, record) do
      :ok
    end
  end

  # Tenant boundary check for resource access. Platform scope bypasses;
  # otherwise `Sanctum.TenantPolicy` rejects a nil/"" athanor and requires
  # the record's athanor to equal the context's.
  defp verify_tenant(%__MODULE__{} = ctx, record) do
    Sanctum.TenantPolicy.verify(ctx, record)
  end

  # Accept permission atoms from Sanctum.Atoms directly.
  defp action_to_permission(action) when is_atom(action), do: action

  # user_id and auth_method ride the rostered Logger metadata — the
  # message carries only what the roster does not.
  defp log_denial(%__MODULE__{} = ctx, action, resource) do
    Logger.warning(
      "[Sanctum.Context] Authorization denied: " <>
        "action=#{action} resource=#{inspect(resource)} scope=#{ctx.scope}"
    )
  end

  # Audit/telemetry + gate for platform-scope construction (see build/1).
  defp audit_platform!(%__MODULE__{scope: :platform} = ctx, sanctioned?) do
    caller = platform_caller()

    Sanctum.Telemetry.platform_context_event(%{
      user_id: ctx.user_id,
      auth_method: ctx.auth_method,
      namespace: ctx.namespace,
      sanctioned: sanctioned?,
      caller: caller
    })

    unless sanctioned? do
      raise ArgumentError,
            "Sanctum.Context.build/1: a platform-scope context is built only by " <>
              "Sanctum.Context.internal/1 / Sanctum.system_context/0 " <>
              "(tests: Sanctum.TestContext.platform/1); " <>
              "caller=#{caller} user=#{ctx.user_id} auth_method=#{ctx.auth_method}"
    end

    :ok
  end

  defp audit_platform!(_ctx, _sanctioned?), do: :ok

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
