# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TailscaleIdentityHeaderSeamTest do
  @moduledoc """
  Tailscale's identity headers confer nothing. Tailscale Serve sets
  `Tailscale-User-Login`, `Tailscale-User-Name` and the rest of its
  `Tailscale-*` headers on what it forwards to the proxy listener, after
  deleting any copy the client sent; but a request that reaches the proxy
  listener some other way, or the loopback listener, carries whatever its
  client wrote, and a header is never the boundary (`CyfrWeb.Ingress`).
  So no code of the product reads one: a person is who their session,
  key or device proves, and a request's authority is exactly what it has
  without the header.

  The seam is a scan of every application's code for the headers' names,
  in any case, and fails naming the line of any it finds; a planted reader
  shows it finding one.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # A Tailscale header's name, as a reader would spell it.
  @header ~r/tailscale-[a-z]/i

  defp hits(files) do
    for {rel, text} <- files,
        {line, n} <- text |> String.split("\n") |> Enum.with_index(1),
        line =~ @header,
        do: "#{rel}:#{n}: #{String.trim(line)}"
  end

  defp app_code do
    for path <- Prima.Test.SourceTree.files!(Path.join(@root, "apps/*/lib/**/*.{ex,exs}")),
        do: {Path.relative_to(path, @root), File.read!(path)}
  end

  test "no application's code names a Tailscale identity header" do
    code = app_code()
    assert length(code) > 500, "the scan read only #{length(code)} files"

    assert hits(code) == [],
           """
           Code under apps/*/lib names a Tailscale identity header, which confers
           nothing here:

           #{Enum.join(hits(code), "\n")}
           """
  end

  test "a planted reader of a Tailscale header, in any case, is found by its line" do
    planted = [
      {"apps/cyfr/lib/cyfr_web/plugs/planted.ex",
       """
       defmodule CyfrWeb.Plugs.Planted do
         def login(conn), do: Plug.Conn.get_req_header(conn, "tailscale-user-login")
         def name(conn), do: Plug.Conn.get_req_header(conn, "Tailscale-User-Name")
       end
       """},
      {"apps/sanctum/lib/sanctum/planted.ex", ~s|@identity "TAILSCALE-USER-PROFILE-PIC"\n|}
    ]

    assert hits(planted) == [
             ~s|apps/cyfr/lib/cyfr_web/plugs/planted.ex:2: def login(conn), do: | <>
               ~s|Plug.Conn.get_req_header(conn, "tailscale-user-login")|,
             ~s|apps/cyfr/lib/cyfr_web/plugs/planted.ex:3: def name(conn), do: | <>
               ~s|Plug.Conn.get_req_header(conn, "Tailscale-User-Name")|,
             ~s|apps/sanctum/lib/sanctum/planted.ex:1: @identity "TAILSCALE-USER-PROFILE-PIC"|
           ]

    # Tailscale named otherwise is no header.
    assert hits([{"apps/cyfr/lib/planted.ex", "# Tailscale Serve forwards here\n"}]) == []
  end
end
