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
  apply the corresponding default.

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
    assert src =~ "case Cyfr.RuntimeConfig.switch(getenv, key, default) do"
  end

  test "no switch is read by comparing its string" do
    offenders =
      for path <- [@runtime_exs, @runtime_config_ex],
          {line, n} <- path |> File.read!() |> Cyfr.Test.CodeLines.code_lines(),
          Regex.match?(@env_read, line) and Regex.match?(@string_compared_switch, line),
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "switches read by string comparison instead of the strict parser:\n" <>
             Enum.join(offenders, "\n")
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

  # The `builder` release runs neither side of the worker wire, and still
  # reads the build settings it shares with CYFR: a gate that skipped them
  # left the builder with no listener, since CYFR_BUILDER_LISTEN was never
  # read there.
  test "the builder release reads the build settings, and nothing else of CYFR's" do
    src = source()

    assert src =~ ~S|builder_boot? = release_name == "builder"|
    assert src =~ ~S|if cyfr_boot? or builder_boot? do|

    [_, shared] = String.split(src, "if cyfr_boot? or builder_boot? do", parts: 2)
    [cyfr_only, rest] = String.split(shared, ~S|config :cyfr, :builder_url|, parts: 2)

    assert cyfr_only =~ "if not builder_boot? do"
    assert cyfr_only =~ "CYFR_CRYPTO_KEYRING"
    assert rest =~ ~S|env_bool.("CYFR_BUILDER_LISTEN", false)|
  end

  # The pool's bounds and the worker watch's are read through the strict
  # readers, so a set value that does not parse refuses the boot by name.
  test "the Opus pool bounds and the worker watch bounds are read strictly" do
    src = source()

    for name <- ~w(OPUS_POOL_SIZE OPUS_IDLE_TTL_MS OPUS_WATCHDOG_GRACE_MS OPUS_RELEASE_GRACE_MS) do
      assert src =~ ~s|opus_bound.("#{name}", |, "#{name} must go through the strict bound reader"
      refute src =~ ~s|env_int.("#{name}"|, "#{name} must not be read with env_int"
    end

    assert src =~ ~S|Opus.Settings.pool(opus_pool, System.get_env())|
    assert src =~ ~S|Cyfr.RuntimeConfig.resolve_worker_watch(getenv)|
    assert src =~ ~S|"local" ->|, "OPUS_KEEPER=local must be refused by name"
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
