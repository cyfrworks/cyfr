# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ReleaseTest do
  @moduledoc """
  A boot is the service unless its environment says it is a runner; a
  keeper starts a runner with the release's own `start` in a release and a
  fresh `erl` on Opus's code paths otherwise, sharing the service's locale
  and nothing that names a key or a channel; and a runner's control port
  reads and writes the descriptor it is given, both ways on one socket.
  """

  use ExUnit.Case, async: true

  alias Opus.Release

  test "the role is the service unless OPUS_ROLE says runner, and no other role exists" do
    assert Release.role(%{}) == :service
    assert Release.role(%{"OPUS_ROLE" => "service"}) == :service
    assert Release.role(%{"OPUS_ROLE" => "runner"}) == :runner

    assert_raise ArgumentError, ~r/OPUS_ROLE=worker names no role/, fn ->
      Release.role(%{"OPUS_ROLE" => "worker"})
    end

    assert Release.role() == :service
  end

  test "in a release, a runner is the release's start under the keeper's temporary directory, never distributed" do
    env = %{
      "RELEASE_ROOT" => "/app",
      "RELEASE_NAME" => "opus",
      "LANG" => "C.UTF-8",
      "ELIXIR_ERL_OPTIONS" => "+fnu",
      "OPUS_SERVICE_KEY" => String.duplicate("0", 64),
      "CYFR_SPAWN_CHANNEL" => "socket:[7]",
      "RELEASE_COOKIE" => "secret"
    }

    assert %{argv: ["/bin/sh", "-c", script, "/app/bin/opus"], env: runner_env} =
             Release.runner_command(env)

    assert script =~ ~s(RELEASE_TMP="${TMPDIR:-/tmp}")
    assert script =~ ~s(exec "$0" start)

    assert runner_env == %{
             "LANG" => "C.UTF-8",
             "ELIXIR_ERL_OPTIONS" => "+fnu",
             "RELEASE_DISTRIBUTION" => "none"
           }
  end

  test "outside a release, a runner is a fresh erl of this runtime on Opus's code paths, with no input" do
    assert %{argv: [erl, "-noinput", "+fnu", "-pa" | rest], env: env} =
             Release.runner_command(%{"LC_ALL" => "C.UTF-8", "OPUS_SERVICE_KEY" => "0"})

    assert erl == Path.join([to_string(:code.root_dir()), "bin", "erl"])
    assert File.exists?(erl)
    assert env == %{"LC_ALL" => "C.UTF-8"}

    {paths, ["-run", "Elixir.Opus.Release", "runner"]} = Enum.split(rest, -3)
    assert paths == Release.code_paths()
  end

  test "the code paths are the ebin of Opus and every application it depends on, outside the runtime's own" do
    paths = Release.code_paths()
    root = to_string(:code.root_dir())

    for app <- [:opus, :cyfr_contracts, :wasmex, :jason, :req, :elixir, :logger] do
      assert Path.join(to_string(:code.lib_dir(app)), "ebin") in paths,
             "#{app}'s ebin is not on the runner's path"
    end

    refute Enum.any?(paths, &String.starts_with?(&1, root))
    refute Enum.any?(paths, &String.contains?(&1, "/cyfr/ebin"))
    assert Enum.all?(paths, &File.dir?/1)
  end

  test "the control port carries frames both ways on one socket, and reports the far end's close" do
    path = Path.join(System.tmp_dir!(), "opus_control_#{System.unique_integer([:positive])}.sock")
    File.rm(path)
    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, service} = :socket.open(:local, :stream)
    :ok = :socket.connect(service, %{family: :local, path: path})
    {:ok, runner_end} = :socket.accept(listener)
    {:ok, fd} = :socket.getopt(runner_end, {:otp, :fd})

    port = Release.open_control(fd)
    line = Cyfr.RunnerControl.encode(%{type: :cancel_child, execution_id: "exec_1"})
    :ok = :socket.send(service, line)
    assert_receive {^port, {:data, data}}
    assert {:ok, %{type: :cancel_child, execution_id: "exec_1"}} = Cyfr.RunnerControl.decode(data)

    true =
      Port.command(port, Cyfr.RunnerControl.encode(%{type: :exit, runner: "runner_1", open: []}))

    assert {:ok, answer} = :socket.recv(service, 0, 2_000)
    assert {:ok, %{type: :exit, runner: "runner_1", open: []}} = Cyfr.RunnerControl.decode(answer)

    :socket.close(service)
    assert_receive {^port, :eof}, 2_000

    Port.close(port)
    :socket.close(runner_end)
    :socket.close(listener)
    File.rm(path)
  end
end
