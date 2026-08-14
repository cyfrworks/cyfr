# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.MCPRequestMetadata do
  @moduledoc """
  The request metadata every MCP request carries, and the rules it must satisfy.

  "Request Metadata" is the specification's own name for this. With no
  handshake, each request declares its protocol version and client capabilities
  in `params._meta` and mirrors the routed fields into `Mcp-Method` /
  `Mcp-Name`. Header and body must agree — a header a gateway can route on is
  only safe if it cannot disagree with what the server will execute.

  This is the protocol's whole per-request contract, not a check bolted on
  beside it: there is nowhere else the version, the declared capabilities or the
  mirrored headers are established. It is a plug because two of the three are
  HTTP headers, and because a violation must answer `400` before any handler
  runs.

  It sits after `EmissaryWeb.Plugs.Authenticate`, which carries no protocol
  knowledge and also serves routes that do not speak MCP. Keeping the two apart
  is what stops a non-JSON-RPC endpoint from inheriting these rules along with
  its credential handling.
  """

  import Plug.Conn

  alias Emissary.MCP.Protocol

  def init(opts), do: opts

  def call(conn, _opts) do
    body = conn.body_params

    cond do
      not (is_map(body) and not is_struct(body)) ->
        conn

      is_nil(body["id"]) ->
        # A notification, not a request. This revision defines no header
        # requirement for them, and a notification carries no id to answer an
        # error on.
        conn

      true ->
        with %Plug.Conn{halted: false} = conn <- check_declared_version(conn, body),
             %Plug.Conn{halted: false} = conn <- check_client_capabilities(conn, body),
             %Plug.Conn{halted: false} = conn <- check_mirrored_headers(conn, body) do
          conn
        end
    end
  end

  # `clientCapabilities` is a required `_meta` field, and a missing required
  # field is `-32602`.
  #
  # It is not decoration. A stateless protocol has no handshake in which to learn
  # what the caller can do, so the server may never assume a capability the
  # request did not declare — which is what makes it safe to *offer* a client
  # something like an elicitation. Accepting requests that omit it would leave
  # the server guessing, and guessing wrong means asking a client for input it
  # has no way to supply.
  defp check_client_capabilities(conn, body) do
    case get_in(body, ["params", "_meta", Protocol.meta_client_capabilities_key()]) do
      caps when is_map(caps) ->
        assign(conn, :mcp_client_capabilities, caps)

      nil ->
        reject(
          conn,
          :invalid_params,
          "Missing required #{Protocol.meta_client_capabilities_key()} in params._meta."
        )

      _other ->
        reject(
          conn,
          :invalid_params,
          "#{Protocol.meta_client_capabilities_key()} must be an object."
        )
    end
  end

  # `Mcp-Method` and `Mcp-Name` mirror body fields into headers so an
  # intermediary can route and authorize without parsing the body. They are only
  # safe to route on if they cannot disagree with the body, so a mismatch is
  # refused here the same way a version mismatch is.
  defp check_mirrored_headers(conn, body) do
    with :ok <- match_header(conn, Protocol.method_header(), body["method"], "Mcp-Method"),
         :ok <-
           match_header(conn, Protocol.name_header(), Protocol.named_subject(body), "Mcp-Name") do
      conn
    else
      {:error, message} -> reject(conn, :header_mismatch, message)
    end
  end

  # A method that names no subject sends no `Mcp-Name`, and must not be
  # required to.
  defp match_header(_conn, _header, nil, _label), do: :ok

  defp match_header(conn, header, expected, label) do
    case get_req_header(conn, header) do
      [] ->
        {:error, "Missing required #{label} header."}

      [raw | _] ->
        case Protocol.decode_header_value(raw) do
          {:ok, ^expected} -> :ok
          {:ok, other} -> {:error, "#{label} header (#{other}) does not match the request body."}
          :error -> {:error, "#{label} header is not valid Base64 sentinel encoding."}
        end
    end
  end

  # Every POST declares its protocol version twice: in `params._meta` and in the
  # `MCP-Protocol-Version` header. Both are required, and they must agree.
  #
  # The duplication is deliberate — a gateway can route and rate-limit on the
  # header without parsing the body, but only if the header cannot disagree with
  # what the server will actually execute. So a mismatch is refused outright
  # rather than resolved in favour of either side.
  defp check_declared_version(conn, body) do
    header = get_req_header(conn, Protocol.protocol_version_header()) |> List.first()
    meta = Protocol.declared_version(body)

    cond do
      is_nil(header) ->
        reject(conn, :header_mismatch, "Missing required MCP-Protocol-Version header.")

      is_nil(meta) ->
        reject(
          conn,
          :header_mismatch,
          "Missing required #{Protocol.meta_protocol_version_key()} in params._meta."
        )

      header != meta ->
        reject(
          conn,
          :header_mismatch,
          "MCP-Protocol-Version header (#{header}) does not match " <>
            "#{Protocol.meta_protocol_version_key()} (#{meta})."
        )

      not Protocol.supported?(header) ->
        reject(
          conn,
          :unsupported_protocol_version,
          "Unsupported protocol version #{header}. Supported: " <>
            Enum.join(Protocol.supported(), ", ") <> "."
        )

      true ->
        conn
    end
  end

  defp reject(conn, code, message), do: EmissaryWeb.MCPError.halt(conn, 400, code, message)
end
