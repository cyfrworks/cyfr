# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.MCPError do
  @moduledoc """
  Sends a JSON-RPC error response from the MCP ingress plugs and controllers.

  Formats the MCP pipeline's rejections as JSON-RPC errors and echoes a
  valid request id so clients can correlate failures.

  The id is recovered from the parsed body. `/mcp`'s pipeline parses the
  body only after the transport's rate limit and authentication
  (`Emissary.Router`), so a refusal sent before the read — a throttled
  request, a credential refused, a body over its cap or of a media type
  refused — carries a null id: the body is never read to recover one. The
  id is genuinely absent for a GET (no body) and for a batch too, and
  `nil` is correct in those cases, as JSON-RPC allows for an id that
  cannot be determined.

  A rejection rendered here is the request's refused decision, recorded
  once (`CyfrWeb.Plugs.CallIdentity.refused/2`) when the pipeline
  minted a call id and nothing recorded it before.
  """

  @behaviour CyfrWeb.ErrorRenderer

  import Plug.Conn

  alias Prima.MCP.Message

  @protocol_version Prima.MCP.Protocol.version()
  @protocol_version_header Prima.MCP.Protocol.protocol_version_header()

  @doc """
  Render a JSON-RPC error, echoing the request id when the body carried one.

  `code` is a numeric code, a code name from `Prima.MCP.Message`'s
  tables, or a refusal — a `%Prima.Refusal{}` or a reason term — answered
  with its class's code (`Prima.MCP.Message.refusal_code/3`).
  """
  @impl true
  def send(%Plug.Conn{} = conn, status, code, message) do
    conn = CyfrWeb.Plugs.CallIdentity.refused(conn, code)
    {code, message} = wire(code, message)

    conn
    # Declared here rather than at each call site: every rejection from the
    # MCP endpoint carries it, whichever caller renders it.
    |> put_resp_header(@protocol_version_header, @protocol_version)
    |> challenge(status)
    |> put_status(status)
    |> Phoenix.Controller.json(Message.encode_error(request_id(conn), code, message))
  end

  defp wire(code, message) when is_integer(code), do: {code, message}

  defp wire(code, message) do
    if Message.code?(code) do
      {code, message}
    else
      refusal = Sanctum.Refusals.classify(code)
      code = Message.refusal_code(refusal, :transport, Sanctum.Refusals.code_override(refusal))
      {code, message || refusal.message}
    end
  end

  # HTTP 401 requires a WWW-Authenticate challenge (RFC 9110).
  # Advertise Bearer for API keys and Sanctum session tokens.
  defp challenge(conn, 401), do: Plug.Conn.put_resp_header(conn, "www-authenticate", "Bearer")
  defp challenge(conn, _status), do: conn

  @doc """
  Render a JSON-RPC error and halt the pipeline. The plug form of `send/4`.
  """
  @impl true
  def halt(%Plug.Conn{} = conn, status, code, message) do
    conn
    |> __MODULE__.send(status, code, message)
    |> Plug.Conn.halt()
  end

  # The JSON-RPC `id` of the request being rejected, or `nil` when there
  # is none: a batch (`%{"_json" => [...]}`) has no single id, and an
  # unfetched or non-map body yields none either.
  defp request_id(%Plug.Conn{body_params: %{"id" => id}}) when is_binary(id) or is_integer(id),
    do: id

  defp request_id(_conn), do: nil
end
