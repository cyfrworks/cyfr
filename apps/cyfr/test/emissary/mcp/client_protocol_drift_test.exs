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
    # The one outbound MCP client: Emissary's, which speaks to an http server
    # and, over a program's session, to a stdio one. Locus carries lines and
    # speaks no MCP of its own.
    @legacy_sources ["apps/cyfr/lib/emissary/external/server.ex"]

    # The one definition, read by name: the alias spelling and the full one.
    @legacy_call ~r/\A(?:Prima\.MCP\.)?Protocol\.legacy_version\(\)\z/
    @date_literal ~r/"\d{4}-\d{2}-\d{2}"/
    # Each revision the hop sends: an `initialize`'s `protocolVersion`.
    @sent_revision ~r/"protocolVersion"\s*=>\s*([^,\n]+)/

    # What is wrong with one outbound hop's source: every revision it sends
    # must read `Prima.MCP.Protocol.legacy_version/0`, and it spells no
    # revision of its own.
    defp legacy_drift(source) do
      sent = for [value] <- Regex.scan(@sent_revision, source, capture: :all_but_first), do: value
      missing = if sent == [], do: [:no_initialize], else: []
      wrong = for value <- sent, not (value =~ @legacy_call), do: {:not_legacy_version, value}
      literals = for [date] <- Regex.scan(@date_literal, source), do: {:date_literal, date}
      missing ++ wrong ++ literals
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
          ~s("#{Protocol.legacy_version()}")
        )

      # Every read spelled back as the date: the client reads it at its
      # initialize and at its legacy fallback.
      date = ~s("#{Protocol.legacy_version()}")
      drift = legacy_drift(planted)
      assert length(drift) >= 4
      assert Enum.uniq(drift) == [{:not_legacy_version, date}, {:date_literal, date}]

      # One initialize of several sending the current revision is refused,
      # though another still reads the legacy one.
      legacy = ~s|"protocolVersion" => Protocol.legacy_version()|
      assert [head, tail] = String.split(source, legacy, parts: 2)
      one = head <> ~s|"protocolVersion" => Protocol.version()| <> tail
      assert legacy_drift(one) == [{:not_legacy_version, "Protocol.version()"}]

      assert legacy_drift(source <> ~s(\n@legacy "2025-03-26"\n)) == [
               {:date_literal, ~s("2025-03-26")}
             ]
    end
  end
end
