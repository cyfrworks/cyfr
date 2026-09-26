# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EgressInventoryTest do
  @moduledoc """
  A mechanical inventory of everywhere this node speaks HTTP outward —
  the mirror of `Cyfr.IngressInventoryTest`.

  Outbound HTTP is where SSRF, credential leakage and unbounded buffering
  live, so each site must be a classified, deliberate act: the control
  plane's pinned transport, the auth domain's token POST, the object
  store, the IdP sliver, or the two guest egress handlers.
  A new `Req`/`Finch`/`httpc` call fails here until someone classifies
  it — the fail-closed direction.

  The pure `Prima.Network` policy validates a supplied address and constructs
  pinned options. Sanctum and Opus own their DNS resolution; Sanctum.Egress
  sends control-plane requests, and Opus owns the guest HTTP handlers.

  Resolving an outbound name is inventoried beside sending to it: every
  site that resolves a host (`getaddr`) or pins a URL through the control
  plane's resolver (`Sanctum.Network.pin/2`) is classified. A guest's
  outbound target is pinned by the control plane (`Crucible.Host.Egress`,
  the `egress_pin` host call), under the attempt's admitted authority.

  The Locus backends service (`Locus.Backends.Service`) is its own egress
  arm: it runs stdio MCP backends (`Locus.Backends.Backend`) under the
  keeper, which reach the network as their commands do, and speaks to them
  only over their stdio. The service itself sends no HTTP, so the scan
  finds nothing there; it is called out so this inventory is honest about
  its edge. CYFR reaches the service through `Sanctum.Egress`.
  """

  use ExUnit.Case, async: true

  @allowed %{
    # OCI, registry, MCP and OAuth token requests all connect through the
    # address Sanctum.Network validates, with streamed response ceilings.
    "apps/sanctum/lib/sanctum/egress.ex" => :pinned_owner,
    # S3-compatible object store — operator-configured endpoint, SigV4.
    "apps/arca/lib/arca/adapters/s3.ex" => :object_store,
    # The IdP OAuth device-flow sliver: GitHub/Google fixed hosts, its own
    # Finch pool, budgeted by the device-poll rate limits.
    "apps/sanctum/lib/sanctum/auth/device_flow.ex" => :idp_sliver,
    # Guest HTTP (cyfr:http/fetch) — consented edges, pinned opts, bounded
    # while streaming.
    "apps/opus/lib/opus/http_handler.ex" => :guest_fetch,
    # Guest streaming HTTP — `into: :self` with an append-time byte budget.
    "apps/opus/lib/opus/http_stream_handler.ex" => :guest_stream,
    # The worker wire, CYFR's side: `Prima.WorkerAPI` requests to the
    # operator-configured worker services (CYFR_OPUS_WORKERS), signed with each
    # service's dispatch key, bounded answers (`Prima.WorkerWire`).
    "apps/cyfr/lib/crucible/worker_client.ex" => :worker_client,
    # The worker wire, Opus's side: a runner's host calls and the service's
    # exit reports to CYFR's host API (OPUS_HOST_URL), sealed and signed
    # with the attempt's keys, bounded answers.
    "apps/opus/lib/opus/host_client.ex" => :host_client,
    # The builds wire, CYFR's side: `Prima.BuilderProtocol` requests to the
    # operator-configured Locus builds service (CYFR_LOCUS_BUILDS_URL),
    # signed with the key derived from the service's, the answer bounded
    # while it streams (`Prima.BoundedBody`) and read strictly.
    "apps/cyfr/lib/compendium/builds/client.ex" => :builds_client
  }

  @patterns [
    "Req.request(",
    "Req.get(",
    "Req.get!(",
    "Req.post(",
    "Req.post!(",
    "Finch.build(",
    "Finch.request(",
    ":httpc."
  ]

  # Every site that resolves an outbound host name.
  @resolvers %{
    # The control plane's one resolver: IPv4 first, IPv6 only when no IPv4
    # address resolves, the address pinned for the connection.
    "apps/sanctum/lib/sanctum/network.ex" => :control_plane_resolver,
    # The control plane's pinned transport, resolving through the above.
    "apps/sanctum/lib/sanctum/egress.ex" => :pinned_owner,
    # A guest's outbound target, pinned by the control plane under the
    # attempt's admitted authority (`egress_pin`), through the above.
    "apps/cyfr/lib/crucible/host/egress.ex" => :guest_pin
  }

  @resolver_patterns ["getaddr(", "Sanctum.Network.pin("]

  defp root, do: Path.expand("../../../..", __DIR__)

  # The lib files whose code (docs and comment lines aside) names any of
  # `patterns`, relative to the root.
  defp sites(patterns) do
    Prima.Test.SourceTree.files!(Path.join(root(), "apps/*/lib/**/*.ex"))
    |> Enum.filter(fn path ->
      source =
        path
        |> Prima.Test.SourceTree.read()
        |> String.replace(~r/"""[\s\S]*?"""/, "")
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.join("\n")

      Enum.any?(patterns, &String.contains?(source, &1))
    end)
    |> Enum.map(&Path.relative_to(&1, root()))
    |> Enum.sort()
  end

  test "every outbound HTTP site is classified" do
    found = sites(@patterns)
    allowed = @allowed |> Map.keys() |> Enum.sort()

    assert found == allowed,
           """
           the outbound-HTTP inventory changed.

           unclassified sites (add a row to @allowed with what they are,
           or route them through a pinned site above):
             #{inspect(found -- allowed)}

           stale rows (the site no longer speaks HTTP):
             #{inspect(allowed -- found)}
           """
  end

  test "every site that resolves an outbound host is classified" do
    found = sites(@resolver_patterns)
    allowed = @resolvers |> Map.keys() |> Enum.sort()

    assert found == allowed,
           """
           the outbound name-resolution inventory changed.

           unclassified sites (add a row to @resolvers with what they are,
           or resolve through a site above):
             #{inspect(found -- allowed)}

           stale rows (the site no longer resolves a host):
             #{inspect(allowed -- found)}
           """
  end

  test "the backends service's egress arm still exists where this inventory says" do
    for path <-
          ~w(apps/locus/lib/locus/backends/service.ex apps/locus/lib/locus/backends/backend.ex) do
      assert File.exists?(Path.join(root(), path)), path
    end
  end
end
