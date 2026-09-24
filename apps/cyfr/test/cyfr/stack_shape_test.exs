# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StackShapeTest do
  @moduledoc """
  The shipped stack is one origin: every request Caddy takes reaches cyfr's
  one endpoint, and compose runs cyfr, the execution worker, the bridge and
  (optionally) caddy and the builds service — nothing else. Read the files,
  assert the shape; the same style as the ingress inventory.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  # One service's block of docker-compose.yml, and the entries of one of
  # its list keys.
  defp service_block(compose, name) do
    [_, services | _] = Regex.split(~r/^services:\s*$/m, compose)
    [services | _] = Regex.split(~r/^[a-z]/m, services)
    [_, block | _] = Regex.split(~r/^  #{Regex.escape(name)}:\s*$/m, services)
    [block | _] = Regex.split(~r/^  [a-z]/m, block)
    block
  end

  defp list_entries(block, key) do
    [_, list | _] = Regex.split(~r/^    #{key}:\s*$/m, block)
    [list | _] = Regex.split(~r/^    [a-z]/m, list)
    Regex.scan(~r/^      - (\S+)/m, list, capture: :all_but_first) |> List.flatten()
  end

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

    assert services == ["caddy", "cyfr", "locus-builds", "mcp-bridge", "opus"]
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

    assert cyfr_block =~
             ~r/^\s*- CYFR_OPUS_WORKERS=\$\{CYFR_OPUS_WORKERS:-wrk_opus=http:\/\/opus:4200\}$/m

    assert cyfr_block =~ ~r/^\s*- CYFR_HOST_API_BIND=0\.0\.0\.0$/m
    assert cyfr_block =~ ~r/^\s*- worker$/m

    assert cyfr_block =~ ~r/^\s*- locus-builds$/m

    # The builds service is attached to its own network and no other: what
    # it listens on is that network, which is its isolation.
    assert list_entries(service_block(compose, "locus-builds"), "networks") == ["locus-builds"]

    # Runtime storage uses one data root.
    refute compose =~ ~r/^\s*- \.\/components:/m
  end

  # cyfr reaches the builder over the builds network, which only the two of
  # them join, and a build reaches crates.io and the npm registry over the
  # same network: it is not `internal`, so the isolation is who is attached.
  # The worker network is the same shape for a guest's consented egress.
  test "the builds and worker networks carry cyfr to its worker and the worker out" do
    compose = read!("docker-compose.yml")
    [_, networks] = Regex.split(~r/^networks:\s*$/m, compose)
    [networks | _] = Regex.split(~r/^[a-z]/m, networks)

    for network <- ["locus-builds", "worker"] do
      assert networks =~ ~r/^  #{network}: \{\}$/m, "#{network} must be declared plain"

      attached =
        for service <- ["caddy", "cyfr", "locus-builds", "mcp-bridge", "opus"],
            block = service_block(compose, service),
            block =~ ~r/^    networks:\s*$/m,
            network in list_entries(block, "networks"),
            do: service

      expected = if network == "worker", do: ["cyfr", "opus"], else: ["cyfr", "locus-builds"]
      assert attached == expected, "#{network} joins #{inspect(attached)}"
    end

    refute networks =~ ~r/internal:\s*true/
  end

  test "the builds service is the locus image under the shipped names, holding only its own settings" do
    compose = read!("docker-compose.yml")
    builds = service_block(compose, "locus-builds")

    assert builds =~ ~r/^    container_name: cyfr-locus-builds$/m
    assert builds =~ ~r/^    image: ghcr\.io\/cyfrworks\/cyfr-locus:latest$/m
    assert builds =~ ~r/^      dockerfile: Dockerfile\.locus$/m
    assert builds =~ ~r/^    profiles: \["locus-builds"\]$/m
    assert builds =~ ~r/^      - path: \.env\.locus$/m
    assert File.regular?(Path.join(@root, "Dockerfile.locus"))

    # `Locus.Config` refuses the control plane's variables, so the service
    # is handed `LOCUS_BUILDS_*` names and nothing else; its key is the one
    # cyfr reads as CYFR_LOCUS_BUILDS_KEY.
    assert list_entries(builds, "environment") == ["LOCUS_BUILDS_KEY=${CYFR_LOCUS_BUILDS_KEY:-}"]

    # The container's limit is a setting, since it holds the concurrent
    # builds' bounds, which are settings too.
    assert builds =~ ~r/^          memory: \$\{LOCUS_BUILDS_MEMORY_LIMIT:-[0-9]+[MG]\}$/m
    assert builds =~ ~r/^          cpus: "\$\{LOCUS_BUILDS_CPU_LIMIT:-[0-9]+\}"$/m

    # Spelled split so the retired names are not themselves found here. The
    # release's user and its directories keep the name cyfr-builder.
    refute compose =~
             ~r/CYFR_BUILDE[R]_|CYFR_BUIL[D]_|CYFR_MAX_CONCURRENT_BUILD[S]|Dockerfile\.builde[r]|cyfrworks\/cyfr-builde[r]/

    refute compose =~ ~r/\.env\.builde[r]/
  end

  test "the builds service and the worker keep their hardening, and can bound a spawn's memory" do
    compose = read!("docker-compose.yml")

    for {service, homes, run_dir} <- [
          {"locus-builds", "/var/lib/cyfr-builder/homes:mode=1733,exec,size=2g",
           "/run/cyfr-builder:uid=10001,gid=10001,mode=0700,size=16m"},
          {"opus", "/var/lib/opus/homes:mode=1733,exec,size=256m",
           "/run/opus:uid=10002,gid=10002,mode=0700,size=16m"}
        ] do
      block = service_block(compose, service)

      assert list_entries(block, "cap_drop") == ["ALL"], service
      assert list_entries(block, "cap_add") == ["SETUID", "SETGID", "KILL"], service

      # cyfr-keeper bounds a spawn's memory only where the container's
      # cgroup is mounted writable; without the option every bounded spawn
      # is refused, so the shipped services carry it.
      assert list_entries(block, "security_opt") == [
               "no-new-privileges:true",
               "writable-cgroups=true"
             ],
             service

      assert list_entries(block, "tmpfs") == [homes, run_dir], service
      assert block =~ ~r/^    read_only: true$/m, service
      assert block =~ ~r/^    ipc: none$/m, service
      assert block =~ ~r/^    init: true$/m, service
      refute block =~ ~r/^    (privileged|pid|userns_mode|cgroup|devices|volumes):/m, service
      assert block =~ ~r/^          memory: \S+$/m, service
    end
  end

  test "the builds service's example names every setting of the locus release, and none of the control plane's" do
    example = read!(".env.locus.example")

    # The release's settings are the rows of `Locus.Config`'s table.
    knobs =
      Regex.scan(~r/^  \| `(LOCUS_BUILDS_[A-Z_]+)` \|/m, read!("apps/locus/lib/locus/config.ex"),
        capture: :all_but_first
      )
      |> List.flatten()

    assert "LOCUS_BUILDS_KEY" in knobs and "LOCUS_BUILDS_MEMORY_BYTES" in knobs

    for knob <- knobs -- ["LOCUS_BUILDS_KEY"] do
      assert example =~ ~r/^# #{knob}=/m, "#{knob} is missing from .env.locus.example"
    end

    # The key reaches the service from the project .env through compose,
    # and the container's limits are compose's to read there: neither is
    # set in this file, and the example says where each is.
    assert example =~ "CYFR_LOCUS_BUILDS_KEY"
    assert example =~ "LOCUS_BUILDS_MEMORY_LIMIT"

    refute example =~
             ~r/^#? ?(LOCUS_BUILDS_KEY|LOCUS_BUILDS_MEMORY_LIMIT|LOCUS_BUILDS_CPU_LIMIT)=/m

    # No setting of the control plane's is offered here: `Locus.Config`
    # refuses to start with the keyring, the database, the worker root or
    # the bridge key in its environment.
    refute example =~ ~r/^#? ?CYFR_[A-Z_]*=/m
    refute File.exists?(Path.join(@root, ".env.builder.example"))
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

    # Prima.WIT embeds the WIT tree at build time; runtime images need no wit directory.
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
    refute env =~
             ~r/CYFR_PORT[A]_BIND|CYFR_PRIS[M]_|CYFR_COMPONENT[S]_PATH|4001|CYFR_WORKE[R]_|CYFR_WORKER[S]\b|CYFR_EXECUTIO[N]_EVENTS_|CYFR_MAX_CONCURRENT_EXECUTION[S]|CYFR_SPAWN_CHANNE[L]/

    for knob <-
          ~w(CYFR_OPUS_KEY OPUS_SERVICE_ID OPUS_SERVICE_KEY OPUS_HOST_URL CYFR_OPUS_WORKERS CYFR_HOST_API_BIND CYFR_HOST_API_PORT) do
      assert env =~ ~r/^#? ?#{knob}=/m, "#{knob} is missing from .env.example"
    end

    # Compose sets five variables in the opus service's environment, over
    # anything .env.opus sets: the three it interpolates from the project
    # .env are documented in .env.example above, and the two it fixes in
    # integration-guide.md's section on running a worker outside Compose.
    # .env.opus.example documents none of them, and says where they are.
    environment = list_entries(service_block(read!("docker-compose.yml"), "opus"), "environment")

    assert environment == [
             "OPUS_SERVICE_ID=${OPUS_SERVICE_ID:-wrk_opus}",
             "OPUS_SERVICE_KEY=${OPUS_SERVICE_KEY:-}",
             "OPUS_HOST_URL=${OPUS_HOST_URL:-http://cyfr:${CYFR_HOST_API_PORT:-4300}}",
             "OPUS_BIND=0.0.0.0",
             "OPUS_PORT=4200"
           ]

    set = for entry <- environment, do: entry |> String.split("=", parts: 2) |> hd()
    opus = read!(".env.opus.example")

    for knob <- set do
      refute opus =~ ~r/^#? ?#{knob}=/m, "#{knob} is documented in .env.opus.example"
    end

    assert opus =~ "project .env"

    guide = read!("integration-guide.md")
    assert guide =~ ~r/^\| `OPUS_BIND` \|/m and guide =~ ~r/^\| `OPUS_PORT` \|/m

    refute opus =~ ~r/CYFR_OPUS_KEY|CYFR_DATABASE_UR[L]|CYFR_CRYPTO_KEYRIN[G]=/
  end
end
