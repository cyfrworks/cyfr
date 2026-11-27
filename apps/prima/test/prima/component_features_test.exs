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

  The shared vectors (`tests/fixtures/component_features.json`) hold the
  refused features and their families to the module's, each refusal's
  sentence to `Prima.Refusal.message/1`'s, and every case to what
  `check/1` answers with the pinned validator; each feature's guest is
  valid with its feature on and every other refused one off, and invalid
  with its feature off.

  Each test that installs another validator puts the configured one back.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.ComponentFeatures

  @catalyst Path.expand(
              "../../../../seed/components/catalysts/local/http/1.1.5/catalyst.wasm",
              __DIR__
            )

  @root Path.expand("../../../..", __DIR__)

  @vectors Path.join(@root, "tests/fixtures/component_features.json")
           |> File.read!()
           |> Jason.decode!()

  # The features a refused feature's guest needs beside its own, which
  # the validator admits it only with: the stackful ABI and the more async
  # builtins are forms of component-model async, and GC's structs are GC
  # types.
  @builds_on %{
    "cm-async-stackful" => ["cm-async"],
    "cm-more-async-builtins" => ["cm-async"],
    "gc" => ["gc-types"]
  }

  setup do
    configured = Application.fetch_env!(:prima, :wasm_tools)

    on_exit(fn ->
      Application.put_env(:prima, :wasm_tools, configured)
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

    log =
      capture_log(fn ->
        assert ComponentFeatures.check(File.read!(@catalyst)) ==
                 {:error, :component_validator_unavailable}
      end)

    assert log =~ "did not answer within 10000 ms and was killed"
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

    assert ComponentFeatures.check(bytes) == :ok

    assert File.read!(Path.join(dir, "received")) == bytes
    env = File.read!(Path.join(dir, "env"))
    refute env =~ "CYFR_VALIDATOR_ENV_PROBE"
    refute env =~ "HOME="
    # In the stand-in's owned directory, the check wrote only its receipt
    # files beside the validator executable.
    assert Enum.sort(File.ls!(dir)) == ["env", "received", "wasm-tools"]
  end

  describe "the shared vectors" do
    defp case_bytes(%{"path" => path}), do: File.read!(Path.join(@root, path))
    defp case_bytes(%{"hex" => hex}), do: Base.decode16!(hex, case: :lower)

    defp outcome(:ok), do: "admitted"
    defp outcome({:error, {refusal, _digest}}), do: Atom.to_string(refusal)

    test "the refused features and their families are the module's" do
      assert @vectors["refused"] == ComponentFeatures.refused()

      assert Enum.map(ComponentFeatures.families(), fn {family, flags} ->
               {Atom.to_string(family), flags}
             end) == Enum.sort_by(@vectors["families"], &family_order/1)

      assert Enum.flat_map(ComponentFeatures.families(), &elem(&1, 1)) ==
               ComponentFeatures.refused()
    end

    test "each refusal's sentence is Prima.Refusal's, its digest in its place" do
      digest = Prima.Digest.sha256("a component")

      for {refusal, sentence} <- @vectors["sentences"] do
        assert Prima.Refusal.message({String.to_existing_atom(refusal), digest}) ==
                 String.replace(sentence, "{digest}", digest)
      end

      assert Enum.sort(Map.keys(@vectors["sentences"])) ==
               ["component_feature_refused", "component_invalid"]
    end

    test "every case is what check/1 answers with the pinned validator" do
      cases = @vectors["cases"]

      capture_log(fn ->
        for vector <- cases do
          assert outcome(ComponentFeatures.check(case_bytes(vector))) == vector["outcome"],
                 vector["why"]
        end
      end)

      features = for %{"feature" => feature} <- cases, do: feature
      assert Enum.sort(features) == Enum.sort(ComponentFeatures.refused())
      assert Enum.any?(cases, &Map.has_key?(&1, "hex"))
      assert Enum.count(cases, &(&1["outcome"] == "admitted")) >= 3
    end

    test "each feature's guest uses its feature and no other refused one", %{validator: validator} do
      for %{"feature" => feature, "path" => path} = vector <- @vectors["cases"] do
        on = [feature | Map.get(@builds_on, feature, [])]
        off = ComponentFeatures.refused() -- on
        file = Path.join(@root, path)

        assert validate(validator, [
                 "--features=" <> Enum.join(on ++ Enum.map(off, &("-" <> &1)), ","),
                 file
               ]) == 0,
               vector["why"]

        assert validate(validator, ["--features=-" <> feature, file]) == 1, vector["why"]
      end
    end
  end

  defp validate(validator, args) do
    {_output, status} =
      System.cmd(validator, ["validate" | args], env: no_env(), stderr_to_stdout: true)

    status
  end

  defp family_order({family, _flags}),
    do: Enum.find_index(ComponentFeatures.families(), &(Atom.to_string(elem(&1, 0)) == family))

  # Whether the process `pid` names still runs: gone, or a zombie its
  # killed parent left for init to reap.
  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> not String.contains?(stat, ") Z ")
      {:error, _} -> false
    end
  end
end
