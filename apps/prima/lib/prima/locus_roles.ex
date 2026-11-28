# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusRoles do
  @moduledoc """
  The one table of the `locus` release's roles: each fact of a role that a
  reader reads or a check holds, and the facts every role shares as the
  release's. Data only: no process, no file and no environment.

  The release (`release/0`) is one compose service, `service`, in the
  container `container`, holding no network of its own: it shares the
  network namespace of its egress guard, the service `guard` in the
  container `guard_container` (`cyfr-locus guard-control`), and starts behind the guard's
  health. The guard sits on the one network `network`, which only it and
  CYFR join, under the alias `service`, so CYFR reaches every role at
  `http://<service>:<port>`. That network's subnet is `subnet` and its
  other containers take addresses from `ip_range` alone; CYFR holds the
  fixed address `host_api_address` on it, where its host API binds and
  where the guard lets the runtime's role process reach it. cyfr-locus
  runs as the container's root and starts one role process for each role
  whose key is set, running `bin`; the role's spawns' homes lie under
  `home_root`, the role's folder of it, and `run_dir`, a tmpfs of
  `run_size` owned by root, holds each role's run folder.

  The release's endpoint, which cyfr serves, binds its loopback listener
  to one fixed address under compose: `endpoint_address`, on the network
  `endpoint_network` (compose's `default`), whose subnet is
  `endpoint_subnet` and whose other containers take addresses from
  `endpoint_ip_range` alone, so nothing started first can hold cyfr's.
  Docker publishes the host's loopback port to that address, and the
  network Locus joins never reaches the endpoint. Its proxy listener, with
  `tailnet` or `domain`, binds `edge_address` on the network
  `edge_network`, whose subnet is `edge_subnet` and whose dynamic range is
  `edge_ip_range`; the two proxies that forward to it sit there at fixed
  addresses of their own, Caddy at `edge_caddy_address` and Tailscale at
  `edge_tailscale_address`, the addresses whose forwarded headers the
  proxy listener trusts.

  A role (`roles/0`, in the order runtime, builds, backends) is a process
  the keeper starts when the role's key variable `key` is set, as the user
  `user` with uid `uid` (its gid the same, alone in its group), listening
  on `port`, in a space of its own routed by the guard. The space's reach
  is the guard's `role` reach, with every private address and core's host
  API besides where `private` is true (the runtime's). Where `floor` is
  true (the runtime's) its runners are the warm floor's, and its spawns'
  groups lie in the pool's `work` beside `rest`, which holds every other
  role's (`Prima.LocusPool`). The role's run
  folder is `run_dir` (its own, 0700, under the release's), and its
  spawns' homes lie on a tmpfs of `home_size` at `home_root`, the
  release's root and the role's name. Its run folder is a tmpfs of
  `run_size` of its own, so no role fills another's. Its spawns are drawn
  from the uid
  pool `pool`, whose uids `uids` are named `user_prefix` and a two-digit
  ordinal, each spawn in a space of its own whose reach is `reach`
  (`reaches/0`, the keeper's `--pool` suffix): the runtime's runners
  reach nothing but their relays, builds and programs leave through the
  route the guard makes for each.

  A role whose programs keep their folders, the backends role, names the
  kept folders' root `kept_root`, the compose volume `kept_volume` mounted
  there (never under `data/`, never in a backup), the uid range
  `kept_uids` the keeper's `--kept-homes` flag draws each person's disk's
  uid from, outside every pool and every user of the image, and the group the
  root is shared with, `kept_group` with gid `kept_gid`, of which no user
  is a member; every other role has none (`nil`). The root is root's and
  that group's, mode 1773.

  The role whose sessions run in a person's machine where the host has KVM,
  the backends role, names the machines' folder `guest_root` and the compose
  volume `guest_volume` mounted there: the image's programs as one squashfs
  the keeper makes, and each machine's sockets (the keeper's package vm);
  every other role has none (`nil`).

  A role's `memory` is what its process holds of its own: the bounds of
  what it counts (`Locus.Output`), `unread` (the backends role's alone,
  `nil` for the others) and `answering`, and the figures of what it holds
  uncounted that an image suite's allowance reads. The runtime names one
  transport read of a pinned fetch (`fetch_read_bytes`), the larger read a
  fetch takes when its count has room for it and the receive queue behind
  it (`fetch_read_ahead_bytes`), the most of a fetch's head the HTTP
  client reads (`fetch_head_bytes`) and the freed segments its VM keeps
  for reuse (`freed_segments_bytes`); every other role names none of them
  (`nil`). The release's `memory` holds what every role's process shares:
  the bytes of resident memory one byte it holds costs at most
  (`byte_cost`), one read of a held keeper connection
  (`keeper_read_bytes`) and the copies of it held at once
  (`keeper_read_copies`), and the kernel's queues beside the process, a
  relay connection's (`relay_queue_bytes`) and a TCP connection's send
  queue (`socket_queue_bytes`). What each is, its cap and how many there
  can be at once, is `Locus.Output`'s table ("What each role holds").

  Every spawn's space is a user, network, IPC, pid, mount and cgroup
  namespace of its own, so no spawn shares a loopback, an abstract unix
  socket, a System V object, a process list or a file outside its home
  with another or with its role's process: a `"relay"` space has its
  loopback down and no route, a `"routed"` space its own loopback and the
  one route the guard makes for it. It sees the image read-only, its own
  /proc, /tmp, /dev/shm, terminals and group, and its home alone.

  `tests/fixtures/locus_roles.json` holds the same table for the image
  suites, which cannot read this module: `Prima.LocusRolesTest` holds the
  file to it value by value. `Locus.Application` selects a node's roles
  from it, CYFR reaches the builds role beside the backends role at the
  builds role's port (`Cyfr.RuntimeConfig`), and the stack's shape test
  holds every other spelling of a role's facts to it: the Locus image's
  users, directories, entrypoint and health probe, compose's services,
  the image suites' overlays, Locus's own pool names, reaches and listener
  ports, and the image suites' harnesses. The pool's memory bound and
  each role's processors are compose's (the `locus` service's
  environment), which the keeper writes into its groups; they are not
  facts of this table,
  and neither is the rule that a node serving the runtime serves no other
  role (`Locus.Application`).
  """

  @typedoc "A role the `locus` release serves."
  @type name :: :runtime | :builds | :backends

  @typedoc "The facts every role shares."
  @type release :: %{
          service: String.t(),
          container: String.t(),
          guard: String.t(),
          guard_container: String.t(),
          network: String.t(),
          subnet: String.t(),
          ip_range: String.t(),
          host_api_address: String.t(),
          bin: String.t(),
          home_root: String.t(),
          run_dir: String.t(),
          run_size: String.t(),
          endpoint_network: String.t(),
          endpoint_subnet: String.t(),
          endpoint_ip_range: String.t(),
          endpoint_address: String.t(),
          edge_network: String.t(),
          edge_subnet: String.t(),
          edge_ip_range: String.t(),
          edge_address: String.t(),
          edge_caddy_address: String.t(),
          edge_tailscale_address: String.t(),
          memory: %{
            byte_cost: float(),
            keeper_read_bytes: pos_integer(),
            keeper_read_copies: pos_integer(),
            relay_queue_bytes: pos_integer(),
            socket_queue_bytes: pos_integer()
          }
        }

  @typedoc "One role's facts."
  @type role :: %{
          name: name(),
          key: String.t(),
          user: String.t(),
          uid: pos_integer(),
          port: :inet.port_number(),
          private: boolean(),
          floor: boolean(),
          run_dir: String.t(),
          run_size: String.t(),
          home_root: String.t(),
          home_size: String.t(),
          pool: String.t(),
          user_prefix: String.t(),
          uids: Range.t(),
          reach: String.t(),
          kept_root: String.t() | nil,
          kept_volume: String.t() | nil,
          kept_uids: Range.t() | nil,
          kept_group: String.t() | nil,
          kept_gid: pos_integer() | nil,
          guest_root: String.t() | nil,
          guest_volume: String.t() | nil,
          memory: %{
            unread: pos_integer() | nil,
            answering: pos_integer(),
            fetch_read_bytes: pos_integer() | nil,
            fetch_read_ahead_bytes: pos_integer() | nil,
            fetch_head_bytes: pos_integer() | nil,
            freed_segments_bytes: pos_integer() | nil
          }
        }

  @release %{
    service: "locus",
    container: "cyfr-locus",
    guard: "locus-guard",
    guard_container: "cyfr-locus-guard",
    network: "locus",
    subnet: "172.16.231.0/24",
    ip_range: "172.16.231.128/25",
    host_api_address: "172.16.231.2",
    bin: "/app/bin/locus",
    home_root: "/var/lib/locus/homes",
    run_dir: "/run/locus",
    run_size: "1m",
    endpoint_network: "default",
    endpoint_subnet: "172.16.230.0/24",
    endpoint_ip_range: "172.16.230.128/25",
    endpoint_address: "172.16.230.2",
    edge_network: "edge",
    edge_subnet: "172.16.234.0/24",
    edge_ip_range: "172.16.234.128/25",
    edge_address: "172.16.234.2",
    edge_caddy_address: "172.16.234.3",
    edge_tailscale_address: "172.16.234.4",
    memory: %{
      byte_cost: 2.8,
      keeper_read_bytes: 65_541,
      keeper_read_copies: 3,
      relay_queue_bytes: 233_167,
      socket_queue_bytes: 4_194_304
    }
  }

  @roles [
    %{
      name: :runtime,
      key: "LOCUS_RUNTIME_KEY",
      user: "locus-runtime",
      uid: 10_011,
      port: 4200,
      private: true,
      floor: true,
      run_dir: "/run/locus/runtime",
      run_size: "16m",
      home_root: "/var/lib/locus/homes/runtime",
      home_size: "256m",
      pool: "runner",
      user_prefix: "locus-runner",
      uids: 30_101..30_108,
      reach: "relay",
      kept_root: nil,
      kept_volume: nil,
      kept_uids: nil,
      kept_group: nil,
      kept_gid: nil,
      guest_root: nil,
      guest_volume: nil,
      memory: %{
        unread: nil,
        answering: 16_777_216,
        fetch_read_bytes: 65_536,
        fetch_read_ahead_bytes: 262_144,
        fetch_head_bytes: 262_144,
        freed_segments_bytes: 69_905_080
      }
    },
    %{
      name: :builds,
      key: "LOCUS_BUILDS_KEY",
      user: "locus-builds",
      uid: 10_012,
      port: 4100,
      private: false,
      floor: false,
      run_dir: "/run/locus/builds",
      run_size: "16m",
      home_root: "/var/lib/locus/homes/builds",
      home_size: "2g",
      pool: "build",
      user_prefix: "locus-build",
      uids: 30_001..30_016,
      reach: "routed",
      kept_root: nil,
      kept_volume: nil,
      kept_uids: nil,
      kept_group: nil,
      kept_gid: nil,
      guest_root: nil,
      guest_volume: nil,
      memory: %{
        unread: nil,
        answering: 8_388_608,
        fetch_read_bytes: nil,
        fetch_read_ahead_bytes: nil,
        fetch_head_bytes: nil,
        freed_segments_bytes: nil
      }
    },
    %{
      name: :backends,
      key: "LOCUS_BACKENDS_KEY",
      user: "locus-backends",
      uid: 10_013,
      port: 4101,
      private: false,
      floor: false,
      run_dir: "/run/locus/backends",
      run_size: "16m",
      home_root: "/var/lib/locus/homes/backends",
      home_size: "2g",
      pool: "backends",
      user_prefix: "locus-backend",
      uids: 20_001..20_032,
      reach: "routed",
      kept_root: "/var/lib/locus/kept",
      kept_volume: "homes",
      kept_uids: 40_001..49_999,
      kept_group: "locus",
      kept_gid: 10_001,
      guest_root: "/var/lib/locus/guest",
      guest_volume: "guest",
      memory: %{
        unread: 67_108_864,
        answering: 27_262_976,
        fetch_read_bytes: nil,
        fetch_read_ahead_bytes: nil,
        fetch_head_bytes: nil,
        freed_segments_bytes: nil
      }
    }
  ]

  @names Enum.map(@roles, & &1.name)

  @doc "The facts every role shares."
  @spec release() :: release()
  def release, do: @release

  @doc "Every role's facts: the runtime's, the builds role's and the backends role's, in that order."
  @spec roles() :: [role(), ...]
  def roles, do: @roles

  @doc """
  The reaches a role's spaces may have, as the keeper's `--pool
  <name>:<first>-<last>:<reach>` spells them (its package pool): a relay
  space's, which reaches nothing but its relay, and a routed space's.
  """
  @spec reaches() :: [String.t(), ...]
  def reaches, do: ~w(relay routed)

  @doc "Every role's name, in the order of `roles/0`."
  @spec names() :: [name(), ...]
  def names, do: @names

  @doc "The facts of the role named `name`; raises `ArgumentError` naming a role the release lacks."
  @spec role!(atom()) :: role()
  def role!(name) when is_atom(name) do
    case Enum.find(@roles, &(&1.name == name)) do
      nil ->
        # The name is an atom the caller's code spells, never a value.
        raise ArgumentError,
              ":#{name} is not a role of the locus release, whose roles are " <>
                Enum.map_join(@names, ", ", &inspect/1)

      role ->
        role
    end
  end
end
