# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeEnvReadingTest do
  @moduledoc """
  How `config/runtime.exs` reads the environment, pinned at the source.

  The file is wrapped in `if config_env() != :test`, so nothing in it runs
  during the suite and its reads cannot be exercised directly. What can be
  checked is the shape of the reads — and the shape is the whole invariant:
  a variable that is present but empty must read as unset.

  Blank environment values must use configured defaults. Optional
  Dotenvy types return nil for blanks; env_str, env_int, and env_bool
  apply the corresponding default. The one exception is the setting whose
  blank value is a value — the CORS allowlist, pinned below — which is
  read by its assignment through `env_assigned`.

  Boolean settings must be parsed as booleans; the string "false"
  is truthy in Elixir.
  """

  use ExUnit.Case, async: true

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)
  @runtime_config_ex Path.expand("../../lib/cyfr/runtime_config.ex", __DIR__)

  # A switch compared as a string reads `on` as off and a typo as the
  # default; every boolean setting goes through the strict parser, which
  # refuses an unrecognised spelling at boot.
  @env_read ~r/\b(env_str|getenv)\.\(|\benv!\(/
  @string_compared_switch ~r/(==|!=)\s*"(true|false|on|off|yes|no|1|0)"|\bin \["(true|false|on|off|yes|no|1|0)"/

  defp source, do: File.read!(@runtime_exs)

  # The helper definitions themselves are the only sanctioned raw reads.
  defp raw_reads(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, "env!(") end)
    |> Enum.reject(fn {line, _n} -> String.contains?(line, "env!(key,") end)
  end

  test "the runtime config file exists where this test expects it" do
    assert File.exists?(@runtime_exs)
  end

  test "every environment read goes through a blank-is-unset helper" do
    leftover = raw_reads(source())

    assert leftover == [],
           """
           config/runtime.exs reads the environment directly at:

           #{Enum.map_join(leftover, "\n", fn {line, n} -> "  #{n}: #{String.trim(line)}" end)}

           Use env_str./env_int./env_bool. instead. A raw `env!` with a plain
           `:string`/`:integer`/`:boolean` type reads a present-but-empty
           variable as a value ("" becomes 0, or false, or a truthy string)
           rather than as unset.
           """
  end

  test "the helpers are built on the nil-on-blank Dotenvy types" do
    src = source()

    assert src =~ "env_str = fn key, default -> env!(key, :string?, nil) || default end"
    assert src =~ "env_int = fn key, default -> env!(key, :integer?, nil) || default end"
    assert src =~ "case Prima.EnvValue.switch(getenv, key, default) do"
  end

  test "no switch is read by comparing its string" do
    offenders =
      for path <- [@runtime_exs, @runtime_config_ex],
          {line, n} <- path |> File.read!() |> Prima.Test.CodeLines.code_lines(),
          Regex.match?(@env_read, line) and Regex.match?(@string_compared_switch, line),
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "switches read by string comparison instead of the strict parser:\n" <>
             Enum.join(offenders, "\n")
  end

  # The allowlist's empty value is its meaning: no cross-origin caller at
  # all, which is what `.env.example` promises and what the shipped stack
  # assigns, while its configured default is the wildcard
  # (`config/config.exs`) that `Cyfr.Application.cors_enforcement/3`
  # refuses for an authenticated release. Read as blank-is-unset, an
  # operator who assigned the empty allowlist got the wildcard and a
  # release that would not boot. It is the only read that may take the
  # assignment for the value, so the exception cannot spread unnoticed.
  test "CYFR_CORS_ALLOWED_ORIGINS is the one read whose assigned empty value is a value" do
    src = source()

    assert src =~ ~S|env_assigned = fn key -> env!(key, :string, nil) end|
    assert src =~ ~S|if env_assigned.("CYFR_CORS_ALLOWED_ORIGINS") do|
    assert src =~ ~S|config :cyfr, :cors_allowed_origins, env_list.("CYFR_CORS_ALLOWED_ORIGINS")|

    refute src =~ ~S|env_str.("CYFR_CORS_ALLOWED_ORIGINS"|,
           "CYFR_CORS_ALLOWED_ORIGINS must not be read as blank-is-unset: an assigned " <>
             "empty allowlist would read as no answer and leave the wildcard standing"

    read_by_assignment =
      ~r/env_assigned\.\("([A-Z0-9_]+)"\)/
      |> Regex.scan(src, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert read_by_assignment == ["CYFR_CORS_ALLOWED_ORIGINS"],
           "these settings read their assignment rather than their value: " <>
             inspect(read_by_assignment)
  end

  test "CYFR_BEHIND_PROXY is read as a boolean, once" do
    src = source()

    assert src =~ ~S|behind_proxy? = env_bool.("CYFR_BEHIND_PROXY", false)|,
           "CYFR_BEHIND_PROXY must be read with env_bool — read as a string and " <>
             "tested for truthiness, the value \"false\" enables XFF trust"

    refute src =~ ~S|env_str.("CYFR_BEHIND_PROXY"|,
           "CYFR_BEHIND_PROXY must not be read as a string"
  end

  # The `opus` release boots as the service or, started by the service's
  # keeper, as a runner (`OPUS_ROLE=runner`). A runner holds no credential
  # and starts no listener: the block that reads the service's credentials
  # and pool must run for the service role alone, or every runner boot
  # would refuse for the OPUS_SERVICE_KEY it must never see.
  test "the opus release configures the service's credentials and pool for the service role alone" do
    src = source()

    assert src =~
             ~S|Opus.Release.role(%{"OPUS_ROLE" => env_str.("OPUS_ROLE", nil)})|,
           "the role must be read as Opus.Release reads it"

    assert src =~ ~S|opus_boot? = opus_role == :service|
    assert src =~ ~S|if opus_boot? do|
    refute src =~ ~S|opus_boot? = release_name in [nil, "opus"]|
  end

  # Three releases, two runtime files: the `locus` release is configured by
  # `config/locus_runtime.exs` alone, so this file skips its CYFR half for
  # the `opus` release and for nothing else, and names no other release.
  test "the CYFR half is skipped for the opus release alone" do
    src = source()

    assert src =~ ~S|cyfr_boot? = release_name != "opus"|
    assert src =~ ~S|if cyfr_boot? do|

    named =
      ~r/release_name\s*(?:==|!=|in|not in)\s*(\[[^\]]*\]|"[^"]*")/
      |> Regex.scan(src, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(&Regex.scan(~r/"([^"]*)"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    assert named == ["opus"], "runtime.exs names releases other than opus: #{inspect(named)}"
    refute src =~ ~r/builder_boot\?|"builder"/
  end

  # The builds service is two variables read by one resolver, both or
  # neither, written as the two keys `Compendium.Builds.Client` reads.
  test "the builds service is read through resolve_locus_builds and written as its two keys" do
    src = source()

    assert src =~ ~S|Cyfr.RuntimeConfig.resolve_locus_builds(getenv)|
    assert src =~ ~S|config :cyfr, :locus_builds_url, locus_builds && locus_builds.url|
    assert src =~ ~S|config :cyfr, :locus_builds_key, locus_builds && locus_builds.key|
    refute src =~ ~S|env_str.("CYFR_LOCUS_BUILDS|
  end

  # The pool's bounds and the worker watch's are read through the strict
  # readers, so a set value that does not parse refuses the boot by name.
  test "the Opus pool bounds and the worker watch bounds are read strictly" do
    src = source()

    for name <- ~w(OPUS_POOL_SIZE OPUS_IDLE_TTL_MS OPUS_WATCHDOG_GRACE_MS OPUS_RELEASE_GRACE_MS) do
      assert src =~ ~s|opus_bound.("#{name}", |, "#{name} must go through the strict bound reader"
      refute src =~ ~s|env_int.("#{name}"|, "#{name} must not be read with env_int"
    end

    # The runner's memory bound is a byte count, whose range the bound
    # reader cannot hold: it is read by the byte reader, in the keeper's range.
    assert src =~ ~S|runner_memory_bytes: opus_bytes.("OPUS_RUNNER_MEMORY_BYTES")|
    assert src =~ ~S|Prima.EnvValue.bytes(getenv, key, Opus.Settings.runner_memory_range())|
    refute src =~ ~S|env_int.("OPUS_RUNNER_MEMORY_BYTES"|
    refute src =~ ~S|opus_bound.("OPUS_RUNNER_MEMORY_BYTES"|

    assert src =~ ~S|Opus.Settings.pool(opus_pool, System.get_env())|
    assert src =~ ~S|Cyfr.RuntimeConfig.resolve_worker_watch(getenv)|

    assert src =~ ~S|names no keeper; use spawn or direct|,
           "OPUS_KEEPER must name spawn or direct, or refuse the boot"

    refute src =~ ~S|"local" ->|, "OPUS_KEEPER names two keepers, and local is neither"
  end

  # Dotenvy is a dependency; these are the behaviours the helpers above
  # depend on, asserted so an upgrade that changes them fails here rather
  # than silently changing what a blank line means.
  describe "the Dotenvy contract the helpers rest on" do
    test "plain types treat blank as a value" do
      assert Dotenvy.Transformer.to!("", :integer) == 0
      assert Dotenvy.Transformer.to!("", :boolean) == false
      assert Dotenvy.Transformer.to!("", :string) == ""
    end

    test "the ? types treat blank as absent" do
      assert Dotenvy.Transformer.to!("", :integer?) == nil
      assert Dotenvy.Transformer.to!("", :boolean?) == nil
      assert Dotenvy.Transformer.to!("", :string?) == nil
    end

    test "a real false is still false, not blank" do
      assert Dotenvy.Transformer.to!("false", :boolean?) == false
      assert Dotenvy.Transformer.to!("0", :boolean?) == false
      assert Dotenvy.Transformer.to!("true", :boolean?) == true
    end

    test "a real zero survives the || default in env_int" do
      # 0 is truthy in Elixir, so `env!(...) || default` keeps an explicit 0
      # (CYFR_SESSION_TTL_HOURS=0 means infinite, and must not become 720).
      assert (Dotenvy.Transformer.to!("0", :integer?) || 720) == 0
    end
  end
end
