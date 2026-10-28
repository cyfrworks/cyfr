# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeEnvReadingTest do
  @moduledoc """
  How `config/runtime.exs` reads the environment, pinned at the source:
  a variable that is present but empty reads as unset, and a switch is
  parsed, never compared as a string. `Cyfr.RuntimeConfigWiringTest`
  evaluates the file; this holds the shape of its reads.

  Blank environment values take their defaults: Dotenvy's optional
  `:string?` type returns nil for a blank, and `env_str`, `env_list` and
  `env_bool` apply the default.
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

           Use env_str./env_list./env_bool. instead. A raw `env!` with a plain
           `:string` type reads a present-but-empty variable as the value ""
           rather than as unset.
           """
  end

  test "the helpers are built on the nil-on-blank Dotenvy types" do
    src = source()

    assert src =~ "env_str = fn key, default -> env!(key, :string?, nil) || default end"
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

  # How the home is reached is one resolution of every access setting
  # (`Cyfr.RuntimeConfig.resolve_access/1`), from the names the .env files
  # assign and the merged environment, and everything this file writes of
  # it comes from the answer: a second read of one of its settings here
  # could disagree with the one the boot checked.
  @access_keys ~w(CYFR_ACCESS CYFR_HOST CYFR_TAILNET_NODE_ID CYFR_PUBLIC_URL CADDY_ACME_EMAIL
                 CYFR_PORT CYFR_BIND_ADDRESS CYFR_LOCAL_INGRESS_ASSERTED CYFR_PROXY_BIND_ADDRESS
                 CYFR_PROXY_PORT CYFR_TRUSTED_PROXY_HOPS CYFR_TRUSTED_PROXY_CIDRS)

  test "the access settings are read by their resolver alone, from the file's own read and the merged one" do
    src = source()

    assert src =~
             ~S|file_env =
    if Enum.any?(env_files, &File.regular?/1),
      do: Cyfr.EnvFiles.source!(env_files, side_effect: false)|

    assert src =~ ~S|sourced = Cyfr.EnvFiles.source!(env_files ++ [System.get_env()])|

    assert src =~
             ~S|Cyfr.RuntimeConfig.resolve_access(%{
           file: file_env,
           process: sourced,
           release?: Cyfr.RuntimeConfig.release?()
         })|

    assert src =~ ~S|raise "[Cyfr] FATAL: " <> Prima.Refusal.message({code, payload})|

    for key <- @access_keys do
      refute src =~ ~s|"#{key}"|, "config/runtime.exs reads #{key} itself"
    end
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

  # Every platform setting is read through its roster entry
  # (`Cyfr.Platform.Settings.Roster.read/2`), whose validator is the one
  # definition of its floor and range: the file spells none of their
  # variables itself, so no second, hand-written bound can disagree with
  # the roster's.
  test "the platform settings are read through the roster" do
    src = source()

    assert src =~ ~S|roster.read(entry, getenv)|
    assert src =~ ~S[roster.unknown(Map.keys(file_env || %{}), Map.keys(System.get_env()))]

    for name <- Cyfr.Platform.Settings.Roster.variables() do
      refute src =~ ~s|"#{name}"|, "config/runtime.exs spells the rostered #{name} itself"
    end
  end

  # Dotenvy is a dependency; this is the behaviour the helpers above rest
  # on, asserted so an upgrade that changes it fails here rather than
  # silently changing what a blank line means.
  test "Dotenvy's :string? type reads a blank as absent, and :string as the value" do
    assert Dotenvy.Transformer.to!("", :string?) == nil
    assert Dotenvy.Transformer.to!("", :string) == ""
  end
end
