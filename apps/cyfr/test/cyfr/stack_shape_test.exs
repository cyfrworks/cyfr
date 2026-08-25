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

    # Only the keys under `services:` — the file also has `volumes:` and
    # `networks:` blocks with the same indentation.
    [_, services_block | _] = Regex.split(~r/^services:\s*$/m, compose)
    [services_block | _] = Regex.split(~r/^[a-z]/m, services_block)

    services =
      Regex.scan(~r/^  ([a-z][a-z0-9_-]*):\s*$/m, services_block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    assert services == ["caddy", "cyfr", "mcp-bridge"]
    refute compose =~ ~r/porta|4001|8080/

    # One runtime root: the old components bind mount must not come back.
    refute compose =~ ~r/^\s*- \.\/components:/m
  end

  test "the image carries the seed tree and reads it in place" do
    # A bare image boot (no host bind mount) must still be able to provision
    # Home: the bundle rides in the image inside the seed tree and the
    # release reads it there directly (CYFR_SEED_PATH) — no first-boot copy.
    dockerfile = read!("Dockerfile")
    entrypoint = read!("docker-entrypoint.sh")
    dockerignore = read!(".dockerignore")

    assert dockerfile =~ ~r/^COPY seed\/components\/ \/app\/seed\/components\/$/m
    assert dockerfile =~ ~r/^ENV CYFR_SEED_PATH=\/app\/seed$/m
    refute entrypoint =~ ~r/seed\/components/

    # The bundle source ships in the build context; the old components/*
    # allowlist pair is gone for good.
    refute dockerignore =~ ~r/^components\/\*$/m
    refute dockerignore =~ ~r/^!components\/_bundle\/$/m
    assert dockerignore =~ ~r/^data\/$/m
  end

  test "the AQUA template is the second seed root, and WIT is embedded" do
    dockerfile = read!("Dockerfile")
    entrypoint = read!("docker-entrypoint.sh")
    compose = read!("docker-compose.yml")

    # The template lives inside the seed tree at the operator-editable
    # mount, seeded from the baked defaults on first boot.
    assert compose =~ ~r/^\s*- \.\/aqua:\/app\/seed\/aqua$/m
    assert dockerfile =~ ~r/^COPY seed\/aqua\/ \/app\/aqua-defaults\/$/m
    assert entrypoint =~ "cp -r /app/aqua-defaults/. /app/seed/aqua/"

    # WIT rides in the BUILD context (Compendium.WITSource embeds it — an
    # absent tree fails the compile), and the runtime image no longer
    # carries a wit/ directory to read.
    stages = String.split(dockerfile, ~r/^FROM /m)
    builder = Enum.find(stages, &String.contains?(&1, "AS builder"))
    runner = Enum.find(stages, &String.contains?(&1, "AS runner"))

    assert builder =~ ~r/^COPY wit\/ wit\/$/m
    refute runner =~ ~r/^COPY wit\/ wit\/$/m
  end

  test "the env template names no retired knobs" do
    env = read!(".env.example")
    # Spelled with the underscore split so the vocabulary gate itself does
    # not trip on this file.
    refute env =~ ~r/CYFR_PORT[A]_BIND|CYFR_PRIS[M]_|CYFR_COMPONENT[S]_PATH|4001/
  end
end
