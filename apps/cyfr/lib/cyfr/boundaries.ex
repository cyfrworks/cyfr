# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Boundaries do
  @moduledoc """
  The one catalog of the architectural boundaries this repository holds
  itself to, and the pure checks that read a tree against it.

  Eight roster tests used to hold these, each scanning the tree its own
  way and each carrying its own copy of what a layer is. The rows are
  here now, and `Cyfr.BoundariesTest` is the one reader: it plants a
  violation of each kind and shows it reported, and it refuses a scan
  that read nothing, because a roster that stops reading passes every
  assertion it makes.

  Four kinds of row, and three registers beside them:

    * `applications/0` — what each umbrella application may depend on, as
      its `mix.exs` declares it, and the layer each module namespace sits
      in. This is the dependency check: `arca` names nothing above the
      contracts, `sanctum` nothing above Arca, the host names neither
      island, and each island names nothing of the control plane.
    * `surfaces/0` — the directed reaches inside an application, which a
      dependency graph cannot express: which Sanctum namespaces the
      console may name, what the auth domain may name of the transport,
      what reaches back up into the component domain.
    * `route_postures/0` and `public_routes/0` — how every HTTP route is
      authenticated. The posture travels with the route
      (`EmissaryWeb.Router` declares it as route metadata); this catalog
      owns the vocabulary and the roster of routes that are public by
      design.
    * `config_key_classes/0` — the configuration schema: every
      application key the code reads that no configuration file declares,
      and what each one is.

  And the registers:

    * `ports/0` and `internal_strategies/0` — the five ports of
      `AGENTS.md`, and the two behaviours Sanctum declares that are not
      ports.
    * `actor_paths/0` — every way a `%Cyfr.Actor{}` is constructed, with
      the reason for each. Four is how you get six.
    * `opus_named_by_cyfr_tests/0` — which CYFR test files may name an
      Opus module, and why.

  Every check here takes a tree already read through
  `Cyfr.Test.CodeLines`, the one line filter, so a name in prose is never
  taken for a dependency. The rules live here; the filter is the reader's,
  which is what keeps a catalog that ships in `lib` off the test support.
  """

  # ---------------------------------------------------------------------------
  # 1. The applications
  # ---------------------------------------------------------------------------

  @typedoc "A layer of the dependency graph, or `:outside` for everything else."
  @type layer :: :contracts | :arca | :sanctum | :host | :opus | :locus | :outside

  @applications [
    %{
      app: :cyfr_contracts,
      layer: :contracts,
      lib: "apps/cyfr_contracts/lib",
      umbrella_deps: [],
      note: "pure contracts: wire shapes, behaviours, primitives, the actor"
    },
    %{
      app: :arca,
      layer: :arca,
      lib: "apps/arca/lib",
      umbrella_deps: [:cyfr_contracts],
      note: "persistence, at the bottom of the graph"
    },
    %{
      app: :sanctum,
      layer: :sanctum,
      lib: "apps/sanctum/lib",
      umbrella_deps: [:arca, :cyfr_contracts],
      note: "identity, tenancy, authority, consent and the vault, over Arca's rows"
    },
    %{
      app: :cyfr,
      layer: :host,
      lib: "apps/cyfr/lib",
      umbrella_deps: [:arca, :cyfr_contracts, :sanctum],
      note:
        "the host and everything above it. It declares neither island: " <>
          "`Cyfr.Execution` is the seam to Opus and `Cyfr.BuilderProtocol` to Locus"
    },
    %{
      app: :opus,
      layer: :opus,
      lib: "apps/opus/lib",
      umbrella_deps: [:cyfr_contracts],
      note: "the WASM engine island; it reaches CYFR over its host API alone",
      dependency_roots: ~w(Jason Req Plug Bandit Wasmex)
    },
    %{
      app: :locus,
      layer: :locus,
      lib: "apps/locus/lib",
      umbrella_deps: [:cyfr_contracts],
      note: "the builds island; CYFR reaches it over the build wire alone",
      dependency_roots: ~w(Jason Plug Bandit ThousandIsland)
    }
  ]

  @doc """
  Every umbrella application, the layer it is, the `lib` tree its code
  lives in, and the umbrella dependencies its `mix.exs` may declare.

  The dependency rule falls out of the list: an application may name a
  module of its own layer, of the layers its declared dependencies are,
  and of nothing else product-side.
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
  # from one of Elixir, OTP or a fetched dependency.
  @product_roots ~w(
    Arca Sanctum Aqua Compendium Crucible Emissary EmissaryWeb Grimoire
    Prism PrismWeb Cyfr Opus Locus Codex
  )

  @doc "The namespace roots this repository owns."
  @spec product_roots() :: [String.t()]
  def product_roots, do: @product_roots

  @doc """
  The layer a module name sits in.

  `contracts` is the set of module names the contracts application
  defines, read from the tree rather than listed here: `Cyfr.Actor` is a
  contract and `Cyfr.Ops.Catalog` is the host's, and only the tree knows
  which is which.
  """
  @spec layer(String.t(), MapSet.t(String.t())) :: layer()
  def layer(module, contracts) do
    cond do
      MapSet.member?(contracts, module) -> :contracts
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
  it names them on, as `Cyfr.Test.CodeLines.aliases/1` returns them.

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
  The one file every source scan skips: this catalog, which names each
  namespace it rosters and would report itself as a reach into all of
  them. Nothing else is skipped, and the compiled scan — which reads what
  the compiler emitted rather than what a line says — covers this file
  with no exception at all.
  """
  @spec scan_exclusions() :: [Path.t()]
  def scan_exclusions, do: ["apps/cyfr/lib/cyfr/boundaries.ex"]

  # ---------------------------------------------------------------------------
  # 2. The surfaces
  # ---------------------------------------------------------------------------

  @surfaces [
    # --- the auth domain's callers, each crossing the licence boundary ---
    %{
      from: ["apps/cyfr/lib/aqua/**/*.ex"],
      into: "Sanctum",
      allow: ~w(Sanctum Sanctum.Context Sanctum.Notify Sanctum.Provisioning Sanctum.Tenancy),
      reason:
        "`Sanctum.Provisioning` is `Aqua.AgentConfig`'s two in-process agent reads " <>
          "alone — the first-need hook: a turn reads its estate's tree in-process " <>
          "now rather than through the `aqua` tool, and the bundle a group estate " <>
          "is filled with on first read has to be there before the turn roots an " <>
          "authority in it."
    },
    %{
      from: ["apps/cyfr/lib/compendium/**/*.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.Cipher Sanctum.CipherAAD Sanctum.Consent Sanctum.Context
        Sanctum.Namespace Sanctum.Provisioning Sanctum.SignIn Sanctum.VaultReader
      ),
      reason:
        "`Sanctum.Provisioning` is the first-need hook and the half of filling an " <>
          "estate that is identity's: the claim it runs under, the baseline consents, " <>
          "the readiness and failure writes on the row. `Compendium.Provisioning` owns " <>
          "the component work and calls down into it."
    },
    %{
      from: ["apps/cyfr/lib/cyfr/**/*.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.Atoms Sanctum.Auth Sanctum.Authority Sanctum.Catalog Sanctum.Cipher
        Sanctum.Consent Sanctum.Context Sanctum.Door Sanctum.Notify
        Sanctum.Policy Sanctum.PubSub Sanctum.Session
        Sanctum.Tenancy Sanctum.ToolServerDigest Sanctum.Unauthorized
        Sanctum.UnauthorizedError Sanctum.VaultReader
      ),
      reason:
        "the glue and application namespace: boot wiring, the operation table, " <>
          "admission, the invoke budget, the vault edge a run is attached with, and " <>
          "the policy record of every admission. `Sanctum` bare is the domain's own " <>
          "front door — `internal_context/1` and `system_context/0` mint the contexts " <>
          "the server's own work runs under, `auth_configured?/0` says whether this " <>
          "deployment has sign-in, and `build_tincture_context/2` is the tincture " <>
          "surface's. A call on the root is a reach like any other and is rostered " <>
          "like one; no roster before this one could see it."
    },
    %{
      from: ["apps/cyfr/lib/emissary/**/*.ex", "apps/cyfr/lib/emissary.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.Context Sanctum.ToolServerDigest Sanctum.Unauthorized
        Sanctum.VaultReader
      ),
      reason: "the MCP transport carries the tenancy and reads a server's vault edge"
    },
    %{
      from: ["apps/cyfr/lib/emissary_web/**/*.ex", "apps/cyfr/lib/emissary_web.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum Sanctum.ApiKey Sanctum.Auth Sanctum.BearerToken Sanctum.Caller
        Sanctum.ClientIp Sanctum.Context Sanctum.Door Sanctum.Session Sanctum.SignIn
        Sanctum.Tenancy Sanctum.TinctureAccess Sanctum.TinctureAuth
        Sanctum.Unauthorized Sanctum.UnauthorizedError Sanctum.Vault Sanctum.Webhook
      ),
      reason: "the auth fabric's own ingress — a wide roster is the front door doing its job"
    },
    %{
      from: ["apps/cyfr/lib/prism/**/*.ex", "apps/cyfr/lib/prism.ex"],
      into: "Sanctum",
      allow: ~w(Sanctum Sanctum.Context Sanctum.Notify Sanctum.Tenancy),
      reason: "console domain code: the tenancy carrier and the tray's vocabulary"
    },
    %{
      from: ["apps/cyfr/lib/prism_web/**/*.ex", "apps/cyfr/lib/prism_web.ex"],
      into: "Sanctum",
      allow: ~w(
        Sanctum.ApiKey Sanctum.Auth Sanctum.Caller Sanctum.ClientIp
        Sanctum.Context Sanctum.Door Sanctum.Notify Sanctum.Session Sanctum.SignIn
        Sanctum.Tenancy Sanctum.TinctureAuth Sanctum.Webhook
      ),
      reason:
        "`Sanctum.ClientIp` is `PrismWeb.AuthHelpers.socket_client_ip/1` alone: the " <>
          "`/live` socket is handled by the endpoint BEFORE the router, so it passes " <>
          "no rate-limit plug, which makes the console the only per-address bound on " <>
          "the anonymous device flows it starts."
    },
    %{
      from: ["apps/cyfr/lib/compendium/**/*.ex"],
      into: "Sanctum.Consent",
      depth: 3,
      allow: ~w(Sanctum.Consent.Components Sanctum.Consent.ShapeDerivation),
      reason:
        "the consent WRITE plane stays behind Sanctum's own surface: the estate " <>
          "filler mints its baseline consents through `Sanctum.Provisioning`, never " <>
          "`Sanctum.Consent.Bootstrap`. `Sanctum.Consent.Components` is the " <>
          "component-facts port — naming a behaviour one implements is the opposite " <>
          "of reaching into the write plane."
    },

    # --- what the layers below name of the layers above ---
    %{
      from: ["apps/sanctum/lib/**/*.ex"],
      into: "Emissary",
      allow: [],
      reason:
        "a foundation below the host emits `:telemetry` and never broadcasts, so the " <>
          "PubSub server's own name — the last thing the auth domain knew about the " <>
          "transport — is the host bridge's now."
    },
    %{
      from: ["apps/arca/lib/**/*.ex"],
      into: "Compendium",
      allow: [],
      reason:
        "the overlay's locators were wired through `Arca.Storage.UnitLocator` so the " <>
          "storage layer would not compile against the component domain; the closed " <>
          "`source` roster it enforces on write is `Cyfr.ComponentSource` now."
    },
    %{
      from: ["apps/sanctum/lib/**/*.ex"],
      into: "Compendium",
      allow: [],
      reason:
        "everything consent reads about a component comes through the " <>
          "`Sanctum.Consent.Components` port, and the sign-in probe moved the other " <>
          "way: `Compendium.SignInSync` holds it and calls down."
    },

    # --- the console and the web layer ---
    %{
      from: ["apps/cyfr/lib/prism_web/**/*.ex", "apps/cyfr/lib/prism_web.ex"],
      into: "EmissaryWeb",
      allow: ~w(EmissaryWeb EmissaryWeb.Endpoint EmissaryWeb.Router),
      reason:
        "one direction only. Building a copy-link's public URL reads a global fact " <>
          "off the endpoint, and `PrismWeb.verified_routes/0` names the endpoint, the " <>
          "router and `EmissaryWeb.static_paths/0`, because that is the triple " <>
          "`use Phoenix.VerifiedRoutes` takes."
    },
    %{
      from: [
        "apps/cyfr_contracts/lib/**/*.ex",
        "apps/opus/lib/**/*.ex",
        "apps/locus/lib/**/*.ex",
        "apps/arca/lib/**/*.ex",
        "apps/cyfr/lib/compendium/**/*.ex",
        "apps/sanctum/lib/**/*.ex",
        "apps/cyfr/lib/aqua/**/*.ex"
      ],
      into: "Prism",
      allow: [],
      reason:
        "an engine does not depend on a user interface. A shared primitive both the " <>
          "engine and the console need is glue and belongs under `Cyfr.` — that is " <>
          "what `Cyfr.Bus` and `Cyfr.UUID7` are."
    },
    %{
      from: [
        "apps/cyfr_contracts/lib/**/*.ex",
        "apps/opus/lib/**/*.ex",
        "apps/locus/lib/**/*.ex",
        "apps/sanctum/lib/**/*.ex",
        "apps/cyfr/lib/aqua/**/*.ex",
        "apps/cyfr/lib/compendium/**/*.ex"
      ],
      into: "EmissaryWeb",
      allow: [],
      reason:
        "Emissary — the MCP contract — is the engines' honest dependency; the " <>
          "endpoint, the router and the plugs are not. The auth domain reads key " <>
          "material and the public origin from configuration, not from the endpoint."
    },

    # --- the host names neither island ---
    %{
      from: ["apps/cyfr/lib/**/*.ex"],
      into: "Opus",
      allow: [],
      reason:
        "`apps/cyfr/mix.exs` declares no dependency on `opus`: `Cyfr.Execution` is " <>
          "the seam, and a run reaches a worker over `Cyfr.WorkerWire`."
    },
    %{
      from: ["apps/cyfr/lib/**/*.ex"],
      into: "Locus",
      allow: [],
      reason:
        "`apps/cyfr/mix.exs` declares no dependency on `locus`: `Cyfr.BuilderProtocol` " <>
          "is the seam, and CYFR reaches the builder over the build wire."
    }
  ]

  @doc """
  Every directed namespace reach this repository has decided on: where it
  is read from, the namespace it is into, the roster it may name and the
  reason the roster reads as it does.

  A row's `depth` is how many segments a reach is rostered by — two
  (`Sanctum.Context`) unless it says otherwise.
  """
  @spec surfaces() :: [map()]
  def surfaces, do: @surfaces

  @doc """
  Which namespaces `named` reaches into, for a surface row: the reach
  truncated to the row's depth, so `Sanctum.Context.focus/2` is
  `Sanctum.Context`. A call on the root itself
  (`EmissaryWeb.static_paths/0`) is the root.
  """
  @spec surface_reaches(map(), named()) :: MapSet.t(String.t())
  def surface_reaches(row, named) do
    depth = Map.get(row, :depth, 2)
    into = row.into

    for {_path, names} <- named,
        {module, _number} <- names,
        module == into or String.starts_with?(module, into <> "."),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(depth) |> Enum.join(".")
  end

  @doc "The namespaces `named` reaches that the row's roster does not name."
  @spec surface_violations(map(), named()) :: [String.t()]
  def surface_violations(row, named) do
    row
    |> surface_reaches(named)
    |> MapSet.difference(MapSet.new(row.allow))
    |> Enum.sort()
  end

  @doc "The namespaces the row's roster names and `named` no longer reaches."
  @spec stale_surface_entries(map(), named()) :: [String.t()]
  def stale_surface_entries(row, named) do
    row.allow
    |> MapSet.new()
    |> MapSet.difference(surface_reaches(row, named))
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # 3. The routes
  # ---------------------------------------------------------------------------

  @route_postures %{
    authenticate_plug:
      "a bearer-credential plug on the pipeline resolves the caller before the controller",
    webhook_hmac: "the sender's HMAC over the raw body, verified on the pipeline",
    handler_auth: "the controller self-gates, answering 401 or 400 without a token",
    tincture_handler_auth:
      "a signed `?_t=` token or an Authorization bearer, resolved in the tincture " <>
        "controller's helper; no session cookie, because a tincture page is embeddable",
    public_oauth_state: "public: the OAuth state token in the callback is the credential",
    browser_oauth_start: "public: starts an IdP round trip and carries nothing of the caller",
    browser_oauth_callback: "public: the IdP's callback, gated by the state it carries",
    browser_oauth_flow: "public: a device-flow ticket or a post-acceptance hop, each single-use",
    browser_claim_gate: "public: the publisher-namespace claim page and its throttled submit",
    browser_public_legal: "public: renders the bundled policies and relays an acceptance",
    public_health: "public by design: a load balancer's probe, throttled per address",
    browser_public_auth: "public: the CSRF-guarded sign-out post",
    browser_public_login: "public: the sign-in page, which is what an anonymous caller comes for",
    browser_focus_handler:
      "the session cookie for who, the URL's athanor for where, focused in the " <>
        "controller exactly as a LiveView mount focuses it",
    browser_authenticated:
      "the `:athanor` live_session's on_mount pair: `PrismWeb.LiveAuth` requires a " <>
        "session and `PrismWeb.Focus` narrows the context to the URL's athanor"
  }

  # Which postures admit a caller who presented no credential at all.
  @public_postures ~w(
    public_oauth_state browser_oauth_start browser_oauth_callback browser_oauth_flow
    browser_claim_gate browser_public_legal public_health browser_public_auth
    browser_public_login
  )a

  @public_routes [
    {:get, "/api/health"},
    {:get, "/api/health/ready"},
    {:get, "/auth/oauth/callback"},
    {:get, "/auth/:provider"},
    {:get, "/auth/:provider/callback"},
    {:get, "/auth/device/complete/:ticket"},
    {:get, "/auth/post-legal-accept"},
    {:get, "/claim-namespace"},
    {:post, "/claim-namespace/submit"},
    {:get, "/legal/accept"},
    {:post, "/legal/accept/submit"},
    {:post, "/auth/logout"},
    {:get, "/login"}
  ]

  @doc """
  Every auth posture a route may declare, and what it means.

  The posture itself is declared where the route is
  (`metadata: %{auth: …}` in `EmissaryWeb.Router`), so it travels with
  the route and a deleted route takes its posture with it. What lives
  here is the vocabulary, and the roster of routes that admit a caller
  with no credential.
  """
  @spec route_postures() :: %{atom() => String.t()}
  def route_postures, do: @route_postures

  @doc "The postures that admit a caller who presented no credential."
  @spec public_postures() :: [atom()]
  def public_postures, do: @public_postures

  @doc """
  Every route that is public by design, as `{verb, path}`.

  A new one fails `Cyfr.BoundariesTest` until it is named here: a route
  must not become reachable without a credential by inheriting a pipeline.
  """
  @spec public_routes() :: [{atom(), String.t()}]
  def public_routes, do: @public_routes

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
          if posture in @public_postures and {route.verb, route.path} not in @public_routes,
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

    # Boot switches with an in-code default; flipping one is a code change.
    cron_scheduler_enabled: :default,
    execution_sweeper_enabled: :default,
    execution_archive_watch_enabled: :default,
    worker_watch_enabled: :default,
    external_server_reconciler_enabled: :default,
    provisioning_boot_enabled: :default,
    retention_scheduler_enabled: :default,
    control_plane_claim_enabled: :default,
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
    establish_cache_ms: :seam,
    namespace_cache_ttl_ms: :seam,
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
  endorsement.
  """
  @spec config_key_classes() :: %{atom() => atom()}
  def config_key_classes, do: @config_key_classes

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

  @config_read ~r/Application\.(?:get_env|fetch_env!?|compile_env!?)\(\s*:(?:cyfr|arca|sanctum),\s*:([a-z_0-9]+)/

  @config_keys_read_by_name %{
    api_rate_limit_max:
      "the `:api` bucket's own budget, read by `EmissaryWeb.Plugs.MCPRateLimit` " <>
        "under a key it builds from the bucket's name",
    api_rate_limit_window_ms: "the same bucket's window, built the same way",
    execution_events_max_concurrent:
      "handed to `EmissaryWeb.SSE.claim_slot/3` as the key to read, so the two SSE " <>
        "surfaces share one reader",
    execution_events_max_ms: "handed to `EmissaryWeb.SSE.deadline/1` as the key to read",
    mcp_subscription_max_concurrent:
      "handed to `EmissaryWeb.SSE.claim_slot/3` as the key to read",
    mcp_subscription_max_ms: "handed to `EmissaryWeb.SSE.deadline/1` as the key to read"
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
    |> Enum.reject(fn {_app, key} -> Map.has_key?(@config_keys_read_by_name, key) end)
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

  @doc "Every application key `scanned` reads, as atoms."
  @spec config_keys_read(scanned()) :: MapSet.t(atom())
  def config_keys_read(scanned) do
    for {_path, lines} <- scanned,
        code = lines |> Enum.map_join("\n", &elem(&1, 0)),
        [_, key] <- Regex.scan(@config_read, code),
        into: MapSet.new(),
        do: String.to_atom(key)
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

  @ports [
    %{
      behaviour: "Sanctum.Catalog",
      what: "consent's view of the operation table",
      declared_by: :sanctum,
      implemented_by: "Cyfr.Ops.Catalog",
      written_at_boot_by: "config :sanctum, :catalog"
    },
    %{
      behaviour: "Sanctum.Consent.Components",
      what: "component facts for consent",
      declared_by: :sanctum,
      implemented_by: "Compendium.ConsentFacts",
      written_at_boot_by: "config :sanctum, :consent_components"
    },
    %{
      behaviour: "Cyfr.Caps",
      what: "the storage and counted cap decision",
      declared_by: :cyfr_contracts,
      implemented_by: "Sanctum.Tenancy.Caps",
      written_at_boot_by: "Cyfr.Application"
    },
    %{
      behaviour: nil,
      what: "proxied tool resolution",
      declared_by: :cyfr,
      implemented_by: "Emissary.MCP.ExternalProvider",
      written_at_boot_by: nil,
      note:
        "the operation table asks the transport for a tool an upstream server " <>
          "defines, on a lookup miss. It is a direct call from `Cyfr.Ops.Catalog` " <>
          "today rather than a declared behaviour, because the table and the " <>
          "transport are one application: nothing in the dependency graph rests on " <>
          "it, and it becomes a behaviour the day they are two."
    },
    %{
      behaviour: "Arca.Storage.UnitLocator",
      what: "where a storage unit's bytes live",
      declared_by: :arca,
      implemented_by: "Compendium.ComponentPath and Compendium.AquaPath",
      written_at_boot_by: "Arca.Storage.install_locators!/0, from config :arca, :overlay_locators"
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
  The five ports of `AGENTS.md`, and only these. A sixth is an
  architecture change.
  """
  @spec ports() :: [map()]
  def ports, do: @ports

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

  @doc "The one call that installs the cap port's implementation, and where it is."
  @spec caps_boot_write() :: {String.t(), Path.t()}
  def caps_boot_write, do: {"Cyfr.Caps.install!(", "apps/cyfr/lib/cyfr/application.ex"}

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
      path: "Cyfr.Actor.system/0",
      file: "apps/cyfr_contracts/lib/cyfr/actor.ex",
      reason:
        "the control plane acting as itself, for work no caller asked for. It carries " <>
          "no tenant and no person, and its authority is the `system` flag rather than " <>
          "a credential someone presented."
    },
    %{
      path: "Cyfr.Actor.in_athanor/1",
      file: "apps/cyfr_contracts/lib/cyfr/actor.ex",
      reason:
        "row work inside one athanor for a caller established by other means than a " <>
          "context — a MAC-verified host call naming its attempt, a schedule's own " <>
          "occurrence row, a recovery scan already narrowed to one estate. The " <>
          "athanor and nothing else: `scope: :athanor`, `system: false`."
    },
    %{
      path: "Sanctum.VaultReader.tenant_actor/1",
      file: "apps/sanctum/lib/sanctum/vault_reader.ex",
      reason:
        "private, and inside the layer that owns tenancy: `usable/3` and " <>
          "`unseal_by_name/2` are reached by host-side callers that hold a resolved " <>
          "tenant and no context. It names the tenant it was already given and " <>
          "widens nothing."
    }
  ]

  @doc """
  Every way a `%Cyfr.Actor{}` is constructed in production code, with the
  reason for each.

  There are four. Each is defensible and in the right layer, and four is
  how you get six — so a fifth is argued for here before it appears.
  """
  @spec actor_paths() :: [map()]
  def actor_paths, do: @actor_paths

  # ---------------------------------------------------------------------------
  # 7. What the suites may name
  # ---------------------------------------------------------------------------

  @opus_named_by_cyfr_tests %{
    "apps/cyfr/test/integration/**" =>
      "the wiring suite, slice A's precedent: the umbrella runs one VM and these " <>
        "cases are integration tests of CYFR against a real worker service.",
    "apps/cyfr/test/support/opus_service.ex" =>
      "starts and stops the in-VM worker service the integration suite runs against.",
    "apps/cyfr/test/support/sandbox.ex" =>
      "drains the runner pool between cases, which is the only way a pooled runner " <>
        "holding a sandbox connection is released before the next test.",
    "apps/cyfr/test/cyfr/test_sandbox_test.exs" =>
      "the sandbox helper's own case: what it drains IS the pool, so the assertion " <>
        "has to name it.",
    "apps/cyfr/test/cyfr/execution/start_refusal_test.exs" =>
      "the refusal a keeper gives is `Opus.Keeper.Spawn.refusal/1`'s shape, and this " <>
        "case holds CYFR's rendering of it to that shape.",
    "apps/cyfr/test/cyfr/ops/error_renderers_test.exs" =>
      "the in-chain guest's renderer is Opus's, and the one-vocabulary case is that " <>
        "the three renderers agree sentence for sentence.",
    "apps/cyfr/test/cyfr/runtime_env_reading_test.exs" =>
      "pins the shape of the reads in `config/runtime.exs`, and that file configures " <>
        "the `opus` release too: what it names, this case quotes.",
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
end
