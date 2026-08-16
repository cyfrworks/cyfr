# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StackShapeTest do
  @moduledoc """
  The shipped stack is one origin: every request Caddy takes reaches cyfr's
  one endpoint, and compose runs cyfr, the bridge and (optionally) caddy —
  nothing else. Read the files, assert the shape; the same style as the
  ingress inventory.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  test "the Caddyfile proxies everything to cyfr:4000 and is well-formed" do
    caddy = read!("Caddyfile")

    proxies = Regex.scan(~r/^\s*reverse_proxy\s+(\S+)/m, caddy, capture: :all_but_first)
    assert proxies == [["cyfr:4000"]], "expected exactly one reverse_proxy to cyfr:4000"

    opens = caddy |> String.graphemes() |> Enum.count(&(&1 == "{"))
    closes = caddy |> String.graphemes() |> Enum.count(&(&1 == "}"))
    assert opens == closes, "unbalanced braces in Caddyfile (#{opens} vs #{closes})"

    refute caddy =~ ~r/porta|4001/
  end

  test "compose runs cyfr, mcp-bridge and caddy — one web origin" do
    compose = read!("docker-compose.yml")

    services =
      Regex.scan(~r/^  ([a-z][a-z0-9-]*):\s*$/m, compose, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    assert services == ["caddy", "cyfr", "mcp-bridge"]
    refute compose =~ ~r/porta|4001|8080/
  end

  test "the env template names no retired knobs" do
    env = read!(".env.example")
    # Spelled with the underscore split so the vocabulary gate itself does
    # not trip on this file.
    refute env =~ ~r/CYFR_PORT[A]_BIND|CYFR_PRIS[M]_|4001/
  end
end
