# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.GuideProtocolDriftTest do
  @moduledoc """
  The guides are not just documentation — `integration-guide.md`,
  `component-guide.md` and `tincture-guide.md` are compiled into
  `Compendium.MCP.AquaTool` as `@external_resource` and served to the AQUA agent
  as its reference material.

  So a stale protocol sample is not a cosmetic problem. It is the agent being
  taught, authoritatively, to send requests the server will refuse: for a while
  the guide documented the `initialize` handshake and `MCP-Session-Id` from
  `2025-11-25`, both removed, and every sample in it failed header validation.

  This test fails on any retired method or header name reappearing.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.Protocol

  @project_root Path.expand("../../../..", __DIR__)
  @guides ~w(integration-guide.md component-guide.md tincture-guide.md)

  # Removed by 2026-07-28. A guide naming any of these is teaching a protocol
  # this server does not speak.
  @retired_methods ~w(
    initialize
    notifications/initialized
    resources/subscribe
    resources/unsubscribe
    logging/setLevel
    tasks/result
    tasks/list
  )

  # `Last-Event-ID` is NOT retired: it left the MCP plane but lives on the
  # non-MCP SSE endpoint (`/api/executions/:id/events`, see the router's
  # :authenticated_api pipeline) — guides may document reconnection there.
  @retired_headers ~w(Mcp-Session-Id)

  # Version strings only ever appear in a `…protocol…version…` context in the
  # guides (headers, `_meta` keys, client constants). Anchoring on that context
  # catches ANY stale revision — including future ones — without a
  # hand-maintained retired list, while ignoring unrelated dates (timestamps,
  # provider api_version fields).
  @version_site_re ~r/protocol[-_\/]?version[^\d]{0,10}(\d{4}-\d{2}-\d{2})/i

  defp guide(name), do: File.read!(Path.join(@project_root, name))

  # Only the samples are checked, not the prose. Explaining that `initialize` was
  # removed necessarily names it, and that sentence is worth having — what must
  # not survive is a code block a reader can copy into a client that will be
  # refused. Splitting on the fence and keeping the odd-indexed chunks leaves
  # exactly the fenced blocks.
  defp samples(name) do
    name
    |> guide()
    |> String.split("```")
    |> Enum.drop_every(2)
    |> Enum.join("\n")
  end

  for name <- @guides do
    test "#{name} shows only supported protocol versions" do
      text = guide(unquote(name))

      versions =
        @version_site_re
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      for version <- versions do
        assert version in Protocol.supported(),
               """
               #{unquote(name)} still shows protocol version #{version}.

               This file is compiled into Compendium.MCP.AquaTool, so the agent
               reads it as authoritative. Use #{Protocol.version()}.
               """
      end
    end

    test "#{name} shows no retired method in a sample" do
      text = samples(unquote(name))

      for method <- @retired_methods do
        refute String.contains?(text, "\"#{method}\""),
               """
               #{unquote(name)} shows a `#{method}` call, which this revision removed.

               A sample that cannot succeed is worse than no sample: the agent
               will follow it and receive a protocol error it has no way to
               interpret.
               """
      end
    end

    test "#{name} shows no retired header in a sample" do
      text = samples(unquote(name))

      for header <- @retired_headers do
        refute String.contains?(text, header),
               "#{unquote(name)} still documents the `#{header}` header, which this revision removed."
      end
    end
  end

  test "the integration guide documents every header the server requires" do
    text = guide("integration-guide.md")

    for header <- Protocol.request_headers() do
      # Documented in the guide's own casing, so compare case-insensitively.
      assert String.contains?(String.downcase(text), header),
             """
             integration-guide.md never mentions the `#{header}` header, which
             EmissaryWeb.Plugs.MCPRequestMetadata requires on every request. A reader
             following this guide would build a client that is refused.
             """
    end
  end

  test "the integration guide shows the required _meta keys" do
    text = guide("integration-guide.md")

    for key <- [Protocol.meta_protocol_version_key(), Protocol.meta_client_capabilities_key()] do
      assert String.contains?(text, key),
             "integration-guide.md does not show the required `#{key}` field."
    end
  end
  # The invoke error-type table is the same class of authority: the agent
  # writes formulas that branch on these. The guide once documented two
  # types no code produced (`invalid_type`, `execution_failed`) and omitted
  # five that are — so generated error handling matched nothing.
  test "component-guide's invoke error table matches Opus.FormulaHandler's vocabulary" do
    handler =
      File.read!(Path.join(@project_root, "apps/opus/lib/opus/formula_handler.ex"))

    produced =
      Regex.scan(~r/encode_error(?:_with_remediation)?\(:(\w+)/, handler)
      |> Enum.map(fn [_, t] -> t end)
      |> Kernel.++(Regex.scan(~r/"type" => "(\w+)"/, handler) |> Enum.map(fn [_, t] -> t end))
      |> Enum.uniq()
      |> Enum.sort()

    guide = guide("component-guide.md")

    [_, table] = String.split(guide, "### Invoke Error Types", parts: 2)
    [table, _] = String.split(table, "\n\n`setup_required`", parts: 2)

    documented =
      Regex.scan(~r/^\| `(\w+)` \|/m, table)
      |> Enum.map(fn [_, t] -> t end)
      |> Enum.sort()

    assert documented == produced,
           "component-guide.md's invoke error table drifted from " <>
             "Opus.FormulaHandler: documented #{inspect(documented)}, " <>
             "produced #{inspect(produced)}"
  end
end
