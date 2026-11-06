# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Vocabulary do
  @moduledoc """
  The vocabulary rule every page test holds its page's text to:
  `refute_vocabulary/1` refutes, in a page's visible text, every word the
  rule keeps from a person.
  """

  import ExUnit.Assertions

  # The words, with their plurals and forms, no page a person reads says.
  @vocabulary ~r/\b(handles?|enroll\w*|director(?:y|ies)|registr(?:y|ies)|kits?|homes?|hubs?|cells?|nodes?|doors?|glass(?:es)?)\b/i

  @doc """
  `html`'s visible text holds none of the vocabulary rule's words: handle,
  enroll, directory, registry, kit, home, hub, cell, node, door or glass,
  whole words in any case, with their plurals and forms.
  """
  def refute_vocabulary(html) when is_binary(html) do
    text = html |> LazyHTML.from_fragment() |> LazyHTML.to_tree() |> visible()
    found = @vocabulary |> Regex.scan(text) |> Enum.map(&hd/1) |> Enum.uniq()
    assert found == [], "the page says #{inspect(found)}:\n#{text}"
  end

  defp visible(nodes) when is_list(nodes), do: Enum.map_join(nodes, " ", &visible/1)
  defp visible({tag, _attrs, _children}) when tag in ~w(script style template), do: ""
  defp visible({_tag, _attrs, children}), do: visible(children)
  defp visible(text) when is_binary(text), do: text
  defp visible(_comment), do: ""
end
