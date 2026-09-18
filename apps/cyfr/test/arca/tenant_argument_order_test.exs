# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantArgumentOrderTest do
  @moduledoc """
  Where the tenant goes in a storage function's arguments.

  A bare `athanor_id` and the row key beside it are both non-empty strings.
  Nothing in the type system, in dialyzer, or in `where_athanor/2`'s guard
  can tell them apart — so a call that swaps them is not an error, it is a
  query against another athanor that returns that athanor's rows, or none,
  and looks like an ordinary miss either way.

  `Arca.ApiKeyStorage` had both spellings at once: `get_key(name,
  athanor_id)` next to `get_key_by_id(athanor_id, id)`, identical
  `(String.t(), String.t())` specs pointing opposite ways. `get_by_name/2`
  existed in two modules with the arguments reversed between them.

  The rule that removes the hazard is positional: the tenant comes first,
  always, in every tenant-scoped storage function. Then there is one shape
  to remember and a swap has to cross a type to happen. The tenant is a
  bare `athanor_id`, or one of the two structs that carry it: a
  `%Sanctum.Context{}`, or the `%Cyfr.Actor{}` a facade matches its
  athanor out of.
  """

  use ExUnit.Case, async: true

  @storage_glob "apps/cyfr/lib/arca/*.ex"

  # The rule is about functions the tenant SCOPES. These are the two shapes
  # where the athanor is something else:
  #
  #   * `where_athanor/2` and `where_tenant/2` compose onto a query — the
  #     query is the subject being piped and the tenant narrows it.
  #   * `update_athanor/2` writes the athanor as a VALUE onto a session
  #     found by its token hash. Swapping those looks up a session whose
  #     hash equals an athanor id, finds none, and says so; it cannot reach
  #     another tenant's row. The two are different types besides.
  @exempt %{
    "query_helpers.ex" => ~w(where_athanor where_tenant),
    "session_storage.ex" => ~w(update_athanor)
  }

  defp root, do: Path.expand("../../../..", __DIR__)

  defp offenders do
    root()
    |> Path.join(@storage_glob)
    |> Cyfr.Test.SourceTree.files!()
    |> Enum.flat_map(fn path ->
      offending(Path.basename(path), Cyfr.Test.SourceTree.read(path))
    end)
  end

  # The public heads of one file's source that name an athanor_id and do
  # not take the tenant first.
  defp offending(file, source) do
    exempt = Map.get(@exempt, file, [])

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.match?(line, ~r/^  def [a-z_]+[!?]?\(/) end)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, "athanor_id") end)
    |> Enum.reject(fn {line, _n} ->
      Enum.any?(exempt, &String.contains?(line, "def #{&1}("))
    end)
    # A `%Context{}`-first or `%Cyfr.Actor{}`-first function carries its
    # tenant inside the struct, which is the shape this rule is protecting
    # in the first place. First only: a struct further along leaves a
    # string ahead of it to be swapped.
    |> Enum.reject(fn {line, _n} ->
      String.match?(
        line,
        ~r/^  def [a-z_]+[!?]?\(\s*(%Context|%Sanctum\.Context|%Cyfr\.Actor|ctx)/
      )
    end)
    |> Enum.reject(fn {line, _n} ->
      String.match?(line, ~r/^  def [a-z_]+[!?]?\(athanor_id\b/)
    end)
    |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
  end

  test "every tenant-scoped storage function takes the athanor first" do
    found = offenders()

    assert found == [],
           """
           These storage functions take an athanor_id somewhere other than
           the first position:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           Both arguments are strings, so a swapped call compiles, passes
           dialyzer, satisfies where_athanor/2's guard, and quietly reads
           another athanor's rows. Put the tenant first — or take a
           %Sanctum.Context{} and let it carry the tenant.
           """
  end

  test "a struct carries the tenant only from the first position" do
    planted = """
    defmodule Arca.Planted do
      def by_actor(%Cyfr.Actor{athanor_id: athanor_id}, key), do: {athanor_id, key}
      def by_context(%Context{athanor_id: athanor_id}, key), do: {athanor_id, key}
      def by_id(athanor_id, key), do: {athanor_id, key}
      def actor_second(key, %Cyfr.Actor{athanor_id: athanor_id}), do: {athanor_id, key}
      def context_second(key, %Context{athanor_id: athanor_id}), do: {athanor_id, key}
      def id_second(key, athanor_id), do: {athanor_id, key}
      def actor_in_a_map(%{actor: %Cyfr.Actor{athanor_id: athanor_id}}), do: athanor_id
    end
    """

    assert offending("planted.ex", planted) == [
             "planted.ex:5: def actor_second(key, %Cyfr.Actor{athanor_id: athanor_id}), do: {athanor_id, key}",
             "planted.ex:6: def context_second(key, %Context{athanor_id: athanor_id}), do: {athanor_id, key}",
             "planted.ex:7: def id_second(key, athanor_id), do: {athanor_id, key}",
             "planted.ex:8: def actor_in_a_map(%{actor: %Cyfr.Actor{athanor_id: athanor_id}}), do: athanor_id"
           ]
  end

  test "the two modules that disagreed now agree" do
    api_key =
      Cyfr.Test.SourceTree.read(Path.join(root(), "apps/cyfr/lib/arca/api_key_storage.ex"))

    webhook =
      Cyfr.Test.SourceTree.read(Path.join(root(), "apps/cyfr/lib/arca/webhook_storage.ex"))

    vault = Cyfr.Test.SourceTree.read(Path.join(root(), "apps/cyfr/lib/arca/vault_storage.ex"))

    assert api_key =~ "def get_key(athanor_id, name)"
    assert api_key =~ "def get_key_by_id(athanor_id, id)"
    assert webhook =~ "def get_by_name(athanor_id, name)"
    assert vault =~ "def get_by_name(athanor_id, name)"
  end
end
