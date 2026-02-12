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

      iex> Emissary.MCP.Message.encode_result(1, %{tools: []})
      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{tools: []}}

  """

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

  # Standard JSON-RPC 2.0 error codes
  @error_codes %{
    parse_error: -32700,
    invalid_request: -32600,
    method_not_found: -32601,
    invalid_params: -32602,
    internal_error: -32603
  }

  # CYFR-specific error codes (PRD §4.5)
  # Transport errors: -33300 to -33399
  @cyfr_transport_codes %{
    session_required: -33301,
    session_expired: -33302,
    invalid_protocol: -33303
  }

  # Authentication errors: -33000 to -33099
  @cyfr_auth_codes %{
    auth_required: -33001,
    auth_invalid: -33002,
    auth_expired: -33003,
    insufficient_permissions: -33004,
    sudo_required: -33000
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

  Returns `{:ok, message}` for single messages or `{:ok, [messages]}` for batches.
  """
  def decode(messages) when is_list(messages) do
    results = Enum.map(messages, &decode_single/1)

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {successes, []} ->
        {:ok, Enum.map(successes, fn {:ok, msg} -> msg end)}

      {_, errors} ->
        # Return first error for now
        hd(errors)
    end
  end

  def decode(message) when is_map(message), do: decode_single(message)

  defp decode_single(%{"jsonrpc" => @jsonrpc_version} = msg) do
    cond do
      # Request: has method and id
      Map.has_key?(msg, "method") and Map.has_key?(msg, "id") ->
        {:ok,
         %__MODULE__{
           type: :request,
           id: msg["id"],
           method: msg["method"],
           params: msg["params"]
         }}

      # Notification: has method but no id
      Map.has_key?(msg, "method") ->
        {:ok,
         %__MODULE__{
           type: :notification,
           method: msg["method"],
           params: msg["params"]
         }}

      # Response: has result and id
      Map.has_key?(msg, "result") and Map.has_key?(msg, "id") ->
        {:ok,
         %__MODULE__{
           type: :response,
           id: msg["id"],
           result: msg["result"]
         }}

      # Error response: has error and id
      Map.has_key?(msg, "error") and Map.has_key?(msg, "id") ->
        {:ok,
         %__MODULE__{
           type: :error,
           id: msg["id"],
           error: msg["error"]
         }}

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
  """
  def encode_result(id, result) do
    %{
      "jsonrpc" => @jsonrpc_version,
      "id" => id,
      "result" => result
    }
  end

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
