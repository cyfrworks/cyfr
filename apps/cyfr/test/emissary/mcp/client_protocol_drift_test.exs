# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ClientProtocolDriftTest do
  @moduledoc """
  The protocol version has one Elixir source (`Prima.MCP.Protocol`), but
  one first-party client lives outside the BEAM and must carry its own
  literal: the Go CLI. This test binds that literal to the server's version
  so a revision bump cannot strand a bundled client on a version the server
  refuses.

  Pins the shared outbound fallback revision used for third-party MCP peers
  and for the stdio backends the Locus backends service runs: both hops read
  `Prima.MCP.Protocol.legacy_version/0` and spell no revision of their own.
  """
  use ExUnit.Case, async: true

  alias Prima.MCP.Protocol

  @project_root Path.expand("../../../../..", __DIR__)

  @clients [
    {"apps/codex/internal/mcp/client.go", ~r/protocolVersion\s*=\s*"(\d{4}-\d{2}-\d{2})"/}
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
      "apps/cyfr/lib/emissary/external/server.ex",
      "apps/locus/lib/locus/backends/backend.ex"
    ]

    # The one definition, read by name: the alias spelling and the full one.
    @legacy_call ~r/\b(?:Prima\.MCP\.)?Protocol\.legacy_version\(\)/
    @date_literal ~r/"\d{4}-\d{2}-\d{2}"/

    # What is wrong with one outbound hop's source: it must read the legacy
    # revision from `Prima.MCP.Protocol.legacy_version/0` and spell no
    # revision of its own.
    defp legacy_drift(source) do
      missing = if source =~ @legacy_call, do: [], else: [:no_legacy_version_call]
      literals = for [date] <- Regex.scan(@date_literal, source), do: {:date_literal, date}
      missing ++ literals
    end

    test "every outbound fallback reads the one legacy revision and spells none of its own" do
      drift =
        for path <- @legacy_sources,
            problem <- legacy_drift(File.read!(Path.join(@project_root, path))),
            do: {path, problem}

      assert drift == [],
             """
             An outbound hop names its own legacy revision, or no longer reads
             `Prima.MCP.Protocol.legacy_version/0`. One legacy revision, or
             "legacy" means whichever hop you happened to ask.

             #{inspect(drift)}
             """

      # And the legacy revision must not be the current one, or the
      # fallback is not a fallback.
      refute Protocol.legacy_version() == Protocol.version()
    end

    test "a hop that spells a revision back into its source is refused" do
      [path | _] = @legacy_sources
      source = File.read!(Path.join(@project_root, path))
      assert legacy_drift(source) == []

      planted =
        String.replace(
          source,
          "Protocol.legacy_version()",
          ~s("#{Protocol.legacy_version()}"),
          global: false
        )

      assert legacy_drift(planted) == [
               :no_legacy_version_call,
               {:date_literal, ~s("#{Protocol.legacy_version()}")}
             ]

      assert legacy_drift(source <> ~s(\n@legacy "2025-03-26"\n)) == [
               {:date_literal, ~s("2025-03-26")}
             ]
    end
  end
end
