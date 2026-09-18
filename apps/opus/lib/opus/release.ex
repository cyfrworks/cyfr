# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Release do
  @moduledoc """
  The two roles the `opus` release runs as, and how one becomes the other.

  A boot is the service unless its environment says `OPUS_ROLE=runner`
  (`role/0`). The service (`Opus.Application`) holds the credentials, the
  listener CYFR reaches it through, the worker service and its runner
  pool, and loads no component. A runner is an OS process the service
  started through its keeper (`Opus.Keeper`) with the environment
  `Opus.Settings.runner/1` reads and nothing else: it holds no key, opens
  its control channel (`open_control/1`) and runs one subtree at a time
  (`Opus.Runner`).

  `runner_command/0` is how the service tells a keeper to start one: in a
  release, the release's own `start` under the runner's temporary
  directory (`RELEASE_TMP` follows the `TMPDIR` the keeper sets, since a
  runner's uid can write nowhere else); otherwise a fresh `erl` of this
  runtime on the code paths of Opus and its applications, with no input
  of its own, running `runner/0`, which starts the application in the
  runner role and returns, leaving the VM up until the runner ends it
  (`stop/1`) or its watchdog halts it (`halt/1`).
  """

  require Logger

  @typedoc "Which role a boot runs as."
  @type role :: :service | :runner

  @typedoc "What a keeper starts a runner with: its argv and the environment beside the keeper's own."
  @type command :: %{argv: [String.t()], env: %{String.t() => String.t()}}

  # The service's environment a runner shares: its locale, so the two
  # sides read file names and log text alike, and the release's emulator
  # options. Nothing that names a key, a channel or the control plane.
  @shared_environment ~w(LANG LANGUAGE LC_ALL ELIXIR_ERL_OPTIONS)

  @doc "The role the process environment names: the service unless `OPUS_ROLE=runner`."
  @spec role() :: role()
  def role, do: role(System.get_env())

  @doc "The role `env` (a map of environment variables) names."
  @spec role(%{optional(String.t()) => String.t()}) :: role()
  def role(env) when is_map(env) do
    case Map.get(env, "OPUS_ROLE") do
      nil -> :service
      "service" -> :service
      "runner" -> :runner
      other -> raise ArgumentError, "[Opus.Release] OPUS_ROLE=#{other} names no role"
    end
  end

  @doc """
  The entrypoint of a runner started as a plain VM (`erl -run
  Elixir.Opus.Release runner`): start the application, which reads the
  runner role from the environment, and return, leaving the VM up. A
  start that fails ends the VM with status 1, since a runner that cannot
  start serves nothing.
  """
  @spec runner() :: :ok
  def runner do
    case Application.ensure_all_started(:opus, type: :permanent) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "[Opus.Release] the runner could not start: #{inspect(reason)}")
        :erlang.halt(1)
    end
  end

  @doc "How a keeper starts a runner of this boot (`t:command/0`)."
  @spec runner_command() :: command()
  def runner_command, do: runner_command(System.get_env())

  @doc false
  @spec runner_command(%{optional(String.t()) => String.t()}) :: command()
  def runner_command(env) when is_map(env) do
    shared = Map.take(env, @shared_environment)

    case {Map.get(env, "RELEASE_ROOT"), Map.get(env, "RELEASE_NAME")} do
      {root, name} when is_binary(root) and root != "" and is_binary(name) and name != "" ->
        %{
          argv: [
            "/bin/sh",
            "-c",
            ~s(RELEASE_TMP="${TMPDIR:-/tmp}" exec "$0" start),
            Path.join([root, "bin", name])
          ],
          # A runner never distributes: no listener a guest could reach.
          env: Map.put(shared, "RELEASE_DISTRIBUTION", "none")
        }

      _not_a_release ->
        %{
          argv:
            [erl(), "-noinput", "+fnu", "-pa"] ++
              code_paths() ++ ["-run", "Elixir.Opus.Release", "runner"],
          env: shared
        }
    end
  end

  @doc """
  The code paths a runner of a non-release boot needs: the `ebin` of every
  application Opus depends on, outside the runtime's own library tree,
  which `erl` finds by itself.
  """
  @spec code_paths() :: [String.t()]
  def code_paths do
    root = to_string(:code.root_dir())

    :opus
    |> closure(MapSet.new())
    |> Enum.map(&:code.lib_dir/1)
    |> Enum.filter(&is_list/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&String.starts_with?(&1, root))
    |> Enum.sort()
    |> Enum.map(&Path.join(&1, "ebin"))
  end

  defp closure(app, seen) do
    if MapSet.member?(seen, app) do
      seen
    else
      _ = Application.load(app)

      deps =
        (Application.spec(app, :applications) || []) ++
          (Application.spec(app, :included_applications) || [])

      Enum.reduce(deps, MapSet.put(seen, app), &closure/2)
    end
  end

  defp erl, do: Path.join([to_string(:code.root_dir()), "bin", "erl"])

  @doc """
  The runner's end of its control channel as a port: file descriptor `fd`
  for both directions, or standard input and output when `fd` is 0. The
  port stays open at end of input and reports it as `{port, :eof}`, so
  the runner sees its service go.
  """
  @spec open_control(non_neg_integer()) :: port()
  def open_control(0), do: Port.open({:fd, 0, 1}, [:binary, :stream, :eof])

  def open_control(fd) when is_integer(fd) and fd > 0,
    do: Port.open({:fd, fd, fd}, [:binary, :stream, :eof])

  @doc """
  Send the runner's own log output to standard error, so nothing but
  control frames reaches standard output when the channel is there.
  """
  @spec log_to_stderr() :: :ok
  def log_to_stderr do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: module, config: config} = handler} ->
        :ok = :logger.remove_handler(:default)

        :ok =
          :logger.add_handler(
            :default,
            module,
            handler
            |> Map.drop([:id, :module])
            |> Map.put(:config, Map.put(config, :type, :standard_error))
          )

      _ ->
        :ok
    end
  end

  @doc "End the runner's VM at once, `reason` logged: its watchdog fired or its channel is unusable."
  @spec halt(term()) :: no_return()
  def halt(reason) do
    Logger.error("[Opus.Release] the runner halts: #{inspect(reason)}")
    :erlang.halt(1)
  end

  @doc "End the runner's VM in order with `status`, once its subtree is done."
  @spec stop(non_neg_integer()) :: :ok
  def stop(status) when is_integer(status) and status >= 0, do: System.stop(status)
end
