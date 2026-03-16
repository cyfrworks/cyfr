defmodule Arca.Storage do
  @moduledoc """
  Behaviour for storage adapters.

  All paths are lists of segments, e.g. `["builds", "build_1", "started.json"]`.
  The adapter handles joining to the actual storage location.

  ## Path Scoping

  Paths are automatically scoped based on the first segment:

  - **Component paths**: `["components" | rest]` → routed to `components_path`
  - **Global paths**: `cache` → stored at root level
  - **User paths**: everything else → stored under `users/{user_id}/`

  This enables:
  - Components to live in a single `components/` directory (no duplication)
  - Services to store user-specific data with isolation (user-scoped)

  ## Storage Structure

      components/                        # Component artifacts (separate root)
      └── {type}s/{publisher}/{name}/{version}/

      data/
      ├── {env}.db                       # SQLite database (all structured data)
      ├── cache/                         # Global: immutable cached artifacts
      │   └── oci/{digest}/
      └── users/{user_id}/               # User-scoped
          ├── builds/                    # Locus build lifecycle
          ├── data/                      # User data (agent conversations, etc.)
          ├── config/                    # User config (retention settings, etc.)
          └── audit/                     # Audit events (append-only JSONL, opt-in)

  ## Structured Logs (SQLite only)

  MCP request logs, execution records, and policy consultation logs are stored
  exclusively in SQLite tables (`mcp_logs`, `executions`, `policy_logs`).
  They are NOT written to disk files.

  ## Implementations

  - `Arca.Adapters.Local` - Filesystem storage
  - `Arca.Adapters.S3` - S3-compatible storage (Managed/Enterprise) [future]

  ## Usage

  Services use the main `Arca` module which dispatches to the configured adapter:

      ctx = Sanctum.Context.local()

      # User-scoped (auto-prefixed with users/{user_id}/)
      Arca.put(ctx, ["builds", "build_1", "started.json"], json_content)

      # Global (no user prefix)
      Arca.put(ctx, ["cache", "oci", "sha256_abc"], wasm_binary)

  """

  alias Sanctum.Context

  @type path :: [String.t()]
  @type error :: {:error, :not_found | :permission_denied | term()}

  @doc """
  Global path prefixes that are NOT scoped to a user.

  These paths are stored at the root level, not under `users/{user_id}/`.
  """
  @global_prefixes ["cache"]

  def global_prefixes, do: @global_prefixes

  @doc """
  Validate that path segments contain no traversal attacks.

  Rejects any segment containing `..` to prevent directory traversal.
  Must be called by all adapter implementations before building paths.

  ## Examples

      iex> Arca.Storage.validate_path!(["builds", "build_1", "started.json"])
      :ok

      iex> Arca.Storage.validate_path!(["builds", "..", "..", "etc", "passwd"])
      ** (ArgumentError) Path traversal rejected: segment \"..\" is not allowed

  """
  def validate_path!(segments) when is_list(segments) do
    Enum.each(segments, fn segment ->
      cond do
        segment == ".." ->
          raise ArgumentError, "Path traversal rejected: segment \"..\" is not allowed"

        String.contains?(segment, <<0>>) ->
          raise ArgumentError, "Path traversal rejected: null bytes are not allowed"

        fully_decode(segment) =~ ~r/(^|[\/\\])\.\.($|[\/\\])/ ->
          raise ArgumentError, "Path traversal rejected: encoded \"..\" is not allowed"

        true ->
          :ok
      end
    end)

    :ok
  end

  # Decode URI-encoded segments until output stabilizes, catching multi-layer encoding.
  defp fully_decode(segment) do
    decoded = URI.decode(segment)
    if decoded == segment, do: segment, else: fully_decode(decoded)
  end

  @doc "Read content from storage"
  @callback get(Context.t(), path()) :: {:ok, binary()} | error()

  @doc "Write content to storage (overwrites existing)"
  @callback put(Context.t(), path(), binary()) :: :ok | error()

  @doc "Append content to storage (for append-only logs like audit/*.jsonl)"
  @callback append(Context.t(), path(), binary()) :: :ok | error()

  @doc "Delete content from storage"
  @callback delete(Context.t(), path()) :: :ok | error()

  @doc "List contents at path prefix"
  @callback list(Context.t(), path()) :: {:ok, [String.t()]} | error()

  @doc "Check if path exists"
  @callback exists?(Context.t(), path()) :: boolean()

  @doc "Recursively delete a directory tree at path"
  @callback delete_tree(Context.t(), path()) :: :ok | error()
end
