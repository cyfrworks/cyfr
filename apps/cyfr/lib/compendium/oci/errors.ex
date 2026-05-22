# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.Errors do
  @moduledoc """
  Structured error types for OCI Distribution operations.
  """

  @type error_reason ::
          :unauthorized
          | :not_found
          | :conflict
          | :manifest_invalid
          | :blob_upload_failed
          | :registry_unavailable
          | :digest_mismatch
          | :rate_limited
          | :unsupported_media_type
          | :parse_error
          | :ssrf_blocked
          | :policy_acceptance_required
          | :policy_version_mismatch
          | :taken_down

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

  def from_response(409, body, registry) do
    message =
      case parse_errors(body) do
        [%{"message" => msg} | _] when is_binary(msg) -> msg
        _ -> "Resource conflict on #{registry}"
      end

    %__MODULE__{
      reason: :conflict,
      message: message,
      registry: registry,
      status: 409,
      detail: parse_errors(body)
    }
  end

  # 412 Precondition Failed comes back from POST /v1/legal/accept (when the
  # client posts a stale policy_version) and from the namespace-claim
  # handlers (when the identity hasn't accepted the current bundled
  # version). The body's `required_version` field is lifted into `detail`
  # so callers can route the user to the clickwrap UI for the right
  # version without re-parsing the JSON.
  def from_response(412, body, registry) do
    parsed = parse_errors(body)
    code = parsed |> List.first(%{}) |> Map.get("code", "")

    reason =
      case code do
        "POLICY_ACCEPTANCE_REQUIRED" -> :policy_acceptance_required
        "POLICY_VERSION_MISMATCH" -> :policy_version_mismatch
        _ -> :manifest_invalid
      end

    required_version =
      with {:ok, decoded} <- Jason.decode(body),
           ver when is_binary(ver) <- decoded["required_version"] do
        ver
      else
        _ -> nil
      end

    %__MODULE__{
      reason: reason,
      message: "Policy acceptance required on #{registry}",
      registry: registry,
      status: 412,
      detail: %{errors: parsed, required_version: required_version}
    }
  end

  # 410 Gone — cyfr.run signals taken-down components on REST detail handlers
  # and on OCI gateway `/v2/*` manifest pulls. The status code is authoritative;
  # `X-Cyfr-Component-Status: taken_down` is also present but not currently
  # captured (catch-all 4-arity from_response/4 not threaded yet).
  def from_response(410, body, registry) do
    %__MODULE__{
      reason: :taken_down,
      message: "Component taken down on #{registry}",
      registry: registry,
      status: 410,
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

  @doc "Build an error from a cyfr.run API response."
  @spec from_api_response(integer(), binary(), String.t()) :: t()
  def from_api_response(status, body, operation) do
    err = from_response(status, body, "cyfr.run")
    %{err | detail: %{operation: operation, original_detail: err.detail}}
  end

  @doc "Build a connection error for the cyfr.run API."
  @spec api_connection_error(term()) :: t()
  def api_connection_error(reason) do
    connection_error("cyfr.run", reason)
  end

  @doc "Build a parse error for unexpected response formats."
  @spec parse_error(String.t(), term()) :: t()
  def parse_error(operation, detail) do
    %__MODULE__{
      reason: :parse_error,
      message: "Unexpected response format from cyfr.run during #{operation}",
      registry: "cyfr.run",
      status: nil,
      detail: detail
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

  @doc "Format error for display — includes HTTP status and reason when present."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{message: message, status: nil, reason: nil}), do: message
  def to_string(%__MODULE__{message: message, status: nil}), do: message

  def to_string(%__MODULE__{message: message, status: status, reason: reason}) do
    suffix =
      [if(status, do: "HTTP #{status}"), if(reason, do: "#{reason}")]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    if suffix == "", do: message, else: "#{message} (#{suffix})"
  end

  @doc "Verbose format for Logger output — includes detail field."
  @spec to_log_string(t()) :: String.t()
  def to_log_string(%__MODULE__{detail: nil} = err), do: __MODULE__.to_string(err)

  def to_log_string(%__MODULE__{detail: detail} = err) do
    "#{__MODULE__.to_string(err)} — detail: #{inspect(detail)}"
  end

  @doc "Returns user-facing guidance based on error reason."
  @spec actionable_hint(t()) :: String.t()
  def actionable_hint(%__MODULE__{reason: :unauthorized}), do: "Run `cyfr login` to authenticate."

  def actionable_hint(%__MODULE__{reason: :registry_unavailable}),
    do: "Check your network connection and verify the registry is reachable."

  def actionable_hint(%__MODULE__{reason: :rate_limited}),
    do: "Wait and retry — the registry is rate-limiting requests."

  def actionable_hint(%__MODULE__{reason: :not_found}),
    do: "Verify the component reference is correct."

  def actionable_hint(%__MODULE__{reason: :digest_mismatch}),
    do: "Re-pull the component — the cached content may be corrupted."

  def actionable_hint(%__MODULE__{reason: :conflict}),
    do: "Publish with a new version number instead."

  def actionable_hint(%__MODULE__{reason: :parse_error}),
    do: "This may indicate a cyfr.run API version mismatch. Check for updates."

  def actionable_hint(%__MODULE__{reason: :ssrf_blocked}),
    do:
      "The registry returned a redirect to a blocked address. This may indicate a misconfigured or malicious registry."

  def actionable_hint(%__MODULE__{reason: :taken_down}),
    do:
      "Component was removed by cyfr.run moderators. If you believe this was in error, open an appeal from the prism Registry tab or run `cyfr registry appeals`."

  def actionable_hint(%__MODULE__{}), do: ""

  defp parse_errors(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"errors" => errors}} -> errors
      _ -> body
    end
  end

  defp parse_errors(other), do: other
end