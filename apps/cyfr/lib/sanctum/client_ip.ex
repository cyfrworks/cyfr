# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ClientIp do
  @moduledoc """
  Single source of truth for resolving the client IP from a `Plug.Conn`,
  applying the X-Forwarded-For trust boundary.

  X-Forwarded-For is honored ONLY when `config :cyfr,
  :trust_x_forwarded_for` is true (set when the deployment is behind a trusted
  reverse proxy). Unconditional XFF trust would let any client spoof an
  API-key IP allowlist; ignoring XFF behind a proxy would make every allowlist
  check see the proxy IP. Both failure modes are closed here, once, for every
  caller (the MCP session plug, the tincture auth resolver, and the tincture
  rate-limit bucket) so the trust decision cannot drift between entry points.

  `resolve/1` ALWAYS returns a binary — never `nil`. A context with no
  resolvable IP yields `"0.0.0.0"`, which fails a real API-key allowlist
  *closed* (it won't match a configured CIDR). Returning `nil` instead would
  silently *disable* the allowlist (`Sanctum.ApiKey.validate/2` skips the
  check when `client_ip` is nil) — the bug this module exists to prevent.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(%Plug.Conn{} = conn) do
    if trust_forwarded_header?() do
      case extract_forwarded_ip(conn) do
        {:ok, ip} -> ip
        :error -> extract_remote_ip(conn)
      end
    else
      extract_remote_ip(conn)
    end
  end

  defp trust_forwarded_header? do
    Application.get_env(:cyfr, :trust_x_forwarded_for, false)
  end

  # First hop of X-Forwarded-For, validated as a real IP literal.
  defp extract_forwarded_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] when forwarded != "" ->
        ip = forwarded |> String.split(",") |> List.first() |> String.trim()
        if valid_ip_string?(ip), do: {:ok, ip}, else: :error

      _ ->
        :error
    end
  end

  # conn.remote_ip tuple → string; "0.0.0.0" (fail-closed) on anything else.
  defp extract_remote_ip(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) ->
        case :inet.ntoa(ip) do
          charlist when is_list(charlist) -> to_string(charlist)
          _ -> "0.0.0.0"
        end

      _ ->
        "0.0.0.0"
    end
  end

  defp valid_ip_string?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
