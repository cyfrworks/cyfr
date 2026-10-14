# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.ProcessFamily do
  @moduledoc """
  A runner's process family through the direct launcher's runtime face
  (`Locus.DirectLauncher.Runner`), for the tests that end one:
  `spawn_family!/1` spawns a leader that starts a child and names it,
  `running?/1` says whether an OS process still runs, `assert_gone/1`
  waits until none of some do, and `event_until/2` reads a runner's
  events until one is awaited. `ps` is named by absolute path, so a test
  that moves this node's PATH still sees its processes.
  """

  import ExUnit.Assertions
  import Prima.Test.Wait

  alias Locus.DirectLauncher
  alias Locus.DirectLauncher.Runner

  # A process that has exited is gone even while its parent has yet to
  # reap it: a zombie holds no memory and runs nothing.
  @doc "Whether the OS process `os_pid` runs."
  @spec running?(non_neg_integer()) :: boolean()
  def running?(os_pid) do
    case System.cmd("/bin/ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_none, _status} -> false
    end
  end

  @doc "Wait until none of `os_pids` runs, flunking if one still does."
  @spec assert_gone([non_neg_integer()]) :: :ok
  def assert_gone(os_pids) do
    for os_pid <- os_pids,
        do: wait_until(fn -> not running?(os_pid) end, 10_000, "process #{os_pid} to end")

    :ok
  end

  @doc """
  The runtime's events of `channel`, until `done` holds of one, which is
  answered.
  """
  @spec event_until(map(), (term() -> boolean())) :: term()
  def event_until(%{ref: ref} = channel, done) do
    receive do
      {DirectLauncher, ^ref, _event} = message ->
        {:events, [event], _channel} = Runner.handle_message(channel, message)
        if done.(event), do: event, else: event_until(channel, done)
    after
      10_000 -> flunk("the runner never sent the event awaited")
    end
  end

  @doc """
  A leader that starts a child, names it on its standard output, which
  is the channel the keeper hands the spawning process, and waits on it;
  with `ignore_term`, both ignore the term signal, which a child
  inherits. Answers the channel, the leader's OS pid and the child's.
  """
  @spec spawn_family!(keyword()) :: {map(), non_neg_integer(), non_neg_integer()}
  def spawn_family!(opts \\ []) do
    trap = if Keyword.get(opts, :ignore_term, false), do: "trap '' TERM; ", else: ""

    spec = %{
      runner: "runner_direct_#{System.unique_integer([:positive])}",
      argv: ["/bin/sh", "-c", trap <> "sleep 300 & echo $!; wait"],
      env: %{}
    }

    {:ok, channel, []} = Runner.spawn(spec)
    {:spawned, leader} = event_until(channel, &match?({:spawned, _pid}, &1))
    {:control, line} = event_until(channel, &match?({:control, _bytes}, &1))
    {channel, leader, line |> String.trim() |> String.to_integer()}
  end
end
