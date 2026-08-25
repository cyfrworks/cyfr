# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StorageHandler do
  @moduledoc """
  Host function handler for Catalyst storage access.

  Provides the `cyfr:storage/files@0.1.0` WASI host function import that
  enables Catalyst components to perform file storage operations from within
  WASM execution.

  ## Security Model

  All storage operations are deny-by-default. A Catalyst's consent edge must
  carry `storage.paths` — an empty list (or a nil edge) means **deny all**.
  A grant entry ending in `/` allows everything under that prefix (so
  `["data/"]` or `["components/"]` allows a whole scope), `"*"` allows every
  path, and anything else must match exactly (`Opus.EdgeGuard.allows_path?/2`
  is the predicate).

  Path safety is enforced at the host boundary:
  - Paths must start with `data/` or `components/` (valid scopes)
  - Absolute paths are rejected
  - Path traversal (`..`) segments are rejected
  - Only paths matching the edge's `storage.paths` prefixes are permitted

  Size is enforced at the same boundary, from the node's limits: writes are
  bounded by `max_request_size` (measured on the decoded payload) and reads
  by `max_response_size` — the one host import without a ceiling would
  otherwise be the cheapest way to balloon host memory.

  ## Architecture

  StorageHandler follows the same pattern as `Opus.HttpHandler`:

  1. Parse JSON request from WASM
  2. Validate path safety (no traversal, no absolute paths)
  3. Validate the edge's `storage.actions` / `storage.paths` (EdgeGuard)
  4. Dispatch to Arca storage functions
  5. Return JSON response to WASM

  All errors are caught and returned as JSON (never raised into WASM).

  ## Request Format (JSON string from WASM)

      {"action": "read", "path": "data/file.txt"}
      {"action": "write", "path": "data/file.txt", "content": "<base64>"}
      {"action": "append", "path": "data/file.txt", "content": "<base64>"}
      {"action": "list", "path": "data/"}
      {"action": "delete", "path": "data/file.txt"}
      {"action": "exists", "path": "data/file.txt"}

  ## Response Format (JSON string returned to WASM)

  On success (varies by action):

      {"status": "ok", "path": "...", "content": "<base64>", "size": 123, "encoding": "base64"}
      {"status": "ok", "path": "...", "written": true, "size": 123}
      {"status": "ok", "path": "...", "appended": true, "size": 123}
      {"status": "ok", "path": "...", "files": [...]}
      {"status": "ok", "path": "...", "deleted": true}
      {"status": "ok", "path": "...", "exists": true}

  On error:

      {"error": {"type": "storage_path_denied", "message": "..."}}

  ## Usage

      imports = Opus.StorageHandler.build_storage_imports(edge, limits, ctx, "my-catalyst")
      # Merge with other imports and pass to Wasmex.Components.start_link
  """

  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.Limits
  alias Opus.EdgeGuard

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build Wasmex import map for the `cyfr:storage/files@0.1.0` host function.

  Returns a map suitable for merging into `Wasmex.Components.start_link` opts.
  When the component calls `cyfr:storage/files.call(json)`, the host function
  parses the request, validates against the consent edge, dispatches to Arca,
  and returns the JSON result.

  ## Parameters

  - `edge` - The `Sanctum.Authority.Blob.Edge` carrying `storage` grants
    (nil = deny all storage)
  - `ctx` - The execution `Sanctum.Context`
  - `component_ref` - Component reference string for telemetry/audit

  ## Returns

  A map with the `"cyfr:storage/files@0.1.0"` namespace containing a `"call"` function.
  """
  @spec build_storage_imports(
          Edge.t() | nil,
          Limits.t() | nil,
          Context.t(),
          String.t(),
          keyword()
        ) ::
          map()
  def build_storage_imports(edge, limits, %Context{} = ctx, component_ref, opts \\ []) do
    %{
      "cyfr:storage/files@0.1.0" => %{
        "call" =>
          {:fn,
           fn json_request ->
             execute(json_request, edge, limits, ctx, component_ref, opts)
           end}
      }
    }
  end

  @doc """
  Execute a storage operation from a catalyst.

  Parses the JSON request, validates path safety and the consent edge,
  dispatches to the appropriate Arca function, and returns a JSON response
  string. All errors are caught and returned as JSON (never raised into WASM).
  """
  @spec execute(String.t(), Edge.t() | nil, Limits.t() | nil, Context.t(), String.t(), keyword()) ::
          String.t()
  def execute(json_request, edge, limits, %Context{} = ctx, component_ref, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case parse_request(json_request) do
        {:ok, %{action: action} = request} ->
          case validate_and_dispatch(request, edge, limits, ctx, opts) do
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
      {:ok, %{"action" => action, "path" => path} = req}
      when is_binary(action) and is_binary(path) ->
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

  defp validate_and_dispatch(%{action: action, path: path} = request, edge, limits, ctx, opts) do
    with :ok <- validate_tenant(ctx),
         :ok <- validate_action_allowed(edge, action),
         :ok <- validate_path_scope(path),
         :ok <- validate_path_safe(path),
         :ok <- validate_allowed_paths(edge, path),
         :ok <- validate_write_size(action, request, limits),
         :ok <- validate_public_quota(action, request, ctx, opts),
         :ok <- validate_athanor_quota(action, request, ctx) do
      dispatch(action, request, limits, ctx)
    end
  end

  # Every guest path is tenant-relative, so a context without an athanor has
  # no storage at all — a typed refusal here, where Arca's fail-closed
  # tenant guard would raise.
  defp validate_tenant(%{athanor_id: id}) when is_binary(id) and id != "", do: :ok

  defp validate_tenant(_ctx),
    do: {:error, :storage_path_denied, "Storage requires an athanor-scoped context."}

  @writing_actions ~w(write append)

  # Storage is a host import like HTTP: the node's limits bound what crosses
  # the boundary. Writes are measured on the DECODED payload — the base64
  # framing is transport, not stored bytes.
  defp validate_write_size(action, %{content: content}, %Limits{} = limits)
       when action in @writing_actions and is_binary(content) do
    case Base.decode64(content) do
      {:ok, decoded} ->
        case EdgeGuard.check_request_size(limits, %{body: decoded}) do
          :ok -> :ok
          {:error, :request_too_large, message} -> {:error, :request_too_large, message}
        end

      :error ->
        # dispatch/4 answers invalid base64 with its own typed error.
        :ok
    end
  end

  defp validate_write_size(_action, _request, _limits), do: :ok

  # Public profiles write under a byte and file ceiling. The flag rides explicit
  # opts rather than a callee-derived `is_public` semantic, which no longer
  # exists — public-ness is a property of the profile, threaded in as an opt.
  # Read-only publishes never reach this.
  defp validate_public_quota(action, request, ctx, opts) when action in @writing_actions do
    if Keyword.get(opts, :public?, false) do
      quota = Keyword.get(opts, :public_quota, default_public_quota())
      enforce_quota(request, ctx, quota)
    else
      :ok
    end
  end

  defp validate_public_quota(_action, _request, _ctx, _opts), do: :ok

  defp default_public_quota do
    Application.get_env(:cyfr, :public_storage_quota, %{
      max_bytes: 26_214_400,
      max_files: 200
    })
  end

  # The operator's per-athanor ceiling for authenticated writes
  # (`CYFR_ATHANOR_STORAGE_BYTES`) — off unless set, as a private box needs
  # none. `Sanctum.Tenancy.Caps.check_storage/2` measures both of the
  # athanor's roots, data and components; the incoming size is the decoded
  # payload.
  defp validate_athanor_quota(action, %{content: content}, ctx) when action in @writing_actions do
    incoming =
      case Base.decode64(content || "") do
        {:ok, decoded} -> byte_size(decoded)
        :error -> byte_size(content || "")
      end

    case Sanctum.Tenancy.Caps.check_storage(ctx, incoming) do
      :ok ->
        :ok

      {:error, {:limit_reached, :athanor_storage_bytes, cap}} ->
        {:error, :storage_quota_exceeded, "Athanor storage quota reached (#{cap} bytes)"}
    end
  end

  defp validate_athanor_quota(_action, _request, _ctx), do: :ok

  # Usage is the RECURSIVE count and byte total under the scope root, and the
  # incoming size is the decoded payload — measuring top-level basenames (or
  # base64 framing) would let nested writes walk straight past the ceiling.
  defp enforce_quota(%{path: path, content: content}, ctx, quota) do
    incoming =
      case Base.decode64(content || "") do
        {:ok, decoded} -> byte_size(decoded)
        :error -> byte_size(content || "")
      end

    # The walk is rooted at the write's scope (`data` or `components`,
    # mapped to its physical name), and Arca scopes it to the context's
    # athanor like every other path.
    case Arca.usage(ctx, map_guest_scope([storage_root(path)])) do
      {:ok, %{files: files, bytes: used}} ->
        cond do
          files >= quota.max_files ->
            {:error, :storage_quota_exceeded,
             "Public profile file quota reached (#{quota.max_files} files)"}

          used + incoming > quota.max_bytes ->
            {:error, :storage_quota_exceeded,
             "Public profile storage quota reached (#{quota.max_bytes} bytes)"}

          true ->
            :ok
        end

      _ ->
        # An unreadable namespace is an empty one for quota purposes: the
        # write itself still passes through every path and action check.
        :ok
    end
  end

  defp storage_root(path) do
    case String.split(path, "/", parts: 2) do
      [scope, _rest] -> scope
      [scope] -> scope
    end
  end

  @known_actions ~w(read write append list delete exists)

  defp validate_action_allowed(_edge, action) when action not in @known_actions do
    # Unknown actions pass through to dispatch/3 which returns a proper "unknown_action" error
    :ok
  end

  defp validate_action_allowed(edge, action) do
    if EdgeGuard.allows_action?(edge, action) do
      :ok
    else
      {:error, :action_denied, "Storage action '#{action}' is not allowed by policy."}
    end
  end

  # The guest storage vocabulary — `Arca.Storage.guest_scopes/0` is the
  # SSOT (it also names the physical scope each one stores under); this
  # boundary only ever consumes it.
  defp valid_scopes, do: Enum.sort(Map.keys(Arca.Storage.guest_scopes()))

  @doc """
  Validate that a path starts with a valid guest scope
  (`Arca.Storage.guest_scopes/0` — `data/` or `components/`).

  Accepts bare scope names like `"data"` for directory listing.
  Empty paths are allowed (for root-level list/exists operations).
  """
  @spec validate_path_scope(String.t()) :: :ok | {:error, atom(), String.t()}
  def validate_path_scope(""), do: :ok

  def validate_path_scope(path) do
    if Enum.any?(valid_scopes(), fn scope ->
         path == scope or String.starts_with?(path, scope <> "/")
       end) do
      :ok
    else
      {:error, :storage_path_denied,
       "Path must start with 'data/' or 'components/'. Got: '#{path}'"}
    end
  end

  @doc """
  Reject path traversal attempts and absolute paths from WASM.

  Arca's normalize_path splits on "/" but does not reject ".." segments,
  so a path like "components/catalysts/agent/../../local/evil/0.1.0/catalyst.wasm"
  would escape the intended prefix. Block at the policy boundary via
  `Cyfr.PathSafety` (the canonical denylist, shared with `Arca.Storage`) —
  which also rejects null bytes, encoded `..`, and backslashes.
  """
  @spec validate_path_safe(String.t()) :: :ok | {:error, atom(), String.t()}
  def validate_path_safe(path) do
    case Cyfr.PathSafety.validate_relative_path(path) do
      :ok -> :ok
      {:error, message} -> {:error, :storage_path_denied, message}
    end
  end

  defp validate_allowed_paths(edge, path) do
    # Normalize: check both "data" and "data/" since directory listings
    # use the bare name but grants use trailing slash prefixes
    path_with_slash = if String.ends_with?(path, "/"), do: path, else: path <> "/"

    if EdgeGuard.allows_path?(edge, path) or
         EdgeGuard.allows_path?(edge, path_with_slash) do
      :ok
    else
      {:error, :storage_path_denied, "Storage path '#{path}' is not allowed by policy."}
    end
  end

  # ============================================================================
  # Private: Action Dispatch
  # ============================================================================

  defp dispatch("read", %{path: path}, limits, ctx) do
    segments = normalize_path(path, ctx)

    case Arca.get(ctx, segments) do
      {:ok, content} ->
        # The response ceiling bites BEFORE base64 framing — encoding an
        # unbounded file would build the +33% blowup in host memory first.
        case check_read_size(limits, content) do
          :ok ->
            {:ok,
             %{
               "path" => path,
               "content" => Base.encode64(content),
               "size" => byte_size(content),
               "encoding" => "base64"
             }}

          {:error, :response_too_large, message} ->
            {:error, :response_too_large, message}
        end

      {:error, :not_found} ->
        {:error, :not_found, "File not found: #{path}"}

      {:error, reason} ->
        {:error, :storage_error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp dispatch("write", %{path: path, content: nil}, _limits, _ctx) do
    {:error, :invalid_request,
     "Write action requires 'content' field with base64-encoded data. Path: #{path}"}
  end

  defp dispatch("write", %{path: path, content: b64_content}, _limits, ctx) do
    case Base.decode64(b64_content) do
      {:ok, content} ->
        segments = normalize_path(path, ctx)

        case Arca.put(ctx, segments, content) do
          :ok ->
            {:ok,
             %{
               "path" => path,
               "written" => true,
               "size" => byte_size(content)
             }}

          {:error, reason} ->
            {:error, :storage_error, "Failed to write file: #{inspect(reason)}"}
        end

      :error ->
        {:error, :invalid_base64,
         "Invalid base64 content. Content must be valid base64-encoded data."}
    end
  end

  # The bare root is a synthetic listing of the two guest scopes — never an
  # Arca walk: `[]` would list the athanor's whole data root, where host
  # state (aqua/, config/, conversations/) lives alongside guest files, and
  # a `*` path grant would hand all of it to the guest.
  defp dispatch("list", %{path: ""}, _limits, _ctx) do
    {:ok, %{"path" => "", "files" => Enum.map(valid_scopes(), &(&1 <> "/"))}}
  end

  defp dispatch("exists", %{path: ""}, _limits, _ctx) do
    {:ok, %{"path" => "", "exists" => true}}
  end

  defp dispatch("list", %{path: path}, _limits, ctx) do
    segments = normalize_path(path, ctx)

    case Arca.list_typed(ctx, segments) do
      {:ok, entries} ->
        # Directory entries carry a trailing "/" — the convention this MCP tool
        # surfaces, and what a guest walking a tree branches on. The kind comes
        # from the adapter, so it reads the same whichever one is configured.
        files =
          Enum.map(entries, fn
            {name, :dir} -> name <> "/"
            {name, :file} -> name
          end)

        {:ok,
         %{
           "path" => path,
           "files" => files
         }}

      {:error, reason} ->
        {:error, :storage_error, "Failed to list path: #{inspect(reason)}"}
    end
  end

  defp dispatch("delete", %{path: path}, _limits, ctx) do
    segments = normalize_path(path, ctx)

    case Arca.delete(ctx, segments) do
      :ok ->
        {:ok,
         %{
           "path" => path,
           "deleted" => true
         }}

      {:error, :not_found} ->
        {:error, :not_found, "File not found: #{path}"}

      {:error, reason} ->
        {:error, :storage_error, "Failed to delete file: #{inspect(reason)}"}
    end
  end

  defp dispatch("exists", %{path: path}, _limits, ctx) do
    segments = normalize_path(path, ctx)
    exists = Arca.exists?(ctx, segments)

    {:ok,
     %{
       "path" => path,
       "exists" => exists
     }}
  end

  defp dispatch("append", %{path: _path, content: nil}, _limits, _ctx) do
    {:error, :invalid_request, "Append action requires 'content' field with base64-encoded data."}
  end

  defp dispatch("append", %{path: path, content: b64_content}, _limits, ctx) do
    case Base.decode64(b64_content) do
      {:ok, content} ->
        segments = normalize_path(path, ctx)

        case Arca.append(ctx, segments, content) do
          :ok ->
            {:ok,
             %{
               "path" => path,
               "appended" => true,
               "size" => byte_size(content)
             }}

          {:error, reason} ->
            {:error, :storage_error, "Failed to append to file: #{inspect(reason)}"}
        end

      :error ->
        {:error, :invalid_base64,
         "Invalid base64 content. Content must be valid base64-encoded data."}
    end
  end

  defp dispatch(action, _request, _limits, _ctx) do
    {:error, :unknown_action,
     "Unknown storage action: #{action}. Use: read, write, append, list, delete, or exists"}
  end

  defp check_read_size(%Limits{} = limits, content),
    do: EdgeGuard.check_response_size(limits, content)

  defp check_read_size(nil, _content), do: :ok

  # ============================================================================
  # Private: Path Normalization
  # ============================================================================

  # Every path is tenant-relative and Arca scopes it to the context's
  # athanor — a catalyst can never read or write another athanor's bytes
  # because no path spelling names one. The one vocabulary difference: the
  # guest contract says `data/`, and the host stores that scope under the
  # athanor's `guest/` subtree, a physical sibling of the host scopes
  # (aqua/, config/, …) so a `data/` grant can never see them. Mapped here,
  # at the boundary; responses keep speaking `data/`.
  defp normalize_path(path, _ctx) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> map_guest_scope()
  end

  # The guest→physical scope map is `Arca.Storage.guest_scopes/0` — the
  # layout, including the one vocabulary difference between guest and
  # host, is written down in a single module.
  defp map_guest_scope([scope | rest]) do
    case Arca.Storage.guest_scopes() do
      %{^scope => physical} -> [physical | rest]
      _ -> [scope | rest]
    end
  end

  defp map_guest_scope([]), do: []

  # ============================================================================
  # Private: Response Encoding
  # ============================================================================

  defp safe_encode(data), do: Opus.WitResponse.safe_encode(data)

  defp encode_success(result) do
    safe_encode(Map.put(result, "status", "ok"))
  end

  @doc false
  def encode_error(type, message), do: Opus.WitResponse.encode_error(type, message)

  # ============================================================================
  # Private: Telemetry
  # ============================================================================

  defp emit_telemetry(component_ref, action, status, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    Opus.Telemetry.storage_call(component_ref, action, status, duration_ms)
  end
end
