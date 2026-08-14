# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ClientProtocolDriftTest do
  @moduledoc """
  The protocol version has one Elixir source (`Emissary.MCP.Protocol`), but
  three first-party clients live outside the BEAM and must carry their own
  literal: the Go CLI, the mcp-bridge, and the Porta PWA. This test binds
  those literals to the server's version so a revision bump cannot strand a
  bundled client on a version the server refuses.

  Only each client's INBOUND/self version is checked. The bridge's
  `CHILD_PROTOCOL_VERSION` (outbound to npx children) and the outbound
  client's legacy fallback are deliberate dual-era support and are not
  bound here.
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
end
