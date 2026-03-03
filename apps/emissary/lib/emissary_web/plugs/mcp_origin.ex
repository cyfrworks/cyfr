defmodule EmissaryWeb.Plugs.MCPOrigin do
  @moduledoc """
  Plug for MCP Origin header validation per MCP 2025-11-25 spec.

  If the Origin header is present, validates it against a configurable allowlist.
  If invalid, responds with 403 Forbidden.
  If absent, passes through (spec only requires validation when present).

  ## Configuration

      config :emissary, :mcp_allowed_origins, ["http://localhost", "https://localhost"]

  Supports wildcard port matching for localhost origins.
  """

  import Plug.Conn
  require Logger

  alias Emissary.MCP.Message

  @protocol_version "2025-11-25"

  @default_allowed_origins [
    "http://localhost",
    "https://localhost",
    "http://127.0.0.1",
    "https://127.0.0.1",
    "http://[::1]",
    "https://[::1]"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [origin | _] ->
        if valid_origin?(origin) do
          conn
        else
          Logger.warning("[MCP Origin] Rejected origin: #{origin}")

          conn
          |> put_resp_header("mcp-protocol-version", @protocol_version)
          |> put_status(403)
          |> Phoenix.Controller.json(%{
            "jsonrpc" => "2.0",
            "error" => %{
              "code" => Message.cyfr_code(:insufficient_permissions),
              "message" => "Origin not allowed: #{origin}"
            },
            "id" => nil
          })
          |> halt()
        end

      [] ->
        conn
    end
  end

  defp valid_origin?(origin) do
    allowed = Application.get_env(:emissary, :mcp_allowed_origins, @default_allowed_origins)

    Enum.any?(allowed, fn allowed_origin ->
      origin_matches?(origin, allowed_origin)
    end)
  end

  # Exact match or localhost with any port
  defp origin_matches?(origin, allowed) do
    origin == allowed or
      (localhost_origin?(allowed) and localhost_with_port?(origin, allowed))
  end

  defp localhost_origin?(origin) do
    String.contains?(origin, "localhost") or
      String.contains?(origin, "127.0.0.1") or
      String.contains?(origin, "[::1]")
  end

  defp localhost_with_port?(origin, base) do
    String.starts_with?(origin, base <> ":")
  end
end
