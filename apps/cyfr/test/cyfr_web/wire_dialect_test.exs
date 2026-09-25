# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.WireDialectTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Every non-empty error body on the HTTP surface renders through an
  `CyfrWeb.ErrorRenderer` (`ApiError` for plain HTTP, `MCPError` for
  JSON-RPC). A hand-rolled `send_resp` is how one resource once answered
  the same condition in two wire dialects — the tincture GET's text/plain
  "Not Found" beside its invoke's JSON `{"code":"not_found"}` — and how a
  signed-asset route collapsed five distinct refusals into one untyped 404.

  The HTTP surface is two trees, the host's web tier (`apps/cyfr/lib/cyfr_web`)
  and the MCP adapter's (`apps/cyfr/lib/emissary/web`); nothing else renders
  an HTTP body. The roster below names every deliberate `send_resp` in them
  with its reason. A new one fails here until it is routed through a
  renderer or written down.
  """

  @lib Path.expand("../../lib", __DIR__)
  @trees ["cyfr_web", "emissary/web"]

  @allowed %{
    # 202 with an empty body for JSON-RPC notifications — nothing to render.
    "emissary/web/controllers/mcp_controller.ex" => "202 empty body for notifications",
    # The Prometheus scrape surface speaks text/plain in all three arms —
    # its clients are scrapers, not API consumers. (404 disabled, 401
    # unauthorized once `CYFR_METRICS_TOKEN` is set, 200 metrics.)
    "cyfr_web/metrics_plug.ex" => "the Prometheus scrape surface speaks text/plain",
    # 204 empty preflight body.
    "cyfr_web/plugs/cors.ex" => "204 empty preflight body",
    # A browser hitting a headless node reads a sentence, not JSON.
    "cyfr_web/plugs/headless.ex" => "browser surface: plain-text explainer on a headless node",
    # The duplicate-delivery answer is a 200 SUCCESS body (JSON), not an
    # error — a renderer would mislabel it.
    "cyfr_web/plugs/webhook_idempotency.ex" => "duplicate answer is a 200 success body",
    # The sign-in flow's no-session pages are HTML pages, not API error bodies.
    "cyfr_web/minimal_page.ex" => "renders the sign-in flow's no-session HTML pages",
    # A missing asset answers a browser's resource fetch with the asset
    # surface's own plain 404.
    "cyfr_web/ingress/tincture_assets.ex" =>
      "the asset surface's plain 404 for a browser resource fetch"
  }

  test "every bare send_resp is on the roster with a reason" do
    offenders =
      @trees
      |> Enum.flat_map(&Prima.Test.SourceTree.files!(Path.join([@lib, &1, "**/*.ex"])))
      |> Enum.filter(fn file ->
        # send_chunked is the SSE open — a stream, not a body to render.
        file |> File.read!() |> String.match?(~r/\bsend_resp\(/)
      end)
      |> Enum.map(&Path.relative_to(&1, @lib))
      |> Enum.reject(&Map.has_key?(@allowed, &1))

    assert offenders == [],
           "bare send_resp outside the renderer seam in #{inspect(offenders)} — " <>
             "route the refusal through CyfrWeb.ApiError / Emissary.Web.MCPError, " <>
             "or add the file to @allowed with its reason"
  end
end
