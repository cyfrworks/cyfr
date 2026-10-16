# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestSkipRosterTest do
  @moduledoc """
  There is no quarantine lane. A test the suite skips is a proven test
  defect that is owned, dated and covered elsewhere, or it runs.

  Every test file under `apps/*/test` is read as code, so a `@tag :skip`
  inside a string or a comment is a fixture, not a skip. For every `test`
  and `property` the roster computes the tags ExUnit gives it: the
  module's `@moduletag`s written before it, then the enclosing describe's
  `@describetag`s, then the test's own `@tag`s, in that order, a later
  write winning over an earlier one, a bare atom standing for `key: true`,
  and the test's own tags consumed by it. The skip rule reads that merged
  map: a `skip` set and truthy to a literal (`:skip`, `skip: true`,
  `skip: "why"`) stands on every host and is refused unless the same map
  carries `owner:` (a name), `expires:` (an ISO 8601 date not yet passed)
  and `covered_by:` (where the coverage is kept; a test path there names a
  file that exists), whichever attribute wrote each. A `skip` whose value
  is computed from the host (`skip: @unavailable && "why"`) skips the test
  only where the host cannot run it and excludes nothing elsewhere, so it
  carries no expiry; each such skip is rostered below by file and exact
  expression, and one not rostered is refused. A tag whose shape the
  roster cannot read statically is refused too, so no skip hides behind a
  call.

  The rule is a function of the files it reads, so it is also run on
  planted files it must refuse and accept.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @test_files "apps/*/test/**/*_test.exs"
  @this "apps/cyfr/test/cyfr/test_skip_roster_test.exs"

  # The prerequisite skips: each file's skip expressions, as written.
  @prerequisite_skips %{
    "apps/cyfr/test/opus/host_listener_test.exs" => [
      ~s(@second_loopback_unavailable && "this host cannot bind 127.0.0.2")
    ]
  }

  # ---------------------------------------------------------------------------
  # The rule, as a function of files
  # ---------------------------------------------------------------------------

  @required [:owner, :expires, :covered_by]
  @test_macros [:test, :property]
  # Bodies no test is defined in, and whose `@tag` would be a read of the
  # attribute, not a tag.
  @opaque_bodies [:def, :defp, :defmacro, :defmacrop, :setup, :setup_all]

  # Every test of every file with the tags ExUnit gives it, as
  # `{file, line, :test, tags}`, and every tag the roster cannot read as
  # `{file, line, :unreadable, source}`.
  defp tests(root, files) do
    Enum.flat_map(files, fn file ->
      path = Path.join(root, file)
      ast = Code.string_to_quoted!(File.read!(path), file: path)
      {_state, found} = walk(ast, fresh(), file, [])
      Enum.reverse(found)
    end)
  end

  # The walk keeps the three tag scopes ExUnit keeps: the module's, the
  # describe's (nil outside one) and the next test's.
  defp fresh, do: %{module: %{}, describe: nil, tag: %{}}

  defp walk({:defmodule, _, [_name, body]}, state, file, found) do
    {_inner, found} = walk(body, fresh(), file, found)
    {state, found}
  end

  defp walk({:@, meta, [{attribute, _, [argument]}]}, state, file, found)
       when attribute in [:moduletag, :describetag, :tag] do
    line = Keyword.get(meta, :line)

    case {attribute, normalize(argument)} do
      {_, :unreadable} ->
        {state, [{file, line, :unreadable, "@#{attribute} #{Macro.to_string(argument)}"} | found]}

      {:moduletag, tags} ->
        {%{state | module: Map.merge(state.module, tags)}, found}

      {:describetag, _tags} when state.describe == nil ->
        {state, [{file, line, :unreadable, "@describetag outside a describe"} | found]}

      {:describetag, tags} ->
        {%{state | describe: Map.merge(state.describe, tags)}, found}

      {:tag, tags} ->
        {%{state | tag: Map.merge(state.tag, tags)}, found}
    end
  end

  defp walk({:describe, _, [_name, body]}, state, file, found) do
    {inner, found} = walk(body, %{state | describe: %{}}, file, found)
    {%{inner | describe: state.describe}, found}
  end

  defp walk({macro, meta, [_name | _] = args}, state, file, found)
       when macro in @test_macros and is_list(args) do
    tags =
      state.module
      |> Map.merge(state.describe || %{})
      |> Map.merge(state.tag)

    {%{state | tag: %{}}, [{file, Keyword.get(meta, :line), :test, tags} | found]}
  end

  defp walk({definer, _, _}, state, _file, found) when definer in @opaque_bodies,
    do: {state, found}

  defp walk({form, _meta, args}, state, file, found) when is_list(args) do
    {state, found} = walk(form, state, file, found)
    walk(args, state, file, found)
  end

  defp walk({left, right}, state, file, found) do
    {state, found} = walk(left, state, file, found)
    walk(right, state, file, found)
  end

  defp walk(list, state, file, found) when is_list(list) do
    Enum.reduce(list, {state, found}, fn node, {state, found} ->
      walk(node, state, file, found)
    end)
  end

  defp walk(_leaf, state, _file, found), do: {state, found}

  # A tag argument as ExUnit folds it: an atom is `key: true`, a keyword
  # list is taken in order with a repeated key's last value, anything else
  # is refused.
  defp normalize(atom) when is_atom(atom), do: %{atom => true}

  defp normalize(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _} when is_atom(key), &1)),
      do: Map.new(list),
      else: :unreadable
  end

  defp normalize(_other), do: :unreadable

  # Why a test's tags are refused, or nil when the test runs or its skip is
  # permitted.
  defp refusal(root, {file, line, :test, tags}, today) do
    skip = Map.get(tags, :skip)

    cond do
      skip in [nil, false] ->
        nil

      Macro.quoted_literal?(skip) ->
        standing_refusal(root, file, line, tags, today)

      Macro.to_string(skip) in Map.get(@prerequisite_skips, file, []) ->
        nil

      true ->
        "#{file}:#{line} prerequisite skip #{Macro.to_string(skip)} is not rostered"
    end
  end

  defp refusal(_root, {file, line, :unreadable, source}, _today),
    do: "#{file}:#{line} tag #{source} cannot be read for a skip"

  defp standing_refusal(root, file, line, tags, today) do
    missing = Enum.reject(@required, &Map.has_key?(tags, &1))

    reasons =
      Enum.reject(
        [
          missing != [] && "lacks #{Enum.map_join(missing, ", ", &"#{&1}:")}",
          Map.has_key?(tags, :owner) && not name?(tags.owner) && "owner: is not a name",
          Map.has_key?(tags, :expires) && expiry_refusal(tags.expires, today),
          Map.has_key?(tags, :covered_by) && coverage_refusal(root, tags.covered_by)
        ],
        &(&1 in [false, nil])
      )

    if reasons == [], do: nil, else: "#{file}:#{line} standing skip #{Enum.join(reasons, "; ")}"
  end

  defp name?(value), do: is_binary(value) and String.trim(value) != ""

  defp expiry_refusal(value, today) do
    with true <- is_binary(value),
         {:ok, date} <- Date.from_iso8601(value) do
      if Date.compare(date, today) == :lt, do: "expired #{value}", else: nil
    else
      _ -> "expires: #{inspect(value)} is not an ISO 8601 date"
    end
  end

  defp coverage_refusal(root, value) do
    cond do
      not name?(value) -> "covered_by: names nothing"
      not Regex.match?(~r{^apps/.*\.exs(:\d+)?$}, value) -> nil
      File.regular?(Path.join(root, String.replace(value, ~r/:\d+$/, ""))) -> nil
      true -> "covered_by: #{value} is not a file in the tree"
    end
  end

  defp refusals(root, files, today \\ Date.utc_today()) do
    root
    |> tests(files)
    |> Enum.map(&refusal(root, &1, today))
    |> Enum.reject(&is_nil/1)
  end

  # The skips computed from the host, with the file each is in.
  defp prerequisite_skips(root, files) do
    for {file, _line, :test, %{skip: skip}} <- tests(root, files),
        skip not in [nil, false],
        not Macro.quoted_literal?(skip),
        do: {file, Macro.to_string(skip)}
  end

  defp test_files(root) do
    root
    |> Path.join(@test_files)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # The tree
  # ---------------------------------------------------------------------------

  test "every test file is scanned, this one among them" do
    files = test_files(@root)
    assert length(files) > 500, "#{length(files)} test files under #{@root}: the wrong tree?"
    assert @this in files
    assert "apps/cyfr/test/opus/host_listener_test.exs" in files
  end

  test "no test skips without an owner, an expiry and kept coverage" do
    assert refusals(@root, test_files(@root)) == []
  end

  test "the prerequisite skips are exactly the rostered expressions" do
    found = prerequisite_skips(@root, test_files(@root))
    rostered = for {file, expressions} <- @prerequisite_skips, e <- expressions, do: {file, e}
    assert Enum.sort(found) == Enum.sort(rostered)
  end

  # ---------------------------------------------------------------------------
  # Planted files: what the rule refuses and what it lets through
  # ---------------------------------------------------------------------------

  setup do
    dir = Path.join(System.tmp_dir!(), "skip-roster-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "apps/planted/test"))
    {:ok, dir: dir}
  end

  defp plant!(dir, body) do
    file = "apps/planted/test/planted_#{System.unique_integer([:positive])}_test.exs"

    File.write!(Path.join(dir, file), """
    defmodule Planted#{System.unique_integer([:positive])}Test do
      use ExUnit.Case
    #{body}
    end
    """)

    file
  end

  defp planted_refusals(dir, body, today \\ Date.utc_today()),
    do: refusals(dir, [plant!(dir, body)], today)

  @future Date.to_iso8601(Date.add(Date.utc_today(), 30))
  @past "2026-01-01"
  @lacking "standing skip lacks owner:, expires:, covered_by:"
  @permitted ~s(skip: true, owner: "someone", expires: "#{@future}", covered_by: "elsewhere")

  test "a bare skip is refused, from every tag attribute", %{dir: dir} do
    for body <- [
          "  @tag :skip\n  test \"t\", do: :ok",
          "  @tag skip: \"flaky\"\n  test \"t\", do: :ok",
          "  @moduletag :skip\n  test \"t\", do: :ok",
          "  describe \"d\" do\n    @describetag skip: true\n    test \"t\", do: :ok\n  end"
        ] do
      assert [refused] = planted_refusals(dir, body)
      assert refused =~ @lacking
    end
  end

  test "a module skip reaches every test written after it, and none before", %{dir: dir} do
    assert [second, third] =
             planted_refusals(dir, """
               test "before", do: :ok
               @moduletag :skip
               test "after", do: :ok
               describe "d" do
                 test "inside", do: :ok
               end
             """)

    assert second =~ ":5 #{@lacking}"
    assert third =~ ":7 #{@lacking}"
  end

  test "a later repeated skip key counts, as ExUnit counts it", %{dir: dir} do
    for off <- ["false", "nil"] do
      assert [refused] =
               planted_refusals(dir, "  @tag skip: #{off}, skip: true\n  test \"t\", do: :ok")

      assert refused =~ @lacking
    end

    assert planted_refusals(dir, "  @tag skip: true, skip: false\n  test \"t\", do: :ok") == []
  end

  test "a later write at any level overrides an earlier one, as ExUnit merges them", %{dir: dir} do
    # A bare skip the test's next tag turns off runs.
    assert planted_refusals(dir, "  @tag :skip\n  @tag skip: false\n  test \"t\", do: :ok") == []
    # A describe turns a module skip off for its tests.
    assert planted_refusals(dir, """
             @moduletag :skip
             describe "d" do
               @describetag skip: false
               test "t", do: :ok
             end
           """) == []

    # The fields may come from another level than the skip.
    assert planted_refusals(dir, """
             @moduletag owner: "someone", covered_by: "elsewhere"
             describe "d" do
               @describetag expires: "#{@future}"
               @tag :skip
               test "t", do: :ok
             end
           """) == []
  end

  test "later tag metadata cannot turn an allowed skip into an expired skip", %{dir: dir} do
    assert [refused] =
             planted_refusals(dir, """
               @tag #{@permitted}
               @tag expires: "#{@past}"
               test "t", do: :ok
             """)

    assert refused =~ "expired #{@past}"
  end

  test "describe metadata cannot expire an inherited module skip", %{dir: dir} do
    assert [refused] =
             planted_refusals(dir, """
               @moduletag #{@permitted}
               describe "inherited" do
                 @describetag expires: "#{@past}"
                 test "t", do: :ok
               end
             """)

    assert refused =~ "expired #{@past}"
  end

  test "test metadata cannot remove the owner of an inherited describe skip", %{dir: dir} do
    assert [refused] =
             planted_refusals(dir, """
               describe "inherited" do
                 @describetag #{@permitted}
                 @tag owner: nil
                 test "t", do: :ok
               end
             """)

    assert refused =~ "owner: is not a name"
  end

  test "a skip with every field, not yet expired, covering a file in the tree, is permitted", %{
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "apps/other/test"))
    File.write!(Path.join(dir, "apps/other/test/kept_test.exs"), "")

    assert planted_refusals(dir, """
             @tag skip: "the defect", owner: "someone", expires: "#{@future}", covered_by: "apps/other/test/kept_test.exs:12"
             test "t", do: :ok
           """) == []
  end

  test "a skip past its date is refused, and one dated today still stands", %{dir: dir} do
    tag =
      ~s(@tag skip: "the defect", owner: "someone", expires: "#{@past}", covered_by: "elsewhere")

    assert [refused] = planted_refusals(dir, "  #{tag}\n  test \"t\", do: :ok")
    assert refused =~ "expired #{@past}"

    today = Date.utc_today()

    assert planted_refusals(dir, "  #{tag}\n  test \"t\", do: :ok", Date.from_iso8601!(@past)) ==
             []

    assert planted_refusals(dir, "  #{tag}\n  test \"t\", do: :ok", Date.add(today, 400)) != []
  end

  test "a field that names nothing, an undated expiry and a missing coverage file are refused", %{
    dir: dir
  } do
    assert [refused] =
             planted_refusals(dir, """
               @tag skip: true, owner: "  ", expires: "soon", covered_by: "apps/other/test/gone_test.exs"
               test "t", do: :ok
             """)

    assert refused =~ "owner: is not a name"
    assert refused =~ "expires: \"soon\" is not an ISO 8601 date"
    assert refused =~ "covered_by: apps/other/test/gone_test.exs is not a file in the tree"
  end

  test "a skip in a string or a comment is a fixture, not a skip", %{dir: dir} do
    assert planted_refusals(dir, """
             # @tag :skip
             @fixture \"\"\"
             @tag :skip
             test "inner", do: :ok
             \"\"\"
             test "t", do: assert(@fixture =~ "skip")
           """) == []
  end

  test "a skip computed from the host is a prerequisite skip, refused unless rostered", %{
    dir: dir
  } do
    body = """
      @unavailable System.get_env("PLANTED_NEVER") == nil
      @tag skip: @unavailable && "the host lacks the planted prerequisite"
      test "t", do: :ok
    """

    assert [refused] = planted_refusals(dir, body)

    assert refused =~
             "prerequisite skip @unavailable && \"the host lacks the planted prerequisite\" is not rostered"
  end

  test "a skip set to false or nil runs, and a tag the roster cannot read is refused", %{dir: dir} do
    assert planted_refusals(dir, "  @tag skip: false\n  @tag skip: nil\n  test \"t\", do: :ok") ==
             []

    assert [refused] = planted_refusals(dir, "  @tag tags_for(:slow)\n  test \"t\", do: :ok")
    assert refused =~ "tag @tag tags_for(:slow) cannot be read for a skip"

    assert [refused] = planted_refusals(dir, "  @describetag :skip\n  test \"t\", do: :ok")
    assert refused =~ "@describetag outside a describe cannot be read"
  end
end
