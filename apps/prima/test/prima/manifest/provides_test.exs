# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.ProvidesTest do
  @moduledoc """
  A manifest's `provides` block: a publisher's public configuration for a
  need of a dependency it declares, a destination and string values of at
  most 4 KiB. A dependency the manifest does not declare, values past the
  bound or of another type, and an entry of any other shape are refused.
  """

  use ExUnit.Case, async: true

  alias Prima.Destination
  alias Prima.Manifest.Provides

  @dependency "catalyst:local.supabase"

  defp manifest(provides, static \\ [@dependency]) do
    %{"dependencies" => %{"static" => static}, "provides" => provides}
  end

  defp entry(extra \\ %{}) do
    Map.merge(
      %{
        "destination" => %{"hosts" => ["abc.supabase.co"], "paths" => ["/rest/v1"]},
        "values" => %{"anon_key" => "eyJ-public", "url" => "https://abc.supabase.co"}
      },
      extra
    )
  end

  defp refused(manifest) do
    assert {:error, {:invalid_provides, reason}} = Provides.validate(manifest)
    reason
  end

  test "reads a declared dependency's needs to their destinations and values" do
    m = manifest(%{@dependency => %{"database" => entry()}})
    assert Provides.validate(m) == :ok

    assert %{@dependency => %{"database" => %{destination: %Destination{} = d, values: values}}} =
             Provides.from_manifest(m)

    assert d.hosts == ["abc.supabase.co"] and d.paths == ["/rest/v1"]
    assert values == %{"anon_key" => "eyJ-public", "url" => "https://abc.supabase.co"}
  end

  test "a dependency named as an object in dependencies.static is declared too" do
    m = manifest(%{@dependency => %{"database" => entry()}}, [%{"ref" => @dependency}])
    assert Provides.validate(m) == :ok
  end

  test "absent, the block declares nothing" do
    assert Provides.validate(%{}) == :ok
    assert Provides.validate(nil) == :ok
    assert Provides.from_manifest(%{}) == nil
  end

  test "a dependency the manifest lacks is refused" do
    assert refused(manifest(%{"catalyst:local.other" => %{"database" => entry()}})) ==
             {:undeclared_dependency, "catalyst:local.other"}

    assert refused(manifest(%{@dependency => %{"database" => entry()}}, [])) ==
             {:undeclared_dependency, @dependency}

    assert Provides.from_manifest(manifest(%{@dependency => %{"database" => entry()}}, [])) ==
             nil
  end

  test "values over 4 KiB in total are refused, and 4 KiB exactly is not" do
    bound = Provides.max_values_bytes()
    assert bound == 4096

    at_bound = %{"k" => String.duplicate("v", bound - 1)}

    assert :ok =
             Provides.validate(
               manifest(%{@dependency => %{"db" => entry(%{"values" => at_bound})}})
             )

    # Names count with their values.
    over = %{"k" => String.duplicate("v", bound - 1), "j" => ""}

    assert {:invalid_entry, @dependency, "db", :values_too_large} =
             refused(manifest(%{@dependency => %{"db" => entry(%{"values" => over})}}))
  end

  test "values that are not string names to strings are refused" do
    for values <- [%{"k" => 1}, %{"" => "v"}, ["v"], %{"k" => nil}, "v"] do
      assert {:invalid_entry, @dependency, "db", :values_not_strings} =
               refused(manifest(%{@dependency => %{"db" => entry(%{"values" => values})}})),
             inspect(values)
    end
  end

  test "an entry's destination is held to the destination grammar" do
    bad = entry(%{"destination" => %{"hosts" => ["*"]}})

    assert {:invalid_entry, @dependency, "db", {:invalid_destination, {:invalid_host, "*"}}} =
             refused(manifest(%{@dependency => %{"db" => bad}}))
  end

  test "an entry of another shape, a need name outside the grammar and an empty dependency" do
    assert {:invalid_entry, @dependency, "db", {:unknown_keys, ["attach"]}} =
             refused(manifest(%{@dependency => %{"db" => entry(%{"attach" => %{}})}}))

    assert {:invalid_entry, @dependency, "db", :destination_and_values_required} =
             refused(manifest(%{@dependency => %{"db" => Map.delete(entry(), "values")}}))

    assert {:invalid_need, @dependency, "Database"} =
             refused(manifest(%{@dependency => %{"Database" => entry()}}))

    assert {:no_needs, @dependency} = refused(manifest(%{@dependency => %{}}))
    assert {:not_a_map, []} = refused(%{"provides" => []})
  end
end
