# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StackShapeTest do
  @moduledoc """
  The shipped stack is one origin: every request Caddy takes reaches cyfr's
  one endpoint, and compose runs cyfr, the execution worker, the bridge and
  (optionally) caddy and the builder — nothing else. Read the files, assert
  the shape; the same style as the ingress inventory.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  test "the Caddyfile proxies everything to cyfr's one (parameterized) port" do
    caddy = read!("Caddyfile")

    proxies = Regex.scan(~r/^\s*reverse_proxy\s+(\S+)/m, caddy, capture: :all_but_first)

    assert proxies == [["cyfr:{$CYFR_PORT:4000}"]],
           "expected exactly one reverse_proxy to cyfr:{$CYFR_PORT:4000}"

    opens = caddy |> String.graphemes() |> Enum.count(&(&1 == "{"))
    closes = caddy |> String.graphemes() |> Enum.count(&(&1 == "}"))
    assert opens == closes, "unbalanced braces in Caddyfile (#{opens} vs #{closes})"

    refute caddy =~ ~r/porta|4001/
  end

  test "compose runs cyfr, opus, mcp-bridge and caddy — one web origin" do
    compose = read!("docker-compose.yml")

    # Only the keys under `services:` — the file also has `volumes:` and
    # `networks:` blocks with the same indentation.
    [_, services_block | _] = Regex.split(~r/^services:\s*$/m, compose)
    [services_block | _] = Regex.split(~r/^[a-z]/m, services_block)

    services =
      Regex.scan(~r/^  ([a-z][a-z0-9_-]*):\s*$/m, services_block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    assert services == ["builder", "caddy", "cyfr", "mcp-bridge", "opus"]
    refute compose =~ ~r/porta|4001|8080/

    # The execution worker is attached to the worker network and no other,
    # which cyfr joins: cyfr reaches it there, it reaches cyfr's host API
    # there, and the bridge and caddy never see either port.
    [_, opus_block | _] = Regex.split(~r/^  opus:\s*$/m, services_block)
    [opus_block | _] = Regex.split(~r/^  [a-z]/m, opus_block)
    [_, opus_networks | _] = Regex.split(~r/^    networks:\s*$/m, opus_block)
    [opus_networks | _] = Regex.split(~r/^    [a-z]/m, opus_networks)
    assert Regex.scan(~r/^      - (\S+)/m, opus_networks, capture: :all_but_first) == [["worker"]]
    assert opus_block =~ ~r/^\s*- OPUS_SERVICE_KEY=\$\{OPUS_SERVICE_KEY:-\}$/m
    assert opus_block =~ ~r/^\s*- OPUS_HOST_URL=\$\{OPUS_HOST_URL:-http:\/\/cyfr:/m

    [_, cyfr_block | _] = Regex.split(~r/^  cyfr:\s*$/m, services_block)
    [cyfr_block | _] = Regex.split(~r/^  [a-z]/m, cyfr_block)
    assert cyfr_block =~ ~r/^\s*- CYFR_WORKERS=\$\{CYFR_WORKERS:-wrk_opus=http:\/\/opus:4200\}$/m
    assert cyfr_block =~ ~r/^\s*- CYFR_HOST_API_BIND=0\.0\.0\.0$/m
    assert cyfr_block =~ ~r/^\s*- worker$/m

    # The builder is attached to its own network and no other: what it
    # listens on is that network, which is its isolation.
    [_, builder_block | _] = Regex.split(~r/^  builder:\s*$/m, services_block)
    [builder_block | _] = Regex.split(~r/^  [a-z]/m, builder_block)
    [_, networks | _] = Regex.split(~r/^    networks:\s*$/m, builder_block)
    [networks | _] = Regex.split(~r/^    [a-z]/m, networks)
    assert Regex.scan(~r/^      - (\S+)/m, networks, capture: :all_but_first) == [["builder"]]

    # Runtime storage uses one data root.
    refute compose =~ ~r/^\s*- \.\/components:/m
  end

  test "the port is a parameter everywhere, 4000 only as its default" do
    # CYFR_PORT=8000 must work by setting one variable. A bare 4000
    # outside a default-expansion is a site the variable does not reach —
    # exactly the drift this test exists to refuse.
    for file <- ["docker-compose.yml", "Caddyfile", "Dockerfile"] do
      stripped =
        file
        |> read!()
        |> String.split("\n")
        |> Enum.map(&String.replace(&1, ~r/(^|\s)#.*$/, ""))
        |> Enum.join("\n")

      bare =
        ~r/(?<!:-)(?<!=)(?<!:)4000/
        |> Regex.scan(stripped)
        |> List.flatten()

      assert bare == [], "bare 4000 outside a default-expansion in #{file}"
    end
  end

  test "the image carries the seed tree and the release reads it there" do
    # A bare image boot (no host bind mount) must still be able to provision
    # an athanor from its seed: the bundle rides in the image inside the seed
    # tree (CYFR_SEED_PATH), each athanor's copy is taken from it at
    # provisioning, and the entrypoint copies nothing into the volume.
    dockerfile = read!("Dockerfile")
    entrypoint = read!("docker-entrypoint.sh")
    dockerignore = read!(".dockerignore")

    assert dockerfile =~ ~r/^COPY seed\/components\/ \/app\/seed\/components\/$/m
    assert dockerfile =~ ~r/^ENV CYFR_SEED_PATH=\/app\/seed$/m
    refute entrypoint =~ ~r/seed\/components/

    # Include seed source in the build context.
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

    # Seed only when the shipped soul file is absent; later boots must preserve operator edits.
    soul = Compendium.AquaPath.soul_file() |> Enum.drop(1) |> Enum.join("/")
    roles = Compendium.AquaPath.roles_dirname()

    code =
      entrypoint
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")

    assert code =~ "[ ! -f /app/seed/aqua/#{soul} ]"
    refute code =~ "agent.json"
    assert File.regular?(Path.join(@root, "seed/aqua/#{soul}"))
    assert File.dir?(Path.join(@root, "seed/aqua/#{roles}"))

    # WITSource embeds the WIT tree at build time; runtime images need no wit directory.
    stages = String.split(dockerfile, ~r/^FROM /m)
    builder = Enum.find(stages, &String.contains?(&1, "AS builder"))
    runner = Enum.find(stages, &String.contains?(&1, "AS runner"))

    assert builder =~ ~r/^COPY wit\/ wit\/$/m
    refute runner =~ ~r/^COPY wit\/ wit\/$/m
  end

  test "the env template names no retired knobs, and every worker knob" do
    env = read!(".env.example")
    # Spelled with the underscore split so the vocabulary gate itself does
    # not trip on this file.
    refute env =~ ~r/CYFR_PORT[A]_BIND|CYFR_PRIS[M]_|CYFR_COMPONENT[S]_PATH|4001|CYFR_WORKER_I[D]/

    for knob <-
          ~w(CYFR_WORKER_KEY OPUS_SERVICE_KEY CYFR_WORKERS CYFR_HOST_API_BIND CYFR_HOST_API_PORT) do
      assert env =~ ~r/^#? ?#{knob}=/m, "#{knob} is missing from .env.example"
    end

    opus = read!(".env.opus.example")

    for knob <- ~w(OPUS_SERVICE_ID OPUS_SERVICE_KEY OPUS_HOST_URL OPUS_BIND OPUS_PORT) do
      assert opus =~ ~r/^#? ?#{knob}=/m, "#{knob} is missing from .env.opus.example"
    end

    refute opus =~ ~r/CYFR_WORKER_KE[Y]|CYFR_DATABASE_UR[L]|CYFR_CRYPTO_KEYRIN[G]=/
  end
end
