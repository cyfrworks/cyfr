# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.GuideProtocolDriftTest do
  @moduledoc """
  The guides are not just documentation — `integration-guide.md`,
  `component-guide.md` and `tincture-guide.md` are compiled into
  `Compendium.Providers.Aqua` as `@external_resource` and served to the AQUA agent
  as its reference material.

  Validate guide samples against the server protocol so copied requests are accepted.

  Rejects unsupported methods and headers in protocol samples.
  """
  use ExUnit.Case, async: true

  alias Prima.MCP.Protocol

  @project_root Path.expand("../../../..", __DIR__)
  @guides ~w(integration-guide.md component-guide.md tincture-guide.md)

  # Methods this protocol revision does not define: a sample calling one
  # is answered with a protocol error.
  @undefined_methods ~w(
    initialize
    notifications/initialized
    resources/subscribe
    resources/unsubscribe
    logging/setLevel
    tasks/result
    tasks/list
  )

  # Headers this protocol revision does not define. Last-Event-ID is
  # defined (/api/executions/:id/events) and may appear in guides.
  @undefined_headers ~w(Mcp-Session-Id)

  # Version strings only ever appear in a `…protocol…version…` context in the
  # guides (headers, `_meta` keys, client constants). Anchoring on that context
  # catches any revision the server does not support, without a hand-kept
  # list, while ignoring unrelated dates (timestamps, provider api_version
  # fields).
  @version_site_re ~r/protocol[-_\/]?version[^\d]{0,10}(\d{4}-\d{2}-\d{2})/i

  defp guide(name), do: File.read!(Path.join(@project_root, name))

  # Check fenced code samples; split on fences and retain odd-indexed chunks.
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
               #{unquote(name)} shows protocol version #{version}, which the server does not support.

               This file is compiled into Compendium.Providers.Aqua, so the agent
               reads it as authoritative. Use #{Protocol.version()}.
               """
      end
    end

    test "#{name} shows only methods the protocol defines in a sample" do
      text = samples(unquote(name))

      for method <- @undefined_methods do
        refute String.contains?(text, "\"#{method}\""),
               """
               #{unquote(name)} shows a `#{method}` call, which this protocol revision does not define.

               A sample that cannot succeed is worse than no sample: the agent
               will follow it and receive a protocol error it has no way to
               interpret.
               """
      end
    end

    test "#{name} shows only headers the protocol defines in a sample" do
      text = samples(unquote(name))

      for header <- @undefined_headers do
        refute String.contains?(text, header),
               "#{unquote(name)} documents the `#{header}` header, which this protocol revision does not define."
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
             Emissary.Web.Plugs.MCPRequestMetadata requires on every request. A reader
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
  # writes formulas that branch on these, so a type the guide names and no
  # code produces, or one it omits, leaves generated error handling matching
  # nothing.
  # A formula's invoke errors are rendered in two places: the runner's
  # `Locus.Runtime.FormulaHandler`, and CYFR's answer to a child or catalog tool call
  # it refuses (`Opus.Host.Children`).
  test "component-guide's invoke error table matches the invoke error vocabulary" do
    handler =
      [
        "apps/locus/lib/locus/runtime/formula_handler.ex",
        "apps/cyfr/lib/opus/host/children.ex"
      ]
      |> Enum.map_join("\n", &File.read!(Path.join(@project_root, &1)))

    produced =
      [
        ~r/(?:encode_error(?:_with_remediation)?|guest_error)\(:(\w+)/,
        ~r/"type" => "(\w+)"/,
        ~r/\{:guest_error, "(\w+)"/
      ]
      |> Enum.flat_map(&Regex.scan(&1, handler))
      |> Enum.map(fn [_, t] -> t end)
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
             "the invoke error vocabulary: documented #{inspect(documented)}, " <>
             "produced #{inspect(produced)}"
  end
end
