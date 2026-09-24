# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetiredSettingsTest do
  @moduledoc """
  Settings this server no longer has, and the two it reaches the builds
  service by.

  What every application key means is the configuration schema's, and the
  schema is a row of `Cyfr.Boundaries` — read by `Cyfr.BoundariesTest`,
  which also plants a key nothing declares and shows it reported. What is
  left here is the other half: a name that must appear nowhere, because a
  setting an operator can still spell is a setting they would set to no
  effect, or a reader that brings one back.
  """

  use ExUnit.Case, async: true

  defp root, do: Path.expand("../../../..", __DIR__)

  # The builder's settings are the `locus` release's own (`LOCUS_BUILDS_*`,
  # `Locus.Config`), and this server reaches it through two variables
  # alone (`CYFR_LOCUS_BUILDS_URL`, `CYFR_LOCUS_BUILDS_KEY`). What configured
  # the in-process builds, the bearer token and the builder's limits under
  # CYFR's prefix is gone, every name of it: a name left in a config file,
  # the code, an example, a compose file, a guide or the CLI is a setting an
  # operator would set to no effect, or a reader that brings one back. The
  # names are spelled split here so this file is not itself a hit.
  @retired_variables Enum.map(
                       ~w(BUILDS ALLOW_IN_PROCESS_BUILDS BUILD_TIMEOUT_MS BUILD_CARGO_SEED
                          MAX_CONCURRENT_BUILDS MAX_CONCURRENT_BUILDS_PER_TENANT),
                       &("CYFR_" <> &1)
                     )
  @retired_prefix "CYFR_" <> "BUILDER_"
  @retired_keys ~w(builder_url builder_token builder_listen builder_port builder_bind
                   builds_enabled build_timeout_ms build_cargo_seed max_concurrent_builds
                   max_concurrent_builds_per_tenant) ++ ["allow_in_" <> "process_builds"]

  defp retired_scan_files do
    [
      "config/*.exs",
      "apps/*/lib/**/*.{ex,exs}",
      "apps/*/mix.exs",
      "apps/codex/**/*.go",
      "scripts/*",
      "tests/**/*.{py,yml,mjs}",
      "docker-compose.yml",
      "Dockerfile*",
      ".env*.example",
      "README.md",
      "integration-guide.md",
      "component-guide.md",
      "tincture-guide.md",
      ".github/workflows/*.yml"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(root(), &1), match_dot: true))
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
    |> Enum.uniq()
  end

  test "no retired build setting is named anywhere a setting is read, shipped or documented" do
    files = retired_scan_files()
    assert length(files) > 50, "the scan found only #{length(files)} files"

    variable =
      ~r/#{Regex.escape(@retired_prefix)}|\b(?:#{Enum.map_join(@retired_variables, "|", &Regex.escape/1)})\b/

    key = ~r/:(?:#{Enum.join(@retired_keys, "|")})\b/

    hits =
      for path <- files,
          File.regular?(path),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(variable, line) or Regex.match?(key, line),
          do: "#{Path.relative_to(path, root())}:#{n}: #{String.trim(line)}"

    assert hits == [],
           """
           Retired build settings are still named:

           #{Enum.join(hits, "\n")}

           The builder is configured by LOCUS_BUILDS_* on the locus release
           (Locus.Config), and this server by CYFR_LOCUS_BUILDS_URL and
           CYFR_LOCUS_BUILDS_KEY alone.
           """
  end

  test "the builds service's two keys are wired, and read through their accessors alone" do
    for key <- ~w(locus_builds_url locus_builds_key) do
      declared =
        for path <- Prima.Test.SourceTree.files!(Path.join(root(), "config/*.exs")),
            File.read!(path) =~ ~r/config :cyfr, :#{key},/,
            do: Path.basename(path)

      assert declared == ["runtime.exs"], "#{key} is declared in #{inspect(declared)}"
    end

    readers =
      for lib <- Prima.Test.SourceTree.app_libs(root()),
          path <- Prima.Test.SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
          Prima.Test.SourceTree.read(path) =~
            ~r/Application\.get_env\(:cyfr, :locus_builds_(url|key)\)/,
          do: Path.relative_to(path, root())

    assert readers == ["apps/cyfr/lib/cyfr/runtime_config.ex"]
  end
end
