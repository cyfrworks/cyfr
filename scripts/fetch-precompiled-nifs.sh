#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Lays down, with curl, what two of the deps download from GitHub releases
# for this machine, where each looks before it downloads, so a build from
# freshly fetched deps never reaches their own downloads:
#
#   scripts/fetch-precompiled-nifs.sh              every precompiled NIF the
#                                                  locked deps compile against
#                                                  (wasmex's), into
#                                                  rustler_precompiled's cache
#   scripts/fetch-precompiled-nifs.sh --tailwind   the tailwind CLI each
#                                                  tailwind profile runs, at
#                                                  the path `mix tailwind`
#                                                  runs it from
#   ... --print                                    print, one a line, what
#                                                  either would lay down and
#                                                  where; fetch nothing
#
# A build that starts from fresh deps runs the first after `mix deps.get`
# and before the deps compile (both images' builder stages, CI's jobs, the
# commit gate, a fresh checkout), and the second once config/ is there and
# before `mix assets.deploy` (the app image's builder stage, the release
# proofs' build) or the dev server's first tailwind watcher.
#
# Why: rustler_precompiled (for the NIFs) and the tailwind package (for its
# CLI) download with Erlang's :httpc, which refuses a response whose
# headers pass 10,240 bytes (inets' HTTP_MAX_HEADER_SIZE, a constant no
# option sets), answering {:header_too_long, {:max, 10240}}. GitHub answers
# a release-asset URL with a redirect whose headers pass it (its
# content-security-policy alone is about 9 KB), so both downloads fail:
# a dep whose NIF is not cached does not compile, and `mix tailwind`, which
# `mix assets.deploy` runs, stops. curl takes those headers. This script
# stays until both download with a client that accepts them.
#
# Nothing here restates their rules. For the NIFs the script loads the
# rustler_precompiled the deps hold and asks it for the file name, URL and
# cache path (RustlerPrecompiled.build_metadata/1 and nifs_from_metadata/1,
# the functions its compile-time download uses), from the options each
# module passes to `use RustlerPrecompiled`, evaluated in its dep's own Mix
# project and directory, where Mix compiles the dep. A download is checked
# with rustler_precompiled's own integrity check against the dep's checksum
# file. The cache is rustler_precompiled's: RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
# when set, else its user cache directory (MIX_XDG respected); a relative
# RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH names a directory under each dep's
# own directory, which is how the dep's compile reads it, so the file goes
# there. A module whose options or RUSTLER_PRECOMPILED_FORCE_BUILD_ALL
# force a build from source needs no file and is skipped.
#
# For tailwind the script loads the tailwind package the deps hold, the
# checkout's Mix project (MIX_ENV, MIX_BUILD_PATH) and its configuration,
# and asks Tailwind for each profile's version, target and binary path
# (configured_version/1, configured_target/1, bin_path/1; `mix tailwind`
# downloads only when that file is missing), and default_base_url/0 for
# the URL. tailwind's own download checks nothing, so the sha256 of each
# release asset is pinned below, by version and target: GitHub's recorded
# digest of the asset, which the release's sha256sums.txt agrees with. A
# version or target the pins do not hold is refused, so a tailwind version
# bump in config/config.exs adds its pins here.
#
# Every file is laid down only when it matches: a download that does not is
# refused and nothing is laid down; a file in place that matches is kept, so
# a second run fetches nothing, and one that does not is replaced only by a
# download that matches. The deps are MIX_DEPS_PATH's, as Mix reads it, else
# the checkout's deps/.
set -euo pipefail

# VERSION TARGET SHA256, one tailwind CLI release asset a line.
TAILWIND_PINS='
4.3.3 linux-x64 dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a
4.3.3 linux-x64-musl a04d34ceacc8f52cbe8920ad846cdeb61d3d0021dba32db0d1f77c9d9fad7a6c
4.3.3 linux-arm64 55fd0b241214eff3de1e8ee4f22796662f2d2e7a49bcfca7477cfd0bac398195
4.3.3 linux-arm64-musl 71ea4be79c9de9827545682df3e040053fb535d37c71ed2cfdedf9385a0868e0
4.3.3 macos-arm64 cdf646702987a743464dff4d9c60fd4480d1c1e73dd819a9a67f1078815dce9d
4.3.3 macos-x64 7922e0953f2110c05976e3bf58f14e643d90427575e766b7d433f5f80cbee7e1
'

usage() { echo "usage: $0 [--tailwind] [--print]" >&2; exit 64; }

what=nifs mode=fetch
for arg in "$@"; do
  case "$arg" in
    --tailwind) what=tailwind ;;
    --print) mode=print ;;
    *) usage ;;
  esac
done
[ "$#" -le 2 ] || usage
root=$(cd "$(dirname "$0")/.." && pwd -P)
if [ "$mode" = fetch ] && ! command -v curl >/dev/null 2>&1; then
  echo "$0: curl is not on PATH, and it fetches what this script lays down" >&2
  exit 69
