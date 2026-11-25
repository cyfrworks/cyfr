# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StackShapeTest do
  @moduledoc """
  The shipped stack is one origin: every request Caddy or Tailscale Serve
  takes reaches cyfr's one endpoint, on its proxy listener, and compose
  runs cyfr, the one Locus behind its egress guard, and (optionally) caddy
  and tailscale — nothing else. cyfr's loopback listener sits on the
  `default` network, which carries cyfr alone and which Docker publishes
  on the host's loopback alone; its proxy listener sits on `edge` with the
  two proxies, at the role table's addresses. Read the files, assert the
  shape; the same style as the ingress inventory.

  docker-compose.yml is parsed whole (`services/1`), and so is each image
  suite's overlay (`overlay/1`), which `role_drift/3` holds to the one
  mapping written here (`expected_overlays/2`).

  Every fact of a Locus role is the role table's (`Prima.LocusRoles`): a
  test here reads the table where it would spell one, and `role_drift/3`
  holds every other spelling to it, wherever it is — Dockerfile.locus's
  users, directories and entrypoint, the image's health probe
  (apps/locus/health.sh), compose's Locus service and guard, the image
  suites' overlays, Locus's own pool names, attach directory and listener
  ports, and the image suites, whose harnesses read the table's vector
  file.
  """
  use ExUnit.Case, async: true

  alias Prima.LocusRoles

  @root Path.expand("../../../..", __DIR__)

  # The hardening the Locus service runs under, beside its tmpfs mounts
  # and volumes, which are the table's (`tmpfs/1`, `locus_volumes/1`).
  @hardening %{
    "init" => true,
    "cap_drop" => ["ALL"],
    "cap_add" => ["SETUID", "SETGID", "KILL"],
    "read_only" => true,
    "ipc" => "none",
    "restart" => "unless-stopped",
    "logging" => %{
      "driver" => "json-file",
      "options" => %{"max-size" => "10m", "max-file" => "3"}
    }
  }

  # Locus runs under the keeper's seccomp profile and, on a host with
  # AppArmor, the profile .env names (CYFR_LOCUS_APPARMOR), with its system
  # paths unmasked: every role process and every spawn is cloned into a
  # space of its own, which mounts its own /proc.
  @confinement [
    "seccomp=./keeper.seccomp.json",
    "apparmor=${CYFR_LOCUS_APPARMOR:-cyfr-locus-unset}",
    "systempaths=unconfined"
  ]
  @security_opt ["no-new-privileges:true", "writable-cgroups=true" | @confinement]

  # Keys that would hand Locus the host's privileges, namespaces, devices,
  # a network of its own or a compose limit: each role's bounds are the
  # keeper's to write into the role's group, from `@bounds`.
  @forbidden_keys ~w(privileged pid userns_mode cgroup devices networks ports expose deploy
                     entrypoint healthcheck mem_limit cpus)

  # Each role's bounds and their defaults, compose's one definition of
  # them: the backends role has no processor bound.
  @bounds [
    {"LOCUS_RUNTIME_MEMORY_LIMIT", "4G"},
    {"LOCUS_RUNTIME_CPU_LIMIT", "4"},
    {"LOCUS_BUILDS_MEMORY_LIMIT", "4G"},
    {"LOCUS_BUILDS_CPU_LIMIT", "2"},
    {"LOCUS_BACKENDS_MEMORY_LIMIT", "2G"}
  ]

  # The files that spell a role's facts, beside docker-compose.yml and the
  # Locus image.
  @dockerfile "Dockerfile.locus"
  @compose "docker-compose.yml"
  @health "apps/locus/health.sh"
  @config "apps/locus/lib/locus/config.ex"
  @locus_lib "apps/locus/lib/"

  # Each role's image suites: their directory, and the harness that reads
  # the table's vector file.
  @suites %{
    runtime: {"tests/locus-runtime-image", "stack.py"},
    builds: {"tests/builder-image", "stack.py"},
    backends: {"tests/locus-backends-image", "harness.py"}
  }

  # A role's suite kept outside its directory.
  @suite_files %{"scripts/builder-smoke.py" => :builds}

  # The guard's control, on the volume both mount: the guard writes it and
  # Locus only reads it.
  @guard_control_dir "/run/cyfr-guard-control"
  @guard_control "#{@guard_control_dir}/guard.sock"
  @control_volume "guard-control"

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  # Where a space's first process builds the space's files: the keeper's
  # one definition, `stage.Root`, which the image makes and the AppArmor
  # profile lets a space mount under.
  defp space_root do
    [root] =
      Regex.run(
        ~r/^const Root = "([^"]+)"$/m,
        read!("apps/locus/keeper/internal/stage/space_linux.go"),
        capture: :all_but_first
      )

    root
  end

  defp services(compose), do: YamlElixir.read_from_string!(compose)["services"]

  # The Locus service's tmpfs mounts as the table spells them: each role's
  # spawns' homes, the release's run directory, root's, and each role's run
  # folder, its own uid's.
  defp tmpfs(release) do
    roles = LocusRoles.roles()

    for(role <- roles, do: "#{role.home_root}:mode=1733,exec,size=#{role.home_size}") ++
      ["#{release.run_dir}:mode=0711,size=#{release.run_size}"] ++
      for(
        role <- roles,
        do: "#{role.run_dir}:uid=#{role.uid},gid=#{role.uid},mode=0700,size=#{role.run_size}"
      )
  end

  # The kept homes at their root, the guard's control, read-only, and the
  # machines' folder.
  defp locus_volumes(roles) do
    for(%{kept_root: root, kept_volume: volume} <- roles, root != nil, do: "#{volume}:#{root}") ++
      ["#{@control_volume}:#{@guard_control_dir}:ro"] ++
      for(
        %{guest_root: root, guest_volume: volume} <- roles,
        root != nil,
        do: "#{volume}:#{root}"
      )
  end

  # The keys compose hands Locus and each role's bounds: every role's key,
  # the builds' and the backends' from the names cyfr reads them under.
  defp locus_environment do
    [
      "LOCUS_RUNTIME_KEY=${LOCUS_RUNTIME_KEY:-}",
      "LOCUS_BUILDS_KEY=${CYFR_LOCUS_BUILDS_KEY:-}",
      "LOCUS_BACKENDS_KEY=${CYFR_LOCUS_BACKENDS_KEY:-}",
      "LOCUS_RUNTIME_SERVICE_ID=${LOCUS_RUNTIME_SERVICE_ID:-wrk_locus}",
      "LOCUS_RUNTIME_HOST_API_URL=${LOCUS_RUNTIME_HOST_API_URL:-http://cyfr:${CYFR_HOST_API_PORT:-4300}}",
      "LOCUS_RUNTIME_BIND=0.0.0.0",
      "LOCUS_RUNTIME_PORT=#{LocusRoles.role!(:runtime).port}"
    ] ++ for({variable, default} <- @bounds, do: "#{variable}=${#{variable}:-#{default}}")
  end

  # The Locus service as compose runs it, by the keys it must hold: the
  # hardening, its mounts, its environment, the guard's namespace and its
  # health. A key here differing is a violation of that key.
  defp locus_service(release, roles) do
    Map.merge(@hardening, %{
      "container_name" => release.container,
      "image" => "ghcr.io/cyfrworks/cyfr-locus:latest",
      "build" => %{"context" => ".", "dockerfile" => "Dockerfile.locus"},
      "security_opt" => @security_opt,
      "env_file" => [%{"path" => ".env.locus", "required" => false}],
      "environment" => locus_environment(),
      "network_mode" => "service:" <> release.guard,
      "depends_on" => %{release.guard => %{"condition" => "service_healthy"}},
      "tmpfs" => tmpfs(release),
      "volumes" => locus_volumes(roles),
      "stop_grace_period" => "40s"
    })
  end

  # The keys, sorted, where the Locus service of a compose text runs
  # without its shape: a value other than the shipped one, or a key it must
  # not have.
  defp locus_violations(compose) do
    release = LocusRoles.release()
    locus = Map.get(services(compose), release.service, %{})
    expected = locus_service(release, LocusRoles.roles())

    Enum.sort(
      for(
        key <- Enum.uniq(Map.keys(locus) ++ Map.keys(expected)),
        key not in @forbidden_keys,
        Map.get(locus, key) != Map.get(expected, key),
        do: key
      ) ++ for(key <- @forbidden_keys, Map.has_key?(locus, key), do: key)
    )
  end

  # The guard as compose runs it, whole: the Locus image running
  # cyfr-guard, NET_ADMIN alone, forwarding with no ICMP rate limit (its
  # sysctls), the ready file's tmpfs and its control's volume, whose socket
  # its environment names, its only writable surfaces, cyfr's fixed
  # endpoint address in its environment with the private hosts the
  # deployment names and core's host API, Locus's service name as its alias
  # on the one network, every role's port exposed, and the guard's own
  # health probe.
  defp guard_service(release, roles) do
    %{
      "container_name" => release.guard_container,
      "image" => "ghcr.io/cyfrworks/cyfr-locus:latest",
      "build" => %{"context" => ".", "dockerfile" => "Dockerfile.locus"},
      "expose" => roles |> Enum.map(&"#{&1.port}") |> Enum.sort(),
      "entrypoint" => ["cyfr-guard"],
      "init" => true,
      "cap_drop" => ["ALL"],
      "cap_add" => ["NET_ADMIN"],
      "security_opt" => ["no-new-privileges:true"],
      "read_only" => true,
      "ipc" => "none",
      "sysctls" => %{"net.ipv4.ip_forward" => "1", "net.ipv4.icmp_ratelimit" => "0"},
      "tmpfs" => ["/run/cyfr-guard:mode=0755,size=1m"],
      "environment" => [
        "CYFR_GUARD_CONTROL_PLANE=#{release.endpoint_address}",
        "CYFR_PRIVATE_EGRESS_TARGETS=${CYFR_PRIVATE_EGRESS_TARGETS:-#{release.service}}",
        "CYFR_GUARD_CONTROL=#{@guard_control}",
        "CYFR_GUARD_HOST_API=#{release.host_api_address}:${CYFR_HOST_API_PORT:-4300}"
      ],
      "volumes" => ["#{@control_volume}:#{@guard_control_dir}"],
      "networks" => %{release.network => %{"aliases" => [release.service]}},
      "healthcheck" => %{
        "test" => ["CMD", "cyfr-guard", "check"],
        "interval" => "10s",
        "timeout" => "3s",
        "start_period" => "5s",
        "retries" => 3
      },
      "restart" => "unless-stopped",
      "logging" => @hardening["logging"],
      "deploy" => %{"resources" => %{"limits" => %{"memory" => "32M"}}}
    }
  end

  # The keys, sorted, where the guard of a compose text differs from
  # `guard_service/2`.
  defp guard_violations(compose) do
    release = LocusRoles.release()
    guard = Map.get(services(compose), release.guard, %{})
    expected = guard_service(release, LocusRoles.roles())

    Enum.sort(
      for key <- Enum.uniq(Map.keys(guard) ++ Map.keys(expected)),
          Map.get(guard, key) != Map.get(expected, key),
          do: key
    )
  end

  # The networks a service of a parsed compose file joins, whether it lists
  # them or maps each to its attachment.
  defp network_names(networks) when is_map(networks), do: Map.keys(networks)
  defp network_names(networks), do: List.wrap(networks)

  # An IPv4 subnet as its first address and prefix length, the address as
  # an integer.
  defp cidr(text) do
    [address, bits] = String.split(text, "/")
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(address))
    <<value::32>> = <<a, b, c, d>>
    {value, String.to_integer(bits)}
  end

  # Whether two subnets share an address: one holds the other's first
  # address at the shorter prefix.
  defp overlaps?({a, a_bits}, {b, b_bits}) do
    shift = 32 - min(a_bits, b_bits)
    Bitwise.bsr(a, shift) == Bitwise.bsr(b, shift)
  end

  # A role's uid pool as cyfr-locus takes it: `<pool>:<first>-<last>:<reach>`.
  defp pool_spec(role), do: "#{role.pool}:#{role.uids.first}-#{role.uids.last}:#{role.reach}"

  # A role as cyfr-locus takes it: `<name>:<uid>:<port>:<pool>`, then
  # `:private` for the role whose space reaches private addresses and
  # `:kept` for the role whose sessions keep homes.
  defp role_spec(role) do
    "#{role.name}:#{role.uid}:#{role.port}:#{role.pool}" <>
      if(role.private, do: ":private", else: "") <> if(role.kept_root, do: ":kept", else: "")
  end

  # The command that serves Locus: cyfr-locus over every role and its pool,
  # the homes' root, the kept homes' root and range, and the guard's
  # control, starting the release for each role.
  defp keeper_argv(release, roles) do
    ["cyfr-locus", "serve"] ++
      Enum.flat_map(roles, &["--role", role_spec(&1)]) ++
      Enum.flat_map(roles, &["--pool", pool_spec(&1)]) ++
      ["--home-root", release.home_root] ++
      Enum.flat_map(
        for(%{kept_root: root} = role <- roles, root != nil, do: role),
        &["--kept-homes", "#{&1.kept_root}:#{&1.kept_uids.first}-#{&1.kept_uids.last}"]
      ) ++ ["--guard", @guard_control, "--", release.bin, "start"]
  end

  # ————— the role table, and every spelling of it —————

  # Every file `role_drift/3` reads, by its path from the checkout's root.
  defp shipped_texts do
    overlays = Map.keys(expected_overlays(LocusRoles.release(), LocusRoles.roles()))
    suites = for {_name, {dir, _harness}} <- @suites, path <- wildcard("#{dir}/*.py"), do: path

    paths =
      [@dockerfile, @compose, @health | overlays] ++
        suites ++ Map.keys(@suite_files) ++ wildcard("#{@locus_lib}**/*.ex")

    Map.new(paths, &{&1, read!(&1)})
  end

  defp wildcard(pattern) do
    @root |> Path.join(pattern) |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, @root))
  end

  defp role(roles, name), do: Enum.find(roles, &(&1.name == name))

  # The `{path, kind, role}` triples, sorted and each once, where a text of
  # `texts` (path => contents) spells a fact other than the table's
  # (`release`, `roles`): `role` is the role whose fact it spells, or
  # `:release` for a fact of the release spelled where no role is. A site
  # that must be spelled and is missing, or is not in the form read, is
  # drift as a differing one is. Its kinds:
  #
  # - `:users`: Dockerfile.locus's role users and pooled users, the kept
  #   homes' group, the run and home roots and each role's folder of them,
  #   and the directory a space's files are built under.
  # - `:entrypoint`: the image's entrypoint, which compose's service takes,
  #   and each overlay's entrypoint.
  # - `:network`: Locus shares the guard's namespace alone, the guard sits
  #   on the one network under Locus's name, cyfr joins it, and it is
  #   declared.
  # - `:tmpfs`: the service's mounts.
  # - `:port`: what the guard exposes, each role's probe in the image's
  #   health script, cyfr's address for each role, the port the runtime is
  #   told to listen on, the overlays' published ports, and
  #   `Locus.Config`'s listener defaults, answered and documented.
  # - `:service`: the service's and the guard's container names, and
  #   everything else an overlay layers: its services and every other key
  #   it gives them (`overlay_drift/3`).
  # - `:suite`: an image suite that spells a fact of its role or the
  #   release, or a harness that reads no vector file.
  # - `:pool`: Locus's own pool names and attach directory, its `--pool`
  #   arguments, and the documented attach directory.
  defp role_drift(texts, release, roles) do
    services = services(Map.fetch!(texts, @compose))

    Enum.sort(
      Enum.uniq(
        users_drift(Map.fetch!(texts, @dockerfile), release, roles) ++
          entrypoint_drift(texts, services, release, roles) ++
          network_drift(Map.fetch!(texts, @compose), services, release) ++
          tmpfs_drift(services, release) ++
          port_drift(texts, services, release, roles) ++
          service_drift(services, release) ++
          overlay_drift(texts, release, roles) ++
          suite_drift(texts, release, roles) ++
          pool_drift(texts, release, roles)
      )
    )
  end

  # Dockerfile.locus names a role's pooled users `printf '<prefix>%02d'`
  # over `<base> + i`, `<base>` being the uid before the pool's first.
  @user_loop ~r/for i in \$\(seq 1 (\d+)\); do \\\s+name="\$\(printf '([a-z-]+)%02d' "\$i"\)"; uid=\$\(\((\d+) \+ i\)\)/

  defp user_loops(dockerfile) do
    for [count, name, base] <- Regex.scan(@user_loop, dockerfile, capture: :all_but_first) do
      base = String.to_integer(base)
      {name, (base + 1)..(base + String.to_integer(count))}
    end
  end

  # Dockerfile.locus makes the role users over `<name>:<uid>` pairs, each
  # `locus-<name>` with its run folder and its homes' folder.
  @role_loop ~r/for role in ((?:[a-z]+:\d+ ?)+); do/

  defp role_users(dockerfile) do
    case Regex.run(@role_loop, dockerfile, capture: :all_but_first) do
      [pairs] ->
        for pair <- String.split(pairs),
            [name, uid] = String.split(pair, ":"),
            do: {name, String.to_integer(uid)}

      nil ->
        nil
    end
  end

  defp users_drift(dockerfile, release, roles) do
    loops = user_loops(dockerfile)
    %{home_root: home_root, run_dir: run_dir} = release
    [kept] = for %{kept_root: root} = role <- roles, root != nil, do: role

    pools =
      for role <- roles,
          {role.user_prefix, role.uids} not in loops or
            {Atom.to_string(role.name), role.uid} not in (role_users(dockerfile) || []),
          do: {@dockerfile, :users, role.name}

    release_spelled? =
      length(role_users(dockerfile) || []) == length(roles) and
        dockerfile =~ ~s(name="locus-${role%%:*}"; uid="${role##*:}") and
        dockerfile =~ ~s(install -d -m 0700 -o "$name" -g "$name" "#{run_dir}/${role%%:*}") and
        dockerfile =~ ~s(install -d -m 1733 -o root -g root "#{home_root}/${role%%:*}") and
        Regex.scan(~r/\bgroupadd -r -g (\d+) (\S+)/, dockerfile, capture: :all_but_first) ==
          [["#{kept.kept_gid}", kept.kept_group]] and
        Regex.scan(~r/\buseradd -r -u (\d+)/, dockerfile, capture: :all_but_first) == [] and
        not (dockerfile =~ ~r/\buseradd [^\n]* -G /) and
        Regex.scan(~r/\binstall -d -m (\d+) -o (\S+) -g (\S+) (\/\S+)/, dockerfile,
          capture: :all_but_first
        ) ==
          [
            ["1773", "root", kept.kept_group, kept.kept_root],
            ["0755", "root", "root", space_root()]
          ] and
        Regex.scan(~r/\bchmod (\d+) (\S+)/, dockerfile, capture: :all_but_first) ==
          [["0711", run_dir], ["0755", home_root]] and
        not (dockerfile =~ "RELEASE_TMP=")

    if release_spelled?, do: pools, else: [{@dockerfile, :users, :release} | pools]
  end

  defp entrypoint_drift(texts, services, release, roles) do
    image =
      case Regex.run(~r/^ENTRYPOINT (\[.*\])$/m, Map.fetch!(texts, @dockerfile),
             capture: :all_but_first
           ) do
        [json] -> decode(json)
        nil -> nil
      end

    if(image == keeper_argv(release, roles), do: [], else: [{@dockerfile, :entrypoint, :release}]) ++
      if(Map.has_key?(Map.get(services, release.service, %{}), "entrypoint"),
        do: [{@compose, :entrypoint, :release}],
        else: []
      )
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  # Locus sits on the one network through its guard alone, whose namespace
  # it shares and which carries Locus's name there; cyfr joins it.
  defp network_drift(compose, services, release) do
    declared = Map.keys(YamlElixir.read_from_string!(compose)["networks"] || %{})
    cyfr = network_names(get_in(services, ["cyfr", "networks"]))
    locus = Map.get(services, release.service, %{})
    guard = Map.get(services, release.guard, %{})

    if locus["network_mode"] == "service:" <> release.guard and
         not Map.has_key?(locus, "networks") and
         guard["networks"] == %{release.network => %{"aliases" => [release.service]}} and
         release.network in cyfr and release.network in declared,
       do: [],
       else: [{@compose, :network, :release}]
  end

  defp tmpfs_drift(services, release) do
    if get_in(services, [release.service, "tmpfs"]) == tmpfs(release),
      do: [],
      else: [{@compose, :tmpfs, :release}]
  end

  # The one variable of a role's roster that names its listener's port.
  defp port_variable(role) do
    [variable] = Enum.filter(Locus.Config.variables(role.name), &String.ends_with?(&1, "_PORT"))
    variable
  end

  # The port each role's listener takes where its variable is unset, as
  # `Locus.Config` answers a node holding each role's key.
  defp listener_defaults do
    key = String.duplicate("ab", 32)
    flat = %{"LOCUS_BUILDS_KEY" => key, "LOCUS_BACKENDS_KEY" => key}
    {:ok, settings} = Locus.Config.from_env(&Map.get(flat, &1), Map.keys(flat))
    env = %{"LOCUS_RUNTIME_KEY" => key, "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"}
    {:ok, runtime} = Locus.Config.runtime_from_env(&Map.get(env, &1))
    %{builds: settings[:port], backends: settings[:backends_port], runtime: runtime[:port]}
  end

  defp port_drift(texts, services, release, roles) do
    config = Map.fetch!(texts, @config)
    health = Map.fetch!(texts, @health)
    defaults = listener_defaults()
    cyfr = List.wrap(get_in(services, ["cyfr", "environment"]))
    exposed = get_in(services, [release.guard, "expose"]) || []
    told = List.wrap(get_in(services, [release.service, "environment"]))

    # Each address cyfr names for Locus is a role's port at Locus's name.
    reached =
      for entry <- cyfr,
          [port] <-
            Regex.scan(~r{http://#{Regex.escape(release.service)}:(\d+)}, entry,
              capture: :all_but_first
            ),
          do: String.to_integer(port)

    strays =
      if Enum.all?(reached, &(&1 in Enum.map(roles, fn role -> role.port end))),
        do: [],
        else: [{@compose, :port, :release}]

    strays ++
      for role <- roles,
          variable = port_variable(role),
          {path, spelled?} <- [
            {@compose,
             "#{role.port}" in exposed and
               Enum.all?(
                 told,
                 &(not String.starts_with?(&1, variable <> "=") or
                     &1 == "#{variable}=#{role.port}")
               )},
            {@health, health_probe?(health, role)},
            {@config,
             defaults[role.name] == role.port and
               documented_default(config, variable) == "#{role.port}"}
          ],
          not spelled?,
          do: {path, :port, role.name}
  end

  # The health script probes a role exactly when its key is set, at the
  # island address and the role's port, once.
  defp health_probe?(health, role) do
    Regex.scan(~r/\$\{(LOCUS_[A-Z]+_KEY):-\}/, health, capture: :all_but_first)
    |> List.flatten()
    |> Enum.count(&(&1 == role.key)) == 1 and
      length(Regex.scan(~r{"http://\$address:#{role.port}/}, health)) == 1
  end

  # The default `Locus.Config`'s documentation table gives `variable`: the
  # last of the four cells of its one row, or `nil` where there is no such
  # row, more than one, or a row of another shape.
  defp documented_default(config, variable) do
    rows = Regex.scan(~r/^  \| `#{Regex.escape(variable)}` \|.*$/m, config) |> List.flatten()

    with [row] <- rows,
         ["", _variable, _setting, _accepted, default, ""] <-
           Enum.map(String.split(row, "|"), &String.trim/1) do
      default
    else
      _ -> nil
    end
  end

  # Each overlay as the image suites write it, whole: the role it layers
  # for, the services it gives keys to with every key and value, and the
  # networks it changes (`nil` where it changes none). A value that is a
  # fact of the table comes from the table; the rest is written here, so a
  # change to an overlay is a change to this test.
  #
  # An overlay publishes its role's port on the guard, since a service
  # under `network_mode: service:` publishes nothing, and the suite reads it
  # with `compose port <guard>`. A builds or backends overlay gives the
  # guard a tools directory first on its PATH, empty in every case but the
  # one that starts the guard with an ip6tables that fails; adds a stand-in
  # for cyfr, a listener on the control plane's two addresses (cyfr's fixed
  # endpoint address and cyfr's fixed address on the Locus network, under
  # cyfr's name), which the suite proves refused and where the builds'
  # stands in for core's host API, which the guard is given; enables IPv6
  # on the Locus network, so the guard's IPv6 rules are met by routed
  # packets; and starts the keeper with a pool and, for the backends, kept
  # homes the suite chooses.
  defp expected_overlays(release, roles) do
    [runtime, builds, backends] = Enum.map([:runtime, :builds, :backends], &role(roles, &1))

    island = fn image_variable, role, locus ->
      {role.name,
       %{
         release.service =>
           Map.merge(
             %{
               "image" => "${#{image_variable}:?set #{image_variable}}",
               "container_name" => nil,
               "pull_policy" => "never"
             },
             locus
           ),
         release.guard => guard_overlay(image_variable, role),
         "cyfr-stand-in" => stand_in_overlay(image_variable, release)
       }, %{release.network => %{"enable_ipv6" => true}}}
    end

    %{
      "tests/builder-image/compose.builds.yml" =>
        island.("BUILDER_IMAGE", builds, %{
          "volumes" => ["${CANARY_DIR:?set CANARY_DIR}:/canary:ro"],
          "entrypoint" => chosen_pool_argv(release, roles, builds, "BUILD_POOL"),
          "environment" => ["LOCUS_BUILDS_TIMEOUT_MS=${LOCUS_BUILDS_TIMEOUT_MS:-}"]
        }),
      "tests/locus-backends-image/compose.backends.yml" =>
        island.("BACKENDS_IMAGE", backends, %{
          "volumes" => [
            "${PROBE_DIR:?set PROBE_DIR}:/probe:ro",
            "${CANARY_DIR:?set CANARY_DIR}:/canary:ro"
          ],
          "entrypoint" => chosen_pool_argv(release, roles, backends, "BACKENDS_POOL"),
          "environment" => [
            "LOCUS_BACKENDS_MEMORY_BYTES=${LOCUS_BACKENDS_MEMORY_BYTES:-}",
            "LOCUS_BACKENDS_MEMORY_BUDGET=${LOCUS_BACKENDS_MEMORY_BUDGET:-}"
          ]
        }),
      # The runtime's suites take the image's entrypoint: the overlay names
      # none.
      "tests/locus-runtime-image/compose.runtime.yml" =>
        {:runtime,
         %{
           release.service => %{
             "image" => "${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}",
             "container_name" => nil,
             "pull_policy" => "never",
             "environment" => [
               "LOCUS_RUNTIME_POOL_SIZE=${LOCUS_RUNTIME_POOL_SIZE:?set LOCUS_RUNTIME_POOL_SIZE}",
               "LOCUS_RUNTIME_IDLE_TTL_MS=${LOCUS_RUNTIME_IDLE_TTL_MS:?set LOCUS_RUNTIME_IDLE_TTL_MS}",
               "LOCUS_RUNTIME_WATCHDOG_GRACE_MS=${LOCUS_RUNTIME_WATCHDOG_GRACE_MS:?set LOCUS_RUNTIME_WATCHDOG_GRACE_MS}",
               "LOCUS_RUNTIME_RELEASE_GRACE_MS=${LOCUS_RUNTIME_RELEASE_GRACE_MS:?set LOCUS_RUNTIME_RELEASE_GRACE_MS}"
             ]
           },
           release.guard => %{
             "image" => "${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}",
             "container_name" => nil,
             "pull_policy" => "never",
             "ports" => ["127.0.0.1::#{runtime.port}"]
           }
         }, nil},
      # The roles proof layers this after the backends overlay: the builds'
      # and the runtime's ports published on the guard beside the backends'.
      "tests/locus-backends-image/compose.roles.yml" =>
        {:backends,
         %{
           release.guard => %{
             "ports" =>
               for(name <- [:builds, :runtime], do: "127.0.0.1::#{role(roles, name).port}")
           }
         }, nil},
      # The overlays a role's suites layer last, without writable cgroups:
      # the service's own security options but that one.
      "tests/builder-image/compose.no-writable-cgroups.yml" =>
        {:builds,
         %{release.service => %{"security_opt" => @security_opt -- ["writable-cgroups=true"]}},
         nil},
      "tests/locus-runtime-image/compose.no-writable-cgroups.yml" =>
        {:runtime,
         %{release.service => %{"security_opt" => @security_opt -- ["writable-cgroups=true"]}},
         nil}
    }
  end

  # The guard as an island's overlay layers it: the image under test, the
  # role's port published on the loopback, and the tools directory the
  # suite chooses first on its PATH.
  defp guard_overlay(image_variable, role) do
    %{
      "image" => "${#{image_variable}:?set #{image_variable}}",
      "container_name" => nil,
      "pull_policy" => "never",
      "ports" => ["127.0.0.1::#{role.port}"],
      "volumes" => ["${GUARD_TOOLS_DIR:?set GUARD_TOOLS_DIR}:/opt/cyfr-guard-tools:ro"],
      "environment" => [
        "PATH=/opt/cyfr-guard-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      ]
    }
  end

  # The stand-in for cyfr an island's suite starts: the image under test
  # answering on port 4000, on cyfr's fixed endpoint address and at cyfr's
  # fixed address and under cyfr's name on the Locus network.
  defp stand_in_overlay(image_variable, release) do
    %{
      "image" => "${#{image_variable}:?set #{image_variable}}",
      "pull_policy" => "never",
      "entrypoint" => [
        "node",
        "-e",
        "require('http').createServer((q, s) => s.end('stand-in')).listen(4000, '::')"
      ],
      "cap_drop" => ["ALL"],
      "read_only" => true,
      "networks" => %{
        release.endpoint_network => %{
          "ipv4_address" => "${ENDPOINT_ADDRESS:?set ENDPOINT_ADDRESS}"
        },
        release.network => %{
          "ipv4_address" => "${HOST_API_ADDRESS:?set HOST_API_ADDRESS}",
          "aliases" => ["cyfr"]
        }
      }
    }
  end

  # The keeper's command where the suite chooses `role`'s pool's uids
  # through `variable` (`<pool>:${VARIABLE:?set VARIABLE}:<reach>`) and, for
  # the role that keeps homes, the kept homes' root and range, since the
  # image suites run several stacks side by side.
  defp chosen_pool_argv(release, roles, role, variable) do
    argv = keeper_argv(release, roles)
    at = Enum.find_index(argv, &(&1 == pool_spec(role)))
    argv = List.replace_at(argv, at, "#{role.pool}:${#{variable}:?set #{variable}}:#{role.reach}")

    case {role.kept_root, Enum.find_index(argv, &(&1 == "--kept-homes"))} do
      {nil, _} -> argv
      {_root, at} -> List.replace_at(argv, at + 1, "${KEPT_HOMES:?set KEPT_HOMES}")
    end
  end

  # Where an overlay differs from the one expected: `:port` for any of its
  # services' ports, `:entrypoint` for any entrypoint, `:service` for any
  # other service, key, value or network; all three where it is not an
  # overlay (`overlay/1`).
  defp overlay_drift(texts, release, roles) do
    for {path, {name, services, networks}} <- expected_overlays(release, roles),
        kind <- overlay_differences(Map.fetch!(texts, path), services, networks),
        do: {path, kind, name}
  end

  defp overlay_differences(text, want_services, want_networks) do
    case overlay(text) do
      {:ok, %{"services" => got_services} = overlay} ->
        differs? = fn read ->
          Enum.any?(want_services, fn {service, want} ->
            read.(Map.get(got_services, service, %{})) != read.(want)
          end)
        end

        for {kind, differs?} <- [
              entrypoint: differs?.(&Map.get(&1, "entrypoint")),
              port: differs?.(&Map.get(&1, "ports")),
              service:
                Enum.sort(Map.keys(got_services)) != Enum.sort(Map.keys(want_services)) or
                  differs?.(&Map.drop(&1, ~w(entrypoint ports))) or
                  Map.get(overlay, "networks") != want_networks
            ],
            differs?,
            do: kind

      :error ->
        [:entrypoint, :port, :service]
    end
  end

  # What stands in for `container_name: !reset null` while the overlay is
  # parsed.
  @reset_null "!reset null"

  # An overlay parsed whole, in the one shape the image suites write and
  # the parse reads as compose does: `{:ok, overlay}`, or `:error` for any
  # other shape. It is one document holding a `services` mapping and, at
  # most, a `networks` mapping, with no merge key, and compose's merge tags
  # appear only as a service's `container_name: !reset null` and
  # `security_opt: !override` over a list: the first as compose reads it
  # (`container_names/2`), the second as the list it tags. YamlElixir
  # refuses every other tag; it reads only the last of several documents
  # and resolves no merge; compose reads `!reset` with a value, or
  # `!override` on a mapping, otherwise than as the value; and a top-level
  # key such as `include` brings in what no parse of this text holds.
  defp overlay(text) do
    resets = length(Regex.scan(~r/^    container_name: !reset null$/m, text))

    untagged =
      text
      |> String.replace(~r/^(    container_name: )!reset null$/m, ~s(\\1"#{@reset_null}"))
      |> String.replace(~r/^(    security_opt: )!override$/m, "\\1")

    with {:ok, [%{"services" => %{} = services} = overlay]} <-
           YamlElixir.read_all_from_string(untagged),
         [] <- Map.keys(overlay) -- ["services", "networks"],
         true <- is_map(Map.get(overlay, "networks", %{})),
         false <- merge_key_in?(overlay),
         {:ok, services} <- container_names(services, resets) do
      {:ok, %{overlay | "services" => services}}
    else
      _ -> :error
    end
  end

  # Compose reads `container_name: !reset null` as the service's name
  # removed, and a plain null as no name written: the deployed name stays.
  # So the reset reads as a null name and a plain null as no key. Every
  # placeholder read must be a tagged line's, so a value that spells it is
  # no overlay.
  defp container_names(services, resets) do
    placeholders =
      Enum.count(services, &match?({_, %{"container_name" => @reset_null}}, &1))

    if placeholders == resets do
      {:ok,
       Map.new(services, fn
         {name, %{"container_name" => @reset_null} = service} ->
           {name, %{service | "container_name" => nil}}

         {name, %{"container_name" => nil} = service} ->
           {name, Map.delete(service, "container_name")}

         other ->
           other
       end)}
    else
      :error
    end
  end

  defp merge_key_in?(%{} = map),
    do: Enum.any?(map, fn {key, value} -> merge_name?(key) or merge_key_in?(value) end)

  defp merge_key_in?(list) when is_list(list), do: Enum.any?(list, &merge_key_in?/1)
  defp merge_key_in?(_value), do: false

  defp merge_name?(key), do: is_binary(key) and String.starts_with?(key, "<<")

  defp service_drift(services, release) do
    if get_in(services, [release.service, "container_name"]) == release.container and
         get_in(services, [release.guard, "container_name"]) == release.guard_container,
       do: [],
       else: [{@compose, :service, :release}]
  end

  # Every image suite of the texts: `{path, role, harness?}`.
  defp suite_files(texts) do
    in_dirs =
      for {path, _text} <- texts,
          {name, {dir, harness}} <- @suites,
          Path.dirname(path) == dir and Path.extname(path) == ".py",
          do: {path, name, Path.basename(path) == harness}

    in_dirs ++
      for({path, name} <- @suite_files, Map.has_key?(texts, path), do: {path, name, false})
  end

  defp suite_drift(texts, release, roles) do
    for {path, name, harness?} <- suite_files(texts),
        text = Map.fetch!(texts, path),
        (harness? and not (text =~ ~s("fixtures", "locus_roles.json"))) or
          (harness? and guard_spelled?(text)) or
          Enum.any?(spellings(release, role(roles, name)), &Regex.match?(&1, text)),
        do: {path, :suite, name}
  end

  # A harness names the guard from the table alone, `GUARD =
  # RELEASE["guard"]`: a literal in that position is drift whatever it
  # says, since a wrong name is not one of the table's values and a value
  # scan would miss it.
  defp guard_spelled?(text),
    do: not (text =~ ~r/^GUARD\s*=\s*RELEASE\["guard"\]\s*$/m) or text =~ ~r/^GUARD\s*=\s*["']/m

  # Where a suite spells a fact of its role or of the release: a number
  # (`_` allowed between its digits) or a path anywhere; a name as a whole
  # string literal, other than the directory `apps/locus` as a joined
  # path's segments; the pool as a spawn's or a pool argument's, the
  # users' prefix as a pooled user's name and the reach as a pool
  # argument's.
  defp spellings(release, role) do
    numbers = [role.uid, role.port, role.uids.first - 1 | Enum.to_list(role.uids)]
    paths = [release.bin, release.home_root, release.run_dir, role.home_root, role.run_dir]

    # The release's container is named as the keeper's binary is,
    # `cyfr-locus`, which a suite spells to run it, and its run root's size,
    # `1m`, as a rate limit's window is: neither is a spelling of the
    # table's.
    names =
      [role.user_prefix, role.user, role.home_size, role.run_size] ++
        [release.service, release.guard, release.guard_container]

    pool = Regex.escape(role.pool)

    Enum.map(numbers, fn number ->
      digits = number |> Integer.to_string() |> String.graphemes() |> Enum.join("_?")
      ~r/(?<![\w.])#{digits}(?!\w)/
    end) ++
      Enum.map(paths, fn path -> ~r/(?<![\w.\/-])#{Regex.escape(path)}(?![\w-])/ end) ++
      for(name <- Enum.uniq(names), do: ~r/(?<!["']apps["'], )["']#{Regex.escape(name)}["']/) ++
      [
        ~r/(?<![\w-])#{pool}:(?=[\d{$])/,
        ~r/["']pool["']\s*:\s*["']#{pool}["']/,
        ~r/(?<![\w-])#{Regex.escape(role.user_prefix)}(?=[\d{%])/
      ] ++ [~r/(?<![\w{}-]):#{Regex.escape(role.reach)}(?![\w-])/]
  end

  # A module of Locus's is a role's when it lies in the directory named for
  # the role, and the builds role's otherwise (`Locus.Keeper`, its client,
  # serves the builds).
  defp lib_role(path, roles) do
    [dir | _] = path |> String.replace_prefix("#{@locus_lib}locus/", "") |> Path.split()
    Enum.find(roles, &(Atom.to_string(&1.name) == dir)) || role(roles, :builds)
  end

  @lib_spellings [
    pool: ~r/^\s*@pool "([^"]*)"/m,
    pool_argument: ~r/--pool[\s=]+([A-Za-z0-9_-]+):/,
    attach_dir: ~r/(?:@attach_dir |\battach_dir: )"([^"]*)"/
  ]

  # The variable whose documented default is the role's run folder, which
  # the keeper names to each role in `@run_dir_variable`; a client named
  # none attaches at the release's run directory.
  @attach_variable "LOCUS_RUNTIME_ATTACH_DIR"
  @run_dir_variable "KEEPER_RUN_DIR"

  defp pool_drift(texts, release, roles) do
    spelled =
      for {path, text} <- texts,
          String.starts_with?(path, @locus_lib),
          role = lib_role(path, roles),
          {kind, pattern} <- @lib_spellings,
          [value] <- Regex.scan(pattern, text, capture: :all_but_first),
          do: {path, role, kind, value}

    expected = fn
      :pool, role -> role.pool
      :pool_argument, role -> role.pool
      :attach_dir, _role -> release.run_dir
    end

    # `Locus.Config` documents the attach directory's default for the role
    # whose variable it is: the run folder the keeper names.
    documented =
      for role <- roles,
          @attach_variable in Locus.Config.variables(role.name),
          documented_default(Map.fetch!(texts, @config), @attach_variable) !=
            "the role's run folder (`#{@run_dir_variable}`)",
          do: {@config, :pool, role.name}

    wrong =
      for {path, role, kind, value} <- spelled,
          value != expected.(kind, role),
          do: {path, :pool, role.name}

    # A role's modules name its pool.
    unspelled =
      for role <- roles,
          kind <- [:pool],
          not Enum.any?(spelled, &match?({_, ^role, ^kind, _}, &1)),
          do: {@locus_lib, :pool, role.name}

    wrong ++ unspelled ++ documented
  end

  test "the Caddyfile proxies everything to cyfr's proxy listener, on its (parameterized) port" do
    caddy = read!("Caddyfile")

    proxies = Regex.scan(~r/^\s*reverse_proxy\s+(\S+)/m, caddy, capture: :all_but_first)

    assert proxies == [["cyfr:{$CYFR_PROXY_PORT}"]],
           "expected exactly one reverse_proxy to cyfr:{$CYFR_PROXY_PORT}"

    opens = caddy |> String.graphemes() |> Enum.count(&(&1 == "{"))
    closes = caddy |> String.graphemes() |> Enum.count(&(&1 == "}"))
    assert opens == closes, "unbalanced braces in Caddyfile (#{opens} vs #{closes})"

    # Never the loopback listener: Caddy is not on its network.
    refute caddy =~ ~r/CYFR_PORT\b|4000/
  end

  test "compose runs cyfr, locus, its guard, caddy and tailscale — one web origin" do
    compose = read!("docker-compose.yml")
    release = LocusRoles.release()
    parsed = services(compose)

    assert Enum.sort(Map.keys(parsed)) ==
             Enum.sort(["caddy", "cyfr", "tailscale", release.service, release.guard])

    cyfr = parsed["cyfr"]
    [runtime, backends] = Enum.map([:runtime, :backends], &LocusRoles.role!/1)

    # cyfr reaches every role at Locus's name, which the guard carries on
    # the one network: the runtime and the backends at the URLs compose
    # gives it, the builds beside the backends (`Cyfr.RuntimeConfig`).
    workers = "wrk_locus=http://#{release.service}:#{runtime.port}"
    backends_url = "http://#{release.service}:#{backends.port}"

    assert "CYFR_LOCUS_RUNTIME_WORKERS=${CYFR_LOCUS_RUNTIME_WORKERS:-#{workers}}" in cyfr[
             "environment"
           ]

    assert "CYFR_LOCUS_BACKENDS_URL=${CYFR_LOCUS_BACKENDS_URL:-#{backends_url}}" in cyfr[
             "environment"
           ]

    assert "CYFR_PRIVATE_EGRESS_TARGETS=${CYFR_PRIVATE_EGRESS_TARGETS:-#{release.service}}" in cyfr[
             "environment"
           ]

    refute compose =~ "CYFR_LOCUS_BUILDS_URL"
    assert release.network in network_names(cyfr["networks"])
  end

  # cyfr reaches Locus over the one network, which only cyfr and the guard
  # join, and a build or a program reaches its registry and upstream API
  # over the same network: it is not `internal`, so the isolation is who is
  # attached.
  test "the locus network carries cyfr and the guard alone, and Locus out" do
    parsed = compose!()
    release = LocusRoles.release()

    assert parsed["networks"][release.network] == %{
             "ipam" => %{
               "config" => [%{"subnet" => release.subnet, "ip_range" => release.ip_range}]
             }
           }

    attached =
      for {service, definition} <- parsed["services"],
          release.network in network_names(definition["networks"]),
          do: service

    assert Enum.sort(attached) == Enum.sort(["cyfr", release.guard])

    assert Enum.sort(Map.keys(parsed["networks"])) ==
             Enum.sort(["default", "edge", release.network])
  end

  # cyfr holds three fixed addresses, each bound by one listener and never
  # an interface wildcard, so no other network cyfr joins reaches any: the
  # host API binds cyfr's address on the Locus network (the table's),
  # reachable from that network alone; the endpoint's loopback listener
  # binds cyfr's address on the default network (the table's), where Docker
  # publishes the host's loopback port; and its proxy listener binds cyfr's
  # address on the edge network (the table's), where Caddy and Tailscale
  # reach it. Each address lies in its network's subnet, outside the range
  # Docker hands the network's other containers, and is neither the
  # subnet's network, gateway nor broadcast address; each subnet is
  # private, outside the pools Docker draws the other networks' subnets
  # from by default, and apart from the others.
  test "the host API and the endpoint's two listeners each bind cyfr's own fixed address on their network" do
    parsed = compose!()
    release = LocusRoles.release()
    cyfr = parsed["services"]["cyfr"]

    # The default network is cyfr's gateway and dual-stack, so Docker maps
    # the published loopback port to the endpoint's address whatever other
    # networks cyfr joins, IPv6-enabled or not, and in whatever order they
    # came up (tests/compose-proof/run.sh --case bind holds it).
    fixed = [
      {release.network, release.subnet, release.ip_range, release.host_api_address,
       "CYFR_HOST_API_BIND=", %{"ipv4_address" => release.host_api_address}, %{}},
      {release.endpoint_network, release.endpoint_subnet, release.endpoint_ip_range,
       release.endpoint_address, "CYFR_BIND_ADDRESS=",
       %{"ipv4_address" => release.endpoint_address, "gw_priority" => 1},
       %{"enable_ipv6" => true}},
      # IPv4 alone and no gateway priority: the default network keeps the
      # published port.
      {release.edge_network, release.edge_subnet, release.edge_ip_range, release.edge_address,
       "CYFR_PROXY_BIND_ADDRESS=", %{"ipv4_address" => release.edge_address}, %{}}
    ]

    for {network, subnet, range, address, variable, attachment, declared} <- fixed do
      assert parsed["networks"][network] ==
               Map.merge(declared, %{
                 "ipam" => %{"config" => [%{"subnet" => subnet, "ip_range" => range}]}
               }),
             network

      assert cyfr["networks"][network] == attachment

      binds = for ^variable <> bind <- cyfr["environment"], do: bind
      refute "0.0.0.0" in binds
      refute "::" in binds
      assert binds == [address], variable

      assert_fixed_address(subnet, range, address)
    end

    # cyfr joins those three networks alone.
    assert Enum.sort(Map.keys(cyfr["networks"])) == Enum.sort(Enum.map(fixed, &elem(&1, 0)))

    subnets = Enum.map(fixed, &cidr(elem(&1, 1)))

    for {a, i} <- Enum.with_index(subnets), b <- Enum.drop(subnets, i + 1) do
      refute overlaps?(a, b), "two fixed subnets overlap"
    end
  end

  # `address` lies in `subnet`, outside `range`, which lies in `subnet`,
  # and is neither the subnet's network, gateway nor broadcast address;
  # the subnet is private and outside Docker's default pools.
  defp assert_fixed_address(subnet, range, address) do
    {base, bits} = cidr(subnet)
    fixed = cidr(address <> "/32")
    last = base + Bitwise.bsl(1, 32 - bits) - 1

    assert overlaps?(fixed, {base, bits}), "#{address} is not in #{subnet}"
    refute overlaps?(fixed, cidr(range)), "#{address} is in #{range}"
    assert overlaps?(cidr(range), {base, bits}), "#{range} is not in #{subnet}"
    refute elem(fixed, 0) in [base, base + 1, last], "#{address} is a reserved address"

    assert Enum.any?(
             ~w(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16),
             &overlaps?({base, bits}, cidr(&1))
           ),
           "#{subnet} is not a private subnet"

    default_pools = ["192.168.0.0/16" | for(octet <- 17..31, do: "172.#{octet}.0.0/16")]

    for pool <- default_pools do
      refute overlaps?({base, bits}, cidr(pool)), "#{subnet} overlaps Docker's pool #{pool}"
    end
  end

  # The bounds' defaults are each role's old container's limits, and the
  # backends' is its budget's default plus the role's 256 MiB of headroom;
  # .env.example documents each, and .env.locus.example says where they are
  # without setting one, since compose's environment wins over that file.
  test "the locus service holds the three keys and each role's bounds, their one default" do
    environment = compose!()["services"][LocusRoles.release().service]["environment"]
    assert environment == locus_environment()

    env = %{"LOCUS_BACKENDS_KEY" => String.duplicate("ab", 32)}
    {:ok, settings} = Locus.Config.from_env(&Map.get(env, &1), Map.keys(env))
    {_, backends_limit} = List.keyfind(@bounds, "LOCUS_BACKENDS_MEMORY_LIMIT", 0)
    assert limit_bytes(backends_limit) == settings[:backends_memory_budget] + 256 * 1024 * 1024

    example = read!(".env.example")
    locus_example = read!(".env.locus.example")

    for {variable, default} <- @bounds do
      assert example =~ ~r/^# #{variable}=#{default}$/m, "#{variable} in .env.example"
      assert locus_example =~ variable, "#{variable} in .env.locus.example"
      refute locus_example =~ ~r/^#? ?#{variable}=/m
    end

    # No role's processor bound but those the table of bounds names.
    refute Enum.any?(environment, &String.starts_with?(&1, "LOCUS_BACKENDS_CPU_LIMIT="))
  end

  defp limit_bytes(limit) do
    {count, unit} = Integer.parse(limit)
    count * Map.fetch!(%{"M" => 1024 * 1024, "G" => 1024 * 1024 * 1024}, unit)
  end

  # cyfr-locus bounds each role and each spawn only where the container's
  # cgroup is mounted writable, and clones each into a space of its own,
  # which takes the keeper's seccomp profile too. The container carries no
  # compose limit: the keeper writes each role's bounds into its group.
  test "the locus service keeps its hardening, its mounts and its guard's namespace" do
    assert locus_violations(read!("docker-compose.yml")) == []
  end

  test "a locus service that loses its shape fails" do
    compose = read!("docker-compose.yml")
    release = LocusRoles.release()

    plants = [
      {"without no-new-privileges:true",
       "\n      - no-new-privileges:true\n      - writable-cgroups=true\n",
       "\n      - writable-cgroups=true\n", ["security_opt"]},
      {"without its AppArmor profile",
       "\n      - apparmor=${CYFR_LOCUS_APPARMOR:-cyfr-locus-unset}\n      - systempaths=unconfined\n",
       "\n      - systempaths=unconfined\n", ["security_opt"]},
      {"setting read_only: false", "\n    read_only: true\n    ipc: none\n    restart",
       "\n    read_only: false\n    ipc: none\n    restart", ["read_only"]},
      {"without ipc: none", "\n    read_only: true\n    ipc: none\n    restart",
       "\n    read_only: true\n    restart", ["ipc"]},
      {"granting privileged: true", "\n  locus:\n    container_name:",
       "\n  locus:\n    privileged: true\n    container_name:", ["privileged"]},
      {"with a compose memory limit", "\n    stop_grace_period: 40s\n    # Healthcheck",
       "\n    stop_grace_period: 40s\n    deploy:\n      resources:\n        limits:\n          memory: 8G\n    # Healthcheck",
       ["deploy"]},
      {"with the runtime's bound at another default", "LOCUS_RUNTIME_MEMORY_LIMIT:-4G}",
       "LOCUS_RUNTIME_MEMORY_LIMIT:-8G}", ["environment"]},
      {"on its own network", "    network_mode: service:#{release.guard}\n",
       "    networks:\n      - #{release.network}\n", ["network_mode", "networks"]},
      {"waiting for its guard's start, not its health",
       "      #{release.guard}:\n        condition: service_healthy\n",
       "      #{release.guard}:\n        condition: service_started\n", ["depends_on"]},
      {"with the run root writable by all", "/run/locus:mode=0711,", "/run/locus:mode=1777,",
       ["tmpfs"]},
      {"with the runtime's run folder another's", "/run/locus/runtime:uid=10011,gid=10011,",
       "/run/locus/runtime:uid=10012,gid=10012,", ["tmpfs"]}
    ]

    # Each plant replaces one exact text, found once; one that is not
    # answers `:unchanged`, which no plant expects.
    outcomes =
      for {plant, from, to, _} <- plants do
        outcome =
          if length(String.split(compose, from)) == 2,
            do: locus_violations(String.replace(compose, from, to)),
            else: :unchanged

        {plant, outcome}
      end

    assert outcomes == for({plant, _, _, expected} <- plants, do: {plant, Enum.sort(expected)})
  end

  # Locus starts behind an egress guard: the Locus image running cyfr-guard
  # with NET_ADMIN and no other capability, in the network namespace Locus
  # shares, carrying Locus's name as its alias there, healthy only with
  # every rule installed, and holding no key or release. Locus waits for
  # the guard's health, not its start, so a guard whose rules failed starts
  # no role.
  test "the guard holds NET_ADMIN alone, exposes every role's port, and gives the runtime core's host API" do
    assert guard_violations(read!("docker-compose.yml")) == []
  end

  test "a guard that loses its shape fails" do
    compose = read!("docker-compose.yml")
    release = LocusRoles.release()

    plants = [
      {"gaining SETUID", "    cap_add:\n      - NET_ADMIN\n",
       "    cap_add:\n      - NET_ADMIN\n      - SETUID\n", ["cap_add"]},
      {"publishing a role's port",
       "    networks:\n      #{release.network}:\n        aliases:\n          - #{release.service}\n",
       "    ports:\n      - \"4101:4101\"\n    networks:\n      #{release.network}:\n        aliases:\n          - #{release.service}\n",
       ["ports"]},
      {"without Locus's alias",
       "    networks:\n      #{release.network}:\n        aliases:\n          - #{release.service}\n",
       "    networks:\n      - #{release.network}\n", ["networks"]},
      {"serving no control",
       "      - CYFR_GUARD_CONTROL=/run/cyfr-guard-control/guard.sock\n      - CYFR_GUARD_HOST_API",
       "      - CYFR_GUARD_HOST_API", ["environment"]},
      {"naming no host API",
       "      - CYFR_GUARD_HOST_API=172.16.231.2:${CYFR_HOST_API_PORT:-4300}\n", "",
       ["environment"]},
      {"exposing the builds' port no more", "      - \"4100\"\n      - \"4101\"\n",
       "      - \"4101\"\n", ["expose"]},
      {"forwarding with the ICMP rate limit on",
       "      net.ipv4.icmp_ratelimit: \"0\"\n    # The ready file's tmpfs",
       "    # The ready file's tmpfs", ["sysctls"]}
    ]

    outcomes =
      for {plant, from, to, _} <- plants do
        outcome =
          if length(String.split(compose, from)) == 2,
            do: guard_violations(String.replace(compose, from, to)),
            else: :unchanged

        {plant, outcome}
      end

    assert outcomes == for({plant, _, _, expected} <- plants, do: {plant, Enum.sort(expected)})
  end

  # cyfr-locus clones each role process and every spawn into a space of
  # its own, a user, network, IPC, pid, mount and cgroup namespace with
  # files of its own, which Docker's default seccomp and AppArmor profiles
  # deny. Locus runs under the keeper's seccomp profile, which the image
  # carries and a scaffolded project holds beside its compose file, where
  # compose reads it, and under the AppArmor profile .env names, which cyfr
  # carries, loads and names there, and whose name the image carries for
  # the keeper to prove; a project without the one, or a host without the
  # other, does not start the service. The image makes the directory a
  # space's files are built under, which the profile lets a space mount.
  test "Locus runs under the keeper's seccomp and AppArmor profiles, shipped beside the compose file" do
    compose = read!("docker-compose.yml")
    locus = services(compose)[LocusRoles.release().service]
    for option <- @confinement, do: assert(option in locus["security_opt"])
    assert compose =~ "user.max_user_namespaces"

    for role <- LocusRoles.roles(), do: assert(role.reach in LocusRoles.reaches())

    dockerfile = read!("Dockerfile.locus")
    assert dockerfile =~ ~r{^COPY apps/locus/keeper/seccomp/keeper\.json /etc/cyfr/keeper\.json$}m
    assert dockerfile =~ ~r{^COPY apps/codex/internal/apparmor/name /etc/cyfr/apparmor-profile$}m
    assert dockerfile =~ ~r{install -d -m 0755 -o root -g root #{Regex.escape(space_root())}$}m
    profile = read!("apps/codex/internal/apparmor/cyfr-locus")
    assert profile =~ "mount fstype=tmpfs -> #{space_root()}/,"
    assert profile =~ "pivot_root oldroot=#{space_root()}/.old/ #{space_root()}/,"

    dir = Path.join(System.tmp_dir!(), "cyfr-scaffold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    tarball = Path.join(dir, "scaffold.tar.gz")

    assert {_, 0} =
             System.cmd("bash", [Path.join(@root, "scripts/scaffold-tarball.sh"), tarball],
               stderr_to_stdout: true,
               env: bare_env()
             )

    {listing, 0} = System.cmd("tar", ["-tzf", tarball], env: bare_env())
    entries = String.split(listing, "\n", trim: true)
    assert "docker-compose.yml" in entries
    assert "keeper.seccomp.json" in entries

    {profile, 0} = System.cmd("tar", ["-xOzf", tarball, "keeper.seccomp.json"], env: bare_env())
    assert profile == read!("apps/locus/keeper/seccomp/keeper.json")
  end

  # A child's environment: every inherited name unset but where it finds
  # its tools and its temporary directory.
  defp bare_env do
    for {name, _} <- System.get_env(), name not in ~w(PATH TMPDIR), do: {name, nil}
  end

  # The image names its pooled uids for the role that runs under them,
  # `printf '<name>%02d'` over `<base> + i`, and each role's user for the
  # role; cyfr-locus refuses pools that overlap, and this keeps every pool,
  # every role's user and the kept homes' group apart.
  test "every pooled uid is named for its role, and no two pools or role users share a uid" do
    dockerfile = read!("Dockerfile.locus")
    pools = user_loops(dockerfile)
    roles = LocusRoles.roles()

    assert Enum.sort(pools) == Enum.sort(for role <- roles, do: {role.user_prefix, role.uids})
    assert role_users(dockerfile) == for(role <- roles, do: {Atom.to_string(role.name), role.uid})

    ranges = Enum.map(pools, &elem(&1, 1))

    for {a, i} <- Enum.with_index(ranges),
        b <- Enum.drop(ranges, i + 1),
        do: assert(Range.disjoint?(a, b), "#{inspect(a)} and #{inspect(b)} overlap")

    for range <- ranges, role <- roles, do: refute(role.uid in range)

    # The shipped entrypoint serves exactly those ranges, and every role.
    for role <- roles do
      assert dockerfile =~ ~s("--pool", "#{pool_spec(role)}")
      assert dockerfile =~ ~s("--role", "#{role_spec(role)}")
    end
  end

  # Each wire refuses a health body at another version, so the probe the
  # image runs posts each wire's own body at its own route, and the worker
  # listener's unsigned status is refused with 401 once it serves. Compose
  # carries no probe of its own, so no version is spelled there.
  test "the image's health script probes each role whose key is set at its wire's version" do
    health = read!(@health)
    dockerfile = read!("Dockerfile.locus")

    assert health =~
             "-d '#{Prima.BuilderProtocol.encode_health_request()}' \\\n    \"http://$address:#{LocusRoles.role!(:builds).port}#{Prima.BuilderProtocol.route(:health)}\""

    assert health =~
             "-d '#{Prima.LocusBackends.health_body()}' \\\n    \"http://$address:#{LocusRoles.role!(:backends).port}#{Prima.LocusBackends.route(:health)}\""

    assert health =~
             "\"http://$address:#{LocusRoles.role!(:runtime).port}#{Prima.WorkerWire.worker_route(:status)}\""

    assert health =~ ~s([ "$status" = "401" ])

    for role <- LocusRoles.roles(),
        do: assert(health_probe?(health, role), "#{role.name}'s probe")

    assert dockerfile =~
             ~r{^COPY --chmod=0755 apps/locus/health\.sh /usr/local/bin/locus-health$}m

    assert dockerfile =~ ~r{^    CMD \["locus-health"\]$}m

    refute Map.has_key?(compose!()["services"][LocusRoles.release().service], "healthcheck")
    refute read!("docker-compose.yml") =~ ~r/"version"/
  end

  test "every spelling of a role's facts is the role table's" do
    assert role_drift(shipped_texts(), LocusRoles.release(), LocusRoles.roles()) == []
  end

  test "a spelling of a role's fact that differs from the table is drift, wherever it is" do
    texts = shipped_texts()
    release = LocusRoles.release()
    roles = LocusRoles.roles()
    [runtime, builds, backends] = Enum.map([:runtime, :builds, :backends], &LocusRoles.role!/1)

    with_role = fn name, change ->
      Enum.map(roles, &if(&1.name == name, do: change.(&1), else: &1))
    end

    unread = fn path, name ->
      for kind <- [:entrypoint, :port, :service], do: {path, kind, name}
    end

    runtime_suite = "tests/locus-runtime-image/stack.py"
    builds_harness = "tests/builder-image/stack.py"
    builds_overlay = "tests/builder-image/compose.builds.yml"
    runtime_overlay = "tests/locus-runtime-image/compose.runtime.yml"
    backends_overlay = "tests/locus-backends-image/compose.backends.yml"
    builds_last_overlay = "tests/builder-image/compose.no-writable-cgroups.yml"
    channel = "apps/locus/lib/locus/runtime/keeper/channel.ex"
    runtime_keeper = "apps/locus/lib/locus/runtime/keeper.ex"
    runtime_last_overlay = "tests/locus-runtime-image/compose.no-writable-cgroups.yml"

    release_grace =
      "      - LOCUS_RUNTIME_RELEASE_GRACE_MS=${LOCUS_RUNTIME_RELEASE_GRACE_MS:?set LOCUS_RUNTIME_RELEASE_GRACE_MS}\n"

    status_route = Prima.WorkerWire.worker_route(:status)
    %{first: first, last: last} = runtime.uids

    plants = [
      {"the runtime's users counted from another base",
       {@dockerfile, "uid=$((#{first - 1} + i))", "uid=$((#{first + 99} + i))"},
       [{@dockerfile, :users, :runtime}]},
      {"the builds role's user at another uid",
       {@dockerfile, "builds:#{builds.uid} ", "builds:#{builds.uid + 100} "},
       [{@dockerfile, :users, :builds}]},
      {"the run root writable by every role",
       {@dockerfile, "chmod 0711 #{release.run_dir}", "chmod 1777 #{release.run_dir}"},
       [{@dockerfile, :users, :release}]},
      {"a role user of the kept homes' group",
       {@dockerfile, ~s(-s /usr/sbin/nologin "$name" \\\n         && install -d -m 0700),
        ~s(-s /usr/sbin/nologin -G locus "$name" \\\n         && install -d -m 0700)},
       [{@dockerfile, :users, :release}]},
      {"the backends' pool a uid short",
       {@dockerfile, ~s("#{pool_spec(backends)}"),
        ~s("#{backends.pool}:#{backends.uids.first}-#{backends.uids.last - 1}:routed")},
       [{@dockerfile, :entrypoint, :release}]},
      {"the runtime's pool not isolated",
       {@dockerfile, ~s("#{pool_spec(runtime)}"), ~s("#{runtime.pool}:#{first}-#{last}")},
       [{@dockerfile, :entrypoint, :release}]},
      {"the runtime role no longer private",
       {@dockerfile, ~s("#{role_spec(runtime)}"),
        ~s("#{role_spec(%{runtime | private: false})}")}, [{@dockerfile, :entrypoint, :release}]},
      {"compose naming an entrypoint of its own",
       {@compose, "    container_name: #{release.container}\n",
        "    container_name: #{release.container}\n    entrypoint: [\"cyfr-locus\"]\n"},
       [{@compose, :entrypoint, :release}]},
      {"the guard on another network",
       {@compose,
        "    networks:\n      #{release.network}:\n        aliases:\n          - #{release.service}\n",
        "    networks:\n      edge:\n        aliases:\n          - #{release.service}\n"},
       [{@compose, :network, :release}]},
      {"the runtime's homes twice as large", {@compose, "size=#{runtime.home_size}", "size=512m"},
       [{@compose, :tmpfs, :release}]},
      {"the runtime's harness spelling its pool",
       {runtime_suite, ~s(POOL_FIRST, POOL_LAST = ROLE["first_uid"], ROLE["last_uid"]),
        "POOL_FIRST, POOL_LAST = #{first}, #{last}"}, [{runtime_suite, :suite, :runtime}]},
      {"the builder overlay starting the builds role as another uid",
       {builds_overlay, ~s("#{role_spec(builds)}"), ~s("builds:0:#{builds.port}:#{builds.pool}")},
       [{builds_overlay, :entrypoint, :builds}]},
      {"the runtime's channel asking another pool",
       {channel, ~s(@pool "#{runtime.pool}"), ~s(@pool "#{runtime.pool}s")},
       [{channel, :pool, :runtime}]},
      {"a table with a ninth runner",
       {release, with_role.(:runtime, &%{&1 | uids: first..(last + 1)//1})},
       [
         {@dockerfile, :entrypoint, :release},
         {@dockerfile, :users, :runtime},
         {backends_overlay, :entrypoint, :backends},
         {builds_overlay, :entrypoint, :builds}
       ]},
      {"a table moving the builds' port",
       {release, with_role.(:builds, &%{&1 | port: &1.port + 2})},
       [
         {@config, :port, :builds},
         {@compose, :port, :builds},
         {@dockerfile, :entrypoint, :release},
         {@health, :port, :builds},
         {backends_overlay, :entrypoint, :backends},
         {builds_overlay, :entrypoint, :builds},
         {builds_overlay, :port, :builds},
         {"tests/locus-backends-image/compose.roles.yml", :port, :backends}
       ]},
      {"the builds' harness reading no vector file",
       {builds_harness, ~s("fixtures", "locus_roles.json"), ~s("fixtures", "locus_builds.json")},
       [{builds_harness, :suite, :builds}]},
      # A site that is missing, or not in the form read, is drift too.
      {"the runtime's probe without its port",
       {@health, "http://$address:#{runtime.port}#{status_route}",
        "http://$address#{status_route}"}, [{@health, :port, :runtime}]},
      {"the backends' probe whatever its key",
       {@health, ~s([ -n "${#{backends.key}:-}" ]), ~s([ -n "${LOCUS_ANY_KEY:-}" ])},
       [{@health, :port, :backends}]},
      {"cyfr reaching the backends at another port",
       {@compose, "http://#{release.service}:#{backends.port}}",
        "http://#{release.service}:#{backends.port + 2}}"}, [{@compose, :port, :release}]},
      {"the runtime told another port",
       {@compose, "LOCUS_RUNTIME_PORT=#{runtime.port}", "LOCUS_RUNTIME_PORT=#{runtime.port + 2}"},
       [{@compose, :port, :runtime}]},
      {"the runtime overlay publishing another port, as tcp",
       {runtime_overlay, ~s("127.0.0.1::#{runtime.port}"),
        ~s("127.0.0.1::#{runtime.port + 2}/tcp")}, [{runtime_overlay, :port, :runtime}]},
      {"the backends overlay publishing another port, as tcp",
       {backends_overlay, ~s("127.0.0.1::#{backends.port}"),
        ~s("127.0.0.1::#{backends.port + 2}/tcp")}, [{backends_overlay, :port, :backends}]},
      {"the backends overlay starting the release elsewhere, behind a comment",
       {backends_overlay, ~s("--", "#{release.bin}", "start"]),
        ~s("--", "/tmp/locus", "start"]  # the suite's release)},
       [{backends_overlay, :entrypoint, :backends}]},
      {"the builds overlay without its entrypoint line",
       {builds_overlay, "\n    entrypoint: [\"cyfr-locus\"",
        "\n    # entrypoint: [\"cyfr-locus\""}, [{builds_overlay, :entrypoint, :builds}]},
      {"the backends overlay publishing the port on Locus, not its guard",
       {backends_overlay,
        "  #{release.guard}:\n    image: ${BACKENDS_IMAGE:?set BACKENDS_IMAGE}\n    container_name: !reset null\n    pull_policy: never\n    ports:\n      - \"127.0.0.1::#{backends.port}\"\n",
        "  #{release.guard}:\n    image: ${BACKENDS_IMAGE:?set BACKENDS_IMAGE}\n    container_name: !reset null\n    pull_policy: never\n"},
       [{backends_overlay, :port, :backends}]},
      {"the builds overlay leaving the locus network IPv4 alone",
       {builds_overlay, "networks:\n  #{release.network}:\n    enable_ipv6: true\n", ""},
       [{builds_overlay, :service, :builds}]},
      {"the builds harness spelling its guard",
       {builds_harness, ~s(GUARD = RELEASE["guard"]), ~s(GUARD = "#{release.guard}")},
       [{builds_harness, :suite, :builds}]},
      {"the builds harness spelling a guard other than the table's",
       {builds_harness, ~s(GUARD = RELEASE["guard"]), ~s(GUARD = "wrong-guard")},
       [{builds_harness, :suite, :builds}]},
      {"a later literal overrides the suite guard lookup",
       {builds_harness, ~s(GUARD = RELEASE["guard"]),
        ~s(GUARD = RELEASE["guard"]) <> "\n" <> ~s(GUARD="wrong-guard")},
       [{builds_harness, :suite, :builds}]},
      {"the runtime keeper's remedy naming another pool",
       {runtime_keeper, "--pool #{runtime.pool}:", "--pool #{runtime.pool}s:"},
       [{runtime_keeper, :pool, :runtime}]},
      {"the builder's last overlay layering another service",
       {builds_last_overlay, "\n  #{release.service}:\n", "\n  #{release.guard}:\n"},
       [{builds_last_overlay, :service, :builds}]},
      {"the documented backends port",
       {@config, "| 1..65535 | #{backends.port} |", "| 1..65535 | #{backends.port + 2} |"},
       [{@config, :port, :backends}]},
      {"the documented attach directory",
       {@config, "| the role's run folder (`KEEPER_RUN_DIR`) |", "| `#{release.run_dir}` |"},
       [{@config, :pool, :runtime}]},
      # An overlay is read whole, so no blank line, comment or spelling of
      # a key ends the reading early.
      {"the backends overlay publishing a second port after a blank line",
       {backends_overlay, ~s(      - "127.0.0.1::#{backends.port}"\n),
        ~s(      - "127.0.0.1::#{backends.port}"\n\n      - "#{backends.port}"\n)},
       [{backends_overlay, :port, :backends}]},
      {"the backends overlay publishing a second port after a comment",
       {backends_overlay, ~s(      - "127.0.0.1::#{backends.port}"\n),
        ~s(      - "127.0.0.1::#{backends.port}"\n    # and on every interface\n      - "#{backends.port}"\n)},
       [{backends_overlay, :port, :backends}]},
      {"the runtime overlay naming an entrypoint, its key quoted",
       {runtime_overlay, "    pull_policy: never\n    environment:\n",
        ~s(    pull_policy: never\n    "entrypoint": ["cyfr-locus", "serve", "--pool", "#{runtime.pool}:#{first}-#{last}"]\n    environment:\n)},
       [{runtime_overlay, :entrypoint, :runtime}]},
      {"the runtime overlay naming an entrypoint, its key spaced",
       {runtime_overlay, "    pull_policy: never\n    environment:\n",
        ~s(    pull_policy: never\n    entrypoint : ["cyfr-locus", "serve", "--pool", "#{runtime.pool}:#{first}-#{last}"]\n    environment:\n)},
       [{runtime_overlay, :entrypoint, :runtime}]},
      {"the builder's last overlay layering a second service after a comment",
       {builds_last_overlay, "      - no-new-privileges:true\n",
        "      - no-new-privileges:true\n# and the guard too\n  #{release.guard}:\n    security_opt: !override\n      - no-new-privileges:true\n"},
       [{builds_last_overlay, :service, :builds}]},
      # An overlay compose reads otherwise than its parse is no overlay:
      # every reading of it is drift.
      {"the runtime overlay resetting its ports",
       {runtime_overlay, "    ports:\n", "    ports: !reset\n"},
       unread.(runtime_overlay, :runtime)},
      {"the runtime overlay resetting an entrypoint it names",
       {runtime_overlay, "    pull_policy: never\n    environment:\n",
        ~s(    pull_policy: never\n    entrypoint: !reset #{Jason.encode!(keeper_argv(release, roles))}\n    environment:\n)},
       unread.(runtime_overlay, :runtime)},
      {"the runtime overlay replacing compose's service whole",
       {runtime_overlay, "  #{release.service}:\n", "  #{release.service}: !override\n"},
       unread.(runtime_overlay, :runtime)},
      {"the runtime overlay merging an entrypoint",
       {runtime_overlay, "services:\n  #{release.service}:\n",
        "x-unisolated: &unisolated\n  entrypoint: [\"cyfr-locus\"]\nservices:\n  #{release.service}:\n    <<: *unisolated\n"},
       unread.(runtime_overlay, :runtime)},
      {"the runtime overlay behind a document naming an entrypoint",
       {runtime_overlay, "services:\n  #{release.service}:\n",
        "services:\n  #{release.service}:\n    entrypoint: [\"cyfr-locus\"]\n---\nservices:\n  #{release.service}:\n"},
       unread.(runtime_overlay, :runtime)},
      {"the runtime overlay extending a service from another file",
       {runtime_overlay, "    pull_policy: never\n    environment:\n",
        "    pull_policy: never\n    extends:\n      file: unisolated.yml\n      service: #{release.service}\n    environment:\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime overlay including another file",
       {runtime_overlay, "services:\n  #{release.service}:\n",
        "include:\n  - sidecar.yml\nservices:\n  #{release.service}:\n"},
       unread.(runtime_overlay, :runtime)},
      {"the runtime's last overlay naming an entrypoint",
       {runtime_last_overlay, "      - systempaths=unconfined\n",
        "      - systempaths=unconfined\n    entrypoint: [\"cyfr-locus\"]\n"},
       [{runtime_last_overlay, :entrypoint, :runtime}]},
      # Every value an overlay gives is read: one the test does not expect
      # is drift, whatever key carries it.
      {"the runtime overlay telling the runtime another port",
       {runtime_overlay, release_grace,
        release_grace <> "      - LOCUS_RUNTIME_PORT=#{runtime.port + 100}\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime overlay moving the attach directory",
       {runtime_overlay, release_grace,
        release_grace <> "      - LOCUS_RUNTIME_ATTACH_DIR=/tmp/attach\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime overlay giving the runtime the builds key",
       {runtime_overlay, release_grace, release_grace <> "      - LOCUS_BUILDS_KEY=${KEY:-}\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime overlay mounting another program over the release",
       {runtime_overlay, "    pull_policy: never\n    environment:\n",
        "    pull_policy: never\n    volumes:\n      - ./bin/locus:#{release.bin}:ro\n    environment:\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime's last overlay unconfining seccomp",
       {runtime_last_overlay, "      - seccomp=./keeper.seccomp.json\n",
        "      - seccomp=./keeper.seccomp.json\n      - seccomp=unconfined\n      - systempaths=unconfined\n"},
       [{runtime_last_overlay, :service, :runtime}]},
      {"the runtime overlay naming its container after the shipped one",
       {runtime_overlay,
        "  #{release.service}:\n    image: ${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}\n    container_name: !reset null\n",
        "  #{release.service}:\n    image: ${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}\n    container_name: #{release.container}\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime overlay keeping the deployed container name through an untagged null",
       {runtime_overlay,
        "  #{release.service}:\n    image: ${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}\n    container_name: !reset null\n",
        "  #{release.service}:\n    image: ${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}\n    container_name: null\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"the runtime overlay naming its container what stands in for the reset",
       {runtime_overlay,
        "  #{release.service}:\n    image: ${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}\n    container_name: !reset null\n",
        ~s(  #{release.service}:\n    image: ${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}\n    container_name: "!reset null"\n)},
       unread.(runtime_overlay, :runtime)},
      {"the guard under another container name",
       {@compose, "    container_name: #{release.guard_container}\n",
        "    container_name: #{release.container}-guard2\n"}, [{@compose, :service, :release}]}
    ]

    # A text plant replaces one exact text, found once; one that is not
    # answers `:unchanged`, which no plant expects. A table plant runs the
    # shipped texts against a changed table.
    outcomes =
      for {plant, change, _} <- plants do
        outcome =
          case change do
            {path, from, to} when is_binary(path) ->
              text = Map.fetch!(texts, path)

              if length(String.split(text, from)) == 2,
                do:
                  role_drift(Map.put(texts, path, String.replace(text, from, to)), release, roles),
                else: :unchanged

            {planted_release, planted_roles} ->
              role_drift(texts, planted_release, planted_roles)
          end

        {plant, outcome}
      end

    for {{plant, outcome}, {_, _, expected}} <- Enum.zip(outcomes, plants) do
      assert outcome == Enum.sort(expected), "#{plant}: #{inspect(outcome)}"
    end
  end

  test "the release's example names every builds setting, and none of the control plane's" do
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

    # The key reaches the role from the project .env through compose, and
    # the role's bounds are compose's to read there: neither is set in this
    # file, and the example says where each is.
    assert example =~ "CYFR_LOCUS_BUILDS_KEY"
    assert example =~ "LOCUS_BUILDS_MEMORY_LIMIT"

    refute example =~
             ~r/^#? ?(LOCUS_BUILDS_KEY|LOCUS_BUILDS_MEMORY_LIMIT|LOCUS_BUILDS_CPU_LIMIT)=/m

    # No setting of the control plane's is offered here: `Locus.Config`
    # refuses to start with the database, the keyring, the runtime's root
    # or the control plane's builds and backends keys in its environment.
    refute example =~ ~r/^#? ?CYFR_[A-Z_]*=/m
  end

  test "the ports are parameters everywhere, 4000 and 4001 only as their defaults" do
    # CYFR_PORT=8000 must work by setting one variable, and CYFR_PROXY_PORT
    # likewise. A bare 4000 or 4001 outside a default-expansion is a site
    # the variable does not reach — exactly the drift this test exists to
    # refuse.
    for file <- ["docker-compose.yml", "Caddyfile", "Dockerfile"] do
      stripped =
        file
        |> read!()
        |> String.split("\n")
        |> Enum.map(&String.replace(&1, ~r/(^|\s)#.*$/, ""))
        |> Enum.join("\n")

      # A port is the whole number: 4000 inside a uid range such as
      # 40001-49999 is no port.
      bare =
        ~r/(?<!:-)(?<!=)(?<!:)(?<!\d)400[01](?!\d)/
        |> Regex.scan(stripped)
        |> List.flatten()

      assert bare == [], "a bare port outside a default-expansion in #{file}"
    end
  end

  # ==========================================================================
  # The access modes' networks, proxies and ports
  # ==========================================================================

  defp compose!, do: YamlElixir.read_from_string!(read!("docker-compose.yml"))

  # The services on the default network: those that name it, and those
  # that name no network at all, which compose puts on it.
  defp default_members(parsed) do
    for {service, definition} <- parsed["services"],
        (is_nil(definition["networks"]) and is_nil(definition["network_mode"])) or
          "default" in network_names(definition["networks"]),
        do: service
  end

  # The loopback listener's network is cyfr's alone: no proxy, no island
  # and no guard reaches it, so what reaches it is the host's published
  # loopback port. A service that names no network joins it as surely as
  # one that names it.
  test "the default network carries cyfr alone, by name, and no service joins it by naming none" do
    parsed = compose!()

    assert LocusRoles.release().endpoint_network == "default"
    assert default_members(parsed) == ["cyfr"]
    assert "default" in network_names(parsed["services"]["cyfr"]["networks"])

    # A service that names no network is found on it.
    planted = put_in(parsed, ["services", "planted"], %{"image" => "planted:latest"})
    assert Enum.sort(default_members(planted)) == ["cyfr", "planted"]

    attached = put_in(planted, ["services", "planted", "networks"], ["default"])
    assert Enum.sort(default_members(attached)) == ["cyfr", "planted"]

    elsewhere = put_in(planted, ["services", "planted", "networks"], ["edge"])
    assert default_members(elsewhere) == ["cyfr"]
  end

  test "edge carries cyfr's proxy listener, Caddy and Tailscale at the role table's addresses" do
    parsed = compose!()
    release = LocusRoles.release()
    services = parsed["services"]

    on_edge =
      for {service, definition} <- services,
          release.edge_network in network_names(definition["networks"]),
          into: %{},
          do: {service, definition["networks"][release.edge_network]}

    assert on_edge == %{
             "cyfr" => %{"ipv4_address" => release.edge_address},
             "caddy" => %{"ipv4_address" => release.edge_caddy_address},
             "tailscale" => %{"ipv4_address" => release.edge_tailscale_address}
           }

    for address <- [release.edge_caddy_address, release.edge_tailscale_address] do
      assert_fixed_address(release.edge_subnet, release.edge_ip_range, address)
    end

    # Each proxy is on edge alone, so it reaches cyfr's proxy listener and
    # nothing else of the stack.
    for proxy <- ["caddy", "tailscale"] do
      assert network_names(services[proxy]["networks"]) == [release.edge_network], proxy
    end

    # cyfr trusts the forwarded headers of those two addresses alone, and
    # its proxy listener is exposed on edge and never published.
    environment = services["cyfr"]["environment"]

    assert ("CYFR_TRUSTED_PROXY_CIDRS=${CYFR_TRUSTED_PROXY_CIDRS:-" <>
              "#{release.edge_caddy_address},#{release.edge_tailscale_address}}") in environment

    assert "${CYFR_PROXY_PORT:-4001}" in services["cyfr"]["expose"]
  end

  # The loopback listener's address is the compose file's to assert, and
  # every access setting reaches cyfr from .env through env_file
  # alone: an `environment:` entry here would be a second, unchecked
  # source of the home's access settings.
  @head_keys ~w(CYFR_ACCESS CYFR_HOST CYFR_PORT CYFR_PUBLIC_URL CYFR_TAILNET_NODE_ID
                CADDY_ACME_EMAIL)

  test "cyfr asserts its loopback listener's address, and takes its access settings from .env alone" do
    cyfr = compose!()["services"]["cyfr"]
    release = LocusRoles.release()

    assert "CYFR_BIND_ADDRESS=#{release.endpoint_address}" in cyfr["environment"]
    assert "CYFR_LOCAL_INGRESS_ASSERTED=true" in cyfr["environment"]
    assert cyfr["env_file"] == [".env"]

    assigned = for entry <- cyfr["environment"], do: entry |> String.split("=", parts: 2) |> hd()
    assert Enum.filter(assigned, &(&1 in @head_keys)) == []
  end

  test "the tailscale service is Serve in userspace, its identity and its configuration its own" do
    parsed = compose!()
    tailscale = parsed["services"]["tailscale"]

    assert tailscale["profiles"] == ["tailnet"]
    assert tailscale["image"] =~ ~r/\Atailscale\/tailscale:v[0-9.]+@sha256:[0-9a-f]{64}\z/

    assert Enum.sort(tailscale["environment"]) ==
             Enum.sort([
               "TS_USERSPACE=true",
               "TS_STATE_DIR=/var/lib/tailscale",
               "TS_AUTH_ONCE=true",
               "TS_ACCEPT_DNS=false",
               "TS_SOCKS5_SERVER=:1055",
               "TS_SOCKET=/var/run/tailscale/tailscaled.sock",
               "TS_SERVE_CONFIG=/serve/serve.json"
             ])

    # The machine's identity in a volume of its own, and Serve's
    # configuration a read-only directory, so containerboot sees the file
    # change.
    assert tailscale["volumes"] == [
             "tailscale_state:/var/lib/tailscale",
             "./.cyfr/tailscale-serve:/serve:ro"
           ]

    assert Map.has_key?(parsed["volumes"], "tailscale_state")
    assert tailscale["healthcheck"]["test"] == ["CMD", "tailscale", "status"]

    assert tailscale["ports"] == ["127.0.0.1:1055:1055"]

    # The proxy needs no added capability, device or host network.
    for key <- ~w(cap_add devices privileged network_mode) do
      refute Map.has_key?(tailscale, key), "tailscale sets #{key}"
    end

    # No other service mounts the identity or the project's state, so
    # nothing cyfr can write reaches Serve's configuration.
    for {service, definition} <- parsed["services"],
        service != "tailscale",
        volume <- List.wrap(definition["volumes"]) do
      refute volume =~ ~r/tailscale|\.cyfr/, "#{service} mounts #{volume}"
    end
  end

  # What a selection of profiles starts publishes on the host: the
  # loopback listener on the host's loopback alone in every mode, the
  # sidecar's SOCKS5 on loopback in tailnet, and Caddy's public 80 and 443.
  defp published(parsed, profiles) do
    for {service, definition} <- parsed["services"],
        definition["profiles"] in [nil, []] or
          Enum.any?(definition["profiles"], &(&1 in profiles)),
        port <- List.wrap(definition["ports"]),
        do: {service, port}
  end

  test "each mode publishes its loopback listeners, and public 80 and 443" do
    parsed = compose!()
    loopback = [{"cyfr", "127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}"}]
    caddy = [{"caddy", "80:80"}, {"caddy", "443:443"}, {"caddy", "443:443/udp"}]
    kiosk = [{"tailscale", "127.0.0.1:1055:1055"}]

    for {profiles, expected} <- [
          {[], loopback},
          {["tailnet"], loopback ++ kiosk},
          {["public"], loopback ++ caddy}
        ] do
      assert Enum.sort(published(parsed, profiles)) == Enum.sort(expected), inspect(profiles)
    end

    assert parsed["services"]["caddy"]["profiles"] == ["public"]
  end

  # A probe that runs the binary (`caddy version`) passes in a container
  # whose server has stopped; the admin API answers only from a running
  # caddy, with the config it loaded.
  test "caddy's healthcheck asks the running server for its loaded config" do
    caddy = compose!()["services"]["caddy"]

    assert caddy["healthcheck"]["test"] ==
             ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:2019/config/"]

    refute read!("Caddyfile") =~ ~r/^\s*admin\s+off\b/m
  end

  # The firewall paragraph names defaults for each mode. Read its port
  # claims and compare them with Compose's own profile selection, so a
  # published binding cannot silently drift away from the operator's guide.
  defp readme_ports(readme) do
    pattern =
      ~r/^- Firewall: \*\*public\*\* opens (.*?)\. In every mode CYFR publishes `(\d+)\/tcp` on `([^`]+)` only .*?With \*\*tailnet\*\* access, CYFR also publishes SOCKS5 `(\d+)\/tcp` on `([^`]+)` only/m

    case Regex.run(pattern, readme) do
      [_, public, port, address, kiosk_port, kiosk_address] ->
        loopback = [{"cyfr", "#{address}:#{port}:#{port}"}]
        kiosk = [{"tailscale", "#{kiosk_address}:#{kiosk_port}:1055"}]

        caddy =
          for [port, protocol] <-
                Regex.scan(~r/`(\d+)\/(tcp|udp)`/, public, capture: :all_but_first) do
            suffix = if protocol == "tcp", do: "", else: "/#{protocol}"
            {"caddy", "#{port}:#{port}#{suffix}"}
          end

        %{[] => loopback, ["tailnet"] => loopback ++ kiosk, ["public"] => loopback ++ caddy}

      _ ->
        nil
    end
  end

  defp readme_ports_hold?(readme, parsed) do
    case readme_ports(readme) do
      nil ->
        false

      modes ->
        Enum.all?(modes, fn {profiles, expected} ->
          actual =
            for {service, port} <- published(parsed, profiles) do
              {service, Regex.replace(~r/\$\{[A-Z_]+:-([^}]+)\}/, port, "\\1")}
            end

          Enum.sort(actual) == Enum.sort(expected)
        end)
    end
  end

  test "README's firewall paragraph agrees with every mode's published ports and finds drift" do
    readme = read!("README.md")
    parsed = compose!()
    assert map_size(readme_ports(readme)) == 3
    assert readme_ports_hold?(readme, parsed)

    for {before, after_text} <- [
          {"SOCKS5 `1055/tcp`", "SOCKS5 `1056/tcp`"},
          {"on `127.0.0.1` only", "on `0.0.0.0` only"},
          {" (+ `443/udp` for HTTP/3)", ""},
          {"CYFR publishes `4000/tcp`", "CYFR publishes `4002/tcp`"}
        ] do
      planted = String.replace(readme, before, after_text)
      refute planted == readme
      refute readme_ports_hold?(planted, parsed), before
    end

    for binding <- [
          "0.0.0.0:1055:1055",
          "127.0.0.1:1056:1055",
          "127.0.0.1:1055:1056",
          "127.0.0.1:1055:1055/udp"
        ] do
      planted = put_in(parsed, ["services", "tailscale", "ports"], [binding])
      refute readme_ports_hold?(readme, planted), binding
    end

    refute readme_ports_hold?(readme, put_in(parsed, ["services", "tailscale", "ports"], []))
  end

  # The image's health check asks the loopback listener where a bare
  # release binds it by default, the access settings' own default listener, and
  # where compose binds it, by the variable compose sets.
  test "the image's health check asks the loopback listener at the access settings' default address" do
    dockerfile = read!("Dockerfile")

    defaults =
      Path.join(@root, "tests/fixtures/access_modes.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("boot")
      |> Enum.find(&(&1["name"] == "local, defaults"))

    ["127.0.0.1" = address, 4000 = port] = defaults["access"]["listeners"]["loopback"]

    assert dockerfile =~ ~s|addr="${CYFR_BIND_ADDRESS:-#{address}}"|
    assert dockerfile =~ ~s|curl -f "http://$addr:${CYFR_PORT:-#{port}}/api/health/ready"|
  end

  test "the image carries the seed tree and the release reads it there" do
    # A bare image boot (no host bind mount) must still be able to provision
    # an athanor from its seed: the bundle rides in the image inside the seed
    # tree (CYFR_SEED_PATH), and each athanor's copy is taken from it at
    # provisioning.
    dockerfile = read!("Dockerfile")
    dockerignore = read!(".dockerignore")

    assert dockerfile =~ ~r/^COPY seed\/components\/ \/app\/seed\/components\/$/m
    assert dockerfile =~ ~r/^ENV CYFR_SEED_PATH=\/app\/seed$/m

    # A checkout's runtime data stays out of the build context.
    assert dockerignore =~ ~r/^data\/$/m
  end

  test "the Aqua template is the second seed root, and WIT is embedded" do
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
    crew = Compendium.AquaPath.crew_dirname()

    code =
      entrypoint
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")

    assert code =~ "[ ! -f /app/seed/aqua/#{soul} ]"
    assert File.regular?(Path.join(@root, "seed/aqua/#{soul}"))
    # The template ships the soul and its scrolls, and no crew member.
    refute File.exists?(Path.join(@root, "seed/aqua/#{crew}"))

    # Prima.WIT embeds the WIT tree at compile time, so the builder stage
    # carries it.
    stages = String.split(dockerfile, ~r/^FROM /m)
    builder = Enum.find(stages, &String.contains?(&1, "AS builder"))

    assert builder =~ ~r/^COPY wit\/ wit\/$/m
  end

  test "the env template names every worker knob" do
    env = read!(".env.example")

    for knob <-
          ~w(CYFR_LOCUS_RUNTIME_ROOT LOCUS_RUNTIME_SERVICE_ID LOCUS_RUNTIME_KEY LOCUS_RUNTIME_HOST_API_URL CYFR_LOCUS_RUNTIME_WORKERS CYFR_HOST_API_BIND CYFR_HOST_API_PORT) do
      assert env =~ ~r/^#? ?#{knob}=/m, "#{knob} is missing from .env.example"
    end

    # Compose sets the runtime's variables in Locus's environment, over
    # anything .env.locus sets: the three it interpolates from the project
    # .env are documented in .env.example above, and the two it fixes in
    # integration-guide.md's section on running a worker outside Compose.
    # .env.locus.example documents none of them, and says where they are.
    environment =
      for entry <- compose!()["services"][LocusRoles.release().service]["environment"],
          String.starts_with?(entry, "LOCUS_RUNTIME_"),
          not String.contains?(entry, "_LIMIT="),
          do: entry

    assert environment == [
             "LOCUS_RUNTIME_KEY=${LOCUS_RUNTIME_KEY:-}",
             "LOCUS_RUNTIME_SERVICE_ID=${LOCUS_RUNTIME_SERVICE_ID:-wrk_locus}",
             "LOCUS_RUNTIME_HOST_API_URL=${LOCUS_RUNTIME_HOST_API_URL:-http://cyfr:${CYFR_HOST_API_PORT:-4300}}",
             "LOCUS_RUNTIME_BIND=0.0.0.0",
             "LOCUS_RUNTIME_PORT=#{LocusRoles.role!(:runtime).port}"
           ]

    set = for entry <- environment, do: entry |> String.split("=", parts: 2) |> hd()
    example = read!(".env.locus.example")

    for knob <- set do
      refute example =~ ~r/^#? ?#{knob}=/m, "#{knob} is documented in .env.locus.example"
    end

    assert example =~ "project .env"

    guide = read!("integration-guide.md")
    assert guide =~ ~r/^\| `LOCUS_RUNTIME_BIND` \|/m and guide =~ ~r/^\| `LOCUS_RUNTIME_PORT` \|/m

    refute example =~ ~r/CYFR_LOCUS_RUNTIME_ROOT|CYFR_DATABASE_UR[L]|CYFR_CRYPTO_KEYRIN[G]=/
  end

  test "the compose file's profiles are public and tailnet" do
    services = YamlElixir.read_from_string!(read!("docker-compose.yml"))

    profiles =
      for {_service, definition} <- services["services"],
          profile <- List.wrap(definition["profiles"]),
          uniq: true,
          do: profile

    assert Enum.sort(profiles) == ["public", "tailnet"]
  end
end
