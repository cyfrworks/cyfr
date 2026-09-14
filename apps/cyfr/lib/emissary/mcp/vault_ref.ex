# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.VaultRef do
  @moduledoc """
  Constructs and classifies vault references in header templates.

  A template is `vault:<entry>` or `<scheme> vault:<entry>` — `Bearer
  vault:gh-token` — and resolves to the entry's one value, after the scheme
  and a space when there is one. `vault:` is the one reference scheme a
  header resolves; a value naming `secret:`, a scheme this server does not
  resolve, is refused wherever a header is written or resolved, never sent
  as a literal. Every reader of templates — the resolver, the validator, the
  reconciler and the listings — goes through `template/1`.
  """

  @prefix "vault:"
  @unresolved ["secret:"]
  # An HTTP authentication scheme is an RFC 9110 token.
  @template ~r/\A(?:([!#$%&'*+.^_`|~0-9A-Za-z-]+) )?vault:(.+)\z/s

  @typedoc "A parsed template: the scheme before the reference, if any, and the entry named."
  @type template :: %{scheme: String.t() | nil, name: String.t()}

  @doc "The reference prefix."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "Build the reference for a vault entry name (or id)."
  @spec build(String.t()) :: String.t()
  def build(name) when is_binary(name), do: @prefix <> name

  @doc "The template a header value spells, or `:error` for a literal."
  @spec template(term()) :: {:ok, template()} | :error
  def template(value) when is_binary(value) do
    case Regex.run(@template, value, capture: :all_but_first) do
      [scheme, name] -> {:ok, %{scheme: if(scheme == "", do: nil, else: scheme), name: name}}
      _ -> :error
    end
  end

  def template(_value), do: :error

  @doc "Whether a header value is a vault reference, with or without a scheme."
  @spec vault_ref?(term()) :: boolean()
  def vault_ref?(value), do: match?({:ok, _}, template(value))

  @doc "The entry names a header map's templates reference, sorted and unique."
  @spec names(map()) :: [String.t()]
  def names(headers) when is_map(headers) do
    for {_header, value} <- headers, {:ok, %{name: name}} <- [template(value)], uniq: true do
      name
    end
    |> Enum.sort()
  end

  @doc "The header value a template resolves to, given its entry's value."
  @spec render(template(), String.t()) :: String.t()
  def render(%{scheme: nil}, value), do: value
  def render(%{scheme: scheme}, value), do: scheme <> " " <> value

  @doc "Whether a header value names a reference scheme this server does not resolve."
  @spec unresolved_ref?(term()) :: boolean()
  def unresolved_ref?(value), do: is_binary(value) and String.starts_with?(value, @unresolved)
end
