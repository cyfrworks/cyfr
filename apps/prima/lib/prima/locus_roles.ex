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

  The release's endpoint, which cyfr serves, binds one fixed address
  under compose: `endpoint_address`, on the network `endpoint_network`
  (compose's `default`), whose subnet is `endpoint_subnet` and whose other
  containers take addresses from `endpoint_ip_range` alone, so nothing
  started first can hold cyfr's. Docker publishes the host's loopback port
  to that address, and the networks the Locus roles join never reach the
  endpoint.

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
          endpoint_address: String.t()
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
          guard: String.t() | nil
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
    endpoint_address: "172.16.230.2"
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
      guard: nil
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
      guard: "locus-builds-guard"
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
      guard: "locus-backends-guard"
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
