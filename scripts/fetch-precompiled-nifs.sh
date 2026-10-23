#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Puts every precompiled NIF this checkout's deps download for this machine
# into the cache rustler_precompiled reads before it downloads, so a build
# from freshly fetched deps compiles without rustler_precompiled's own
# download. Every build that starts from fresh deps runs it after
# `mix deps.get` and before the deps compile: both images' builder stages,
# CI's jobs, the commit gate and a fresh checkout.
#
#   scripts/fetch-precompiled-nifs.sh           fetch what is not cached yet
#   scripts/fetch-precompiled-nifs.sh --print   print, a NIF a line, its
#                                               module, file name, URL and
#                                               cache path; fetch nothing
#
# Why: rustler_precompiled downloads with Erlang's :httpc, which refuses a
# response whose headers pass 10,240 bytes (inets' HTTP_MAX_HEADER_SIZE, a
# constant no option sets), answering {:header_too_long, {:max, 10240}}.
# GitHub answers a release-asset URL with a redirect whose headers pass it
# (its content-security-policy alone is about 9 KB), so every download
# from a GitHub release fails, and a dep whose NIF is not cached does not
# compile. curl takes those headers. This script stays until
# rustler_precompiled downloads with a client that accepts them.
#
# Nothing here restates rustler_precompiled's rules: the script loads the
# rustler_precompiled the deps hold and asks it for the file name, URL and
# cache path (RustlerPrecompiled.build_metadata/1 and nifs_from_metadata/1,
# the functions its compile-time download uses), from the options each
# module passes to `use RustlerPrecompiled`, evaluated in its dep's own
# Mix project. A download is checked with rustler_precompiled's own
# integrity check against the dep's checksum file, and refused, with
# nothing cached, when it does not match; the compile checks the cached
# file again. A cached file that matches is kept, so a second run fetches
# nothing; one that does not is replaced only by a download that matches.
# The cache is rustler_precompiled's: RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
# when set, else its user cache directory (MIX_XDG respected). A module
# whose options or RUSTLER_PRECOMPILED_FORCE_BUILD_ALL force a build from
# source needs no file and is skipped. The deps are MIX_DEPS_PATH's, as
# Mix reads it, else the checkout's deps/.
set -euo pipefail

usage() { echo "usage: $0 [--print]" >&2; exit 64; }

mode=fetch
case "$#:${1:-}" in
  0:) ;;
  1:--print) mode=print ;;
  *) usage ;;
esac
root=$(cd "$(dirname "$0")/.." && pwd -P)
if [ "$mode" = fetch ] && ! command -v curl >/dev/null 2>&1; then
  echo "$0: curl is not on PATH, and it fetches the NIFs" >&2
  exit 69
fi

program=$(cat <<'EXS'
[root, mode, work] = System.argv()
ebin = Path.join(work, "ebin")
Logger.configure(level: :warning)

refuse = fn message -> throw({:refuse, message}) end

deps =
  case System.get_env("MIX_DEPS_PATH") do
    nil -> Path.join(root, "deps")
    path -> Path.expand(path)
  end

run = fn ->
  rustler_precompiled = Path.join(deps, "rustler_precompiled")

  unless File.dir?(Path.join(rustler_precompiled, "lib")) do
    refuse.("#{rustler_precompiled} holds no rustler_precompiled: run mix deps.get first")
  end

  # Compiled as Mix compiles a dep, into a directory of the caller's.
  {:ok, _, _} =
    rustler_precompiled
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Kernel.ParallelCompiler.compile_to_path(ebin, return_diagnostics: true)

  Code.prepend_path(ebin)

  # Read as Mix reads it, quoted keys and all.
  lockfile = Path.join(root, "mix.lock")

  {lock, _} =
    lockfile
    |> File.read!()
    |> Code.string_to_quoted!(file: lockfile, emit_warnings: false)
    |> Code.eval_quoted([], file: lockfile)

  Mix.start()

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
    refuse.("no locked dep in #{deps} calls `use RustlerPrecompiled`: run mix deps.get first, or drop this script once no dep needs it")
  end

  for {app, dir, file, module, before, opts} <- users do
    # Evaluated as the module's compile evaluates them: in its dep's Mix
    # project, so Mix.Project.config/0 is the dep's.
    {opts, _} =
      Mix.Project.in_project(app, dir, fn _ ->
        Code.eval_quoted({:__block__, [], before ++ [opts]}, [], file: file)
      end)

    # What `use RustlerPrecompiled` adds before it builds its config.
    opts =
      if System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL") in ["1", "true"] do
        Keyword.put(opts, :force_build, true)
      else
        Keyword.put_new(opts, :force_build, false)
      end

    config = RustlerPrecompiled.Config.new(Keyword.put_new(opts, :module, module))

    if config.force_build? do
      IO.puts(:stderr, "#{inspect(module)} is built from source here (force_build): no NIF to fetch")
    else
      meta =
        case RustlerPrecompiled.build_metadata(config) do
          {:ok, meta} -> meta
          {:error, reason} -> refuse.("#{inspect(module)}: #{reason}")
        end

      {:ok, nifs} = RustlerPrecompiled.nifs_from_metadata(meta)

      {url, headers} =
        case List.keyfind(nifs, meta.file_name, 0) do
          {_, found} -> found
          nil -> refuse.("#{inspect(module)}: rustler_precompiled names no URL for #{meta.file_name}")
        end

      if headers != [] do
        refuse.("#{inspect(module)}: #{url} takes request headers, which this script does not send")
      end

      path = meta.cached_tar_gz

      case mode do
        "print" ->
          IO.puts(Enum.join([inspect(module), meta.file_name, url, path], "\t"))

        "fetch" ->
          checksum_file = Path.join(dir, "checksum-#{module}.exs")
          File.regular?(checksum_file) || refuse.("#{checksum_file} is missing")
          {checksums, _} = Code.eval_file(checksum_file)

          verify = &RustlerPrecompiled.check_integrity_from_map(checksums, &1, module)

          cond do
            File.regular?(path) and verify.(path) == :ok ->
              IO.puts("#{meta.file_name} is cached at #{path}")

            true ->
              if File.exists?(path) do
                IO.puts(:stderr, "#{path} does not match #{app}'s checksum file; fetching it again")
              end

              # The download keeps the file's own name, which the integrity
              # check looks its checksum up by, in the caller's directory, and
              # reaches the cache only once it matches, renamed into place
              # whole.
              part = Path.join([work, "download", meta.file_name])
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
                  File.rename!(incoming, path)
                  IO.puts("#{meta.file_name} fetched from #{url} to #{path}")

                {:error, reason} ->
                  refuse.("#{url} does not match #{app}'s checksum file (#{reason}); nothing is cached")
              end
          end
      end
    end
  end
end

try do
  run.()
catch
  {:refuse, message} ->
    IO.puts(:stderr, "fetch-precompiled-nifs: #{message}")
    System.halt(1)
end
EXS
)

# rustler_precompiled's compiled modules and the downloads, removed however
# the run ends.
work=$(mktemp -d "${TMPDIR:-/tmp}/fetch-precompiled-nifs.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
elixir -e "$program" -- "$root" "$mode" "$work"
