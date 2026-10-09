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

  # A `mix` boot runs the runtime beside CYFR, and configures it here
  # through the runtime's own reader; the `cyfr` release runs none. A
  # runner never reads this file: it is started as a plain VM, or as the
  # `locus` release, whose runtime file configures nothing for it.
  test "a mix boot alone configures the runtime, through the runtime's own reader" do
    src = source()

    assert src =~ ~S|if release_name == nil do|
    assert src =~ ~S|Locus.Runtime.Settings.from_env(getenv, fallback)|
    assert src =~ ~S|{:ok, runtime} -> config :locus, :runtime, runtime|
    refute src =~ ~S|"RUNTIME_ROLE"|
    refute src =~ ~r/runtime_boot\?|runtime_role|cyfr_boot\?/
  end

  # Two releases, two runtime files: the `locus` release is configured by
  # `config/locus_runtime.exs` alone, so this file configures CYFR for
  # every boot that reads it and names no release.
  test "the CYFR half is configured for every boot, and no release is named" do
    src = source()

    named =
      ~r/release_name\s*(?:==|!=|in|not in)\s*(\[[^\]]*\]|"[^"]*")/
      |> Regex.scan(src, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(&Regex.scan(~r/"([^"]*)"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    assert named == [], "runtime.exs names releases: #{inspect(named)}"
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

  # The runtime's settings are read by the runtime's own strict reader
  # (`Locus.Runtime.Settings.from_env/2`), so this file spells none of its
  # pool's variables, and a set value that does not parse refuses the boot
  # by name there.
  test "the runtime's settings are read by its own reader, and its stray names refused" do
    src = source()

    for name <- ~w(LOCUS_RUNTIME_KEY LOCUS_RUNTIME_HOST_API_URL LOCUS_RUNTIME_BIND
                   LOCUS_RUNTIME_PORT LOCUS_RUNTIME_POOL_SIZE LOCUS_RUNTIME_IDLE_TTL_MS
                   LOCUS_RUNTIME_WATCHDOG_GRACE_MS LOCUS_RUNTIME_RELEASE_GRACE_MS
                   LOCUS_RUNTIME_MEMORY_BYTES LOCUS_RUNTIME_ATTACH_DIR) do
      refute src =~ ~s|"#{name}"|, "config/runtime.exs spells the runtime's #{name} itself"
    end

    # The names are checked against everything this file reads, so a
    # stray `LOCUS_RUNTIME_*` name is refused from an .env file as from the
    # process; the container limits compose reads are the roster's.
    assert src =~ ~S|Locus.Runtime.Settings.unknown_names()|
    assert src =~ ~S|Kernel.--(Cyfr.Platform.Settings.Roster.compose_only())|
    assert src =~ ~S|Locus.Runtime.Settings.unknown(stray)|

    # The keeper is the channel: nothing here reads a choice of another.
    refute src =~ ~S|keeper:|
  end

  # Every platform setting is read through its roster entry
  # (`Cyfr.Platform.Settings.Roster.read/2`), whose validator is the one
  # definition of its floor and range: the file spells none of their
  # variables itself, so no second, hand-written bound can disagree with
  # the roster's. The trusted proxy count, a deployment variable, is read
  # by the strict bound reader from its floor.
  test "the platform settings are read through the roster, and the proxy count strictly" do
    src = source()

    assert src =~ ~S|roster.read(entry, getenv)|
    assert src =~ ~S|roster.unknown(file_names, Map.keys(System.get_env()))|

    for name <- Cyfr.Platform.Settings.Roster.variables() do
      refute src =~ ~s|"#{name}"|, "config/runtime.exs spells the rostered #{name} itself"
    end

    assert src =~ ~S|env_bound.("CYFR_TRUSTED_PROXY_HOPS", 0..16, "proxy hops")|
    refute src =~ ~S|env_int.("CYFR_TRUSTED_PROXY_HOPS"|
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
