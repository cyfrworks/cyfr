# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ApiError do
  @moduledoc """
  Renders a rejection from a plain HTTP endpoint — one that is not speaking
  JSON-RPC.

  One of the two `EmissaryWeb.ErrorRenderer` implementations; the other is
  `EmissaryWeb.MCPError`, which answers in JSON-RPC.
  """

  @behaviour EmissaryWeb.ErrorRenderer

  import Plug.Conn

  @doc """
  Render an error body and set the status.

  `code` is the same atom the JSON-RPC renderer would map to a numeric code. It
  is emitted as a stable string so a client has something to branch on that is
  not the prose.
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, code, message) do
    conn
    |> challenge(status)
    |> put_status(status)
    |> Phoenix.Controller.json(%{"error" => message, "code" => to_string(code)})
  end

  @doc """
  Render an error and halt the pipeline. The plug form of `send/4`.
  """
  @impl true
  def halt(%Plug.Conn{} = conn, status, code, message) do
    conn
    |> __MODULE__.send(status, code, message)
    |> Plug.Conn.halt()
  end

  # RFC 9110 §15.5.2: a 401 MUST carry at least one challenge.
  defp challenge(conn, 401), do: put_resp_header(conn, "www-authenticate", "Bearer")
  defp challenge(conn, _status), do: conn
end
