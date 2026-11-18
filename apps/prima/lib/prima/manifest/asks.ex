# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Asks do
  @max_entries 16
  @max_title 80

  @moduledoc """
  A catalyst manifest's `asks` block: the actions its developer says the
  component asks its person about before doing them.

      "asks": [
        {"name": "delete_table", "title": "delete a table"},
        {"name": "delete_rows", "title": "delete rows from a table"}
      ]

  Each entry is exactly a `name` and a `title`. The name is the action's
  stable name, `\\A[a-z][a-z0-9_]{0,63}\\z`, once in the list; an answer
  that stands is keyed by it across versions. The title completes
  "<component> wants to …": Unicode letters, decimal digits, spaces and
  hyphens, not blank, at most #{@max_title} code points, so it is one line
  that carries no second sentence, control character or format character.
  At most #{@max_entries} entries. The block is valid only on a manifest
  whose `type` is `"catalyst"`, even when it is empty.

  The list is the developer's claim: CYFR checks its shape and nothing
  else, neither that the component asks nor that an action fits what it
  does.
  """

  @name_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @title_pattern ~r/\A[\p{L}\p{Nd} -]+\z/u

  @typedoc "One declared action."
  @type declaration :: %{name: String.t(), title: String.t()}

  @doc """
  Holds a decoded manifest's `asks` block to its grammar. A manifest
  without the key passes. Answers the first refusal as
  `{:invalid_asks, sentence}`, the form `Prima.Manifest`'s other block
  checks answer.
  """
  @spec validate(map()) :: :ok | {:error, {:invalid_asks, String.t()}}
  def validate(%{"asks" => list, "type" => "catalyst"}) when is_list(list) do
    names = Enum.map(list, &entry_name/1)

    cond do
      length(list) > @max_entries ->
        refuse("asks declares at most #{@max_entries} actions")

      not Enum.all?(list, &entry?/1) ->
        refuse(list |> Enum.reject(&entry?/1) |> hd() |> entry_sentence())

      names != Enum.uniq(names) ->
        refuse("asks names #{inspect(hd(names -- Enum.uniq(names)))} more than once")

      true ->
        :ok
    end
  end

  def validate(%{"asks" => _other, "type" => "catalyst"}), do: refuse("asks must be a list")
  def validate(%{"asks" => _block}), do: refuse("asks is only valid on type catalyst")
  def validate(manifest) when is_map(manifest), do: :ok

  @doc """
  The actions a manifest declares, in its order, each `%{name, title}`.
  An absent block declares none, and so does one that does not validate:
  every stored manifest was validated at its write.
  """
  @spec from_manifest(term()) :: [declaration()]
  def from_manifest(%{"asks" => list} = manifest) do
    case validate(manifest) do
      :ok -> Enum.map(list, &%{name: &1["name"], title: &1["title"]})
      {:error, _refused} -> []
    end
  end

  def from_manifest(_manifest), do: []

  @doc """
  A declaration's digest: SHA-256, as lowercase hexadecimal, over its
  `name` then its `title`, each prefixed with its UTF-8 byte length as an
  unsigned 32-bit big-endian integer. A standing allow holds the digest of
  the declaration it was given under, so a reworded title no longer
  matches it.
  """
  @spec digest(declaration()) :: String.t()
  def digest(%{name: name, title: title}) when is_binary(name) and is_binary(title) do
    :sha256
    |> :crypto.hash([field(name), field(title)])
    |> Base.encode16(case: :lower)
  end

  defp field(text), do: [<<byte_size(text)::unsigned-big-32>>, text]

  defp entry?(%{"name" => name, "title" => title} = entry) when map_size(entry) == 2,
    do: name?(name) and title?(title)

  defp entry?(_entry), do: false

  defp entry_name(%{"name" => name}), do: name
  defp entry_name(_entry), do: nil

  defp name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)

  # Code points, not graphemes: the bound is the contract's count.
  defp title?(title) do
    is_binary(title) and String.valid?(title) and
      length(String.codepoints(title)) <= @max_title and
      Regex.match?(@title_pattern, title) and String.trim(title, " ") != ""
  end

  defp entry_sentence(%{"name" => name, "title" => _title} = entry) when map_size(entry) == 2 do
    if name?(name) do
      "asks.#{name}: a title is one line of letters, digits, spaces and hyphens, " <>
        "not blank, at most #{@max_title} characters"
    else
      "asks names are lowercase letters, digits and underscores, starting with a letter, " <>
        "at most 64 characters"
    end
  end

  defp entry_sentence(_entry), do: "each asks entry is an object of exactly name and title"

  defp refuse(sentence), do: {:error, {:invalid_asks, sentence}}
end
