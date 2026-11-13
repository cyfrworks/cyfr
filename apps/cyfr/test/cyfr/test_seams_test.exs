# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestSeamsTest do
  # Every test seam, in Arca, Sanctum and the host, is read only by a build
  # compiled with the test permission (`:prima, :test_seams_permitted`): a
  # release, compiled without it, answers each seam's shipped default and
  # never reads the key (`Prima.TestSeam.value/2`). Async: it reads source
  # files and sets nothing.
  #
  # It holds what a lib file's syntax tree writes, not a name or call that code builds (`apply/3`,
  # `Module.concat/1`, a macro computing what it emits): tests/release-boot/test_seams.exs proves those.
  use ExUnit.Case, async: true

  alias Cyfr.Boundaries
  alias Prima.Test.SourceTree

  @root Path.expand("../../../..", __DIR__)

  # The calls that read an application's environment, by their module:
  # under a named key (a literal atom, or `__MODULE__`), or without one.
  @named %{
    Application => [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!],
    :application => [:get_env]
  }
  @bulk %{Application => [:get_all_env], :application => [:get_all_env, :get_key]}

  # Configuration read under the module's own name rather than a key, and
  # a seam's all the same: the projection reconciler's (`config/test.exs`
  # turns it off). A module key is named as its source spells it.
  @module_keyed ["Compendium.ProjectionReconciler"]

  # The reads in any application's code whose application is not a literal
  # atom, by file and function, each with its reason. Exact: another such
  # read fails until someone decides it.
  @unnamed_applications %{
    {"apps/cyfr/lib/cyfr/platform/settings.ex", :configured} =>
      "the platform settings' reader: each entry's application and key are the " <>
        "settings roster's (`Cyfr.Platform.Settings.Roster`), which holds no seam's key",
    {"apps/cyfr/lib/cyfr/release.ex", :repos} =>
      "the release tasks' read of the repositories under `@app`, which is `:arca`"
  }

  # The seams each application's code reads through the gate, each once. A
  # seam no read goes through any more is a key to drop from
  # `Cyfr.Boundaries` and the test configurations.
  @seams_read %{
    arca: [
      :control_plane_claim_enabled,
      :control_plane_pool,
      :decision_log_budget_ms,
      :record_sink_inline,
      :write_turn
    ],
    cyfr: [
      "Compendium.ProjectionReconciler",
      :crew_delivery_enabled,
      :cron_scheduler_enabled,
      :database_checks_enabled,
      :egress_resolver,
      :execution_archive_watch_enabled,
      :execution_sweeper_enabled,
      :external_server_reconciler_enabled,
      :provisioning_boot_enabled,
      :registry_health_probe,
      :retention_scheduler_enabled,
      :schedule_notes_enabled,
      :status_watch_enabled,
      :thread_recovery,
      :tincture_rate_limit_max,
      :worker_watch_enabled
    ],
    sanctum: [
      :caller_memo_ttl_ms,
      :directory_client,
      :namespace_cache_ttl_ms,
      :oidc_reauth_client,
      :scripted_oauth_provider,
      :workos_api_url
    ]
  }

  # The code a branch compiled only with the permission holds
  # (`if Application.compile_env(:prima, :test_seams_permitted, false)`),
  # which every other build leaves out entirely.
  @compiled_out [{:sanctum, :tenancy_resolver_override}]

  # The permission's readers: the gate, which compiles it into each caller,
  # and Sanctum's two compile-time branches. Each reads it at compile time.
  @permission_readers [
    "apps/prima/lib/prima/test_seam.ex",
    "apps/sanctum/lib/sanctum/issuance.ex",
    "apps/sanctum/lib/sanctum/tenancy.ex"
  ]

  # The decision holds for a seam only where its read goes through it.
  # Every read of Arca's, Sanctum's and the host's application environment
  # in every application's code, read as code: a key `Cyfr.Boundaries`
  # classes `:seam` is read inside the function `Prima.TestSeam.value/2`
  # is handed as its read (never in its default), inside a branch compiled
  # only with the permission, or by
  # `compile_env`, which fixes it when the release is built; and a read
  # inside a seam is a seam's key. tests/release-boot/test_seams.exs and
  # the restores case of tests/release-boot/boot.sh hold the shipped
  # release to the same seams.
  test "every read of a seam's key is inside Prima.TestSeam.value/2, compiled out, or compiled" do
    seams = seams()
    found = found()
    gated = for %{app: app} = read <- found, app in [:arca, :cyfr, :sanctum], do: read

    outside =
      for %{key: key, gate: :plain, fun: fun} = read <- gated,
          key in seams,
          fun not in [:compile_env, :compile_env!],
          do: read

    assert outside == [], "a seam's key read outside Prima.TestSeam.value/2: #{inspect(outside)}"

    # A read that names no key (`Application.get_all_env(:cyfr)`,
    # `:application.get_all_env(:arca)`, `:application.get_key(:sanctum, :env)`)
    # or names it by a value holds every seam's key at once, and a release
    # would answer what its configuration says: none is read, inside a seam
    # or out.
    unnamed = for %{key: key} = read <- gated, key in [:bulk, :dynamic], do: read

    assert unnamed == [],
           "a read of an application's environment names no key: #{inspect(unnamed)}"

    # A read names its application as a literal atom: one named by a
    # variable, an attribute or a call could be a gated application and
    # read a seam's key past every rule above. The exceptions are the list
    # above; the settings reader's stays one because its roster names no
    # seam's key.
    unnamed_applications =
      for %{app: :unnamed_application, file: file, function: function} <- found,
          do: {file, function}

    assert Enum.sort(unnamed_applications) == Enum.sort(Map.keys(@unnamed_applications)),
           "reads whose application is not a literal atom: #{inspect(unnamed_applications)}"

    rostered =
      for %Cyfr.Platform.Settings.Roster.Entry{config: [key | _]} <-
            Cyfr.Platform.Settings.Roster.entries(),
          key in seams,
          do: key

    assert rostered == []

    inside = for %{gate: :seam} = read <- gated, do: read
    assert Enum.reject(inside, &(&1.key in seams)) == [], inspect(inside)

    by_app = Enum.group_by(inside, & &1.app, & &1.key)

    assert Map.new(by_app, fn {app, keys} -> {app, Enum.sort(keys)} end) ==
             Map.new(@seams_read, fn {app, keys} -> {app, Enum.sort(keys)} end)

    compiled_out =
      for %{gate: :compiled_out} = read <- gated, uniq: true, do: {read.app, read.key}

    assert compiled_out == @compiled_out

    # The permission is read at compile time and nowhere else.
    permission = for %{app: :prima, key: :test_seams_permitted} = read <- found, do: read
    assert Enum.all?(permission, &(&1.fun in [:compile_env, :compile_env!])), inspect(permission)
    assert permission |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort() == @permission_readers
  end

  # A seam is read only through `value/2`, which decides with the
  # permission its caller was compiled with. `value/3` takes the permission
  # as an argument, so a call of it with `true` would read a seam in a
  # release: nothing calls or captures it but the macro's own expansion,
  # and nothing names the gate but to require it and call `value/2`.
  test "nothing names the gate but through value/2, and value/3 only in the macro's expansion" do
    named =
      for path <- lib_files(),
          use <- gate_uses(SourceTree.quoted(path), false),
          use not in [:require, {:call, :value, 2}],
          do: {Path.relative_to(path, @root), use}

    assert named == [
             {"apps/prima/lib/prima/test_seam.ex", :defmodule},
             {"apps/prima/lib/prima/test_seam.ex", {:quoted, {:call, :value, 3}}}
           ],
           "the gate named but through value/2: #{inspect(named)}"
  end

  # The rules above match `Application` (with `:application`) and
  # `Prima.TestSeam` by name, so each is written by its full plain name and
  # nothing else, read on the syntax tree: no alias, `require ..., as:` or
  # import of either; no alias of a prefix of either (`Elixir`, `Prima`),
  # single or in braces; no alias or nested module that makes `Application`,
  # `Prima` or `Elixir` name another module; neither the `Elixir.`
  # spelling nor the atom of either; and every alias, require and import,
  # inside a quote too, names its target literally.
  test "Application and the gate are written by their full plain names alone" do
    quoted = for path <- lib_files(), do: {Path.relative_to(path, @root), SourceTree.quoted(path)}

    renamed = for {file, ast} <- quoted, renaming <- renamings(ast), do: {file, renaming}
    assert renamed == []

    # The scan reads the directives it holds: the tree writes hundreds.
    directives =
      for {_file, ast} <- quoted,
          {_ast, found} = Macro.prewalk(ast, 0, &count_directive/2),
          reduce: 0,
          do: (total -> total + found)

    assert directives > 500
  end

  # A macro that injects `directive` with the name it is handed, invoked
  # with `Application`, as a caller's own lines.
  injected = fn directive ->
    "defmodule Sanctum.SeamAlias do\n  defmacro bind(target) do\n    quote do\n      " <>
      directive <>
      "\n    end\n  end\nend\nrequire Sanctum.SeamAlias\nSanctum.SeamAlias.bind(Application)\n"
  end

  # Each form a file could read a seam's key or reach `value/3` with, past
  # a check that matched by spelling, is refused; an honest file passes.
  @refused_forms [
    "require Prima.TestSeam\n" <>
      "def read, do: Prima.TestSeam.value(fn -> Application.get_env(:arca, :control_plane_pool, true) end, " <>
      "fn -> fn -> false end end).()",
    "require Prima.TestSeam\n" <>
      "def read, do: Prima.TestSeam.value(pool(), fn -> false end)\n" <>
      "defp pool, do: Application.get_env(:arca, :control_plane_pool, true)",
    "def read, do: Prima.TestSeam.value(true, :shipped, fn -> :read end)",
    "def read, do: Elixir.Prima.TestSeam.value(true, :shipped, fn -> :read end)",
    "def read do\n  decision = &Elixir.Prima.TestSeam.value/3\n  decision.(true, :shipped, fn -> :read end)\nend",
    "require Prima.TestSeam, as: Gate\ndef read, do: Gate.value(true, :shipped, fn -> :read end)",
    "alias Elixir, as: Root\nalias Root.Application, as: Env\ndef read, do: Env.get_env(:sanctum, :workos_api_url)",
    "require Application, as: Env\ndef read, do: Env.get_env(:sanctum, :workos_api_url)",
    "alias Application, as: Env\ndef read, do: Env.get_env(:sanctum, :workos_api_url)",
    "alias :application, as: Env\ndef read, do: Env.get_env(:sanctum, :workos_api_url)",
    "import Application\ndef read, do: get_env(:sanctum, :workos_api_url)",
    "import Prima.TestSeam\ndef read, do: value(true, :shipped, fn -> :read end)",
    "alias Prima.TestSeam\ndef read, do: TestSeam.value(true, :shipped, fn -> :read end)",
    "alias Prima.TestSeam, as: Gate\ndef read, do: Gate.value(true, :shipped, fn -> :read end)",
    "alias Prima\ndef read, do: Prima.TestSeam.value(true, :shipped, fn -> :read end)",
    "alias Prima, as: P\ndef read, do: P.TestSeam.value(true, :shipped, fn -> :read end)",
    "alias Prima.{TestSeam}\ndef read, do: TestSeam.value(true, :shipped, fn -> :read end)",
    "alias Elixir.{Application}\ndef read, do: Application.get_env(:sanctum, :workos_api_url)",
    "def read, do: Elixir.Application.get_env(:sanctum, :workos_api_url)",
    "def read, do: :\"Elixir.Application\".get_env(:sanctum, :workos_api_url)",
    "def read, do: :\"Elixir.Prima.TestSeam\".value(true, :shipped, fn -> :read end)",
    "alias Sanctum.Fake, as: Prima\nrequire Prima.TestSeam\n" <>
      "def read, do: Prima.TestSeam.value(nil, fn -> Application.get_env(:sanctum, :workos_api_url) end)",
    "alias Sanctum.Fake.Application\ndef read, do: Application.get_env(:sanctum, :workos_api_url)",
    "defmodule Prima.TestSeam do\nend\nrequire Prima.TestSeam\n" <>
      "def read, do: Prima.TestSeam.value(nil, fn -> Application.get_env(:sanctum, :workos_api_url) end)",
    "def read, do: Application.get_env(:sanctum, :workos_api_url)",
    injected.("alias unquote(target), as: Env") <>
      "def read, do: Env.get_env(:sanctum, :workos_api_url)",
    injected.("require unquote(target), as: Env") <>
      "def read, do: Env.get_env(:sanctum, :workos_api_url)",
    injected.("import unquote(target)") <> "def read, do: get_env(:sanctum, :workos_api_url)"
  ]

  @honest_form """
  alias Sanctum.Context
  require Prima.TestSeam

  def read(%Context{}),
    do: Prima.TestSeam.value(nil, fn -> Application.get_env(:sanctum, :workos_api_url) end)
  """

  test "every form that renames, respells or reaches past the gate is refused; an honest file passes" do
    for form <- @refused_forms do
      assert refusals(form) != [], "passed: #{form}"
    end

    assert refusals(@honest_form) == []
  end

  test "the permission is the test configurations' and no other's" do
    setting =
      for path <-
            Path.wildcard(Path.join(@root, "config/*.exs")) ++
              Path.wildcard(Path.join(@root, "apps/*/config/*.exs")),
          File.read!(path) =~ ~r/test_seams_permitted/,
          do: Path.relative_to(path, @root)

    assert Enum.sort(setting) ==
             ["apps/arca/config/config.exs", "apps/sanctum/config/config.exs", "config/test.exs"]

    assert File.read!(Path.join(@root, "config/test.exs")) =~
             ~r/^config :prima, test_seams_permitted: true$/m

    # An island's file sets it under test alone.
    for island <- ["apps/arca/config/config.exs", "apps/sanctum/config/config.exs"] do
      [shipped, under_test] =
        @root
        |> Path.join(island)
        |> File.read!()
        |> String.split("if config_env() == :test do", parts: 2)

      refute shipped =~ "test_seams_permitted", island
      assert under_test =~ ~r/^  config :prima, test_seams_permitted: true$/m, island
    end
  end

  # Each place `ast` names `Prima.TestSeam`, in source order: `:require`,
  # `:defmodule`, `{:call, fun, arity}`, `{:capture, fun, arity}`, or
  # `:other` for any other mention (an alias, an argument); a call inside a
  # `quote` is `{:quoted, call}`.
  defp gate_uses({:quote, _, args}, _quoted), do: gate_uses(args, true)

  defp gate_uses({:require, _, [alias | rest]} = ast, quoted) do
    if gate?(alias), do: [:require | gate_uses(rest, quoted)], else: gate_walk(ast, quoted)
  end

  defp gate_uses({:defmodule, _, [alias | rest]} = ast, quoted) do
    if gate?(alias), do: [:defmodule | gate_uses(rest, quoted)], else: gate_walk(ast, quoted)
  end

  defp gate_uses({:&, _, [{:/, _, [{{:., _, [alias, fun]}, _, []}, arity]}]} = ast, quoted) do
    if gate?(alias), do: [{:capture, fun, arity}], else: gate_walk(ast, quoted)
  end

  defp gate_uses({{:., _, [alias, fun]}, _, args} = ast, quoted) when is_list(args) do
    if gate?(alias) do
      call = {:call, fun, length(args)}
      [if(quoted, do: {:quoted, call}, else: call) | gate_uses(args, quoted)]
    else
      gate_walk(ast, quoted)
    end
  end

  defp gate_uses(ast, quoted), do: if(gate?(ast), do: [:other], else: gate_walk(ast, quoted))

  defp gate_walk({form, _meta, args}, quoted),
    do: gate_uses(form, quoted) ++ gate_uses(List.wrap(args), quoted)

  defp gate_walk({left, right}, quoted), do: gate_uses(left, quoted) ++ gate_uses(right, quoted)
  defp gate_walk(list, quoted) when is_list(list), do: Enum.flat_map(list, &gate_uses(&1, quoted))
  defp gate_walk(_leaf, _quoted), do: []

  defp gate?(ast), do: match?({:__aliases__, _, [:Prima, :TestSeam]}, ast)

  defp seams do
    for {key, :seam} <-
          Map.merge(Boundaries.config_key_classes(), Boundaries.test_only_config_key_classes()),
        into: MapSet.new(@module_keyed),
        do: key
  end

  # What every rule above refuses in one file's code, `body` set in a
  # module of Sanctum's.
  defp refusals(body) do
    ast = Code.string_to_quoted!("defmodule Sanctum.SeamReview do\n" <> body <> "\nend\n")
    seams = seams()
    reads = reads(ast, %{module: nil, function: nil, gate: :plain})

    renamings(ast) ++
      for(use <- gate_uses(ast, false), use not in [:require, {:call, :value, 2}], do: use) ++
      for(
        %{app: app, key: key, gate: :plain, fun: fun} = read <- reads,
        app in [:arca, :cyfr, :sanctum] and
          ((key in seams and fun not in [:compile_env, :compile_env!]) or key in [:bulk, :dynamic]),
        do: read
      ) ++ for(%{app: :unnamed_application} = read <- reads, do: read)
  end

  @full_names [[:"Elixir", :Application], [:"Elixir", :Prima, :TestSeam]]
  @plain_names [:Application, :Prima, :"Elixir"]

  # Each way `ast` writes `Application`, `:application` or `Prima.TestSeam`
  # by another name, or makes a plain name reach another module.
  defp renamings(ast), do: renamings(ast, false)

  defp renamings({:defmodule, _, [{:__aliases__, _, [first | _]} = name, body]}, nested) do
    if(nested and first in @plain_names, do: [{:nested_module, name}], else: []) ++
      renamings(name, nested) ++ renamings(body, true)
  end

  defp renamings({directive, _, [target | _]} = ast, nested)
       when directive in [:alias, :require, :import] do
    if literal_target?(target),
      do: directive(ast, nested),
      else: [{:target_not_a_name, ast}]
  end

  defp renamings({:__aliases__, _, [:"Elixir" | _] = parts} = ast, _nested) do
    if parts in @full_names, do: [{:elixir_spelling, ast}], else: []
  end

  defp renamings(atom, _nested) when atom in [Application, Prima.TestSeam], do: [{:atom, atom}]
  defp renamings(ast, nested), do: walk_renamings(ast, nested)

  defp directive({:alias, _, [{{:., _, [base, :{}]}, _, children} | _]} = ast, nested) do
    renamed =
      Enum.any?(children, fn
        {:__aliases__, _, parts} = child ->
          reaches?(join(base, child)) or List.last(parts) in @plain_names

        _child ->
          true
      end)

    if(renamed, do: [{:alias, ast}], else: []) ++ walk_renamings(ast, nested)
  end

  defp directive({:alias, _, [target | options]} = ast, nested) do
    as = options |> List.first([]) |> Keyword.get(:as)
    introduced = name_of(as) || last_name(target)

    if(reaches?(target) or introduced in @plain_names, do: [{:alias, ast}], else: []) ++
      walk_renamings(ast, nested)
  end

  defp directive({:require, _, [target, options]} = ast, nested) when is_list(options) do
    as = Keyword.get(options, :as)

    if(as != nil and (reaches?(target) or name_of(as) in @plain_names),
      do: [{:require, ast}],
      else: []
    ) ++ walk_renamings(ast, nested)
  end

  defp directive({:import, _, [target | _]} = ast, nested) do
    if(full?(target), do: [{:import, ast}], else: []) ++ walk_renamings(ast, nested)
  end

  defp directive(ast, nested), do: walk_renamings(ast, nested)

  # A directive's target written as a module name: an atom, an alias of
  # names alone, or braces of those.
  defp literal_target?(atom) when is_atom(atom), do: true
  defp literal_target?({:__aliases__, _, parts}), do: Enum.all?(parts, &is_atom/1)

  defp literal_target?({{:., _, [base, :{}]}, _, children}),
    do:
      literal_target?(base) and Enum.all?(children, &match?({:__aliases__, _, _}, &1)) and
        Enum.all?(children, &literal_target?/1)

  defp literal_target?(_expression), do: false

  defp count_directive({directive, _, [_ | _]} = ast, count)
       when directive in [:alias, :require, :import],
       do: {ast, count + 1}

  defp count_directive(ast, count), do: {ast, count}

  defp walk_renamings({form, _meta, args}, nested),
    do: renamings(form, nested) ++ renamings(List.wrap(args), nested)

  defp walk_renamings({left, right}, nested),
    do: renamings(left, nested) ++ renamings(right, nested)

  defp walk_renamings(list, nested) when is_list(list),
    do: Enum.flat_map(list, &renamings(&1, nested))

  defp walk_renamings(_leaf, _nested), do: []

  # A module expression as written, as the `Elixir.`-rooted name it spells,
  # or nil when it is not spelled by names alone.
  defp spelled({:__aliases__, _, [:"Elixir" | _] = parts}),
    do: if(Enum.all?(parts, &is_atom/1), do: parts)

  defp spelled({:__aliases__, _, parts}),
    do: if(Enum.all?(parts, &is_atom/1), do: [:"Elixir" | parts])

  defp spelled(:application), do: [:application]

  defp spelled(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ ->
        [:"Elixir" | atom |> Module.split() |> Enum.map(&String.to_existing_atom/1)]

      _erlang ->
        nil
    end
  end

  defp spelled(_expression), do: nil

  defp join({:__aliases__, meta, base}, {:__aliases__, _, child}),
    do: {:__aliases__, meta, base ++ child}

  # Whether a module expression names one of the two modules or a prefix of
  # one, through which a shorter name would reach it.
  defp reaches?(expression) do
    case spelled(expression) do
      [:application] -> true
      nil -> false
      parts -> Enum.any?(@full_names, &(Enum.take(&1, length(parts)) == parts))
    end
  end

  defp full?(expression), do: spelled(expression) in [[:application] | @full_names]

  defp name_of({:__aliases__, _, [name]}), do: name
  defp name_of(_as), do: nil

  defp last_name({:__aliases__, _, parts}), do: List.last(parts)
  defp last_name(_target), do: nil

  defp lib_files do
    for lib <- SourceTree.app_libs(@root),
        path <- SourceTree.files!(Path.join([@root, lib, "**/*.ex"])),
        do: path
  end

  defp found do
    for path <- lib_files(),
        read <- reads(SourceTree.quoted(path), %{module: nil, function: nil, gate: :plain}),
        do: Map.put(read, :file, Path.relative_to(path, @root))
  end

  # The reads of an application's environment in `ast`, each with its
  # application, its key (the module's name as its source spells it, for
  # `__MODULE__`; `:bulk` for a read that names none; `:dynamic` for one
  # named by a value) and its gate: `:seam` inside the function
  # `Prima.TestSeam.value/2` is handed as its read, `:compiled_out` inside a
  # branch compiled only with the permission, `:plain` otherwise. A piped
  # read (`:cyfr |> Application.get_all_env()`) is read as the call it is,
  # and `Application.compile_env/4` by the application it names after the
  # caller's environment. A read of an application named by anything but
  # a literal atom is `:unnamed_application`, with the function it sits in.
  defp reads({:defmodule, _, [{:__aliases__, _, parts}, body]}, scope),
    do: reads(body, %{scope | module: Enum.map_join(parts, ".", &Atom.to_string/1)})

  defp reads({kind, _, [head | body]}, scope) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: reads(body, %{scope | function: name(head)})

  # Only the gate's read, its second argument, is inside the seam: its
  # default is code every build runs, scanned as any other.
  defp reads({{:., _, [{:__aliases__, _, [:Prima, :TestSeam]}, :value]}, _, args}, scope)
       when is_list(args),
       do:
         args
         |> Enum.with_index()
         |> Enum.flat_map(fn
           {{:fn, _, _} = read, 1} -> reads(read, %{scope | gate: :seam})
           {arg, _index} -> reads(arg, scope)
         end)

  defp reads({:if, _, [condition, clauses]} = ast, scope) when is_list(clauses) do
    if permission?(condition),
      do:
        reads(condition, scope) ++
          reads(Keyword.get(clauses, :do), %{scope | gate: :compiled_out}) ++
          reads(Keyword.get(clauses, :else), scope),
      else: walk(ast, scope)
  end

  defp reads({:|>, _, [subject, {{:., _, [module, fun]}, meta, args}]}, scope)
       when is_list(args),
       do: reads({{:., [], [module, fun]}, meta, [subject | args]}, scope)

  defp reads({{:., _, [module, :compile_env]}, meta, [_env, app, key, default]}, scope)
       when is_atom(app) do
    if module(module) == Application,
      do: reads({{:., [], [module, :compile_env]}, meta, [app, key, default]}, scope),
      else: walk({{:., [], [module, :compile_env]}, meta, [app, key, default]}, scope)
  end

  defp reads({{:., _, [module, fun]}, _, [app | rest] = args} = ast, scope) when is_atom(app) do
    case read(module(module), fun, rest, scope) do
      nil -> walk(ast, scope)
      read -> [Map.put(read, :app, app) | reads(args, scope)]
    end
  end

  defp reads({{:., _, [module, fun]}, _, [_application | rest] = args} = ast, scope) do
    case read(module(module), fun, rest, scope) do
      nil ->
        walk(ast, scope)

      read ->
        [
          Map.merge(read, %{app: :unnamed_application, function: scope.function})
          | reads(args, scope)
        ]
    end
  end

  defp reads(ast, scope), do: walk(ast, scope)

  defp walk({form, _meta, args}, scope), do: reads(form, scope) ++ reads(List.wrap(args), scope)
  defp walk({left, right}, scope), do: reads(left, scope) ++ reads(right, scope)
  defp walk(list, scope) when is_list(list), do: Enum.flat_map(list, &reads(&1, scope))
  defp walk(_leaf, _scope), do: []

  defp module({:__aliases__, _, [:Application]}), do: Application
  defp module({:__aliases__, _, [:"Elixir", :Application]}), do: Application
  defp module(Application), do: Application
  defp module(:application), do: :application
  defp module(_module), do: nil

  defp permission?({{:., _, [module, :compile_env]}, _, [:prima, :test_seams_permitted | _]}),
    do: module(module) == Application

  defp permission?(_condition), do: false

  defp read(module, fun, rest, scope) do
    cond do
      fun in Map.get(@bulk, module, []) -> %{fun: fun, key: :bulk, gate: scope.gate}
      fun in Map.get(@named, module, []) -> %{fun: fun, key: key(rest, scope), gate: scope.gate}
      true -> nil
    end
  end

  defp name({:when, _, [head | _]}), do: name(head)
  defp name({name, _, _}) when is_atom(name), do: name

  defp key([{:__MODULE__, _, _} | _], %{module: module}), do: module

  defp key([{:__aliases__, _, parts} | _], _scope) when is_list(parts),
    do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp key([key | _], _scope) when is_atom(key), do: key
  defp key(_args, _scope), do: :dynamic
end
