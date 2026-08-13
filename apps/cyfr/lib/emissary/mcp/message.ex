# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Message do
  @moduledoc """
  JSON-RPC 2.0 message parsing and serialization for MCP.

  Handles encoding/decoding of:
  - Requests (method call with id)
  - Notifications (method call without id)
  - Responses (result or error)
  - Batches (array of any of the above)

  ## Examples

      iex> Emissary.MCP.Message.decode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      {:ok, %Emissary.MCP.Message{type: :request, id: 1, method: "tools/list", params: nil}}

      iex> encoded = Emissary.MCP.Message.encode_result(1, %{"tools" => []})
      iex> encoded["result"]["resultType"]
      "complete"

  """

  alias Emissary.MCP.Protocol

  @type message_type :: :request | :notification | :response | :error
  @type t :: %__MODULE__{
          type: message_type(),
          id: integer() | String.t() | nil,
          method: String.t() | nil,
          params: map() | nil,
          result: any() | nil,
          error: map() | nil
        }

  defstruct [:type, :id, :method, :params, :result, :error]

  @jsonrpc_version "2.0"

  # Standard JSON-RPC 2.0 error codes, plus the codes the MCP specification
  # reserves for itself in -32020..-32099. Those are protocol-defined, not
  # CYFR-defined, so they live here rather than with the -33xxx block.
  @error_codes %{
    parse_error: -32700,
    invalid_request: -32600,
    method_not_found: -32601,
    invalid_params: -32602,
    internal_error: -32603,
    resource_not_found: -32602,
    header_mismatch: -32020,
    missing_required_client_capability: -32021,
    unsupported_protocol_version: -32022
  }

  # CYFR-specific error codes.
  # Transport errors: -33300 to -33399
  @cyfr_transport_codes %{
    invalid_protocol: -33303,
    rate_limited: -33304,
    # Never reaches a client — by the time it is recorded the caller has already
    # closed the stream. It exists so the request log distinguishes "the caller
    # went away" from a genuine failure.
    request_cancelled: -33305
  }

  # Authentication errors: -33000 to -33099
  @cyfr_auth_codes %{
    auth_required: -33001,
    auth_invalid: -33002,
    auth_expired: -33003,
    insufficient_permissions: -33004
  }

  # Execution errors: -33100 to -33199
  @cyfr_execution_codes %{
    execution_failed: -33100,
    execution_timeout: -33101,
    capability_denied: -33102
  }

  # Registry/Compendium errors: -33200 to -33299
  @cyfr_registry_codes %{
    component_not_found: -33200,
    component_invalid: -33201,
    registry_unavailable: -33202
  }

  # Signature verification errors: -33400 to -33499
  @cyfr_signature_codes %{
    signature_invalid: -33400,
    signature_expired: -33401,
    signature_missing: -33402
  }

  # Combined CYFR error codes for lookup
  @cyfr_error_codes Map.merge(
                      @cyfr_transport_codes,
                      Map.merge(
                        @cyfr_auth_codes,
                        Map.merge(
                          @cyfr_execution_codes,
                          Map.merge(@cyfr_registry_codes, @cyfr_signature_codes)
                        )
                      )
                    )

  @doc """
  Decode a JSON-RPC message from a map (already parsed from JSON).

  One message, never a batch: "The body of the HTTP POST **MUST** be a single
  JSON-RPC *request* or *notification*." A batch arrives as a list and is
  refused at the transport, so nothing reaches here that this could not decode.
  """
  def decode(message) when is_map(message), do: decode_single(message)

  defp decode_single(%{"jsonrpc" => @jsonrpc_version} = msg) do
    cond do
      # Method must be a string if present
      Map.has_key?(msg, "method") and not is_binary(msg["method"]) ->
        {:error, :invalid_request, "Method must be a string"}

      # Request: has method and id (MCP: id MUST NOT be null)
      Map.has_key?(msg, "method") and Map.has_key?(msg, "id") ->
        if is_nil(msg["id"]) do
          {:error, :invalid_request, "Request ID must not be null"}
        else
          {:ok,
           %__MODULE__{
             type: :request,
             id: msg["id"],
             method: msg["method"],
             params: msg["params"]
           }}
        end

      # Notification: has method but no id
      Map.has_key?(msg, "method") ->
        {:ok,
         %__MODULE__{
           type: :notification,
           method: msg["method"],
           params: msg["params"]
         }}

      # Response: has result and id (MCP: id MUST NOT be null)
      Map.has_key?(msg, "result") and Map.has_key?(msg, "id") ->
        if is_nil(msg["id"]) do
          {:error, :invalid_request, "Response ID must not be null"}
        else
          {:ok,
           %__MODULE__{
             type: :response,
             id: msg["id"],
             result: msg["result"]
           }}
        end

      # Error response: has error and id (MCP: id MUST NOT be null)
      Map.has_key?(msg, "error") and Map.has_key?(msg, "id") ->
        if is_nil(msg["id"]) do
          {:error, :invalid_request, "Error response ID must not be null"}
        else
          {:ok,
           %__MODULE__{
             type: :error,
             id: msg["id"],
             error: msg["error"]
           }}
        end

      true ->
        {:error, :invalid_request, "Missing required fields"}
    end
  end

  defp decode_single(%{"jsonrpc" => version}) do
    {:error, :invalid_request, "Unsupported jsonrpc version: #{version}"}
  end

  defp decode_single(_) do
    {:error, :invalid_request, "Missing jsonrpc field"}
  end

  @doc """
  Encode a successful result response.

  Stamps the two things the specification requires of every result and that no
  individual handler should have to remember: `resultType`, which tells a client
  whether this is a finished answer or a request for more input, and the server's
  identity under `_meta`.

  Both are applied here rather than in `Emissary.MCP.Router` because the router
  is not the only producer — the discovery path in `EmissaryWeb.MCPController`
  encodes its own result — and a result that reaches the wire without a
  `resultType` is invalid to a conforming client.

  Any `_meta` a handler already built is preserved; the server identity is merged
  into it, never over it.
  """
  def encode_result(id, result, kind \\ :complete) do
    %{
      "jsonrpc" => @jsonrpc_version,
      "id" => id,
      "result" => stamp_result(result, kind)
    }
  end

  defp stamp_result(result, kind) when is_map(result) do
    meta =
      result
      |> Map.get("_meta", %{})
      |> Map.put(Protocol.meta_server_info_key(), Protocol.server_info())

    result
    |> Map.put("resultType", Protocol.result_type(kind))
    |> Map.put("_meta", meta)
  end

  # A non-map result cannot carry the required fields. No handler produces one;
  # passing it through unchanged beats corrupting it into a map that the caller
  # did not ask for.
  defp stamp_result(result, _kind), do: result

  @doc """
  Encode an error response.

  Accepts either an atom error code (from standard codes) or a numeric code.
  """
  def encode_error(id, code, message, data \\ nil)

  def encode_error(id, code, message, data) when is_atom(code) do
    numeric_code =
      Map.get(@error_codes, code) ||
        Map.get(@cyfr_error_codes, code) ||
        -32603

    encode_error(id, numeric_code, message, data)
  end

  def encode_error(id, code, message, data) when is_integer(code) do
    error =
      %{
        "code" => code,
        "message" => message
      }
      |> maybe_add_data(data)

    %{
      "jsonrpc" => @jsonrpc_version,
      "id" => id,
      "error" => error
    }
  end

  defp maybe_add_data(error, nil), do: error
  defp maybe_add_data(error, data), do: Map.put(error, "data", data)

  @doc """
  Encode a notification (no id, no response expected).
  """
  def encode_notification(method, params \\ nil) do
    %{
      "jsonrpc" => @jsonrpc_version,
      "method" => method
    }
    |> maybe_add_params(params)
  end

  defp maybe_add_params(msg, nil), do: msg
  defp maybe_add_params(msg, params), do: Map.put(msg, "params", params)

  @doc """
  Get the numeric error code for an atom.

  Supports both standard JSON-RPC 2.0 codes and CYFR-specific codes.
  """
  def error_code(atom) when is_atom(atom) do
    Map.get(@error_codes, atom) ||
      Map.get(@cyfr_error_codes, atom) ||
      -32603
  end

  @doc """
  Get the CYFR transport error code for session-related errors.
  """
  def cyfr_code(atom) when is_atom(atom) do
    Map.get(@cyfr_error_codes, atom)
  end

  @doc """
  Check if a code is a CYFR-specific error code.
  """
  def cyfr_error?(code) when is_integer(code) do
    code <= -33000 and code >= -33499
  end

  def cyfr_error?(_), do: false
end
