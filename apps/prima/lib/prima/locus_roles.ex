# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusRoles do
  @moduledoc """
  The one table of the `locus` release's roles: each fact of a role that a
  reader reads or a check holds, and the facts every role shares as the
  release's. Data only: no process, no file and no environment.

  The release (`release/0`) runs every role's service as one user, `user`
  with uid `uid`, starting `bin`; each spawn's home is under `home_root`,
  and `run_dir`, a tmpfs of `run_size`, holds the release's temporary files
  and the socket spawns' relays attach to. The image's own entrypoint and
  health probe serve `image_role`.

  The release's endpoint, which cyfr serves, binds its loopback listener
  to one fixed address under compose: `endpoint_address`, on the network
  `endpoint_network` (compose's `default`), whose subnet is
  `endpoint_subnet` and whose other containers take addresses from
  `endpoint_ip_range` alone, so nothing started first can hold cyfr's.
  Docker publishes the host's loopback port to that address, and the
  networks the Locus roles join never reach the endpoint. Its proxy
  listener, in a tailnet or public home, binds `edge_address` on the
  network `edge_network`, whose subnet is `edge_subnet` and whose dynamic
  range is `edge_ip_range`; the two proxies that forward to it sit there
  at fixed addresses of their own, Caddy at `edge_caddy_address` and
  Tailscale at `edge_tailscale_address`, the addresses whose forwarded
  headers the proxy listener trusts.

  A role (`roles/0`, in the order runtime, builds, backends) is served
  under cyfr-locus from the uid pool `pool`, whose uids `uids` are named
  `user_prefix` and a two-digit ordinal, each spawn isolated as `isolation`
  says (`nil`, or one of `Prima.KeeperProtocol.isolations/0`). Its service
  listens on `port`; compose runs it as the service `service` in the
  container `container`, on the network `network` that only it and CYFR
  join, selected by the profile `profile` where it has one (`nil`: it
  always starts), with its spawns' homes on a tmpfs of `home_size`. A role
  whose spawns have a network of the island's own, the builds and backends
  roles, runs behind the egress guard `guard`: the compose service that
  holds the island's network namespace and installs the rules every build
  or backend leaves through (cyfr-guard), which the role's service shares
  (`network_mode: service:<guard>`) and starts behind; the runtime, whose
  runners have no network, has none (`nil`).

  A role whose programs keep their folders, the backends role, names the
  kept folders' root `kept_root`, the compose volume `kept_volume` mounted
  there (never under `data/`, never in a backup) and the uid range
  `kept_uids` the keeper's `--kept-homes` flag draws each folder's uid
  from, outside every pool and every user of the image; every other role
  has none (`nil`). The root is the release user's group's, mode 1773.

  A role's `memory` is what its service holds of its own: the bounds of
  what it counts (`Locus.Output`), `unread` (the backends role's alone,
  `nil` for the others) and `answering`, and the figures of what it holds
  uncounted that an image suite's allowance reads. The runtime names one
  transport read of a pinned fetch (`fetch_read_bytes`), the most of a
  fetch's head the HTTP client reads (`fetch_head_bytes`) and the freed
  segments its VM keeps for reuse (`freed_segments_bytes`); every other
  role names none of them (`nil`). The release's `memory` holds what every
  role's service shares: the bytes of resident memory one byte it holds
  costs at most (`byte_cost`), one read of a held keeper connection
  (`keeper_read_bytes`) and the copies of it held at once
  (`keeper_read_copies`), and the kernel's queues beside the service, a
  relay connection's (`relay_queue_bytes`) and a TCP connection's send
  queue (`socket_queue_bytes`). What each is, its cap and how many there
  can be at once, is `Locus.Output`'s table ("What each role holds").

  A role whose `isolation` is `nil` spawns into its container's own
  namespaces, so every spawn of the island shares the island's network
  namespace and the container's one IPC namespace (compose's
  `ipc: none`). An abstract unix socket one spawn binds is therefore
  reachable by its siblings whatever their uid, since the kernel checks
  no owner on one. A System V object one spawn makes is kept from its
  siblings by its owner's uid and mode, and retirement removes it with
  the uid.

  `tests/fixtures/locus_roles.json` holds the same table for the image
  suites, which cannot read this module: `Prima.LocusRolesTest` holds the
  file to it value by value. `Locus.Application` selects a node's roles
  from it, and the stack's shape test holds every other spelling of a
  role's facts to it: the Locus image's users and entrypoint, compose's
  services and the image suites' overlays, Locus's own pool names,
  isolation, attach directory and listener ports, and the image suites'
  harnesses. A role's key variables are `Locus.Config`'s; the memory bound
  of each spawn and each container's limits are not facts of this table,
  and neither is the rule that a node serving the runtime serves no other
  role (`Locus.Application`).
  """

  @typedoc "A role the `locus` release serves."
  @type name :: :runtime | :builds | :backends

  @typedoc "The facts every role's service shares."
  @type release :: %{
          user: String.t(),
          uid: pos_integer(),
          bin: String.t(),
          home_root: String.t(),
          run_dir: String.t(),
          run_size: String.t(),
          image_role: name(),
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
          pool: String.t(),
          user_prefix: String.t(),
          uids: Range.t(),
          isolation: String.t() | nil,
          port: :inet.port_number(),
          home_size: String.t(),
          service: String.t(),
          container: String.t(),
          network: String.t(),
          profile: String.t() | nil,
          guard: String.t() | nil,
          kept_root: String.t() | nil,
          kept_volume: String.t() | nil,
          kept_uids: Range.t() | nil,
          memory: %{
            unread: pos_integer() | nil,
            answering: pos_integer(),
            fetch_read_bytes: pos_integer() | nil,
            fetch_head_bytes: pos_integer() | nil,
            freed_segments_bytes: pos_integer() | nil
          }
        }

  @release %{
    user: "locus",
    uid: 10_001,
    bin: "/app/bin/locus",
    home_root: "/var/lib/locus/homes",
    run_dir: "/run/locus",
    run_size: "16m",
    image_role: :builds,
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
      relay_queue_bytes: 212_992,
      socket_queue_bytes: 4_194_304
    }
  }

  @roles [
    %{
      name: :runtime,
      pool: "runner",
      user_prefix: "locus-runner",
      uids: 30_101..30_108,
      isolation: "netns",
      port: 4200,
      home_size: "256m",
      service: "locus-runtime",
      container: "cyfr-locus-runtime",
      network: "locus-runtime",
      profile: nil,
      guard: nil,
      kept_root: nil,
      kept_volume: nil,
      kept_uids: nil,
      memory: %{
        unread: nil,
        answering: 16_777_216,
        fetch_read_bytes: 65_536,
        fetch_head_bytes: 262_144,
        freed_segments_bytes: 69_905_080
      }
    },
    %{
      name: :builds,
      pool: "build",
      user_prefix: "locus-build",
      uids: 30_001..30_016,
      isolation: nil,
      port: 4100,
      home_size: "2g",
      service: "locus-builds",
      container: "cyfr-locus-builds",
      network: "locus-builds",
      profile: "locus-builds",
      guard: "locus-builds-guard",
      kept_root: nil,
      kept_volume: nil,
      kept_uids: nil,
      memory: %{
        unread: nil,
        answering: 8_388_608,
        fetch_read_bytes: nil,
        fetch_head_bytes: nil,
        freed_segments_bytes: nil
      }
    },
    %{
      name: :backends,
      pool: "backends",
      user_prefix: "locus-backend",
      uids: 20_001..20_032,
      isolation: nil,
      port: 4101,
      home_size: "2g",
      service: "locus-backends",
      container: "cyfr-locus-backends",
      network: "locus-backends",
      profile: nil,
      guard: "locus-backends-guard",
      kept_root: "/var/lib/locus/kept",
      kept_volume: "homes",
      kept_uids: 40_001..49_999,
      memory: %{
        unread: 67_108_864,
        answering: 27_262_976,
        fetch_read_bytes: nil,
        fetch_head_bytes: nil,
        freed_segments_bytes: nil
      }
    }
  ]

  @names Enum.map(@roles, & &1.name)

  @doc "The facts every role's service shares."
  @spec release() :: release()
  def release, do: @release

  @doc "Every role's facts: the runtime's, the builds role's and the backends role's, in that order."
  @spec roles() :: [role(), ...]
  def roles, do: @roles

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
