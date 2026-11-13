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

  A person signs in with their account: this CYFR mints a request, a key
  of the account signs it (a passkey at the account pages, or a device
  over its channel) and the answer is verified against the account's log
  (`Sanctum.SignIn`). A person is made only by an admission of an account
  by its identifier (`Sanctum.Newcomer`): setup, an invitation
  (`Sanctum.Invitations`) or the door. Every session is minted by
  `Sanctum.Session`, on one of these paths:

  - a sign-in's answer (`Sanctum.SignIn`), which asks the door about the
    person (`Sanctum.Door`) or admits a new one;
  - a protected device's unlock (`Sanctum.DeviceUnlock`), redeemed by its
    browser or its command line.

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
      Auth.OIDC,
      Authority,
      Authority.BudgetCounter,
      BearerToken,
      Caller,
      Catalog,
      Catalog.NotLoadedError,
      Cipher,
      Cipher.Rotation,
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
      DeviceUnlock,
      Directory,
      Directory.Client,
      Directory.Handles,
      Door,
      Door.Store,
      Egress,
      ExecutionStanding,
      Gate,
      Gate.Supervisor,
      IdentityFreshness,
      Invitations,
      Mount,
      Namespace,
      Network,
      Newcomer,
      Notify,
      Pairing,
      Policy.Enforcement,
      PolicyLog,
      Provisioning,
      Proxy,
      Refusals,
      RegistryCredentials,
      RequestLog,
      Resources,
      RunningTasks,
      Session,
      SharedThreads,
      Shares,
      SignIn,
      Tenancy,
      Tenancy.Athanors,
      Tenancy.Caps,
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
  How this home is reached, `:local`, `:tailnet` or `:public`: the access
  mode `config/runtime.exs` resolves from `CYFR_ACCESS`
  (`Cyfr.RuntimeConfig.resolve_access/1`); a boot that resolves none, as a
  test's does, is a local home's (`config/config.exs`). It decides what
  freshness answers while a directory cannot be read
  (`Sanctum.IdentityFreshness`).
  """
  @spec access_mode() :: :local | :tailnet | :public
  def access_mode do
    case Application.fetch_env!(:sanctum, :access_mode) do
      mode when mode in [:local, :tailnet, :public] ->
        mode

      other ->
        raise ArgumentError,
              "the access mode is none of local, tailnet or public: " <>
                Prima.LoggerContext.shape(other)
    end
  end

  @doc """
  The directory this deployment enrolls its local people at
  (`:sanctum, :directory_url`, from `CYFR_DIRECTORY_URL`; unset, it is
  `https://cyfr.run` in every build). Every CYFR names one, cyfr.run or
  its own. No operation takes a directory URL. `Sanctum.Supervisor`
  refuses the boot on a value `enrollment_directory?/1` refuses, and on
  none.
  """
  @spec directory_url() :: String.t()
  def directory_url, do: Application.fetch_env!(:sanctum, :directory_url)

  @doc """
  The registry this deployment speaks to (`:sanctum, :registry_url`, from
  the one parse of `CYFR_REGISTRY_URL` that sets Compendium's too): a host
  with an optional port (`registry_url?/1`). Every CYFR names one, cyfr.run
  or its own; `config/runtime.exs` refuses a boot that names none.
  """
  @spec registry_url() :: String.t()
  def registry_url, do: Application.fetch_env!(:sanctum, :registry_url)

  @doc """
  The registry's canonical host, the name a signed registry request binds
  (`Prima.RegistryRequest`): `registry_url/0` lowercased without its port.
  """
  @spec registry_host() :: String.t()
  def registry_host do
    {:ok, host} = registry_authority(registry_url())
    host
  end

  @doc """
  Whether `value` names a registry: a host name or an IPv4 address, in any
  case, an optional port from 1 to 65535 (empty, the scheme's own), and an
  optional path a proxy serves it under: segments, none empty, with no
  trailing `/`, query, fragment, space or control character.
  An IPv6 literal is not one: a signed registry request and a handle's
  answer bind the registry by a host name's grammar
  (`Prima.RegistryRequest`, `Prima.HandleAnswer`), which cannot spell one.
  """
  @spec registry_url?(term()) :: boolean()
  def registry_url?(value), do: match?({:ok, _host}, registry_authority(value))

  # The registry's host and port, before the path a proxy may add, which
  # its base URL carries and nothing signed names.
  defp registry_authority(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [authority] ->
        parse_registry(authority)

      # One or more segments, none empty: a path that begins `/` is a
      # scheme's `//` (`https://host`), and an empty segment or a trailing
      # `/` puts `//` in every request, which a CYFR's router forgives and
      # cyfr.run answers 404.
      [authority, path] ->
        if path =~ ~r/\A[^\/?#\x00-\x20\x7f]+(?:\/[^\/?#\x00-\x20\x7f]+)*\z/,
          do: parse_registry(authority),
          else: :error
    end
  end

  defp registry_authority(_value), do: :error

  defp parse_registry(value) when is_binary(value) do
    {host, port} =
      case String.split(value, ":", parts: 2) do
        [host] -> {host, nil}
        [host, port] -> {host, port}
      end

    host = String.downcase(host)

    if Prima.Identity.Encoding.host?(host) and registry_port?(port),
      do: {:ok, host},
      else: :error
  end

  # An empty port is the scheme's own, as a URL reads it.
  defp registry_port?(nil), do: true
  defp registry_port?(""), do: true

  # Digits as a URL reads them, leading zeros among them.
  defp registry_port?(port),
    do: port =~ ~r/\A[0-9]+\z/ and String.to_integer(port) in 1..65_535

  @doc """
  Whether `value` names an OCI registry, which components are pulled from
  (`CYFR_OCI_REGISTRY_URL`): a host name, an IPv4 address or a bracketed
  IPv6 address, each with an optional port from 1 to 65535 (empty, the
  scheme's own), and no path,
  since the host begins every component reference pulled from it. The
  OCI transport reaches an IPv6 registry by its bracketed URL authority,
  and nothing signed names this host.
  """
  @spec oci_registry_url?(term()) :: boolean()
  def oci_registry_url?(value) when is_binary(value) do
    case Regex.run(~r/\A\[([0-9A-Fa-f:.]+)\](?::([^:]*))?\z/, value, capture: :all_but_first) do
      [address | port] ->
        match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(address))) and
          Enum.all?(port, &registry_port?/1)

      nil ->
        match?({:ok, _host}, parse_registry(value))
    end
  end

  def oci_registry_url?(_value), do: false

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
  (`Prima.Confirmation.Preview.max_text/0`, 1,024 bytes).

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

  Uses `:tincture` authentication through the shared authorization path.

  For an authenticated request, the caller's real `user_id` and `namespace`
  are carried through for the audit trail (namespace is identity-only and may
  be nil); a public request falls back to the tincture identity and the
  dedicated public-tincture namespace tag. The athanor is inherited from the
  caller and the context stays athanor-scoped (NOT platform-scoped) so tenant
  isolation still applies to the invocation.

  An invocation an API key stands behind (`Sanctum.Context.key_bound?/1`)
  carries the key's id and binding into the run, so the run is still the
  key's and works in the athanor the key was minted in alone
  (`Sanctum.Context.focus/2`) rather than in every athanor the key's
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
