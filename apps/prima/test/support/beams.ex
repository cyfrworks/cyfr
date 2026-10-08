# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.Beams do
  @moduledoc """
  What a compiled module reaches, read from its beam: the remote calls
  the compiler emitted and the external captures it stored. A seam a
  source scan cannot hold — a call through an alias or an import, a
  capture, a name that is only a string — is held here, because the beam
  says what runs.

  A beam is a path as a charlist, or the compiled binary
  `Code.compile_string/1` returns.
  """

  @typedoc "A function another module reaches: `{module, function, arity}`."
  @type reach :: {module(), atom(), arity()}

  @typedoc "A beam: its path as a charlist, or its compiled binary."
  @type beam :: charlist() | binary()

  @doc "Every function `beam` calls or captures, the calls first."
  @spec reaches(beam()) :: [reach()]
  def reaches(beam), do: imports(beam) ++ captures(beam)

  @doc "The remote calls `beam` makes, from its import table."
  @spec imports(beam()) :: [reach()]
  def imports(beam) do
    {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports
  end

  @doc """
  The external captures `beam` holds. A call is in the import table; an
  external capture (`&Sanctum.Egress.pinned_request/5`) emits no import
  and is a fun in the literal table instead.
  """
  @spec captures(beam()) :: [reach()]
  def captures(beam) do
    # The literal table is `<<size::32, data>>`, `data` zlib-compressed unless
    # `size` is 0, and holds a count and then each term length-prefixed.
    case :beam_lib.chunks(beam, [~c"LitT"]) do
      {:ok, {_mod, [{~c"LitT", <<size::32, data::binary>>}]}} ->
        <<count::32, terms::binary>> = if size == 0, do: data, else: :zlib.uncompress(data)
        terms |> literal_terms(count) |> Enum.flat_map(&external_funs/1)

      _ ->
        []
    end
  end

  @doc """
  Whether the beam at `path` was compiled from a `lib/` source. The test
  build compiles `test/support` into the same ebin; a support module is
  not the application, and its reaches are the suite's.
  """
  @spec production?(Path.t()) :: boolean()
  def production?(path) do
    case :beam_lib.chunks(String.to_charlist(path), [:compile_info]) do
      {:ok, {_mod, [compile_info: info]}} ->
        info |> Keyword.get(:source, ~c"") |> to_string() |> String.contains?("/lib/")

      _ ->
        false
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
end
