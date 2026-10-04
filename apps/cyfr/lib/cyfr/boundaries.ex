# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Boundaries do
  @moduledoc """
  The one catalog of the architectural boundaries this repository holds
  itself to, and the pure checks that read a tree against it.

  The catalog names every module it judges, from the gate to the routers,
  so it is a boundary of its own beside the host rather than a host
  module: its dependencies are the boundaries its rows name, and nothing
  depends on it.

  The Boundary declarations make an edge between two boundaries of one
  application a compile error, and a surface row the compiler holds whole
  is not here: its plant in `Cyfr.BoundariesTest.CompilerPlants` is its
  proof. The catalog holds what that compiler cannot see: the edges out of
  Prima and the islands, which run no Boundary compiler, and out of a
  foundation, whose build does not see the boundaries above it; a roster
  narrower than its target's exports, since Boundary's exports are global,
  the security stores among them; a name in a route provider's or the
  shared tier's quote, which Boundary traces only in the composition router
  it expands in; functions rather than modules; and module names, keys,
  routes, sites and calls that are data, configuration or runtime terms
  rather than references. `Cyfr.BoundariesTest` is the one reader: it
  plants a violation of each kind and shows it reported, and it refuses a
  scan that read nothing, because a roster that stops reading passes
  every assertion it makes.

  Five kinds of row, and three registers beside them:

    * `applications/0` — what each umbrella application may depend on, as
      its `mix.exs` declares it, and the layer each module namespace sits
      in. This is the dependency check: `arca` names nothing above the
      contracts, `sanctum` nothing above Arca, the host names neither
      island, and each island names nothing of the control plane.
    * `surfaces/0` — the directed reaches inside an application, which a
      dependency graph cannot express: which Sanctum namespaces the
      console may name, what the auth domain may name of the transport,
      what reaches back up into the component domain, and which storage
      modules hold security rows only Sanctum may read
      (`sanctum_only_storage/0`). Beside them, `http_free/0` names the
      domain trees no line of which names an HTTP type, `bus_free/0`
      the bus's own tree, which names no identity, domain or surface
      module, and `sanctum_exports/0` the identity domain's functions the
      host application calls, one by one.
    * `route_postures/0` and `public_routes/0` — how every HTTP route is
      authenticated. The posture travels with the route (each route
      provider declares it as route metadata); this catalog
      owns the vocabulary and the roster of routes that are public by
      design.
    * `config_key_classes/0` — the configuration schema: every
      application key the code reads that no configuration file declares,
      and what each one is.
    * `filesystem_seam/0` — the storage seam: a direct filesystem call in
      an application's `lib` goes through `Arca.Storage` or carries the
      bypass marker that names its group.

  Every row is settled: a row names only what the tree reaches now, and
  the stale checks hold each one to being reached, so a row written ahead
  of its caller fails as surely as a caller without a row.

  And the registers:

    * `ports/0` and `internal_strategies/0` — the five ports of
      `ARCHITECTURE.md`, and the two behaviours Sanctum declares that are not
      ports.
    * `actor_paths/0` — every way a `%Prima.Actor{}` is constructed, with
      the reason for each. Four is how you get six.
    * `system_responsibilities/0` — every write the server makes on work
      whose standing it does not require, and every read it makes before
      any caller is known, with the module that makes it and why: a system
      responsibility is rostered, never a caller's flag.
    * `opus_named_by_cyfr_tests/0` — which CYFR test files may name an
      Opus module, and why.

  Every check here takes a tree already read through
  `Prima.Test.CodeLines`: the module names a file names, for the namespace
  rows, and its code lines for the rest — beside the file's text for the
  filesystem seam, whose marker is a comment the filter drops. A name is
  read from the token stream rather than matched in a line, so a module
  named in a log sentence or a tool description is not a dependency and a
  call on a root module is. The rules live here; the filter is the
  reader's, which is what keeps a catalog that ships in `lib` off the
  test support.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Grimoire,
      Crucible,
      Emissary,
      Emissary.Router,
      Emissary.Web,
      Prism.Router,
      CyfrWeb,
      CyfrWeb.Router
    ],
    exports: [],
    check: [aliases: true]

  # ---------------------------------------------------------------------------
  # 1. The applications
  # ---------------------------------------------------------------------------

  @typedoc "A layer of the dependency graph, or `:outside` for everything else."
  @type layer :: :prima | :arca | :sanctum | :host | :opus | :locus | :outside

  @applications [
    %{
      app: :prima,
      layer: :prima,
      lib: "apps/prima/lib",
      umbrella_deps: [],
      note: "pure contracts and the explicit shared runtime primitives; no owned processes"
    },
    %{
      app: :arca,
      layer: :arca,
      lib: "apps/arca/lib",
      umbrella_deps: [:prima],
      note: "persistence, at the bottom of the graph"
    },
    %{
      app: :sanctum,
      layer: :sanctum,
      lib: "apps/sanctum/lib",
      umbrella_deps: [:arca, :prima],
      note: "identity, tenancy, authority, consent and the vault, over Arca's rows"
    },
    %{
      app: :cyfr,
      layer: :host,
      lib: "apps/cyfr/lib",
      umbrella_deps: [:arca, :prima, :sanctum],
      note:
        "the host and everything above it. It declares neither island: " <>
          "`Crucible` is the seam to Opus and `Prima.BuilderProtocol` to Locus"
    },
    %{
      app: :opus,
      layer: :opus,
      lib: "apps/opus/lib",
      umbrella_deps: [:prima],
      note: "the WASM engine island; it reaches CYFR over its host API alone",
      dependency_roots: ~w(Jason Req Plug Bandit Wasmex)
    },
    %{
      app: :locus,
      layer: :locus,
      lib: "apps/locus/lib",
      umbrella_deps: [:prima],
      note: "the builds and backends island; CYFR reaches it over its two wires alone",
      dependency_roots: ~w(Plug Bandit ThousandIsland)
    }
  ]

  @doc """
  Every umbrella application, the layer it is, the `lib` tree its code
  lives in, and the umbrella dependencies its `mix.exs` may declare.

  The dependency rule falls out of the list: an application may name a
  module of its own layer, of the layers its declared dependencies are,
  and of nothing else product-side. Boundary cannot hold it: a build does
  not see the boundaries of an application it does not depend on, whose
  call is an undefined-module warning naming no boundary and whose bare
  name compiles, and Prima and the islands run no Boundary compiler.
  """
  @spec applications() :: [map()]
  def applications, do: @applications

  @doc """
  The islands: the applications whose releases carry the contracts alone,
  and whose code is therefore held to a closed world — its own modules,
  the contracts, Elixir and OTP, and the roots of the libraries its
  `mix.exs` declares. `dependency_roots` is that last roster, and a root
  it names must be a module of a declared dependency and must still be
  reached; Elixir's own modules are not rostered, because naming `Enum` is
  not a dependency decision.
  """
  @spec islands() :: [atom()]
  def islands, do: for(row <- @applications, Map.has_key?(row, :dependency_roots), do: row.app)

  @doc "The application row for `app`."
  @spec application!(atom()) :: map()
  def application!(app) do
    Enum.find(@applications, &(&1.app == app)) || raise "no boundary row for #{inspect(app)}"
  end

  @doc """
  The layers `app`'s code may name, derived from its declared umbrella
  dependencies: its own, its dependencies' (transitively), and
  `:outside`, which is Elixir, OTP and the fetched dependencies.
  """
  @spec reachable_layers(atom()) :: [layer()]
  def reachable_layers(app) do
    row = application!(app)

    deps =
      row.umbrella_deps
      |> Enum.flat_map(&[application!(&1).layer | reachable_layers(&1)])
      |> Enum.reject(&(&1 == :outside))

    Enum.uniq([row.layer | deps] ++ [:outside])
  end

  # The product namespaces, so a scan can tell a module of this repository
  # from one of Elixir, OTP or a fetched dependency. Boundary knows each
  # boundary's modules, not which names are this repository's.
  @product_roots ~w(
    Arca Sanctum Aqua Compendium Crucible Emissary Grimoire
    Prism PrismWeb Cyfr CyfrWeb Opus Locus Codex Prima
  )

  @doc "The namespace roots this repository owns."
  @spec product_roots() :: [String.t()]
  def product_roots, do: @product_roots

  @doc """
  The layer a module name sits in.

  `prima` is the set of module names Prima defines, read from the tree
  rather than listed here: `Prima.Actor` is Prima's and
  `Grimoire.Catalog` is the host's, and only the tree knows which is
  which.
  """
  @spec layer(String.t(), MapSet.t(String.t())) :: layer()
  def layer(module, prima) do
    cond do
      MapSet.member?(prima, module) -> :prima
      root?(module, "Sanctum") -> :sanctum
      root?(module, "Arca") -> :arca
      root?(module, "Opus") -> :opus
      root?(module, "Locus") -> :locus
      (module |> String.split(".") |> hd()) in @product_roots -> :host
      true -> :outside
    end
  end

  defp root?(module, root), do: module == root or String.starts_with?(module, root <> ".")

  @typedoc """
  A scanned tree: each file with the module names it names and the lines
  it names them on, as `Prima.Test.CodeLines.aliases/1` returns them.

  Every namespace check below takes one of these rather than raw sources,
  so this module holds the rules and the one reader holds the filter — and
  a planted source, run through the same filter, proves a rule reports
  what it should.
  """
  @type named :: [{Path.t(), [{String.t(), pos_integer()}]}]

  @typedoc "A scanned tree of code lines, for the checks that read a line's text."
  @type scanned :: [{Path.t(), [{String.t(), pos_integer()}]}]

  @doc "Every product-namespace name in `named`, as `{path, line, module}`."
  @spec product_reaches(named()) :: [{Path.t(), pos_integer(), String.t()}]
  def product_reaches(named) do
    for {path, names} <- named,
        {module, number} <- names,
        (module |> String.split(".") |> hd()) in @product_roots,
        uniq: true,
        do: {path, number, module}
  end

  @doc """
  The reaches in `scanned` that `app` may not name, each rendered with its
  file, line, module and the layer it lands in.
  """
  @spec dependency_violations(atom(), named(), MapSet.t(String.t())) :: [String.t()]
  def dependency_violations(app, named, contracts) do
    allowed = reachable_layers(app)

    for {path, line, module} <- product_reaches(named),
        found = layer(module, contracts),
        found not in allowed,
        do: "#{path}:#{line} names #{module} (#{found}); #{app} may name #{inspect(allowed)}"
  end

  @doc """
  The one file the source scans skip: this catalog, which names each
  namespace it rosters and would report itself as a reach into all of
  them. Nothing else is skipped, and the compiled scan — which reads what
  the compiler emitted rather than what a line says — covers this file
  with no exception at all. The filesystem seam skips nothing: the call
  pattern this file writes down is not a call.
  """
  @spec scan_exclusions() :: [Path.t()]
  def scan_exclusions, do: ["apps/cyfr/lib/cyfr/boundaries.ex"]

  # ---------------------------------------------------------------------------
  # 2. The surfaces
  # ---------------------------------------------------------------------------

  # The storage modules whose rows are security rows, and the `lib` trees
  # that may name them: Sanctum, their one reader, and Arca, which holds
  # them.
  @sanctum_only_storage ~w(
    Arca.ConsentStorage Arca.ConsentProofStorage Arca.ProfileStorage Arca.ToolGrantStorage
    Arca.VaultStorage Arca.SessionStorage Arca.ApiKeyStorage Arca.RegistryTokenStorage
    Arca.ProviderCredentialStorage Arca.WebhookStorage Arca.FrameCredentials
    Arca.PairedClients Arca.Users Arca.Members Arca.Athanors Arca.Doors
    Arca.PersonIdentities Arca.IdentityAttempts Arca.IdentityLog Arca.DirectoryHeads
    Arca.DeviceCertificates Arca.DeviceCertifications Arca.PairingInvitations Arca.Passkeys
    Arca.PendingConfirmations Arca.CarryActions Arca.InstallationClaims
    Arca.RequestRateWindows Arca.InstanceEntries Arca.InstanceEntryUsage
  )
  @security_row_readers ["apps/sanctum/lib", "apps/arca/lib"]

  @surfaces [
    # --- the auth domain's callers, each crossing the licence boundary ---
    %{
      from: ["apps/cyfr/lib/aqua/**/*.ex", "apps/cyfr/lib/aqua.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.Consent Sanctum.Context Sanctum.ExecutionStanding Sanctum.Notify
        Sanctum.Provisioning Sanctum.Tenancy Sanctum.ToolGrants
      ),
      reason:
        "`Sanctum.ToolGrants` holds the standing answers a person gave, which are " <>
          "consent state: the assistant composes them with an agent's policy and " <>
          "checks which may stand, and reads and writes the rows only through it. " <>
          "`Sanctum.Provisioning` is `Aqua.AgentConfig`'s two in-process agent reads " <>
          "alone — the first-need hook: a turn reads its athanor's tree in-process " <>
          "now rather than through the `aqua` tool, and the bundle a group athanor " <>
          "is filled with on first read has to be there before the turn roots an " <>
          "authority in it. `Sanctum.ExecutionStanding` is `Aqua.Tape`'s check over " <>
          "the grant a turn's root attempt stores, handed to the turn's writes. " <>
          "`Sanctum.Consent` is `Aqua.ConsentStatus`'s read of what a source " <>
          "declares, through consent's own derivation; the row below narrows it. " <>
          "Boundary's exports are global, and `Sanctum` exports more than this roster to " <>
          "every boundary that lists it, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/aqua/**/*.ex", "apps/cyfr/lib/aqua.ex"],
      into: "Sanctum.Consent",
      depth: 3,
      allow: ~w(Sanctum.Consent.ShapeDerivation),
      reason:
        "the assistant reports whether a consent still covers its source and grants " <>
          "nothing: it reads what a source declares through " <>
          "`Sanctum.Consent.ShapeDerivation` and what was consented from the authority " <>
          "a turn would pin, and names nothing of the plane that writes a consent. " <>
          "`Sanctum.Consent` is no boundary of its own, and `Sanctum`'s exports, which are " <>
          "global, name more of it than this roster, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/compendium/**/*.ex", "apps/cyfr/lib/compendium.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.Consent Sanctum.Context Sanctum.Egress Sanctum.Network
        Sanctum.Namespace Sanctum.Provisioning Sanctum.RegistryCredentials Sanctum.SignIn
        Sanctum.VaultReader Sanctum.Webhook
      ),
      reason:
        "`Sanctum.Provisioning` is the first-need hook and the half of filling an " <>
          "athanor that is identity's: the claim it runs under, the baseline consents, " <>
          "the readiness and failure writes on the row. `Compendium.Provisioning` owns " <>
          "the component work and calls down into it. OCI and registry transports " <>
          "use Sanctum.Network and Sanctum.Egress for validated outbound requests. " <>
          "A person's push tokens are sealed and read by `Sanctum.RegistryCredentials`; " <>
          "removing a component's last version revokes its profiles " <>
          "(`Sanctum.Consent.revoke_source/2`) and disables its webhooks " <>
          "(`Sanctum.Webhook.disable_for_component/2`). `Compendium` never names " <>
          "`Sanctum.Tenancy`. " <>
          "Boundary's exports are global, and `Sanctum` exports more than this roster to " <>
          "every boundary that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/cyfr/**/*.ex",
        "apps/cyfr/lib/grimoire/**/*.ex",
        "apps/cyfr/lib/crucible/**/*.ex",
        "apps/cyfr/lib/crucible.ex"
      ],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.Atoms Sanctum.Attach Sanctum.Auth Sanctum.Authority Sanctum.Caller
        Sanctum.Carry Sanctum.Cipher Sanctum.Consent Sanctum.Context Sanctum.Door
        Sanctum.Egress Sanctum.ExecutionStanding Sanctum.Grimoire Sanctum.InstanceEntries
        Sanctum.Network Sanctum.Policy Sanctum.Session
        Sanctum.Tenancy Sanctum.TinctureAccess Sanctum.ToolServerDigest Sanctum.Unauthorized
        Sanctum.UnauthorizedError Sanctum.VaultReader
      ),
      reason:
        "the glue and application namespace: boot wiring, the operation table, " <>
          "admission, the invoke budget, the vault edge a run is attached with, and " <>
          "the policy record of every admission. `Sanctum` bare is the domain's own " <>
          "front door — `internal_context/1` and `system_context/0` mint the contexts " <>
          "the server's own work runs under, `auth_configured?/0` says whether this " <>
          "deployment has sign-in, and `build_tincture_context/2` is a tincture " <>
          "invocation's. A call on the root is a reach like any other and is rostered " <>
          "like one; no roster before this one could see it. `Sanctum.Caller` is " <>
          "here for `drop_memo/1` alone: the identity domain announces that an " <>
          "established-caller memo is no longer good and never broadcasts, so the " <>
          "host's own watch (`Cyfr.StandingWatch`) is what carries the drop to " <>
          "every member and calls back down to make it. `Sanctum.ExecutionStanding` " <>
          "decides whether an admitted execution's grant still stands: admission, " <>
          "every host effect, the in-chain gate and the sweep ask it. `Sanctum.Egress` " <>
          "is `Grimoire.Provider`'s registry probe and `system.notify` webhook. " <>
          "`Sanctum.Network` is `Crucible.Host.Egress`'s one resolution of a guest's " <>
          "outbound host, which it pins under the attempt's authority. " <>
          "`Sanctum.TinctureAccess` is that invocation's reread of the tincture it " <>
          "roots at: its public-profile and private-access policy. " <>
          "`Sanctum.Carry` is `Cyfr.RetentionScheduler`'s periodic sweep of every " <>
          "person's expired sign-in carries (`sweep/1`), which names no store. " <>
          "`Sanctum.InstanceEntries` is `Cyfr.RetentionScheduler`'s periodic sweep of " <>
          "instance-entry usage days (`sweep_usage/0`), which names no entry and no person. " <>
          "`Sanctum.Attach` is `Crucible.Host.AttachedFetch`'s one resolution of the value " <>
          "an attached request carries (`resolve/5`): the vault decides, and the control " <>
          "plane attaches and performs. " <>
          "Boundary's exports are global, and `Sanctum` exports more than this roster to " <>
          "every boundary that lists it, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/emissary/**/*.ex", "apps/cyfr/lib/emissary.ex"],
      into: "Sanctum",
      depth: 3,
      allow: ~w(
        Sanctum Sanctum.BearerToken Sanctum.Caller Sanctum.ClientIp Sanctum.Consent
        Sanctum.Context Sanctum.DeviceCerts Sanctum.Directory Sanctum.Egress
        Sanctum.ExecutionStanding
        Sanctum.Network Sanctum.Recovery Sanctum.Session Sanctum.TinctureAccess
        Sanctum.TinctureAuth Sanctum.ToolServerDigest Sanctum.Unauthorized
        Sanctum.UnauthorizedError Sanctum.Vault Sanctum.Vault.OAuthGrant Sanctum.VaultReader
        Sanctum.Webhook
      ),
      reason:
        "the auth fabric's own front door, where a wide roster is the front door doing " <>
          "its job. The MCP transport carries tenancy, reads a server's vault edge, and " <>
          "uses Sanctum.Network/Egress for external servers and the backends service. " <>
          "`Sanctum.Vault` is the check of a server definition against the entries it " <>
          "names, metadata only, which the external provider makes before storing one " <>
          "and the server process and the backends controller make again before " <>
          "unsealing any: a header's entry's destination covers the server's URL " <>
          "(`destination_matches?/3`) and a backend env's entry is disclosed " <>
          "(`disclosed?/2`). " <>
          "An outbound call's row runs under its caller's grant, checked through " <>
          "Sanctum.ExecutionStanding as it is admitted and closed, and the MCP " <>
          "controller answers a `Sanctum.UnauthorizedError` raised in the request " <>
          "process as a JSON-RPC refusal. The HTTP adapters read the bearer token, " <>
          "the caller and the session, the tincture credentials and access policy, the " <>
          "vault's OAuth grant and a webhook's row. `Sanctum.Consent` is the tincture " <>
          "data routes' read of the grant revision a frame credential names " <>
          "(`Sanctum.Consent.profiles/2`, `head_consent/2`), read as the shell reads it " <>
          "when it mints. The directory's routes are `Sanctum.Directory`'s decisions, the " <>
          "restore ingress `Sanctum.Recovery`'s, and the device channel checks each " <>
          "certificate and proof through `Sanctum.DeviceCerts`. " <>
          "Boundary's exports are global, and `Sanctum` exports more than this roster to " <>
          "every boundary that lists it, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/prism/**/*.ex", "apps/cyfr/lib/prism.ex"],
      into: "Sanctum",
      allow: ~w(Sanctum Sanctum.Consent Sanctum.Context Sanctum.Tenancy Sanctum.TinctureAuth),
      reason:
        "console domain code: the tenancy carrier. The tray's messages arrive on " <>
          "`Cyfr.Bus` as its own structs, so the console names none of the identity " <>
          "domain's announcement vocabulary. The shell's frames (`Prism.Frames`) mint, " <>
          "suspend, resume and revoke each frame credential through " <>
          "`Sanctum.TinctureAuth`, and read the grant revision it binds through " <>
          "`Sanctum.Consent`'s own entries (`profiles/2`, `head_consent/2`). " <>
          "Boundary's exports are global, and `Sanctum` exports more than this roster to " <>
          "every boundary that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex",
        "apps/cyfr/lib/cyfr_web/**/*.ex",
        "apps/cyfr/lib/cyfr_web.ex"
      ],
      into: "Sanctum",
      allow: ~w(
        Sanctum.ApiKey Sanctum.Auth Sanctum.BearerToken Sanctum.Caller Sanctum.ClientIp
        Sanctum.Consent Sanctum.Context Sanctum.Door Sanctum.Pairing Sanctum.Passkeys
        Sanctum.Session Sanctum.SignIn Sanctum.Tenancy Sanctum.TinctureAuth
        Sanctum.Unauthorized Sanctum.Webhook
      ),
      reason:
        "the console, its browser sign-in (`PrismWeb.AuthController`, which asks the " <>
          "door before the sign-in response mints a session), its context guard " <>
          "(`CyfrWeb.ContextGuard`, which names " <>
          "`Sanctum.Caller` and `Sanctum.Context` alone) and the web tier's shared " <>
          "ingress plugs (`CyfrWeb.Plugs.*`), which are the auth fabric's own " <>
          "ingress — a wide roster is the front door doing its job. " <>
          "`Sanctum.Consent` is the shell's read of whether a tincture has an active " <>
          "public profile (`Sanctum.Consent.profiles/2`). " <>
          "`Sanctum.Pairing` is the system layer's reading of the action table and of " <>
          "whether this client has a person behind it who can confirm, which hides a " <>
          "control and never decides: the operation a confirmation dispatches decides. " <>
          "`Sanctum.Passkeys` is the sign-in page's passkey door: the challenge it holds " <>
          "and the answer it verifies into a session, as the device flow's poll is " <>
          "(`sign_in_challenge/0`, `sign_in/2`); `Sanctum.Auth.CyfrDoor` is the `cyfr` door's: " <>
          "the signing home the sign-in page sends a person to (`signing_home/1`), the " <>
          "challenge it mints for the carry they bring back (`challenge/1`), where the " <>
          "callback's hop returns them (`redirect_url/1`), the assertion the callback " <>
          "admits into a session, behind the door (`callback/2`), and the carry's " <>
          "lifetime the sign-in and `/carry` pages hand their script " <>
          "(`carry_lifetime_ms/0`); " <>
          "`Sanctum.Auth.OIDC.reauth_callback/1` and " <>
          "`reauth_decide/3` are the re-authentication's callback and its person's answer " <>
          "(`PrismWeb.ReauthController`), which confirm one pending confirmation on that " <>
          "answer and mint nothing. " <>
          "In the console, `Sanctum.ClientIp` is `PrismWeb.AuthHelpers.socket_client_ip/1` " <>
          "alone: the `/live` socket is handled by the endpoint BEFORE the router, so " <>
          "it passes no rate-limit plug, which makes the console the only per-address " <>
          "bound on the anonymous device flows it starts. " <>
          "Boundary's exports are global, and `Sanctum` exports more than this roster to " <>
          "every boundary that lists it, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/compendium/**/*.ex", "apps/cyfr/lib/compendium.ex"],
      into: "Sanctum.Consent",
      depth: 3,
      allow: ~w(Sanctum.Consent Sanctum.Consent.Components Sanctum.Consent.ShapeDerivation),
      reason:
        "the consent WRITE plane stays behind Sanctum's own surface: the athanor " <>
          "filler mints its baseline consents through `Sanctum.Provisioning`, never " <>
          "`Sanctum.Consent.Bootstrap`. `Sanctum.Consent.Components` is the " <>
          "component-facts port — naming a behaviour one implements is the opposite " <>
          "of reaching into the write plane. `Sanctum.Consent` itself is the read " <>
          "and revoke entries the setup plan and the removal cascade call. " <>
          "`Sanctum.Consent` is no boundary of its own, and `Sanctum`'s exports, which are " <>
          "global, name more of it than this roster, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex",
        "apps/cyfr/lib/cyfr_web/**/*.ex",
        "apps/cyfr/lib/cyfr_web.ex"
      ],
      into: "Sanctum.Consent",
      depth: 3,
      allow: ~w(Sanctum.Consent),
      reason:
        "the console reads consent through `Sanctum.Consent`'s own entries (the " <>
          "shell's `profiles/2`) and names nothing of the plane behind them: the " <>
          "plan, preview and commit walk, its proofs and its loader are reached " <>
          "through the operation table like every other surface's. " <>
          "`Sanctum.Consent` is no boundary of its own, and `Sanctum`'s exports, which are " <>
          "global, name more of it than this roster, so no declaration can say it."
    },

    # --- what the layers below name of the layers above ---
    %{
      from: ["apps/sanctum/lib/**/*.ex", "apps/arca/lib/**/*.ex"],
      into: "Phoenix.PubSub",
      allow: [],
      reason:
        "a foundation below the host emits `:telemetry` and never broadcasts: the host's " <>
          "bridge (`Cyfr.TelemetryBridge`) is the one place an announcement becomes a " <>
          "bus message, after the fact it announces committed. " <>
          "No boundary declares `Phoenix.PubSub`, neither foundation's `check: apps` lists " <>
          "its application, and Sanctum's build carries it, so no compiler refuses the reach."
    },
    %{
      from: ["apps/sanctum/lib/**/*.ex", "apps/arca/lib/**/*.ex"],
      into: "Cyfr.PubSub",
      allow: [],
      reason:
        "the PubSub server's name is the host's: only `Cyfr.Application` starts it and " <>
          "only `Cyfr.Bus` publishes on it. " <>
          "`Cyfr.PubSub` is a process name, not a module, and a foundation's build does not " <>
          "see the host's boundaries, so no compiler sees the reach."
    },
    %{
      from: ["apps/sanctum/lib/**/*.ex", "apps/arca/lib/**/*.ex"],
      into: "Cyfr.Bus",
      allow: [],
      reason:
        "the topics, their payloads and their tenant checks are the host's bus; a " <>
          "foundation below it names none of them and keeps no topic vocabulary. " <>
          "A foundation's build does not see the host's boundaries: its pruned code path " <>
          "makes a call an undefined-module warning that names no boundary, and a bare name " <>
          "compiles."
    },
    %{
      from: ["apps/arca/lib/**/*.ex"],
      into: "Compendium",
      allow: [],
      reason:
        "the overlay's locators were wired through `Arca.Storage.UnitLocator` so the " <>
          "storage layer would not compile against the component domain; the closed " <>
          "`source` roster it enforces on write is `Prima.ComponentSource` now. " <>
          "A foundation's build does not see the host's boundaries: its pruned code path " <>
          "makes a call an undefined-module warning that names no boundary, and a bare name " <>
          "compiles."
    },
    %{
      from: ["apps/cyfr/lib/aqua/**/*.ex", "apps/cyfr/lib/aqua.ex"],
      into: "Crucible",
      allow: ~w(Crucible),
      reason:
        "the assistant runs what it runs through the execution domain's root facade " <>
          "alone: a turn claims, pauses, resumes and releases its root there, and a " <>
          "model listing or a consent status derives an authority there; nothing of " <>
          "admission, dispatch or the attempt's rows is the assistant's to name. " <>
          "Boundary's exports are global, and `Crucible` exports `Host.Children`, `Keys`, " <>
          "`Schedules.Scheduler` and `Supervisor` beside its root to every boundary that " <>
          "lists it, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/aqua/**/*.ex", "apps/cyfr/lib/aqua.ex"],
      into: "Compendium",
      allow: ~w(Compendium),
      reason:
        "the assistant reads its agents, their snapshots and consent rows, its skills " <>
          "and its model catalysts through the component domain's root facade alone, " <>
          "and the agent-reference and version vocabularies it reads are Prima's. " <>
          "Boundary's exports are global, and `Compendium` exports its two paths, " <>
          "`ConsentFacts`, `Providers.Component` and `Supervisor` beside its root to every " <>
          "boundary that lists it, so no declaration can say it."
    },
    %{
      from: ["apps/cyfr/lib/crucible/**/*.ex", "apps/cyfr/lib/crucible.ex"],
      into: "Compendium",
      allow: ~w(Compendium),
      reason:
        "execution resolves, inspects and activates what it runs through the component " <>
          "domain's root facade alone: the reference, the manifest, the activation graph " <>
          "and an artifact's bytes are component facts Compendium answers, and the " <>
          "source and agent-reference vocabularies it reads are Prima's. " <>
          "Boundary's exports are global, and `Compendium` exports its two paths, " <>
          "`ConsentFacts`, `Providers.Component` and `Supervisor` beside its root to every " <>
          "boundary that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/emissary/**/*.ex",
        "apps/cyfr/lib/emissary.ex"
      ],
      into: "Aqua",
      allow: [],
      reason:
        "Emissary reaches the assistant only as operations through the gate " <>
          "(the `aqua` and thread tools); it names no function of the domain. " <>
          "Boundary traces a quote only where it expands, and `Emissary.Router.routes/0` " <>
          "expands in the composition router, whose deps admit `Aqua`: only this row reads " <>
          "the quoted names."
    },
    %{
      from: [
        "apps/cyfr/lib/emissary/**/*.ex",
        "apps/cyfr/lib/emissary.ex"
      ],
      into: "Crucible",
      allow: ~w(Crucible),
      reason:
        "Emissary follows executions, serves webhooks, keeps an outbound call's " <>
          "lease and reports health through the execution domain's root facade. " <>
          "Boundary's exports are global, and `Crucible` exports `Host.Children`, `Keys`, " <>
          "`Schedules.Scheduler` and `Supervisor` beside its root to every boundary that " <>
          "lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/prism/**/*.ex",
        "apps/cyfr/lib/prism.ex",
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex"
      ],
      into: "Crucible",
      allow: ~w(Crucible),
      reason:
        "the console reads executions, invokes tinctures and checks the executor " <>
          "through the execution domain's root facade under the caller's context, and " <>
          "names none of its internals. " <>
          "Boundary's exports are global, and `Crucible` exports `Host.Children`, `Keys`, " <>
          "`Schedules.Scheduler` and `Supervisor` beside its root to every boundary that " <>
          "lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/emissary/**/*.ex",
        "apps/cyfr/lib/emissary.ex"
      ],
      into: "Compendium",
      allow: ~w(Compendium),
      reason:
        "Emissary reaches the component domain's root facade alone: tinctures' files " <>
          "and data routes are its adapters, and they read a tincture's entry and " <>
          "declaration, what it invokes, the version an asset credential names, the " <>
          "served types and a document's policy and sandbox through it " <>
          "(`Compendium.tincture_asset_rules/0`, " <>
          "`Compendium.inspect_component/2`, `Compendium.tincture_csp/2`, " <>
          "`Compendium.tincture_sandbox_tokens/1`). Every component operation MCP serves " <>
          "is a gate operation, reached through the operation table. " <>
          "Boundary's exports are global, and `Compendium` exports its two paths, " <>
          "`ConsentFacts`, `Providers.Component` and `Supervisor` beside its root to every " <>
          "boundary that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/prism/**/*.ex",
        "apps/cyfr/lib/prism.ex",
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex"
      ],
      into: "Aqua",
      allow: ~w(Aqua),
      reason:
        "the console reads threads, approvals, attachments, notes, the virtual-tool " <>
          "catalogue and the reply stream through the assistant's root facade, and " <>
          "follows a thread on `Cyfr.Bus`. " <>
          "Boundary's exports are global, and `Aqua` exports `Supervisor` and `Text` beside " <>
          "its root to every boundary that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/prism/**/*.ex",
        "apps/cyfr/lib/prism.ex",
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex"
      ],
      into: "Compendium",
      allow: ~w(Compendium),
      reason:
        "the console reads components, agents, path grammars, the projection epoch " <>
          "and the registry's claim and legal pages through the component domain's " <>
          "root facade, and a registry refusal reaches it as a `%Prima.Refusal{}`; " <>
          "the publisher and version vocabularies it reads are Prima's. " <>
          "Boundary's exports are global, and `Compendium` exports its two paths, " <>
          "`ConsentFacts`, `Providers.Component` and `Supervisor` beside its root to every " <>
          "boundary that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/cyfr/**/*.ex",
        "apps/cyfr/lib/cyfr_web/**/*.ex",
        "apps/cyfr/lib/cyfr_web.ex"
      ],
      except: ["apps/cyfr/lib/cyfr/application.ex"],
      into: "Aqua",
      allow: [],
      reason:
        "the host names no domain: the bus, telemetry, runtime configuration and the " <>
          "web tier's glue sit below the domains, which reach them downward. The " <>
          "composition root (`Cyfr.Application`) names what it starts, and is " <>
          "excepted. " <>
          "The composition router and the endpoint this row reads are boundaries whose deps " <>
          "admit `Aqua`, and the shared tier's router macros expand in the first, so the " <>
          "compiler admits what this row refuses."
    },
    %{
      from: [
        "apps/cyfr/lib/cyfr/**/*.ex",
        "apps/cyfr/lib/cyfr_web/**/*.ex",
        "apps/cyfr/lib/cyfr_web.ex"
      ],
      except: ["apps/cyfr/lib/cyfr/application.ex"],
      into: "Compendium",
      allow: [],
      reason:
        "the host names nothing of the component domain: the seed offer " <>
          "(`Cyfr.SeedOffer`) runs the work the composition root hands it " <>
          "(`Compendium.sync_seeds/0`), and the composition root is excepted. " <>
          "The composition router and the endpoint this row reads are boundaries whose deps " <>
          "admit `Compendium`, and the shared tier's router macros expand in the first, so " <>
          "the compiler admits what this row refuses."
    },
    %{
      from: [
        "apps/cyfr/lib/cyfr/**/*.ex",
        "apps/cyfr/lib/cyfr_web/**/*.ex",
        "apps/cyfr/lib/cyfr_web.ex"
      ],
      except: ["apps/cyfr/lib/cyfr/application.ex"],
      into: "Crucible",
      allow: [],
      reason:
        "the host names nothing of execution: the member slot, the bus and the web " <>
          "tier's glue sit below it. The composition root (`Cyfr.Application`) starts " <>
          "execution's trees, and is excepted. " <>
          "The composition router and the endpoint this row reads are boundaries whose deps " <>
          "admit `Crucible`, and the shared tier's router macros expand in the first, so " <>
          "the compiler admits what this row refuses."
    },
    %{
      from: [
        "apps/cyfr/lib/cyfr/**/*.ex",
        "apps/cyfr/lib/cyfr_web/**/*.ex",
        "apps/cyfr/lib/cyfr_web.ex"
      ],
      except: [
        "apps/cyfr/lib/cyfr/application.ex",
        "apps/cyfr/lib/cyfr_web/router.ex",
        "apps/cyfr/lib/cyfr_web/endpoint.ex"
      ],
      into: "Emissary",
      allow: [],
      reason:
        "the host names nothing of the MCP surface: a surface sits above it and is " <>
          "wired only by the composition root (`Cyfr.Application`), which installs " <>
          "the proxied-tool port and starts the surface's trees, and is excepted. " <>
          "The composition router (`CyfrWeb.Router`, which invokes `Emissary.Router`) " <>
          "and the endpoint (`CyfrWeb.Endpoint`, whose parser wrapper answers `/mcp` " <>
          "in `Emissary.Web.MCPError`) are composition boundaries beside it, and are " <>
          "excepted too. " <>
          "Boundary traces a quote only where it expands, and `use CyfrWeb, :router` and " <>
          "`CyfrWeb.Pipelines`' macros expand in the composition router, whose deps admit " <>
          "`Emissary`: only this row reads the quoted names."
    },
    %{
      from: ["apps/cyfr/lib/compendium/**/*.ex"],
      except: [
        "apps/cyfr/lib/compendium/tincture/rules.ex",
        "apps/cyfr/lib/compendium/tincture_validator.ex"
      ],
      into: "Compendium.Tincture",
      depth: 3,
      only: ["Compendium.Tincture.Rules"],
      allow: [],
      reason:
        "the tincture frame's rules — served types, capabilities, the sandbox and " <>
          "allow map, the CSP, templates, the lockfile rule and the declaration grammar " <>
          "— are read by the publish check (`Compendium.TinctureValidator`) and by the " <>
          "root facade (`apps/cyfr/lib/compendium.ex`, outside this row's tree), and by " <>
          "nothing else of the domain, so no sandbox token or CSP directive is spelled " <>
          "twice. Every tree outside the domain is already held to the root facade by the " <>
          "rows above. Boundary checks between boundaries, and a module inside one is " <>
          "every other module's neighbour, so no declaration can say it."
    },
    %{
      from: ["apps/sanctum/lib/**/*.ex"],
      into: "Compendium",
      allow: [],
      reason:
        "everything consent reads about a component comes through the " <>
          "`Sanctum.Consent.Components` port, and the sign-in probe moved the other " <>
          "way: `Compendium.SignInSync` holds it and calls down. " <>
          "A foundation's build does not see the host's boundaries: its pruned code path " <>
          "makes a call an undefined-module warning that names no boundary, and a bare name " <>
          "compiles."
    },

    # --- the console and the web layer ---
    %{
      from: [
        "apps/cyfr/lib/prism/**/*.ex",
        "apps/cyfr/lib/prism.ex",
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex"
      ],
      into: "CyfrWeb",
      depth: 3,
      allow: ~w(
        CyfrWeb CyfrWeb.ContextGuard CyfrWeb.Endpoint CyfrWeb.MinimalPage CyfrWeb.PendingProbe
        CyfrWeb.Pipelines CyfrWeb.Plugs.ApiSecurityHeaders CyfrWeb.Plugs.AuthRateLimit
        CyfrWeb.Plugs.BrowserCSP CyfrWeb.Plugs.ConfiguredUeberauth CyfrWeb.Plugs.FrameRequest
        CyfrWeb.Plugs.Headless CyfrWeb.Router CyfrWeb.SafeRedirect CyfrWeb.SignInResponse
      ),
      reason:
        "the console reads the host's shared web tier and the composition triple its " <>
          "verified routes need, and never another adapter. Browser sign-in answers its " <>
          "refusals on the no-session page (`CyfrWeb.MinimalPage`) and runs the " <>
          "configured providers' strategy (`CyfrWeb.Plugs.ConfiguredUeberauth`). " <>
          "Building a copy-link's " <>
          "public URL reads a global fact off the endpoint, `PrismWeb.verified_routes/0` " <>
          "names the endpoint and the router beside `CyfrWeb.static_paths/0`, because " <>
          "that is the triple `use Phoenix.VerifiedRoutes` takes, and `Prism.Router` " <>
          "declares its pipelines from the shared browser definition and plugs, the " <>
          "glass's page's wider `connect-src` among them (`CyfrWeb.Plugs.BrowserCSP`). " <>
          "Boundary's exports are global, and `CyfrWeb` exports more of the shared tier than " <>
          "this roster to every surface that lists it, so no declaration can say it."
    },
    %{
      from: [
        "apps/cyfr/lib/prism/**/*.ex",
        "apps/cyfr/lib/prism.ex",
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex"
      ],
      into: "Emissary",
      allow: [],
      reason:
        "an adapter names no other surface: the console and Emissary's adapters meet " <>
          "only below them, in the host's shared web tier and the domains. The browser's " <>
          "sign-in callbacks share the OAuth callback throttle through the shared " <>
          "pipelines (`CyfrWeb.Pipelines`), not through Emissary's router. " <>
          "Boundary traces a quote only where it expands, and `Prism.Router.routes/0` expands " <>
          "in the composition router, whose deps admit `Emissary`: only this row reads the " <>
          "quoted names."
    },
    %{
      from: [
        "apps/prima/lib/**/*.ex",
        "apps/opus/lib/**/*.ex",
        "apps/locus/lib/**/*.ex",
        "apps/arca/lib/**/*.ex",
        "apps/cyfr/lib/compendium/**/*.ex",
        "apps/cyfr/lib/compendium.ex",
        "apps/sanctum/lib/**/*.ex",
        "apps/cyfr/lib/aqua/**/*.ex",
        "apps/cyfr/lib/aqua.ex"
      ],
      into: "Prism",
      allow: [],
      reason:
        "an engine does not depend on a user interface. A shared primitive both the " <>
          "engine and the console need lives in Prima, as `Prima.UUID7` does, or in " <>
          "the host's glue, as `Cyfr.Bus` does. " <>
          "Prima and the islands run no Boundary compiler, and a foundation's build does not " <>
          "see the host's boundaries: a call is an undefined-module warning that names none, " <>
          "and a bare name compiles."
    },
    %{
      from: [
        "apps/prima/lib/**/*.ex",
        "apps/opus/lib/**/*.ex",
        "apps/locus/lib/**/*.ex",
        "apps/arca/lib/**/*.ex",
        "apps/cyfr/lib/compendium/**/*.ex",
        "apps/cyfr/lib/compendium.ex",
        "apps/sanctum/lib/**/*.ex",
        "apps/cyfr/lib/aqua/**/*.ex",
        "apps/cyfr/lib/aqua.ex"
      ],
      into: "PrismWeb",
      allow: [],
      reason:
        "the console is two namespaces and an engine may name neither: `Prism` is " <>
          "its domain and `PrismWeb` its LiveViews, layouts and hooks. " <>
          "Prima and the islands run no Boundary compiler, and a foundation's build does not " <>
          "see the host's boundaries: a call is an undefined-module warning that names none, " <>
          "and a bare name compiles."
    },
    %{
      from: [
        "apps/prima/lib/**/*.ex",
        "apps/opus/lib/**/*.ex",
        "apps/locus/lib/**/*.ex",
        "apps/arca/lib/**/*.ex",
        "apps/sanctum/lib/**/*.ex",
        "apps/cyfr/lib/compendium/**/*.ex",
        "apps/cyfr/lib/compendium.ex",
        "apps/cyfr/lib/aqua/**/*.ex",
        "apps/cyfr/lib/aqua.ex"
      ],
      into: "CyfrWeb",
      allow: [],
      reason:
        "`CyfrWeb` is the web tier's own: the context guard, the plugs and the " <>
          "renderers the surfaces' adapters turn a domain's answer into an HTTP " <>
          "response with. A domain hands a " <>
          "surface plain data and a typed refusal and never names the adapter " <>
          "that renders it. " <>
          "Prima and the islands run no Boundary compiler, and a foundation's build does not " <>
          "see the host's boundaries: a call is an undefined-module warning that names none, " <>
          "and a bare name compiles."
    },
    %{
      from: ["apps/cyfr/lib/emissary/**/*.ex", "apps/cyfr/lib/emissary.ex"],
      into: "PrismWeb",
      allow: [],
      reason:
        "an adapter names no other surface: Emissary's adapters and the console meet " <>
          "only below them, in the host's shared web tier and the domains. The OAuth " <>
          "grant callback renders its own no-session page (`CyfrWeb.MinimalPage`) and " <>
          "the API's sign-out drops the cookie session through the shared sign-in " <>
          "response, so neither names the console's browser sign-in. " <>
          "Boundary traces a quote only where it expands, and `Emissary.Router.routes/0` " <>
          "expands in the composition router, whose deps admit `PrismWeb`: only this row " <>
          "reads the quoted names."
    },
    %{
      from: ["apps/cyfr/lib/emissary/**/*.ex", "apps/cyfr/lib/emissary.ex"],
      into: "CyfrWeb",
      depth: 3,
      allow: ~w(
        CyfrWeb.ApiError CyfrWeb.ContextGuard CyfrWeb.ErrorRenderer CyfrWeb.MinimalPage
        CyfrWeb.Pipelines CyfrWeb.Plugs.ApiSecurityHeaders CyfrWeb.Plugs.AuthRateLimit
        CyfrWeb.Plugs.Authenticate CyfrWeb.Plugs.CORS CyfrWeb.Plugs.CallIdentity
        CyfrWeb.Plugs.FrameRequest CyfrWeb.Plugs.MCPOrigin CyfrWeb.Plugs.MCPRateLimit
        CyfrWeb.Plugs.ScrubTinctureCredentials CyfrWeb.Plugs.TinctureRateLimit
        CyfrWeb.Plugs.VerifyWebhookSignature CyfrWeb.Plugs.WebhookIdempotency
        CyfrWeb.Plugs.WebhookRateLimit CyfrWeb.SSE CyfrWeb.SignInResponse
      ),
      reason:
        "Emissary's adapters read the host's shared web tier and never its root router, " <>
          "its endpoint or another adapter: the HTTP API renders its refusals " <>
          "(`CyfrWeb.ApiError`) and the OAuth grant callback its no-session page " <>
          "(`CyfrWeb.MinimalPage`), the API's sign-out drops the cookie session through " <>
          "the sign-in response (`CyfrWeb.SignInResponse`), and `Emissary.Router` " <>
          "declares the OAuth callback throttle from the shared pipelines " <>
          "(`CyfrWeb.Pipelines`). " <>
          "Boundary's exports are global, and `CyfrWeb` exports more of the shared tier than " <>
          "this roster to every surface that lists it, so no declaration can say it."
    },

    # --- the admission roster is the host's ---
    %{
      from: [
        "apps/prima/lib/**/*.ex",
        "apps/arca/lib/**/*.ex",
        "apps/sanctum/lib/**/*.ex",
        "apps/cyfr/lib/grimoire/**/*.ex",
        "apps/cyfr/lib/grimoire.ex",
        "apps/cyfr/lib/compendium/**/*.ex",
        "apps/cyfr/lib/compendium.ex",
        "apps/cyfr/lib/aqua/**/*.ex",
        "apps/cyfr/lib/aqua.ex",
        "apps/cyfr/lib/crucible/**/*.ex",
        "apps/cyfr/lib/crucible.ex",
        "apps/cyfr/lib/emissary/**/*.ex",
        "apps/cyfr/lib/emissary.ex",
        "apps/cyfr/lib/prism/**/*.ex",
        "apps/cyfr/lib/prism.ex",
        "apps/cyfr/lib/prism_web/**/*.ex",
        "apps/cyfr/lib/prism_web.ex"
      ],
      into: "Cyfr.Admission",
      allow: [],
      reason:
        "the admission paths are the host's roster (`Cyfr.Admission`, beside " <>
          "`admission_entries/0`): the composition root checks every listener against " <>
          "it at boot, so no domain, surface or foundation names it and a listener " <>
          "cannot admit itself. A foundation's build does not see the host's " <>
          "boundaries, and the host's boundary admits every domain, so no compiler " <>
          "refuses the reach."
    },

    # --- the security rows: Sanctum is their only reader ---
    %{
      from:
        for(%{lib: lib} <- @applications, lib not in @security_row_readers, do: lib <> "/**/*.ex"),
      into: "Arca",
      only: @sanctum_only_storage,
      allow: [],
      reason:
        "profiles, consents and their proofs, standing tool grants, vault entries, " <>
          "sessions, API keys, tincture frame credentials, paired clients, their " <>
          "pairing invitations and device certificates, registry push tokens, " <>
          "provider credentials, webhooks, " <>
          "the identities, memberships, athanors and doors that decide standing, a " <>
          "person's identity row, keys, attempts and carries, the directory's logs " <>
          "and cached heads, passkeys, pending confirmations, the installation claim, " <>
          "the pre-authentication rate windows, and the instance's own entries and " <>
          "their use counts " <>
          "are security rows. A domain or a surface learns about them only " <>
          "through Sanctum's entries, which scope by the caller's context and keep an " <>
          "outage, a damaged row and an absent one apart. Arca holds the rows and " <>
          "Sanctum reads them; no other tree names the stores. " <>
          "Boundary's exports are global and its membership is by name, so no declaration " <>
          "exports these stores to Sanctum alone."
    },

    # --- the host names neither island ---
    %{
      from: ["apps/cyfr/lib/**/*.ex"],
      into: "Opus",
      allow: [],
      reason:
        "`apps/cyfr/mix.exs` declares no dependency on `opus`: `Crucible` is " <>
          "the seam, and a run reaches a worker over `Prima.WorkerWire`. " <>
          "`Opus` is no boundary and `cyfr` does not depend on it: the pruned code path makes " <>
          "a call an undefined-module warning, and a bare name compiles."
    },
    %{
      from: ["apps/cyfr/lib/**/*.ex"],
      into: "Locus",
      allow: [],
      reason:
        "`apps/cyfr/mix.exs` declares no dependency on `locus`: `Prima.BuilderProtocol` " <>
          "is the seam, and CYFR reaches the builder over the build wire. " <>
          "`Locus` is no boundary and `cyfr` does not depend on it: the pruned code path " <>
          "makes a call an undefined-module warning, and a bare name compiles."
    }
  ]

  @doc """
  Every directed namespace reach this repository has decided on: where it
  is read from, the namespace it is into, the roster it may name and the
  reason the roster reads as it does.

  A row's `depth` is how many segments a reach is rostered by — two
  (`Sanctum.Context`) unless it says otherwise. A row's `only`, when it
  has one, narrows it to those namespaces under `into`: every other reach
  into `into` is some other row's business. A row's `except`, when it has
  one, lists globs of files under `from` the row does not read — a file
  the composition root owns, whose reaches another row decides. Every row
  is one the Boundary compiler cannot hold, and its reason ends saying why.
  """
  @spec surfaces() :: [map()]
  def surfaces, do: @surfaces

  @doc """
  The storage modules whose rows only Sanctum may read: the `only` of the
  surface row every `lib` tree but Sanctum's and Arca's is held to.
  """
  @spec sanctum_only_storage() :: [String.t()]
  def sanctum_only_storage, do: @sanctum_only_storage

  @doc """
  Which namespaces `named` reaches into, for a surface row: the reach
  truncated to the row's depth, so `Sanctum.Context.focus/2` is
  `Sanctum.Context`. A call on the root itself
  (`CyfrWeb.static_paths/0`) is the root.
  """
  @spec surface_reaches(map(), named()) :: MapSet.t(String.t())
  def surface_reaches(row, named) do
    depth = Map.get(row, :depth, 2)
    into = row.into
    only = Map.get(row, :only)

    for {_path, names} <- named,
        {module, _number} <- names,
        module == into or String.starts_with?(module, into <> "."),
        reach = module |> String.split(".") |> Enum.take(depth) |> Enum.join("."),
        is_nil(only) or reach in only,
        into: MapSet.new(),
        do: reach
  end

  @doc "The namespaces `named` reaches that the row's `allow` does not name."
  @spec surface_violations(map(), named()) :: [String.t()]
  def surface_violations(row, named) do
    row
    |> surface_reaches(named)
    |> MapSet.difference(MapSet.new(row.allow))
    |> Enum.sort()
  end

  @doc "The namespaces the row's `allow` names and `named` no longer reaches."
  @spec stale_surface_entries(map(), named()) :: [String.t()]
  def stale_surface_entries(row, named) do
    row.allow
    |> MapSet.new()
    |> MapSet.difference(surface_reaches(row, named))
    |> Enum.sort()
  end

  # The domain trees an HTTP type never enters, and what a line that names
  # one looks like: a module of `Plug`, or a `conn`.
  @http_free %{
    from: [
      "apps/cyfr/lib/compendium/**/*.ex",
      "apps/cyfr/lib/compendium.ex",
      "apps/cyfr/lib/aqua/**/*.ex",
      "apps/cyfr/lib/aqua.ex",
      "apps/sanctum/lib/sanctum/tincture_access.ex"
    ],
    pattern: ~r/\bPlug\.|\bconn\b/,
    reason:
      "a domain answers plain data and a typed refusal; the connection, the " <>
        "response and its headers are the surface adapter's. The tincture rules " <>
        "are Compendium's and the public tenancy Sanctum's, and neither takes a " <>
        "request or sends one. The compiler sees neither a `conn` binding nor a call " <>
        "into `Plug`, whose application no domain's `check: apps` lists."
  }

  @doc """
  The domain trees no line of which names an HTTP type: `from` is where to
  read, `pattern` what a line that names one matches.
  """
  @spec http_free() :: map()
  def http_free, do: @http_free

  @doc "The code lines in `scanned` that name an HTTP type, as `path:line: code`."
  @spec http_violations(scanned()) :: [String.t()]
  def http_violations(scanned) do
    for {path, lines} <- scanned,
        {line, n} <- lines,
        line =~ @http_free.pattern,
        do: "#{path}:#{n}: #{String.trim(line)}"
  end

  # The bus is the host's primitive every layer above it publishes through:
  # it names its own payloads, the actor and Phoenix, and nothing of the
  # identity domain, a domain or a surface — so no topic can come to
  # depend on who publishes or hears it.
  @bus_free %{
    from: ["apps/cyfr/lib/cyfr/bus.ex", "apps/cyfr/lib/cyfr/bus/**/*.ex"],
    roots: ~w(Sanctum Aqua Compendium Crucible Grimoire Emissary Prism PrismWeb CyfrWeb),
    namespaces: ~w(Crucible Crucible.Schedules),
    reason:
      "`Cyfr.Bus` owns every topic and payload and checks every publish against the " <>
        "actor it is handed; naming the identity domain, a domain or a surface would " <>
        "make the one shared carrier depend on its own publishers and subscribers. " <>
        "The roster names them as text (`Cyfr.Bus.topics/0`), which is not a reach. " <>
        "Boundary cannot hold this: the bus sits in the host's boundary, whose deps " <>
        "admit `Sanctum` and `Grimoire` for the rest of the host."
  }

  @doc """
  The bus's own tree and what it may not name: `from` is where to read,
  `roots` the product namespaces and `namespaces` the host's domain
  namespaces it stays clear of.
  """
  @spec bus_free() :: map()
  def bus_free, do: @bus_free

  @doc "Every name in `named` the bus may not reach, as `path:line names Module`."
  @spec bus_violations(named()) :: [String.t()]
  def bus_violations(named) do
    for {path, names} <- named,
        {module, number} <- names,
        forbidden_by_bus?(module),
        uniq: true,
        do: "#{path}:#{number} names #{module}"
  end

  defp forbidden_by_bus?(module) do
    (module |> String.split(".") |> hd()) in @bus_free.roots or
      Enum.any?(@bus_free.namespaces, &(module == &1 or String.starts_with?(module, &1 <> ".")))
  end

  # The gate sits below the domains and the surfaces it dispatches for: it
  # reaches providers through the operation table and the transport's
  # proxied tools through `Grimoire.Proxy`, so it names neither. Each
  # allowed reach is exact, names the owner it moves to, and is reported
  # stale the day the gate stops making it.
  @gate_free %{
    from: ["apps/cyfr/lib/grimoire.ex", "apps/cyfr/lib/grimoire/**/*.ex"],
    roots: ~w(Emissary Aqua Compendium Crucible Prism PrismWeb CyfrWeb),
    allow: [],
    reason:
      "the operation table dispatches for every domain and surface; naming one " <>
        "would make the gate depend on what it gates. Proxied tools reach it " <>
        "through `Grimoire.Proxy`, which `Cyfr.Application` installs. The gate's " <>
        "boundary refuses each of these edges; this roster also reads an alias " <>
        "directive and a quoted name, which Boundary does not trace."
  }

  @doc """
  The gate's own tree and what it may not name: `from` is where to read,
  `roots` the domain and surface namespaces it stays clear of, and
  `allow` the exact reaches still moving to their `owner`.
  """
  @spec gate_free() :: map()
  def gate_free, do: @gate_free

  @doc "Every name in `named` the gate may not reach, as `path:line names Module`."
  @spec gate_violations(named()) :: [String.t()]
  def gate_violations(named) do
    allowed = MapSet.new(@gate_free.allow, & &1.name)

    for {path, names} <- named,
        {module, number} <- names,
        (module |> String.split(".") |> hd()) in @gate_free.roots,
        not MapSet.member?(allowed, module),
        uniq: true,
        do: "#{path}:#{number} names #{module}"
  end

  @doc "The allowed reaches `named` no longer makes."
  @spec stale_gate_allowances(named()) :: [String.t()]
  def stale_gate_allowances(named) do
    reached =
      for {_path, names} <- named, {module, _number} <- names, into: MapSet.new(), do: module

    for %{name: name} <- @gate_free.allow, not MapSet.member?(reached, name), do: name
  end

  # What the host application calls of the identity domain, function by
  # function. The namespace rows above say which Sanctum namespaces a tree
  # may name; this says which functions of them `apps/cyfr/lib` calls at
  # all, so the domain's export set is a reviewed list rather than whatever
  # is public. The compiled beams are its reader: a call the host starts
  # making without a row here fails, and a row nothing calls any longer is
  # reported stale. Boundary checks modules, never functions.
  @sanctum_exports %{
    "Sanctum" => [
      auth_configured?: 0,
      build_tincture_context: 2,
      internal_context: 1,
      origin: 0,
      public_url: 0,
      reconcile_platform_admins: 2,
      system_context: 0
    ],
    "Sanctum.ApiKey" => [default_scopes: 1, looks_like_key?: 1, valid_scopes: 1],
    "Sanctum.Atoms" => [known_permissions: 0],
    "Sanctum.Attach" => [resolve: 5],
    "Sanctum.Auth" => [provider: 0],
    "Sanctum.Auth.CyfrDoor" => [
      callback: 2,
      carry_lifetime_ms: 0,
      challenge: 1,
      redirect_url: 1,
      signing_home: 1
    ],
    "Sanctum.Auth.DeviceFlow" => [configured_providers: 0, impl: 0, provider?: 1, providers: 0],
    "Sanctum.Auth.EmailVerification" => [verify_with_claim: 3],
    "Sanctum.Auth.Identity" => [reserved_issuer?: 1],
    "Sanctum.Auth.OIDC" => [issuer: 0, reauth_callback: 1, reauth_decide: 3],
    "Sanctum.Authority" => [guard_invoke: 1, release_invoke: 1, step: 3, take_over_invoke: 2],
    "Sanctum.Authority.BudgetCounter" => [release: 1],
    "Sanctum.BearerToken" => [read: 1],
    "Sanctum.Caller" => [
      drop_memo: 1,
      establish: 2,
      establish_context: 1,
      fresh?: 1,
      peek: 1,
      revalidate_session: 1
    ],
    "Sanctum.Carry" => [sweep: 1],
    "Sanctum.Cipher" => [keyring!: 0],
    "Sanctum.Cipher.Rotation" => [audit: 0, reencrypt_all: 1],
    "Sanctum.ClientIp" => [from_connect_info: 1, resolve: 1],
    "Sanctum.Consent" => [head_consent: 2, profiles: 2, revoke_source: 2, row_binding: 3],
    "Sanctum.Consent.Authz" => [
      authorize_interactive: 1,
      authorize_interactive_in_chain: 1,
      authorize_staging: 1
    ],
    "Sanctum.Consent.Components" => [install!: 1],
    "Sanctum.Consent.Loader" => [load_root: 3, pinned_intact?: 2],
    "Sanctum.Consent.Proof" => [store: 0],
    "Sanctum.Consent.RegistrationBinding" => [authorize: 3, message: 1],
    "Sanctum.Consent.ShapeDerivation" => [expand_tools: 1, live_digest: 2, manifest_blocks: 2],
    "Sanctum.Consent.ShapeDiff" => [compute: 3],
    "Sanctum.Context" => [
      actor: 1,
      athanor!: 1,
      authorize: 2,
      authorize: 3,
      build: 1,
      enter_guest: 1,
      focus: 2,
      for_scheduled: 2,
      has_permission?: 2,
      internal: 1,
      refocus: 2,
      require_permission: 2,
      require_permission: 3,
      require_tenant!: 1
    ],
    "Sanctum.DeviceCerts" => [verify_connect: 3, verify_request: 3],
    "Sanctum.Directory" => [append: 2, outcome: 1, recover: 2, register: 1, resolve: 1],
    "Sanctum.Door" => [admit_identity: 2, platform_admin_emails: 0, refusal_message: 0],
    "Sanctum.Door.Store" => [requests: 0],
    "Sanctum.Egress" => [pinned_request: 5],
    "Sanctum.ExecutionStanding" => [capture: 1, retired_attempts: 3, stamp_only: 1, verify: 1],
    "Sanctum.Grimoire" => [install!: 1],
    "Sanctum.InstanceEntries" => [sweep_usage: 0],
    "Sanctum.Namespace" => [lookup_status: 1],
    "Sanctum.Network" => [pin: 2, validate_redirect_url: 2],
    "Sanctum.Notify" => [broadcast: 3],
    "Sanctum.Pairing" => [actions: 0, can_confirm?: 1],
    "Sanctum.Passkeys" => [sign_in: 2, sign_in_challenge: 0],
    "Sanctum.Policy.Enforcement" => [record: 1],
    "Sanctum.Provisioning" => [
      athanor: 1,
      await_claim: 5,
      bootstrap_consents: 2,
      bootstrap_consents_for: 3,
      bounded_work: 3,
      fill_event: 0,
      filled_athanors: 0,
      hold: 3,
      holding: 2,
      lost: 1,
      mark_filled: 1,
      ready: 1,
      record_failure: 4,
      release: 2,
      seed_ctx: 1,
      settle: 4,
      start_provisioning: 1,
      take_claim: 2,
      under_claim: 3
    ],
    "Sanctum.Recovery" => [reproof: 2, restore: 2, restore_challenge: 1],
    "Sanctum.RegistryCredentials" => [delete: 3, get: 3, list: 2, put_push_token: 6],
    "Sanctum.Session" => [cleanup: 0, create: 1, destroy: 1, get: 1],
    "Sanctum.SignIn" => [admitted: 2, link_ticket: 2, record_namespace: 2, suggested_slug: 2],
    "Sanctum.Tenancy" => [
      channel_active?: 2,
      continuation: 3,
      list_athanors: 1,
      resolve_status: 2,
      revalidate: 1
    ],
    "Sanctum.Tenancy.Athanors" => [
      active?: 1,
      by_route_slug: 1,
      get: 1,
      list_active: 0,
      provisioning_failure: 1,
      route_slug: 1,
      settings: 1
    ],
    "Sanctum.Tenancy.Members" => [list_by_athanor: 1, member?: 2, solo?: 1],
    "Sanctum.Tenancy.Users" => [
      display_name: 1,
      get: 1,
      own_athanor?: 2,
      personal_athanor_id: 1,
      prefs: 1,
      put_prefs: 2
    ],
    "Sanctum.TinctureAccess" => [get_private: 3, get_public: 3, public_context: 1],
    "Sanctum.TinctureAuth" => [
      mint_asset_credential: 2,
      mint_frame_credential: 5,
      resume_frame: 2,
      revoke_frame: 2,
      suspend_frame: 2,
      verify_asset_credential: 2
    ],
    "Sanctum.ToolGrants" => [
      admits?: 2,
      check_standing: 2,
      for_thread: 2,
      grant_row: 2,
      put: 2,
      revoke: 2
    ],
    "Sanctum.ToolServerDigest" => [
      descriptions_digest: 2,
      from_server: 1,
      normalize_input_schema: 1,
      tool_patterns: 1
    ],
    "Sanctum.Unauthorized" => [class: 1, code_override: 1, message: 1, message: 2, reason?: 1],
    "Sanctum.Vault" => [destination_matches?: 3, disclosed?: 2],
    "Sanctum.Vault.OAuthGrant" => [complete: 3, redirect_uri: 0],
    "Sanctum.VaultReader" => [
      fetch: 3,
      oauth_token: 4,
      revisions: 2,
      unseal_disclosed: 2,
      unseal_for: 3,
      usable: 3
    ],
    "Sanctum.Webhook" => [
      decode_input_template: 1,
      default_signature_header: 0,
      disable_for_component: 2,
      resolve_ingress: 1,
      verify_with_grace: 4
    ]
  }

  @doc """
  Every Sanctum function the host application's `lib` calls, as the
  namespace module to its sorted `{function, arity}` list: remote calls
  and external captures (`&Sanctum.Egress.pinned_request/5`) alike. A
  typespec or a struct pattern is not a call and is not listed.
  """
  @spec sanctum_exports() :: %{String.t() => [{atom(), non_neg_integer()}]}
  def sanctum_exports, do: @sanctum_exports

  @typedoc "A remote function as the compiled scan reads it: module name, function, arity."
  @type reach :: {String.t(), atom(), non_neg_integer()}

  @doc "The Sanctum functions `reaches` holds that the roster does not, as `Module.function/arity`."
  @spec sanctum_export_violations([reach()]) :: [String.t()]
  def sanctum_export_violations(reaches) do
    rostered = rostered_sanctum_exports()

    reaches
    |> Enum.filter(fn {module, _function, _arity} -> sanctum_module?(module) end)
    |> Enum.reject(&MapSet.member?(rostered, &1))
    |> Enum.map(&reach_label/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The rostered Sanctum functions `reaches` no longer holds, as `Module.function/arity`."
  @spec stale_sanctum_exports([reach()]) :: [String.t()]
  def stale_sanctum_exports(reaches) do
    reached = MapSet.new(reaches)

    rostered_sanctum_exports()
    |> Enum.reject(&MapSet.member?(reached, &1))
    |> Enum.map(&reach_label/1)
    |> Enum.sort()
  end

  defp rostered_sanctum_exports do
    for {module, functions} <- @sanctum_exports,
        {function, arity} <- functions,
        into: MapSet.new(),
        do: {module, function, arity}
  end

  defp sanctum_module?(module), do: module == "Sanctum" or String.starts_with?(module, "Sanctum.")

  defp reach_label({module, function, arity}), do: "#{module}.#{function}/#{arity}"

  # ---------------------------------------------------------------------------
  # 3. The routes
  # ---------------------------------------------------------------------------

  @route_postures %{
    authenticate_plug: %{
      admits: :credential,
      why: "a bearer-credential plug on the pipeline resolves the caller before the controller"
    },
    webhook_hmac: %{
      admits: :credential,
      why: "the sender's HMAC over the raw body, verified on the pipeline"
    },
    handler_auth: %{
      admits: :credential,
      why: "the controller self-gates, answering 401 or 400 without a token"
    },
    tincture_handler_auth: %{
      admits: :credential,
      why:
        "resolved in the tincture controller: a public tincture's address admits " <>
          "anyone to its files; a private tincture version's files (`/_s/`) admit the " <>
          "asset credential in their path, verified on every request " <>
          "(`Sanctum.TinctureAuth.verify_asset_credential/2`) and redacted from the " <>
          "request path by `CyfrWeb.Plugs.ScrubTinctureCredentials`. No " <>
          "session cookie: a tincture page is embeddable cross-origin, and an ambient " <>
          "cookie credential on a cross-origin surface is the CSRF food the design refuses"
    },
    frame_credential: %{
      admits: :credential,
      why:
        "the tincture data routes: a frame's per-open credential as a bearer, established " <>
          "at every request (`Sanctum.Caller.establish({:frame_credential, bearer}, …)`) " <>
          "and held to the tincture version and grant it names, or a public tincture's " <>
          "page naming a tincture whose public profile admits it. No session cookie and " <>
          "no CSRF token: the bearer is the only credential, and the `null` origin of a " <>
          "sandboxed frame is answered on these routes alone"
    },
    browser_authenticated: %{
      admits: :session,
      why:
        "the `:athanor` live_session's on_mount pair: `CyfrWeb.ContextGuard` requires " <>
          "a session and keeps it current, and `PrismWeb.Focus` narrows the context to " <>
          "the URL's athanor"
    },
    browser_focus_handler: %{
      admits: :session,
      why:
        "the session cookie for who, the URL's athanor for where, focused in the " <>
          "controller exactly as a LiveView mount focuses it"
    },
    public_oauth_state: %{
      admits: :flow_state,
      why: "the OAuth state token the callback carries is the credential"
    },
    browser_oauth_callback: %{
      admits: :flow_state,
      why: "the IdP's callback, gated by the state token the kickoff issued"
    },
    browser_oauth_flow: %{
      admits: :flow_state,
      why: "a device-flow ticket or a post-acceptance hop, each single-use and consumed on lookup"
    },
    browser_cyfr_callback: %{
      admits: :flow_state,
      why:
        "the `cyfr` door's callback: a person assertion over the challenge this home keeps " <>
          "in the browser's own session cookie, posted with the browser pipeline's CSRF " <>
          "token, verified under the person's head read fresh from the directory their " <>
          "genesis names, and redeemed once through its login receipt " <>
          "(`Sanctum.Auth.CyfrDoor`)"
    },
    browser_claim_gate: %{
      admits: :flow_state,
      why:
        "the publisher-namespace claim page and its throttled submit, gated by the " <>
          "pending sign-in probe the session holds — expired, the page says so and " <>
          "sends the caller back to sign in"
    },
    browser_public_legal: %{
      admits: :flow_state,
      why:
        "renders the bundled policies and relays an acceptance, under the same " <>
          "pending sign-in the claim gate reads"
    },
    public_health: %{
      admits: :nothing,
      why: "a load balancer's probe, throttled per address"
    },
    browser_public_login: %{
      admits: :nothing,
      why: "the sign-in page, which is what an anonymous caller comes for"
    },
    browser_public_auth: %{
      admits: :nothing,
      why:
        "the sign-out post drops whatever session the browser has and needs none to " <>
          "be told to; POST and not GET, so the browser pipeline's CSRF token guards it"
    },
    browser_oauth_start: %{
      admits: :nothing,
      why: "starts an IdP round trip and carries nothing of the caller into it"
    },
    public_directory: %{
      admits: :nothing,
      why:
        "the identity directory's reads and a genesis registration, which any caller may " <>
          "make: a log is public history, and a genesis names its own keys and is its own " <>
          "identifier. No session; every request is bounded per source and per installation"
    },
    directory_signed: %{
      admits: :credential,
      why:
        "a directory entry or recovery, signed by a key the identifier's verified chain " <>
          "authorizes and verified against that chain before anything is written; no session"
    },
    device_key_proof: %{
      admits: :credential,
      why:
        "a certified device's renewal at its person's home: the device key's proof over a " <>
          "renewal challenge this home issued for a certification it recorded, under the " <>
          "person's current `key_epoch` (`Sanctum.RemoteCertification`); no session or cookie " <>
          "is read, and CORS answers any origin with no credentials, since the proof is the " <>
          "only credential"
    },
    installation_capability: %{
      admits: :credential,
      why:
        "the restore ingress: the installation capability (`CYFR_RESTORE_TOKEN`) as the " <>
          "authorization header, checked in constant time before any kit is read, any key " <>
          "staged or any outbound call made (`Sanctum.Recovery`); no session and no CSRF " <>
          "token, since no cross-site form sets the header and no CORS answer admits one"
    },
    browser_session: %{
      admits: :session,
      why:
        "the browser's own cookie session, established and revalidated in the controller, " <>
          "with the browser pipeline's CSRF token on the POST; no athanor, since what it " <>
          "starts (linking a door) is the person's own"
    }
  }

  @public_routes [
    {:get, "/api/health"},
    {:get, "/api/health/ready"},
    {:get, "/auth/:provider"},
    {:post, "/auth/logout"},
    {:get, "/directory/v1/:identifier"},
    {:get, "/directory/v1/:identifier/requests/:request_id"},
    {:post, "/directory/v1/genesis"},
    {:get, "/login"},
    {:get, "/pair"},
    {:get, "/restore"}
  ]

  @doc """
  Every auth posture a route may declare, what admits a caller to it, and
  why.

  The posture itself is declared where the route is
  (`metadata: %{auth: …}` in its provider), so it travels with the
  route and a deleted route takes its posture with it. What lives here is
  the vocabulary.

  `admits` is the tier: `:credential`, a token or signature the caller
  presented; `:session`, the browser's own cookie; `:flow_state`, a
  single-use token or pending sign-in the server itself issued, which
  authenticates the step and nothing else; and `:nothing`, a route
  reachable by anyone, whose routes are rostered one by one in
  `public_routes/0`. A posture is route metadata, a term no compiler
  checks.
  """
  @spec route_postures() :: %{
          atom() => %{
            required(:admits) => atom(),
            required(:why) => String.t()
          }
        }
  def route_postures, do: @route_postures

  @doc "The postures that admit a caller who presented nothing at all."
  @spec public_postures() :: [atom()]
  def public_postures, do: for({p, %{admits: :nothing}} <- @route_postures, do: p)

  @doc """
  Every route anyone can reach, as `{verb, path}`.

  A new one fails `Cyfr.BoundariesTest` until it is named here: a route
  must not become reachable by anyone through inheriting a pipeline. A
  route's reach is data in the route table, which no compiler reads.
  """
  @spec public_routes() :: [{atom(), String.t()}]
  def public_routes, do: @public_routes

  # Every posture, public-roster and `route_info` consumer reads the route
  # table through this one name, so splitting the route providers and
  # changing the root router are each made here, in one place.
  @router CyfrWeb.Router

  @doc "The composition router: the one module whose table is every HTTP route."
  @spec router() :: module()
  def router, do: @router

  # The route providers the composition router invokes, so another cannot
  # appear silently: each hands its routes to the root by macro.
  @routers [Emissary.Router, Prism.Router]

  @doc "The route providers whose routes the composition router's table holds."
  @spec routers() :: [module()]
  def routers, do: @routers

  @doc "The total route table, `router/0`'s `__routes__/0`."
  @spec routes() :: [map()]
  def routes, do: @router.__routes__()

  @doc """
  What is wrong with `routes`, a router's `__routes__/0`: a route with no
  declared posture, a posture outside the vocabulary, or a public route
  the roster does not name.
  """
  @spec route_violations([map()]) :: [String.t()]
  def route_violations(routes) do
    Enum.flat_map(routes, fn route ->
      where = "#{route.verb} #{route.path}"

      case route.metadata[:auth] do
        nil ->
          ["#{where}: no declared auth posture (add `metadata: %{auth: …}`)"]

        posture when is_map_key(@route_postures, posture) ->
          if posture in public_postures() and {route.verb, route.path} not in @public_routes,
            do: ["#{where}: declares the public posture #{inspect(posture)} and is not rostered"],
            else: []

        other ->
          ["#{where}: auth posture #{inspect(other)} is not in the vocabulary"]
      end
    end)
  end

  @doc "The rostered public routes no route in `routes` declares any more."
  @spec stale_public_routes([map()]) :: [{atom(), String.t()}]
  def stale_public_routes(routes) do
    live = MapSet.new(routes, &{&1.verb, &1.path})
    Enum.reject(@public_routes, &MapSet.member?(live, &1))
  end

  # ---------------------------------------------------------------------------
  # 4. The configuration schema
  # ---------------------------------------------------------------------------

  @config_key_classes %{
    # Test seams — see `Sanctum.Auth.DeviceFlow.impl/0` for the rule.
    allow_tenancy_resolver_override: :seam,
    tenancy_resolver_override: :seam,
    tool_providers_lenient: :seam,
    thread_recovery: :seam,
    device_flow: :seam,
    device_flow_endpoints: :seam,
    provisioning_inline: :seam,
    record_sink_inline: :seam,
    # The issuer's side of an OpenID Connect re-authentication
    # (`Sanctum.Auth.OIDC`): a test stands in its own for the token
    # exchange, as `device_flow` does for the device flow's.
    oidc_reauth_client: :seam,
    # The directory client's resolver and trusted certificates
    # (`Sanctum.Directory.Client`), which a suite sets to reach its
    # scripted directory through paths that pass no options; a caller's
    # options win, and a release never sets it, so it uses the system's.
    directory_client: :seam,
    # An OAuth provider shown to attenuate a refresh (`Sanctum.Vault.OAuth`):
    # a suite sets it to script a preset for a hint no shipped preset holds,
    # and that preset's token endpoint, never replacing a shipped one; a
    # release never sets it, so only the shipped presets are read.
    scripted_oauth_provider: :seam,
    # Compiled in by `config/test.exs` alone; with the runtime switch off it
    # lets the sandboxed suite boot omit `Cyfr.Bootstrap`
    # (`Cyfr.Application.bootstrap_skipped?/2`).
    bootstrap_skip_permitted: :seam,
    # Compiled in by the test configurations alone — `config/test.exs` and,
    # for the standalone build, `apps/sanctum/config/config.exs` — as
    # `:allow_tenancy_resolver_override` is; it lets a fixture hand an
    # issuance a generation snapshot read from the rows (`Sanctum.Issuance`),
    # which every release refuses.
    issuance_snapshot_permitted: :seam,

    # Boot switches with an in-code default; flipping one is a code change.
    cron_scheduler_enabled: :default,
    execution_sweeper_enabled: :default,
    execution_archive_watch_enabled: :default,
    worker_watch_enabled: :default,
    external_server_reconciler_enabled: :default,
    provisioning_boot_enabled: :default,
    retention_scheduler_enabled: :default,
    control_plane_claim_enabled: :default,
    control_plane_pool: :default,
    write_turn: :default,
    database_checks_enabled: :default,
    telemetry_console_enabled: :default,

    # The at-rest keyring: `Cyfr.Application` resolves it at boot, from
    # `CYFR_CRYPTO_KEYRING` (which `runtime.exs` reads into
    # `:cyfr, :crypto_keyring_json`) or derived from the master secret, and
    # writes it here. A real lever, reached through the boot rather than a
    # config file, which is why no file the umbrella reads declares it —
    # the standalone Sanctum suite, which has no host to resolve one,
    # carries a keyring of its own.
    crypto_keyring: :operator,

    # Operator-shaped, with nothing to set them from. Each has a sensible
    # in-code default, so this is a gap in reach, not a broken deployment.
    oci_max_blob_bytes: :missing_lever,
    webhook_max_body_bytes: :missing_lever,
    platform_ceiling: :missing_lever,
    registry_scheme: :missing_lever
  }

  @test_only_config_key_classes %{
    namespace_cache_ttl_ms: :seam,
    # A one-time confirmation code's transport
    # (`Sanctum.Auth.EmailVerification`): the tree ships none, so only the
    # suite sets one, its capture sink; with none the email method refuses
    # `:email_unavailable`.
    confirmation_code_transport: :seam,
    # The registry probe's switch, read by `Compendium.Provider.status/0`.
    registry_health_probe: :seam,

    # `TinctureRateLimit`'s own moduledoc calls this an override an operator
    # sets, and only the suite can set it.
    tincture_rate_limit_max: :missing_lever
  }

  @doc """
  What every application key the code reads and no configuration file
  declares is.

  Four classes: `:operator`, a real lever `config/runtime.exs` reads a
  `CYFR_*` variable into; `:default`, a value the code owns; `:seam`, a
  test hook deliberately not published in `runtime.exs`; and
  `:missing_lever`, a knob that reads like an operator's and has no
  variable to set it with — the honest record of the gap, not an
  endorsement. A key is an atom read at runtime, which no compiler sees.
  A fifth class, `:setting`, is the platform settings' and is computed
  from their roster (`config_key_classes/1`).
  """
  @spec config_key_classes() :: %{atom() => atom()}
  def config_key_classes, do: @config_key_classes

  @doc """
  `config_key_classes/0` with the platform settings' keys classed
  `:setting`: the head of each configuration path in `settings`, the
  `{application, key}` pairs `Cyfr.Platform.Settings.Roster.config_keys/0`
  answers, under the schema's applications.

  The caller reads the roster and hands it in: this catalog is a boundary
  of its own beside the host's and names none of the host's modules, so
  the class is computed where the roster can be read, and held equal to it
  there, rather than copied here as a second list.
  """
  @spec config_key_classes([{atom(), atom()}]) :: %{atom() => atom()}
  def config_key_classes(settings) when is_list(settings) do
    for {app, key} <- settings,
        app in config_applications(),
        into: @config_key_classes,
        do: {key, Map.get(@config_key_classes, key, :setting)}
  end

  @doc "The same, for keys only `config/test.exs` declares."
  @spec test_only_config_key_classes() :: %{atom() => atom()}
  def test_only_config_key_classes, do: @test_only_config_key_classes

  @doc """
  The applications whose keys this schema covers. Alphabetical, which also
  keeps a three-atom list beginning `:cyfr` out of the tree — the
  telemetry roster reads one as an event name.
  """
  @spec config_applications() :: [atom()]
  def config_applications, do: [:arca, :cyfr, :sanctum]

  @config_keys_read_by_name %{}

  @config_keys_read_outside_lib %{
    default_test_namespace:
      "read by the Sanctum suite's context fixture, in `apps/sanctum/test/support`. " <>
        "The schema reads each application's `lib` alone: widening it to test " <>
        "support would change what it means — keys the application reads becomes " <>
        "keys anything reads — and pull in every fixture's own reads with it."
  }

  @doc """
  The keys no code reads by a literal `Application.get_env(:app, :key)` —
  each is read under a key the caller computes, and a scan of the source
  cannot see it. The honest record of them, so a key nothing reads at all
  is not mistaken for one of these.
  """
  @spec config_keys_read_by_name() :: %{atom() => String.t()}
  def config_keys_read_by_name, do: @config_keys_read_by_name

  @doc """
  The keys a configuration file sets that nothing under any `lib` reads,
  and why each is set anyway.
  """
  @spec config_keys_read_outside_lib() :: %{atom() => String.t()}
  def config_keys_read_outside_lib, do: @config_keys_read_outside_lib

  @doc """
  The keys `declared` names under an application that `scanned` never
  reads under that application.

  A configuration file that sets `:arca, :some_key` while the code reads
  `:cyfr, :some_key` sets nothing: the umbrella build reads the root
  file, an application's own build reads its own, and a key in the wrong
  one of them is inert in both. A name-keyed roster cannot see it, because
  by name the key is declared.
  """
  @spec unread_config_keys(named_keys :: [{atom(), atom()}], scanned()) :: [{atom(), atom()}]
  def unread_config_keys(declared, scanned) do
    read = config_pairs_read(scanned)

    declared
    |> Enum.reject(fn {_app, key} ->
      Map.has_key?(@config_keys_read_by_name, key) or
        Map.has_key?(@config_keys_read_outside_lib, key)
    end)
    |> Enum.reject(&MapSet.member?(read, &1))
    |> Enum.sort()
  end

  @config_pair ~r/Application\.(?:get_env|fetch_env!?|compile_env!?)\(\s*:([a-z_]+),\s*:([a-z_0-9]+)/

  @doc "Every `{application, key}` pair `scanned` reads by a literal name."
  @spec config_pairs_read(scanned()) :: MapSet.t({atom(), atom()})
  def config_pairs_read(scanned) do
    for {_path, lines} <- scanned,
        code = Enum.map_join(lines, "\n", &elem(&1, 0)),
        [app, key] <- Regex.scan(@config_pair, code, capture: :all_but_first),
        into: MapSet.new(),
        do: {String.to_atom(app), String.to_atom(key)}
  end

  @doc "Every key of this repository's three applications that `scanned` reads."
  @spec config_keys_read(scanned()) :: MapSet.t(atom())
  def config_keys_read(scanned) do
    for {app, key} <- config_pairs_read(scanned),
        app in config_applications(),
        into: MapSet.new(),
        do: key
  end

  @doc """
  The keys `scanned` reads that no configuration file declares and this
  schema does not classify.

  `declared` is `%{key => [file, …]}`.
  """
  @spec config_violations(scanned(), %{atom() => [String.t()]}) :: [atom()]
  def config_violations(scanned, declared) do
    scanned
    |> config_keys_read()
    |> Enum.filter(fn key ->
      Map.get(declared, key, []) == [] and not Map.has_key?(@config_key_classes, key)
    end)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # 5. The ports, and the behaviours that are not ports
  # ---------------------------------------------------------------------------

  # Each port is installed the one way: its declaring module's
  # `install!/1` writes `{Module, :impl}` into `:persistent_term`, its
  # `impl!/0` reads it and raises `Module.NotInstalledError` when nothing
  # was written, and `Cyfr.Application.start/2` is the one caller of
  # `install!/1`, from literals, before its supervisor starts.
  @boot_writer "Cyfr.Application"
  @boot_file "apps/cyfr/lib/cyfr/application.ex"

  @ports [
    %{
      behaviour: "Prima.Caps",
      what: "the storage and counted cap decision",
      declared_by: :prima,
      implemented_by: "Sanctum.Tenancy.Caps",
      written_at_boot_by: @boot_writer
    },
    %{
      behaviour: "Sanctum.Grimoire",
      what: "consent's view of the operation table",
      declared_by: :sanctum,
      implemented_by: "Grimoire.Catalog",
      written_at_boot_by: @boot_writer
    },
    %{
      behaviour: "Sanctum.Consent.Components",
      what: "component facts for consent",
      declared_by: :sanctum,
      implemented_by: "Compendium.ConsentFacts",
      written_at_boot_by: @boot_writer
    },
    %{
      behaviour: "Grimoire.Proxy",
      what: "proxied tool resolution",
      declared_by: :cyfr,
      implemented_by: "Emissary.External.Proxy",
      written_at_boot_by: @boot_writer
    },
    %{
      behaviour: "Arca.Storage.UnitLocator",
      what: "where a storage unit's bytes live",
      declared_by: :arca,
      implemented_by: "Compendium.ComponentPath and Compendium.AquaPath",
      written_at_boot_by: @boot_writer
    }
  ]

  @internal_strategies [
    %{
      behaviour: "Sanctum.Consent.Proof",
      reason:
        "two adapters inside Sanctum — `Proof.DB`, which calls `Arca.ConsentProofStorage` " <>
          "downward, and `Proof.Memory`, which tests need because it forgets. The same " <>
          "shape as Arca's Local and S3 adapters, not a cross-layer port."
    },
    %{
      behaviour: "Sanctum.Auth",
      reason:
        "declared and implemented inside Sanctum (`auth/oauth.ex`, `auth/oidc.ex`) and " <>
          "selected by configuration. An internal strategy behaviour, not a port."
    }
  ]

  @doc """
  The five ports of `ARCHITECTURE.md`, and only these. A sixth is an
  architecture change. A port's implementation is written at boot and read
  from `:persistent_term`, so Boundary sees no edge from the declaring
  module to it.
  """
  @spec ports() :: [map()]
  def ports, do: @ports

  # The admission entries: every site that decides a request before, or
  # instead of, the gate, and so records the decision itself. Each row is
  # the deciding module, the function (a plug's `call/2`, a controller
  # action, a gate head, a server's message handler), the plane its
  # refusals are recorded on, and the origin of the context it builds
  # (`Prima.Origin`): `:inherits` for an in-chain entry, whose context
  # carries its root's, and `:none` for one that builds no context.
  # `CyfrWeb.Plugs.CallIdentity` is not a row: it mints the identity and
  # decides nothing. Which function decides is behaviour, not a reference,
  # so no compiler sees it.
  @admission_entries [
    # The gate's heads: refusals made before its own checks and identity.
    # The external head takes the context its surface built.
    %{module: Grimoire, site: :call_external, plane: :external, origin: :none},
    %{module: Grimoire, site: :call_in_chain, plane: :in_chain, origin: :inherits},
    # The gate's stream entry: an open is decided and recorded there, and
    # MCP `subscriptions/listen` admits through it.
    %{module: Grimoire, site: :open_stream, plane: :external, origin: :none},
    # The JSON-RPC router's pre-gate refusals: a request naming no tool or
    # an unknown one, a read naming no resource, an unknown method.
    %{module: Emissary.MCP.Router, site: :dispatch, plane: :external, origin: :programmatic},
    # The MCP transport: a batch, a method the endpoint does not serve, an
    # authorization refusal raised in the request process.
    %{module: Emissary.Web.MCPController, site: :handle, plane: :external, origin: :none},
    %{
      module: Emissary.Web.MCPController,
      site: :method_not_allowed,
      plane: :external,
      origin: :none
    },
    # The MCP pipeline's plugs, after routing. The authenticating plug
    # builds the context of the HTTP API and MCP, whatever credential it
    # holds.
    %{module: CyfrWeb.Plugs.Authenticate, site: :call, plane: :external, origin: :programmatic},
    %{module: CyfrWeb.Plugs.FrameRequest, site: :call, plane: :external, origin: :none},
    %{module: CyfrWeb.Plugs.MCPOrigin, site: :call, plane: :external, origin: :none},
    %{module: CyfrWeb.Plugs.MCPRateLimit, site: :call, plane: :external, origin: :none},
    %{
      module: Emissary.Web.Plugs.MCPRequestMetadata,
      site: :call,
      plane: :external,
      origin: :none
    },
    # The endpoint's ownership plug: a stale owner refusing is an admission
    # refusal, class not_owner.
    %{
      module: CyfrWeb.Plugs.ControlPlaneOwnership,
      site: :call,
      plane: :external,
      origin: :none
    },
    # The tincture routes: a tincture the address does not resolve, and the
    # routes' rate limit.
    %{module: Emissary.Web.TinctureController, site: :index, plane: :external, origin: :none},
    %{module: CyfrWeb.Plugs.TinctureRateLimit, site: :call, plane: :external, origin: :none},
    # The tincture data routes: a request with no frame credential and no
    # public tincture, a credential that no longer stands, an undeclared
    # operation or stream, and the per-frame limits. A frame's call is an
    # interactive admission.
    %{
      module: Emissary.Web.TinctureDataController,
      site: :invoke,
      plane: :external,
      origin: :interactive
    },
    %{
      module: Emissary.Web.TinctureDataController,
      site: :system_action,
      plane: :external,
      origin: :interactive
    },
    %{
      module: Emissary.Web.TinctureDataController,
      site: :stream,
      plane: :external,
      origin: :interactive
    },
    # The webhook route: the caller the row establishes, its signature,
    # its idempotency key and its rate limit.
    %{module: Emissary.Web.WebhookController, site: :invoke, plane: :external, origin: :webhook},
    %{
      module: CyfrWeb.Plugs.VerifyWebhookSignature,
      site: :call,
      plane: :external,
      origin: :none
    },
    %{module: CyfrWeb.Plugs.WebhookIdempotency, site: :call, plane: :external, origin: :none},
    %{module: CyfrWeb.Plugs.WebhookRateLimit, site: :call, plane: :external, origin: :none},
    # The execution-events stream: an execution the caller may not read (or
    # that does not exist), an unauthenticated caller, and the stream limit.
    %{
      module: Emissary.Web.ExecutionEventsController,
      site: :stream,
      plane: :external,
      origin: :none
    },
    # The scheduler's fire: its own admission is the occurrence claimed
    # under a held generation, and a run admission refusal is that fire's
    # failed completion.
    %{
      module: Crucible.Schedules.Scheduler,
      site: :handle_info,
      plane: :external,
      origin: :schedule
    },
    # The HostAPI's in-chain entry: a tool call whose attempt refuses it
    # before any chain exists.
    %{module: Crucible.Host.Children, site: :call, plane: :in_chain, origin: :inherits},
    # The device channel: a paired device's connection proof and each
    # discrete intent it sends, a person acting on an interactive surface.
    %{
      module: Emissary.Web.DeviceChannel,
      site: :handle_in,
      plane: :external,
      origin: :interactive
    }
  ]

  @typedoc """
  The origin an admission entry gives the context it builds: a
  `Prima.Origin`, `:inherits` for an in-chain entry, whose context carries
  its root's, or `:none` for one that builds no context.
  """
  @type admission_origin :: Prima.Origin.t() | :inherits | :none

  @doc """
  The admission entries: every site that decides a request before, or
  instead of, the gate, and records the decision itself — one
  `%{module, site, plane, origin}` row per entry. Host owns the roster;
  the seam test drives each row to its refusal and finds exactly one
  decision.
  """
  @spec admission_entries() :: [
          %{
            required(:module) => module(),
            required(:site) => atom(),
            required(:plane) => :external | :in_chain,
            required(:origin) => admission_origin()
          }
        ]
  def admission_entries, do: @admission_entries

  @doc """
  The behaviours Sanctum declares that are not ports: named internal
  strategies, declared and implemented inside the application.
  """
  @spec internal_strategies() :: [map()]
  def internal_strategies, do: @internal_strategies

  @doc "Every behaviour name Sanctum may declare — a port's, or an internal strategy's."
  @spec sanctum_behaviours() :: [String.t()]
  def sanctum_behaviours do
    ports = for p <- @ports, p.declared_by == :sanctum, p.behaviour != nil, do: p.behaviour
    Enum.sort(ports ++ Enum.map(@internal_strategies, & &1.behaviour))
  end

  @doc """
  Each port's one installation: the call that writes its implementation
  and the file it is written in, as `{behaviour, call, file}`, in the
  order the boot writes them.
  """
  @spec boot_writes() :: [{String.t(), String.t(), Path.t()}]
  def boot_writes,
    do: for(p <- @ports, do: {p.behaviour, p.behaviour <> ".install!(", @boot_file})

  # ---------------------------------------------------------------------------
  # 6. The actor construction paths
  # ---------------------------------------------------------------------------

  @actor_paths [
    %{
      path: "Sanctum.Context.actor/1",
      file: "apps/sanctum/lib/sanctum/context.ex",
      reason:
        "the projection of an established context, and the only way a request's " <>
          "actor is made. `scope` travels as it stands and `system` is " <>
          "`auth_method == :system`; a hand-assembled actor could claim either."
    },
    %{
      path: "Prima.Actor.system/0",
      file: "apps/prima/lib/prima/actor.ex",
      reason:
        "the control plane acting as itself, for work no caller asked for. It carries " <>
          "no tenant and no person, and its authority is the `system` flag rather than " <>
          "a credential someone presented."
    },
    %{
      path: "Prima.Actor.in_athanor/1",
      file: "apps/prima/lib/prima/actor.ex",
      reason:
        "row work inside one athanor for a caller established by other means than a " <>
          "context — a MAC-verified host call naming its attempt, a schedule's own " <>
          "occurrence row, a recovery scan already narrowed to one athanor. The " <>
          "athanor and nothing else: `scope: :athanor`, `system: false`."
    },
    %{
      path: "Sanctum.VaultReader.tenant_actor/1",
      file: "apps/sanctum/lib/sanctum/vault_reader.ex",
      reason:
        "private, and inside the layer that owns tenancy: `usable/3`, `unseal_for/3` " <>
          "and `unseal_disclosed/2` are reached by host-side callers that hold a " <>
          "resolved tenant and no context. It names the tenant it was already given " <>
          "and widens nothing."
    }
  ]

  @doc """
  Every way a `%Prima.Actor{}` is constructed in production code, with the
  reason for each.

  There are four. Each is defensible and in the right layer, and four is
  how you get six — so a fifth is argued for here before it appears.
  """
  @spec actor_paths() :: [map()]
  def actor_paths, do: @actor_paths

  # ---------------------------------------------------------------------------
  # 6b. The system responsibilities
  # ---------------------------------------------------------------------------

  @system_responsibilities [
    %{
      responsibility: "retire execution work under its stored grant",
      modules: ~w(
        Sanctum.ExecutionStanding Crucible.Record Crucible.Lapse
        Crucible.Cascade Crucible.Sweeper Crucible.TurnRoot
        Emissary.External.Proxy Aqua.Tape
      ),
      check: "Sanctum.ExecutionStanding.stamp_only/1",
      reason:
        "a failure, a cancel, a lease lapse and the sweep's cancellation of an " <>
          "archived athanor's work end an admitted execution without asking whether " <>
          "its grant still stands: the attempt must carry the grant's stored stamp " <>
          "and be the current one, and the member must hold its slot, but retiring " <>
          "work its athanor no longer admits is exactly when these run. None of them " <>
          "can report success, and none can write over a successor's attempt. A " <>
          "completion, new output, a renewal, a resume and a recovery each need the " <>
          "grant to stand (`Sanctum.ExecutionStanding.verify/1`)."
    },
    %{
      responsibility: "resolve an inbound webhook delivery's slug before any caller is known",
      modules: ~w(
        Sanctum.Webhook CyfrWeb.Plugs.WebhookRateLimit
        CyfrWeb.Plugs.VerifyWebhookSignature
      ),
      check: "Sanctum.Webhook.resolve_ingress/1",
      reason:
        "a webhook delivery authenticates by its signature, not by a caller: the slug " <>
          "it is posted to is the only thing that names the row, so the lookup reads " <>
          "across tenants by that one indexed column, and the athanor every later step " <>
          "is scoped by is the one read off the row. The rate limiter reads it to pick " <>
          "a bucket and the signature plug to verify. Its secrets are opened only by " <>
          "that verification, and the function that opens them leaves the connection " <>
          "once it is done."
    },
    %{
      responsibility: "probe that storage still takes a write, before any caller is known",
      modules: ~w(Emissary.Web.HealthController Arca),
      check: "Arca.Storage.authorize_path/2",
      reason:
        "the readiness probe is anonymous and asks whether the store still takes a " <>
          "write, so it runs before any caller is known and in no athanor: `ready/2` " <>
          "puts one fixed key under the global `system/` root " <>
          "(`Emissary.Web.HealthController.probe_dir/0`) and deletes it again, under " <>
          "the platform's internal context, whose system actor is the only kind " <>
          "`Arca.Storage.authorize_path/2` opens a global root to. `Arca` runs that " <>
          "check on every put and delete. The probe names no tenant path and reads " <>
          "nothing back, and its one key means a stranded write is overwritten, never " <>
          "accumulated."
    },
    %{
      responsibility: "reconcile storage projections before any caller is known",
      modules: ~w(Arca.StorageProjectionChanges Compendium.ProjectionReconciler),
      check: "Arca.StorageProjectionChanges.pending_athanors/2",
      reason:
        "the component registry and the agent index must catch up with a change whose " <>
          "writer died or whose notification was lost, and nobody is asking yet: the " <>
          "reconciler's recovery reads, under the platform-scope actor alone, which " <>
          "athanors hold a seeded root whose projection is behind its epoch — one column of " <>
          "the root rows and nothing of any tenant's content. Every athanor it names is " <>
          "then reconciled inside that athanor's own context, and every replacement is " <>
          "checked against the generations it read, so a recovery can do no more than a " <>
          "reader of that athanor would."
    },
    %{
      responsibility:
        "apply each active athanor's retention policy on the cell's cadence, with no caller",
      modules: ~w(Cyfr.RetentionScheduler),
      check: "Arca.Retention.cleanup_athanor/2",
      reason:
        "retention deletes what each athanor's own settings say it no longer keeps, and " <>
          "nobody asks for it: the scheduler, holding the cell's retention claim and its " <>
          "slot, walks the athanors the identity domain names active, asks again before " <>
          "each, and hands the storage layer one actor per athanor — the server's, narrowed " <>
          "to that athanor, reading and writing storage and nothing else. The storage " <>
          "layer refuses any other actor, and refuses the whole athanor when its settings " <>
          "are corrupt or cannot be read. An archived athanor is passed over, so its " <>
          "records freeze with it."
    },
    %{
      responsibility: "Host purges null-tenant decision rows under its held claim",
      modules: ~w(Cyfr.RetentionScheduler),
      check: "Arca.DecisionLog.purge_global/2",
      reason:
        "a decision refused before any caller or tenant was established is appended " <>
          "with no athanor, so no athanor's retention reaches it and no tenant reads it: " <>
          "the scheduler's `decisions_global` step, holding the cell's retention claim " <>
          "and its slot, deletes those rows once they are older than " <>
          "CYFR_DECISION_RETENTION_DAYS. The storage layer takes only the platform's own " <>
          "system actor for it and matches only rows without an athanor, so the purge " <>
          "can reach no athanor's decisions, which go with the athanor or its own policy."
    }
  ]

  @doc """
  Every write the server makes on work whose standing it does not
  require, and every read it makes before any caller is known, with the
  modules that make it, the check they pass in place of the standing one,
  and why. A new one is argued for here before it appears. Boundary admits
  a system-scope call like any other: what it may do is the check, not the
  edge.
  """
  @spec system_responsibilities() :: [map()]
  def system_responsibilities, do: @system_responsibilities

  # ---------------------------------------------------------------------------
  # 7. What the suites may name
  # ---------------------------------------------------------------------------

  @opus_named_by_cyfr_tests %{
    "apps/cyfr/test/integration/**" =>
      "the wiring suite: the umbrella runs one VM and these " <>
        "cases are integration tests of CYFR against a real worker service.",
    "apps/cyfr/test/support/opus_service.ex" =>
      "starts and stops the in-VM worker service the integration suite runs against.",
    "apps/cyfr/test/support/sandbox.ex" =>
      "drains the runner pool between cases, which is the only way a pooled runner " <>
        "holding a sandbox connection is released before the next test.",
    "apps/cyfr/test/cyfr/test_sandbox_test.exs" =>
      "the sandbox helper's own case: what it drains IS the pool, so the assertion " <>
        "has to name it.",
    "apps/cyfr/test/crucible/start_refusal_test.exs" =>
      "the refusal a keeper gives is `Opus.Keeper.Channel.refusal/1`'s shape, and this " <>
        "case holds CYFR's rendering of it to that shape.",
    "apps/cyfr/test/grimoire/error_renderers_test.exs" =>
      "the in-chain guest's renderer is Opus's, and the one-vocabulary case is that " <>
        "the three renderers agree sentence for sentence.",
    "apps/cyfr/test/cyfr/runtime_env_reading_test.exs" =>
      "pins the shape of the reads in `config/runtime.exs`, and that file configures " <>
        "the `opus` release too: what it names, this case quotes.",
    "apps/cyfr/test/cyfr/platform_settings_roster_test.exs" =>
      "holds the inventory of every name a boot reads, and the `opus` release declares " <>
        "its own prefix (`Opus.Settings.variables/0`): an opus boot's refusal of a stray " <>
        "name is `Opus.Settings.unknown/1`'s, and this case quotes it.",
    "apps/cyfr/test/cyfr/wit_abi_drift_test.exs" =>
      "names `Opus.Runtime` in the sentence its failure prints, so a reader is told " <>
        "which side of the ABI to look at."
  }

  @doc """
  Which CYFR test files may name an Opus module, and why.

  `apps/cyfr/mix.exs` declares no dependency on `opus`, and `apps/cyfr/lib`
  names no Opus module — that is the production boundary. The suite is
  another matter: the umbrella loads both applications into one VM, and
  the integration suite's whole job is CYFR against a real worker
  service. So a CYFR test MAY name an Opus module, from the wiring suite
  and the support that starts it, and everywhere else by a row here.
  """
  @spec opus_named_by_cyfr_tests() :: %{String.t() => String.t()}
  def opus_named_by_cyfr_tests, do: @opus_named_by_cyfr_tests

  # ---------------------------------------------------------------------------
  # 8. The filesystem seam
  # ---------------------------------------------------------------------------

  @filesystem_seam %{
    owner: "Arca.Storage",
    from: "apps/*/lib/**/*.ex",
    exempt: ["*/arca/adapters/*", "apps/arca/lib/arca/storage.ex"],
    entire_module: ~r/arca:bypass-ok=[A-E] — entire module/,
    marker: "arca:bypass-ok",
    window: 4,
    call:
      ~r/(^|[^A-Za-z0-9_.])File\.[a-z]|Path\.wildcard|(^|[^A-Za-z0-9_]):(file|filelib|erl_tar|prim_file)\./,
    reason:
      "file and blob I/O goes through `Arca.Storage`, so the local filesystem and a " <>
        "configured object store behave alike. A direct call fits one of the bypass " <>
        "groups `Arca.Storage` documents and names it: the marker on the call's line " <>
        "or within the window above it, or once for a module whose every call is " <>
        "sandbox or compile-time work. The adapters and the behaviour itself are the " <>
        "seam, not callers of it. A filesystem call is a call into Elixir and OTP, " <>
        "which no boundary declares or refuses."
  }

  @typedoc """
  A scanned tree with each file's text beside its code lines, as
  `{path, source, code_lines}`. The seam's marker is usually a comment,
  which the code-line view drops, so the marker is read from the text and
  the calls from the code lines.
  """
  @type texts :: [{Path.t(), String.t(), [{String.t(), pos_integer()}]}]

  @doc """
  The storage seam: every file under `from` whose path matches no
  `exempt` pattern (`*` spans any characters, `/` included, as in a shell
  `case`) and whose text carries no `entire_module` marker makes a direct
  filesystem call — a code line `call` matches — only with `marker` on
  that line or on one of the `window` lines above it.
  """
  @spec filesystem_seam() :: map()
  def filesystem_seam, do: @filesystem_seam

  @doc "Whether the seam exempts the whole file, by where it is or by what it says."
  @spec filesystem_exempt?(Path.t(), String.t()) :: boolean()
  def filesystem_exempt?(path, source) do
    Enum.any?(@filesystem_seam.exempt, &shell_match?(&1, path)) or
      source =~ @filesystem_seam.entire_module
  end

  @doc """
  The direct filesystem calls in `tree` that no marker covers, each
  rendered as `path:line: code`.
  """
  @spec filesystem_violations(texts()) :: [String.t()]
  def filesystem_violations(tree) do
    %{call: call, marker: marker, window: window} = @filesystem_seam

    for {path, source, lines} <- tree,
        not filesystem_exempt?(path, source),
        marked = marked_lines(source, marker),
        {line, n} <- lines,
        line =~ call,
        not Enum.any?((n - window)..n//1, &MapSet.member?(marked, &1)),
        do: "#{path}:#{n}: #{String.trim(line)}"
  end

  @doc """
  The exemptions the row names that exempt no file in `tree`: each
  `exempt` pattern no path matches, and the `entire_module` marker's
  pattern when no file carries it.
  """
  @spec stale_filesystem_exemptions(texts()) :: [String.t()]
  def stale_filesystem_exemptions(tree) do
    %{exempt: exempt, entire_module: entire_module} = @filesystem_seam

    patterns =
      for pattern <- exempt,
          not Enum.any?(tree, fn {path, _source, _lines} -> shell_match?(pattern, path) end),
          do: pattern

    marked? = Enum.any?(tree, fn {_path, source, _lines} -> source =~ entire_module end)
    if marked?, do: patterns, else: patterns ++ [Regex.source(entire_module)]
  end

  # Numbered as `Prima.Test.CodeLines` numbers them: 1-based, split on "\n".
  defp marked_lines(source, marker) do
    for {text, n} <- source |> String.split("\n") |> Enum.with_index(1),
        String.contains?(text, marker),
        into: MapSet.new(),
        do: n
  end

  defp shell_match?(pattern, path) do
    body = pattern |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.match?(Regex.compile!("\\A" <> body <> "\\z"), path)
  end
end
