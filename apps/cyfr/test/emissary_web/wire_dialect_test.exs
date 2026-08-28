# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.WireDialectTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Every non-empty error body on the EmissaryWeb surface renders through an
  `EmissaryWeb.ErrorRenderer` (`ApiError` for plain HTTP, `MCPError` for
  JSON-RPC). A hand-rolled `send_resp` is how one resource once answered
  the same condition in two wire dialects — the tincture GET's text/plain
  "Not Found" beside its invoke's JSON `{"code":"not_found"}` — and how a
  signed-asset route collapsed five distinct refusals into one untyped 404.

  The roster below names every deliberate `send_resp` with its reason. A
  new one fails here until it is routed through a renderer or written down.
  """

  @root Path.expand("../../lib/emissary_web", __DIR__)

  @allowed %{
    # 202 with an empty body for JSON-RPC notifications — nothing to render.
    "controllers/mcp_controller.ex" => "202 empty body for notifications",
    # The Prometheus scrape surface speaks text/plain in both arms — its
    # clients are scrapers, not API consumers.
    "metrics_plug.ex" => "the Prometheus scrape surface speaks text/plain",
    # The one no-session HTML shell — a browser page, not an API answer.
    "minimal_page.ex" => "renders the console's no-session HTML shell",
    # 204 empty preflight body.
    "plugs/cors.ex" => "204 empty preflight body",
    # A browser hitting a headless node reads a sentence, not JSON.
    "plugs/headless.ex" => "browser surface: plain-text explainer on a headless node",
    # The browser claim-gate flow: its other arms redirect; the 503 stays
    # in the same human dialect.
    "plugs/require_personal_namespace.ex" => "browser flow: plain-text 503 beside redirects",
    # The duplicate-delivery answer is a 200 SUCCESS body (JSON), not an
    # error — a renderer would mislabel it.
    "plugs/webhook_idempotency.ex" => "duplicate answer is a 200 success body"
  }

  test "every bare send_resp is on the roster with a reason" do
    offenders =
      Path.join(@root, "**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn file ->
        # send_chunked is the SSE open — a stream, not a body to render.
        file |> File.read!() |> String.match?(~r/\bsend_resp\(/)
      end)
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.reject(&Map.has_key?(@allowed, &1))

    assert offenders == [],
           "bare send_resp outside the renderer seam in #{inspect(offenders)} — " <>
             "route the refusal through EmissaryWeb.ApiError / EmissaryWeb.MCPError, " <>
             "or add the file to @allowed with its reason"
  end
end
