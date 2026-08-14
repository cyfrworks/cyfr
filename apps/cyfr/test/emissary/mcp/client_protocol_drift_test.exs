# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ClientProtocolDriftTest do
  @moduledoc """
  The protocol version has one Elixir source (`Emissary.MCP.Protocol`), but
  three first-party clients live outside the BEAM and must carry their own
  literal: the Go CLI, the mcp-bridge, and the Porta PWA. This test binds
  those literals to the server's version so a revision bump cannot strand a
  bundled client on a version the server refuses.

  Outbound legacy support is deliberate — third-party servers and npx
  children are on their own release cadence — but it is *one* legacy
  revision, and that is bound here too. It used to be two: the bridge
  offered its children 2024-11-05 while cyfr offered peers 2025-03-26, so
  "the legacy version" named two different dates depending on the hop.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.Protocol

  @project_root Path.expand("../../../../..", __DIR__)

  @clients [
    {"apps/codex/internal/mcp/client.go", ~r/protocolVersion\s*=\s*"(\d{4}-\d{2}-\d{2})"/},
    {"apps/mcp-bridge/server.mjs", ~r/const PROTOCOL_VERSION\s*=\s*"(\d{4}-\d{2}-\d{2})"/},
    {"apps/porta/src-ui/src/api/mcp-client.ts",
     ~r/const PROTOCOL_VERSION\s*=\s*"(\d{4}-\d{2}-\d{2})"/}
  ]

  for {path, regex} <- @clients do
    test "#{path} speaks the server's protocol version" do
      source = File.read!(Path.join(@project_root, unquote(path)))

      case Regex.run(unquote(Macro.escape(regex)), source, capture: :all_but_first) do
        [version] ->
          assert version == Protocol.version(),
                 """
                 #{unquote(path)} declares protocol version #{version}, but the
                 server speaks #{Protocol.version()}. Bump the client literal —
                 a bundled client on a retired revision is refused by every
                 request's version check.
                 """

        nil ->
          flunk("""
          Could not find the protocol version literal in #{unquote(path)}.
          If the constant moved or was renamed, update this test's pattern —
          losing this check silently unbinds the client from the server.
          """)
      end
    end
  end

  describe "outbound legacy support names one revision" do
    @legacy_sources [
      {"apps/cyfr/lib/emissary/mcp/external_server.ex",
       ~r/@legacy_protocol_version\s+"(\d{4}-\d{2}-\d{2})"/},
      {"apps/mcp-bridge/server.mjs",
       ~r/const CHILD_PROTOCOL_VERSION\s*=\s*"(\d{4}-\d{2}-\d{2})"/}
    ]

    test "every outbound fallback offers the same legacy revision" do
      versions =
        for {path, regex} <- @legacy_sources do
          source = File.read!(Path.join(@project_root, path))

          case Regex.run(regex, source, capture: :all_but_first) do
            [version] ->
              {path, version}

            nil ->
              flunk("""
              Could not find the legacy protocol literal in #{path}.
              If the constant moved or was renamed, update this test —
              losing this check lets the two hops drift apart again.
              """)
          end
        end

      [{_, first} | _] = versions

      for {path, version} <- versions do
        assert version == first,
               """
               #{path} falls back to #{version}, but another outbound hop
               falls back to #{first}. One legacy revision, or "legacy"
               means whichever hop you happened to ask.

               #{inspect(versions)}
               """
      end

      # And the legacy revision must not be the current one, or the
      # fallback is not a fallback.
      refute first == Protocol.version()
    end
  end
end
