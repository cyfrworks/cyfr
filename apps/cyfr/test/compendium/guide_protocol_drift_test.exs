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

  @retired_headers ~w(Mcp-Session-Id Last-Event-ID)

  # Revisions this server no longer accepts. `Protocol.supported/0` is the only
  # version string a guide may show.
  @retired_versions ~w(2024-11-05 2025-03-26 2025-06-18 2025-11-25)

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
    test "#{name} shows no retired protocol version in a sample" do
      text = samples(unquote(name))

      for version <- @retired_versions do
        refute String.contains?(text, version),
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
             EmissaryWeb.Plugs.MCPSession requires on every request. A reader
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
end
