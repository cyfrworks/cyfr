# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RosterLiteralTest do
  @moduledoc """
  The credential kinds have one owner, and no library source spells them
  again.

  `Prima.CredentialKinds` owns the kinds (`all/0`, `shareable/0`). A
  second spelling is a roster that stays behind when the owner moves: a
  surface offering a kind the vault refuses.

  The scan reads every app's `lib/` as code, not text: a `~w` sigil or a
  list of strings naming a roster's whole set, in any order, a string
  naming its members in a row ("api_key | oauth | bundle | login"), and a
  map keyed by every credential kind, whose policy per kind derives from
  the owner's list. Documentation and comments may name the members.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # The rosters' ordered vocabularies; the first test holds the owners to
  # them.
  @kinds ~w(api_key oauth bundle login)
  @shareable_kinds ~w(api_key bundle login)

  @rosters [
    {"credential kinds", @kinds},
    {"shareable credential kinds", @shareable_kinds}
  ]

  @owners %{
    "apps/prima/lib/prima/credential_kinds.ex" => [
      "credential kinds",
      "shareable credential kinds"
    ]
  }

  test "the owners answer the rosters" do
    assert Prima.CredentialKinds.all() == @kinds
    assert Prima.CredentialKinds.shareable() == @shareable_kinds
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
           (Prima.CredentialKinds):

           #{Enum.join(offenders, "\n")}
           """

    # The scan read the tree the owners live in.
    assert Map.keys(@owners) -- files == []
  end

  test "every roster form is found" do
    planted = [
      {~S'@k ~w(api_key oauth bundle login)', "credential kinds"},
      {~S'@k ~w(bundle login api_key oauth)a', "credential kinds"},
      {~S'def k, do: ["api_key", "oauth", "bundle", "login"]', "credential kinds"},
      {~S'def k(x) when x in ~w(api_key bundle login), do: x', "shareable credential kinds"},
      {~S'def k, do: Arg.new("kind", :string, enum: ["api_key", "bundle", "login"])',
       "shareable credential kinds"},
      {~S'def m, do: {:error, "create requires name and kind (api_key | oauth | bundle | login)"}',
       "credential kinds"},
      {~S'@m %{"api_key" => :fields, "bundle" => :fields, "oauth" => :scopes, "login" => nil}',
       "credential kinds"}
    ]

    for {line, roster} <- planted do
      assert [finding] = refused("lib/planted.ex", module_with(line)),
             "#{line} is not refused once"

      assert finding =~ "lib/planted.ex:3" and finding =~ "(#{roster})", finding
    end

    for line <- [
          ~S'@k ~w(api_key oauth)',
          ~S'@k ~w(api_key bundle)',
          ~S'@doc "A kind: api_key | oauth | bundle | login."',
          ~S'def m, do: "api_key oauth bundle login"'
        ] do
      assert refused("lib/planted.ex", module_with(line)) == [], "#{line} is refused"
    end

    # The owner spells its rosters.
    owner = "apps/prima/lib/prima/credential_kinds.ex"
    assert refused(owner, module_with(~S'@k ~w(api_key oauth bundle login)')) == []
    assert refused(owner, module_with(~S'@s ~w(api_key bundle login)')) == []
  end

  defp module_with(line), do: "defmodule Planted do\n  @moduledoc false\n  #{line}\nend\n"

  # `path:line in function: form (roster)` for each spelling the source holds
  # that its owner does not.
  defp refused(file, source) do
    owned = Map.get(@owners, file, [])

    source
    |> Code.string_to_quoted!(file: file, literal_encoder: &located/2)
    |> walk(%{function: nil, line: 1}, [])
    |> Enum.reverse()
    |> Enum.reject(fn {_line, _function, _form, roster} -> roster in owned end)
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
