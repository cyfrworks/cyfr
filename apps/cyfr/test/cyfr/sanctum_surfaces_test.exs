# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SanctumSurfacesTest do
  @moduledoc """
  Every Apache-2.0 namespace's reach into the FSL-licensed auth domain,
  written down.

  `Arca.SanctumSurfaceTest` and `Opus.HostSurfaceTest` pinned two of the
  crossings; the other seven namespaces reached into `lib/sanctum` with no
  governed surface at all — and since `lib/sanctum` is FSL while everything
  else is Apache-2.0, every one of those reaches is also a license-boundary
  crossing that could only widen silently.

  The rosters record today's reality, each entry with the reason it is
  there. A new reach fails here until someone decides it belongs; a
  namespace that stops reaching must leave the roster.
  """

  use ExUnit.Case, async: true

  # ordinary layering notes:
  #   - the web faces (emissary_web, prism_web) are the auth fabric's own
  #     ingresses — their wide rosters are the front doors doing their job;
  #   - `cyfr` is the glue/application namespace: boot wiring, telemetry
  #     and supervision legitimately name many Sanctum parts;
  #   - the narrow ones to watch are `aqua`, `prism`, `compendium` and
  #     `emissary` — domain code whose Sanctum reach should stay vocabulary
  #     and the tenancy carrier.
  @surfaces %{
    # `Sanctum.Authority` is `Aqua.Ops` alone: the in-chain call an
    # approved proposal runs under carries the chain's authority, and the
    # seam's contract names its type. `Sanctum.Provisioning` is
    # `Aqua.AgentConfig`'s two in-process agent reads alone — the first-need
    # hook: a turn reads its estate's tree in-process now rather than
    # through the `aqua` tool, and the bundle a group estate is filled
    # with on first read has to be there before the turn roots an
    # authority in it. The tool keeps the same hook for readers outside
    # the harness.
    # `Sanctum.JCS` is the canonical form a card's proposal is digested in
    # (`Aqua.Loop.Policy.proposal_digest/1`) — the same canon the consent
    # digests use, so a decision consumes exactly what was shown.
    # `Sanctum.Limits` is the loop's deadline: the timeout the authority's
    # consented node limits carry, parsed once per turn.
    "aqua" => ~w(
      Sanctum.Authority Sanctum.ComponentRef Sanctum.Context Sanctum.JCS
      Sanctum.Limits Sanctum.Notify Sanctum.Provisioning Sanctum.Sanitizer Sanctum.Tenancy
    ),
    # `Sanctum.Provisioning` is `Compendium.MCP.AquaTool` and
    # `ComponentTool`'s list action alone — the first-need hook. A group
    # estate is now minted as a bare row and filled the first time
    # something reads its bundle, because clicking a person's name to open
    # a DM must not wait on a registry round trip that can fail. These two
    # tools ARE the bundle's readers, so the hook lives where the read is
    # rather than in every caller that might trigger one.
    # `Sanctum.Limits` is here for `Compendium.Manifest.Caps` alone: a
    # manifest's `limits` block is that module's vocabulary, and the caps
    # reader matches the keys against its closed field list rather than
    # trusting `String.to_existing_atom/1` to find atoms some other module
    # happened to load first.
    "compendium" => ~w(
      Sanctum.Cipher Sanctum.CipherAAD Sanctum.ComponentRef Sanctum.Consent
      Sanctum.Context Sanctum.JCS Sanctum.Limits Sanctum.Namespace
      Sanctum.Provisioning Sanctum.Sanitizer Sanctum.SignIn Sanctum.ToolPattern
      Sanctum.VaultReader
    ),
    # Cyfr.Release uses Sanctum.Cipher for key rotation. Cyfr.Ops uses
    # consent classes, chain authority, authorization rendering, and
    # the Sanctum.Catalog port. Cyfr.Models.Windows parses a catalyst
    # reference to read its exact name (Sanctum.ComponentRef).
    "cyfr" => ~w(
      Sanctum.Atoms Sanctum.Auth Sanctum.Authority Sanctum.Catalog Sanctum.Cidr
      Sanctum.Cipher Sanctum.ComponentRef Sanctum.Consent Sanctum.Context
      Sanctum.Door Sanctum.Notify
      Sanctum.OAuth
      Sanctum.Provisioning Sanctum.ProvisioningRegistry Sanctum.ProvisioningSupervisor
      Sanctum.PubSub
      Sanctum.Sanitizer Sanctum.Session Sanctum.Tenancy Sanctum.ToolServerDigest
      Sanctum.Unauthorized Sanctum.UnauthorizedError
    ),
    # Aqua.Notes resolves personal notes through users.personal_athanor_id.
    "emissary" => ~w(
      Sanctum.ComponentRef Sanctum.Context Sanctum.Sanitizer Sanctum.ToolPattern
      Sanctum.ToolServerDigest Sanctum.Unauthorized Sanctum.VaultReader
    ),
    "emissary_web" => ~w(
      Sanctum.ApiKey Sanctum.Auth Sanctum.BearerToken Sanctum.Caller
      Sanctum.ClientIp Sanctum.Context Sanctum.Door Sanctum.Limits
      Sanctum.Sanitizer Sanctum.Session Sanctum.SignIn
      Sanctum.Tenancy Sanctum.TinctureAccess Sanctum.TinctureAuth
      Sanctum.Unauthorized Sanctum.UnauthorizedError Sanctum.Vault
      Sanctum.Webhook
    ),
    "prism" => ~w(
      Sanctum.Context Sanctum.Notify Sanctum.Sanitizer Sanctum.Tenancy
    ),
    # `Sanctum.ClientIp` is `PrismWeb.AuthHelpers.socket_client_ip/1` alone,
    # and it is here for the same reason `emissary_web` has it: the console
    # is an ingress that must resolve its caller's address. The `/live`
    # socket is handled by the endpoint BEFORE the router, so it passes no
    # rate-limit plug — which makes the console, not a plug, the only
    # per-address bound on the anonymous device flows it starts
    # (`LoginLive`, `RegistryLive`). Assembling `connect_info` is a web
    # concern; the hop rules stay in the auth domain, spelled once.
    "prism_web" => ~w(
      Sanctum.ApiKey Sanctum.Auth Sanctum.Caller Sanctum.ClientIp
      Sanctum.ComponentRef Sanctum.Consent Sanctum.Context Sanctum.Door
      Sanctum.Notify Sanctum.Session Sanctum.SignIn Sanctum.Tenancy
      Sanctum.TinctureAuth Sanctum.Webhook
    )
  }

  @namespace ~r/\bSanctum(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached(ns) do
    for path <- Path.wildcard(Path.join(root(), "apps/cyfr/lib/#{ns}/**/*.ex")),
        line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  for {ns, surface} <- @surfaces do
    test "lib/#{ns} reaches only into the Sanctum namespaces its surface names" do
      extra =
        reached(unquote(ns))
        |> MapSet.difference(MapSet.new(unquote(surface)))
        |> Enum.sort()

      assert extra == [],
             """
             lib/#{unquote(ns)} reaches into Sanctum namespaces its surface does not name:

             #{Enum.map_join(extra, "\n", &"  #{&1}")}

             This crossing spans the license boundary (Apache-2.0 calling the
             FSL auth domain), so it widens only by decision: add the
             namespace with a line saying why, or move the shared piece to
             the glue namespace (`Cyfr.`).
             """
    end

    test "lib/#{ns}'s surface names nothing it has stopped reaching into" do
      stale =
        MapSet.new(unquote(surface))
        |> MapSet.difference(reached(unquote(ns)))
        |> Enum.sort()

      assert stale == [],
             """
             lib/#{unquote(ns)}'s surface names Sanctum namespaces it no longer reaches:

             #{Enum.map_join(stale, "\n", &"  #{&1}")}

             Remove them — a stale roster is how the real surface stops being
             readable here.
             """
    end
  end

  # Restrict Compendium's sensitive Sanctum calls to credential encryption
  # and the listed consent readers. Consent write operations are excluded.
  @compendium_consent_allowed ~w(
    Sanctum.Consent.ShapeDerivation
    Sanctum.Consent.Source
  )

  test "lib/compendium touches only the allowed Sanctum.Consent submodules" do
    deep =
      for path <- Path.wildcard(Path.join(root(), "apps/cyfr/lib/compendium/**/*.ex")),
          line <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.lines(),
          [module] <- Regex.scan(~r/\bSanctum\.Consent\.[A-Z]\w+/, line, capture: :first),
          into: MapSet.new(),
          do: module

    extra = deep |> MapSet.difference(MapSet.new(@compendium_consent_allowed)) |> Enum.sort()

    assert extra == [],
           """
           lib/compendium reaches Sanctum.Consent submodules outside its allowlist:

           #{Enum.map_join(extra, "\n", &"  #{&1}")}

           The consent write plane stays behind Sanctum's own surface.
           """
  end
end
