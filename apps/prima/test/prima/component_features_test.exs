# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentFeaturesTest do
  @moduledoc """
  The validator a component passes before it is stored or compiled: the
  pinned wasm-tools accepts each refused feature's name, a shipped
  component passes it, and it fails closed. A validator not installed,
  answering other than valid or invalid, or past its deadline refuses the
  component; it reads the component on its standard input with no
  environment, and nothing of the component is written anywhere. Which
  component each refused
  feature refuses is `Locus.Runtime.ComponentFeaturesTest`'s, beside the
  hostile guests.

  Each test that installs another validator puts the configured one back.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.ComponentFeatures

  @catalyst Path.expand(
              "../../../../seed/components/catalysts/local/http/1.1.2/catalyst.wasm",
              __DIR__
            )

  setup do
    configured = Application.fetch_env!(:prima, :wasm_tools)

    on_exit(fn ->
      Application.put_env(:prima, :wasm_tools, configured)
      Application.delete_env(:prima, :wasm_tools_timeout_ms)
      :ok = ComponentFeatures.install!()
    end)

    %{validator: configured}
  end

  # A stand-in validator: a shell script, its body a function of its own
  # directory, with no PATH to look anything up by, since the check hands
  # it an empty environment. One that answers reads its input to the end
  # first, as wasm-tools does.
  defp fake!(body) do
    dir = Path.join(System.tmp_dir!(), "fake-validator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "wasm-tools")
    File.write!(path, "#!/bin/sh\n" <> body.(dir) <> "\n")
    File.chmod!(path, 0o755)
    {dir, path}
  end

  # The validator runs as the check runs it, with no environment: a nil value
  # unsets each inherited name.
  defp no_env, do: Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

  defp install!(path) do
    Application.put_env(:prima, :wasm_tools, path)
    ComponentFeatures.install!()
  end

  test "the pinned validator accepts every refused feature's name, and a shipped component passes",
       %{validator: validator} do
    bytes = File.read!(@catalyst)
    assert ComponentFeatures.check(bytes) == :ok

    # An unknown name is a usage error (status 2), never a refusal of the
    # component; each name the check passes is the pinned version's own.
    for flag <- ComponentFeatures.refused() do
      assert {_output, 0} =
               System.cmd(validator, ["validate", "--features=-" <> flag, @catalyst],
                 env: no_env()
               )
    end

    assert {_output, 2} =
             System.cmd(validator, ["validate", "--features=-no-such-feature", @catalyst],
               env: no_env(),
               stderr_to_stdout: true
             )
  end

  test "install! refuses a path that is not absolute, names nothing, or is not executable" do
    {dir, _path} = fake!(fn _dir -> "exit 0" end)
    plain = Path.join(dir, "plain")
    File.write!(plain, "")
    File.chmod!(plain, 0o644)

    for {path, words} <- [
          {"_tools/wasm-tools", "is not an absolute path"},
          {Path.join(dir, "missing"), "names no executable file"},
          {plain, "names no executable file"},
          {dir, "names no executable file"}
        ] do
      assert_raise ArgumentError, ~r/#{words}/, fn -> install!(path) end
    end
  end

  test "with no validator installed, a component is refused unchecked" do
    :persistent_term.erase({ComponentFeatures, :validator})

    log =
      capture_log(fn ->
        assert ComponentFeatures.check(File.read!(@catalyst)) ==
                 {:error, :component_validator_unavailable}
      end)

    assert log =~ "no validator is installed"
  end

  test "a validator that ends other than valid or invalid refuses the component" do
    {_dir, path} = fake!(fn _dir -> "/usr/bin/cat > /dev/null\nexit 3" end)
    install!(path)

    log =
      capture_log(fn ->
        assert ComponentFeatures.check(File.read!(@catalyst)) ==
                 {:error, :component_validator_unavailable}
      end)

    assert log =~ "it ended with status 3"
  end

  test "a validator that refuses with its own defaults too names the component invalid" do
    {_dir, path} = fake!(fn _dir -> "/usr/bin/cat > /dev/null\nexit 1" end)
    install!(path)
    bytes = File.read!(@catalyst)

    capture_log(fn ->
      assert ComponentFeatures.check(bytes) ==
               {:error, {:component_invalid, Prima.Digest.sha256(bytes)}}
    end)
  end

  test "a validator past its deadline is killed with its process group, and the component refused" do
    {dir, path} = fake!(&"echo $$ > #{&1}/pid\nexec /bin/sleep 30")
    install!(path)
    Application.put_env(:prima, :wasm_tools_timeout_ms, 300)

    log =
      capture_log(fn ->
        assert ComponentFeatures.check(File.read!(@catalyst)) ==
                 {:error, :component_validator_unavailable}
      end)

    assert log =~ "did not answer within 300 ms and was killed"
    pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
    Prima.Test.Wait.wait_until(fn -> not running?(pid) end, 5_000, "the validator to be gone")
  end

  test "the validator reads the component on its input, with an empty environment" do
    {dir, path} =
      fake!(fn dir ->
        ~s"""
        /usr/bin/cat > #{dir}/received
        /usr/bin/env > #{dir}/env
        exit 0
        """
      end)

    install!(path)
    System.put_env("CYFR_VALIDATOR_ENV_PROBE", "must-not-leak")
    on_exit(fn -> System.delete_env("CYFR_VALIDATOR_ENV_PROBE") end)
    bytes = File.read!(@catalyst)
    before = Path.wildcard(Path.join(System.tmp_dir!(), "*"))

    assert ComponentFeatures.check(bytes) == :ok

    assert File.read!(Path.join(dir, "received")) == bytes
    env = File.read!(Path.join(dir, "env"))
    refute env =~ "CYFR_VALIDATOR_ENV_PROBE"
    refute env =~ "HOME="
    assert Path.wildcard(Path.join(System.tmp_dir!(), "*")) -- before == []
  end

  # Whether the process `pid` names still runs: gone, or a zombie its
  # killed parent left for init to reap.
  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not String.contains?(stat, ") Z ")
      {:error, _} -> false
    end
  end
end
