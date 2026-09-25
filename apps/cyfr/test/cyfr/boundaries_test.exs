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

    * **A planted violation must fail.** A dependency, a route, a
      configuration key and a filesystem call are each planted below and
      shown reported. A catalog nobody can break is a catalog that checks
      nothing.
    * **An empty source scan must fail.** Every roster this replaces
      learned that the hard way, two of them this slice: a scan pointed at
      a moved tree passes every assertion it makes. So each scan is shown
      to have read code before its rosters are believed.
    * **Two scans, because neither sees everything.** The source scan,
      through `Prima.Test.CodeLines`, sees aliases, struct patterns,
      typespecs and compile-time attributes, which emit no call. The
      compiled scan, the import table of each `.beam`, sees every remote
      call the compiler emitted, including ones spelled in a way a regex
      would miss — and it is what covers `Cyfr.Boundaries` itself, the one
      file the source scan skips.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Boundaries
  alias Prima.Test.{CodeLines, SourceTree}

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
  # from the token stream, so a name in prose is not one. Given a surface
  # row, the files its `except` lists are not read.
  defp names(%{from: from} = row), do: names(from, Map.get(row, :except, []))
  defp names(globs), do: names(globs, [])

  defp names(globs, except) do
    skip = MapSet.new(Boundaries.scan_exclusions() ++ excepted(except))

    for glob <- List.wrap(globs),
        path <- SourceTree.files!(Path.join(root(), glob)),
        rel = Path.relative_to(path, root()),
        not MapSet.member?(skip, rel),
        do: {rel, SourceTree.aliases(path)}
  end

  # Every file an `except` glob matches, relative to the root.
  defp excepted(globs) do
    for glob <- globs,
        path <- Path.wildcard(Path.join(root(), glob)),
        do: Path.relative_to(path, root())
  end

  defp lines_read(scanned), do: Enum.sum(for {_path, lines} <- scanned, do: length(lines))

  # `.../Elixir.Cyfr.JCS.beam` is the module `Prima.JCS`. An Erlang module's
  # beam carries no prefix and yields its own name, which no layer claims.
  defp module_name(path),
    do: path |> Path.basename(".beam") |> String.replace_prefix("Elixir.", "")

  defp beams(app),
    do: app |> Application.app_dir("ebin") |> Path.join("*.beam") |> Path.wildcard()

  defp contracts_modules do
    :prima |> beams() |> Enum.map(&module_name/1) |> MapSet.new()
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

  # Every Sanctum function a beam (a path or a compiled binary) calls or
  # captures. A call is in the import table; an external capture
  # (`&Sanctum.Egress.pinned_request/5`) emits no import and is a fun in
  # the literal table instead, so both are read.
  defp sanctum_reaches(beam) do
    for {module, function, arity} <- beam_imports(beam) ++ beam_captures(beam),
        name = inspect(module),
        name == "Sanctum" or String.starts_with?(name, "Sanctum."),
        uniq: true,
        do: {name, function, arity}
  end

  defp beam_imports(beam) do
    {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports
  end

  # The literal table is `<<size::32, data>>`, `data` zlib-compressed unless
  # `size` is 0, and holds a count and then each term length-prefixed.
  defp beam_captures(beam) do
    case :beam_lib.chunks(beam, [~c"LitT"]) do
      {:ok, {_mod, [{~c"LitT", <<size::32, data::binary>>}]}} ->
        <<count::32, terms::binary>> = if size == 0, do: data, else: :zlib.uncompress(data)
        terms |> literal_terms(count) |> Enum.flat_map(&external_funs/1)

      _ ->
        []
    end
  end

  defp literal_terms(_binary, 0), do: []

  defp literal_terms(<<size::32, term::binary-size(size), rest::binary>>, count),
    do: [:erlang.binary_to_term(term) | literal_terms(rest, count - 1)]

  defp external_funs(fun) when is_function(fun) do
    info = Function.info(fun)

    if info[:type] == :external,
      do: [{info[:module], info[:name], info[:arity]}],
      else: []
  end

  defp external_funs(list) when is_list(list), do: improper_flat_map(list)
  defp external_funs(tuple) when is_tuple(tuple), do: external_funs(Tuple.to_list(tuple))

  defp external_funs(map) when is_map(map),
    do: map |> Map.to_list() |> external_funs()

  defp external_funs(_term), do: []

  defp improper_flat_map([head | tail]), do: external_funs(head) ++ improper_flat_map(tail)
  defp improper_flat_map([]), do: []
  defp improper_flat_map(tail), do: external_funs(tail)

  # The host application's production beams, as the Sanctum roster reads them.
  defp host_sanctum_reaches do
    for path <- beams(:cyfr),
        production?(path),
        reach <- sanctum_reaches(String.to_charlist(path)),
        uniq: true,
        do: reach
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

    test "every surface row reads code, and names, where it says it looks" do
      for row <- Boundaries.surfaces() do
        where = "the surface #{row.into} <- #{inspect(row.from)}"
        lines = lines_read(scan(row.from))
        named = Enum.sum(for {_path, names} <- names(row), do: length(names))

        assert lines > 100, "#{where} read #{lines} code lines — it is not reading"

        # Most of these rosters are empty and stay empty, so the reader
        # that finds nothing and the reader that reads nothing look alike.
        # The names view is the one the roster is compared against.
        assert named > 100, "#{where} found #{named} module names — it is not reading"
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

  describe "the storage doors" do
    # The files and records doors moved below the identity and component
    # domains: they take the actor the gate projects and name only Arca,
    # the contracts and Elixir. A reach back up (a namespace policy, the
    # context, a manifest owner above) is refused here as well as by the
    # graph, with the door named.
    test "Arca.Files and the Arca providers name nothing above Arca" do
      named = names(["apps/arca/lib/arca/files.ex", "apps/arca/lib/arca/providers/*.ex"])
      contracts = contracts_modules()

      assert Enum.map(named, &elem(&1, 0)) |> Enum.sort() ==
               ~w(apps/arca/lib/arca/files.ex apps/arca/lib/arca/providers/files.ex
                  apps/arca/lib/arca/providers/records.ex)

      reached =
        for {_path, names} <- named,
            {module, _line} <- names,
            uniq: true,
            do: {module, Boundaries.layer(module, contracts)}

      assert reached != [], "the scan of the storage doors found no names"
      assert {"Prima.Manifest", :prima} in reached
      assert {"Prima.ComponentNamespace", :prima} in reached

      above =
        for {module, layer} <- reached, layer not in [:arca, :prima, :outside], do: module

      assert above == [], "a storage door names a module above Arca: #{inspect(above)}"

      assert Boundaries.dependency_violations(:arca, named, contracts) == []
    end

    # Retention moved below the host with the doors. It is handed one actor
    # per estate and decides nothing about which estates are active, so it
    # names neither a layer above Arca nor the athanor rows that say so.
    test "retention names nothing above Arca, and not the athanor rows" do
      named =
        names([
          "apps/arca/lib/arca/retention.ex",
          "apps/arca/lib/arca/retention_settings.ex",
          "apps/arca/lib/arca/retention/*.ex"
        ])

      contracts = contracts_modules()

      assert "apps/arca/lib/arca/retention/projection_tombstones.ex" in Enum.map(
               named,
               &elem(&1, 0)
             )

      reached =
        for {_path, names} <- named,
            {module, _line} <- names,
            uniq: true,
            do: {module, Boundaries.layer(module, contracts)}

      assert {"Arca.StorageProjectionChanges", :arca} in reached,
             "the scan of retention found no names"

      above =
        for {module, layer} <- reached, layer not in [:arca, :prima, :outside], do: module

      assert above == [], "retention names a module above Arca: #{inspect(above)}"
      assert athanor_rows(named) == []
      assert Boundaries.dependency_violations(:arca, named, contracts) == []

      planted = [
        {"apps/arca/lib/arca/retention.ex",
         CodeLines.aliases(~S'''
         defmodule Arca.Retention do
           def active?(actor, id), do: Arca.Athanors.get(actor, id)
         end
         ''')}
      ]

      assert athanor_rows(planted) == ["apps/arca/lib/arca/retention.ex:2 names Arca.Athanors"]
    end

    test "a door that reaches back up is reported" do
      planted = [
        {"apps/arca/lib/arca/files.ex",
         CodeLines.aliases(~S'''
         defmodule Arca.Files do
           def local(p), do: Compendium.NamespacePolicy.require_local_register(p)
           def actor(ctx), do: Sanctum.Context.actor(ctx)
         end
         ''')}
      ]

      assert Enum.sort(Boundaries.dependency_violations(:arca, planted, contracts_modules())) == [
               "apps/arca/lib/arca/files.ex:2 names Compendium.NamespacePolicy (host); " <>
                 "arca may name [:arca, :prima, :outside]",
               "apps/arca/lib/arca/files.ex:3 names Sanctum.Context (sanctum); " <>
                 "arca may name [:arca, :prima, :outside]"
             ]
    end
  end

  defp athanor_rows(named) do
    for {path, names} <- named,
        {module, line} <- names,
        module == "Arca.Athanors" or String.starts_with?(module, "Arca.Athanors."),
        do: "#{path}:#{line} names #{module}"
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

  # `Prima.Authority.Blob.Edge` is named for its struct and type: a module
  # of the contracts, or a type spelled under one (`Prima.HostAPI.renewal`).
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
            extra = Boundaries.surface_violations(row, names(row)),
            extra != [],
            do: "#{inspect(row.from)} -> #{row.into}: #{inspect(extra)}\n  #{row.reason}"

      assert found == [],
             """
             A surface widened. Add the namespace to its row in `Cyfr.Boundaries`
             with a line saying why, or move the shared piece to Prima
             (`Prima.`) or the host's glue (`Cyfr.`) — several of these cross
             the licence boundary, and one of them is a domain naming a user
             interface.

             #{Enum.join(found, "\n\n")}
             """
    end

    test "no surface names something it has stopped reaching" do
      found =
        for row <- Boundaries.surfaces(),
            stale = Boundaries.stale_surface_entries(row, names(row)),
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

    test "only Sanctum and Arca name the storage modules that hold security rows" do
      row = security_row_seam()

      # The row reads every `lib` tree but the one reader's and the holder's.
      expected =
        for %{lib: lib} <- Boundaries.applications(),
            lib not in ["apps/sanctum/lib", "apps/arca/lib"],
            do: lib <> "/**/*.ex"

      assert Enum.sort(row.from) == Enum.sort(expected)

      assert Boundaries.surface_violations(row, names(row)) == [],
             "a module outside Sanctum names a security-row store — read it through Sanctum"

      # The one reader does name them, so a scan that found none above it
      # found none because there are none, not because it cannot see them.
      below = Boundaries.surface_reaches(row, names("apps/sanctum/lib/**/*.ex"))
      assert MapSet.member?(below, "Arca.ConsentStorage")
      assert MapSet.member?(below, "Arca.RegistryTokenStorage")
      assert MapSet.member?(below, "Arca.Members")
    end

    test "the security-row roster is exactly the fourteen stores, each a module" do
      assert Enum.sort(Boundaries.sanctum_only_storage()) ==
               Enum.sort(~w(
                 Arca.ConsentStorage Arca.ConsentProofStorage Arca.ProfileStorage
                 Arca.ToolGrantStorage Arca.VaultStorage Arca.SessionStorage
                 Arca.ApiKeyStorage Arca.RegistryTokenStorage Arca.ProviderCredentialStorage
                 Arca.WebhookStorage Arca.Users Arca.Members Arca.Athanors Arca.Doors
               ))

      for name <- Boundaries.sanctum_only_storage() do
        assert Code.ensure_loaded?(Module.concat([name])), "#{name} is not a module"
      end
    end

    test "a row's except names files its sources hold, and they go unread" do
      for %{except: except} = row <- Boundaries.surfaces() do
        read = MapSet.new(for {path, _names} <- names(row.from), do: path)

        for glob <- except do
          matched = MapSet.new(excepted([glob]))

          assert MapSet.size(MapSet.intersection(matched, read)) > 0,
                 "the surface #{inspect(row.from)} -> #{row.into} excepts #{glob}, " <>
                   "which names no file it reads"
        end
      end

      planted = %{
        from: ["apps/cyfr/lib/cyfr/**/*.ex"],
        except: ["apps/cyfr/lib/cyfr/application.ex"],
        into: "Aqua",
        allow: []
      }

      paths = for {path, _names} <- names(planted), do: path
      assert "apps/cyfr/lib/cyfr/bus.ex" in paths
      refute "apps/cyfr/lib/cyfr/application.ex" in paths

      assert "apps/cyfr/lib/cyfr/application.ex" in for(
               {path, _} <- names(planted.from),
               do: path
             )
    end

    test "every row says why its roster reads as it does" do
      for row <- Boundaries.surfaces() do
        assert is_binary(row.reason) and String.length(row.reason) > 40,
               "the surface #{inspect(row.from)} -> #{row.into} carries no reason"
      end
    end

    test "no line of a domain names an HTTP type" do
      row = Boundaries.http_free()
      scanned = scan(row.from)

      assert lines_read(scanned) > 100, "the HTTP-type scan read no code — it is not reading"

      assert "apps/sanctum/lib/sanctum/tincture_access.ex" in Enum.map(scanned, &elem(&1, 0))
      assert "apps/cyfr/lib/compendium/tincture.ex" in Enum.map(scanned, &elem(&1, 0))

      assert Boundaries.http_violations(scanned) == [],
             """
             A domain names a Plug connection or response. The request and the
             response are the surface adapter's (`CyfrWeb.Ingress.*`, a
             controller); the domain answers plain data and a typed refusal.

             #{Enum.join(Boundaries.http_violations(scanned), "\n")}
             """
    end

    test "the surface adapter is the one that does name them" do
      # A scan that finds nothing in the domains finds nothing because they
      # name nothing, not because the pattern cannot see a connection.
      adapter = scan("apps/cyfr/lib/cyfr_web/ingress/tincture_assets.ex")
      assert Boundaries.http_violations(adapter) != []
    end
  end

  # ---------------------------------------------------------------------------
  # 3. The routes
  # ---------------------------------------------------------------------------

  describe "the Sanctum exports" do
    test "the host calls exactly the rostered Sanctum functions" do
      reaches = host_sanctum_reaches()

      assert length(reaches) > 100,
             "the Sanctum scan found #{length(reaches)} functions — it is not reading"

      assert Boundaries.sanctum_export_violations(reaches) == [],
             """
             The host calls a Sanctum function the export roster does not
             list. Add it to `Cyfr.Boundaries.sanctum_exports/0`, or call an
             entry already listed.

             #{Enum.join(Boundaries.sanctum_export_violations(reaches), "\n")}
             """

      assert Boundaries.stale_sanctum_exports(reaches) == [],
             """
             The export roster lists Sanctum functions the host no longer
             calls. Remove them from `Cyfr.Boundaries.sanctum_exports/0`.

             #{Enum.join(Boundaries.stale_sanctum_exports(reaches), "\n")}
             """
    end

    test "every rostered function is a public function of a Sanctum module, listed once in order" do
      for {module, functions} <- Boundaries.sanctum_exports() do
        assert module == "Sanctum" or String.starts_with?(module, "Sanctum.")
        assert functions == Enum.sort(Enum.uniq(functions)), "#{module}'s list is not sorted"

        mod = Module.concat([module])
        assert Code.ensure_loaded?(mod), "#{module} is not a module"

        for {function, arity} <- functions do
          assert function_exported?(mod, function, arity),
                 "#{module}.#{function}/#{arity} is not exported"
        end
      end
    end

    test "a planted call or capture outside the roster is reported, and a dropped one is stale" do
      [{Cyfr.PlantedSanctumReach, binary}] =
        Code.compile_string(~S'''
        defmodule Cyfr.PlantedSanctumReach do
          def a(ctx), do: Sanctum.Context.tenant_ok(ctx)
          def b, do: &Sanctum.Egress.pinned_request/2
          def c(ctx), do: Sanctum.Context.actor(ctx)
        end
        ''')

      :code.purge(Cyfr.PlantedSanctumReach)
      :code.delete(Cyfr.PlantedSanctumReach)

      planted = sanctum_reaches(binary)

      assert Boundaries.sanctum_export_violations(planted) == [
               "Sanctum.Context.tenant_ok/1",
               "Sanctum.Egress.pinned_request/2"
             ]

      reaches = host_sanctum_reaches()
      assert Boundaries.sanctum_export_violations(reaches ++ planted) != []

      dropped = List.delete(reaches, {"Sanctum.Context", :actor, 1})
      assert Boundaries.stale_sanctum_exports(dropped) == ["Sanctum.Context.actor/1"]
    end
  end

  describe "the routes" do
    test "every HTTP route declares an auth posture from the vocabulary" do
      assert Boundaries.route_violations(Boundaries.routes()) == [],
             """
             A route does not say how it is authenticated. The posture is route
             metadata (`metadata: %{auth: …}`) so it travels with the route and a
             deleted route takes it with it; the vocabulary is
             `Cyfr.Boundaries.route_postures/0`. A route must not inherit auth by
             accident from a scope, and a route that admits a caller with no
             credential is named in `public_routes/0` as well.

             #{Enum.join(Boundaries.route_violations(Boundaries.routes()), "\n")}
             """
    end

    test "every rostered public route still exists" do
      stale = Boundaries.stale_public_routes(Boundaries.routes())

      assert stale == [],
             "the public-route roster names routes that are gone: #{inspect(stale)}"
    end

    test "every posture in the vocabulary is declared by at least one route" do
      declared =
        Boundaries.routes()
        |> Enum.map(& &1.metadata[:auth])
        |> MapSet.new()

      unused =
        Boundaries.route_postures()
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(declared, &1))

      assert unused == [],
             "these postures are in the vocabulary and no route declares them: #{inspect(unused)}"
    end

    test "every posture says what admits a caller to it, and why" do
      for {posture, row} <- Boundaries.route_postures() do
        assert row.admits in [:credential, :session, :flow_state, :nothing],
               "the posture #{inspect(posture)} admits #{inspect(row.admits)}, which is no tier"

        assert is_binary(row.why) and String.length(row.why) > 20,
               "the posture #{inspect(posture)} carries no sentence"
      end
    end

    test "the rostered routes are exactly the ones whose posture admits nothing" do
      anyone =
        Boundaries.routes()
        |> Enum.filter(&(&1.metadata[:auth] in Boundaries.public_postures()))
        |> Enum.map(&{&1.verb, &1.path})
        |> Enum.sort()

      assert anyone == Enum.sort(Boundaries.public_routes()),
             """
             The routes whose posture admits nothing are #{inspect(anyone)}; the
             roster names #{inspect(Enum.sort(Boundaries.public_routes()))}.

             A route anyone can reach is named one by one, so widening the tier
             of a posture cannot quietly open every route that declares it.
             """
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

  defp security_row_seam do
    Enum.find(Boundaries.surfaces(), &(Map.get(&1, :only) == Boundaries.sanctum_only_storage())) ||
      flunk("no surface row holds the security-row stores to Sanctum")
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
                 "arca may name [:arca, :prima, :outside]",
               "apps/arca/lib/arca/planted.ex:4 names Compendium.Resolver (host); " <>
                 "arca may name [:arca, :prima, :outside]"
             ]

      # The same file under the host, which may name both, is no violation.
      assert Boundaries.dependency_violations(:cyfr, planted, contracts_modules()) == []
    end

    test "a surface that widens is reported against its row" do
      row = Enum.find(Boundaries.surfaces(), &(&1.into == "Compendium" and &1.allow == []))

      planted = [
        {"apps/sanctum/lib/sanctum/planted.ex",
         CodeLines.aliases(
           "defmodule Sanctum.Planted do\n  alias Compendium.Registry.Client\nend\n"
         )}
      ]

      assert Boundaries.surface_violations(row, planted) == ["Compendium.Registry"]
    end

    test "a foundation that broadcasts, names the PubSub server or reaches the bus is reported" do
      planted = [
        {"apps/sanctum/lib/sanctum/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Sanctum.Planted do
           def announce(topic), do: Phoenix.PubSub.broadcast(Cyfr.PubSub, topic, :changed)
           def topic(actor), do: Cyfr.Bus.notify(actor)
         end
         ''')},
        {"apps/arca/lib/arca/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Arca.Planted do
           alias Cyfr.Bus.Components
           def announce(actor), do: Components.new(actor, :changed)
         end
         ''')}
      ]

      reported =
        for into <- ["Phoenix.PubSub", "Cyfr.PubSub", "Cyfr.Bus"],
            row = Enum.find(Boundaries.surfaces(), &(&1.into == into)),
            do: {into, Boundaries.surface_violations(row, planted)}

      assert reported == [
               {"Phoenix.PubSub", ["Phoenix.PubSub"]},
               {"Cyfr.PubSub", ["Cyfr.PubSub"]},
               {"Cyfr.Bus", ["Cyfr.Bus"]}
             ]

      for into <- ["Phoenix.PubSub", "Cyfr.PubSub", "Cyfr.Bus"] do
        row = Enum.find(Boundaries.surfaces(), &(&1.into == into))
        assert "apps/sanctum/lib/**/*.ex" in row.from and "apps/arca/lib/**/*.ex" in row.from
        assert row.allow == []
      end
    end

    test "the bus names nothing of the identity domain, a domain or a surface" do
      named = names(Boundaries.bus_free().from)

      assert Enum.sum(for {_path, names} <- named, do: length(names)) > 20,
             "the bus's own scan found no names — it is not reading"

      assert Boundaries.bus_violations(named) == []

      planted = [
        {"apps/cyfr/lib/cyfr/bus/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Cyfr.Bus.Planted do
           alias Sanctum.Context
           def a(%Context{} = ctx), do: Aqua.Runner.subscribe(ctx.athanor_id, "t")
           def b, do: Crucible.Events.flush("e")
           def c, do: Prima.Actor.system()
         end
         ''')}
      ]

      assert Boundaries.bus_violations(planted) == [
               "apps/cyfr/lib/cyfr/bus/planted.ex:2 names Sanctum.Context",
               "apps/cyfr/lib/cyfr/bus/planted.ex:3 names Aqua.Runner",
               "apps/cyfr/lib/cyfr/bus/planted.ex:4 names Crucible.Events"
             ]
    end

    test "the gate names no domain and no surface beyond its rostered reaches" do
      named = names(Boundaries.gate_free().from)

      assert Enum.sum(for {_path, names} <- named, do: length(names)) > 50,
             "the gate's own scan found no names — it is not reading"

      assert Boundaries.gate_violations(named) == []
      assert Boundaries.stale_gate_allowances(named) == []

      assert Boundaries.gate_free().allow == []

      planted = [
        {"apps/cyfr/lib/grimoire/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Grimoire.Planted do
           alias Emissary.External.Proxy
           def a(ctx), do: Proxy.list_external_tools(ctx)
           def b, do: Aqua.Runner.subscribe("ath", "t")
           def c, do: Task.Supervisor.async_nolink(Emissary.TaskSupervisor, fn -> :ok end)
           def d(ctx), do: PrismWeb.Focus.current(ctx)
           def e, do: Grimoire.Proxy.impl!()
         end
         ''')}
      ]

      assert Boundaries.gate_violations(planted) == [
               "apps/cyfr/lib/grimoire/planted.ex:2 names Emissary.External.Proxy",
               "apps/cyfr/lib/grimoire/planted.ex:4 names Aqua.Runner",
               "apps/cyfr/lib/grimoire/planted.ex:5 names Emissary.TaskSupervisor",
               "apps/cyfr/lib/grimoire/planted.ex:6 names PrismWeb.Focus"
             ]

      assert Boundaries.stale_gate_allowances(planted) == []
    end

    test "a direct read of a security row in a surface is reported, however it is spelled" do
      row = security_row_seam()

      planted = [
        {"apps/cyfr/lib/prism_web/live/planted_live.ex",
         CodeLines.aliases(~S'''
         defmodule PrismWeb.PlantedLive do
           alias Arca.Execution

           def public?(actor, ref), do: Arca.ConsentStorage.profiles(actor, ref)
           def run(actor, id), do: Execution.get(actor, id)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, planted) == ["Arca.ConsentStorage"]

      # Standing is a security row too: a surface that asks the membership
      # store who is seated, rather than Sanctum, is refused.
      standing = [
        {"apps/cyfr/lib/prism_web/live/planted_members_live.ex",
         CodeLines.aliases(~S'''
         defmodule PrismWeb.PlantedMembersLive do
           def seated(actor), do: Arca.Members.active_user_ids(actor)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, standing) == ["Arca.Members"]

      for name <- Boundaries.sanctum_only_storage() do
        ["Arca", store] = String.split(name, ".")

        aliased = [
          {"apps/cyfr/lib/aqua/planted.ex",
           CodeLines.aliases(
             "defmodule Aqua.Planted do\n  alias Arca.{Cache, #{store}}\n" <>
               "  def f(a), do: #{store}.get(a, Cache)\nend\n"
           )}
        ]

        assert Boundaries.surface_violations(row, aliased) == [name]
      end

      # The row looks where the planted surface sits.
      assert "apps/cyfr/lib/**/*.ex" in row.from
    end

    test "the console may call the consent entries and nothing of the plane behind them" do
      row =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Sanctum.Consent" and "apps/cyfr/lib/prism_web/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the console out of the consent plane")

      planted = [
        {"apps/cyfr/lib/prism_web/live/planted_consent_live.ex",
         CodeLines.aliases(~S'''
         defmodule PrismWeb.PlantedConsentLive do
           def public?(ctx, ref), do: Sanctum.Consent.profiles(ctx, ref)
           def grant(ctx), do: Sanctum.Consent.Commit.commit(ctx, %{})
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, planted) == ["Sanctum.Consent.Commit"]

      entries_only = [
        {"apps/cyfr/lib/prism_web/live/planted_consent_live.ex",
         CodeLines.aliases(~S'''
         defmodule PrismWeb.PlantedConsentLive do
           def public?(ctx, ref), do: Sanctum.Consent.profiles(ctx, ref)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, entries_only) == []
    end

    test "a component-domain reach into the assistant or into execution is reported" do
      into_aqua =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Aqua" and "apps/cyfr/lib/compendium/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the component domain out of the assistant")

      into_execution =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Crucible" and "apps/cyfr/lib/compendium/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the component domain out of execution")

      assert into_aqua.allow == []

      planted = [
        {"apps/cyfr/lib/compendium/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Compendium.Planted do
           def models(ctx), do: Aqua.Models.catalogue(ctx)
           def status(ctx), do: Aqua.model_status(ctx, [])
           def hand(tool), do: Aqua.Hands.catalyst_for(tool)
           def run(ctx, ref), do: Crucible.authority_for(ctx, :default, ref)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(into_aqua, planted) ==
               ["Aqua", "Aqua.Hands", "Aqua.Models"]

      assert Boundaries.surface_violations(into_execution, planted) == ["Crucible"]
    end

    test "execution naming a component-domain internal is reported" do
      row =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Compendium" and "apps/cyfr/lib/crucible/**/*.ex" in &1.from)
        ) || flunk("no surface row fences execution into the component domain's root")

      assert row.allow == ["Compendium"]
      assert "apps/cyfr/lib/crucible.ex" in row.from

      planted = [
        {"apps/cyfr/lib/crucible/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Crucible.Planted do
           def resolve(ctx, ref), do: Compendium.resolve(ctx, ref)
           def inspect(ctx, ref), do: Compendium.Component.inspect_component(ctx, ref)
           def graph(ctx, component), do: Compendium.Activation.resolve(ctx, component)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, planted) ==
               ["Compendium.Activation", "Compendium.Component"]
    end

    test "the assistant naming a component-domain internal is reported" do
      row =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Compendium" and "apps/cyfr/lib/aqua/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the assistant into the component domain's root")

      assert row.allow == ["Compendium"]
      assert "apps/cyfr/lib/aqua.ex" in row.from

      planted = [
        {"apps/cyfr/lib/aqua/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Aqua.Planted do
           alias Compendium.AgentSource

           def agent(ctx, name), do: Compendium.agent(ctx, name)
           def snapshot(ctx, name), do: Compendium.AgentIndex.snapshot(ctx, name)
           def roster(ctx), do: AgentSource.enabled_roster(ctx)
           def skills(ctx), do: Compendium.AquaSkills.index(ctx, 10)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, planted) ==
               ["Compendium.AgentIndex", "Compendium.AgentSource", "Compendium.AquaSkills"]
    end

    test "execution or the MCP surface naming the assistant is reported" do
      from_execution =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Aqua" and "apps/cyfr/lib/crucible/**/*.ex" in &1.from)
        ) || flunk("no surface row fences execution out of the assistant")

      from_mcp =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Aqua" and "apps/cyfr/lib/emissary/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the MCP surface out of the assistant")

      assert from_execution.allow == [] and from_mcp.allow == []

      planted = [
        {"apps/cyfr/lib/crucible/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Crucible.Planted do
           def kind(tool, action), do: Aqua.tool_kind(tool, action)
           def turn(ctx, id), do: Aqua.Runner.state(id, ctx.athanor_id)
         end
         ''')},
        {"apps/cyfr/lib/emissary/web/planted_controller.ex",
         CodeLines.aliases(~S'''
         defmodule Emissary.Web.PlantedController do
           alias Aqua.Notes
           def pinned(ctx), do: Notes.pinned_page(ctx)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(from_execution, planted) ==
               ["Aqua", "Aqua.Notes", "Aqua.Runner"]

      assert Boundaries.surface_violations(from_mcp, planted) ==
               ["Aqua", "Aqua.Notes", "Aqua.Runner"]
    end

    test "the console and the host name only the component domain's root; MCP names none" do
      find = fn tree ->
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Compendium" and "apps/cyfr/lib/#{tree}/**/*.ex" in &1.from)
        ) || flunk("no surface row fences #{tree} into the component domain's root")
      end

      rows = Enum.map(["cyfr_web", "prism", "prism_web"], find)

      planted = [
        {"apps/cyfr/lib/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Planted do
           alias Compendium.Registry.Client

           def sign_in(ctx, user), do: Compendium.complete_sign_in(ctx, user, :github, "t")
           def probe(ctx, user), do: Compendium.SignInSync.complete(ctx, user, :github, "t")
           def accept(v), do: Client.accept_policies(:github, "t", nil, v)

           def required({:error, %Compendium.OCI.Errors{} = err}),
             do: Compendium.OCI.Errors.required_version(err)
         end
         ''')}
      ]

      for row <- rows do
        assert row.allow == ["Compendium"]

        assert Boundaries.surface_violations(row, planted) ==
                 ["Compendium.OCI", "Compendium.Registry", "Compendium.SignInSync"]
      end

      mcp = find.("emissary")
      assert mcp.allow == []

      assert Boundaries.surface_violations(mcp, planted) ==
               ["Compendium", "Compendium.OCI", "Compendium.Registry", "Compendium.SignInSync"]
    end

    test "the console names the assistant's root, nothing more" do
      row =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Aqua" and "apps/cyfr/lib/prism_web/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the console into the assistant's root")

      assert row.allow == ["Aqua"]
      assert "apps/cyfr/lib/prism/**/*.ex" in row.from

      planted = [
        {"apps/cyfr/lib/prism_web/planted_live.ex",
         CodeLines.aliases(~S'''
         defmodule PrismWeb.PlantedLive do
           alias Aqua.Runner

           def roster(ctx), do: Aqua.roster(ctx)
           def work(fun), do: Task.Supervisor.start_child(Aqua.TaskSupervisor, fun)
           def follow(id, athanor_id), do: Runner.subscribe(id, athanor_id)
           def partials, do: Aqua.Loop.Stream.new()
           def kind(tool, action), do: Aqua.Kinds.kind_for(tool, action)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, planted) ==
               ["Aqua.Kinds", "Aqua.Loop", "Aqua.Runner", "Aqua.TaskSupervisor"]
    end

    test "the host names no domain but the component and execution domains' roots" do
      rows =
        for into <- ~w(Aqua Compendium Crucible Emissary),
            do:
              {into,
               Enum.find(
                 Boundaries.surfaces(),
                 &(&1.into == into and "apps/cyfr/lib/cyfr/**/*.ex" in &1.from)
               ) || flunk("no surface row fences the host out of #{into}")}

      # The composition router and the endpoint wire the MCP adapter in, as
      # the composition root does, so the host's row into it excepts them too.
      composition = %{
        "Emissary" => [
          "apps/cyfr/lib/cyfr/application.ex",
          "apps/cyfr/lib/cyfr_web/router.ex",
          "apps/cyfr/lib/cyfr_web/endpoint.ex"
        ]
      }

      for {into, row} <- rows do
        except = Map.get(composition, into, ["apps/cyfr/lib/cyfr/application.ex"])
        read = for {path, _} <- names(row), do: path

        assert "apps/cyfr/lib/cyfr_web/**/*.ex" in row.from
        assert row.except == except

        for path <- except, do: refute(path in read)
      end

      planted = [
        {"apps/cyfr/lib/cyfr/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Cyfr.Planted do
           def seeds, do: Compendium.sync_seeds()
           def sync, do: Compendium.Provisioning.sync_seeds()
           def roster(ctx), do: Aqua.roster(ctx)
           def run(ctx, ref), do: Crucible.authority_for(ctx, :default, ref)
           def admit(ctx, ref), do: Crucible.Admission.authority_for(ctx, :default, ref, [])
           def proxy, do: Emissary.External.Proxy
         end
         ''')}
      ]

      expected = %{
        "Aqua" => ["Aqua"],
        "Compendium" => ["Compendium.Provisioning"],
        "Crucible" => ["Crucible.Admission"],
        "Emissary" => ["Emissary.External"]
      }

      for {into, row} <- rows do
        assert Boundaries.surface_violations(row, planted) == expected[into]
      end
    end

    test "the assistant, the MCP surface and the console name only execution's root" do
      rows =
        for tree <- ["aqua", "emissary", "prism_web"],
            do:
              Enum.find(
                Boundaries.surfaces(),
                &(&1.into == "Crucible" and "apps/cyfr/lib/#{tree}/**/*.ex" in &1.from)
              ) || flunk("no surface row fences #{tree} into execution's root")

      planted = [
        {"apps/cyfr/lib/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Planted do
           def run(ctx, ref), do: Crucible.authority_for(ctx, :default, ref)
           def admit(ctx, ref), do: Crucible.Admission.authority_for(ctx, :default, ref, [])
           def charge(authority), do: Crucible.Charge.take(authority, [])
         end
         ''')}
      ]

      for row <- rows do
        assert Boundaries.surface_violations(row, planted) ==
                 ["Crucible.Admission", "Crucible.Charge"]
      end
    end

    test "the assistant reads consent's derivation and nothing of the plane that writes it" do
      row =
        Enum.find(
          Boundaries.surfaces(),
          &(&1.into == "Sanctum.Consent" and "apps/cyfr/lib/aqua/**/*.ex" in &1.from)
        ) || flunk("no surface row fences the assistant out of the consent plane")

      planted = [
        {"apps/cyfr/lib/aqua/planted.ex",
         CodeLines.aliases(~S'''
         defmodule Aqua.Planted do
           def declared(ctx, ref), do: Sanctum.Consent.ShapeDerivation.manifest_blocks(ctx, ref)
           def grant(ctx), do: Sanctum.Consent.Commit.commit(ctx, %{})
           def profiles(ctx, ref), do: Sanctum.Consent.profiles(ctx, ref)
         end
         ''')}
      ]

      assert Boundaries.surface_violations(row, planted) ==
               ["Sanctum.Consent", "Sanctum.Consent.Commit"]
    end

    test "a domain that takes a connection is reported with its file and line" do
      planted =
        {"apps/cyfr/lib/compendium/planted.ex",
         CodeLines.code_lines(~S'''
         defmodule Compendium.Planted do
           # A Plug.Conn in a comment is prose.
           def serve(conn, bytes), do: Plug.Conn.send_resp(conn, 200, bytes)
           def connect(domain), do: domain
         end
         ''')}

      assert Boundaries.http_violations([planted]) == [
               "apps/cyfr/lib/compendium/planted.ex:3: " <>
                 "def serve(conn, bytes), do: Plug.Conn.send_resp(conn, 200, bytes)"
             ]
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

    get "/planted/unclassified", CyfrWeb.Ingress.HealthController, :check

    get "/planted/unknown-posture", CyfrWeb.Ingress.HealthController, :check,
      metadata: %{auth: :made_up}

    get "/planted/unrostered-public", CyfrWeb.Ingress.HealthController, :check,
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

    test "every port has exactly one installation site, the boot's" do
      libs = for lib <- SourceTree.app_libs(root()), do: scan(lib <> "/**/*.ex")

      counts =
        for {behaviour, call, expected} <- Boundaries.boot_writes() do
          writes =
            for scanned <- libs,
                {path, lines} <- scanned,
                {line, n} <- lines,
                String.contains?(line, call),
                do: "#{path}:#{n}"

          assert Enum.all?(writes, &String.starts_with?(&1, expected <> ":")),
                 "`#{call}` is written at #{inspect(writes)}; the boot's write is in #{expected}"

          {behaviour, length(writes)}
        end

      assert counts == Enum.map(Boundaries.ports(), &{&1.behaviour, 1}),
             """
             Installation sites per port: #{inspect(counts)}. Each port is
             written once, at boot. A second writer means a process can read a
             different implementation depending on when it asked; none means
             the port refuses every call.
             """
    end

    test "the boot installs the five in order, before its supervisor starts" do
      source = SourceTree.read(Path.join(root(), "apps/cyfr/lib/cyfr/application.ex"))
      calls = for {_behaviour, call, _file} <- Boundaries.boot_writes(), do: call

      offsets =
        for call <- calls ++ ["Supervisor.start_link("] do
          {offset, _length} = :binary.match(source, call)
          offset
        end

      assert offsets == Enum.sort(offsets)
    end

    test "every port row names its declaring module, its implementation and the boot" do
      assert Enum.map(Boundaries.ports(), & &1.behaviour) == [
               "Prima.Caps",
               "Sanctum.Grimoire",
               "Sanctum.Consent.Components",
               "Grimoire.Proxy",
               "Arca.Storage.UnitLocator"
             ]

      for port <- Boundaries.ports() do
        assert is_binary(port.what) and is_binary(port.implemented_by)
        assert port.declared_by in [:prima, :arca, :sanctum, :cyfr]
        assert port.written_at_boot_by == "Cyfr.Application"
      end

      assert %{declared_by: :cyfr, implemented_by: "Emissary.External.Proxy"} =
               Enum.find(Boundaries.ports(), &(&1.behaviour == "Grimoire.Proxy"))
    end

    test "every declaring module installs, reads and refuses the one way" do
      for %{behaviour: behaviour} <- Boundaries.ports() do
        port = Module.concat([behaviour])
        error = Module.concat([behaviour, "NotInstalledError"])

        assert Code.ensure_loaded?(port) and function_exported?(port, :install!, 1) and
                 function_exported?(port, :impl!, 0),
               "#{behaviour} has no install!/1 and impl!/0"

        assert Code.ensure_loaded?(error) and function_exported?(error, :exception, 1),
               "#{behaviour} raises no #{inspect(error)}"
      end
    end

    test "the running boot installed each row's implementation" do
      installed =
        for %{behaviour: behaviour} <- Boundaries.ports(),
            do: {behaviour, Module.concat([behaviour]).impl!()}

      assert installed == [
               {"Prima.Caps", Sanctum.Tenancy.Caps},
               {"Sanctum.Grimoire", Grimoire.Catalog},
               {"Sanctum.Consent.Components", Compendium.ConsentFacts},
               {"Grimoire.Proxy", Emissary.External.Proxy},
               {"Arca.Storage.UnitLocator",
                %{"aqua" => Compendium.AquaPath, "components" => Compendium.ComponentPath}}
             ]
    end
  end

  describe "admission entries" do
    test "every row names a loaded module exporting its site, or a plug" do
      for %{module: module, site: site, plane: plane} <- Boundaries.admission_entries() do
        assert Code.ensure_loaded?(module), "#{inspect(module)} does not load"
        assert plane in [:external, :in_chain]

        assert function_exported?(module, site, 2) or
                 (site == :call and function_exported?(module, :init, 1)) or
                 function_exported?(module, site, 4) or function_exported?(module, site, 5),
               "#{inspect(module)} exports no #{site}"
      end
    end

    test "the identity plug decides nothing and is not an entry" do
      refute Enum.any?(
               Boundaries.admission_entries(),
               &(&1.module == CyfrWeb.Plugs.CallIdentity)
             )
    end

    test "each entry is rostered once" do
      keys = Enum.map(Boundaries.admission_entries(), &{&1.module, &1.site})
      assert keys == Enum.uniq(keys)
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
            Enum.any?(lines, &String.contains?(elem(&1, 0), "%Prima.Actor{")),
            constructed_at(SourceTree.read(Path.join(root(), path))) != [],
            do: path

      rostered = MapSet.new(Boundaries.actor_paths(), & &1.file)
      unrostered = built |> Enum.uniq() |> Enum.reject(&MapSet.member?(rostered, &1))

      assert unrostered == [],
             """
             A `%Prima.Actor{}` is built in a file the catalog does not name:

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
      assert constructed_at("defmodule A do\n  def a, do: %Prima.Actor{athanor_id: \"x\"}\nend\n") ==
               [2]

      assert constructed_at(
               "defmodule A do\n  def a(%Prima.Actor{athanor_id: id}), do: id\nend\n"
             ) ==
               []

      assert constructed_at("defmodule A do\n  def a(x) do\n    %Prima.Actor{} = x\n  end\nend\n") ==
               []
    end
  end

  describe "the system responsibilities" do
    test "the register is not empty, and each row names its modules, its check and why" do
      rows = Boundaries.system_responsibilities()
      refute Enum.empty?(rows), "the system-responsibility register is empty"

      for row <- rows do
        refute Enum.empty?(row.modules), "#{row.responsibility} names no module"

        for name <- row.modules do
          module = Module.concat([name])
          assert Code.ensure_loaded?(module), "#{row.responsibility} names #{name}, not a module"
        end

        [module, fun, arity] =
          Regex.run(~r/^(.+)\.(\w+)\/(\d+)$/, row.check, capture: :all_but_first)

        # `function_exported?/3` answers false for a module not yet loaded,
        # and a check no boot path calls is loaded on first use.
        Code.ensure_loaded(Module.concat([module]))

        assert function_exported?(
                 Module.concat([module]),
                 String.to_atom(fun),
                 String.to_integer(arity)
               ),
               "#{row.responsibility} names #{row.check}, which is not exported"

        assert String.length(row.reason) > 60, "#{row.responsibility} carries no reason"
      end
    end

    test "the projection recovery's read across estates is rostered, and its query says why" do
      assert %{modules: modules} =
               Enum.find(
                 Boundaries.system_responsibilities(),
                 &(&1.check == "Arca.StorageProjectionChanges.pending_athanors/2")
               ),
             "the storage projection recovery walk is not a rostered system responsibility"

      assert "Compendium.ProjectionReconciler" in modules

      # The one cross-estate query behind that check carries the marker the
      # unscoped-query seam reads, and names the roster row.
      source =
        SourceTree.read(Path.join(root(), "apps/arca/lib/arca/storage_projection_changes.ex"))

      assert source =~
               ~r/# arca:unscoped-ok .*system_responsibilities\/0.*\n\s+defp behind\(/
    end

    test "retention's walk across the estates is rostered, and its check refuses any other actor" do
      assert %{modules: ["Cyfr.RetentionScheduler"]} =
               Enum.find(
                 Boundaries.system_responsibilities(),
                 &(&1.check == "Arca.Retention.cleanup_athanor/2")
               ),
             "the retention walk is not a rostered system responsibility"

      # Refused before any query: only the server's own actor, narrowed to
      # one athanor, is what the row names.
      estate = %Prima.Actor{athanor_id: "ath_boundaries", scope: :athanor, system: true}

      assert {:error, :forbidden} = Arca.Retention.cleanup_athanor(%{estate | system: false})
      assert {:error, :forbidden} = Arca.Retention.cleanup_athanor(%{estate | scope: :platform})
      assert {:error, :no_athanor} = Arca.Retention.cleanup_athanor(%{estate | athanor_id: nil})
    end

    test "the host's decision purge is rostered, and its check refuses any other actor" do
      assert %{modules: ["Cyfr.RetentionScheduler"]} =
               Enum.find(
                 Boundaries.system_responsibilities(),
                 &(&1.check == "Arca.DecisionLog.purge_global/2")
               ),
             "the host's decision purge is not a rostered system responsibility"

      # Refused before any query: only the platform's own system actor.
      cutoff = DateTime.utc_now()
      system = Prima.Actor.system()

      for actor <- [
            %{system | system: false},
            %{system | scope: :athanor, athanor_id: "ath_boundaries"},
            %{Prima.Actor.in_athanor("ath_boundaries") | platform_admin: true}
          ] do
        assert {:error, :forbidden} = Arca.DecisionLog.purge_global(actor, cutoff)
      end
    end

    test "every module that passes a retirement's check is rostered with it" do
      rostered =
        for row <- Boundaries.system_responsibilities(),
            check = row.check |> String.split("/") |> hd(),
            name <- row.modules,
            into: MapSet.new(),
            do: {check, name}

      passing =
        for lib <- SourceTree.app_libs(root()),
            {path, lines} <- scan(lib <> "/**/*.ex"),
            row <- Boundaries.system_responsibilities(),
            check = row.check |> String.split("/") |> hd(),
            Enum.any?(lines, &String.contains?(elem(&1, 0), check)),
            [_, module] =
              Regex.run(~r/^defmodule ([\w.]+) do/m, SourceTree.read(Path.join(root(), path))),
            do: {check, module}

      assert passing != [], "no module passes a rostered check: the scan read nothing"
      assert Enum.reject(passing, &MapSet.member?(rostered, &1)) == []
    end
  end

  # The lines where a `%Prima.Actor{}` is BUILT — in expression position,
  # not matched in a function head, a `case` clause or the left of a
  # match. A regex cannot tell those apart; the parser can, so this walks
  # the tree and carries the one bit that decides it.
  defp constructed_at(source),
    do: source |> Code.string_to_quoted!() |> built(false) |> Enum.sort()

  defp built({:%, meta, [{:__aliases__, _, [:Prima, :Actor]}, {:%{}, _, fields}]}, false),
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
      # Read from here rather than from Locus's own suite, which used to
      # hold it: the builder's suite runs in a checkout with nothing of
      # the control plane in it, so a roster that names what it may not
      # name cannot live there without naming it.
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
  # 8. The filesystem seam
  # ---------------------------------------------------------------------------

  describe "the filesystem seam" do
    test "no application makes a direct filesystem call without its marker" do
      seam = Boundaries.filesystem_seam()
      tree = filesystem_tree()

      calls =
        for {_path, _source, lines} <- tree, {line, _n} <- lines, line =~ seam.call, do: line

      assert lines_read(for {path, _source, lines} <- tree, do: {path, lines}) > 100,
             "the filesystem scan read no code — it is not reading"

      # The tree makes marked calls, so a pattern that stopped matching
      # would read as a tree that makes none.
      assert length(calls) > 10,
             "the filesystem scan found #{length(calls)} calls — the pattern is not matching"

      found = Boundaries.filesystem_violations(tree)

      assert found == [],
             """
             A direct filesystem call carries no `#{seam.marker}` marker on its
             line or within the #{seam.window} lines above it:

             #{Enum.join(found, "\n")}

             Route it through `Arca.Storage`, or mark the call with the bypass
             group `Arca.Storage` documents for it: `# arca:bypass-ok=<A-E> — why`.
             """
    end

    test "every exemption the row names still exempts a file" do
      stale = Boundaries.stale_filesystem_exemptions(filesystem_tree())

      assert stale == [],
             "these exemptions exempt no file any more; remove them: #{inspect(stale)}"

      # A tree none of them fits reports every one.
      seam = Boundaries.filesystem_seam()
      planted = planted_file("apps/cyfr/lib/cyfr/planted.ex", "defmodule Cyfr.Planted do\nend\n")

      assert Boundaries.stale_filesystem_exemptions([planted]) ==
               seam.exempt ++ [Regex.source(seam.entire_module)]
    end

    test "an unmarked call is reported with its file and line" do
      planted =
        planted_file("apps/cyfr/lib/cyfr/planted.ex", ~S'''
        defmodule Cyfr.Planted do
          @moduledoc "Reads a file."

          def read(path), do: File.read(path)
        end
        ''')

      assert Boundaries.filesystem_violations([planted]) ==
               ["apps/cyfr/lib/cyfr/planted.ex:4: def read(path), do: File.read(path)"]
    end

    test "each call the row names is reported, and a near miss is not" do
      planted =
        planted_file("apps/cyfr/lib/cyfr/planted.ex", ~S'''
        defmodule Cyfr.Planted do
          def a(p), do: File.write!(p, "")
          def b(p), do: Path.wildcard(p)
          def c(p), do: :file.read_file(p)
          def d(p), do: :filelib.is_dir(p)
          def e(p), do: :erl_tar.extract(p)
          def f(p), do: :prim_file.read_file(p)
          def g(p), do: Arca.File.read(p)
          def h(p), do: MyFile.read(p)
          def i(%File.Stat{} = s), do: s
          def j(p), do: :files.read(p)
          def k(p), do: Path.join(p, "x")
        end
        ''')

      assert planted |> List.wrap() |> Boundaries.filesystem_violations() |> line_numbers() ==
               [2, 3, 4, 5, 6, 7]
    end

    test "a marker on the call's line or within four lines above covers it" do
      planted =
        planted_file("apps/cyfr/lib/cyfr/planted.ex", ~S'''
        defmodule Cyfr.Planted do
          def a(p), do: File.read(p) # arca:bypass-ok=D — same line

          # arca:bypass-ok=D — four lines above the call
          @scratch "tmp"

          def b(p),
            do: File.read(Path.join(@scratch, p))
        end
        ''')

      assert Boundaries.filesystem_violations([planted]) == []
    end

    test "a marker five lines above, or below, covers nothing" do
      planted =
        planted_file("apps/cyfr/lib/cyfr/planted.ex", ~S'''
        defmodule Cyfr.Planted do
          # arca:bypass-ok=D — five lines above the call
          @scratch "tmp"


          def b(p),
            do: File.read(Path.join(@scratch, p))

          def c(p), do: File.rm(p)
          # arca:bypass-ok=D — one line below the call
        end
        ''')

      assert planted |> List.wrap() |> Boundaries.filesystem_violations() |> line_numbers() ==
               [7, 9]
    end

    test "the entire-module marker exempts the file, for a group the seam names" do
      source = fn group ->
        """
        defmodule Locus.Planted do
          @moduledoc \"\"\"
          Builds in a scratch sandbox.

          ## arca:bypass-ok=#{group} — entire module
          \"\"\"

          @root "/tmp"

          def a(p), do: File.read(Path.join(@root, p))
        end
        """
      end

      assert Boundaries.filesystem_violations([
               planted_file("apps/locus/lib/locus/planted.ex", source.("D"))
             ]) == []

      assert Boundaries.filesystem_violations([
               planted_file("apps/locus/lib/locus/planted.ex", source.("F"))
             ])
             |> line_numbers() == [10]
    end

    test "the adapters and the storage behaviour are the seam, not callers of it" do
      source = "defmodule Arca.Planted do\n  def a(p), do: File.read(p)\nend\n"

      exempt =
        for path <- [
              "apps/arca/lib/arca/adapters/local.ex",
              "apps/arca/lib/arca/adapters/planted.ex",
              "apps/arca/lib/arca/storage.ex"
            ],
            do: planted_file(path, source)

      assert Boundaries.filesystem_violations(exempt) == []

      assert Boundaries.filesystem_violations([
               planted_file("apps/arca/lib/arca/storage_helper.ex", source),
               planted_file("apps/arca/lib/arca/adapters.ex", source)
             ]) == [
               "apps/arca/lib/arca/storage_helper.ex:2: def a(p), do: File.read(p)",
               "apps/arca/lib/arca/adapters.ex:2: def a(p), do: File.read(p)"
             ]
    end

    test "a call in a comment or in documentation is not a call" do
      planted =
        planted_file("apps/cyfr/lib/cyfr/planted.ex", ~S'''
        defmodule Cyfr.Planted do
          @moduledoc """
          Once read with File.read(path).
          """

          # def a(p), do: File.read(p)
          #   :file.delete(p)
          def b(p), do: p # File.rm(p)

          @doc "Not File.read(p)."
          def c(p), do: p
        end
        ''')

      assert Boundaries.filesystem_violations([planted]) == []
    end
  end

  # Every file the seam reads, with its text for the marker and its code
  # lines for the calls. Unlike `scan/1`, the catalog's own file is read.
  defp filesystem_tree do
    for path <- SourceTree.files!(Path.join(root(), Boundaries.filesystem_seam().from)),
        do: {Path.relative_to(path, root()), SourceTree.read(path), SourceTree.code_lines(path)}
  end

  # A planted file as the seam reads one: its text, and its code lines
  # through the one filter.
  defp planted_file(path, source), do: {path, source, CodeLines.code_lines(source)}

  defp line_numbers(found) do
    for violation <- found do
      [_path, n | _rest] = String.split(violation, ":", parts: 3)
      String.to_integer(n)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. What the tree must keep looking like
  # ---------------------------------------------------------------------------

  describe "the tree" do
    test "the shared primitives live in Prima, and the bus in the host" do
      assert File.exists?(Path.join(root(), "apps/cyfr/lib/cyfr/bus.ex"))
      assert File.exists?(Path.join(root(), "apps/prima/lib/prima/uuid7.ex"))

      refute File.exists?(Path.join(root(), "apps/cyfr/lib/prism/topics.ex")),
             "Cyfr.Bus is the host's, not the console's; it must not come back"

      refute File.exists?(Path.join(root(), "apps/cyfr/lib/emissary/uuid7.ex")),
             "Prima.UUID7 is a shared primitive, not the transport's; it must not come back"
    end

    test "the builder's copy of the line filter is the contracts' copy" do
      owner = SourceTree.read(Path.join(root(), "apps/prima/test/support/code_lines.ex"))
      copy = SourceTree.read(Path.join(root(), "apps/locus/test/support/code_lines.ex"))
      marker = "  # `Foo.Bar.{A, B}`"

      assert String.contains?(owner, marker) and String.contains?(copy, marker)

      assert body(owner, marker) == body(copy, marker),
             """
             `Locus.Test.CodeLines` and `Prima.Test.CodeLines` have drifted. The
             builder's suite loads nothing of the control plane's, so it keeps a
             copy — and a copy that classifies lines differently is two filters,
             which is two answers to what a dependency is.

             Regenerate the copy from the owner: everything from the multi-alias
             comment down is the same bytes.
             """
    end

    test "the five retired helper modules neither load nor are named in any tracked source" do
      # Spelled in parts, so this file is not itself a mention.
      retired = ~w(Models TinctureHelpers ConsentDrift ScheduleNotes Text)

      for suffix <- retired do
        module = Module.concat(Cyfr, suffix)
        refute Code.ensure_loaded?(module), "#{inspect(module)} still loads"
      end

      pattern = Regex.compile!("\\bCyfr\\.(?:" <> Enum.join(retired, "|") <> ")\\b")

      sources =
        for glob <- [
              "apps/*/lib/**/*.{ex,heex}",
              "apps/*/test/**/*.{ex,exs}",
              "apps/*/mix.exs",
              "apps/*/*.md",
              "config/**/*.exs",
              "mix.exs",
              "*.md"
            ],
            path <- Path.wildcard(Path.join(root(), glob)),
            do: path

      assert length(sources) > 500,
             "the scan found #{length(sources)} sources — it is not reading"

      named =
        for path <- sources,
            SourceTree.read(path) =~ pattern,
            do: Path.relative_to(path, root())

      assert named == [], "a retired helper is still named in: #{inspect(named)}"
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
