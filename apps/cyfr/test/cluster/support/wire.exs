# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Wire do
  @moduledoc """
  A TCP path one member reaches something through, which a case can cut.

  A partition is a failure of a link, not of a peer
  (`cell-ownership.md` §7.2), and the three links answer differently. This
  is how the suite cuts one link without touching either end of it: the
  member is given a loopback port of this wire's, the wire forwards to the
  real address, and `cut/1` closes every connection through it and refuses
  new ones until `restore/1`.

  It runs on the control node, so cutting a member's wire survives killing
  that member, and a member cut off from a worker keeps its database and
  keeps acting — which is what makes it a *live partitioned owner* rather
  than a dead one. A cut refuses the connection outright rather than
  hanging it, because a member whose requests time out and a member whose
  requests are refused are the same failure to the watch and the first
  costs the case a timeout per poll.
  """

  use GenServer

  @doc """
  Open a wire to `host:port`, answering `{:ok, port}` — the loopback port
  a member should be given instead.
  """
  @spec open(atom(), :inet.ip_address() | charlist(), :inet.port_number()) ::
          {:ok, :inet.port_number()}
  def open(name, host, port) do
    case GenServer.start(__MODULE__, {host, port}, name: via(name)) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :port)}
      {:error, {:already_started, pid}} -> {:ok, GenServer.call(pid, :port)}
    end
  end

  @doc "The loopback port of an open wire."
  @spec port(atom()) :: :inet.port_number()
  def port(name), do: GenServer.call(via(name), :port)

  @doc """
  Cut the wire: every connection through it is closed and every new one
  refused, so what is on the far side is unreachable through it and
  reachable by any other path.
  """
  @spec cut(atom()) :: :ok
  def cut(name), do: GenServer.call(via(name), :cut)

  @doc "Let the wire carry again."
  @spec restore(atom()) :: :ok
  def restore(name), do: GenServer.call(via(name), :restore)

  @doc "Whether a wire of this name is open."
  @spec open?(atom()) :: boolean()
  def open?(name), do: GenServer.whereis(via(name)) != nil

  @doc "Close the wire for good."
  @spec close(atom()) :: :ok
  def close(name) do
    case GenServer.whereis(via(name)) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp via(name), do: :"#{__MODULE__}.#{name}"

  @impl true
  def init({host, port}) do
    Process.flag(:trap_exit, true)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_ip, listen_port}} = :inet.sockname(listener)

    # The owner is this process, named before the acceptor is spawned: a
    # `self()` evaluated inside the spawned function is the acceptor's own
    # pid, and an acceptor that called itself would answer nothing.
    owner = self()
    spawn_link(fn -> accept(listener, owner) end)

    {:ok,
     %{
       listener: listener,
       port: listen_port,
       host: host,
       remote: port,
       cut: false,
       pumps: []
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:cut, _from, state) do
    for pump <- state.pumps, do: Process.exit(pump, :kill)
    {:reply, :ok, %{state | cut: true, pumps: []}}
  end

  def handle_call(:restore, _from, state), do: {:reply, :ok, %{state | cut: false}}

  def handle_call({:accepted, socket}, _from, state) do
    if state.cut do
      :gen_tcp.close(socket)
      {:reply, :refused, state}
    else
      case :gen_tcp.connect(state.host, state.remote, [:binary, active: false], 5_000) do
        {:ok, upstream} ->
          pump = spawn(fn -> pump(socket, upstream) end)
          :ok = :gen_tcp.controlling_process(socket, pump)
          :ok = :gen_tcp.controlling_process(upstream, pump)
          send(pump, :go)
          {:reply, :ok, %{state | pumps: [pump | Enum.filter(state.pumps, &Process.alive?/1)]}}

        {:error, _reason} ->
          :gen_tcp.close(socket)
          {:reply, :refused, state}
      end
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    for pump <- state.pumps, do: Process.exit(pump, :kill)
    :ok
  end

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, owner)
        GenServer.call(owner, {:accepted, socket})
        accept(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  # Two halves of one connection, each copying until either end closes.
  # Killing the pump is what a cut does, and it takes both sockets with
  # it: they are the pump's, so its exit closes them.
  defp pump(a, b) do
    receive do
      :go -> :ok
    after
      5_000 -> :ok
    end

    half = spawn_link(fn -> copy(b, a) end)
    copy(a, b)
    Process.exit(half, :kill)
    :gen_tcp.close(a)
    :gen_tcp.close(b)
  end

  defp copy(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, bytes} ->
        case :gen_tcp.send(to, bytes) do
          :ok -> copy(from, to)
          {:error, _closed} -> :ok
        end

      {:error, _closed} ->
        :ok
    end
  end
end
