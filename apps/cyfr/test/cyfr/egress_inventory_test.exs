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

  Deciding and connecting are separate, and only connecting is listed
  here. `Cyfr.Network` (in the contracts) resolves the host once,
  classifies the address and answers the options that connect to it with
  redirects, retry, compression and body decoding all off; it holds no
  HTTP client, so the layers below the host — the builder island among
  them — can validate a destination without one in their tree. Every
  `:pinned_*` row below is a few lines over that one decision, in the app
  that already speaks HTTP. A row that starts deciding for itself is the
  drift this inventory is for.

  The JS bridge (`apps/mcp-bridge/server.mjs`) is its own egress arm: it
  runs stdio MCP backends, which reach the network as their commands do,
  and speaks to them only over their stdio. It ships with the server, is
  scanned by nothing here, and is called out so this inventory is honest
  about its edge. CYFR reaches the bridge through `Cyfr.Egress`.
  """

  use ExUnit.Case, async: true

  @allowed %{
    # The control plane's pinned transport: every OCI, registry, MCP and
    # bridge request goes out here, to the address `Cyfr.Network.pin/2`
    # validated, with its response bounded while it streams
    # (`Cyfr.BoundedBody`).
    "apps/cyfr/lib/cyfr/egress.ex" => :pinned_owner,
    # The OAuth token POST to a caller-supplied endpoint, pinned the same
    # way under the operator's private-egress allowlist. The auth domain
    # owns the few lines rather than reaching up to the host's transport;
    # the decision is still `Cyfr.Network.pin/2`'s.
    "apps/sanctum/lib/sanctum/vault/oauth.ex" => :pinned_token_exchange,
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
    # The worker wire, CYFR's side: `Cyfr.WorkerAPI` requests to the
    # operator-configured worker services (CYFR_WORKERS), signed with each
    # service's dispatch key, bounded answers (`Cyfr.WorkerWire`).
    "apps/cyfr/lib/cyfr/execution/worker_client.ex" => :worker_client,
    # The worker wire, Opus's side: a runner's host calls and the service's
    # exit reports to CYFR's host API (OPUS_HOST_URL), sealed and signed
    # with the attempt's keys, bounded answers.
    "apps/opus/lib/opus/host_client.ex" => :host_client,
    # The builds wire, CYFR's side: `Cyfr.BuilderProtocol` requests to the
    # operator-configured Locus builds service (CYFR_LOCUS_BUILDS_URL),
    # signed with the key derived from the service's, the answer bounded
    # while it streams (`Cyfr.BoundedBody`) and read strictly.
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

  defp root, do: Path.expand("../../../..", __DIR__)

  test "every outbound HTTP site is classified" do
    found =
      Cyfr.Test.SourceTree.files!(Path.join(root(), "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        source =
          path
          |> Cyfr.Test.SourceTree.read()
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
           or route them through a pinned site above):
             #{inspect(found -- allowed)}

           stale rows (the site no longer speaks HTTP):
             #{inspect(allowed -- found)}
           """
  end

  test "the bridge's egress arm still exists where this inventory says" do
    assert File.exists?(Path.join(root(), "apps/mcp-bridge/server.mjs"))
  end
end
