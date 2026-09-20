# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ConfigKeyRosterTest do
  @moduledoc """
  Classifies every :cyfr application key read by the code.
  Unclassified keys fail the roster check.

  The classes:

  - `:operator` — a real lever. `config/runtime.exs` reads a `CYFR_*`
    variable into it, so a deployment can change it without a rebuild.
  - `:default` — a value the code owns, declared in `config/config.exs` (or
    carried as the third argument to `get_env/3`). Changing it is a code
    change, deliberately.
  - `:seam` — a test hook: a module swap, or a switch that runs inline what
    production runs in a task. Deliberately NOT in `config/runtime.exs`;
    declaring one would publish it as a supported setting.
  - `:missing_lever` — reads like an operator's knob and has no variable to
    set it with. This list is the honest record of that gap, not an
    endorsement: promoting one means adding the `CYFR_*` read in
    `runtime.exs` and a line in `.env.example`, then moving it to
    `:operator` here.

  The audit that produced this found the third and fourth classes tangled:
  a review counted "twelve operator-facing knobs that are compile-time
  only" without distinguishing a test seam from a real gap, and the tree
  offered no way to tell them apart.
  """

  use ExUnit.Case, async: true

  # Keys with no `config :cyfr, …` declaration anywhere, classified.
  @unwired %{
    # Test seams — see `Sanctum.Auth.DeviceFlow.impl/0` for the rule.
    allow_tenancy_resolver_override: :seam,
    tenancy_resolver_override: :seam,
    tool_providers_lenient: :seam,
    thread_recovery: :seam,
    device_flow: :seam,
    device_flow_endpoints: :seam,
    provisioning_inline: :seam,
    record_sink_inline: :seam,

    # Boot switches with an in-code default; flipping one is a code change.
    cron_scheduler_enabled: :default,
    execution_sweeper_enabled: :default,
    execution_archive_watch_enabled: :default,
    worker_watch_enabled: :default,
    external_server_reconciler_enabled: :default,
    provisioning_boot_enabled: :default,
    retention_scheduler_enabled: :default,
    control_plane_claim_enabled: :default,
    database_checks_enabled: :default,
    telemetry_console_enabled: :default,

    # Operator-shaped, with nothing to set them from. Each has a sensible
    # in-code default, so this is a gap in reach, not a broken deployment.
    oci_max_blob_bytes: :missing_lever,
    webhook_max_body_bytes: :missing_lever,
    platform_ceiling: :missing_lever,
    registry_scheme: :missing_lever
  }

  # Keys declared ONLY in `config/test.exs`.
  #
  # `:default_test_namespace` was here and is not: its one reader is
  # `Sanctum.TestContext`, a test-support fixture, and the scan below
  # reads each app's `lib` alone. A key no application code reads is not
  # application configuration, whatever a config file still sets, so it
  # has no class in this roster. Widening the scan to `test/support`
  # would change what the roster means — "keys the application reads"
  # becomes "keys anything reads" — and pull in every fixture's `:cyfr`
  # read with it.
  @test_only %{
    establish_cache_ms: :seam,
    namespace_cache_ttl_ms: :seam,
    registry_health_probe: :seam,

    # `TinctureRateLimit`'s own moduledoc calls this an override an operator
    # sets, and only the suite can set it.
    tincture_rate_limit_max: :missing_lever
  }

  defp root, do: Path.expand("../../../..", __DIR__)

  # `Application.get_env/fetch_env/compile_env` on `:cyfr`, ignoring
  # comments so a key named in prose is not mistaken for a read.
  defp keys_read do
    for lib <- Cyfr.Test.SourceTree.app_libs(root()),
        path <- Cyfr.Test.SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
        source = Cyfr.Test.SourceTree.read(path),
        code = source |> Cyfr.Test.CodeLines.lines() |> Enum.join("\n"),
        [_, key] <-
          Regex.scan(
            ~r/Application\.(?:get_env|fetch_env!?|compile_env!?)\(\s*:cyfr,\s*:([a-z_0-9]+)/,
            code
          ),
        into: MapSet.new(),
        do: String.to_atom(key)
  end

  # `config :cyfr, :key, …` and the multi-key `config :cyfr,\n  key: …` form.
  defp keys_declared do
    for path <- Cyfr.Test.SourceTree.files!(Path.join(root(), "config/*.exs")),
        source = File.read!(path),
        key <- single_keys(source) ++ block_keys(source),
        reduce: %{} do
      acc -> Map.update(acc, key, [Path.basename(path)], &[Path.basename(path) | &1])
    end
  end

  defp single_keys(source) do
    ~r/config :cyfr,\s*:([a-z_0-9]+)/
    |> Regex.scan(source)
    |> Enum.map(fn [_, k] -> String.to_atom(k) end)
  end

  defp block_keys(source) do
    ~r/^config :cyfr,\s*$((?:\n[ \t]+.*)+)/m
    |> Regex.scan(source)
    |> Enum.flat_map(fn [_, block] ->
      ~r/^\s{2,}([a-z_0-9]+):/m
      |> Regex.scan(block)
      |> Enum.map(fn [_, k] -> String.to_atom(k) end)
    end)
  end

  test "every key the code reads is either wired to config or classified here" do
    declared = keys_declared()

    unclassified =
      for key <- keys_read(),
          where = Map.get(declared, key, []),
          where == [] and not Map.has_key?(@unwired, key),
          do: key

    assert unclassified == [],
           """
           These `:cyfr` keys are read by the code and set by no config file:

           #{Enum.map_join(Enum.sort(unclassified), "\n", &"  #{inspect(&1)}")}

           Say what each one is in `@unwired`: `:operator` if you are adding
           the `CYFR_*` read in `config/runtime.exs` (and the line in
           `.env.example`), `:default` if the value is the code's to own,
           `:seam` if it is a test hook that must stay unpublished, or
           `:missing_lever` if it reads like an operator's knob and does not
           have one yet.
           """
  end

  test "every key set only by config/test.exs is classified here" do
    declared = keys_declared()

    unclassified =
      for key <- keys_read(),
          Map.get(declared, key) == ["test.exs"],
          not Map.has_key?(@test_only, key),
          do: key

    assert unclassified == [],
           """
           These `:cyfr` keys are read in `lib/` and set only by the suite:

           #{Enum.map_join(Enum.sort(unclassified), "\n", &"  #{inspect(&1)}")}

           A key only the suite can set is either a seam (fine — say so) or
           a knob an operator cannot reach (`:missing_lever`).
           """
  end

  test "the roster names no key that is gone or has since been wired" do
    read = keys_read()
    declared = keys_declared()

    stale =
      for {key, _class} <- Map.merge(@unwired, @test_only),
          not MapSet.member?(read, key) or
            Map.get(declared, key, []) not in [[], ["test.exs"]],
          do: key

    assert stale == [],
           """
           The roster names keys that are no longer unwired — deleted, or
           given a config declaration:

           #{Enum.map_join(Enum.sort(stale), "\n", &"  #{inspect(&1)}")}

           Wiring one to `config/runtime.exs` is the good outcome; remove
           its line here when you do.
           """
  end

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
    declared = keys_declared()

    for key <- [:locus_builds_url, :locus_builds_key] do
      assert Map.get(declared, key) == ["runtime.exs"],
             "#{key} is declared in #{inspect(declared[key])}"
    end

    readers =
      for lib <- Cyfr.Test.SourceTree.app_libs(root()),
          path <- Cyfr.Test.SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
          Cyfr.Test.SourceTree.read(path) =~
            ~r/Application\.get_env\(:cyfr, :locus_builds_(url|key)\)/,
          do: Path.relative_to(path, root())

    assert readers == ["apps/cyfr/lib/cyfr/runtime_config.ex"]
  end

  test "the gaps are named, so they are a decision and not an oversight" do
    gaps =
      Map.merge(@unwired, @test_only)
      |> Enum.filter(fn {_k, class} -> class == :missing_lever end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    # A canary, not a target: this list should shrink as knobs are wired,
    # and any change to it should be a deliberate one someone reads.
    assert gaps == [
             :oci_max_blob_bytes,
             :platform_ceiling,
             :registry_scheme,
             :tincture_rate_limit_max,
             :webhook_max_body_bytes
           ]
  end
end
