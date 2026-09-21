# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BoundariesTest do
  @moduledoc """
  The one reader of `Cyfr.Boundaries`, and what it holds the tree to.

  Eight roster tests scanned this tree before this one, each its own way:
  `namespace_direction`, `web_direction`, `sanctum_surfaces`,
  `emissary_surface` and `layer_independence` under `apps/cyfr/test/cyfr`,
  `compendium/reverse_surface`, and the two host-surface suites in
  `apps/opus` and `apps/locus`. Every boundary they held is a row of the
  catalog now, and this file is what reads the rows.

  Three rules govern what is here, and they are why it is longer than a
  roster:

    * **A planted violation must fail.** A dependency, a route and a
      configuration key are each planted below and shown reported. A
      catalog nobody can break is a catalog that checks nothing.
    * **An empty source scan must fail.** Every roster this replaces
      learned that the hard way, two of them this slice: a scan pointed at
      a moved tree passes every assertion it makes. So each scan is shown
      to have read code before its rosters are believed.
    * **Two scans, because neither sees everything.** The source scan,
      through `Cyfr.Test.CodeLines`, sees aliases, struct patterns,
      typespecs and compile-time attributes, which emit no call. The
      compiled scan, the import table of each `.beam`, sees every remote
      call the compiler emitted, including ones spelled in a way a regex
      would miss — and it is what covers `Cyfr.Boundaries` itself, the one
      file the source scan skips.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Boundaries
  alias Cyfr.Test.{CodeLines, SourceTree}

  defp root, do: Path.expand("../../../..", __DIR__)

  # Every file under `globs`, read through the one line filter. The
  # catalog's own file is skipped: it names each namespace it rosters and
  # would report itself as a reach into all of them.
  defp scan(globs) do
    skip = MapSet.new(Boundaries.scan_exclusions())

    for glob <- List.wrap(globs),
        path <- SourceTree.files!(Path.join(root(), glob)),
        rel = Path.relative_to(path, root()),
        not MapSet.member?(skip, rel),
        do: {rel, SourceTree.code_lines(path)}
  end

  # The other view of the same files: every module name they name, read
  # from the token stream, so a name in prose is not one.
  defp names(globs) do
    skip = MapSet.new(Boundaries.scan_exclusions())

    for glob <- List.wrap(globs),
        path <- SourceTree.files!(Path.join(root(), glob)),
        rel = Path.relative_to(path, root()),
        not MapSet.member?(skip, rel),
        do: {rel, SourceTree.aliases(path)}
  end

  defp lines_read(scanned), do: Enum.sum(for {_path, lines} <- scanned, do: length(lines))

  # `.../Elixir.Cyfr.JCS.beam` is the module `Cyfr.JCS`. An Erlang module's
  # beam carries no prefix and yields its own name, which no layer claims.
  defp module_name(path),
    do: path |> Path.basename(".beam") |> String.replace_prefix("Elixir.", "")

  defp beams(app),
    do: app |> Application.app_dir("ebin") |> Path.join("*.beam") |> Path.wildcard()

  defp contracts_modules do
    :cyfr_contracts |> beams() |> Enum.map(&module_name/1) |> MapSet.new()
  end

  # Every remote call the compiler emitted from `app`'s production
  # modules, read from each beam's import table.
  defp compiled_reaches(app) do
    for path <- beams(app),
        caller = module_name(path),
        production?(path),
        {:ok, {_mod, [imports: imports]}} <-
          [:beam_lib.chunks(String.to_charlist(path), [:imports])],
        {callee, function, arity} <- imports,
        callee = inspect(callee),
        callee != caller,
        uniq: true,
        do: {caller, callee, "#{function}/#{arity}"}
  end

  # The test build compiles `test/support` into the same ebin. A support
  # module is not the app, and its reaches are the suite's.
  defp production?(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:compile_info]) do
      {:ok, {_mod, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> String.contains?("/lib/")

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # The scans read
  # ---------------------------------------------------------------------------

  describe "the scans" do
    test "every application's source scan reads code" do
      for row <- Boundaries.applications() do
        read = lines_read(scan(row.lib <> "/**/*.ex"))

        assert read > 100,
               "the source scan of #{row.app} read #{read} code lines — it is not reading"
      end
    end

    test "every application's compiled scan reads imports" do
      for row <- Boundaries.applications() do
        read = length(compiled_reaches(row.app))

        assert read > 100,
               "the compiled scan of #{row.app} read #{read} imports — it is not reading"
      end
    end

    test "every surface row reads code where it says it looks" do
      for row <- Boundaries.surfaces() do
        read = lines_read(scan(row.from))

        assert read > 0,
               "the surface #{row.into} <- #{inspect(row.from)} read no code line"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 1. The applications
  # ---------------------------------------------------------------------------

  describe "the dependency graph" do
    test "each mix.exs declares the umbrella dependencies the catalog names" do
      for row <- Boundaries.applications() do
        declared =
          root()
          |> Path.join("apps/#{row.app}/mix.exs")
          |> SourceTree.read()
          |> CodeLines.lines()
          |> Enum.join("\n")
          |> then(
            &Regex.scan(~r/\{:([a-z_0-9]+), in_umbrella: true/, &1, capture: :all_but_first)
          )
          |> List.flatten()
          |> Enum.map(&String.to_atom/1)
          |> Enum.sort()
          |> Enum.uniq()

        assert declared == Enum.sort(row.umbrella_deps),
               "apps/#{row.app}/mix.exs declares #{inspect(declared)} in the umbrella; " <>
                 "the catalog says #{inspect(Enum.sort(row.umbrella_deps))}"
      end
    end

    test "no application's code names a layer its dependencies do not reach" do
      contracts = contracts_modules()

      found =
        for row <- Boundaries.applications(),
            violation <-
              Boundaries.dependency_violations(row.app, names(row.lib <> "/**/*.ex"), contracts),
            do: violation

      assert found == [],
             """
             An application names a module outside the layers its `mix.exs`
             declares. `arca` sits at the bottom, `sanctum` above it, the host
             above both and neither island is declared by anything — so this
             does not compile in the island builds, whatever the umbrella says.

             #{Enum.join(Enum.sort(found), "\n")}
             """
    end

    test "no application's compiled calls reach a layer its dependencies do not" do
      contracts = contracts_modules()

      found =
        for row <- Boundaries.applications(),
            allowed = Boundaries.reachable_layers(row.app),
            {caller, callee, function} <- compiled_reaches(row.app),
            found = Boundaries.layer(callee, contracts),
            found not in allowed,
            do: "#{row.app}: #{caller} -> #{callee}.#{function} (#{found})"

      assert found == [],
             """
             The compiler emitted a call across a boundary the dependency graph
             does not allow:

             #{Enum.join(Enum.sort(found), "\n")}
             """
    end
  end

  describe "the islands" do
    test "each names only its own modules, the contracts, and its declared dependencies' roots" do
      contracts = contracts_modules()

      for app <- Boundaries.islands() do
        row = Boundaries.application!(app)
        own = row.app |> to_string() |> Macro.camelize()

        outside =
          for {path, named} <- names(row.lib <> "/**/*.ex"),
              {name, n} <- named,
              String.contains?(name, "."),
              not String.starts_with?(name, own <> "."),
              not MapSet.member?(contracts, name),
              not contract_type?(name, contracts),
              not MapSet.member?(elixir_modules(), name),
              (name |> String.split(".") |> hd()) not in row.dependency_roots,
              uniq: true,
              do: "#{path}:#{n}: #{name}"

        assert outside == [],
               """
               #{app} names modules outside its surface. A run's authority, its
               children, its catalog tools, its rows and its keys are CYFR's: an
               island asks for them over its wire, and the answer is a host call
               or a client, never a dependency.

               #{Enum.join(Enum.sort(outside), "\n")}
               """
      end
    end

    test "every rostered root is a module of a dependency the island declares" do
      for app <- Boundaries.islands() do
        row = Boundaries.application!(app)
        known = dependency_modules(app)

        unbacked = for name <- row.dependency_roots, not MapSet.member?(known, name), do: name

        assert unbacked == [],
               "#{app}'s roster names roots no declared dependency defines: " <>
                 inspect(unbacked) <> " — remove them, or declare the dependency"
      end
    end

    test "every rostered root is still reached" do
      for app <- Boundaries.islands() do
        row = Boundaries.application!(app)

        reached =
          for {_path, named} <- names(row.lib <> "/**/*.ex"),
              {name, _n} <- named,
              into: MapSet.new(),
              do: name |> String.split(".") |> hd()

        stale = Enum.reject(row.dependency_roots, &MapSet.member?(reached, &1))

        assert stale == [],
               "#{app}'s roster names roots its code no longer reaches: #{inspect(stale)} — " <>
                 "a standing entry readmits the reach it was written to allow"
      end
    end
  end

  # `Cyfr.Authority.Blob.Edge` is named for its struct and type: a module
  # of the contracts, or a type spelled under one (`Cyfr.HostAPI.renewal`).
  defp contract_type?(name, contracts) do
    name
    |> String.split(".")
    |> Enum.drop(-1)
    |> Enum.join(".")
    |> then(&MapSet.member?(contracts, &1))
  end

  # Elixir's and OTP's own modules, which no island rosters: naming `Enum`
  # or `Logger.Formatter` is not a dependency decision, it is the language.
  defp elixir_modules do
    Enum.reduce([:elixir, :logger, :kernel, :stdlib], MapSet.new(), fn app, acc ->
      _ = Application.load(app)
      MapSet.union(acc, MapSet.new(Application.spec(app, :modules) || [], &inspect/1))
    end)
  end

  # Every module name the applications `app` depends on define, its own
  # excluded: the transitive closure of its `mix.exs`, plus Elixir itself.
  defp dependency_modules(app) do
    app
    |> dependency_closure()
    |> Enum.reduce(MapSet.new(), fn dep, acc ->
      _ = Application.load(dep)
      MapSet.union(acc, MapSet.new(Application.spec(dep, :modules) || [], &inspect/1))
    end)
  end

  defp dependency_closure(app) do
    declared =
      root()
      |> Path.join("apps/#{app}/mix.exs")
      |> SourceTree.read()
      |> then(&Regex.scan(~r/\{:([a-z_0-9]+),/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.map(&String.to_atom/1)

    walk(declared, MapSet.new([:elixir, :stdlib, :kernel]))
  end

  defp walk([], seen), do: seen

  defp walk([app | rest], seen) do
    if MapSet.member?(seen, app) do
      walk(rest, seen)
    else
      _ = Application.load(app)
      deps = Application.spec(app, :applications) || []
      walk(rest ++ deps, MapSet.put(seen, app))
    end
  end

  # ---------------------------------------------------------------------------
  # 2. The surfaces
  # ---------------------------------------------------------------------------

  describe "the surfaces" do
    test "no source reaches a namespace its surface does not name" do
      found =
        for row <- Boundaries.surfaces(),
            extra = Boundaries.surface_violations(row, names(row.from)),
            extra != [],
            do: "#{inspect(row.from)} -> #{row.into}: #{inspect(extra)}\n  #{row.reason}"

      assert found == [],
             """
             A surface widened. Add the namespace to its row in `Cyfr.Boundaries`
             with a line saying why, or move the shared piece to the glue
             namespace (`Cyfr.`) — several of these cross the licence boundary,
             and one of them is a domain naming a user interface.

             #{Enum.join(found, "\n\n")}
             """
    end

    test "no surface names something it has stopped reaching" do
      found =
        for row <- Boundaries.surfaces(),
            stale = Boundaries.stale_surface_entries(row, names(row.from)),
            stale != [],
            do: "#{inspect(row.from)} -> #{row.into}: #{inspect(stale)}"

      assert found == [],
             """
             A surface names namespaces its sources no longer reach. Remove
             them — a standing entry readmits the reach it was written to allow,
             and a stale roster is how the real surface stops being readable.

             #{Enum.join(found, "\n")}
             """
    end

    test "every row says why its roster reads as it does" do
      for row <- Boundaries.surfaces() do
        assert is_binary(row.reason) and String.length(row.reason) > 40,
               "the surface #{inspect(row.from)} -> #{row.into} carries no reason"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. The routes
  # ---------------------------------------------------------------------------

  describe "the routes" do
    test "every HTTP route declares an auth posture from the vocabulary" do
      assert Boundaries.route_violations(EmissaryWeb.Router.__routes__()) == [],
             """
             A route does not say how it is authenticated. The posture is route
             metadata (`metadata: %{auth: …}`) so it travels with the route and a
             deleted route takes it with it; the vocabulary is
             `Cyfr.Boundaries.route_postures/0`. A route must not inherit auth by
             accident from a scope, and a route that admits a caller with no
             credential is named in `public_routes/0` as well.

             #{Enum.join(Boundaries.route_violations(EmissaryWeb.Router.__routes__()), "\n")}
             """
    end

    test "every rostered public route still exists" do
      stale = Boundaries.stale_public_routes(EmissaryWeb.Router.__routes__())

      assert stale == [],
             "the public-route roster names routes that are gone: #{inspect(stale)}"
    end

    test "every posture in the vocabulary is declared by at least one route" do
      declared =
        EmissaryWeb.Router.__routes__()
        |> Enum.map(& &1.metadata[:auth])
        |> MapSet.new()

      unused =
        Boundaries.route_postures()
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(declared, &1))

      assert unused == [],
             "these postures are in the vocabulary and no route declares them: #{inspect(unused)}"
    end

    test "every posture says what authenticates the route" do
      for {posture, sentence} <- Boundaries.route_postures() do
        assert is_binary(sentence) and String.length(sentence) > 20,
               "the posture #{inspect(posture)} carries no sentence"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. The configuration schema
  # ---------------------------------------------------------------------------

  describe "the configuration schema" do
    test "every key the code reads is wired to a config file or classified" do
      unclassified = Boundaries.config_violations(application_sources(), declared_config_keys())

      assert unclassified == [],
             """
             These application keys are read by the code and set by no config file:

             #{Enum.map_join(unclassified, "\n", &"  #{inspect(&1)}")}

             Say what each one is in `Cyfr.Boundaries.config_key_classes/0`:
             `:operator` if you are adding the `CYFR_*` read in
             `config/runtime.exs` (and the line in `.env.example`), `:default` if
             the value is the code's to own, `:seam` if it is a test hook that
             must stay unpublished, or `:missing_lever` if it reads like an
             operator's knob and does not have one yet.
             """
    end

    test "every key only the suite declares is classified" do
      declared = declared_config_keys()

      unclassified =
        for key <- Boundaries.config_keys_read(application_sources()),
            Map.get(declared, key) == ["test.exs"],
            not Map.has_key?(Boundaries.test_only_config_key_classes(), key),
            do: key

      assert unclassified == [],
             """
             These application keys are read in `lib/` and set only by the suite:

             #{Enum.map_join(Enum.sort(unclassified), "\n", &"  #{inspect(&1)}")}

             A key only the suite can set is either a seam (fine — say so) or a
             knob an operator cannot reach (`:missing_lever`).
             """
    end

    test "the schema names no key that is gone or has since been wired" do
      read = Boundaries.config_keys_read(application_sources())
      declared = declared_config_keys()

      stale =
        for {key, _class} <-
              Map.merge(
                Boundaries.config_key_classes(),
                Boundaries.test_only_config_key_classes()
              ),
            not MapSet.member?(read, key) or
              Map.get(declared, key, []) not in [[], ["test.exs"]],
            do: key

      assert stale == [],
             """
             The schema names keys that are no longer unwired — deleted, or given
             a config declaration:

             #{Enum.map_join(Enum.sort(stale), "\n", &"  #{inspect(&1)}")}

             Wiring one to `config/runtime.exs` is the good outcome; remove its
             line from `Cyfr.Boundaries` when you do.
             """
    end

    test "no configuration file sets a key under an application that never reads it" do
      unread = Boundaries.unread_config_keys(declared_config_pairs(), application_sources())

      assert unread == [],
             """
             These keys are set under an application no code reads them under:

             #{Enum.map_join(unread, "\n", fn {app, key} -> "  config :#{app}, #{inspect(key)}" end)}

             A file that sets `:arca, :some_key` while the code reads
             `:cyfr, :some_key` sets nothing: the umbrella build reads the root
             file, an application's own build reads its own, and a key in the
             wrong one of them is inert in both. If the key really is read under
             a name a caller computes, say so in
             `Cyfr.Boundaries.config_keys_read_by_name/0`.
             """
    end

    test "every key said to be read by a computed name is still declared somewhere" do
      declared = MapSet.new(declared_config_pairs(), &elem(&1, 1))

      stale =
        for {key, _reason} <-
              Map.merge(
                Boundaries.config_keys_read_by_name(),
                Boundaries.config_keys_read_outside_lib()
              ),
            not MapSet.member?(declared, key),
            do: key

      assert stale == [],
             "these keys are named as read by a computed name and nothing sets them: " <>
               inspect(stale)
    end

    test "the gaps are named, so they are a decision and not an oversight" do
      gaps =
        Boundaries.config_key_classes()
        |> Map.merge(Boundaries.test_only_config_key_classes())
        |> Enum.filter(fn {_key, class} -> class == :missing_lever end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      # A canary, not a target: this list should shrink as knobs are wired,
      # and any change to it should be a deliberate one someone reads.
      assert gaps == [
               :oci_max_blob_bytes,
               :platform_ceiling,
               :registry_scheme,
               :tincture_rate_limit_max,
               :webhook_max_body_bytes
             ]
    end
  end

  defp application_sources do
    for lib <- SourceTree.app_libs(root()), source <- scan(lib <> "/**/*.ex"), do: source
  end

  # Every declaration a configuration file makes for one of the schema's
  # three applications, as `{file, app, key}` — the single-key form and
  # the multi-key `config :app,\n  key: …` form, parsed once so the two
  # views below cannot read them differently. The applications' own files
  # are read as well as the root's, because an application's own build
  # reads its own.
  defp config_declarations do
    apps = Enum.map_join(Boundaries.config_applications(), "|", &to_string/1)
    single = Regex.compile!("config :(#{apps}),\\s*:([a-z_0-9]+)")
    block = Regex.compile!("^config :(#{apps}),\\s*$((?:\\n[ \\t]+.*)+)", "m")
    member = ~r/^\s{2,}([a-z_0-9]+):/m

    files =
      SourceTree.files!(Path.join(root(), "config/*.exs")) ++
        SourceTree.files!(Path.join(root(), "apps/*/config/*.exs"))

    for path <- files, source = File.read!(path), reduce: [] do
      acc ->
        rows =
          for [app, key] <- Regex.scan(single, source, capture: :all_but_first),
              do: {path, String.to_atom(app), String.to_atom(key)}

        members =
          for [app, body] <- Regex.scan(block, source, capture: :all_but_first),
              [key] <- Regex.scan(member, body, capture: :all_but_first),
              do: {path, String.to_atom(app), String.to_atom(key)}

        acc ++ rows ++ members
    end
  end

  # Which of the root's configuration files declare each key, by name.
  # The root's alone: these are the files the umbrella build reads.
  defp declared_config_keys do
    for {path, _app, key} <- config_declarations(),
        Path.dirname(path) == Path.join(root(), "config"),
        reduce: %{} do
      acc -> Map.update(acc, key, [Path.basename(path)], &[Path.basename(path) | &1])
    end
  end

  # Every `{application, key}` a configuration file sets, wherever it sets it.
  defp declared_config_pairs do
    config_declarations() |> Enum.map(fn {_path, app, key} -> {app, key} end) |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # The planted violations
  # ---------------------------------------------------------------------------

  describe "a planted violation" do
    test "a dependency the graph forbids is reported, with its file and its layer" do
      planted = [
        {"apps/arca/lib/arca/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Arca.Planted do
           alias Sanctum.Context

           def reach(%Context{} = ctx), do: Compendium.Resolver.resolve(ctx)
         end
         ''')}
      ]

      found = Boundaries.dependency_violations(:arca, planted, contracts_modules())

      assert Enum.sort(found) == [
               "apps/arca/lib/arca/planted.ex:2 names Sanctum.Context (sanctum); " <>
                 "arca may name [:arca, :contracts, :outside]",
               "apps/arca/lib/arca/planted.ex:4 names Compendium.Resolver (host); " <>
                 "arca may name [:arca, :contracts, :outside]"
             ]

      # The same file under the host, which may name both, is no violation.
      assert Boundaries.dependency_violations(:cyfr, planted, contracts_modules()) == []
    end

    test "a surface that widens is reported against its row" do
      row = Enum.find(Boundaries.surfaces(), &(&1.into == "Emissary" and &1.allow == []))

      planted = [
        {"apps/sanctum/lib/sanctum/planted.ex",
         CodeLines.aliases("defmodule Sanctum.Planted do\n  alias Emissary.MCP.Tools\nend\n")}
      ]

      assert Boundaries.surface_violations(row, planted) == ["Emissary.MCP"]
    end

    test "a route with no declared posture is reported" do
      found = Boundaries.route_violations(Cyfr.BoundariesTest.PlantedRouter.__routes__())

      assert found == [
               "get /planted/unclassified: no declared auth posture " <>
                 "(add `metadata: %{auth: …}`)",
               "get /planted/unknown-posture: auth posture :made_up is not in the vocabulary",
               "get /planted/unrostered-public: declares the public posture " <>
                 ":public_health and is not rostered"
             ]
    end

    test "a configuration key nothing declares and nothing classifies is reported" do
      planted = [
        {"apps/cyfr/lib/cyfr/planted.ex",
         CodeLines.code_lines(~S'''
         defmodule Cyfr.Planted do
           def knob, do: Application.get_env(:cyfr, :planted_knob, 1)
           def wired, do: Application.get_env(:cyfr, :cors_allowed_origins)
         end
         ''')}
      ]

      assert Boundaries.config_violations(planted, declared_config_keys()) == [:planted_knob]
    end
  end

  # A router of this file's own, so a route that says nothing about its
  # authentication can be shown reported without one landing in the real
  # router first.
  defmodule PlantedRouter do
    use Phoenix.Router

    get "/planted/unclassified", EmissaryWeb.HealthController, :check

    get "/planted/unknown-posture", EmissaryWeb.HealthController, :check,
      metadata: %{auth: :made_up}

    get "/planted/unrostered-public", EmissaryWeb.HealthController, :check,
      metadata: %{auth: :public_health}
  end

  # ---------------------------------------------------------------------------
  # 5. The ports
  # ---------------------------------------------------------------------------

  describe "the ports" do
    test "there are five, and only five" do
      assert length(Boundaries.ports()) == 5,
             "a sixth port is an architecture change, not a catalog edit"
    end

    test "every behaviour Sanctum declares is a listed port or a named internal strategy" do
      declared =
        for {path, lines} <- scan("apps/sanctum/lib/**/*.ex"),
            Enum.any?(lines, &String.contains?(elem(&1, 0), "@callback")),
            do: defmodule_name(path, lines)

      assert Enum.sort(declared) == Boundaries.sanctum_behaviours(),
             """
             Sanctum declares #{inspect(Enum.sort(declared))}; the catalog allows
             #{inspect(Boundaries.sanctum_behaviours())}.

             A behaviour the identity domain declares is either one of the five
             ports of `AGENTS.md` — something above it implements and the boot
             writes in — or a named internal strategy, declared and implemented
             inside Sanctum and selected by configuration. Anything else is a
             sixth port, which is an architecture change.
             """
    end

    test "no Sanctum-declared behaviour is implemented by Arca" do
      found =
        for {path, lines} <- scan("apps/arca/lib/**/*.ex"),
            {line, n} <- lines,
            line =~ ~r/@behaviour\s+Sanctum\./,
            do: "#{path}:#{n}: #{String.trim(line)}"

      assert found == [],
             """
             Arca implements a behaviour Sanctum declares:

             #{Enum.join(found, "\n")}

             Arca sits below Sanctum. A reach from Sanctum into Arca is a direct
             downward facade call, never a port — `apps/arca` does not compile
             against `apps/sanctum`, so this cannot be answered anyway.
             """
    end

    test "the cap port has exactly one boot write" do
      {call, expected} = Boundaries.caps_boot_write()

      writes =
        for lib <- SourceTree.app_libs(root()),
            {path, lines} <- scan(lib <> "/**/*.ex"),
            {line, n} <- lines,
            String.contains?(line, call),
            do: "#{path}:#{n}"

      assert length(writes) == 1 and hd(writes) =~ expected,
             """
             `#{call}` is written at #{inspect(writes)}; it is the boot's one
             write, in #{expected}. A second writer means a process can read a
             different implementation depending on when it asked, and the port
             refuses before the first write rather than reading as a server with
             no ceilings.
             """
    end

    test "every port row names its implementation and where the boot writes it" do
      for port <- Boundaries.ports() do
        assert is_binary(port.what) and is_binary(port.implemented_by)

        if port.behaviour do
          assert port.written_at_boot_by,
                 "the port #{port.behaviour} names no boot write"
        else
          assert Map.has_key?(port, :note),
                 "the port #{port.what} declares no behaviour and says nothing about why"
        end
      end
    end
  end

  defp defmodule_name(path, lines) do
    Enum.find_value(lines, fn {line, _n} ->
      case Regex.run(~r/^defmodule ([A-Z][\w.]*) do$/, line, capture: :all_but_first) do
        [name] -> name
        _ -> nil
      end
    end) || raise "no top-level defmodule in #{path}"
  end

  # ---------------------------------------------------------------------------
  # 6. The actor construction paths
  # ---------------------------------------------------------------------------

  describe "the actor" do
    test "the catalog names every file that builds one" do
      built =
        for lib <- SourceTree.app_libs(root()),
            {path, lines} <- scan(lib <> "/**/*.ex"),
            Enum.any?(lines, &String.contains?(elem(&1, 0), "%Cyfr.Actor{")),
            constructed_at(SourceTree.read(Path.join(root(), path))) != [],
            do: path

      rostered = MapSet.new(Boundaries.actor_paths(), & &1.file)
      unrostered = built |> Enum.uniq() |> Enum.reject(&MapSet.member?(rostered, &1))

      assert unrostered == [],
             """
             A `%Cyfr.Actor{}` is built in a file the catalog does not name:

             #{Enum.join(unrostered, "\n")}

             J1's rule was that `Sanctum.Context.actor/1` is the only way to build
             one. There are four ways now, each defensible and in the right layer,
             and four is how you get six. Add the path to
             `Cyfr.Boundaries.actor_paths/0` with the reason it is not one of the
             four — or reach for one of them.
             """
    end

    test "every rostered path is still there, and says why it exists" do
      for row <- Boundaries.actor_paths() do
        source = SourceTree.read(Path.join(root(), row.file))
        name = row.path |> String.split(".") |> List.last() |> String.split("/") |> hd()

        assert source =~ ~r/def[p]? #{name}[( ]/,
               "#{row.path} is rostered and #{row.file} defines no #{name}"

        assert String.length(row.reason) > 60, "#{row.path} carries no reason"
      end
    end

    test "a built actor is found where a matched one is not" do
      assert constructed_at("defmodule A do\n  def a, do: %Cyfr.Actor{athanor_id: \"x\"}\nend\n") ==
               [2]

      assert constructed_at("defmodule A do\n  def a(%Cyfr.Actor{athanor_id: id}), do: id\nend\n") ==
               []

      assert constructed_at("defmodule A do\n  def a(x) do\n    %Cyfr.Actor{} = x\n  end\nend\n") ==
               []
    end
  end

  # The lines where a `%Cyfr.Actor{}` is BUILT — in expression position,
  # not matched in a function head, a `case` clause or the left of a
  # match. A regex cannot tell those apart; the parser can, so this walks
  # the tree and carries the one bit that decides it.
  defp constructed_at(source),
    do: source |> Code.string_to_quoted!() |> built(false) |> Enum.sort()

  defp built({:%, meta, [{:__aliases__, _, [:Cyfr, :Actor]}, {:%{}, _, fields}]}, false),
    do: [meta[:line] | built(fields, false)]

  defp built({:=, _meta, [lhs, rhs]}, pattern?), do: built(lhs, true) ++ built(rhs, pattern?)
  defp built({:<-, _meta, [lhs, rhs]}, pattern?), do: built(lhs, true) ++ built(rhs, pattern?)
  defp built({:->, _meta, [heads, body]}, _pattern?), do: built(heads, true) ++ built(body, false)

  defp built({op, _meta, [head | rest]}, _pattern?)
       when op in [:def, :defp, :defmacro, :defmacrop],
       do: built(head, true) ++ built(rest, false)

  defp built({left, _meta, right}, pattern?), do: built(left, pattern?) ++ built(right, pattern?)

  defp built({left, right}, pattern?), do: built(left, pattern?) ++ built(right, pattern?)
  defp built(list, pattern?) when is_list(list), do: Enum.flat_map(list, &built(&1, pattern?))
  defp built(_other, _pattern?), do: []

  # ---------------------------------------------------------------------------
  # 7. What the suites may name
  # ---------------------------------------------------------------------------

  describe "the suites" do
    test "no test module is defined twice" do
      defined =
        for path <- SourceTree.files!(Path.join(root(), "apps/*/test/**/*_test.exs")),
            {line, _n} <- path |> SourceTree.read() |> CodeLines.code_lines(),
            [name] <- Regex.scan(~r/^defmodule ([A-Z][\w.]*) do$/, line, capture: :all_but_first),
            do: {name, Path.relative_to(path, root())}

      duplicates =
        defined
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.filter(fn {_name, files} -> length(files) > 1 end)
        |> Enum.sort()

      assert duplicates == [],
             """
             A test module is defined in more than one file:

             #{Enum.map_join(duplicates, "\n", fn {name, files} -> "  #{name}: #{Enum.join(files, ", ")}" end)}

             The umbrella loads every suite into one VM, so the second definition
             replaces the first and which code each ran against follows app
             order. Two suites both defined `Opus.WorkerServiceTest` and it stood
             for four slices. A module name is one authoritative definition.
             """
    end

    test "a CYFR test names an Opus module only where the catalog says it may" do
      rostered = Boundaries.opus_named_by_cyfr_tests()

      offenders =
        for {path, lines} <- scan("apps/cyfr/test/**/*.{ex,exs}"),
            not Enum.any?(Map.keys(rostered), &covers?(&1, path)),
            {line, n} <- lines,
            line =~ ~r/\bOpus\.[A-Z]/,
            do: "#{path}:#{n}: #{String.trim(line)}"

      assert offenders == [],
             """
             A CYFR test names an Opus module outside the wiring suite:

             #{Enum.join(offenders, "\n")}

             `apps/cyfr/mix.exs` declares no dependency on `opus` and
             `apps/cyfr/lib` names no Opus module — that is the production
             boundary, and it is checked above. The suite is another matter: the
             umbrella loads both applications into one VM, and the integration
             suite's job is CYFR against a real worker service. So a CYFR test
             MAY name an Opus module, from `apps/cyfr/test/integration/` and the
             support that starts it, and everywhere else by a row in
             `Cyfr.Boundaries.opus_named_by_cyfr_tests/0` saying what it needs.
             """
    end

    test "every row of that roster still names a file that names Opus" do
      stale =
        for {pattern, _reason} <- Boundaries.opus_named_by_cyfr_tests(),
            not Enum.any?(scan("apps/cyfr/test/**/*.{ex,exs}"), fn {path, lines} ->
              covers?(pattern, path) and Enum.any?(lines, &(elem(&1, 0) =~ ~r/\bOpus\.[A-Z]/))
            end),
            do: pattern

      assert stale == [],
             "these rows name no file that names Opus any more: #{inspect(stale)}"
    end

    test "the builder's suite names nothing of the control plane" do
      # This test file plants control-plane names on purpose, and so does
      # the catalog; the builder's own suite may name none.
      allowed = Boundaries.reachable_layers(:locus)
      contracts = contracts_modules()

      reaches =
        for {path, named} <- names("apps/locus/test/**/*.{ex,exs}"),
            {name, n} <- named,
            (name |> String.split(".") |> hd()) in Boundaries.product_roots(),
            Boundaries.layer(name, contracts) not in allowed,
            do: "#{path}:#{n}: #{name}"

      assert reaches == [],
             """
             The builder's suite names the control plane:

             #{Enum.join(reaches, "\n")}

             The locus release carries the contracts alone, and its suite runs in
             a checkout that holds nothing else.
             """
    end
  end

  # `apps/cyfr/test/integration/**` covers everything under it; a plain
  # path covers itself.
  defp covers?(pattern, path) do
    case String.split(pattern, "/**") do
      [prefix, ""] -> String.starts_with?(path, prefix <> "/")
      _ -> pattern == path
    end
  end

  # ---------------------------------------------------------------------------
  # 8. What the tree must keep looking like
  # ---------------------------------------------------------------------------

  describe "the tree" do
    test "the shared primitives live in the glue namespace" do
      assert File.exists?(Path.join(root(), "apps/cyfr/lib/cyfr/bus.ex"))
      assert File.exists?(Path.join(root(), "apps/cyfr_contracts/lib/cyfr/uuid7.ex"))

      refute File.exists?(Path.join(root(), "apps/cyfr/lib/prism/topics.ex")),
             "Cyfr.Bus moved out of the console namespace; it must not come back"

      refute File.exists?(Path.join(root(), "apps/cyfr/lib/emissary/uuid7.ex")),
             "Cyfr.UUID7 moved out of the transport namespace; it must not come back"
    end

    test "the builder's copy of the line filter is the contracts' copy" do
      owner = SourceTree.read(Path.join(root(), "apps/cyfr_contracts/test/support/code_lines.ex"))
      copy = SourceTree.read(Path.join(root(), "apps/locus/test/support/code_lines.ex"))
      marker = "  # `Foo.Bar.{A, B}`"

      assert String.contains?(owner, marker) and String.contains?(copy, marker)

      assert body(owner, marker) == body(copy, marker),
             """
             `Locus.Test.CodeLines` and `Cyfr.Test.CodeLines` have drifted. The
             builder's suite loads nothing of the control plane's, so it keeps a
             copy — and a copy that classifies lines differently is two filters,
             which is two answers to what a dependency is.

             Regenerate the copy from the owner: everything from the multi-alias
             comment down is the same bytes.
             """
    end

    test "the catalog skips exactly one file, and the compiled scan covers it" do
      assert Boundaries.scan_exclusions() == ["apps/cyfr/lib/cyfr/boundaries.ex"]

      assert Enum.any?(compiled_reaches(:cyfr), fn {caller, _callee, _fun} ->
               caller == "Cyfr.Boundaries"
             end),
             "the compiled scan does not reach the one file the source scan skips"
    end
  end

  # Everything from `marker` to the end of the file: the part the copy and
  # the owner share byte for byte.
  defp body(source, marker) do
    {at, _length} = :binary.match(source, marker)
    binary_part(source, at, byte_size(source) - at)
  end
end
