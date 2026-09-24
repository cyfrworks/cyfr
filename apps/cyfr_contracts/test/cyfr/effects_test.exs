# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EffectsTest do
  @moduledoc """
  The contracts application's effects are an exact roster.

  Two views prove it. The compiled view reads every contracts module's
  beam imports and holds the effect classes they reach to a literal
  module-to-effect roster. The source view walks every contracts source
  file and pins the stateless effects — the clock and entropy behind
  identifiers and sealing IVs — to the exact functions allowed them, and
  compile-time reads to module bodies.

  The roster keeps its categories apart: the six runtime primitives (the
  process and state owners), identifiers, encryption IVs, compile-time
  embeds, and the one code-loading probe of an optional provider callback.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Test.SourceTree

  @lib Path.expand("../../lib", __DIR__)

  # Module => {category, effect classes}. A compile-time row lists the
  # effects its module BODY reaches while compiling; its beam reaches none.
  @roster %{
    Cyfr.Boot => {:primitive, [:persistent_term]},
    Cyfr.RateLimiter => {:primitive, [:ets, :logger, :otp, :process, :system]},
    Cyfr.LoggerContext => {:primitive, [:logger]},
    Cyfr.JsonFormatter => {:primitive, [:app_env, :persistent_term]},
    Cyfr.Slots => {:primitive, [:logger, :otp, :process, :system]},
    Cyfr.Caps => {:primitive, [:code, :persistent_term]},
    Cyfr.UUID7 => {:id, [:entropy, :wall_clock]},
    Cyfr.Hex => {:id, [:entropy]},
    Cyfr.MacEnvelope => {:encryption_iv, [:entropy]},
    Cyfr.BridgeAuth => {:encryption_iv, [:entropy]},
    Cyfr.WorkerAuth => {:encryption_iv, [:entropy]},
    Compendium.WITSource => {:compile_time, [:file]},
    Cyfr.Version => {:compile_time, [:mix]},
    Cyfr.Ops.Provider => {:code_probe, [:code]}
  }

  @primitives [
    Cyfr.Boot,
    Cyfr.Caps,
    Cyfr.JsonFormatter,
    Cyfr.LoggerContext,
    Cyfr.RateLimiter,
    Cyfr.Slots
  ]

  # The stateless effects, each pinned to the functions allowed it.
  @wall_clock_pins [{Cyfr.UUID7, {:generate, 0}}]

  @id_entropy_pins [{Cyfr.UUID7, {:generate_at, 1}}, {Cyfr.Hex, {:short, 0}}]

  # The default IV of each seal.
  @iv_entropy_pins [
    {Cyfr.BridgeAuth, {:seal, 5}},
    {Cyfr.MacEnvelope, {:seal, 6}},
    {Cyfr.WorkerAuth, {:seal_attempt_keys, 3}},
    {Cyfr.WorkerAuth, {:seal_call, 5}}
  ]

  # Who outside the identifier modules mints an identifier.
  @id_minters [{Cyfr.Authority.Budget, {:new, 2}}, {Cyfr.Boot, {:mint, 0}}]

  @id_functions [
    {Cyfr.UUID7, :generate},
    {Cyfr.UUID7, :generate_at},
    {Cyfr.UUID7, :generate_id},
    {Cyfr.UUID7, :request_id},
    {Cyfr.UUID7, :execution_id},
    {Cyfr.UUID7, :build_id},
    {Cyfr.Hex, :short}
  ]

  # Wall-clock reads: the freshness a signed envelope or an identifier
  # could take from the machine rather than from its caller.
  @wall_clock [
    {System, :system_time},
    {System, :os_time},
    {DateTime, :utc_now},
    {DateTime, :now},
    {DateTime, :now!},
    {NaiveDateTime, :utc_now},
    {Date, :utc_today},
    {Time, :utc_now},
    {:os, :system_time},
    {:os, :timestamp},
    {:erlang, :system_time},
    {:erlang, :now},
    {:erlang, :timestamp},
    {:erlang, :localtime},
    {:erlang, :universaltime},
    {:erlang, :date},
    {:erlang, :time},
    {:calendar, :local_time},
    {:calendar, :universal_time}
  ]

  @process_bifs [
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :spawn_opt,
    :send,
    :send_after,
    :start_timer,
    :cancel_timer,
    :read_timer,
    :monitor,
    :demonitor,
    :link,
    :unlink,
    :process_flag,
    :process_info,
    :register,
    :unregister,
    :whereis,
    :self,
    :is_process_alive,
    :make_ref,
    :put,
    :get,
    :erase,
    :group_leader,
    :hibernate
  ]

  # The process calls Kernel imports, written without a module.
  @kernel_process [:spawn, :spawn_link, :spawn_monitor, :send, :self, :make_ref]

  @otp [
    GenServer,
    Task,
    Agent,
    Supervisor,
    DynamicSupervisor,
    Registry,
    :gen_server,
    :gen_statem,
    :proc_lib,
    :supervisor
  ]

  @http [Req, Finch, :httpc, :hackney, :gen_tcp, :gen_udp, :ssl, :inet_res]
  @name_resolution [:getaddr, :getaddrs, :gethostbyname, :gethostbyaddr]

  setup_all do
    {:ok, modules: lib_modules(), findings: lib_findings()}
  end

  describe "the compiled view" do
    test "every contracts module's beam reaches exactly its roster's effects", %{modules: modules} do
      assert beam_violations(modules, @roster) == []
      assert absent_rows(modules, @roster) == []
    end

    test "a removed roster row fails", %{modules: modules} do
      for module <- [Cyfr.UUID7, Cyfr.Slots, Cyfr.WorkerAuth] do
        violations = beam_violations(modules, Map.delete(@roster, module))
        assert Enum.any?(violations, &match?({^module, [_ | _], []}, &1))
      end
    end

    test "a stale roster row fails", %{modules: modules} do
      roster = Map.put(@roster, Cyfr.Digest, {:id, [:entropy]})
      assert {Cyfr.Digest, [], [:entropy]} in beam_violations(modules, roster)

      roster = Map.put(@roster, Cyfr.Gone, {:id, [:entropy]})
      assert absent_rows(modules, roster) == [Cyfr.Gone]
    end

    test "Logger is reached only by Slots, RateLimiter and LoggerContext", %{modules: modules} do
      assert reaching(modules, :logger) == [Cyfr.LoggerContext, Cyfr.RateLimiter, Cyfr.Slots]
    end

    test "the wall clock is read only by the identifier generator", %{modules: modules} do
      assert reaching(modules, :wall_clock) == [Cyfr.UUID7]
    end

    test "no beam reads Mix, an application spec or configuration at run time",
         %{modules: modules} do
      for module <- modules, {m, f, a} <- imports(module) do
        refute mix?(m), "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a} at run time"
        refute {m, f} in [{Application, :spec}, {:application, :get_key}]
      end

      assert reaching(modules, :app_spec) == []
      assert reaching(modules, :app_env) == [Cyfr.JsonFormatter]
    end

    test "a compile-time row's beam reaches nothing" do
      for {module, {:compile_time, _effects}} <- @roster do
        assert beam_effects(module) == []
      end
    end
  end

  describe "the source view" do
    test "every effect a function reaches is its module's roster row", %{findings: findings} do
      assert source_violations(findings, @roster) == []
    end

    test "the clock is read only in UUID7.generate/0", %{findings: findings} do
      assert pinned(findings, :wall_clock) == @wall_clock_pins
    end

    test "entropy is drawn only by the identifier generators and the seals' default IVs",
         %{findings: findings} do
      assert pinned(findings, :entropy) == Enum.sort(@id_entropy_pins ++ @iv_entropy_pins)
    end

    test "nothing draws from :rand or a unique integer", %{findings: findings} do
      assert pinned(findings, :rand) == []

      assert for(
               {m, where, _class, {mod, :unique_integer, _}} <- findings,
               mod in [System, :erlang],
               do: {m, where}
             ) == []
    end

    test "an identifier is minted outside its generators only by the boot and a budget",
         %{findings: findings} do
      assert pinned(findings, :mint) == @id_minters
    end

    test "a compile-time embed reads files and Mix only in its module body",
         %{findings: findings} do
      for {module, {:compile_time, effects}} <- @roster do
        reached = for {^module, where, class, _mfa} <- findings, class in effects, do: where
        assert reached != [], "#{inspect(module)} no longer reaches #{inspect(effects)}"
        assert Enum.uniq(reached) == [:body]
      end
    end
  end

  describe "the roster" do
    test "the six primitives are the process and state owners, and the categories stay apart" do
      assert for({m, {:primitive, _}} <- @roster, do: m) |> Enum.sort() == @primitives

      categories = @roster |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert categories == [:code_probe, :compile_time, :encryption_iv, :id, :primitive]

      for {module, _pin} <- @id_entropy_pins, do: assert({:id, _} = @roster[module])
      for {module, _pin} <- @iv_entropy_pins, do: assert({:encryption_iv, _} = @roster[module])
    end

    test "the scan is not empty", %{modules: modules, findings: findings} do
      assert length(modules) > 50
      assert Cyfr.UUID7 in modules and Compendium.WITSource in modules
      assert length(findings) > 20

      # The two views read the same modules: none compiled that the walk
      # missed, none walked that did not compile.
      assert findings |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.all?(&(&1 in modules))
      assert Enum.sort(walked_modules()) == Enum.sort(modules)
    end
  end

  describe "a planted effect" do
    test "Logger.warning is reported by module and function in both views" do
      {module, beam, found} =
        plant(Plant.Log, """
        require Logger
        def warn(x), do: Logger.warning("value: \#{x}")
        """)

      assert {module, {:warn, 1}, :logger, {Logger, :warning, 1}} in found
      assert source_violations(found, @roster) != []
      assert [{^module, [:logger], []}] = beam_violations([module], @roster, %{module => beam})
    end

    test "Application.get_env is reported by module and function in both views" do
      {module, beam, found} = plant(Plant.Env, "def mode, do: Application.get_env(:cyfr, :mode)")

      assert {module, {:mode, 0}, :app_env, {Application, :get_env, 2}} in found
      assert [{^module, [:app_env], []}] = beam_violations([module], @roster, %{module => beam})
    end

    test "DateTime.now! is reported by module and function in both views" do
      {module, beam, found} = plant(Plant.Now, ~s[def now, do: DateTime.now!("Etc/UTC")])

      assert {module, {:now, 0}, :wall_clock, {DateTime, :now!, 1}} in found
      assert pinned(found, :wall_clock) == [{module, {:now, 0}}]

      assert [{^module, [:wall_clock], []}] =
               beam_violations([module], @roster, %{module => beam})
    end

    test ":os.getenv is reported by module and function in both views" do
      {module, beam, found} = plant(Plant.OsEnv, ~s[def home, do: :os.getenv(~c"HOME")])

      assert {module, {:home, 0}, :app_env, {:os, :getenv, 1}} in found
      assert source_violations(found, @roster) != []
      assert [{^module, [:app_env], []}] = beam_violations([module], @roster, %{module => beam})
    end

    test ":rand.uniform is reported by module and function in both views" do
      {module, beam, found} = plant(Plant.Rand, "def roll, do: :rand.uniform(6)")

      assert {module, {:roll, 0}, :rand, {:rand, :uniform, 1}} in found
      assert pinned(found, :rand) == [{module, {:roll, 0}}]
      assert [{^module, [:rand], []}] = beam_violations([module], @roster, %{module => beam})
    end

    test "an aliased call is caught" do
      {module, beam, found} =
        plant(Plant.Aliased, """
        alias Application, as: Env
        alias System, as: Clock
        def mode, do: Env.get_env(:cyfr, :mode)
        def now, do: Clock.system_time(:millisecond)
        """)

      assert {module, {:mode, 0}, :app_env, {Application, :get_env, 2}} in found
      assert {module, {:now, 0}, :wall_clock, {System, :system_time, 1}} in found
      assert classes(beam_imports(beam)) == [:app_env, :wall_clock]
    end

    test "a default argument is the function's own" do
      {module, _beam, found} =
        plant(Plant.Default, "def seal(x, iv \\\\ :crypto.strong_rand_bytes(12)), do: {x, iv}")

      assert pinned(found, :entropy) == [{module, {:seal, 2}}]
    end

    test "a doc mention is not an effect" do
      {_module, beam, found} =
        plant(Plant.Doc, """
        @doc "Calls Logger.warning/1, Application.get_env/2 and :rand.uniform/1."
        def pure(x), do: x
        # Logger.warning("in a comment")
        """)

      assert found == []
      assert classes(beam_imports(beam)) == []
    end
  end

  # ---------------------------------------------------------------------------
  # The compiled view
  # ---------------------------------------------------------------------------

  # Every module compiled from this application's lib/, test support aside.
  defp lib_modules do
    for module <- Application.spec(:cyfr_contracts, :modules),
        source = module.module_info(:compile)[:source],
        String.starts_with?(to_string(source), @lib <> "/"),
        do: module
  end

  defp imports(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  defp beam_imports(binary) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])
    imports
  end

  defp beam_effects(module), do: module |> imports() |> classes()

  defp classes(imports) do
    imports |> Enum.map(&classify/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  defp reaching(modules, class),
    do: for(m <- modules, class in beam_effects(m), do: m) |> Enum.sort()

  # `{module, found, expected}` for every module whose beam disagrees with
  # its row. `beams` supplies binaries for modules not on the code path.
  defp beam_violations(modules, roster, beams \\ %{}) do
    for module <- modules,
        found = found_effects(module, beams),
        expected = expected_beam_effects(roster, module),
        found != expected,
        do: {module, found, expected}
  end

  # A row naming a module that no longer compiles here.
  defp absent_rows(modules, roster),
    do: for({module, _row} <- roster, module not in modules, do: module) |> Enum.sort()

  defp found_effects(module, beams) do
    case Map.fetch(beams, module) do
      {:ok, binary} -> classes(beam_imports(binary))
      :error -> beam_effects(module)
    end
  end

  defp expected_beam_effects(roster, module) do
    case Map.get(roster, module) do
      nil -> []
      {:compile_time, _body_effects} -> []
      {_category, effects} -> Enum.sort(effects)
    end
  end

  # ---------------------------------------------------------------------------
  # The source view
  # ---------------------------------------------------------------------------

  defp lib_sources, do: SourceTree.files!(Path.join(@lib, "**/*.ex"))

  defp lib_findings do
    Enum.flat_map(lib_sources(), &(&1 |> SourceTree.read() |> source_findings()))
  end

  defp walked_modules do
    lib_sources()
    |> Enum.flat_map(fn path ->
      path |> SourceTree.read() |> Code.string_to_quoted!() |> modules_in(nil, [])
    end)
  end

  defp modules_in({:defmodule, _, [name, [do: body]]}, parent, acc) do
    module = nested(name, parent)
    modules_in(body, module, [module | acc])
  end

  defp modules_in({:defimpl, _, [protocol, opts | rest]}, parent, acc) when is_list(opts) do
    for_module = if opts[:for], do: expand(opts[:for], parent, %{}), else: parent
    module = Module.concat(expand(protocol, parent, %{}), for_module)
    body = Keyword.get(opts, :do) || Keyword.get(List.first(rest) || [], :do)
    modules_in(body, module, [module | acc])
  end

  defp modules_in({:__block__, _, statements}, parent, acc),
    do: Enum.reduce(statements, acc, &modules_in(&1, parent, &2))

  defp modules_in(_statement, _parent, acc), do: acc

  # `{module, {name, arity} | :body, class, {m, f, a}}` for every effectful
  # call the source makes.
  defp source_findings(source) do
    source |> Code.string_to_quoted!() |> walk(nil, %{}) |> elem(1) |> Enum.reverse()
  end

  defp pinned(findings, class) do
    for({module, where, ^class, _mfa} <- findings, uniq: true, do: {module, where}) |> Enum.sort()
  end

  # Every finding whose class the module's row does not admit, or that a
  # compile-time row makes outside its body. Minting an identifier is not
  # an effect of the minter's; it is pinned on its own.
  defp source_violations(findings, roster) do
    for {module, where, class, _mfa} = finding <- findings,
        class != :mint,
        not admitted?(Map.get(roster, module), class, where),
        do: finding
  end

  defp admitted?(nil, _class, _where), do: false
  defp admitted?({:compile_time, effects}, class, where), do: class in effects and where == :body
  defp admitted?({_category, effects}, class, _where), do: class in effects

  # Walk a module body: aliases accumulate, each definition is walked
  # under its own name and arity, and anything else is the body's.
  defp walk({:defmodule, _, [name, [do: body]]}, parent, aliases) do
    module = nested(name, parent)
    aliases = alias_nested(aliases, name, module)
    {_aliases, found} = walk_body(body, module, aliases)
    {aliases, found}
  end

  defp walk(other, parent, aliases), do: walk_body(other, parent, aliases)

  defp walk_body(body, module, aliases) do
    statements =
      case body do
        {:__block__, _, statements} -> statements
        statement -> [statement]
      end

    Enum.reduce(statements, {aliases, []}, fn statement, {aliases, found} ->
      {aliases, more} = statement(statement, module, aliases)
      {aliases, more ++ found}
    end)
  end

  defp statement({:defmodule, _, [name, _body]} = nested, module, aliases) do
    {_, found} = walk(nested, module, aliases)
    {alias_nested(aliases, name, nested(name, module)), found}
  end

  defp statement({:defimpl, _, [protocol, opts | rest]}, module, aliases) when is_list(opts) do
    for_module = if opts[:for], do: expand(opts[:for], module, aliases), else: module
    impl = Module.concat(expand(protocol, module, aliases), for_module)
    body = Keyword.get(opts, :do) || Keyword.get(List.first(rest) || [], :do)
    {_, found} = walk_body(body, impl, aliases)
    {aliases, found}
  end

  defp statement({kind, _, [target | opts]}, module, aliases) when kind in [:alias, :require] do
    {add_alias(aliases, target, List.first(opts) || [], module), []}
  end

  defp statement({:import, _, [target | opts]}, module, aliases) do
    imported = expand(target, module, aliases)
    only = Keyword.get(List.first(opts) || [], :only)
    {aliases, imported_findings(module, imported, only)}
  end

  defp statement({:use, _, [target | _]}, module, aliases) do
    used = expand(target, module, aliases)

    found =
      case classify({used, :__using__, 1}) do
        nil -> []
        class -> [{module, :body, class, {used, :__using__, 1}}]
      end

    {aliases, found}
  end

  defp statement({kind, _, [head | rest]}, module, aliases)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    where = name_arity(head)
    {aliases, calls([head | rest], module, aliases, where)}
  end

  defp statement({:defdelegate, _, [head, opts]}, module, aliases) do
    {name, arity} = name_arity(head)
    target = expand(opts[:to], module, aliases)
    mfa = {target, Keyword.get(opts, :as, name), arity}

    found =
      case classify(mfa) do
        nil -> []
        class -> [{module, {name, arity}, class, mfa}]
      end

    {aliases, found}
  end

  # A typespec names types, not calls: `Logger.level()` in a spec calls nothing.
  defp statement({:@, _, [{attribute, _, _}]}, _module, aliases)
       when attribute in [:spec, :type, :typep, :opaque, :callback, :macrocallback],
       do: {aliases, []}

  defp statement(other, module, aliases), do: {aliases, calls(other, module, aliases, :body)}

  defp name_arity({:when, _, [head | _guards]}), do: name_arity(head)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, nil}) when is_atom(name), do: {name, 0}

  # Every classified call inside `ast`.
  defp calls(ast, module, aliases, where) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [target, fun]}, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, record(acc, module, where, {expand(target, module, aliases), fun, length(args)})}

        {fun, _, args} = node, acc when fun in @kernel_process and is_list(args) ->
          {node, record(acc, module, where, {:erlang, fun, length(args)})}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp record(acc, module, where, {target, f, _a} = mfa) when is_atom(target) do
    case classify(mfa) do
      nil when {target, f} in @id_functions -> [{module, where, :mint, mfa} | acc]
      nil -> acc
      class -> [{module, where, class, mfa} | acc]
    end
  end

  defp record(acc, _module, _where, _dynamic), do: acc

  defp imported_findings(module, imported, only) do
    functions =
      if only do
        only
      else
        Code.ensure_loaded(imported)
        imported.module_info(:exports)
      end

    for {f, a} <- functions,
        class = classify({imported, f, a}),
        class != nil,
        do: {module, :body, class, {imported, f, a}}
  end

  defp nested({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, parent),
    do: Module.concat([parent | rest])

  defp nested({:__aliases__, _, segments}, nil), do: Module.concat(segments)
  defp nested({:__aliases__, _, segments}, parent), do: Module.concat([parent | segments])
  defp nested(atom, _parent) when is_atom(atom), do: atom

  # A nested `defmodule Child` is reachable as `Child` in its parent.
  defp alias_nested(aliases, {:__aliases__, _, [single]}, module) when is_atom(single),
    do: Map.put(aliases, single, module)

  defp alias_nested(aliases, _name, _module), do: aliases

  defp add_alias(aliases, {{:., _, [base, :{}]}, _, members}, _opts, module) do
    base = expand(base, module, aliases)

    Enum.reduce(members, aliases, fn {:__aliases__, _, segments}, acc ->
      Map.put(acc, List.last(segments), Module.concat([base | segments]))
    end)
  end

  defp add_alias(aliases, target, opts, module) do
    full = expand(target, module, aliases)

    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as]} -> Map.put(aliases, as, full)
      nil -> Map.put(aliases, full |> Module.split() |> List.last() |> String.to_atom(), full)
    end
  rescue
    # `alias :erlang_module` has no Elixir segments to shorten.
    ArgumentError -> aliases
  end

  defp expand({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, module, _aliases),
    do: Module.concat([module | rest])

  defp expand({:__aliases__, _, [first | rest]}, _module, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> Module.concat([full | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp expand({:__MODULE__, _, _}, module, _aliases), do: module
  defp expand(atom, _module, _aliases) when is_atom(atom), do: atom
  defp expand(_dynamic, _module, _aliases), do: nil

  # ---------------------------------------------------------------------------
  # Effect classes
  # ---------------------------------------------------------------------------

  defp classify({m, f, a}) when is_atom(m) do
    cond do
      {m, f} in @wall_clock -> :wall_clock
      m in [Logger, :logger] -> :logger
      {m, f} in [{Application, :spec}, {:application, :get_key}] -> :app_spec
      m in [Application, :application] or {m, f} == {:os, :getenv} -> :app_env
      m == :crypto and f in [:strong_rand_bytes, :rand_bytes, :rand_uniform] -> :entropy
      m in [:rand, :random] -> :rand
      m == System -> :system
      m == :erlang and f in [:unique_integer, :monotonic_time] -> :system
      m in [File, :file, :filelib, :prim_file] or {m, f} == {Path, :wildcard} -> :file
      m in @http or http?(m) or (m == :inet and f in @name_resolution) -> :http
      m in [Process, :timer] -> :process
      m == :erlang and f == :exit and a == 2 -> :process
      m == :erlang and f in @process_bifs -> :process
      m == :persistent_term -> :persistent_term
      m == :ets -> :ets
      m in [Code, :code] -> :code
      m in @otp or under?(m, ["Task", "Agent", "Supervisor"]) -> :otp
      mix?(m) -> :mix
      m == :telemetry -> :telemetry
      true -> nil
    end
  end

  defp classify(_mfa), do: nil

  defp http?(m), do: under?(m, ["Req", "Finch", "Mint", "HTTPoison", "Tesla"])

  defp mix?(m), do: m == Mix or under?(m, ["Mix"])

  defp under?(m, roots) do
    name = Atom.to_string(m)
    Enum.any?(roots, &String.starts_with?(name, "Elixir." <> &1 <> "."))
  end

  # ---------------------------------------------------------------------------
  # Plants
  # ---------------------------------------------------------------------------

  # Compile `body` as a module of its own and walk the same source: the
  # compiled binary is what the beam view reads, the source what the walk
  # reads.
  defp plant(name, body) do
    module = Module.concat(__MODULE__, name)
    source = "defmodule #{inspect(module)} do\n#{body}\nend\n"
    [{^module, binary}] = Code.compile_string(source)
    {module, binary, source_findings(source)}
  end
end
