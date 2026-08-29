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
    "aqua" => ~w(
      Sanctum.ComponentRef Sanctum.Context Sanctum.Notify Sanctum.Sanitizer
      Sanctum.Tenancy
    ),
    "compendium" => ~w(
      Sanctum.Cipher Sanctum.CipherAAD Sanctum.ComponentRef Sanctum.Consent
      Sanctum.Context Sanctum.JCS Sanctum.Namespace Sanctum.Sanitizer
      Sanctum.SignIn Sanctum.ToolPattern Sanctum.VaultReader
    ),
    "cyfr" => ~w(
      Sanctum.Auth Sanctum.Authority Sanctum.Cidr Sanctum.Consent
      Sanctum.Context Sanctum.Door Sanctum.Notify Sanctum.OAuth
      Sanctum.Provisioning Sanctum.ProvisioningSupervisor Sanctum.PubSub
      Sanctum.Sanitizer Sanctum.Session Sanctum.Tenancy
    ),
    "emissary" => ~w(
      Sanctum.Atoms Sanctum.Authority Sanctum.ComponentRef Sanctum.Consent
      Sanctum.Context Sanctum.Sanitizer Sanctum.ToolPattern
      Sanctum.ToolServerDigest Sanctum.Unauthorized Sanctum.UnauthorizedError
      Sanctum.VaultReader
    ),
    "emissary_web" => ~w(
      Sanctum.ApiKey Sanctum.Auth Sanctum.BearerToken Sanctum.Caller
      Sanctum.ClientIp Sanctum.Context Sanctum.Door Sanctum.Limits
      Sanctum.Namespace Sanctum.Sanitizer Sanctum.Session Sanctum.SignIn
      Sanctum.Tenancy Sanctum.TinctureAccess Sanctum.TinctureAuth
      Sanctum.Unauthorized Sanctum.UnauthorizedError Sanctum.Vault
      Sanctum.Webhook
    ),
    "prism" => ~w(
      Sanctum.Context Sanctum.Notify Sanctum.Sanitizer Sanctum.Tenancy
    ),
    "prism_web" => ~w(
      Sanctum.ApiKey Sanctum.Auth Sanctum.Caller Sanctum.ComponentRef
      Sanctum.Consent Sanctum.Context Sanctum.Door Sanctum.Notify
      Sanctum.Session Sanctum.SignIn Sanctum.Tenancy Sanctum.TinctureAuth
      Sanctum.Webhook
    )
  }

  @namespace ~r/\bSanctum(?:\.[A-Z]\w+)+\b/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp reached(ns) do
    for path <- Path.wildcard(Path.join(root(), "apps/cyfr/lib/#{ns}/**/*.ex")),
        line <- path |> File.read!() |> code_lines(),
        [module] <- Regex.scan(@namespace, line, capture: :first),
        into: MapSet.new(),
        do: module |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  # Code only — heredoc prose, # comments, AND one-line @doc strings are
  # about the dependency, not the dependency (a `@doc "pinned by
  # Sanctum.VaultTest"` is not a reach).
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {kept, in_heredoc?} ->
      delimiters = line |> String.graphemes() |> Enum.chunk_every(3, 1, :discard)
      toggles = Enum.count(delimiters, &(&1 == ["\"", "\"", "\""]))
      now_inside? = if rem(toggles, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      keep? =
        not in_heredoc? and not now_inside? and
          not String.match?(line, ~r/^\s*#/) and
          not String.match?(line, ~r/^\s*@(module)?doc\s+"/)

      {if(keep?, do: [line | kept], else: kept), now_inside?}
    end)
    |> elem(0)
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
end
