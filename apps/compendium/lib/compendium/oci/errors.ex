defmodule Compendium.OCI.Errors do
  @moduledoc """
  Structured error types for OCI Distribution operations.
  """

  @type error_reason ::
          :unauthorized
          | :not_found
          | :manifest_invalid
          | :blob_upload_failed
          | :registry_unavailable
          | :digest_mismatch
          | :rate_limited
          | :unsupported_media_type

  @type t :: %__MODULE__{
          reason: error_reason(),
          message: String.t(),
          registry: String.t() | nil,
          status: integer() | nil,
          detail: term()
        }

  defstruct [:reason, :message, :registry, :status, :detail]

  @doc "Build an error from an HTTP response status and body."
  @spec from_response(integer(), binary(), String.t()) :: t()
  def from_response(401, body, registry) do
    %__MODULE__{
      reason: :unauthorized,
      message: "Authentication required for #{registry}",
      registry: registry,
      status: 401,
      detail: parse_errors(body)
    }
  end

  def from_response(403, body, registry) do
    %__MODULE__{
      reason: :unauthorized,
      message: "Access denied for #{registry}",
      registry: registry,
      status: 403,
      detail: parse_errors(body)
    }
  end

  def from_response(404, _body, registry) do
    %__MODULE__{
      reason: :not_found,
      message: "Resource not found on #{registry}",
      registry: registry,
      status: 404,
      detail: nil
    }
  end

  def from_response(429, body, registry) do
    %__MODULE__{
      reason: :rate_limited,
      message: "Rate limited by #{registry}",
      registry: registry,
      status: 429,
      detail: parse_errors(body)
    }
  end

  def from_response(status, body, registry) when status >= 500 do
    %__MODULE__{
      reason: :registry_unavailable,
      message: "Registry #{registry} returned server error #{status}",
      registry: registry,
      status: status,
      detail: parse_errors(body)
    }
  end

  def from_response(status, body, registry) do
    %__MODULE__{
      reason: :manifest_invalid,
      message: "Unexpected response #{status} from #{registry}",
      registry: registry,
      status: status,
      detail: parse_errors(body)
    }
  end

  @doc "Build an error for a connection failure."
  @spec connection_error(String.t(), term()) :: t()
  def connection_error(registry, reason) do
    %__MODULE__{
      reason: :registry_unavailable,
      message: "Failed to connect to #{registry}: #{inspect(reason)}",
      registry: registry,
      status: nil,
      detail: reason
    }
  end

  @doc "Build a digest mismatch error."
  @spec digest_mismatch(String.t(), String.t()) :: t()
  def digest_mismatch(expected, actual) do
    %__MODULE__{
      reason: :digest_mismatch,
      message: "Digest mismatch: expected #{expected}, got #{actual}",
      registry: nil,
      status: nil,
      detail: %{expected: expected, actual: actual}
    }
  end

  @doc "Format error for display."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{message: message}), do: message

  defp parse_errors(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"errors" => errors}} -> errors
      _ -> body
    end
  end

  defp parse_errors(other), do: other
end
