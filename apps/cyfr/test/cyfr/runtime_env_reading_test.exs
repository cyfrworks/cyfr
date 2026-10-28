# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimeEnvReadingTest do
  @moduledoc """
  How `config/runtime.exs` reads the environment, pinned at the source and by
  evaluation: a variable that is present but empty reads as unset, and a switch
  is parsed, never compared as a string. `Cyfr.RuntimeConfigWiringTest`
  evaluates the file across its settings; this holds the shape of its reads.

  Blank environment values take their defaults: Dotenvy's optional `:string?`
  type returns nil for a blank, and `env_str`, `env_list` and `env_bool` apply
  the default.
  """

  # The tests set the environment the file reads, so they run one at a time.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)
  @runtime_config_ex Path.expand("../../lib/cyfr/runtime_config.ex", __DIR__)

  # A switch compared as a string reads `on` as off and a typo as the default;
  # every boolean setting goes through the strict parser, which refuses an
  # unrecognised spelling at boot.
  @env_read ~r/\b(env_str|getenv)\.\(|\benv!\(/
  @string_compared_switch ~r/(==|!=)\s*"(true|false|on|off|yes|no|1|0)"|\bin \["(true|false|on|off|yes|no|1|0)"/

  # Every setting the access resolver reads.
  @access_keys ~w(CYFR_ACCESS CYFR_HOST CYFR_TAILNET_NODE_ID CYFR_PUBLIC_URL CADDY_ACME_EMAIL
                 CYFR_PORT CYFR_BIND_ADDRESS CYFR_LOCAL_INGRESS_ASSERTED CYFR_PROXY_BIND_ADDRESS
                 CYFR_PROXY_PORT CYFR_TRUSTED_PROXY_HOPS CYFR_TRUSTED_PROXY_CIDRS)

  # The variables the evaluations set or clear, so a case starts from none of them.
  @controlled @access_keys ++
                ~w(CYFR_LOCUS_BUILDS_URL CYFR_LOCUS_BUILDS_KEY CYFR_CLUSTER CYFR_CRYPTO_KEYRING
                   CYFR_OPUS_MAX_CONCURRENT)

  @builds_key :binary.copy(<<7>>, 32)

  defp source, do: File.read!(@runtime_exs)

  # The helper definitions themselves are the only sanctioned raw reads.
  defp raw_reads(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, "env!(") end)
    |> Enum.reject(fn {line, _n} -> String.contains?(line, "env!(key,") end)
  end

  # The environment a boot is evaluated in: a release named cyfr, local access,
  # a secret, and none of the variables the evaluations set.
  defp base_env do
    @controlled
    |> Map.new(&{&1, nil})
    |> Map.merge(%{
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr",
      "CYFR_ACCESS" => "local"
    })
  end

  # Public so the process-death probe at the end of this file can run it in a
  # child VM. A test killed mid-body runs no `after`, but its on_exit does: the
  # restore is registered before the change, and the `after` is the fast path
  # that puts the variables back before the test goes on.
  def with_env(overrides, fun) do
    env = Map.merge(base_env(), overrides)
    previous = Map.new(env, fn {k, _} -> {k, System.get_env(k)} end)

    restore = fn ->
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end

    on_exit(restore)

    try do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      restore.()
    end
  end

  defp read_prod_config! do
    Config.Reader.read!(@runtime_exs, env: :prod, imports: :disabled)
  end

  # A directory of the test's own under the runner's TMPDIR, so no .env file
  # the checkout holds supplies a setting; removed after the test.
  defp scratch_dir do
    dir =
      Path.join(System.tmp_dir!(), "runtime_env_reading_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    dir
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

  # The helpers' contract, evaluated: a blank reads as the default (nil for a
  # value with none), and a switch is the strict parser's answer, refused when
  # it is not a switch.
  test "a blank value reads as unset, and a switch is read by the strict parser" do
    with_env(%{"CYFR_CLUSTER" => "", "CYFR_CRYPTO_KEYRING" => ""}, fn ->
      cyfr = read_prod_config!()[:cyfr]

      assert cyfr[:cluster] == false
      assert cyfr[:crypto_keyring_json] == nil
    end)

    with_env(%{"CYFR_CLUSTER" => "on"}, fn ->
      assert read_prod_config!()[:cyfr][:cluster] == true
    end)

    with_env(%{"CYFR_CLUSTER" => "yes"}, fn ->
      message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
      assert message =~ "CYFR_CLUSTER"
    end)
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
  # (`Cyfr.RuntimeConfig.resolve_access/1`), and it gates the boot: a release
  # without a mode refuses with the sentence that names its fix, and local access
  # boots.
  test "the access settings are resolved from the environment, and a release without a mode refuses" do
    dir = scratch_dir()

    with_env(%{"CYFR_ACCESS" => nil, "RELEASE_ROOT" => dir}, fn ->
      message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))

      assert message == "[Cyfr] FATAL: " <> Prima.Refusal.message({:access_missing, %{}})
    end)

    with_env(%{"CYFR_ACCESS" => "local"}, fn ->
      assert is_list(read_prod_config!()[:cyfr][:mcp_allowed_origins])
    end)
  end

  test "config/runtime.exs spells no access setting itself" do
    src = source()

    for key <- @access_keys do
      refute src =~ ~s|"#{key}"|, "config/runtime.exs reads #{key} itself"
    end
  end

  # The CYFR half is configured for every boot that reads the file, and no
  # release is named.
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

  # The builds service is two variables read by one resolver, both or neither,
  # written as the two keys `Compendium.Builds.Client` reads.
  test "the builds service is written as its URL and key, both or neither" do
    with_env(
      %{
        "CYFR_LOCUS_BUILDS_URL" => "http://locus-builds:4100/",
        "CYFR_LOCUS_BUILDS_KEY" => Base.encode16(@builds_key)
      },
      fn ->
        cyfr = read_prod_config!()[:cyfr]

        assert cyfr[:locus_builds_url] == "http://locus-builds:4100"
        assert cyfr[:locus_builds_key] == @builds_key
      end
    )

    with_env(%{"CYFR_LOCUS_BUILDS_URL" => nil, "CYFR_LOCUS_BUILDS_KEY" => nil}, fn ->
      cyfr = read_prod_config!()[:cyfr]

      assert cyfr[:locus_builds_url] == nil
      assert cyfr[:locus_builds_key] == nil
    end)
  end

  test "the builds variables are not read through env_str" do
    refute source() =~ ~S|env_str.("CYFR_LOCUS_BUILDS|
  end

  # Every platform setting is read through its roster entry, which validates it
  # and pins the value; a CYFR name no roster declares refuses the boot naming it.
  test "a platform setting is read through the roster and pinned, and an undeclared name refuses" do
    with_env(%{"CYFR_OPUS_MAX_CONCURRENT" => "33"}, fn ->
      assert {"opus_max_concurrent", 33} in read_prod_config!()[:cyfr][:deployment_pinned]
    end)

    with_env(%{"CYFR_NOT_A_SETTING" => "1"}, fn ->
      message = Exception.message(assert_raise(RuntimeError, &read_prod_config!/0))
      assert message =~ "CYFR_NOT_A_SETTING"
    end)
  end

  test "config/runtime.exs spells no rostered variable itself" do
    src = source()

    for name <- Cyfr.Platform.Settings.Roster.variables() do
      refute src =~ ~s|"#{name}"|, "config/runtime.exs spells the rostered #{name} itself"
    end
  end

  # Dotenvy is a dependency; this is the behaviour the helpers above rest on,
  # asserted so an upgrade that changes it fails here rather than silently
  # changing what a blank line means.
  test "Dotenvy's :string? type reads a blank as absent, and :string as the value" do
    assert Dotenvy.Transformer.to!("", :string?) == nil
    assert Dotenvy.Transformer.to!("", :string) == ""
  end

  # A test killed mid-body runs no `after`, so the helper's restore has to come
  # from its on_exit. A killed test takes a VM of its own: the probe runs one in
  # a child VM and reports how many tests ran, how many failed, and whether the
  # environment changed.
  @tag timeout: 120_000
  test "a test killed mid-body leaves the environment as its helper found it" do
    probe = ~S"""
    ExUnit.start(autorun: false, exclude: [:test], include: [death: true])
    {:ok, _} = Application.ensure_all_started(:crypto)
    System.put_env("CYFR_CLUSTER", "off")
    before = System.get_env()
    Code.require_file(System.fetch_env!("CYFR_RUNTIME_ENV_READING_TEST"))

    defmodule DeathProbe do
      use ExUnit.Case, async: false

      @tag :death
      test "killed mid-body" do
        Cyfr.RuntimeEnvReadingTest.with_env(%{"CYFR_CLUSTER" => "on"}, fn ->
          Process.exit(self(), :kill)
        end)
      end
    end

    result = ExUnit.run()
    IO.puts("ran=#{result.total - result.excluded} failures=#{result.failures} leaked=#{System.get_env() != before}")
    """

    {output, _status} =
      System.cmd("mix", ["run", "--no-start", "-e", probe],
        cd: Path.expand("../../../..", __DIR__),
        env: [{"MIX_ENV", "test"}, {"CYFR_RUNTIME_ENV_READING_TEST", __ENV__.file}],
        stderr_to_stdout: true
      )

    assert output =~ "ran=1 failures=1 leaked=false", output
  end
end
