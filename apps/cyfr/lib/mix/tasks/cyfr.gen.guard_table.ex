# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Gen.GuardTable do
  @shortdoc "Write the island egress guard's address table from Prima.Cidr"

  @moduledoc """
  Writes `Prima.Cidr.address_table/0` into the island egress guard,
  `apps/locus/keeper/guard/cyfr-guard.sh`, between its `# BEGIN address
  table` and `# END address table` lines: the metadata rows and the private
  rows of each family, a private row that is also a metadata row left to
  the metadata rule the guard installs first.

      mix cyfr.gen.guard_table
      mix cyfr.gen.guard_table --check

  `--check` fails when the guard does not hold the table;
  `apps/cyfr/test/cyfr/guard_table_test.exs` fails on it as well.
  """

  use Boundary, classify_to: Cyfr

  use Mix.Task

  @target "apps/locus/keeper/guard/cyfr-guard.sh"
  @begin "# BEGIN address table"
  @end_marker "# END address table"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    path = path()
    # arca:bypass-ok=E — the guard is a tracked file of the repository.
    current = File.read!(path)
    spliced = splice(current)

    case args do
      ["--check"] ->
        if current == spliced do
          Mix.shell().info("#{@target} holds the address table")
        else
          Mix.raise(
            "#{@target} does not hold Prima.Cidr's address table — run `mix cyfr.gen.guard_table`"
          )
        end

      [] ->
        # arca:bypass-ok=E
        File.write!(path, spliced)
        Mix.shell().info("wrote the address table into #{@target}")

      _other ->
        Mix.raise("usage: mix cyfr.gen.guard_table [--check]")
    end
  end

  @doc "The guard's absolute path."
  @spec path() :: Path.t()
  def path, do: Path.join(root(), @target)

  @doc "The rows the guard installs, by its variable's name."
  @spec rows() :: [{String.t(), [String.t()]}]
  def rows do
    %{metadata: metadata, private: private} = Prima.Cidr.address_table()
    private = private -- metadata

    [
      {"METADATA_V4", ipv4(metadata)},
      {"METADATA_V6", ipv6(metadata)},
      {"PRIVATE_V4", ipv4(private)},
      {"PRIVATE_V6", ipv6(private)}
    ]
  end

  @doc "The block between the markers, the markers included."
  @spec block() :: String.t()
  def block do
    variables =
      Enum.map_join(rows(), "", fn {name, rows} ->
        "#{name}='\n" <> Enum.map_join(rows, "", &(&1 <> "\n")) <> "'\n"
      end)

    """
    #{@begin}: written by `mix cyfr.gen.guard_table` from
    # Prima.Cidr.address_table/0. Edit the table there and run the task; the
    # suite fails on a copy that differs.
    #{variables}#{@end_marker}
    """
  end

  @doc "`script` with the block between its markers replaced by `block/0`."
  @spec splice(String.t()) :: String.t()
  def splice(script) do
    case Regex.split(~r/^#{Regex.escape(@begin)}.*?^#{Regex.escape(@end_marker)}\n/ms, script,
           parts: 2
         ) do
      [before, rest] -> before <> block() <> rest
      [_none] -> raise ArgumentError, "#{@target} has no #{@begin} … #{@end_marker} lines"
    end
  end

  defp ipv4(rows), do: Enum.reject(rows, &String.contains?(&1, ":"))
  defp ipv6(rows), do: Enum.filter(rows, &String.contains?(&1, ":"))

  defp root, do: Path.expand("../../../../..", __DIR__)
end
