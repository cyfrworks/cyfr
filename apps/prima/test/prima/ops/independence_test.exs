# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Ops.IndependenceTest do
  use ExUnit.Case, async: true

  test "the contracts package depends only on jason" do
    mix = File.read!(Path.expand("../../../mix.exs", __DIR__))
    deps = mix |> String.split("defp deps do", parts: 2) |> Enum.at(1)
    assert is_binary(deps)
    assert deps =~ ~s({:jason, "~> 1.4"})
    refute deps =~ ~r/\{:cyfr[,\s]/
    refute deps =~ ":sanctum"
    refute deps =~ ":locus"
    refute deps =~ ":opus"
    # The network contract takes resolved addresses; applications own DNS,
    # configuration and HTTP. Islands carry only the pure network policy.
    refute deps =~ ":req"
  end

  test "operation modules compile without Sanctum or a running catalog" do
    root = Path.expand("../../../lib/prima", __DIR__)
    # Named, not globbed: a file that moves or goes raises on its read
    # rather than leaving a partial match to pass.
    files = for name <- ~w(arg operation provider), do: Path.join(root, name <> ".ex")

    for file <- files do
      source =
        file
        |> File.read!()
        |> String.replace(~r/#.*$/m, "")
        |> String.replace(~r/@moduledoc\s+""".*?"""/s, "")
        |> String.replace(~r/@doc\s+""".*?"""/s, "")
        |> String.replace(~r/@typedoc\s+""".*?"""/s, "")

      refute source =~ ~r/\bSanctum\b/, "#{file} names Sanctum outside documentation"
      refute source =~ ~r/\bCyfr\.Ops\.Catalog\b/, "#{file} reaches the catalog"
    end

    assert {:handle, 3} in Prima.Provider.behaviour_info(:callbacks)

    provider = File.read!(Path.join(root, "provider.ex"))
    assert provider =~ "ctx :: term()"
    refute provider =~ ~r/@callback handle.*Sanctum/s
  end
end
