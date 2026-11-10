# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.EstablishBoundaryTest do
  @moduledoc """
  `Sanctum.Caller.establish/2` is the only builder of an authenticated
  context from a credential. Mechanically: every place code gives
  `authenticated` the value `true` is one of the enumerated sites, and
  the credential recipes — a session load, an API key's context and a
  frame credential's verification — are called from `Sanctum.Caller`
  alone.
  """
  use ExUnit.Case, async: true

  alias Prima.Test.SourceTree

  @root Path.expand("../../../..", __DIR__)

  # Every file that builds an authenticated context, with its site count
  # and what each site is.
  @sites %{
    # The recipes `establish/2` runs in place, a frame credential and a
    # webhook row; and `establish_device/2`: a paired device
    # `Sanctum.DeviceCerts`, its one caller, verified.
    "apps/sanctum/lib/sanctum/caller.ex" => 3,
    # `Session.load/1`, the session recipe `establish/2` calls.
    "apps/sanctum/lib/sanctum/session.ex" => 1,
    # `ApiKey.context_from_metadata/1`, the key recipe `establish/2` calls.
    "apps/sanctum/lib/sanctum/api_key.ex" => 1,
    # `Context.internal/1`: the server's own tasks; no credential.
    "apps/sanctum/lib/sanctum/context.ex" => 1,
    # The context a tincture invocation runs under, derived from an
    # already established caller's, or the public identity.
    "apps/sanctum/lib/sanctum.ex" => 1,
    # `Provisioning`'s person context: the server filling an admitted
    # person's athanor with their pull credential; no credential of its own.
    "apps/sanctum/lib/sanctum/provisioning.ex" => 1,
    # `Tenancy.continuation/3`: the person-shaped context a recovered
    # turn continues under, rebuilt from the turn's rows and refused when
    # the person is denied, or the athanor is not theirs or is archived.
    "apps/sanctum/lib/sanctum/tenancy.ex" => 1,
    # The suite's own builders. They live in `test/support`, which only the
    # test build compiles, and the roster reaches outside lib to keep them
    # enumerated: a permissive builder of authenticated contexts is worth
    # naming wherever it sits. None of them is a credential recipe; each
    # stands in for one that already ran.
    #
    # The general fixture, used by roughly 250 test files, and the pair of
    # people in two athanors every tenant-isolation test needs in order to
    # prove one cannot read the other.
    "apps/sanctum/test/support/test_context.ex" => 2,
    # `PrismConnCase`'s signed-in caller: the context a LiveView test's
    # session would have carried had a real OIDC sign-in produced it.
    "apps/cyfr/test/support/prism_conn_case.ex" => 1,
    # The test `Sanctum.Auth` implementation's established identity — the
    # provider seam, standing in for the real OIDC or OAuth strategy.
    "apps/cyfr/test/support/test_auth_provider.ex" => 1
  }

  # The credential recipes, callable from `Sanctum.Caller` only.
  @recipes [
    ~r/\bSession\.load\(/,
    ~r/\bApiKey\.(?:validate|context_from_metadata)\(/,
    ~r/\bTinctureAuth\.verify_frame_credential\(/
  ]
  @caller "apps/sanctum/lib/sanctum/caller.ex"

  defp lib_paths do
    for dir <- SourceTree.app_libs(@root),
        file <- SourceTree.files!(Path.join([@root, dir, "**/*.ex"])),
        do: {Path.relative_to(file, @root), file}
  end

  # Where a context may be BUILT: every app's lib, plus the two test
  # support trees holding fixtures that mint authenticated contexts.
  # `lib_paths/0` stays lib-only for the recipe test below, whose invariant
  # is about production code alone.
  defp builder_paths do
    support =
      for glob <- ~w(apps/cyfr/test/support/**/*.ex apps/sanctum/test/support/**/*.ex),
          file <- SourceTree.files!(Path.join(@root, glob)),
          do: {Path.relative_to(file, @root), file}

    lib_paths() ++ support
  end

  defp code_lines(paths),
    do: for({rel, file} <- paths, do: {rel, Enum.map(SourceTree.code_lines(file), &elem(&1, 0))})

  @defs [:def, :defp, :defmacro, :defmacrop]
  @types [:spec, :type, :typep, :opaque, :callback, :macrocallback]
  @key_writers [:put, :put_new, :replace, :replace!]

  # The line of every place `ast` gives `authenticated` the value `true`,
  # each pipe undone: a map or struct literal or update, a keyword list or
  # a pair naming it, a `Map` or `Keyword` writer whose key it is, and
  # `put_in/2,3` whose path reaches it. A pattern matches the key and
  # writes nothing: a function head, a clause's head, the left of `=` or
  # `<-`, `match?/2`'s pattern, and a type.
  defp authenticated_sets(ast) do
    ast
    |> Macro.prewalk(fn
      {:|>, _meta, [left, {call, meta, args}]} when is_list(args) -> {call, meta, [left | args]}
      node -> node
    end)
    |> sets(0, [])
    |> Enum.reverse()
  end

  defp sets({def, meta, [_head | body]}, _line, acc) when def in @defs,
    do: sets(body, meta[:line], acc)

  defp sets({op, meta, [_pattern, expression]}, _line, acc) when op in [:=, :<-],
    do: sets(expression, meta[:line], acc)

  defp sets({:->, meta, [_heads, body]}, _line, acc), do: sets(body, meta[:line], acc)
  defp sets({:match?, meta, [_pattern, term]}, _line, acc), do: sets(term, meta[:line], acc)
  defp sets({:@, _meta, [{type, _, _}]}, _line, acc) when type in @types, do: acc
  defp sets({:authenticated, true}, line, acc), do: [line | acc]

  defp sets(
         {{:., _, [{:__aliases__, _, [module]}, fun]}, meta, [_data, key, true]} = node,
         _,
         acc
       )
       when module in [:Map, :Keyword] and fun in @key_writers,
       do: children(node, meta[:line], mark(key == :authenticated, meta, acc))

  defp sets({:put_in, meta, [path, true]} = node, _line, acc),
    do: children(node, meta[:line], mark(names?(path), meta, acc))

  defp sets({:put_in, meta, [_data, keys, true]} = node, _line, acc),
    do: children(node, meta[:line], mark(names?(keys), meta, acc))

  defp sets({_call, meta, args} = node, line, acc) when is_list(meta) and is_list(args),
    do: children(node, meta[:line] || line, acc)

  defp sets(node, line, acc), do: children(node, line, acc)

  defp children({call, _meta, args}, line, acc) when is_list(args),
    do: sets(args, line, sets(call, line, acc))

  defp children({left, right}, line, acc), do: sets(right, line, sets(left, line, acc))

  defp children(list, line, acc) when is_list(list),
    do: Enum.reduce(list, acc, &sets(&1, line, &2))

  defp children(_leaf, _line, acc), do: acc

  defp mark(true, meta, acc), do: [meta[:line] | acc]
  defp mark(false, _meta, acc), do: acc

  # Whether a path names the key: the atom itself in a key list, or
  # `.authenticated`; a variable of that name does not.
  defp names?(:authenticated), do: true
  defp names?({name, _meta, context}) when is_atom(name) and is_atom(context), do: false
  defp names?({call, _meta, args}) when is_list(args), do: names?(call) or names?(args)
  defp names?(list) when is_list(list), do: Enum.any?(list, &names?/1)
  defp names?(_leaf), do: false

  test "an authenticated context is built only at the enumerated sites" do
    found =
      for {rel, file} <- builder_paths(),
          count = length(authenticated_sets(SourceTree.quoted(file))),
          count > 0,
          into: %{},
          do: {rel, count}

    new_sites = for {rel, count} <- found, count > Map.get(@sites, rel, 0), do: rel

    assert new_sites == [],
           """
           A context is built with `authenticated: true` outside the enumerated sites:

           #{Enum.map_join(Enum.sort(new_sites), "\n", &"  #{&1}")}

           A credential becomes a context through `Sanctum.Caller.establish/2`
           alone. A site that is not a credential (the server's own work)
           belongs in this test's roster, with a comment saying what it is.
           """

    stale = for {rel, count} <- @sites, Map.get(found, rel, 0) != count, do: rel

    assert stale == [],
           "stale roster entries (site count changed — update the roster and its " <>
             "comments): #{inspect(Enum.sort(stale))}"
  end

  test "every way of giving the key true is a site, and a pattern or another value is not" do
    planted = """
    defmodule Planted do
      def a(ctx), do: %{ctx | authenticated: true} # set
      def b(ctx), do: Map.put(ctx, :authenticated, true) # set
      def c(ctx), do: ctx |> Map.replace!(:authenticated, true) # set
      def d, do: %Sanctum.Context{user_id: "u", authenticated: true} # set
      def e(opts), do: Sanctum.Context.build([authenticated: true] ++ opts) # set
      def f(ctx), do: struct(ctx, authenticated: true) # set
      def g(ctx), do: Map.merge(ctx, %{authenticated: true}) # set
      def h(ctx), do: put_in(ctx.authenticated, true) # set
      def i(ctx), do: put_in(ctx, [:authenticated], true) # set
      def j(opts), do: Keyword.put(opts, :authenticated, true) # set
      def k(%Sanctum.Context{authenticated: true} = ctx), do: ctx
      def l(ctx) do
        case ctx do
          %{authenticated: true} -> ctx
        end
      end
      def m(ctx) do
        %{authenticated: true} = ctx
        with {:ok, %{authenticated: true}} <- {:ok, ctx}, do: match?(%{authenticated: true}, ctx)
      end
      def n(ctx), do: %{ctx | authenticated: false}
      def o(ctx), do: Map.get(ctx, :authenticated, true)
      @spec p() :: %{authenticated: true}
      def p, do: :ok
    end
    """

    set =
      for {line, number} <- Enum.with_index(String.split(planted, "\n"), 1),
          line =~ "# set",
          do: number

    assert length(set) == 10
    assert authenticated_sets(Code.string_to_quoted!(planted)) == set
  end

  test "a paired device's verifier builds no context: establish_device/2 builds it" do
    file = "apps/sanctum/lib/sanctum/device_certs.ex"
    lines = Enum.map(SourceTree.code_lines(Path.join(@root, file)), &elem(&1, 0))

    refute Enum.any?(lines, &Regex.match?(~r/\bContext\.build\(|%Context\{[^}]*\|/, &1)),
           "#{file} builds or rewrites a context; it verifies, then calls " <>
             "Sanctum.Caller.establish_device/2"
  end

  test "establish_device/2 has one call site, in Sanctum.DeviceCerts" do
    calls =
      for {rel, lines} <- code_lines(builder_paths()),
          line <- lines,
          line =~ ~r/\bestablish_device\(/,
          not (rel == @caller and line =~ ~r/^\s*(def|@spec)\s/),
          do: rel

    assert calls == ["apps/sanctum/lib/sanctum/device_certs.ex"],
           "establish_device/2 is Sanctum.DeviceCerts' alone, called once: #{inspect(calls)}"
  end

  test "no Host module can reach establish_device/2: Host's export roster refuses it" do
    # The Host's calls into Sanctum are held to its export roster, and the
    # device branch is not on it.
    refute {:establish_device, 2} in Map.get(Cyfr.Boundaries.sanctum_exports(), "Sanctum.Caller")

    assert Cyfr.Boundaries.sanctum_export_violations([{"Sanctum.Caller", :establish_device, 2}]) ==
             ["Sanctum.Caller.establish_device/2"]
  end

  test "establish/2 takes no device credential: made-up rows open nothing" do
    # A Host module handing `establish/2` rows of its own gets no
    # authenticated device context back: no clause takes a device row.
    user_id = Prima.UUID7.generate_id("usr")
    athanor_id = Prima.UUID7.generate_id("ath")

    forged = %{
      certificate: nil,
      client: %{
        id: Prima.UUID7.generate_id("pcl"),
        user_id: user_id,
        athanor_id: athanor_id,
        standing: "active",
        source_kind: "device_cert",
        device_public_key: :crypto.strong_rand_bytes(32)
      },
      user: %{id: user_id, status: "active", security_generation: 1, email: nil},
      athanor: %{id: athanor_id, status: "active", security_generation: 1},
      platform_admin: true
    }

    # Called through `apply/3`, since no clause of `establish/2` takes it
    # and the compiler says so.
    for args <- [[{:device, forged}], [{:device, forged}, []]] do
      assert_raise FunctionClauseError, fn -> apply(Sanctum.Caller, :establish, args) end
    end
  end

  test "the credential recipes are called from Sanctum.Caller alone" do
    reaches =
      for {rel, lines} <- code_lines(lib_paths()),
          rel != @caller,
          line <- lines,
          Enum.any?(@recipes, &Regex.match?(&1, line)),
          do: "#{rel}: #{String.trim(line)}"

    assert reaches == [],
           "a credential recipe is called outside Sanctum.Caller:\n" <>
             Enum.join(reaches, "\n")
  end
end
