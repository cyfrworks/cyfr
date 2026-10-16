# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RosterLiteralTest do
  @moduledoc """
  The credential kinds and the sign-in providers each have one owner, and
  no library source spells them again.

  `Prima.CredentialKinds` owns the kinds (`all/0`, `instance/0`),
  `Sanctum.Atoms.providers/0` the sign-in providers, and
  `Sanctum.Auth.DeviceFlow.providers/0` is a filter over it. A second
  spelling is a roster that stays behind when the owner moves: a surface
  offering a kind the vault refuses, or an operation enum refusing a
  provider sign-in accepts.

  The scan reads every app's `lib/` as code, not text: a `~w` sigil or a
  list of strings naming a roster's whole set, in any order, a string
  naming its members in a row ("api_key | oauth | bundle"), and a map
  keyed by every credential kind, whose policy per kind derives from the
  owner's list. A map keyed by sign-in providers is no roster: it holds
  each provider's own facts (an issuer, an endpoint), which the module
  that speaks to that provider keeps. Documentation and comments may name
  the members.

  One spelling is no roster: the commit's no-scopes policy
  (`Sanctum.Consent.Commit`'s `check_token_grant/3`), which says that a key
  or a bundle need grants no scopes. It coincides with the instance kinds
  and is its own owner, so it is exempt in that function alone.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # The rosters, as §N2 of the plan fixes their values; the first test
  # holds the owners to them.
  @kinds ~w(api_key oauth bundle)
  @instance_kinds ~w(api_key bundle)
  @sign_in ~w(github google oidcc)
  @device_flow ~w(github google)

  @rosters [
    {"credential kinds", @kinds},
    {"instance credential kinds", @instance_kinds},
    {"sign-in providers", @sign_in},
    {"device-flow providers", @device_flow}
  ]

  @owners %{
    "apps/prima/lib/prima/credential_kinds.ex" => [
      "credential kinds",
      "instance credential kinds"
    ],
    "apps/sanctum/lib/sanctum/atoms.ex" => ["sign-in providers"]
  }

  # `{file, function, roster}`: a spelling that is its own policy, not the
  # roster it coincides with.
  @policies [
    {"apps/sanctum/lib/sanctum/consent/commit.ex", :check_token_grant,
     "instance credential kinds"}
  ]

  @commit "apps/sanctum/lib/sanctum/consent/commit.ex"

  test "the owners answer the rosters" do
    assert Prima.CredentialKinds.all() == @kinds
    assert Prima.CredentialKinds.instance() == @instance_kinds
    assert Sanctum.Atoms.providers() == @sign_in
    assert Sanctum.Auth.DeviceFlow.providers() == @device_flow
  end

  test "no library source spells a roster outside its owner" do
    files =
      for lib <- Prima.Test.SourceTree.app_libs(@root),
          file <- Prima.Test.SourceTree.files!(Path.join([@root, lib, "**/*.ex"])),
          do: Path.relative_to(file, @root)

    offenders =
      for file <- files,
          finding <- refused(file, Prima.Test.SourceTree.read(Path.join(@root, file))),
          do: finding

    assert offenders == [],
           """
           These sources spell a roster its owner declares; read the owner instead
           (Prima.CredentialKinds, Sanctum.Atoms.providers/0,
           Sanctum.Auth.DeviceFlow.providers/0):

           #{Enum.join(offenders, "\n")}
           """

    # The scan read the tree the owners and the policy live in.
    assert @commit in files and Map.keys(@owners) -- files == []
  end

  test "every roster form is found, and only the named policy is exempt" do
    planted = [
      {~S'@k ~w(api_key oauth bundle)', "credential kinds"},
      {~S'@k ~w(bundle api_key oauth)a', "credential kinds"},
      {~S'def k, do: ["api_key", "oauth", "bundle"]', "credential kinds"},
      {~S'def k(x) when x in ~w(api_key bundle), do: x', "instance credential kinds"},
      {~S'def k, do: Arg.new("kind", :string, enum: ["api_key", "bundle"])',
       "instance credential kinds"},
      {~S'@p ~w(github google oidcc)', "sign-in providers"},
      {~S'def p, do: ["github", "google", "oidcc"]', "sign-in providers"},
      {~S'def p(x) when x in ["github", "google"], do: x', "device-flow providers"},
      {~S'def m, do: {:error, "create requires name and kind (api_key | oauth | bundle)"}',
       "credential kinds"},
      {~S'def m(x), do: "#{x} takes github or google"', "device-flow providers"},
      {~S'@m %{"api_key" => :fields, "bundle" => :fields, "oauth" => :scopes}',
       "credential kinds"}
    ]

    for {line, roster} <- planted do
      assert [finding] = refused("lib/planted.ex", module_with(line)),
             "#{line} is not refused once"

      assert finding =~ "lib/planted.ex:3" and finding =~ "(#{roster})", finding
    end

    for line <- [
          ~S'@k ~w(api_key oauth)',
          ~S'def p, do: ["github"]',
          ~S'@doc "A kind: api_key | oauth | bundle."',
          ~S'def m, do: "api_key oauth bundle"',
          ~S'@i %{"github" => "https://github.com", "google" => "https://accounts.google.com"}'
        ] do
      assert refused("lib/planted.ex", module_with(line)) == [], "#{line} is refused"
    end

    # An owner spells its roster and nothing else.
    assert refused(
             "apps/sanctum/lib/sanctum/atoms.ex",
             module_with(~S'@p ~w(github google oidcc)')
           ) ==
             []

    assert [_] =
             refused("apps/sanctum/lib/sanctum/atoms.ex", module_with(~S'@k ~w(api_key bundle)'))

    # The commit's no-scopes policy is accepted where it is, and the same
    # spelling anywhere else in the file is a roster.
    source = Prima.Test.SourceTree.read(Path.join(@root, @commit))

    assert source =~
             "defp check_token_grant(%{kind: kind}, [_ | _], need) when kind in ~w(api_key bundle)"

    assert refused(@commit, source) == []

    duplicate = "  defp planted_kind(kind) when kind in ~w(api_key bundle), do: kind\n"
    planted = String.replace(source, ~r/\nend\s*\z/, "\n" <> duplicate <> "end\n")
    assert planted != source

    assert [finding] = refused(@commit, planted)
    assert finding =~ "planted_kind" and finding =~ "(instance credential kinds)"
  end

  defp module_with(line), do: "defmodule Planted do\n  @moduledoc false\n  #{line}\nend\n"

  # `path:line in function: form (roster)` for each spelling the source holds
  # that neither its owner nor a named policy may hold.
  defp refused(file, source) do
    owned = Map.get(@owners, file, [])

    source
    |> Code.string_to_quoted!(file: file, literal_encoder: &located/2)
    |> walk(%{function: nil, line: 1}, [])
    |> Enum.reverse()
    |> Enum.reject(fn {_line, _function, _form, roster} -> roster in owned end)
    |> Enum.reject(fn {_line, function, _form, roster} ->
      {file, function, roster} in @policies
    end)
    |> Enum.map(fn {line, function, form, roster} ->
      "#{file}:#{line} in #{function || "the module body"}: #{form} (#{roster})"
    end)
  end

  # A string or list literal carries its own line, as a one-form block.
  defp located(literal, meta) when is_binary(literal) or is_list(literal),
    do: {:ok, {:__block__, meta, [literal]}}

  defp located(literal, _meta), do: {:ok, literal}

  defp plain({:__block__, _, [literal]}) when is_binary(literal) or is_list(literal),
    do: plain(literal)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(other), do: other

  @doc_attributes [:doc, :moduledoc, :typedoc, :shortdoc]

  defp walk({:@, _, [{attribute, _, _}]}, _ctx, acc) when attribute in @doc_attributes,
    do: acc

  defp walk({kind, meta, [head | body]}, ctx, acc)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(meta) do
    ctx = %{ctx | function: function_name(head), line: Keyword.get(meta, :line, ctx.line)}
    walk([head | body], ctx, acc)
  end

  defp walk({:__block__, meta, [literal]}, ctx, acc)
       when is_binary(literal) or is_list(literal) do
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line)}

    case spelled(plain(literal)) do
      {form, roster} -> [{ctx.line, ctx.function, form, roster} | acc]
      nil -> literal |> children() |> Enum.reduce(acc, &walk(&1, ctx, &2))
    end
  end

  defp walk(node, ctx, acc) do
    ctx = %{ctx | line: line(node, ctx.line)}

    case spelled(node) do
      {form, roster} ->
        [{ctx.line, ctx.function, form, roster} | acc]

      nil ->
        node |> children() |> Enum.reduce(acc, &walk(&1, ctx, &2))
    end
  end

  defp function_name({:when, _, [call | _]}), do: function_name(call)
  defp function_name({name, _, _}) when is_atom(name), do: name
  defp function_name(_head), do: nil

  defp line({_, meta, _}, line) when is_list(meta), do: Keyword.get(meta, :line, line)
  defp line(_node, line), do: line

  defp children({form, _meta, args}) when is_list(args), do: [form | args]
  defp children({form, _meta, _context}), do: [form]
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_leaf), do: []

  # A `~w` sigil or a string list naming a roster's set, a map keyed by
  # the credential kinds, or a string naming a roster's members in a row.
  defp spelled({sigil, _, [{:<<>>, _, [words]}, _modifiers]})
       when sigil in [:sigil_w, :sigil_W] do
    case plain(words) do
      words when is_binary(words) -> roster_of(String.split(words), "~w(#{words})")
      _interpolated -> nil
    end
  end

  defp spelled([_, _ | _] = list) do
    if Enum.all?(list, &is_binary/1), do: roster_of(list, inspect(list))
  end

  defp spelled({:%{}, _, [_, _ | _] = pairs}) do
    keys = for {key, _value} <- pairs, do: plain(key)

    if Enum.all?(keys, &is_binary/1) and MapSet.equal?(MapSet.new(keys), MapSet.new(@kinds)),
      do: {"a map keyed #{inspect(keys)}", "credential kinds"}
  end

  defp spelled(text) when is_binary(text) do
    Enum.find_value(@rosters, fn {roster, values} ->
      if Regex.match?(in_a_row(values), text), do: {inspect(text), roster}
    end)
  end

  defp spelled(_node), do: nil

  defp roster_of(values, form) do
    set = MapSet.new(values)

    Enum.find_value(@rosters, fn {roster, members} ->
      if MapSet.equal?(set, MapSet.new(members)), do: {form, roster}
    end)
  end

  # The members in their order, apart by a `|`, a comma or a slash, or by
  # "or" or "and".
  defp in_a_row(values) do
    separator = ~S"\s*(?:[|,/]\s*(?:(?:or|and)\s+)?|\s(?:or|and)\s+)"
    Regex.compile!(~S"\b" <> Enum.map_join(values, separator, &Regex.escape/1) <> ~S"\b")
  end
end
