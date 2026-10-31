# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum do
  @moduledoc """
  Identity and authorization layer for CYFR.

  Sanctum is the gatekeeper for all CYFR operations. It manages:
  - **Authentication**: Who is making the request (OAuth, API keys)
  - **Authorization**: What they're allowed to do (permissions)
  - **Context**: The execution context that flows through all services

  ## People and signing in

  A person is made only by an admission (`Sanctum.Newcomer`): setup, an
  invitation (`Sanctum.Invitations`), an open door, a verified CYFR
  sign-in, or a restore. Every session is
  minted by `Sanctum.Session`, on one of these paths:

  - an admission that brings its credential (`Sanctum.Newcomer`);
  - the OpenID Connect browser flow — `PrismWeb.AuthController.callback/2`
    unlocks the person who linked the identity `Sanctum.Auth.OIDC` proves
    (`Sanctum.SignIn.unlock/1`, which asks the door about them);
  - the GitHub and Google device flows —
    `Sanctum.Auth.DeviceFlow.poll_for_session/4` behind the `session` MCP
    tool (`cyfr login`) and the sign-in page, which unlock the same way;
  - a command line a signed-in person approves in Prism
    (`Sanctum.CliSignIn`);
  - the CYFR sign-in (`Sanctum.Auth.CyfrDoor`), which unlocks a person
    admitted before or admits a remote newcomer, and a passkey
    (`Sanctum.Passkeys`), which asks the door about the person;
  - the installation-authorized restore (`Sanctum.Recovery`).

  A sign-in method proves who someone is; it never makes a person and
  never mints a session itself. The methods offered are the ones
  configured (`Sanctum.Auth.DeviceFlow.configured_providers/0`,
  `Sanctum.Auth.OIDC.issuer/0`); passkeys, paired devices and the CYFR
  sign-in are always offered.

  A CYFR may also require a company sign-in of every person here
  (`Sanctum.CompanyLogin`): a standing condition, never a sign-in method,
  which `Sanctum.Caller` checks last wherever a person's standing is read.
  """

  use Boundary,
    deps: [Arca],
    exports: [
      Annotations,
      ApiKey,
      Attach,
      Auth,
      Auth.CyfrDoor,
      Auth.DeviceFlow,
      Auth.EmailVerification,
      Auth.Identity,
      Auth.OIDC,
      Authority,
      Authority.BudgetCounter,
      BearerToken,
      Caller,
      Carry,
      Catalog,
      Catalog.NotLoadedError,
      Cipher,
      Cipher.Rotation,
      CliSignIn,
      ClientIp,
      CompanyLogin,
      Consent,
      Consent.Accounts,
      Consent.Components,
      Consent.Loader,
      Consent.Proof,
      Consent.RegistrationBinding,
      Consent.ShapeDerivation,
      Consent.ShapeDiff,
      Context,
      Decisions,
      DeviceCerts,
      Directory,
      Directory.Client,
      Door,
      Door.Store,
      Egress,
      ExecutionStanding,
      Gate,
      Gate.Supervisor,
      Handle,
      IdentityFreshness,
      InstanceEntries,
      Invitations,
      Namespace,
      Network,
      Newcomer,
      Notify,
      Pairing,
      Passkeys,
      Person,
      Policy.Enforcement,
      PolicyLog,
      Providers.Assertion,
      Providers.Confirmation,
      Providers.Pairing,
      Providers.Passkey,
      Providers.Person,
      Provisioning,
      Proxy,
      Recovery,
      Refusals,
      RegistryCredentials,
      RequestLog,
      Resources,
      RunningTasks,
      Session,
      SignIn,
      Tenancy,
      Tenancy.Athanors,
      Tenancy.Caps,
      Tenancy.Members,
      Tenancy.Users,
      TinctureAccess,
      TinctureAuth,
      ToolGrants,
      ToolServerDigest,
      Unauthorized,
      UnauthorizedError,
      Vault,
      Vault.OAuthGrant,
      VaultReader,
      VirtualTools,
      Visibility,
      Webhook
    ],
    # Sanctum holds no Ecto: these applications are checked and none is in
    # `deps`, so the boundary check of a dev or release compile refuses any
    # reference to Ecto, a driver or an adapter, and every row Sanctum reads
    # or writes goes through Arca.
    check: [aliases: true, apps: [:ecto, :ecto_sql, :postgrex, :exqlite, :ecto_sqlite3]]

  alias Sanctum.Context

  @doc """
  The externally reachable base URL of this instance, without a trailing
  slash, or `nil` when the operator has not declared one
  (`:sanctum, :public_url`, from `CYFR_PUBLIC_URL`).

  Only the operator knows it: behind a proxy or a tunnel it is neither
  the bind address nor the `Host` of any particular request. Two of this
  domain's surfaces face outward and need it — the URL a webhook sender
  is handed (`Sanctum.Webhook`) and the `redirect_uri` an OAuth provider
  returns to (`Sanctum.Vault.OAuthGrant`) — so it is read here once.
  """
  @spec public_url() :: String.t() | nil
  def public_url do
    case Application.get_env(:sanctum, :public_url) do
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
  `public_url/0` when the operator declared one, otherwise the
  deployment's own origin (`:sanctum, :fallback_origin`, the endpoint's
  scheme, host and port).

  Distinct from `public_url/0` on purpose: a webhook URL is a *path* when
  nothing is declared, because handing a sender a guessed host is worse
  than handing it nothing, while an OAuth `redirect_uri` must be absolute
  or the flow cannot start at all. TLS deployments set `CYFR_PUBLIC_URL`.
  """
  @spec origin() :: String.t()
  def origin do
    public_url() || Application.get_env(:sanctum, :fallback_origin, "http://localhost:4000")
  end

  @doc """
  The directory this deployment enrolls its local people at
  (`:sanctum, :directory_url`, from `CYFR_DIRECTORY_URL`; unset, it is
  `https://cyfr.run` in production and none in development), or `nil` when
  it names none: local operation and local pairing need none, and
  enrollment needs one. No operation takes a
  directory URL. `Sanctum.Supervisor` refuses the boot on a value
  `enrollment_directory?/1` refuses.
  """
  @spec directory_url() :: String.t() | nil
  def directory_url, do: Application.get_env(:sanctum, :directory_url)

  @doc """
  The registry this deployment speaks to (`:sanctum, :registry_url`, from
  the one parse of `CYFR_REGISTRY_URL` that sets Compendium's too): a host
  with an optional port, or `"none"` for no registry.
  """
  @spec registry_url() :: String.t()
  def registry_url, do: Application.get_env(:sanctum, :registry_url, "none")

  @doc """
  The registry's canonical host, the name a signed registry request binds
  (`Prima.RegistryRequest`): `registry_url/0` lowercased without its port.
  `{:error, :no_registry}` when this deployment names no registry, or a
  value with no host.
  """
  @spec registry_host() :: {:ok, String.t()} | {:error, :no_registry}
  def registry_host do
    with url when url != "none" <- registry_url(),
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse("//" <> url),
         host = String.downcase(host),
         true <- Prima.Identity.Encoding.host?(host) do
      {:ok, host}
    else
      _none -> {:error, :no_registry}
    end
  end

  @doc """
  The base URL of a registry host (a name or address with an optional
  port): `http://` for a loopback host, `localhost`, `127.0.0.0/8` or
  `::1`, a registry on this machine, and `https://` for every other.
  """
  @spec registry_base_url(String.t()) :: String.t()
  def registry_base_url(host) when is_binary(host) do
    if loopback_host?(host), do: "http://" <> host, else: "https://" <> host
  end

  @doc """
  Whether `host` (a name or address with an optional port) is this
  machine's loopback: `localhost`, an address in `127.0.0.0/8`, or `::1`.
  A name that only begins like one, such as `127.0.0.1.example`, is not.
  """
  @spec loopback_host?(String.t()) :: boolean()
  def loopback_host?(host) when is_binary(host) do
    case URI.parse("//" <> host) do
      %URI{host: name} when is_binary(name) -> loopback_name?(name)
      _ -> false
    end
  end

  # A host as a URI holds it: no port, an IPv6 address without brackets.
  defp loopback_name?("localhost"), do: true

  defp loopback_name?(name) do
    case :inet.parse_address(String.to_charlist(name)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  @doc """
  Whether `value` is a directory this deployment may pin for registering
  its people: a directory URL (`Prima.Identity.Encoding.directory_url?/1`)
  served over `https`, or over `http` on a loopback host
  (`loopback_host?/1`), no longer than a confirmation preview's text
  (`Prima.Confirmation.Preview.max_text/0`, 1,024 bytes), since the
  confirmation that shows a recovery code again names the directory in its
  preview (`Sanctum.Recovery`).

  Plain HTTP is allowed on loopback alone because TLS protects a network
  path and loopback has none, and because a directory is trusted only for
  ordering: its writes carry signatures and its reads are verified chains
  (`Sanctum.Directory.Client`). The pinned egress still refuses the
  address unless the operator lists it in `CYFR_PRIVATE_EGRESS_TARGETS`.
  An identity whose genesis names a loopback directory cannot be resolved
  by any other CYFR, which then fails closed.
  """
  @spec enrollment_directory?(term()) :: boolean()
  def enrollment_directory?(value) do
    Prima.Identity.Encoding.directory_url?(value) and directory_transport?(value) and
      byte_size(value) <= Prima.Confirmation.Preview.max_text()
  end

  @doc """
  Whether a directory URL is spoken to over a transport this deployment
  accepts: `https`, or `http` on a loopback host (`enrollment_directory?/1`
  says why).
  """
  @spec directory_transport?(String.t()) :: boolean()
  def directory_transport?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when is_binary(host) -> loopback_name?(host)
      _other -> false
    end
  end

  @doc """
  Whether `value` is an installation's restore token: exactly 64 lowercase
  hexadecimal characters, 32 random bytes. The token is optional (unset,
  restore is disabled) and is never a platform setting or a log value.
  """
  @spec restore_token?(term()) :: boolean()
  def restore_token?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  @doc """
  Whether `value` is an installation's setup token, in the restore
  token's form: exactly 64 lowercase hexadecimal characters, 32 random
  bytes. The token admits the installation's first person
  (`Sanctum.Newcomer`); unset, setup opens nothing. It is never a
  platform setting or a log value.
  """
  @spec setup_token?(term()) :: boolean()
  def setup_token?(value), do: restore_token?(value)

  @doc """
  Server-internal context for background/system operations — sweepers, health
  checks, retention, cache sweep, audit fan-out, secret-store bootstrap,
  execution-record write-back.

  Returns a `scope: :platform`, `auth_method: :system` context with
  `user_id: "system"`. Platform scope bypasses
  tenant boundary checks (`Sanctum.TenantPolicy.verify/2`), correctly modeling
  system tasks that cross tenant boundaries. Distinct from cron, which uses
  `Sanctum.Context.for_scheduled/2` (`auth_method: :scheduled`).

  Thin facade over the single builder `Sanctum.Context.internal/1`.
  """
  def system_context, do: Context.internal([])

  # Namespace for public (unauthenticated) tincture execution. A leading
  # underscore cannot be a real claimed namespace (claimed slugs match
  # ^[a-z0-9]+(-[a-z0-9]+)*$), so this is collision-proof by construction —
  # the same guarantee `"_system"` relies on — while keeping public-tincture
  # execution in its own isolated, audit-distinct namespace (not conflated
  # with system tasks).
  @public_tincture_namespace "_tincture"

  @doc """
  Build the scoped execution context for a tincture invocation.

  This is the *invoke* path (the tincture's catalyst runs with `:execute`). For
  serving a tincture's static assets / looking it up without executing anything,
  use `Sanctum.TinctureAccess.public_context/1` instead.

  Uses `:tincture` authentication through the shared authorization path,
  with or without an auth provider configured.

  For an authenticated request, the caller's real `user_id` and `namespace`
  are carried through for the audit trail (namespace is identity-only and may
  be nil); a public request falls back to the tincture identity and the
  dedicated public-tincture namespace tag. The athanor is inherited from the
  caller and the context stays athanor-scoped (NOT platform-scoped) so tenant
  isolation still applies to the invocation.

  An invocation an API key stands behind (`Sanctum.Context.key_bound?/1`)
  carries the key's id and binding into the run, so the run is still the
  key's and works in the key's athanor alone (`Sanctum.Context.focus/2`,
  `Sanctum.Tenancy.list_athanors/1`) rather than in every athanor the key's
  creator sits in. Any other caller's binding stays behind: a run is not a
  sign-in and issues nothing on one.
  """
  @spec build_tincture_context(Context.t(), map()) :: Context.t()
  def build_tincture_context(%Context{} = caller_ctx, tincture) do
    tincture_id = Prima.ComponentRef.build("tincture", tincture.publisher, tincture.name)

    # Key on `authenticated` (the real signal), NOT on namespace presence — an
    # authenticated user may legitimately have a nil namespace (identity-only,
    # not required). Their namespace passes through for attribution; only a
    # genuinely public caller falls back to the public-tincture identity.
    #
    # An authenticated caller's invocation runs with the caller's OWN
    # permissions — no stronger, no weaker. A public caller gets exactly
    # [:execute] and is marked `anonymous`, which the credential plane
    # (Sanctum.VaultReader) denies: an anonymous internet request must never be
    # silently upgraded into a credential-bearing executor.
    {user_id, namespace, permissions, anonymous} =
      if caller_ctx.authenticated and is_binary(caller_ctx.user_id) do
        {caller_ctx.user_id, caller_ctx.namespace, caller_ctx.permissions, false}
      else
        {tincture_id, @public_tincture_namespace, [:execute], true}
      end

    {api_key_id, binding} =
      if not anonymous and Context.key_bound?(caller_ctx),
        do: {caller_ctx.api_key_id, caller_ctx.credential_binding},
        else: {nil, nil}

    Context.build(
      user_id: user_id,
      namespace: namespace,
      permissions: permissions,
      # Carries the caller's resolved athanor; a nil here flows through and the
      # tenant gate rejects downstream (a tincture cannot widen tenant scope).
      athanor_id: caller_ctx.athanor_id,
      scope: :athanor,
      auth_method: :tincture,
      api_key_id: api_key_id,
      credential_binding: binding,
      authenticated: true,
      anonymous: anonymous
    )
  end
end
