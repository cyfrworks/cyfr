# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BoundaryDeclarationsTest do
  @moduledoc """
  The `use Boundary` declarations of `arca`, `sanctum` and `cyfr`, read
  from their source and held to the architecture: every module belongs to
  exactly one boundary, each boundary's `deps` is the settled edge set,
  no boundary switches a check off, the one exception is the console's,
  and what Arca, Sanctum, the gate and each domain export is the facade
  roster's entries (`test/support/facade_roster.exs`) plus the additions
  rostered here, each with its reason. Nothing under `apps`, `tests`,
  `scripts` or `.github` reads the untracked design material beside the
  checkout.

  The Boundary compiler enforces the declarations in the dev build
  (`mix compile --force --warnings-as-errors`); this test pins what they
  say, so a widened edge or a new export is a reviewed change here.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @apps ~w(arca sanctum cyfr)

  # The composition set: what the composition root may name to wire it.
  @composition [
    Arca,
    Sanctum,
    Grimoire,
    Cyfr,
    Compendium,
    Aqua,
    Crucible,
    Emissary,
    Prism,
    PrismWeb,
    CyfrWeb,
    CyfrWeb.Ingress,
    CyfrWeb.Endpoint
  ]

  @deps %{
    Arca => [],
    Sanctum => [Arca],
    Grimoire => [Sanctum, Arca],
    Cyfr => [Grimoire, Sanctum, Arca],
    Cyfr.Application => @composition,
    # The endpoint plugs the root router and answers `/mcp` parser
    # failures in the MCP adapter's JSON-RPC renderer.
    CyfrWeb.Endpoint => (@composition -- [CyfrWeb.Endpoint]) ++ [CyfrWeb.Router, Emissary.Web],
    # The router expands each adapter's route provider, whose routes name
    # the adapter's controllers and plugs. The endpoint plugs the router,
    # so the router cannot name the endpoint.
    CyfrWeb.Router =>
      (@composition -- [CyfrWeb.Endpoint]) ++ [Emissary.Router, Emissary.Web, Prism.Router],
    CyfrWeb => [Grimoire, Sanctum, Arca, Cyfr],
    CyfrWeb.Ingress => [Sanctum, Grimoire, Arca, Cyfr, CyfrWeb, Compendium, Crucible],
    Compendium => [Grimoire, Cyfr, Sanctum, Arca],
    Crucible => [Compendium, Grimoire, Cyfr, Sanctum, Arca],
    Aqua => [Compendium, Crucible, Grimoire, Cyfr, Sanctum, Arca],
    Emissary => [Grimoire, Sanctum, Arca, Cyfr, Crucible, CyfrWeb],
    Emissary.Web => [Emissary, Grimoire, Sanctum, Arca, Cyfr, Crucible, CyfrWeb],
    Emissary.Router => [],
    Prism => [Grimoire, Sanctum, Arca, Cyfr, Compendium, Aqua, Crucible, CyfrWeb],
    Prism.Router => [],
    PrismWeb => [Prism, CyfrWeb, Grimoire, Sanctum, Arca, Cyfr, Compendium, Aqua, Crucible],
    Cyfr.Mix => [Grimoire],
    Cyfr.Boundaries => [
      Grimoire,
      Crucible,
      Emissary,
      Emissary.Router,
      Emissary.Web,
      Prism.Router,
      CyfrWeb,
      CyfrWeb.Ingress,
      CyfrWeb.Router
    ]
  }

  @top_level [
    Cyfr.Application,
    CyfrWeb.Endpoint,
    CyfrWeb.Router,
    CyfrWeb.Ingress,
    Emissary.Web,
    Emissary.Router,
    Prism.Router,
    Cyfr.Mix,
    Cyfr.Boundaries
  ]

  # Compile-time route verification in the console needs the root router
  # and endpoint, and the root names the console: an edge either way is a
  # cycle, so this is the one boundary exception.
  @dirty_xrefs %{PrismWeb => [CyfrWeb.Endpoint, CyfrWeb.Router]}

  # Exports beyond the facade manifest's rows, each group with its reason.
  @export_additions %{
    Arca => [
      {~w(ApiKeyStorage Athanors ConsentProofStorage ConsentStorage Doors FrameCredentials
          Members ProfileStorage ProviderCredentialStorage RegistryTokenStorage SessionStorage
          ToolGrantStorage Users VaultStorage WebhookStorage),
       "the security rows, which Sanctum reads; that no other layer reads them is " <>
         "`Cyfr.Boundaries`' security row"},
      {~w(AgentRevisions AgentStorage BudgetReservations BuildRecords Cache Cache.Keys
          CipherRotation ComponentStorage ControlPlane CredentialBindings CronSchedule
          DecisionLog DecisionLog.AuditFailure Execution ExecutionAttempts ExecutionEvents
          ExecutionPayloads ExecutionStanding Health JobClaims McpLog McpServerStorage
          Overlay PolicyLog ProvisioningClaims RateWindows RecordSink ScheduleOccurrences
          SecurityTransitions ServerMetaStorage Storage StorageProjectionChanges
          StorageProjectionRoots TenantTables ThreadStorage ThreadSubscriptionStorage
          TurnStorage Usage WebhookDeliveryStorage),
       "the storage, lease, claim and cache facades the layers above call downward"},
      {~w(Providers.Records), "the records door the gate's resources read through"},
      {~w(Repo.Errors), "the row plane's error convention, which callers rescue by"},
      {~w(SchemaFingerprint SchemaFingerprint.Check AuditHandler Storage.UnitLocator),
       "the composition root and the release task: the schema check, the audit " <>
         "handler and the overlay port it installs"}
    ],
    Sanctum => [
      {~w(ApiKey Atoms Auth Auth.DeviceFlow Auth.EmailVerification Auth.Identity
          Auth.OAuth Auth.OIDC Authority Authority.BudgetCounter BearerToken Caller Cipher
          Cipher.Rotation ClientIp Consent.Authz Consent.Loader Consent.Proof
          Consent.RegistrationBinding Consent.ShapeDerivation Consent.ShapeDiff Context
          Door Door.Store Egress ExecutionStanding Namespace Network Notify
          Policy.Enforcement Provisioning Session SignIn Tenancy Tenancy.Athanors
          Tenancy.Members Tenancy.Users TinctureAuth ToolServerDigest Unauthorized
          UnauthorizedError Vault.OAuthGrant VaultReader),
       "the identity, authority, consent and vault entries the layers above call " <>
         "downward, each rostered for its callers in `Cyfr.Boundaries`' surface rows"},
      {~w(Consent.Components Grimoire Tenancy.Caps),
       "the ports the composition root installs: component facts, the operation " <>
         "table and the storage cap"}
    ],
    Grimoire => [
      {~w(Catalog Supervisor), "the composition root loads the table and starts the gate"},
      {~w(Error), "the gate's refusal renderer, which the MCP adapter answers with"}
    ],
    Compendium => [
      {~w(AquaPath ComponentPath ConsentFacts),
       "the port implementations the composition root installs"},
      {~w(Supervisor), "the tree the composition root starts"}
    ],
    Crucible => [
      {~w(Keys Schedules.Scheduler Supervisor),
       "the worker root the composition root mints and the trees it starts"},
      {~w(Host.Children), "an admission entry `Cyfr.Boundaries` rosters"}
    ],
    Aqua => [{~w(Supervisor), "the tree the composition root starts"}]
  }

  @manifest_rows ~w(Arca Sanctum Grimoire Compendium Crucible Aqua)
  @roster_path Path.join(@root, "apps/cyfr/test/support/facade_roster.exs")

  defp sources(app), do: Path.wildcard(Path.join(@root, "apps/#{app}/lib/**/*.ex"))

  # Every module a file defines, with its `use Boundary` options when it
  # declares any, walking nested `defmodule`s and `defimpl`s.
  defp defined(path) do
    path |> File.read!() |> Code.string_to_quoted!() |> walk(nil)
  end

  defp walk({:defmodule, _, [name, [do: body]]}, parent) do
    module = module_name(name, parent)
    [%{module: module, kind: kind(module), boundary: boundary_opts(body)} | walk(body, module)]
  end

  defp walk({:defimpl, _, [protocol, opts]}, parent) when is_list(opts) do
    {body, opts} = Keyword.pop(opts, :do)
    walk({:defimpl, [], [protocol, opts, [do: body]]}, parent)
  end

  defp walk({:defimpl, _, [protocol, opts, [do: body]]}, parent) do
    for_module = opts |> Keyword.fetch!(:for) |> module_name(nil)
    module = Module.concat(module_name(protocol, nil), for_module)
    _ = parent
    [%{module: module, kind: :impl, boundary: boundary_opts(body)}]
  end

  defp walk({_, _, args}, parent) when is_list(args), do: Enum.flat_map(args, &walk(&1, parent))
  defp walk({left, right}, parent), do: walk(left, parent) ++ walk(right, parent)
  defp walk(list, parent) when is_list(list), do: Enum.flat_map(list, &walk(&1, parent))
  defp walk(_other, _parent), do: []

  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, parent),
    do: Module.concat([parent | rest])

  defp module_name({:__aliases__, _, parts}, nil), do: Module.concat(parts)
  defp module_name({:__aliases__, _, parts}, parent), do: Module.concat([parent | parts])

  defp kind(module) do
    if String.starts_with?(inspect(module), "Mix.Tasks."), do: :mix_task, else: :module
  end

  defp boundary_opts({:__block__, _, exprs}), do: Enum.find_value(exprs, &use_boundary/1)
  defp boundary_opts(expr), do: use_boundary(expr)

  defp use_boundary({:use, _, [{:__aliases__, _, [:Boundary]}]}), do: []
  defp use_boundary({:use, _, [{:__aliases__, _, [:Boundary]}, opts]}), do: literal(opts)
  defp use_boundary(_expr), do: nil

  defp literal({:__aliases__, _, parts}), do: Module.concat(parts)
  defp literal(list) when is_list(list), do: Enum.map(list, &literal/1)
  defp literal({key, value}), do: {literal(key), literal(value)}
  defp literal(value) when is_atom(value) or is_number(value) or is_binary(value), do: value

  defp inventory do
    for app <- @apps, path <- sources(app), entry <- defined(path) do
      Map.merge(entry, %{app: app, file: Path.relative_to(path, @root)})
    end
  end

  defp boundaries(inventory) do
    for %{boundary: opts, kind: :module} = entry <- inventory,
        is_list(opts),
        not Keyword.has_key?(opts, :classify_to),
        into: %{},
        do: {entry.module, Map.put(Map.new(opts), :app, entry.app)}
  end

  defp exports(name, opts) do
    for export <- Map.get(opts, :exports, []) do
      is_atom(export) || flunk("#{inspect(name)} mass-exports #{inspect(export)}")
      Module.concat(name, export)
    end
  end

  # The boundary a module's name places it in: the longest declared prefix
  # among its own application's boundaries.
  defp owner(module, app, boundaries) do
    name = inspect(module)

    boundaries
    |> Enum.filter(fn {b, opts} ->
      opts.app == app and (name == inspect(b) or String.starts_with?(name, inspect(b) <> "."))
    end)
    |> Enum.max_by(fn {b, _} -> String.length(inspect(b)) end, fn -> nil end)
  end

  test "the scan reads every application's declarations" do
    inv = inventory()
    bounds = boundaries(inv)

    for app <- @apps do
      assert Enum.any?(inv, &(&1.app == app)), "read no module of #{app}"
    end

    assert Map.keys(bounds) |> Enum.sort() == Map.keys(@deps) |> Enum.sort()
  end

  test "every module belongs to exactly one boundary of its own application" do
    inv = inventory()
    bounds = boundaries(inv)

    unowned =
      for %{kind: kind} = entry <- inv, kind == :module do
        case owner(entry.module, entry.app, bounds) do
          nil -> "#{entry.file}: #{inspect(entry.module)}"
          {_b, _} -> nil
        end
      end

    assert Enum.reject(unowned, &is_nil/1) == []

    reclassified =
      for %{kind: kind} = entry <- inv, kind in [:impl, :mix_task] do
        target = entry.boundary && entry.boundary[:classify_to]

        if match?(%{app: app} when app == entry.app, bounds[target]),
          do: nil,
          else: "#{entry.file}: #{inspect(entry.module)} classifies to #{inspect(target)}"
      end

    assert Enum.reject(reclassified, &is_nil/1) == [],
           "a protocol implementation or Mix task is checked only once it is classified"
  end

  test "a boundary under another's namespace stands on its own" do
    bounds = boundaries(inventory())

    nested =
      for {name, _opts} <- bounds,
          Enum.any?(bounds, fn {parent, _} ->
            String.starts_with?(inspect(name), inspect(parent) <> ".")
          end),
          do: name

    # A nested boundary would inherit its parent's edges and be reachable
    # only through it; each of these is a boundary beside its namespace.
    assert Enum.sort(nested) == Enum.sort(@top_level)

    for name <- @top_level, do: assert(bounds[name][:top_level?] == true, inspect(name))
  end

  test "each boundary's deps are the settled edge set" do
    bounds = boundaries(inventory())

    for {name, settled} <- @deps do
      declared = bounds |> Map.fetch!(name) |> Map.get(:deps, [])

      assert Enum.sort(declared) == Enum.sort(settled),
             "#{inspect(name)} declares deps #{inspect(declared)}; settled: #{inspect(settled)}"
    end
  end

  test "no check is off, every boundary checks aliases, and the one exception is the console's" do
    bounds = boundaries(inventory())

    for {name, opts} <- bounds do
      check = Map.get(opts, :check, [])
      assert check[:aliases] == true, "#{inspect(name)} does not check aliases"
      refute Keyword.get(check, :in) == false, "#{inspect(name)} turns its in-check off"
      refute Keyword.get(check, :out) == false, "#{inspect(name)} turns its out-check off"
      refute Map.has_key?(opts, :type), "#{inspect(name)} sets a type"

      assert Map.get(opts, :dirty_xrefs, []) == Map.get(@dirty_xrefs, name, []),
             "#{inspect(name)} carries #{inspect(opts[:dirty_xrefs])}"
    end

    assert bounds[Sanctum].check[:apps] == [:ecto, :ecto_sql, :postgrex, :exqlite, :ecto_sqlite3]
  end

  test "Arca, Sanctum, the gate and each domain export the manifest's rows and the rostered additions" do
    bounds = boundaries(inventory())
    manifest = manifest_exports()

    for key <- @manifest_rows do
      name = Module.concat([key])
      declared = bounds |> Map.fetch!(name) |> then(&exports(name, &1)) |> Enum.sort()

      additions =
        for {modules, _reason} <- Map.get(@export_additions, name, []),
            m <- modules,
            do: Module.concat(name, m)

      assert MapSet.disjoint?(MapSet.new(additions), MapSet.new(manifest[key])),
             "#{key}: an addition the manifest already lists"

      assert declared == Enum.sort(manifest[key] ++ additions),
             """
             #{key} exports differ from the manifest plus the additions:
               declared only: #{inspect(declared -- (manifest[key] ++ additions))}
               missing: #{inspect((manifest[key] ++ additions) -- declared)}
             """
    end
  end

  test "a row with no roster entry fails naming the row" do
    roster = @roster_path |> load_roster() |> Map.delete("Crucible")

    assert_raise ExUnit.AssertionError, ~r/no entry for Crucible/, fn ->
      check_roster(roster)
    end
  end

  test "a roster entry naming a module that does not exist fails naming the module" do
    roster = @roster_path |> load_roster() |> Map.update!("Aqua", &["Aqua.NoSuchFacade" | &1])

    assert_raise ExUnit.AssertionError, ~r/Aqua\.NoSuchFacade/, fn -> check_roster(roster) end
  end

  test "an absent roster fails naming its path" do
    path = Path.join(@root, "apps/cyfr/test/support/no_such_roster.exs")

    assert_raise ExUnit.AssertionError, ~r/#{Regex.escape(path)}/, fn -> load_roster(path) end
  end

  # A path into the design material outside the checkout, anchored so a
  # URL segment such as `/en-US/docs/` is not one; built so this file does
  # not name it.
  @docs_path Regex.compile!("(^|[^A-Za-z0-9_./-])" <> "docs" <> "/")
  @scanned ~w(apps tests scripts .github)
  @unscanned ~w(/vendor/ /priv/static/ /node_modules/ /_build/ /deps/ /.elixir_ls/)

  test "no file under apps, tests, scripts or .github names a docs path outside a comment" do
    offending =
      for dir <- @scanned,
          path <- Path.wildcard(Path.join([@root, dir, "**"]), match_dot: true),
          rel = Path.relative_to(path, @root),
          not String.ends_with?(rel, ".md"),
          not String.contains?("/" <> rel, @unscanned),
          File.regular?(path),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not comment?(line),
          Regex.match?(@docs_path, line),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert offending == [], "a docs path outside a comment:\n" <> Enum.join(offending, "\n")
  end

  defp comment?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, "//")
  end

  # The facade roster's module names under each key's own namespace.
  defp manifest_exports, do: @roster_path |> load_roster() |> check_roster()

  defp load_roster(path) do
    File.regular?(path) || flunk("the facade roster #{path} is absent")
    {roster, _binding} = Code.eval_file(path)
    roster
  end

  defp check_roster(roster) do
    for key <- @manifest_rows, into: %{} do
      names =
        case Map.fetch(roster, key) do
          {:ok, names} -> names
          :error -> flunk("the facade roster has no entry for #{key}")
        end

      modules =
        for name <- names do
          module = Module.concat([name])

          Code.ensure_loaded?(module) ||
            flunk("the facade roster's #{key} entry names #{name}, which does not exist")

          module
        end

      {key, modules}
    end
  end
end
