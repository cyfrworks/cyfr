# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.StreamForwarder do
  @moduledoc """
  One granted stream of a socket that carries several: subscribed to the
  one topic its grant admits, it hands each fact of the grant's payload
  struct to its owner as `{tag, :fact, key, message}`, under the key the
  owner gave it, so an owner holding several grants knows which a fact
  belongs to. It ends with its owner, or when the owner stops it, and it
  reaches no store. The device channel (`Emissary.Web.DeviceChannel`) and
  a frame's stream connection (`Emissary.Web.FrameSocket`) each start one
  per stream they deliver.
  """

  @ready_ms 5_000

  @doc """
  Start a forwarder for `owner` that is subscribed before it answers: the
  grant is answered only once its topic is heard. One that could not
  start, could not subscribe or did not say so in time is
  `{:error, reason}`, and none is left running.
  """
  @spec start(pid(), atom(), term(), Prima.Actor.t(), String.t(), module()) ::
          {:ok, pid()} | {:error, term()}
  def start(owner, tag, key, actor, topic, payload) do
    ready = make_ref()

    case start_child(fn -> run(owner, ready, tag, key, actor, topic, payload) end) do
      {:ok, pid} ->
        receive do
          {^ready, :subscribed} ->
            {:ok, pid}

          {^ready, {:error, reason}} ->
            {:error, reason}
        after
          @ready_ms ->
            Task.Supervisor.terminate_child(Emissary.Web.TaskSupervisor, pid)
            {:error, :not_subscribed}
        end

      {:error, reason} ->
        {:error, reason}

      _not_started ->
        {:error, :not_started}
    end
  end

  # The supervisor itself may be gone, or restarting.
  defp start_child(fun) do
    Task.Supervisor.start_child(Emissary.Web.TaskSupervisor, fun)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Stop forwarder `pid`: it forwards nothing more."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    send(pid, {__MODULE__, :stop})
    :ok
  end

  defp run(owner, ready, tag, key, actor, topic, payload) do
    monitor = Process.monitor(owner)

    case Cyfr.Bus.subscribe(actor, topic) do
      :ok ->
        send(owner, {ready, :subscribed})
        loop(owner, monitor, {tag, key}, payload)

      {:error, reason} ->
        send(owner, {ready, {:error, reason}})
    end
  end

  defp loop(owner, monitor, {tag, key} = to, payload) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      {__MODULE__, :stop} ->
        :ok

      %{__struct__: ^payload} = message ->
        send(owner, {tag, :fact, key, message})
        loop(owner, monitor, to, payload)

      _other ->
        loop(owner, monitor, to, payload)
    end
  end
end
