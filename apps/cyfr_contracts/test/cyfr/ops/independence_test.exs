# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.IndependenceTest do
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
    # No HTTP client: `Cyfr.Network` decides, and each app that speaks
    # HTTP issues the request with its own. The builder island carries
    # these contracts and would carry anything added here.
    refute deps =~ ":req"
  end

  test "operation modules compile without Sanctum or a running catalog" do
    root = Path.expand("../../../lib/cyfr/ops", __DIR__)
    files = Path.wildcard(Path.join(root, "**/*.ex"))
    assert files != []

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

    assert {:handle, 3} in Cyfr.Ops.Provider.behaviour_info(:callbacks)

    provider = File.read!(Path.join(root, "provider.ex"))
    assert provider =~ "ctx :: term()"
    refute provider =~ ~r/@callback handle.*Sanctum/s
  end
end
