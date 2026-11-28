# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncherPairTest do
  @moduledoc """
  The test build's keeper (`Locus.DirectLauncher.Runner`) runs the runner
  program the pool names as the checkout's build of it, the pair, read at
  each spawn through `scripts/runner.sh pair`: a pair whose stamp is not
  the checkout's sources', or a binary that is not there, is the spawn's
  refusal, "the runner program cannot run here: " and the script's
  sentence, and nothing runs; the pair whose stamp is the checkout's is
  what runs. The pair here is a scratch one in a target folder of the
  test's own (`CARGO_TARGET_DIR`, which the script honours), never the
  checkout's, its binary a stand-in that exits. The variable is the
  node's, which every spawn reads, so the module runs alone and restores
  it.
  """

  use ExUnit.Case, async: false

  import Locus.Test.ProcessFamily, only: [event_until: 2]

  alias Locus.DirectLauncher.Runner

  @root Path.expand("../../../..", __DIR__)

  setup do
    unless Process.whereis(Runner), do: start_supervised!(Runner)

    target =
      Path.join(System.tmp_dir!(), "direct_launcher_pair_#{System.unique_integer([:positive])}")

    release = Path.join(target, "release")
    File.mkdir_p!(release)
    on_exit(fn -> File.rm_rf!(target) end)
    Prima.Test.Env.put_system_env("CARGO_TARGET_DIR", target)
    {:ok, release: release}
  end

  defp spawned, do: Runner.spawn(%{argv: Locus.Runtime.Settings.runner_command().argv, env: %{}})

  defp stamp do
    {stamp, 0} =
      System.cmd("/bin/bash", [Path.join(@root, "scripts/runner.sh"), "stamp"],
        env: Locus.Test.ProcessFamily.without_cyfr()
      )

    String.trim(stamp)
  end

  defp stand_in!(release) do
    binary = Path.join(release, "cyfr-runner")
    File.write!(binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(binary, 0o755)
    binary
  end

  defp refused(why),
    do: %{reason: "spawn_failed", message: "the runner program cannot run here: " <> why}

  test "a pair that is not there is the spawn's refusal", %{release: release} do
    assert {:error, {:runner_pair, why} = reason} = spawned()
    assert why == "runner: #{release}/cyfr-runner is not built (scripts/runner.sh build)"
    assert Runner.refusal(reason) == refused(why)
  end

  test "a pair whose stamp is not the checkout's is the spawn's refusal, and the checkout's runs",
       %{release: release} do
    binary = stand_in!(release)
    stamp = stamp()
    stale = String.slice(stamp, 0, 63) <> if(String.ends_with?(stamp, "0"), do: "1", else: "0")
    File.write!(Path.join(release, "cyfr-runner.stamp"), stale <> "\n")

    assert {:error, {:runner_pair, why} = reason} = spawned()

    assert why ==
             "runner: #{binary} is stale: its stamp is not the checkout's (scripts/runner.sh build)"

    assert Runner.refusal(reason) == refused(why)

    # The control: with the checkout's stamp the same pair is what runs.
    File.write!(Path.join(release, "cyfr-runner.stamp"), stamp <> "\n")
    assert {:ok, channel, []} = spawned()
    assert {:exited, {:status, 0}, nil} = event_until(channel, &match?({:exited, _, _}, &1))
    :ok = Runner.release(channel, 0)
    assert :released = event_until(channel, &(&1 == :released))
  end
end