fi

program=$(cat <<'EXS'
[root, what, mode, work, pins] = System.argv()
Logger.configure(level: :warning)

refuse = fn message -> throw({:refuse, message}) end

deps =
  case System.get_env("MIX_DEPS_PATH") do
    nil -> Path.join(root, "deps")
    path -> Path.expand(path)
  end

# A dep's own modules, compiled as Mix compiles a dep, into a directory of
# the caller's.
load_dep = fn name ->
  dir = Path.join(deps, name)

  unless File.dir?(Path.join(dir, "lib")) do
    refuse.("#{dir} holds no #{name}: run mix deps.get first")
  end

  ebin = Path.join([work, "ebin", name])

  {:ok, _, _} =
    dir
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Kernel.ParallelCompiler.compile_to_path(ebin, return_diagnostics: true)

  Code.prepend_path(ebin)
end

sha256 = fn path ->
  path
  |> File.stream!(1_048_576)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)
end

# Lays url down at path, unless a file there already passes verify, with
# the download in the caller's directory under name (the NIFs' integrity
# check looks a checksum up by the file's name) and renamed into place
# whole once verify passes; what = the name a message gives the file.
lay_down = fn url, path, name, mode_bits, what, verify ->
  cond do
    File.regular?(path) and verify.(path) == :ok ->
      IO.puts("#{name} is in place at #{path}")

    true ->
      if File.exists?(path) do
        IO.puts(:stderr, "#{path} does not match #{what}; fetching it again")
      end

      part = Path.join([work, "download", name])
      File.mkdir_p!(Path.dirname(part))

      {out, status} =
        System.cmd(
          "curl",
          ~w(--fail --silent --show-error --location --proto =https --proto-redir =https --retry 3 --output) ++
            [part, url],
          stderr_to_stdout: true
        )

      if status != 0 do
        refuse.("curl could not fetch #{url} (exit #{status}): #{String.trim(out)}")
      end

      case verify.(part) do
        :ok ->
          incoming = "#{path}.part-#{System.pid()}"
          File.mkdir_p!(Path.dirname(path))
          File.cp!(part, incoming)
          if mode_bits, do: File.chmod!(incoming, mode_bits)
          File.rename!(incoming, path)
          IO.puts("#{name} fetched from #{url} to #{path}")

        {:error, reason} ->
          refuse.("#{url} does not match #{what} (#{reason}); nothing is laid down")
      end
  end
end

nifs = fn ->
  load_dep.("rustler_precompiled")

  # Read as Mix reads it, quoted keys and all.
  lockfile = Path.join(root, "mix.lock")

  {lock, _} =
    lockfile
    |> File.read!()
    |> Code.string_to_quoted!(file: lockfile, emit_warnings: false)
    |> Code.eval_quoted([], file: lockfile)

  rp_use? = &match?({:use, _, [{:__aliases__, _, [:RustlerPrecompiled]} | _]}, &1)

  # Every source file of a locked dep that calls `use RustlerPrecompiled`
  # anywhere, and how many times.
  sources =
    for app <- lock |> Map.keys() |> Enum.sort(),
        dir = Path.join(deps, to_string(app)),
        File.regular?(Path.join(dir, "mix.exs")),
        file <- Path.wildcard(Path.join(dir, "lib/**/*.ex")),
        source = File.read!(file),
        String.contains?(source, "RustlerPrecompiled"),
        ast = Code.string_to_quoted!(source, file: file),
        {_, calls} = Macro.prewalk(ast, 0, fn node, n -> {node, if(rp_use?.(node), do: n + 1, else: n)} end),
        calls > 0,
        do: {app, dir, file, ast, calls}

  # Every top-level module of those that calls it among its own top-level
  # statements, with the statements before the call and its options,
  # unevaluated.
  users =
    for {app, dir, file, ast, _} <- sources,
        {:defmodule, _, [name, [do: body]]} <-
          (case ast do
             {:__block__, _, forms} -> forms
             form -> [form]
           end) do
      forms =
        case body do
          {:__block__, _, forms} -> forms
          form -> [form]
        end

      {before, rest} = Enum.split_while(forms, &(not rp_use?.(&1)))

      case {name, rest} do
        {_, []} ->
          nil

        {{:__aliases__, _, parts}, [{:use, _, [_, opts]} | _]} ->
          # Module attributes (@moduledoc and the like) mean nothing outside
          # the module; every other statement before the call is evaluated.
          before = Enum.reject(before, &match?({:@, _, _}, &1))
          {app, dir, file, Module.concat(parts), before, opts}

        _ ->
          refuse.("#{file}: a `use RustlerPrecompiled` this script cannot read")
      end
    end
    |> Enum.reject(&is_nil/1)

  # A call this reading does not find (in a nested module, a condition or
  # a quote) is refused, not skipped.
  for {_, _, file, _, calls} <- sources, calls != Enum.count(users, &(elem(&1, 2) == file)) do
    refuse.("#{file} calls `use RustlerPrecompiled` outside a top-level module's own statements, which this script does not read")
  end

  if users == [] do
    refuse.("no locked dep in #{deps} calls `use RustlerPrecompiled`: run mix deps.get first, or drop this part of the script once no dep needs it")
  end

  for {app, dir, file, module, before, opts} <- users do
    # In the dep's own Mix project and directory, as its compile runs: the
    # options are evaluated with Mix.Project.config/0 the dep's, and a
    # relative cache override resolves against the dep's directory.
    {config, meta, path} =
      Mix.Project.in_project(app, dir, fn _ ->
        {opts, _} = Code.eval_quoted({:__block__, [], before ++ [opts]}, [], file: file)

        # What `use RustlerPrecompiled` adds before it builds its config.
        opts =
          if System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL") in ["1", "true"] do
            Keyword.put(opts, :force_build, true)
          else
            Keyword.put_new(opts, :force_build, false)
          end

        config = RustlerPrecompiled.Config.new(Keyword.put_new(opts, :module, module))

        if config.force_build? do
          {config, nil, nil}
        else
          case RustlerPrecompiled.build_metadata(config) do
            {:ok, meta} -> {config, meta, Path.expand(meta.cached_tar_gz)}
            {:error, reason} -> refuse.("#{inspect(module)}: #{reason}")
          end
        end
      end)

    if config.force_build? do
      IO.puts(:stderr, "#{inspect(module)} is built from source here (force_build): no NIF to fetch")
    else
      {:ok, nifs} = RustlerPrecompiled.nifs_from_metadata(meta)

      {url, headers} =
        case List.keyfind(nifs, meta.file_name, 0) do
          {_, found} -> found
          nil -> refuse.("#{inspect(module)}: rustler_precompiled names no URL for #{meta.file_name}")
        end

      if headers != [] do
        refuse.("#{inspect(module)}: #{url} takes request headers, which this script does not send")
      end

      case mode do
        "print" ->
          IO.puts(Enum.join([inspect(module), meta.file_name, url, path], "\t"))

        "fetch" ->
          checksum_file = Path.join(dir, "checksum-#{module}.exs")
          File.regular?(checksum_file) || refuse.("#{checksum_file} is missing")
          {checksums, _} = Code.eval_file(checksum_file)

          lay_down.(url, path, meta.file_name, nil, "#{app}'s checksum file",
            &RustlerPrecompiled.check_integrity_from_map(checksums, &1, module))
      end
    end
  end
