# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.DirectLauncherPathTest do
  @moduledoc """
  The test environment's keeper looks none of its own tools up through
  this node's PATH: with PATH naming no `kill`, a runner released with no
  grace still has its leader and the child it started killed, and its
  owner hears the kill and then the release. The test moves the node's
  PATH, which every process of the node shares, so it runs alone and
  restores PATH on every exit; what it proves is that the launcher no
  longer reads it.
  """

  use ExUnit.Case, async: false

  import Locus.Test.ProcessFamily

  alias Locus.DirectLauncher.Runner

  setup do
    unless Process.whereis(Runner), do: start_supervised!(Runner)
    :ok
  end

  test "a runner released while PATH names no kill is killed, leader and child, and reported released" do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)

    empty =
      Path.join(
        System.tmp_dir!(),
        "direct_launcher_no_path_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    {channel, leader, child} = spawn_family!()
    assert running?(leader) and running?(child)

    try do
      System.put_env("PATH", empty)
      assert System.find_executable("kill") == nil

      :ok = Runner.release(channel, 0)

      assert_gone([leader, child])
      assert {:exited, {:signal, "SIGKILL"}} = event_until(channel, &match?({:exited, _}, &1))
      assert :released = event_until(channel, &(&1 == :released))
    after
      System.put_env("PATH", path)
    end

    assert System.get_env("PATH") == path
  end
end
