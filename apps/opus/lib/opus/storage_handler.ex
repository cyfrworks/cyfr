defmodule Opus.StorageHandler do
  @moduledoc """
  Host function handler for Catalyst storage access.

  Provides the `cyfr:storage/files@0.1.0` WASI host function import that
  enables Catalyst components to perform file storage operations from within
  WASM execution.

  ## Security Model

  All storage operations are deny-by-default. A Catalyst's policy must have
  `allowed_storage_paths` configured — an empty list means **deny all**
  (consistent with `allowed_tools`). Use `["*"]` to allow all paths.

  Path safety is enforced at the host boundary:
  - Absolute paths are rejected
  - Path traversal (`..`) segments are rejected
  - Only paths matching `allowed_storage_paths` prefixes are permitted

  ## Architecture

  StorageHandler follows the same pattern as `Opus.HttpHandler`:

  1. Parse JSON request from WASM
  2. Validate path safety (no traversal, no absolute paths)
  3. Validate `allowed_storage_paths` policy (Sanctum)
  4. Dispatch to Arca storage functions
  5. Return JSON response to WASM

  All errors are caught and returned as JSON (never raised into WASM).

  ## Request Format (JSON string from WASM)

      {"action": "read", "path": "data/file.txt"}
      {"action": "write", "path": "data/file.txt", "content": "<base64>"}
      {"action": "list", "path": "data/"}
      {"action": "delete", "path": "data/file.txt"}
      {"action": "exists", "path": "data/file.txt"}

  ## Response Format (JSON string returned to WASM)

  On success (varies by action):

      {"status": "ok", "path": "...", "content": "<base64>", "size": 123, "encoding": "base64"}
      {"status": "ok", "path": "...", "written": true, "size": 123}
      {"status": "ok", "path": "...", "files": [...]}
      {"status": "ok", "path": "...", "deleted": true}
      {"status": "ok", "path": "...", "exists": true}

  On error:

      {"error": {"type": "storage_path_denied", "message": "..."}}

  ## Usage

      imports = Opus.StorageHandler.build_storage_imports(policy, ctx, "my-catalyst")
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  require Logger

  alias Sanctum.{Context, Policy}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:storage/files@0.1.0` host function.

  Returns a map suitable for merging into `Wasmex.Components.start_link` opts.
  When the component calls `cyfr:storage/files.call(json)`, the host function
  parses the request, validates against the policy, dispatches to Arca, and
  returns the JSON result.

  ## Parameters

  - `policy` - The `Sanctum.Policy` with `allowed_storage_paths` configured
  - `ctx` - The execution `Sanctum.Context`
  - `component_ref` - Component reference string for telemetry/audit

  ## Returns

  A map with the `"cyfr:storage/files@0.1.0"` namespace containing a `"call"` function.
  """
  @spec build_storage_imports(Policy.t(), Context.t(), String.t()) :: map()
  def build_storage_imports(%Policy{} = policy, %Context{} = ctx, component_ref) do
    %{
      "cyfr:storage/files@0.1.0" => %{
        "call" => {:fn, fn json_request ->
          execute(json_request, policy, ctx, component_ref)
        end}
      }
    }
  end

  @doc """
  Execute a storage operation from a catalyst.

  Parses the JSON request, validates path safety and policy, dispatches to
  the appropriate Arca function, and returns a JSON response string. All
  errors are caught and returned as JSON (never raised into WASM).
  """
  @spec execute(String.t(), Policy.t(), Context.t(), String.t()) :: String.t()
  def execute(json_request, %Policy{} = policy, %Context{} = ctx, component_ref) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case parse_request(json_request) do
        {:ok, %{action: action} = request} ->
          case validate_and_dispatch(request, policy, ctx) do
            {:ok, response} ->
              emit_telemetry(component_ref, action, :ok, start_time)
              encode_success(response)

            {:error, type, message} ->
              emit_telemetry(component_ref, action, :error, start_time)
              encode_error(type, message)
          end

        {:error, type, message} ->
          emit_telemetry(component_ref, "unknown", :error, start_time)
          encode_error(type, message)
      end

    result
  end

  # ============================================================================
  # Private: Request Parsing
  # ============================================================================

  defp parse_request(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"action" => action, "path" => path} = req} when is_binary(action) and is_binary(path) ->
        {:ok, %{action: action, path: path, content: req["content"]}}

      {:ok, %{"action" => action}} when is_binary(action) and action in ["list", "exists"] ->
        # list and exists can default to root
        {:ok, %{action: action, path: "", content: nil}}

      {:ok, %{"action" => action}} when is_binary(action) ->
        {:error, :invalid_request, "Request must include 'path' (string) for action '#{action}'"}

      {:ok, _} ->
        {:error, :invalid_request, "Request must include 'action' (string)"}

      {:error, _} ->
        {:error, :invalid_json, "Invalid JSON request"}
    end
  end

  # ============================================================================
  # Private: Validation & Dispatch
  # ============================================================================

  defp validate_and_dispatch(%{action: action, path: path} = request, policy, ctx) do
    with :ok <- validate_path_safe(path),
         :ok <- validate_allowed_storage_paths(policy, path) do
      dispatch(action, request, ctx)
    end
  end

  @doc """
  Reject path traversal attempts and absolute paths from WASM.

  Arca's normalize_path splits on "/" but does not reject ".." segments,
  so a path like "components/catalysts/agent/../../local/evil/0.1.0/catalyst.wasm"
  would escape the intended prefix. Block at the policy boundary.
  """
  @spec validate_path_safe(String.t()) :: :ok | {:error, atom(), String.t()}
  def validate_path_safe(path) do
    segments =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    cond do
      String.starts_with?(path, "/") ->
        {:error, :storage_path_denied, "Absolute paths are not allowed."}

      ".." in segments ->
        {:error, :storage_path_denied, "Path traversal ('..') is not allowed."}

      true ->
        :ok
    end
  end

  defp validate_allowed_storage_paths(policy, path) do
    # Normalize: check both "data" and "data/" since directory listings
    # use the bare name but policies use trailing slash prefixes
    path_with_slash = if String.ends_with?(path, "/"), do: path, else: path <> "/"

    if Policy.allows_storage_path?(policy, path) or
       Policy.allows_storage_path?(policy, path_with_slash) do
      :ok
    else
      {:error, :storage_path_denied, "Storage path '#{path}' is not allowed by policy."}
    end
  end

  # ============================================================================
  # Private: Action Dispatch
  # ============================================================================

  defp dispatch("read", %{path: path}, ctx) do
    segments = normalize_path(path)

    case Arca.get(ctx, segments) do
      {:ok, content} ->
        {:ok, %{
          "path" => path,
          "content" => Base.encode64(content),
          "size" => byte_size(content),
          "encoding" => "base64"
        }}

      {:error, :not_found} ->
        {:error, :not_found, "File not found: #{path}"}

      {:error, reason} ->
        {:error, :storage_error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp dispatch("write", %{path: path, content: nil}, _ctx) do
    {:error, :invalid_request, "Write action requires 'content' field with base64-encoded data. Path: #{path}"}
  end

  defp dispatch("write", %{path: path, content: b64_content}, ctx) do
    case Base.decode64(b64_content) do
      {:ok, content} ->
        segments = normalize_path(path)

        case Arca.put(ctx, segments, content) do
          :ok ->
            {:ok, %{
              "path" => path,
              "written" => true,
              "size" => byte_size(content)
            }}

          {:error, reason} ->
            {:error, :storage_error, "Failed to write file: #{inspect(reason)}"}
        end

      :error ->
        {:error, :invalid_base64, "Invalid base64 content. Content must be valid base64-encoded data."}
    end
  end

  defp dispatch("list", %{path: path}, ctx) do
    segments = normalize_path(path)

    case Arca.list(ctx, segments) do
      {:ok, files} ->
        {:ok, %{
          "path" => path,
          "files" => files
        }}

      {:error, reason} ->
        {:error, :storage_error, "Failed to list path: #{inspect(reason)}"}
    end
  end

  defp dispatch("delete", %{path: path}, ctx) do
    segments = normalize_path(path)

    case Arca.delete(ctx, segments) do
      :ok ->
        {:ok, %{
          "path" => path,
          "deleted" => true
        }}

      {:error, :not_found} ->
        {:error, :not_found, "File not found: #{path}"}

      {:error, reason} ->
        {:error, :storage_error, "Failed to delete file: #{inspect(reason)}"}
    end
  end

  defp dispatch("exists", %{path: path}, ctx) do
    segments = normalize_path(path)
    exists = Arca.exists?(ctx, segments)

    {:ok, %{
      "path" => path,
      "exists" => exists
    }}
  end

  defp dispatch(action, _request, _ctx) do
    {:error, :unknown_action, "Unknown storage action: #{action}. Use: read, write, list, delete, or exists"}
  end

  # ============================================================================
  # Private: Path Normalization
  # ============================================================================

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
  end

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp encode_success(result) do
    Jason.encode!(Map.put(result, "status", "ok"))
  end

  @doc false
  def encode_error(type, message) do
    Jason.encode!(%{
      "error" => %{
        "type" => to_string(type),
        "message" => to_string(message)
      }
    })
  end

  # ============================================================================
  # Private: Telemetry
  # ============================================================================

  defp emit_telemetry(component_ref, action, status, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    Opus.Telemetry.storage_call(component_ref, action, status, duration_ms)
  end
end
