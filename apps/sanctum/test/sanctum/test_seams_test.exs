# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TestSeamsTest do
  # Sanctum's test seams are read only by a build compiled with the test
  # permission (`:test_seams_permitted`): a release, compiled without it,
  # answers each seam's shipped default and never reads the key, whatever
  # its start-up configuration sets. Synchronous: a case sets the seams'
  # keys, which every reader in the VM sees.
  use ExUnit.Case, async: false

  # Each seam a release could be handed at start-up, beside the default a
  # build without the permission answers in its place.
  @seams [
    workos_api_url: "https://api.workos.com",
    oidc_reauth_client: Sanctum.Auth.OIDC.Oidcc,
    directory_client: [],
    scripted_oauth_provider: nil,
    caller_memo_ttl_ms: 2_000,
    namespace_cache_ttl_ms: 60_000,
    bearer_provider: nil,
    provisioning_inline: false
  ]

  # The application whose code reads each seam: Sanctum's own, but for the
  # host's inline fill (`Compendium.Provisioning`).
  @seam_readers %{provisioning_inline: "apps/cyfr/lib"}

  setup do
    for {key, _default} <- @seams do
      Prima.Test.Env.put_app_env(:sanctum, key, {:set_at_start_up, key})
    end

    :ok
  end

  test "a build without the permission answers every seam's default and reads none of them" do
    for {key, default} <- @seams do
      read = fn -> flunk("#{key} was read by a build without the test permission") end
      assert Sanctum.seam(false, default, read) == default
    end
  end

  test "a build with the permission reads each seam's setting" do
    for {key, default} <- @seams do
      read = fn -> Application.get_env(:sanctum, key, default) end
      assert Sanctum.seam(true, default, read) == {:set_at_start_up, key}
    end
  end

  # Every other key of Sanctum's environment the code reads, by its class.
  # Shipped: a shipped configuration file sets it, or the boot writes it
  # (`Cyfr.Application` writes the keyring), checked below where the
  # umbrella's configuration is present.
  @shipped ~w(access_mode company_login crypto_keyring directory_url fallback_origin
              oidc_client oidc_issuer private_egress_targets proxy_trust public_url
              registry_url secret_key_base setup_token tool_providers workos)a

  # Operator-shaped, with no lever to set it yet (`Cyfr.Boundaries` classes
  # it `:missing_lever`): no shipped file sets it, and no seam reads it.
  @missing_levers [:platform_ceiling]

  # The one reader whose application and key are values, not names: the
  # platform settings' (`Cyfr.Platform.Settings`), whose pairs are its
  # roster's and are written at boot.
  @dynamic_readers ["apps/cyfr/lib/cyfr/platform/settings.ex"]

  @readers [:get_env, :fetch_env, :fetch_env!, :get_all_env, :compile_env, :compile_env!]

  # The decision above holds for a seam only where its read goes through
  # it. Every read of Sanctum's application environment in every
  # application's code, read as code: inside the function `Sanctum.seam/2`
  # is handed, or inside a branch compiled only with the permission, is a
  # seam's; a `compile_env` read is fixed when the release is built, and
  # the release refuses to boot under another value; anything else names a
  # key of the classes above. A key that is not a literal atom fails. A
  # call's module is resolved as the compiler resolves it, through the
  # file's aliases (`Elixir.Application`, `alias Application, as: A`) and
  # an `import Application`. It holds the one door this codebase gives a
  # hook, the application environment, and no other (a `System.get_env`
  # or a `:persistent_term` read is the behavioural probes' to catch).
  # tests/release-boot/test_seams.exs holds the shipped release to the
  # same seams.
  test "every read of Sanctum's environment is a seam's, compiled, or a key of its stated class" do
    root = Path.expand("../../../..", __DIR__)

    found =
      for lib <- Prima.Test.SourceTree.app_libs(root),
          path <- Prima.Test.SourceTree.files!(Path.join([root, lib, "**/*.ex"])),
          quoted = Prima.Test.SourceTree.quoted(path),
          names = attributes(quoted),
          read <- reads(quoted, scope(quoted)),
          do: resolve(read, names, Path.relative_to(path, root))

    classed = Enum.map(found, &Map.put(&1, :class, class(&1)))

    unclassed =
      for %{class: {:refused, why}} = read <- classed, do: {why, Map.delete(read, :class)}

    assert unclassed == [],
           "reads of Sanctum's environment no class admits: #{inspect(unclassed)}"

    by_class = Enum.group_by(classed, & &1.class, & &1.key)

    present = fn file -> File.exists?(Path.join(root, file)) end

    # Each seam read once, inside its seam, in the application that reads
    # it: a seam read elsewhere, or not at all, is not the seam this suite
    # proves. A build without the host's code holds Sanctum's own.
    seams_here =
      for {key, _default} <- @seams,
          present.(Map.get(@seam_readers, key, "apps/sanctum/lib")),
          do: key

    assert Enum.sort(Map.get(by_class, :seam, [])) == Enum.sort(seams_here)

    for %{class: :seam, key: key, file: file} <- classed,
        do:
          assert(
            String.starts_with?(file, Map.get(@seam_readers, key, "apps/sanctum/lib") <> "/")
          )

    assert Map.get(by_class, :compiled_out) == [:tenancy_resolver_override]

    assert by_class |> Map.get(:compiled, []) |> Enum.uniq() |> Enum.sort() ==
             [:directory_request_ms, :test_seams_permitted]

    # The lists above hold what is read, no more.
    shipped_read = MapSet.new(Map.get(by_class, :shipped, []))
    assert MapSet.equal?(shipped_read, MapSet.new(@shipped)), inspect(shipped_read)
    assert Enum.uniq(Map.get(by_class, :missing_lever, [])) == @missing_levers

    dynamic = for %{class: :dynamic, file: file} <- classed, uniq: true, do: file
    assert dynamic == Enum.filter(@dynamic_readers, present)

    if present.("config/runtime.exs"), do: assert(shipped_unset(root) == [])
  end

  test "the permission is the test configurations' and no other's" do
    root = Path.expand("../../../..", __DIR__)

    setting =
      for path <-
            Path.wildcard(Path.join(root, "config/*.exs")) ++
              Path.wildcard(Path.join(root, "apps/*/config/*.exs")),
          File.read!(path) =~ ~r/^\s*config :sanctum,.*test_seams_permitted/m,
          do: Path.relative_to(path, root)

    # The standalone build holds no `config/test.exs`; the umbrella holds both.
    assert "apps/sanctum/config/config.exs" in setting
    assert setting -- ["apps/sanctum/config/config.exs", "config/test.exs"] == []

    # The standalone build's file sets it under test alone.
    [_shipped, under_test] =
      root
      |> Path.join("apps/sanctum/config/config.exs")
      |> File.read!()
      |> String.split("if config_env() == :test do", parts: 2)

    assert under_test =~ "test_seams_permitted: true"
  end

  # The reads of an application's environment in `ast`, each with its
  # application and key (`:dynamic` where it is not a literal atom) and the
  # gate it sits under: `:seam`, inside the function `Sanctum.seam/2` is
  # handed; `:compiled_out`, inside a branch compiled only with the test
  # permission; `:plain` otherwise.
  defp reads({{:., _, [module, :seam]}, _, args} = ast, scope) when is_list(args) do
    if module(module, scope) == Sanctum,
      do:
        Enum.flat_map(args, fn
          {:fn, _, _} = read -> reads(read, %{scope | gate: :seam})
          arg -> reads(arg, scope)
        end),
      else: walk(ast, scope)
  end

  defp reads({:if, _, [condition, clauses]} = ast, scope) when is_list(clauses) do
    if permission?(condition, scope),
      do:
        reads(condition, scope) ++
          reads(Keyword.get(clauses, :do), %{scope | gate: :compiled_out}) ++
          reads(Keyword.get(clauses, :else), scope),
      else: walk(ast, scope)
  end

  defp reads({:|>, _, [subject, {{:., _, [module, fun]}, meta, args}]}, scope)
       when is_list(args) do
    if env_reader?(module(module, scope), fun),
      do: [read(fun, meta, [subject | args], scope.gate) | reads([subject | args], scope)],
      else: reads(subject, scope) ++ reads(args, scope)
  end

  defp reads({{:., _, [module, fun]}, meta, args} = ast, scope) when is_list(args) do
    if env_reader?(module(module, scope), fun),
      do: [read(fun, meta, args, scope.gate) | reads(args, scope)],
      else: walk(ast, scope)
  end

  # A call of an imported `Application` function, by its bare name.
  defp reads({fun, meta, args} = ast, %{imports_application: true} = scope)
       when is_atom(fun) and is_list(args) do
    if fun in @readers,
      do: [read(fun, meta, args, scope.gate) | reads(args, scope)],
      else: walk(ast, scope)
  end

  defp reads(ast, scope), do: walk(ast, scope)

  defp walk({form, _meta, args}, scope), do: reads(form, scope) ++ reads(List.wrap(args), scope)
  defp walk({left, right}, scope), do: reads(left, scope) ++ reads(right, scope)
  defp walk(list, scope) when is_list(list), do: Enum.flat_map(list, &reads(&1, scope))
  defp walk(_leaf, _scope), do: []

  defp env_reader?(Application, fun), do: fun in @readers
  defp env_reader?(:application, fun), do: fun in [:get_env, :get_all_env, :get_key]
  defp env_reader?(_module, _fun), do: false

  defp permission?({{:., _, [module, :compile_env]}, _, args}, scope),
    do:
      module(module, scope) == Application and match?([:sanctum, :test_seams_permitted | _], args)

  defp permission?(_condition, _scope), do: false

  # What a file's aliases make of its names, and whether it imports
  # `Application`, read once per file: `alias A.B` names `B`, `alias A.B,
  # as: C` names `C`, `alias A.{B, C}` names both.
  defp scope(quoted) do
    nodes = flatten(quoted)

    aliases =
      for {:alias, _, [target | options]} <- nodes,
          {name, module} <- aliased(target, List.first(options) || []),
          into: %{},
          do: {name, module}

    imports =
      Enum.any?(nodes, fn
        {:import, _, [target | _]} -> module(target, %{aliases: aliases}) == Application
        _node -> false
      end)

    %{gate: :plain, aliases: aliases, imports_application: imports}
  end

  defp aliased({{:., _, [base, :{}]}, _, children}, _options) do
    case module(base, %{aliases: %{}}) do
      nil ->
        []

      base ->
        for {:__aliases__, _, parts} <- children,
            do: {List.last(parts), Module.concat([base | parts])}
    end
  end

  defp aliased({:__aliases__, _, parts} = target, options) when is_list(options) do
    module = module(target, %{aliases: %{}})

    name =
      case Keyword.get(options, :as) do
        {:__aliases__, _, [as]} -> as
        nil -> List.last(parts)
        _other -> nil
      end

    if name && module, do: [{name, module}], else: []
  end

  defp aliased(_target, _options), do: []

  # A module expression as the module it names: an atom as itself, an
  # alias through the file's aliases unless it starts at `Elixir`.
  defp module(atom, _scope) when is_atom(atom), do: atom
  defp module({:__aliases__, _, [:"Elixir" | parts]}, _scope), do: Module.concat(parts)
  defp module({:__aliases__, _, [head | _]}, _scope) when not is_atom(head), do: nil

  defp module({:__aliases__, _, [head | rest]}, scope) do
    case Map.fetch(scope.aliases, head) do
      {:ok, aliased} -> Module.concat([aliased | rest])
      :error -> Module.concat([head | rest])
    end
  end

  defp module(_expression, _scope), do: nil

  defp read(fun, meta, args, gate) do
    {app, key} =
      case args do
        [app, key | _] -> {app, key}
        [app] -> {app, :dynamic}
        [] -> {:dynamic, :dynamic}
      end

    %{fun: fun, line: meta[:line], app: app, key: key, gate: gate}
  end

  # A read's application and key as names: a literal atom, or a module
  # attribute the file sets to one (`@app :cyfr`); anything else is
  # `:dynamic`.
  defp resolve(read, names, file),
    do:
      %{read | app: literal(read.app, names), key: literal(read.key, names)}
      |> Map.put(:file, file)

  defp literal(atom, _names) when is_atom(atom), do: atom
  defp literal({:@, _, [{name, _, _}]}, names), do: Map.get(names, name, :dynamic)
  defp literal(_value, _names), do: :dynamic

  defp attributes(quoted) do
    for {:@, _, [{name, _, [value]}]} <- flatten(quoted),
        is_atom(value),
        into: %{},
        do: {name, value}
  end

  # A read of another application's environment is not this check's; one
  # whose application is a value may be Sanctum's.
  defp class(%{app: app}) when app not in [:sanctum, :dynamic], do: :other

  defp class(%{app: :dynamic, file: file}),
    do: if(file in @dynamic_readers, do: :dynamic, else: {:refused, :application_not_a_name})

  defp class(%{key: :dynamic}), do: {:refused, :key_not_a_name}

  defp class(%{gate: :seam, key: key}),
    do: if(key in Keyword.keys(@seams), do: :seam, else: {:refused, :unlisted_seam})

  defp class(%{gate: :compiled_out}), do: :compiled_out
  defp class(%{fun: fun}) when fun in [:compile_env, :compile_env!], do: :compiled
  defp class(%{key: key}) when key in @shipped, do: :shipped
  defp class(%{key: key}) when key in @missing_levers, do: :missing_lever

  defp class(%{}), do: {:refused, :read_outside_a_seam}

  # The shipped keys no shipped configuration file sets and no boot writes:
  # `config :sanctum, …` in config/config.exs, prod.exs and runtime.exs and,
  # outside its test branch, apps/sanctum/config/config.exs; and
  # `Application.put_env(:sanctum, key, …)` in an application's code.
  defp shipped_unset(root) do
    files =
      ~w(config/config.exs config/prod.exs config/runtime.exs apps/sanctum/config/config.exs)

    set =
      for file <- files,
          path = Path.join(root, file),
          File.exists?(path),
          key <- configured(Code.string_to_quoted!(File.read!(path))),
          into: MapSet.new(),
          do: key

    written =
      for lib <- Prima.Test.SourceTree.app_libs(root),
          path <- Prima.Test.SourceTree.files!(Path.join([root, lib, "**/*.ex"])),
          {_, _, _} = node <- flatten(Prima.Test.SourceTree.quoted(path)),
          match?(
            {{:., _, [{:__aliases__, _, [:Application]}, :put_env]}, _, [:sanctum, key, _]}
            when is_atom(key),
            node
          ),
          into: MapSet.new(),
          do: node |> elem(2) |> Enum.at(1)

    Enum.reject(@shipped, &(MapSet.member?(set, &1) or MapSet.member?(written, &1)))
  end

  # The keys `config :sanctum, …` sets in a configuration file's code,
  # outside any `if config_env() == :test` branch.
  defp configured({:if, _, [{:==, _, [{:config_env, _, _}, :test]}, _clauses]}), do: []

  defp configured({:config, _, [:sanctum, keywords]}) when is_list(keywords),
    do: Keyword.keys(keywords)

  defp configured({:config, _, [:sanctum, key, _value]}) when is_atom(key), do: [key]
  defp configured({form, _, args}), do: configured(form) ++ configured(List.wrap(args))
  defp configured({left, right}), do: configured(left) ++ configured(right)
  defp configured(list) when is_list(list), do: Enum.flat_map(list, &configured/1)
  defp configured(_leaf), do: []

  defp flatten(ast) do
    {_ast, nodes} = Macro.prewalk(ast, [], fn node, acc -> {node, [node | acc]} end)
    nodes
  end
end
