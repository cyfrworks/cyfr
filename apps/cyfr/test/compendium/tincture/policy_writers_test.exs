# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Tincture.PolicyWritersTest do
  @moduledoc """
  A frame's policy has one writer: no library source but the tincture
  rules writes a Content Security Policy directive or a sandbox token, or
  pairs a file extension with the type it is served as.
  Every string literal of every library module and template is read, and
  documentation is not code, so a module's docs may name a directive. The
  console's page policy and the API's and the OAuth callback's response
  policies are other surfaces' own, rostered here by reason, and the
  roster is exact.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @rules "apps/cyfr/lib/compendium/tincture/rules.ex"

  @roster %{
    "apps/cyfr/lib/cyfr_web/plugs/browser_csp.ex" =>
      "the console's own page policy, for the glass and its LiveViews; no frame is served under it",
    "apps/cyfr/lib/cyfr_web/plugs/api_security_headers.ex" =>
      "an API response renders no document, and its policy refuses everything",
    "apps/cyfr/lib/emissary/web/controllers/oauth_callback_controller.ex" =>
      "the OAuth callback's own result page, served on the site origin and framed by nothing"
  }

  # A directive starts a policy or follows a `;`, and what follows its name
  # is a source or a token (`'self'`, `data:`, `https://…`, `*`,
  # `allow-…`) or nothing yet, the value a caller appends. Prose that opens
  # with a directive's word is followed by neither.
  @directive ~r/(?:^|;)\s*(?:[a-z]+-src|frame-ancestors|form-action|base-uri|sandbox|upgrade-insecure-requests|block-all-mixed-content|report-uri|report-to|require-trusted-types-for|trusted-types|navigate-to)(?:\s+$|\s+(?:'[^']+'|[a-z][a-z0-9+.-]*:|\*|allow-[a-z-]+))/
  @sandbox_token ~r/(?:^|[\s"'])allow-(?:scripts|same-origin|forms|popups|popups-to-escape-sandbox|modals|pointer-lock|downloads|top-navigation[a-z-]*|presentation|orientation-lock|storage-access-by-user-activation)(?=[\s"']|$)/

  @docs [:moduledoc, :doc, :typedoc, :shortdoc]

  # A module's quoted source with every run of adjacent literal fragments
  # joined into one literal: a `<>` chain and a binary construction are
  # read as the text they build, so a directive, a token or a type split
  # across literals is still the literal it spells.
  defp quoted(source, file) do
    source
    |> Code.string_to_quoted!(file: file, columns: false)
    |> Macro.postwalk(&joined/1)
  end

  defp joined({:<>, meta, [left, right]}) do
    case {left, right} do
      {left, right} when is_binary(left) and is_binary(right) ->
        left <> right

      {left, {:<>, inner, [head, rest]}} when is_binary(left) and is_binary(head) ->
        {:<>, inner, [left <> head, rest]}

      {{:<>, inner, [rest, tail]}, right} when is_binary(tail) and is_binary(right) ->
        {:<>, inner, [rest, tail <> right]}

      _apart ->
        {:<>, meta, [left, right]}
    end
  end

  defp joined({:<<>>, meta, parts}) when is_list(parts) do
    case parts |> Enum.map(&segment/1) |> Enum.chunk_while([], &run/2, &flush/1) do
      [text] when is_binary(text) -> text
      joined -> {:<<>>, meta, joined}
    end
  end

  defp joined(node), do: node

  # A literal segment is read as its literal whatever its specifier
  # (`::binary`, `::utf8`, a size); an interpolation's segment is not one.
  defp segment({:"::", _, [literal, _specifier]}) when is_binary(literal), do: literal
  defp segment(part), do: part

  defp run(part, [text]) when is_binary(part) and is_binary(text), do: {:cont, [text <> part]}
  defp run(part, []), do: {:cont, [part]}
  defp run(part, [previous]), do: {:cont, previous, [part]}

  defp flush([]), do: {:cont, []}
  defp flush([last]), do: {:cont, last, []}

  # The string literals of a module's source, its docs left out.
  defp literals(source, file) do
    source
    |> quoted(file)
    |> Macro.prewalk([], fn
      {:@, _, [{doc, _, _}]}, acc when doc in @docs -> {nil, acc}
      literal, acc when is_binary(literal) -> {literal, [literal | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
  end

  defp writes_policy?(text), do: text =~ @directive or text =~ @sandbox_token

  defp writers(sources) do
    for {path, source} <- sources,
        texts =
          if(String.ends_with?(path, ".ex"), do: literals(source, path), else: [source]),
        hits = Enum.filter(texts, &writes_policy?/1),
        hits != [],
        into: %{},
        do: {path, hits}
  end

  defp library_sources do
    for path <- Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.{ex,heex}")),
        do: {Path.relative_to(path, @repo_root), File.read!(path)}
  end

  test "no library source but the tincture rules writes a policy directive or a sandbox token" do
    found = writers(library_sources())

    # The scan reads the rules themselves, so it is reading what it claims to.
    assert Map.has_key?(found, @rules)

    outside = found |> Map.delete(@rules) |> Map.keys() |> Enum.sort()

    assert outside == @roster |> Map.keys() |> Enum.sort(),
           """
           policy writers outside the tincture rules: #{inspect(outside)}
           rostered: #{inspect(@roster |> Map.keys() |> Enum.sort())}
           A frame's policy belongs in Compendium.Tincture.Rules; another surface's own
           policy joins the roster with its reason, and an entry that no longer writes
           one is removed.
           """
  end

  # A served type is an extension paired with the media type it is served
  # as, in a map or a two-element tuple; the tincture rules hold the one
  # table of them (`Compendium.Tincture.Rules.served_types/0`).
  @extension ~r/^\.[a-z0-9]+$/
  @media_type ~r/^[a-z]+\/[a-z0-9.+-]+$/

  defp served_type?({extension, type}) when is_binary(extension) and is_binary(type),
    do: extension =~ @extension and type =~ @media_type

  defp served_type?(_pair), do: false

  defp type_tables(sources) do
    for {path, source} <- sources,
        String.ends_with?(path, ".ex"),
        pairs = served_type_pairs(source, path),
        pairs != [],
        into: %{},
        do: {path, pairs}
  end

  defp served_type_pairs(source, file) do
    source
    |> quoted(file)
    # A map's pairs are two-element tuples in the quoted form too.
    |> Macro.prewalk([], fn
      {_extension, _type} = pair, acc ->
        {pair, if(served_type?(pair), do: [pair | acc], else: acc)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  test "no library source but the tincture rules pairs an extension with a served type" do
    found = type_tables(library_sources())

    assert Map.has_key?(found, @rules)
    assert found |> Map.delete(@rules) |> Map.keys() == []
  end

  test "the type scan finds a table in a map and in tuples" do
    table = ~S"""
    defmodule Types do
      @types %{".html" => "text/html"}
      def more, do: [{".wasm", "application/wasm"}, {"name", "value"}]
    end
    """

    assert %{"types.ex" => pairs} = type_tables([{"types.ex", table}])
    assert Enum.sort(pairs) == [{".html", "text/html"}, {".wasm", "application/wasm"}]
  end

  test "the scan finds a composed directive and a token, and leaves docs alone" do
    composed = ~S'''
    defmodule Probe do
      @moduledoc "Served with `frame-ancestors 'none'` and `allow-scripts`."
      @doc "; sandbox allow-scripts"
      def policy(csp, tokens), do: csp <> "; sandbox " <> Enum.join(tokens, " ")
      def token, do: "allow-same-origin"
      def mention, do: "the page's `connect-src` names the endpoint"
    end
    '''

    assert %{"probe.ex" => hits} = writers([{"probe.ex", composed}])
    assert Enum.sort(hits) == ["; sandbox ", "allow-same-origin"]

    documented = ~S'''
    defmodule Quiet do
      @moduledoc "default-src 'self'; sandbox allow-scripts"
      def sandbox, do: "sandbox"
      def prose, do: "sandbox or compile-time work, and script-src is the page's"
    end
    '''

    assert writers([{"quiet.ex", documented}]) == %{}
  end

  test "a directive assembled from literal fragments still has a policy writer" do
    source = ~S'''
    defmodule SplitPolicy do
      def policy, do: "script" <> "-src 'none'"
    end
    '''

    assert Map.has_key?(writers([{"split_policy.ex", source}]), "split_policy.ex")
  end

  test "a sandbox token assembled from literal fragments still has a policy writer" do
    source = ~S'''
    defmodule SplitSandbox do
      def token, do: "allow-" <> "scripts"
    end
    '''

    assert Map.has_key?(writers([{"split_sandbox.ex", source}]), "split_sandbox.ex")
  end

  test "an extension and media type assembled from literal fragments still have a type writer" do
    source = ~S'''
    defmodule SplitTypes do
      def types, do: %{"." <> "html" => "text/" <> "html"}
    end
    '''

    assert Map.has_key?(type_tables([{"split_types.ex", source}]), "split_types.ex")
  end

  test "a binary construction and a parenthesised chain of literals are read as the text they build" do
    source = ~S'''
    defmodule Built do
      def token, do: <<"allow-", "forms">>
      def policy, do: ("frame-" <> "ancestors") <> " 'none'"
      def type, do: {<<".", "wasm">>, "application/" <> "wasm"}
      def interpolated(x), do: "frame-#{x}"
    end
    '''

    assert %{"built.ex" => hits} = writers([{"built.ex", source}])
    assert Enum.sort(hits) == ["allow-forms", "frame-ancestors 'none'"]
    assert %{"built.ex" => [{".wasm", "application/wasm"}]} = type_tables([{"built.ex", source}])
  end

  test "a directive built from typed literal binary segments is found" do
    assert <<"script"::binary, "-src 'none'">> == "script-src 'none'"

    source = ~S"""
    defmodule TypedPolicy do
      def policy, do: <<"script"::binary, "-src 'none'">>
    end
    """

    assert Map.has_key?(writers([{"typed_policy.ex", source}]), "typed_policy.ex")
  end

  test "a sandbox token built from typed literal binary segments is found" do
    assert <<"allow-"::binary, "scripts">> == "allow-scripts"

    source = ~S"""
    defmodule TypedSandbox do
      def token, do: <<"allow-"::binary, "scripts">>
    end
    """

    assert Map.has_key?(writers([{"typed_sandbox.ex", source}]), "typed_sandbox.ex")
  end

  test "a served type pair built from typed literal binary segments is found" do
    source = ~S"""
    defmodule TypedTypes do
      def types, do: %{<<"."::binary, "html">> => <<"text/"::binary, "html">>}
    end
    """

    assert Map.has_key?(type_tables([{"typed_types.ex", source}]), "typed_types.ex")
  end
end
