# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EgressInventoryTest do
  @moduledoc """
  A mechanical inventory of everywhere this node speaks HTTP outward —
  the mirror of `Cyfr.IngressInventoryTest`.

  Outbound HTTP is where SSRF, credential leakage and unbounded buffering
  live, so each site must be a classified, deliberate act: the pinned
  transport (`Cyfr.Network` — SSRF-validated IP, streaming byte caps),
  the object store, the IdP sliver, or the two guest egress handlers.
  A new `Req`/`Finch`/`httpc` call fails here until someone classifies
  it — the fail-closed direction.

  The JS bridge (`apps/mcp-bridge/server.mjs`) is its own egress arm: it
  wraps stdio MCP backends and speaks HTTP only to the loopback backends
  it spawned. It ships with the server, is scanned by nothing here, and
  is called out so this inventory is honest about its edge.
  """

  use ExUnit.Case, async: true

  @allowed %{
    # The one pinned transport: SSRF validation, hostname-preserving IP
    # pinning, and streaming response caps live here.
    "apps/cyfr/lib/cyfr/network.ex" => :pinned_owner,
    # S3-compatible object store — operator-configured endpoint, SigV4.
    "apps/cyfr/lib/arca/adapters/s3.ex" => :object_store,
    # The IdP OAuth device-flow sliver: GitHub/Google fixed hosts, its own
    # Finch pool, budgeted by the device-poll rate limits.
    "apps/cyfr/lib/sanctum/auth/device_flow.ex" => :idp_sliver,
    # Guest HTTP (cyfr:http/fetch) — consented edges, pinned opts, bounded
    # while streaming.
    "apps/opus/lib/opus/http_handler.ex" => :guest_fetch,
    # Guest streaming HTTP — `into: :self` with an append-time byte budget.
    "apps/opus/lib/opus/http_stream_handler.ex" => :guest_stream
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

  defp root, do: Path.expand("../../../..", __DIR__)

  test "every outbound HTTP site is classified" do
    found =
      Path.wildcard(Path.join(root(), "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        source =
          path
          |> File.read!()
          |> String.replace(~r/"""[\s\S]*?"""/, "")
          |> String.split("\n")
          |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
          |> Enum.join("\n")

        Enum.any?(@patterns, &String.contains?(source, &1))
      end)
      |> Enum.map(&Path.relative_to(&1, root()))
      |> Enum.sort()

    allowed = @allowed |> Map.keys() |> Enum.sort()

    assert found == allowed,
           """
           the outbound-HTTP inventory changed.

           unclassified sites (add a row to @allowed with what they are,
           or route them through Cyfr.Network):
             #{inspect(found -- allowed)}

           stale rows (the site no longer speaks HTTP):
             #{inspect(allowed -- found)}
           """
  end

  test "the bridge's egress arm still exists where this inventory says" do
    assert File.exists?(Path.join(root(), "apps/mcp-bridge/server.mjs"))
  end
end
