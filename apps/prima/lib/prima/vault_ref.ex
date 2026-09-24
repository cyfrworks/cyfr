# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.VaultRef do
  @moduledoc """
  Constructs and classifies vault references in header and env values.

  A value spells a reference when it is `<ref>:<entry>` or
  `<scheme> <ref>:<entry>`, the scheme an RFC 9110 token and `<ref>` one of
  `vault` and `secret`:

    * `vault:<entry>` naming an entry is a template — `Bearer vault:gh-token`
      — and resolves to that single-field entry's value, after the scheme
      and a space when there is one;
    * `secret:<entry>`, and `vault:` naming no entry, are references this
      server does not resolve, in either spelling. They are refused wherever
      a header or env is written or resolved, never sent as a literal;
    * anything else is a literal.

  `classify/1` reads the one grammar, and `template/1`, `vault_ref?/1` and
  `unresolved_ref?/1` answer from it; every reader of values — the
  resolvers, the validators, the reconciler and the listings — goes through
  them.
  """

  @prefix "vault:"
  # An HTTP authentication scheme is an RFC 9110 token.
  @reference ~r/\A(?:([!#$%&'*+.^_`|~0-9A-Za-z-]+) )?(vault|secret):(.*)\z/s

  @typedoc "A parsed template: the scheme before the reference, if any, and the entry named."
  @type template :: %{scheme: String.t() | nil, name: String.t()}

  @typedoc "What a value spells: a template, a reference this server does not resolve, or a literal."
  @type class :: {:vault, template()} | :unresolved | :literal

  @doc "The reference prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Build the reference for a vault entry name (or id)."
  @spec build(String.t()) :: String.t()
  def build(name) when is_binary(name), do: @prefix <> name

  @doc "What a value spells. A non-binary value is a literal."
  @spec classify(term()) :: class()
  def classify(value) when is_binary(value) do
    case Regex.run(@reference, value, capture: :all_but_first) do
      [scheme, "vault", name] when name != "" -> {:vault, %{scheme: scheme(scheme), name: name}}
      [_scheme, _ref, _name] -> :unresolved
      nil -> :literal
    end
  end

  def classify(_value), do: :literal

  @doc "The template a value spells, or `:error` for a literal or an unresolved reference."
  @spec template(term()) :: {:ok, template()} | :error
  def template(value) do
    case classify(value) do
      {:vault, template} -> {:ok, template}
      _other -> :error
    end
  end

  @doc "Whether a value is a vault template, with or without a scheme."
  @spec vault_ref?(term()) :: boolean()
  def vault_ref?(value), do: match?({:vault, _template}, classify(value))

  @doc "The entry names a header or env map's templates reference, sorted and unique."
  @spec names(map()) :: [String.t()]
  def names(values) when is_map(values) do
    for {_key, value} <- values, {:ok, %{name: name}} <- [template(value)], uniq: true do
      name
    end
    |> Enum.sort()
  end

  @doc "The value a template resolves to, given its entry's value."
  @spec render(template(), String.t()) :: String.t()
  def render(%{scheme: nil}, value), do: value
  def render(%{scheme: scheme}, value), do: scheme <> " " <> value

  @doc "Whether a value spells a reference this server does not resolve, with or without a scheme."
  @spec unresolved_ref?(term()) :: boolean()
  def unresolved_ref?(value), do: classify(value) == :unresolved

  defp scheme(""), do: nil
  defp scheme(scheme), do: scheme
end
