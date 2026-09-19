# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.LocusService do
  @moduledoc """
  The Locus builds service of the test boot, reached as CYFR reaches it:
  over the build wire (`Cyfr.BuilderProtocol`), on a loopback port of the
  system's choosing.

  The umbrella starts the Locus application beside CYFR, and a node whose
  environment was never read serves no builds (`Locus.Application`).
  `serve!/0`, run once by `test_helper.exs`, gives it the builds key and
  starts its listener (`Locus.Application.listener/1`) under
  `Locus.Supervisor`, where the builds run through `Locus.DirectLauncher`,
  the one executor the test build knows beside cyfr-spawn: as this
  machine's user, with no uid or memory bound of their own. `stop!/0`, run
  when the suite ends, takes both away again, so a suite that runs after
  this one in the same VM finds Locus as it started.

  Builds stay disabled on this server until a test asks for them:
  `configure!/0`, from a test's `setup`, points
  `config :cyfr, :locus_builds_url` and `:locus_builds_key` at the service
  until the test ends, and every build that test starts is a real build,
  sent, signed and answered over the wire.
  """

  alias Cyfr.BuilderProtocol

  # Locus is a sibling application, not a dependency: CYFR names it here
  # as the suite's, never in its own code.
  @compile {:no_warn_undefined, [Locus.Application]}

  # The suite's builds key: 32 bytes, as the service and this server each
  # hold it. Test-only; no deployment holds it.
  @key :binary.copy(<<0x4C>>, 32)
  @listener __MODULE__.Listener

  @doc "The builds key the service verifies requests with and this server signs them with."
  @spec key() :: <<_::256>>
  def key, do: @key

  @doc """
  Serve builds from the running Locus application: the key installed and
  the listener started on a port of the system's choosing. Answers the
  service's base URL.
  """
  @spec serve!() :: String.t()
  def serve! do
    unless Process.whereis(Locus.Supervisor),
      do: raise("the Locus builds service is not running: run the suite from the umbrella root")

    Application.put_env(:locus, :request_key, BuilderProtocol.request_key(@key))

    {Bandit, opts} = Locus.Application.listener(ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    spec = Supervisor.child_spec({Bandit, opts}, id: @listener)

    case Supervisor.start_child(Locus.Supervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        {:ok, _pid} = Supervisor.restart_child(Locus.Supervisor, @listener)
    end

    url()
  end

  @doc """
  Stop serving: the listener stopped and removed from `Locus.Supervisor`
  and the key taken away, as they were before `serve!/0`.
  """
  @spec stop!() :: :ok
  def stop! do
    if Process.whereis(Locus.Supervisor) do
      _ = Supervisor.terminate_child(Locus.Supervisor, @listener)
      _ = Supervisor.delete_child(Locus.Supervisor, @listener)
    end

    Application.delete_env(:locus, :request_key)
    :ok
  end

  @doc "The base URL the service answers on."
  @spec url() :: String.t()
  def url do
    {_id, server, _type, _modules} =
      Locus.Supervisor |> Supervisor.which_children() |> List.keyfind(@listener, 0)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  Point this server's builds at the service until the calling test ends,
  restoring what the two keys held before.
  """
  @spec configure!() :: :ok
  def configure! do
    previous = for name <- [:locus_builds_url, :locus_builds_key], do: {name, get(name)}

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn {name, value} -> put(name, value) end)
    end)

    put(:locus_builds_url, url())
    put(:locus_builds_key, @key)
  end

  defp get(name), do: Application.get_env(:cyfr, name)
  defp put(name, nil), do: Application.delete_env(:cyfr, name)
  defp put(name, value), do: Application.put_env(:cyfr, name, value)
end
