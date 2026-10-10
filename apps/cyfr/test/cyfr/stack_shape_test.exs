# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.StackShapeTest do
  @moduledoc """
  The shipped stack is one origin: every request Caddy takes reaches cyfr's
  one endpoint, and compose runs cyfr, the Locus runtime, the Locus
  backends service and (optionally) caddy and the Locus builds service —
  nothing else. Read the files, assert the shape; the same style as the
  ingress inventory.

  Two readings of docker-compose.yml serve the tests. The tests of the
  Locus services' hardening and `role_drift/3` parse the file whole: the
  `x-locus-role` block the services share, and each service as compose
  runs it, that block merged under the service's own keys
  (`merged_services/1`). Every other test reads a service's own lines
  (`service_block/2`, `list_entries/2`), which resolve no merge.
  `role_drift/3` parses the image suites' overlays whole (`overlay/1`) and
  holds each to the one mapping written here (`expected_overlays/2`).

  Every fact of a Locus role is the role table's (`Prima.LocusRoles`): a
  test here reads the table where it would spell one, and `role_drift/3`
  holds every other spelling to it, wherever it is — Dockerfile.locus's
  users, entrypoint and ports, compose's Locus services, the image suites'
  overlays, Locus's own pool names, isolation, attach directory and
  listener ports, and the image suites, whose harnesses read the table's
  vector file.
  """
  use ExUnit.Case, async: true

  alias Prima.LocusRoles

  @root Path.expand("../../../..", __DIR__)

  @locus_services Enum.map(LocusRoles.roles(), & &1.service)

  # The keys every Locus service takes from `x-locus-role`.
  @role_keys ~w(init cap_drop cap_add security_opt read_only ipc restart logging)

  # The hardening every Locus service runs under, and each role's own
  # security options; its tmpfs mounts are the table's (`tmpfs/2`).
  @shared_hardening %{
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

  @security_opt %{
    builds: ["no-new-privileges:true", "writable-cgroups=true"],
    backends: ["no-new-privileges:true", "writable-cgroups=true"],
    runtime: ["no-new-privileges:true", "writable-cgroups=true", "seccomp=./keeper.seccomp.json"]
  }

  # Keys that would hand a Locus service the host's privileges, namespaces,
  # devices or storage.
  @forbidden_keys ~w(privileged pid userns_mode cgroup devices volumes)

  # The files that spell a role's facts, beside docker-compose.yml and the
  # Locus image.
  @dockerfile "Dockerfile.locus"
  @compose "docker-compose.yml"
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

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  # A merge key, as YamlElixir names it: `<<` and a counter.
  defp merge_key?({key, _}), do: String.starts_with?(key, "<<")

  # Each service of a compose text as compose runs it: the one mapping it
  # merges, under the service's own keys, which win. A merge copies keys
  # and never joins lists, so a list the service sets replaces the merged
  # one whole.
  defp merged_services(compose) do
    for {service, definition} <- YamlElixir.read_from_string!(compose)["services"],
        into: %{} do
      {merges, own} = Enum.split_with(definition, &merge_key?/1)

      merged =
        case merges do
          [] -> Map.new(own)
          [{_, role}] -> Map.merge(role, Map.new(own))
        end

      {service, merged}
    end
  end

  # A role's tmpfs mounts as the table spells them: its homes, then the
  # release's run directory, owned by the release's user.
  defp tmpfs(release, role) do
    [
      "#{release.home_root}:mode=1733,exec,size=#{role.home_size}",
      "#{release.run_dir}:uid=#{release.uid},gid=#{release.uid},mode=0700,size=#{release.run_size}"
    ]
  end

  defp service_hardening(release, role) do
    Map.merge(@shared_hardening, %{
      "security_opt" => Map.fetch!(@security_opt, role.name),
      "tmpfs" => tmpfs(release, role)
    })
  end

  # The `{service, key}` pairs, sorted, where a Locus service of a compose
  # text runs without its hardening: a value other than the shipped one, a
  # key it must not have, or no memory limit.
  defp hardening_violations(compose) do
    services = merged_services(compose)
    release = LocusRoles.release()

    Enum.sort(
      for role <- LocusRoles.roles(),
          merged = Map.get(services, role.service, %{}),
          violation <- service_violations(merged, service_hardening(release, role)),
          do: {role.service, violation}
    )
  end

  defp service_violations(merged, expected) do
    wrong = for {key, value} <- expected, Map.get(merged, key) != value, do: key
    forbidden = for key <- @forbidden_keys, Map.has_key?(merged, key), do: key

    unbounded =
      case merged do
        %{"deploy" => %{"resources" => %{"limits" => %{"memory" => memory}}}}
        when memory not in [nil, ""] ->
          []

        _ ->
          ["deploy.resources.limits.memory"]
      end

    wrong ++ forbidden ++ unbounded
  end

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

  # A role's uid pool as cyfr-locus takes it: `<pool>:<first>-<last>`, and
  # `:<isolation>` where the role isolates its spawns.
  defp pool_spec(role),
    do:
      Enum.join(
        [role.pool, "#{role.uids.first}-#{role.uids.last}" | List.wrap(role.isolation)],
        ":"
      )

  # The command that serves a role: cyfr-locus over the role's pool,
  # starting the release as its user.
  defp keeper_argv(release, role) do
    ["cyfr-locus", "serve", "--pool", pool_spec(role), "--home-root", release.home_root] ++
      ["--client-user", release.user, "--", release.bin, "start"]
  end

  # The one entrypoint line of a service's block, decoded.
  defp entrypoint(block) do
    [json] = Regex.run(~r/^    entrypoint: (\[.*\])$/m, block, capture: :all_but_first)
    Jason.decode!(json)
  end

  # ————— the role table, and every spelling of it —————

  # Every file `role_drift/3` reads, by its path from the checkout's root.
  defp shipped_texts do
    overlays = Map.keys(expected_overlays(LocusRoles.release(), LocusRoles.roles()))
    suites = for {_name, {dir, _harness}} <- @suites, path <- wildcard("#{dir}/*.py"), do: path

    paths =
      [@dockerfile, @compose | overlays] ++
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
  # - `:users`: Dockerfile.locus's pooled users and the release's user,
  #   group and directories.
  # - `:entrypoint`: the image's entrypoint (the image's role), each
  #   other role's compose entrypoint, and each overlay's entrypoint.
  # - `:network`: a service's networks are its own alone, cyfr joins it,
  #   and it is declared.
  # - `:tmpfs`: a service's mounts.
  # - `:port`: what a service exposes, its health probe (each role's but
  #   the image's, which takes the image's probe), cyfr's address for it,
  #   the port it is told to listen on, the image's port arguments and
  #   probe, the overlays' published ports, and `Locus.Config`'s listener
  #   defaults, answered and documented.
  # - `:service`: a service's container name and profile, and everything
  #   else an overlay layers: its one service and every other key it gives
  #   it (`overlay_drift/3`).
  # - `:suite`: an image suite that spells a fact of its role or the
  #   release, or a harness that reads no vector file.
  # - `:pool`: Locus's own pool names, isolation and attach directory,
  #   its `--pool` arguments, and the documented attach directory.
  defp role_drift(texts, release, roles) do
    compose = Map.fetch!(texts, @compose)
    services = merged_services(compose)

    Enum.sort(
      Enum.uniq(
        users_drift(Map.fetch!(texts, @dockerfile), release, roles) ++
          entrypoint_drift(texts, services, release, roles) ++
          network_drift(compose, services, roles) ++
          tmpfs_drift(services, release, roles) ++
          port_drift(texts, services, release, roles) ++
          service_drift(services, roles) ++
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

  defp users_drift(dockerfile, release, roles) do
    loops = user_loops(dockerfile)
    %{user: user, uid: uid, home_root: home_root, run_dir: run_dir} = release
    uid = Integer.to_string(uid)

    pools =
      for role <- roles,
          {role.user_prefix, role.uids} not in loops,
          do: {@dockerfile, :users, role.name}

    release_spelled? =
      Regex.scan(~r/\bgroupadd -r -g (\d+) (\S+)/, dockerfile, capture: :all_but_first) ==
        [[uid, user]] and
        Regex.scan(~r/\buseradd -r -u (\d+) -g (\S+) .* (\S+) \\$/m, dockerfile,
          capture: :all_but_first
        ) == [[uid, user, user]] and
        Regex.scan(~r/\binstall -d -m (\d+) -o (\S+) -g (\S+) (\S+)/, dockerfile,
          capture: :all_but_first
        ) == [["1733", "root", "root", home_root], ["0700", user, user, run_dir]] and
        Regex.scan(~r/\bRELEASE_TMP=(\S+)/, dockerfile, capture: :all_but_first) == [[run_dir]]

    if release_spelled?, do: pools, else: [{@dockerfile, :users, :release} | pools]
  end

  defp entrypoint_drift(texts, services, release, roles) do
    image_role = role(roles, release.image_role)

    image =
      case Regex.run(~r/^ENTRYPOINT (\[.*\])$/m, Map.fetch!(texts, @dockerfile),
             capture: :all_but_first
           ) do
        [json] -> decode(json)
        nil -> nil
      end

    composed =
      for role <- roles,
          not compose_entrypoint?(
            Map.get(services, role.service, %{}),
            release,
            role,
            image_role
          ),
          do: {@compose, :entrypoint, role.name}

    if(image == keeper_argv(release, image_role),
      do: [],
      else: [{@dockerfile, :entrypoint, image_role.name}]
    ) ++ composed
  end

  # The image's role may take the image's entrypoint; every other role's
  # service names its own.
  defp compose_entrypoint?(service, release, role, image_role) do
    case service["entrypoint"] do
      nil -> role.name == image_role.name
      argv -> argv == keeper_argv(release, role)
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp network_drift(compose, services, roles) do
    declared = Map.keys(YamlElixir.read_from_string!(compose)["networks"] || %{})
    cyfr = List.wrap(get_in(services, ["cyfr", "networks"]))

    for role <- roles,
        get_in(services, [role.service, "networks"]) != [role.network] or
          role.network not in cyfr or role.network not in declared,
        do: {@compose, :network, role.name}
  end

  defp tmpfs_drift(services, release, roles) do
    for role <- roles,
        get_in(services, [role.service, "tmpfs"]) != tmpfs(release, role),
        do: {@compose, :tmpfs, role.name}
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
    {:ok, runtime} = Locus.Config.runtime_from_env(&Map.get(env, &1), [])
    %{builds: settings[:port], backends: settings[:backends_port], runtime: runtime[:port]}
  end

  defp port_drift(texts, services, release, roles) do
    dockerfile = Map.fetch!(texts, @dockerfile)
    image_role = role(roles, release.image_role)
    cyfr = List.wrap(get_in(services, ["cyfr", "environment"]))
    defaults = listener_defaults()

    image_probe =
      if Regex.scan(~r/localhost:\$\{([A-Z_]+):-(\d+)\}/, dockerfile, capture: :all_but_first) ==
           [[port_variable(image_role), "#{image_role.port}"]],
         do: [],
         else: [{@dockerfile, :port, image_role.name}]

    config = Map.fetch!(texts, @config)

    image_probe ++
      for role <- roles,
          {path, spelled?} <- [
            {@dockerfile,
             Regex.scan(~r/^ARG #{port_variable(role)}=(\S+)$/m, dockerfile,
               capture: :all_but_first
             ) == [["#{role.port}"]]},
            {@compose,
             compose_ports?(Map.get(services, role.service, %{}), cyfr, role, image_role)},
            {@config,
             defaults[role.name] == role.port and
               documented_default(config, port_variable(role)) == "#{role.port}"}
          ],
          not spelled?,
          do: {path, :port, role.name}
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

  # A service exposes its port alone, probes its health there, is told to
  # listen there where compose tells it, and cyfr reaches it there. Its
  # probe names exactly one `localhost:<port>`; only the image's role may
  # have no healthcheck, taking the image's own, and none disables it.
  defp compose_ports?(service, cyfr, role, image_role) do
    port = "#{role.port}"
    variable = port_variable(role)

    probed? =
      case service["healthcheck"] do
        nil ->
          role.name == image_role.name

        %{"test" => test} = check ->
          check["disable"] != true and
            test |> List.wrap() |> Enum.join(" ") |> then(&Regex.scan(~r/localhost(?::\d+)?/, &1)) ==
              [["localhost:#{port}"]]

        _check ->
          false
      end

    told =
      for entry <- List.wrap(service["environment"]),
          String.starts_with?(entry, variable <> "="),
          do: String.replace_prefix(entry, variable <> "=", "")

    address = ~r{http://#{Regex.escape(role.service)}:(\d+)}

    reached =
      for entry <- cyfr, [value] <- Regex.scan(address, entry, capture: :all_but_first), do: value

    service["expose"] == [port] and probed? and Enum.all?(told ++ reached, &(&1 == port))
  end

  # Each overlay as the image suites write it, whole: the role it layers,
  # and the one service it gives keys to with every key and value. A value
  # that is a fact of the table comes from the table; the rest is written
  # here, so a change to an overlay is a change to this test.
  defp expected_overlays(release, roles) do
    [runtime, builds, backends] = Enum.map([:runtime, :builds, :backends], &role(roles, &1))

    %{
      "tests/builder-image/compose.locus-builds.yml" =>
        {:builds,
         %{
           builds.service => %{
             "image" => "${BUILDER_IMAGE:?set BUILDER_IMAGE}",
             "container_name" => nil,
             "pull_policy" => "never",
             "ports" => ["127.0.0.1::#{builds.port}"],
             "volumes" => ["${CANARY_DIR:?set CANARY_DIR}:/canary:ro"],
             "entrypoint" => chosen_pool_argv(release, builds, "BUILD_POOL"),
             "environment" => ["LOCUS_BUILDS_TIMEOUT_MS=${LOCUS_BUILDS_TIMEOUT_MS:-}"]
           }
         }},
      "tests/locus-backends-image/compose.locus-backends.yml" =>
        {:backends,
         %{
           backends.service => %{
             "image" => "${BACKENDS_IMAGE:?set BACKENDS_IMAGE}",
             "container_name" => nil,
             "pull_policy" => "never",
             "ports" => ["127.0.0.1::#{backends.port}"],
             "volumes" => [
               "${PROBE_DIR:?set PROBE_DIR}:/probe:ro",
               "${CANARY_DIR:?set CANARY_DIR}:/canary:ro"
             ],
             "entrypoint" => chosen_pool_argv(release, backends, "BACKENDS_POOL"),
             "environment" => ["LOCUS_BACKENDS_MEMORY_BYTES=${LOCUS_BACKENDS_MEMORY_BYTES:-}"]
           }
         }},
      # The runtime's suites take compose's entrypoint: the overlay names none.
      "tests/locus-runtime-image/compose.locus-runtime.yml" =>
        {:runtime,
         %{
           runtime.service => %{
             "image" => "${LOCUS_RUNTIME_IMAGE:?set LOCUS_RUNTIME_IMAGE}",
             "pull_policy" => "never",
             "container_name" => nil,
             "ports" => ["127.0.0.1::#{runtime.port}"],
             "extra_hosts" => ["host.docker.internal:host-gateway"],
             "environment" => [
               "LOCUS_RUNTIME_POOL_SIZE=${LOCUS_RUNTIME_POOL_SIZE:?set LOCUS_RUNTIME_POOL_SIZE}",
               "LOCUS_RUNTIME_IDLE_TTL_MS=${LOCUS_RUNTIME_IDLE_TTL_MS:?set LOCUS_RUNTIME_IDLE_TTL_MS}",
               "LOCUS_RUNTIME_WATCHDOG_GRACE_MS=${LOCUS_RUNTIME_WATCHDOG_GRACE_MS:?set LOCUS_RUNTIME_WATCHDOG_GRACE_MS}",
               "LOCUS_RUNTIME_RELEASE_GRACE_MS=${LOCUS_RUNTIME_RELEASE_GRACE_MS:?set LOCUS_RUNTIME_RELEASE_GRACE_MS}"
             ]
           }
         }},
      # The overlays a role's suites layer last, without writable cgroups:
      # the role's own security options but that one.
      "tests/builder-image/compose.no-writable-cgroups.yml" =>
        {:builds,
         %{
           builds.service => %{
             "security_opt" => @security_opt.builds -- ["writable-cgroups=true"]
           }
         }},
      "tests/locus-runtime-image/compose.no-writable-cgroups.yml" =>
        {:runtime,
         %{
           runtime.service => %{
             "security_opt" => @security_opt.runtime -- ["writable-cgroups=true"]
           }
         }}
    }
  end

  # The keeper's command for a role whose suite chooses its pool's uids
  # through `variable`: `<pool>:${VARIABLE:?set VARIABLE}[:<isolation>]`.
  defp chosen_pool_argv(release, role, variable) do
    spec =
      Enum.join([role.pool, "${#{variable}:?set #{variable}}" | List.wrap(role.isolation)], ":")

    List.replace_at(keeper_argv(release, role), 3, spec)
  end

  # Where an overlay differs from the one expected: `:port` for its
  # service's ports, `:entrypoint` for its entrypoint, `:service` for any
  # other service, key or value; all three where it is not an overlay
  # (`overlay/1`).
  defp overlay_drift(texts, release, roles) do
    for {path, {name, expected}} <- expected_overlays(release, roles),
        kind <- overlay_differences(Map.fetch!(texts, path), expected),
        do: {path, kind, name}
  end

  defp overlay_differences(text, expected) do
    [{service, want}] = Map.to_list(expected)

    case overlay(text) do
      {:ok, %{"services" => services}} ->
        got =
          case Map.get(services, service) do
            %{} = got -> got
            _ -> %{}
          end

        for {kind, differs?} <- [
              entrypoint: got["entrypoint"] != want["entrypoint"],
              port: got["ports"] != want["ports"],
              service:
                Map.keys(services) != [service] or
                  Map.drop(got, ~w(entrypoint ports)) != Map.drop(want, ~w(entrypoint ports))
            ],
            differs?,
            do: kind

      :error ->
        [:entrypoint, :port, :service]
    end
  end

  # An overlay parsed whole, in the one shape the image suites write and
  # the parse reads as compose does: `{:ok, overlay}`, or `:error` for any
  # other shape. It is one document holding a `services` mapping alone,
  # with no merge key, and compose's merge tags appear only as a service's
  # `container_name: !reset null` and `security_opt: !override` over a
  # list, read as the values they tag. YamlElixir refuses every other tag;
  # it reads only the last of several documents and resolves no merge;
  # compose reads `!reset` with a value, or `!override` on a mapping,
  # otherwise than as the value; and a top-level key such as `include`
  # brings in what no parse of this text holds.
  defp overlay(text) do
    untagged =
      text
      |> String.replace(~r/^(    container_name: )!reset (null)$/m, "\\1\\2")
      |> String.replace(~r/^(    security_opt: )!override$/m, "\\1")

    with {:ok, [%{"services" => %{}} = overlay]} <- YamlElixir.read_all_from_string(untagged),
         [] <- Map.keys(overlay) -- ["services"],
         false <- merge_key_in?(overlay) do
      {:ok, overlay}
    else
      _ -> :error
    end
  end

  defp merge_key_in?(%{} = map),
    do: Enum.any?(map, fn {key, value} -> merge_name?(key) or merge_key_in?(value) end)

  defp merge_key_in?(list) when is_list(list), do: Enum.any?(list, &merge_key_in?/1)
  defp merge_key_in?(_value), do: false

  defp merge_name?(key), do: is_binary(key) and String.starts_with?(key, "<<")

  defp service_drift(services, roles) do
    for role <- roles,
        service = Map.get(services, role.service, %{}),
        service["container_name"] != role.container or
          service["profiles"] != if(role.profile, do: [role.profile]),
        do: {@compose, :service, role.name}
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
          Enum.any?(spellings(release, role(roles, name)), &Regex.match?(&1, text)),
        do: {path, :suite, name}
  end

  # Where a suite spells a fact of its role or of the release: a number
  # (`_` allowed between its digits) or a path anywhere; a name as a whole
  # string literal, other than the directory `apps/locus` as a joined
  # path's segments; the pool as a spawn's or a pool argument's, the
  # users' prefix as a pooled user's name and the isolation as a pool
  # argument's.
  defp spellings(release, role) do
    numbers = [release.uid, role.port, role.uids.first - 1 | Enum.to_list(role.uids)]
    paths = [release.bin, release.home_root, release.run_dir]

    names =
      [role.user_prefix, role.service, role.container, role.network, role.profile] ++
        [role.isolation, role.home_size, release.run_size, release.user]

    pool = Regex.escape(role.pool)

    Enum.map(numbers, fn number ->
      digits = number |> Integer.to_string() |> String.graphemes() |> Enum.join("_?")
      ~r/(?<![\w.])#{digits}(?!\w)/
    end) ++
      Enum.map(paths, fn path -> ~r/(?<![\w.\/-])#{Regex.escape(path)}(?![\w-])/ end) ++
      for(name <- names, name != nil, do: ~r/(?<!["']apps["'], )["']#{Regex.escape(name)}["']/) ++
      [
        ~r/(?<![\w-])#{pool}:(?=[\d{$])/,
        ~r/["']pool["']\s*:\s*["']#{pool}["']/,
        ~r/(?<![\w-])#{Regex.escape(role.user_prefix)}(?=[\d{%])/
      ] ++ if(role.isolation, do: [~r/:#{Regex.escape(role.isolation)}(?![\w-])/], else: [])
  end

  # A module of Locus's is a role's when it lies in the directory named for
  # the role, and the image's role's otherwise.
  defp lib_role(path, release, roles) do
    [dir | _] = path |> String.replace_prefix("#{@locus_lib}locus/", "") |> Path.split()
    Enum.find(roles, &(Atom.to_string(&1.name) == dir)) || role(roles, release.image_role)
  end

  @lib_spellings [
    pool: ~r/^\s*@pool "([^"]*)"/m,
    pool_argument: ~r/--pool[\s=]+([A-Za-z0-9_-]+):/,
    isolation: ~r/^\s*@isolation "([^"]*)"/m,
    attach_dir: ~r/(?:@attach_dir |\battach_dir: )"([^"]*)"/
  ]

  # The variable whose documented default is the release's run directory.
  @attach_variable "LOCUS_RUNTIME_ATTACH_DIR"

  defp pool_drift(texts, release, roles) do
    spelled =
      for {path, text} <- texts,
          String.starts_with?(path, @locus_lib),
          role = lib_role(path, release, roles),
          {kind, pattern} <- @lib_spellings,
          [value] <- Regex.scan(pattern, text, capture: :all_but_first),
          do: {path, role, kind, value}

    expected = fn
      :pool, role -> role.pool
      :pool_argument, role -> role.pool
      :isolation, role -> role.isolation
      :attach_dir, _role -> release.run_dir
    end

    # `Locus.Config` documents the attach directory's default for the role
    # whose variable it is.
    documented =
      for role <- roles,
          @attach_variable in Locus.Config.variables(role.name),
          documented_default(Map.fetch!(texts, @config), @attach_variable) !=
            "`#{release.run_dir}`",
          do: {@config, :pool, role.name}

    wrong =
      for {path, role, kind, value} <- spelled,
          value != expected.(kind, role),
          do: {path, :pool, role.name}

    # A role's modules name its pool, and its isolation where it has one.
    unspelled =
      for role <- roles,
          kind <- [:pool | if(role.isolation, do: [:isolation], else: [])],
          not Enum.any?(spelled, &match?({_, ^role, ^kind, _}, &1)),
          do: {@locus_lib, :pool, role.name}

    wrong ++ unspelled ++ documented
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

  test "compose runs cyfr, locus-runtime, locus-backends, locus-builds and caddy — one web origin" do
    compose = read!("docker-compose.yml")
    runtime = LocusRoles.role!(:runtime)
    backends = LocusRoles.role!(:backends)

    # Only the keys under `services:` — the file also has `volumes:` and
    # `networks:` blocks with the same indentation.
    [_, services_block | _] = Regex.split(~r/^services:\s*$/m, compose)
    [services_block | _] = Regex.split(~r/^[a-z]/m, services_block)

    services =
      Regex.scan(~r/^  ([a-z][a-z0-9_-]*):\s*$/m, services_block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    assert services == Enum.sort(["caddy", "cyfr" | @locus_services])
    refute compose =~ ~r/porta|4001|8080/

    # The runtime is attached to its network and no other, which cyfr
    # joins: cyfr reaches it there, it reaches cyfr's host API there, and
    # the other Locus services and caddy never see either port. The network
    # is the service's alone: its runners have none, and reach the host API
    # and a pinned address only through the service.
    [_, runtime_block | _] =
      Regex.split(~r/^  #{Regex.escape(runtime.service)}:\s*$/m, services_block)

    [runtime_block | _] = Regex.split(~r/^  [a-z]/m, runtime_block)
    [_, runtime_networks | _] = Regex.split(~r/^    networks:\s*$/m, runtime_block)
    [runtime_networks | _] = Regex.split(~r/^    [a-z]/m, runtime_networks)

    assert Regex.scan(~r/^      - (\S+)/m, runtime_networks, capture: :all_but_first) ==
             [[runtime.network]]

    assert runtime_block =~ ~r/^\s*- LOCUS_RUNTIME_KEY=\$\{LOCUS_RUNTIME_KEY:-\}$/m

    assert runtime_block =~
             ~r/^\s*- LOCUS_RUNTIME_HOST_API_URL=\$\{LOCUS_RUNTIME_HOST_API_URL:-http:\/\/cyfr:/m

    [_, cyfr_block | _] = Regex.split(~r/^  cyfr:\s*$/m, services_block)
    [cyfr_block | _] = Regex.split(~r/^  [a-z]/m, cyfr_block)

    workers = "wrk_locus=http://#{runtime.service}:#{runtime.port}"

    assert cyfr_block =~
             ~r/^\s*- CYFR_LOCUS_RUNTIME_WORKERS=\$\{CYFR_LOCUS_RUNTIME_WORKERS:-#{Regex.escape(workers)}\}$/m

    assert cyfr_block =~ ~r/^\s*- CYFR_HOST_API_BIND=0\.0\.0\.0$/m

    for role <- LocusRoles.roles() do
      assert cyfr_block =~ ~r/^\s*- #{Regex.escape(role.network)}$/m
    end

    backends_url = "http://#{backends.service}:#{backends.port}"

    assert cyfr_block =~
             ~r/^\s*- CYFR_LOCUS_BACKENDS_URL=\$\{CYFR_LOCUS_BACKENDS_URL:-#{Regex.escape(backends_url)}\}$/m

    assert cyfr_block =~
             ~r/^\s*- CYFR_PRIVATE_EGRESS_TARGETS=\$\{CYFR_PRIVATE_EGRESS_TARGETS:-#{Regex.escape(backends.service)}\}$/m

    # Each Locus service is attached to its own network and no other: what
    # it listens on is that network, which is its isolation.
    for role <- LocusRoles.roles() do
      assert list_entries(service_block(compose, role.service), "networks") == [role.network]
    end

    # Runtime storage uses one data root.
    refute compose =~ ~r/^\s*- \.\/components:/m
  end

  # cyfr reaches the builder over the builds network, which only the two of
  # them join, and a build reaches crates.io and the npm registry over the
  # same network: it is not `internal`, so the isolation is who is attached.
  # The backends network is the same shape for a backend's registry and
  # upstream API, and the runtime's network for a guest's consented egress.
  test "the builds, backends and runtime networks carry cyfr to each service and the service out" do
    compose = read!("docker-compose.yml")
    [_, networks] = Regex.split(~r/^networks:\s*$/m, compose)
    [networks | _] = Regex.split(~r/^[a-z]/m, networks)

    for network <- Enum.map(LocusRoles.roles(), & &1.network) do
      assert networks =~ ~r/^  #{Regex.escape(network)}: \{\}$/m,
             "#{network} must be declared plain"

      attached =
        for service <- ["caddy", "cyfr" | @locus_services],
            block = service_block(compose, service),
            block =~ ~r/^    networks:\s*$/m,
            network in list_entries(block, "networks"),
            do: service

      assert attached == ["cyfr", network], "#{network} joins #{inspect(attached)}"
    end

    refute networks =~ ~r/internal:\s*true/
  end

  test "the builds service is the locus image under the shipped names, holding only its own settings" do
    compose = read!("docker-compose.yml")
    role = LocusRoles.role!(:builds)
    builds = service_block(compose, role.service)

    assert builds =~ ~r/^    container_name: #{Regex.escape(role.container)}$/m
    assert builds =~ ~r/^    image: ghcr\.io\/cyfrworks\/cyfr-locus:latest$/m
    assert builds =~ ~r/^      dockerfile: Dockerfile\.locus$/m
    assert builds =~ ~r/^    profiles: \["#{Regex.escape(role.profile)}"\]$/m
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

    # Spelled split so the retired names are not themselves found here.
    refute compose =~
             ~r/CYFR_BUILDE[R]_|CYFR_BUIL[D]_|CYFR_MAX_CONCURRENT_BUILD[S]|Dockerfile\.builde[r]|cyfrworks\/cyfr-builde[r]/

    refute compose =~ ~r/\.env\.builde[r]/
  end

  # The backends service runs the Locus image as compose runs the builds
  # service, with the backend pool in place of the build pool; its key is
  # the one cyfr reads as CYFR_LOCUS_BACKENDS_KEY, and it always starts.
  test "the backends service is the locus image under the shipped names, holding only its own settings" do
    compose = read!("docker-compose.yml")
    role = LocusRoles.role!(:backends)
    backends = service_block(compose, role.service)

    assert backends =~ ~r/^    container_name: #{Regex.escape(role.container)}$/m
    assert backends =~ ~r/^    image: ghcr\.io\/cyfrworks\/cyfr-locus:latest$/m
    assert backends =~ ~r/^      dockerfile: Dockerfile\.locus$/m
    assert role.profile == nil
    refute backends =~ ~r/^    profiles:/m
    assert backends =~ ~r/^      - path: \.env\.locus$/m
    assert list_entries(backends, "expose") == [~s("#{role.port}")]

    assert list_entries(backends, "environment") == [
             "LOCUS_BACKENDS_KEY=${CYFR_LOCUS_BACKENDS_KEY:-}"
           ]

    assert entrypoint(backends) == keeper_argv(LocusRoles.release(), role)

    # The release's own health probe is the builds wire's; this service
    # probes the backends wire's instead.
    assert backends =~ Prima.LocusBackends.route(:health)
  end

  # The hardening is written once, so a role cannot miss one and a new role
  # inherits it; the block carries the hardening alone, so no role gains a
  # network, an environment or a mount from it.
  test "the Locus services take their hardening from one block" do
    compose = YamlElixir.read_from_string!(read!("docker-compose.yml"))
    role = compose["x-locus-role"]
    runtime = LocusRoles.role!(:runtime).service

    assert for({key, _} <- compose, String.starts_with?(key, "x-"), do: key) == ["x-locus-role"]
    assert role |> Map.keys() |> Enum.sort() == Enum.sort(@role_keys)

    for service <- @locus_services,
        do: assert(Map.has_key?(compose["services"], service), service)

    for {service, definition} <- compose["services"] do
      {merges, own} = Enum.split_with(definition, &merge_key?/1)

      if service in @locus_services do
        assert Enum.map(merges, &elem(&1, 1)) == [role], "#{service} merges x-locus-role once"

        # A service's own list replaces the merged one whole, so the
        # runtime restates the block's security options before its own.
        overlap = for {key, _} <- own, key in @role_keys, do: key

        if service == runtime do
          assert overlap == ["security_opt"], service

          assert definition["security_opt"] ==
                   role["security_opt"] ++ ["seccomp=./keeper.seccomp.json"]
        else
          assert overlap == [], "#{service} sets #{inspect(overlap)} over x-locus-role"
        end
      else
        assert merges == [], "#{service} merges #{inspect(merges)}"
      end
    end
  end

  # cyfr-locus bounds a spawn's memory only where the container's cgroup is
  # mounted writable; without the option every bounded spawn is refused, so
  # the shipped services carry it. The runtime's runner pool is isolated,
  # which takes the keeper's seccomp profile too.
  test "the Locus services keep their hardening, and can bound a spawn's memory" do
    assert hardening_violations(read!("docker-compose.yml")) == []
  end

  test "a Locus service that loses a hardening option fails" do
    compose = read!("docker-compose.yml")
    every = fn key -> for service <- @locus_services, do: {service, key} end
    [runtime, builds, backends] = Enum.map([:runtime, :builds, :backends], &LocusRoles.role!/1)

    plants = [
      {"the runtime's list without no-new-privileges:true", "\n      - no-new-privileges:true\n",
       "\n", [{runtime.service, "security_opt"}]},
      {"locus-backends without its merge", "\n  #{backends.service}:\n    <<: *locus-role\n",
       "\n  #{backends.service}:\n", for(key <- @role_keys, do: {backends.service, key})},
      {"locus-builds setting read_only: false", "\n  #{builds.service}:\n    <<: *locus-role\n",
       "\n  #{builds.service}:\n    <<: *locus-role\n    read_only: false\n",
       [{builds.service, "read_only"}]},
      {"the block without ipc: none", "\n  ipc: none\n", "\n", every.("ipc")},
      {"the block granting privileged: true", "\nx-locus-role: &locus-role\n",
       "\nx-locus-role: &locus-role\n  privileged: true\n", every.("privileged")}
    ]

    # Each plant replaces one exact line; one that changes nothing answers
    # `:unchanged`, which no plant expects.
    outcomes =
      for {plant, line, replacement, _} <- plants do
        planted = String.replace(compose, line, replacement)
        {plant, if(planted == compose, do: :unchanged, else: hardening_violations(planted))}
      end

    assert outcomes == for({plant, _, _, expected} <- plants, do: {plant, Enum.sort(expected)})
  end

  # The runtime's runner pool is isolated: cyfr-locus clones each runner into
  # a user and network namespace of its own, which Docker's default seccomp
  # profile denies. The service runs under the keeper's profile, which the
  # image carries and a scaffolded project holds beside its compose file,
  # where compose reads it; a project without it does not start the service.
  test "the runtime runs under the keeper's seccomp profile, shipped beside the compose file" do
    role = LocusRoles.role!(:runtime)
    runtime = service_block(read!("docker-compose.yml"), role.service)
    assert "seccomp=./keeper.seccomp.json" in list_entries(runtime, "security_opt")
    assert runtime =~ "user.max_user_namespaces"
    assert runtime =~ "kernel.apparmor_restrict_unprivileged_userns"

    # The image's entrypoint is the builds role's; the runtime's service
    # names its own, the isolated runner pool, and its own health probe.
    assert role.isolation in Prima.KeeperProtocol.isolations()
    assert entrypoint(runtime) == keeper_argv(LocusRoles.release(), role)
    assert entrypoint(runtime) |> Enum.at(3) |> String.ends_with?(":" <> role.isolation)

    assert runtime =~ Prima.WorkerWire.worker_route(:status)

    dockerfile = read!("Dockerfile.locus")
    assert dockerfile =~ ~r{^COPY apps/locus/keeper/seccomp/keeper\.json /etc/cyfr/keeper\.json$}m

    dir = Path.join(System.tmp_dir!(), "cyfr-scaffold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    tarball = Path.join(dir, "scaffold.tar.gz")

    assert {_, 0} =
             System.cmd("bash", [Path.join(@root, "scripts/scaffold-tarball.sh"), tarball],
               stderr_to_stdout: true
             )

    {listing, 0} = System.cmd("tar", ["-tzf", tarball])
    entries = String.split(listing, "\n", trim: true)
    assert "docker-compose.yml" in entries
    assert "keeper.seccomp.json" in entries

    {profile, 0} = System.cmd("tar", ["-xOzf", tarball, "keeper.seccomp.json"])
    assert profile == read!("apps/locus/keeper/seccomp/keeper.json")
  end

  # The image names its pooled uids for the role that runs under them,
  # `printf '<name>%02d'` over `<base> + i`; cyfr-locus refuses pools that
  # overlap within one container, and this keeps every role's pool and the
  # release's own user apart across the role's containers too.
  test "every pooled uid is named for its service, and no two pools or services share a uid" do
    pools = user_loops(read!("Dockerfile.locus"))
    roles = LocusRoles.roles()

    assert Enum.sort(pools) == Enum.sort(for role <- roles, do: {role.user_prefix, role.uids})

    ranges = Enum.map(pools, &elem(&1, 1))

    for {a, i} <- Enum.with_index(ranges),
        b <- Enum.drop(ranges, i + 1),
        do: assert(Range.disjoint?(a, b), "#{inspect(a)} and #{inspect(b)} overlap")

    for range <- ranges, do: refute(LocusRoles.release().uid in range)

    # The shipped entrypoints serve exactly those ranges: the image's the
    # builds role's, each other role's its compose service's.
    image_role = LocusRoles.release().image_role

    for role <- roles do
      file = if role.name == image_role, do: "Dockerfile.locus", else: "docker-compose.yml"
      assert read!(file) =~ ~s("--pool", "#{pool_spec(role)}")
    end

    # Spelled split so the retired names are not themselves found here.
    refute read!("Dockerfile.locus") =~
             ~r/cyfr-buil[d]\d|cyfr-backen[d]\d|'cyfr-(buil[d]|backen[d])%/
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
    builds_overlay = "tests/builder-image/compose.locus-builds.yml"
    runtime_overlay = "tests/locus-runtime-image/compose.locus-runtime.yml"
    backends_overlay = "tests/locus-backends-image/compose.locus-backends.yml"
    builds_last_overlay = "tests/builder-image/compose.no-writable-cgroups.yml"
    channel = "apps/locus/lib/locus/runtime/keeper/channel.ex"
    runtime_keeper = "apps/locus/lib/locus/runtime/keeper.ex"
    runtime_last_overlay = "tests/locus-runtime-image/compose.no-writable-cgroups.yml"

    release_grace =
      "      - LOCUS_RUNTIME_RELEASE_GRACE_MS=${LOCUS_RUNTIME_RELEASE_GRACE_MS:?set LOCUS_RUNTIME_RELEASE_GRACE_MS}\n"

    status_route = Prima.WorkerWire.worker_route(:status)
    %{first: first, last: last} = runtime.uids

    plants = [
      {"1: the runtime's users counted from another base",
       {@dockerfile, "uid=$((#{first - 1} + i))", "uid=$((#{first + 99} + i))"},
       [{@dockerfile, :users, :runtime}]},
      {"2: the backends' pool a uid short",
       {@compose, ~s("#{pool_spec(backends)}"),
        ~s("#{backends.pool}:#{backends.uids.first}-#{backends.uids.last - 1}")},
       [{@compose, :entrypoint, :backends}]},
      {"3: the runtime's pool not isolated",
       {@compose, ~s("#{pool_spec(runtime)}"), ~s("#{runtime.pool}:#{first}-#{last}")},
       [{@compose, :entrypoint, :runtime}]},
      {"4: the image's entrypoint starting the release as root",
       {@dockerfile, ~s("--client-user", "#{release.user}"), ~s("--client-user", "root")},
       [{@dockerfile, :entrypoint, :builds}]},
      {"5: the builds service on the backends' network",
       {@compose, "    networks:\n      - #{builds.network}\n",
        "    networks:\n      - #{backends.network}\n"}, [{@compose, :network, :builds}]},
      {"6: the runtime's homes twice as large",
       {@compose, "size=#{runtime.home_size}", "size=512m"}, [{@compose, :tmpfs, :runtime}]},
      {"7: the runtime's harness spelling its pool",
       {runtime_suite, ~s(POOL_FIRST, POOL_LAST = ROLE["first_uid"], ROLE["last_uid"]),
        "POOL_FIRST, POOL_LAST = #{first}, #{last}"}, [{runtime_suite, :suite, :runtime}]},
      {"8: the builder overlay starting the release as nobody",
       {builds_overlay, ~s("--client-user", "#{release.user}"), ~s("--client-user", "nobody")},
       [{builds_overlay, :entrypoint, :builds}]},
      {"9: the runtime's channel asking another pool",
       {channel, ~s(@pool "#{runtime.pool}"), ~s(@pool "#{runtime.pool}s")},
       [{channel, :pool, :runtime}]},
      {"10: a table with a ninth runner",
       {release, with_role.(:runtime, &%{&1 | uids: first..(last + 1)//1})},
       [{@compose, :entrypoint, :runtime}, {@dockerfile, :users, :runtime}]},
      {"11: a table moving the builds' port",
       {release, with_role.(:builds, &%{&1 | port: &1.port + 2})},
       [
         {@config, :port, :builds},
         {@compose, :port, :builds},
         {@dockerfile, :port, :builds},
         {builds_overlay, :port, :builds}
       ]},
      {"12: the builds' harness reading no vector file",
       {builds_harness, ~s("fixtures", "locus_roles.json"), ~s("fixtures", "locus_builds.json")},
       [{builds_harness, :suite, :builds}]},
      # A site that is missing, or not in the form read, is drift too.
      {"V1: the runtime's probe without its port",
       {@compose, "http://localhost:#{runtime.port}#{status_route}",
        "http://localhost#{status_route}"}, [{@compose, :port, :runtime}]},
      {"V3: the backends' probe on another address and port",
       {@compose, "http://localhost:#{backends.port}/locus",
        "http://127.0.0.1:#{backends.port + 2}/locus"}, [{@compose, :port, :backends}]},
      {"V4: the runtime overlay publishing another port, as tcp",
       {runtime_overlay, ~s("127.0.0.1::#{runtime.port}"),
        ~s("127.0.0.1::#{runtime.port + 2}/tcp")}, [{runtime_overlay, :port, :runtime}]},
      {"V5: the backends overlay publishing another port, as tcp",
       {backends_overlay, ~s("127.0.0.1::#{backends.port}"),
        ~s("127.0.0.1::#{backends.port + 2}/tcp")}, [{backends_overlay, :port, :backends}]},
      {"E4: the backends overlay starting the release as nobody, behind a comment",
       {backends_overlay,
        ~s("--client-user", "#{release.user}", "--", "#{release.bin}", "start"]),
        ~s("--client-user", "nobody", "--", "#{release.bin}", "start"]  # the suite's user)},
       [{backends_overlay, :entrypoint, :backends}]},
      {"c: the builds overlay without its entrypoint line",
       {builds_overlay, "\n    entrypoint: ", "\n    # entrypoint: "},
       [{builds_overlay, :entrypoint, :builds}]},
      {"d: the runtime keeper's remedy naming another pool",
       {runtime_keeper, "--pool #{runtime.pool}:", "--pool #{runtime.pool}s:"},
       [{runtime_keeper, :pool, :runtime}]},
      {"e: the builder's last overlay layering another service",
       {builds_last_overlay, "\n  #{builds.service}:\n", "\n  #{backends.service}:\n"},
       [{builds_last_overlay, :service, :builds}]},
      {"f: the documented backends port",
       {@config, "| 1..65535 | #{backends.port} |", "| 1..65535 | #{backends.port + 2} |"},
       [{@config, :port, :backends}]},
      {"f2: the documented attach directory",
       {@config, "| `#{release.run_dir}` |", "| `#{release.run_dir}/attach` |"},
       [{@config, :pool, :runtime}]},
      # An overlay is read whole, so no blank line, comment or spelling of
      # a key ends the reading early.
      {"B1: the backends overlay publishing a second port after a blank line",
       {backends_overlay, ~s(      - "127.0.0.1::#{backends.port}"\n),
        ~s(      - "127.0.0.1::#{backends.port}"\n\n      - "#{backends.port}"\n)},
       [{backends_overlay, :port, :backends}]},
      {"B2: the backends overlay publishing a second port after a comment",
       {backends_overlay, ~s(      - "127.0.0.1::#{backends.port}"\n),
        ~s(      - "127.0.0.1::#{backends.port}"\n    # and on every interface\n      - "#{backends.port}"\n)},
       [{backends_overlay, :port, :backends}]},
      {"C1: the runtime overlay naming an unisolated entrypoint, its key quoted",
       {runtime_overlay, "    pull_policy: never\n",
        ~s(    pull_policy: never\n    "entrypoint": ["cyfr-locus", "serve", "--pool", "#{runtime.pool}:#{first}-#{last}"]\n)},
       [{runtime_overlay, :entrypoint, :runtime}]},
      {"C2: the runtime overlay naming an unisolated entrypoint, its key spaced",
       {runtime_overlay, "    pull_policy: never\n",
        ~s(    pull_policy: never\n    entrypoint : ["cyfr-locus", "serve", "--pool", "#{runtime.pool}:#{first}-#{last}"]\n)},
       [{runtime_overlay, :entrypoint, :runtime}]},
      {"E5: the builder's last overlay layering a second service after a comment",
       {builds_last_overlay, "      - no-new-privileges:true\n",
        "      - no-new-privileges:true\n# and the backends service too\n  #{backends.service}:\n    security_opt: !override\n      - no-new-privileges:true\n"},
       [{builds_last_overlay, :service, :builds}]},
      # An overlay compose reads otherwise than its parse is no overlay:
      # every reading of it is drift.
      {"R1: the runtime overlay resetting its ports",
       {runtime_overlay, "    ports:\n", "    ports: !reset\n"},
       unread.(runtime_overlay, :runtime)},
      {"R2: the runtime overlay resetting an entrypoint it names",
       {runtime_overlay, "    pull_policy: never\n",
        ~s(    pull_policy: never\n    entrypoint: !reset #{Jason.encode!(keeper_argv(release, runtime))}\n)},
       unread.(runtime_overlay, :runtime)},
      {"T3: the runtime overlay replacing compose's service whole",
       {runtime_overlay, "  #{runtime.service}:\n", "  #{runtime.service}: !override\n"},
       unread.(runtime_overlay, :runtime)},
      {"M1: the runtime overlay merging an unisolated entrypoint",
       {runtime_overlay, "services:\n  #{runtime.service}:\n",
        "x-unisolated: &unisolated\n  entrypoint: #{Jason.encode!(keeper_argv(release, %{runtime | isolation: nil}))}\nservices:\n  #{runtime.service}:\n    <<: *unisolated\n"},
       unread.(runtime_overlay, :runtime)},
      {"D2: the runtime overlay behind a document naming an unisolated entrypoint",
       {runtime_overlay, "services:\n  #{runtime.service}:\n",
        "services:\n  #{runtime.service}:\n    entrypoint: #{Jason.encode!(keeper_argv(release, %{runtime | isolation: nil}))}\n---\nservices:\n  #{runtime.service}:\n"},
       unread.(runtime_overlay, :runtime)},
      {"X1: the runtime overlay extending a service from another file",
       {runtime_overlay, "    pull_policy: never\n",
        "    pull_policy: never\n    extends:\n      file: unisolated.yml\n      service: #{runtime.service}\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"I2: the runtime overlay including another file",
       {runtime_overlay, "services:\n  #{runtime.service}:\n",
        "include:\n  - sidecar.yml\nservices:\n  #{runtime.service}:\n"},
       unread.(runtime_overlay, :runtime)},
      {"LAST1: the runtime's last overlay naming an unisolated entrypoint",
       {runtime_last_overlay, "      - seccomp=./keeper.seccomp.json\n",
        "      - seccomp=./keeper.seccomp.json\n    entrypoint: #{Jason.encode!(keeper_argv(release, %{runtime | isolation: nil}))}\n"},
       [{runtime_last_overlay, :entrypoint, :runtime}]},
      # Every value an overlay gives is read: one the test does not expect
      # is drift, whatever key carries it.
      {"r5-P1: the runtime overlay telling the runtime another port",
       {runtime_overlay, release_grace,
        release_grace <> "      - LOCUS_RUNTIME_PORT=#{runtime.port + 100}\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"r5-P2: the runtime overlay moving the attach directory",
       {runtime_overlay, release_grace,
        release_grace <> "      - LOCUS_RUNTIME_ATTACH_DIR=/tmp/attach\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"r5-K1: the runtime overlay putting another cyfr-locus first on the path",
       {runtime_overlay, release_grace,
        release_grace <>
          "      - PATH=/canary:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n    volumes:\n      - ./bin:/canary:ro\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"r5-V4: the runtime overlay mounting another program over the release",
       {runtime_overlay, "    pull_policy: never\n",
        "    pull_policy: never\n    volumes:\n      - ./bin/locus:#{release.bin}:ro\n"},
       [{runtime_overlay, :service, :runtime}]},
      {"r5-LAST4: the runtime's last overlay unconfining seccomp",
       {runtime_last_overlay, "      - seccomp=./keeper.seccomp.json\n",
        "      - seccomp=./keeper.seccomp.json\n      - seccomp=unconfined\n      - systempaths=unconfined\n"},
       [{runtime_last_overlay, :service, :runtime}]},
      {"r5-C1: the runtime overlay naming its container after the builds'",
       {runtime_overlay, "    container_name: !reset null\n",
        "    container_name: #{builds.container}\n"}, [{runtime_overlay, :service, :runtime}]},
      {"A1: the builds service disabling the image's probe",
       {@compose, "  #{builds.service}:\n",
        "  #{builds.service}:\n    healthcheck:\n      disable: true\n"},
       [{@compose, :port, :builds}]}
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

    assert outcomes == for({plant, _, expected} <- plants, do: {plant, Enum.sort(expected)})
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
    # refuses to start with the database, the keyring, the runtime's root
    # or the control plane's builds and backends keys in its environment.
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
          ~w(CYFR_LOCUS_RUNTIME_ROOT LOCUS_RUNTIME_SERVICE_ID LOCUS_RUNTIME_KEY LOCUS_RUNTIME_HOST_API_URL CYFR_LOCUS_RUNTIME_WORKERS CYFR_HOST_API_BIND CYFR_HOST_API_PORT) do
      assert env =~ ~r/^#? ?#{knob}=/m, "#{knob} is missing from .env.example"
    end

    # Compose sets five variables in the runtime service's environment,
    # over anything .env.locus sets: the three it interpolates from the
    # project .env are documented in .env.example above, and the two it
    # fixes in integration-guide.md's section on running a worker outside
    # Compose. .env.locus.example documents none of them, and says where
    # they are.
    runtime = LocusRoles.role!(:runtime)

    environment =
      list_entries(service_block(read!("docker-compose.yml"), runtime.service), "environment")

    assert environment == [
             "LOCUS_RUNTIME_SERVICE_ID=${LOCUS_RUNTIME_SERVICE_ID:-wrk_locus}",
             "LOCUS_RUNTIME_KEY=${LOCUS_RUNTIME_KEY:-}",
             "LOCUS_RUNTIME_HOST_API_URL=${LOCUS_RUNTIME_HOST_API_URL:-http://cyfr:${CYFR_HOST_API_PORT:-4300}}",
             "LOCUS_RUNTIME_BIND=0.0.0.0",
             "LOCUS_RUNTIME_PORT=#{runtime.port}"
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
end
