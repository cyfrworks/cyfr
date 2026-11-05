# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends do
  @moduledoc """
  The backends service: the programs CYFR registers, one owner per
  athanor and `mcp_servers` row, each session of a program a long-lived
  process under the keeper whose lines go to and from its owner, served
  over `Prima.LocusBackends`. This module is its facade:
  the children `Locus.Application` starts on a node that holds a backends
  key, and the address its listener serves on as `Locus.Config` reads it.
  Nothing
  outside `Locus.Backends` names a module under it but `Locus.Application`,
  and it only through this facade.

  The children, in dependency order under the application's
  `:rest_for_one` tree: the owners (`Locus.Backends.Owners`), the
  supervisor every session runs under (`Locus.Backends.BackendSupervisor`,
  whose children are never restarted: an owner's next open starts a
  program again, and an owner that restarts forgets its sessions), the tick
  (`Locus.Backends.LeaseSweeper`), and the listener
  (`Locus.Backends.Service`). The owners restarting restart everything
  after them, so no session outlives the table that accounts for it.
  """

  alias Locus.Backends.{LeaseSweeper, Owners, Service}

  @doc "The children of a node that serves backends, in the order they start."
  @spec children() :: [Supervisor.child_spec() | {module(), keyword()}]
  def children do
    [
      {Owners, name: Owners},
      {DynamicSupervisor, name: Locus.Backends.BackendSupervisor, strategy: :one_for_one},
      {LeaseSweeper, owners: Owners},
      listener()
    ]
  end

  @doc """
  The backends service's listener on the address `Locus.Config` names, or
  on `opts` (`:ip`, `:port`, `:plug`) in its place: HTTP/1.1 alone. In
  compose the container sits on the backends network alone, so every
  interface is that network; elsewhere `LOCUS_BACKENDS_BIND` names the one
  address to listen on.
  """
  @spec listener(keyword()) :: {module(), keyword()}
  def listener(opts \\ []) do
    {Bandit,
     Keyword.merge(
       [
         plug: Service,
         ip: bind(),
         port: port(),
         http_2_options: [enabled: false]
       ],
       opts
     )}
  end

  @doc "Create the service's table of nonces seen, owned by the calling process."
  @spec init_nonces() :: :ok
  defdelegate init_nonces, to: Service

  @doc "The address the backends service listens on."
  @spec bind() :: :inet.ip_address()
  defdelegate bind, to: Locus.Config, as: :backends_bind

  @doc "The port the backends service listens on."
  @spec port() :: :inet.port_number()
  defdelegate port, to: Locus.Config, as: :backends_port
end
