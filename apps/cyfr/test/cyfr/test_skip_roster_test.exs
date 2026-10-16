# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestSkipRosterTest do
  @moduledoc """
  There is no quarantine lane. A test the suite skips is a proven test
  defect that is owned, dated and covered elsewhere, or it runs.

  Every test file under `apps/*/test` is read as code, so a `@tag :skip`
  inside a string or a comment is a fixture, not a skip, and a skip spelled
  `@tag :skip`, `@tag skip: ...`, `@moduletag ...` or `@describetag ...`,
  bare or inside a keyword list, is one. A skip whose value is a literal
  (`:skip`, `skip: true`, `skip: "why"`) stands on every host: it is
  refused unless its tag also carries `owner:` (a name), `expires:` (an
  ISO 8601 date not yet passed) and `covered_by:` (where the coverage is
  kept; a test path there names a file that exists). A skip whose value
  is computed from the host (`skip: @unavailable && "why"`) skips the test
  only where the host cannot run it and excludes nothing elsewhere, so it
  carries no expiry; each such skip is rostered below by file and exact
  expression, and one not rostered is refused. A tag whose shape the roster cannot read
  statically is refused too, so no skip hides behind a call. Within one tag a
  repeated key counts as ExUnit counts it, the last one written, so
  `skip: false, skip: true` skips; the fields belong on the same tag as the
  skip.

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

  @tag_attributes [:tag, :moduletag, :describetag]
  @required [:owner, :expires, :covered_by]

  # Every tag of every file that skips, or that cannot be read, as
  # `{file, line, kind, detail}`: kind `:standing` with its keyword fields,
  # `:prerequisite` with the skip's expression, `:unreadable` with the tag's
  # source.
  defp skips(root, files) do
    Enum.flat_map(files, fn file ->
      path = Path.join(root, file)
      source = File.read!(path)
      ast = Code.string_to_quoted!(source, file: path)

      {_ast, found} =
        Macro.prewalk(ast, [], fn
          {:@, meta, [{name, _, [argument]}]} = node, acc when name in @tag_attributes ->
            line = Keyword.get(meta, :line)

            case tag_skip(argument) do
              nil -> {node, acc}
              {kind, detail} -> {node, [{file, line, kind, detail} | acc]}
            end

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(found)
    end)
  end

  # What a tag argument says about skipping, read from its syntax.
  defp tag_skip(:skip), do: {:standing, %{}}
  defp tag_skip(atom) when is_atom(atom), do: nil

  defp tag_skip(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _} when is_atom(key), &1)) do
      # ExUnit folds a tag's keywords into a map, so a repeated key is the
      # last one written.
      fields = Map.new(list)

      case Map.fetch(fields, :skip) do
        :error ->
          nil

        {:ok, value} when value in [false, nil] ->
          nil

        {:ok, value} ->
          if Macro.quoted_literal?(value), do: {:standing, fields}, else: {:prerequisite, value}
      end
    else
      {:unreadable, Macro.to_string(list)}
    end
  end

  defp tag_skip(other), do: {:unreadable, Macro.to_string(other)}

  # Why a found skip is refused, or nil when it is permitted.
  defp refusal(root, {file, line, :standing, fields}, today) do
    missing = Enum.reject(@required, &Map.has_key?(fields, &1))

    reasons =
      Enum.reject(
        [
          missing != [] && "lacks #{Enum.map_join(missing, ", ", &"#{&1}:")}",
          Map.has_key?(fields, :owner) && not name?(fields[:owner]) && "owner: is not a name",
          Map.has_key?(fields, :expires) && expiry_refusal(fields[:expires], today),
          Map.has_key?(fields, :covered_by) && coverage_refusal(root, fields[:covered_by])
        ],
        &(&1 in [false, nil])
      )

    if reasons == [], do: nil, else: "#{file}:#{line} standing skip #{Enum.join(reasons, "; ")}"
  end

  defp refusal(_root, {file, line, :prerequisite, expression}, _today) do
    written = Macro.to_string(expression)

    if written in Map.get(@prerequisite_skips, file, []),
      do: nil,
      else: "#{file}:#{line} prerequisite skip #{written} is not rostered"
  end

  defp refusal(_root, {file, line, :unreadable, source}, _today),
    do: "#{file}:#{line} tag #{source} cannot be read for a skip"

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
    |> skips(files)
    |> Enum.map(&refusal(root, &1, today))
    |> Enum.reject(&is_nil/1)
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

  test "no test file skips without an owner, an expiry and kept coverage" do
    files = test_files(@root)
    assert refusals(@root, files) == []
  end

  test "the prerequisite skips are exactly the rostered expressions" do
    found =
      for {file, _line, :prerequisite, expression} <- skips(@root, test_files(@root)),
          do: {file, Macro.to_string(expression)}

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

  test "a later repeated skip key cannot hide an effective skip", %{dir: dir} do
    for off <- ["false", "nil"] do
      assert [refused] =
               planted_refusals(dir, "  @tag skip: #{off}, skip: true\n  test \"t\", do: :ok")

      assert refused =~ "standing skip lacks owner:, expires:, covered_by:"
    end

    # And the other way round, as ExUnit reads it: the last key, false, runs
    # the test.
    assert planted_refusals(dir, "  @tag skip: true, skip: false\n  test \"t\", do: :ok") == []
  end

  test "a bare skip is refused, in every tag attribute", %{dir: dir} do
    for attribute <- [
          "@tag :skip",
          "@moduletag :skip",
          "@describetag skip: true",
          "@tag skip: \"flaky\""
        ] do
      assert [refused] = planted_refusals(dir, "  #{attribute}\n  test \"t\", do: :ok")
      assert refused =~ "standing skip lacks owner:, expires:, covered_by:"
    end
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
    assert refused =~ "tag tags_for(:slow) cannot be read for a skip"
  end
end