end

tailwind = fn ->
  load_dep.("tailwind")

  pins =
    for line <- String.split(pins, "\n", trim: true),
        [version, target, sum] = String.split(line),
        into: %{},
        do: {{version, target}, sum}

  # The checkout's project and configuration, as Mix loads them before it
  # runs `mix tailwind`.
  env = String.to_atom(System.get_env("MIX_ENV") || "dev")
  Mix.env(env)

  Mix.Project.in_project(:cyfr_umbrella, root, fn _ ->
    root
    |> Path.join(Mix.Project.config()[:config_path] || "config/config.exs")
    |> Config.Reader.read!(env: env, target: Mix.target())
    |> Application.put_all_env(persistent: true)

    if Tailwind.profiles() == [] do
      refuse.("the configuration names no tailwind profile: nothing runs tailwind, so drop this part of the script")
    end

    for {profile, _} <- Tailwind.profiles(),
        version = Tailwind.configured_version(profile),
        target = Tailwind.configured_target(profile),
        uniq: true do
      {version, target, Tailwind.bin_path(version)}
    end
  end)
  |> Enum.each(fn {version, target, path} ->
    url =
      Tailwind.default_base_url()
      |> String.replace("$version", version)
      |> String.replace("$target", target)

    sum =
      Map.get(pins, {version, target}) ||
        refuse.("no sha256 is pinned for tailwind #{version} on #{target}: add it to TAILWIND_PINS in this script")

    case mode do
      "print" ->
        IO.puts(Enum.join(["tailwind", version, target, url, path], "\t"))

      "fetch" ->
        verify = fn file ->
          if sha256.(file) == sum, do: :ok, else: {:error, "its sha256 is not the one pinned for #{version} on #{target}"}
        end

        lay_down.(url, path, Path.basename(path), 0o755, "the sha256 pinned for tailwind #{version} on #{target}", verify)
    end
  end)
end

try do
  Mix.start()

  case what do
    "nifs" -> nifs.()
    "tailwind" -> tailwind.()
  end
catch
  {:refuse, message} ->
    IO.puts(:stderr, "fetch-precompiled-nifs: #{message}")
    System.halt(1)
end
EXS
)

# The deps' compiled modules and the downloads, removed however the run
# ends.
work=$(mktemp -d "${TMPDIR:-/tmp}/fetch-precompiled-nifs.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
elixir -e "$program" -- "$root" "$what" "$mode" "$work" "$TAILWIND_PINS"
