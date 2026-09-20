# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.GuestStorage do
  @moduledoc """
  A running component's storage operations, in its athanor, under the
  storage its consent edge grants: the checks and the store calls behind
  the `storage` host call (`Cyfr.Execution.Host.Storage`). A runner parses
  its guest's `cyfr:storage/files` request into an operation and its
  arguments and hands the answer back to the guest; every decision about
  what the operation may reach is taken here.

  ## Operations

  | Operation | Arguments | Answer members |
  |---|---|---|
  | `:read` | `path` | `path`, `content` (base64), `size`, `encoding` |
  | `:write` | `path`, `content` (base64) | `path`, `written`, `size` |
  | `:append` | `path`, `content` (base64) | `path`, `appended`, `size` |
  | `:list` | `path` | `path`, `files` (directories end in `/`) |
  | `:delete` | `path` | `path`, `deleted` |
  | `:exists` | `path` | `path`, `exists` |

  ## Checks, in order

    1. The context names an athanor (`Arca.Storage.athanor_ready?/1`).
    2. The edge's `storage.actions` name the operation (case-insensitive).
    3. The path starts with a guest scope (`Arca.Storage.valid_guest_path?/1`:
       `data/` or `components/`, or `""` for the scope listing).
    4. A write, append or delete names a file inside a scope; inside an
       overlaid scope it lands inside a unit (`Arca.Storage.locate/1`), and
       under a component publisher only `local/`
       (`Compendium.NamespacePolicy.require_local_guest_write/1`).
    5. The path is relative, with no traversal (`Cyfr.PathSafety`).
    6. The edge's `storage.paths` allow the path: `"*"` allows every path,
       an entry ending in `/` a prefix, anything else that exact path. An
       empty list, a nil storage group and a nil edge allow nothing.
    7. A write or append's decoded content is within the node's
       `max_request_size`.
    8. For a public profile, a write or append keeps its scope within the
       public quota (`config :cyfr, :public_storage_quota`); usage that
       cannot be read refuses the write.
    9. A write or append finds its scope under 100,000 files; usage that
       cannot be read passes this check.

  A read or listing answers at most the node's `max_response_size` bytes.
  The athanor's byte cap is `Arca`'s own write gate.

  ## Holding the attempt

  A write, append or delete is handed to the scope's `hold` as a
  `t:Arca.ExecutionAttempts.write/0`: the operation, the physical path and
  the store call. The hold records the write's intent while the calling
  attempt holds its row, runs the store call outside any transaction and
  settles the intent against the same hold
  (`Arca.ExecutionAttempts.while_held/5`). This module never calls the
  store for a mutation itself.

  | The hold answers | The guest is answered |
  |---|---|
  | `{:error, :lost}`: the attempt did not hold its row; nothing was recorded or written | `{:error, :lost}` |
  | `{:error, :unavailable}`: the database could not say; nothing was recorded or written | `{:error, :unavailable}` |
  | `{:ok, {:confirmed, :ok}}` | the operation's members |
  | `{:ok, {:failed, {:error, reason}}}`: the store wrote nothing | the refusal of that reason: `not_found`, `storage_quota_exceeded`, `storage_conflict` for an append that kept losing to concurrent writers, else `storage_error` |
  | `{:ok, {:uncertain, reason}}`: the write may or may not be in the store | `storage_uncertain`, saying whether the attempt lost its row or the store could not say |

  ## Answers

  `{:ok, members}`, or `{:error, {:guest_error, type, message}}` with the
  refusal the guest is handed: `storage_path_denied`, `action_denied`,
  `request_too_large`, `response_too_large`, `storage_quota_exceeded`,
  `not_found`, `invalid_request`, `invalid_base64`, `storage_conflict`,
  `storage_uncertain` or `storage_error`. Every refusal but
  `storage_uncertain` wrote nothing; after `storage_uncertain` the guest
  reads the path back before it writes it again. A store fault is logged
  and answered by the verb that failed; a raise below this module is logged
  and answered `Internal storage error.`.
  """

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Limits
  alias Sanctum.Context

  @typedoc "An operation a guest asks of its storage."
  @type op :: Cyfr.HostAPI.storage_op()

  @typedoc "The public profile's ceilings on one guest scope."
  @type quota :: %{max_bytes: non_neg_integer(), max_files: non_neg_integer()}

  @typedoc """
  Runs a write for the calling attempt under its hold on its row, answering
  what became of it (`t:Arca.ExecutionAttempts.written/0`),
  `{:error, :lost}` when the attempt does not hold its row, or
  `{:error, :unavailable}` when the database cannot say.
  """
  @type hold ::
          (Arca.ExecutionAttempts.write() ->
             {:ok, Arca.ExecutionAttempts.written()} | {:error, :lost | :unavailable})

  @typedoc """
  What an operation runs under: the guest-plane context, the consent edge
  (nil grants nothing), the node's limits, the public quota (nil for a
  profile that is not public) and the attempt's hold.
  """
  @type scope :: %{
          ctx: Context.t(),
          edge: Edge.t() | nil,
          limits: Limits.t() | nil,
          quota: quota() | nil,
          hold: hold()
        }

  @typedoc "A refusal handed to the guest, or the attempt's loss of its row."
  @type refusal :: {:guest_error, String.t(), String.t()} | :lost | :unavailable

  @mutating [:write, :append, :delete]
  @writing [:write, :append]

  # A fixed ceiling on files per guest-writable scope: no byte cap sees a
  # loop of empty files.
  @max_scope_files 100_000

  @doc """
  The scope an attempt's operations run under: `ctx` on the guest plane,
  the edge and profile kind of `authority`, the node's `limits` and the
  attempt's `hold`.
  """
  @spec scope(Context.t(), Authority.t(), Limits.t() | nil, hold()) :: scope()
  def scope(%Context{} = ctx, %Authority{} = authority, limits, hold) when is_function(hold, 1) do
    %{
      ctx: ctx,
      edge: edge(authority),
      limits: limits,
      quota: quota(authority),
      hold: hold
    }
  end

  defp edge(%Authority{resources: %Edge{} = edge}), do: edge
  defp edge(%Authority{}), do: nil

  # A public profile's guest writes are held to the configured quota.
  defp quota(%Authority{profile_kind: :public}),
    do: Application.fetch_env!(:cyfr, :public_storage_quota)

  defp quota(%Authority{}), do: nil

  @doc """
  Run one guest storage operation `op` with `args` (`"path"`, and
  `"content"` for a write or append) under `scope`.
  """
  @spec run(scope(), op(), map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{ctx: %Context{}} = scope, op, %{"path" => path} = args)
      when op in [:read, :write, :append, :list, :delete, :exists] and is_binary(path) do
    content = Map.get(args, "content")

    if is_nil(content) or is_binary(content) do
      caught(scope, op, path, content)
    else
      guest_error(:invalid_request, "'content' must be a base64 string.")
    end
  end

  defp caught(scope, op, path, content) do
    checked(scope, op, path, content)
  rescue
    exception ->
      Logger.error(
        "[Cyfr.Execution.GuestStorage] #{op} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      guest_error(:storage_error, "Internal storage error.")
  end

  defp checked(scope, op, path, content) do
    with :ok <- athanor(scope.ctx),
         :ok <- action_allowed(scope.edge, op),
         :ok <- path_scope(path),
         :ok <- mutable_depth(op, path),
         :ok <- path_safe(path),
         :ok <- path_allowed(scope.edge, path),
         :ok <- write_size(op, content, scope.limits),
         :ok <- public_quota(op, path, content, scope),
         :ok <- scope_files(op, path, scope.ctx) do
      dispatch(op, path, content, scope)
    end
  end

  # ---------------------------------------------------------------------------
  # Checks
  # ---------------------------------------------------------------------------

  # Every guest path is tenant-relative, so a context without an athanor has
  # no storage at all.
  defp athanor(ctx) do
    if Arca.Storage.athanor_ready?(Sanctum.Context.actor(ctx)),
      do: :ok,
      else: guest_error(:storage_path_denied, "Storage requires an athanor-scoped context.")
  end

  defp action_allowed(edge, op) do
    action = Atom.to_string(op)

    if Enum.any?(Edge.actions(edge), &(String.downcase(&1) == action)),
      do: :ok,
      else: guest_error(:action_denied, "Storage action '#{action}' is not allowed by policy.")
  end

  defp path_scope(path) do
    if Arca.Storage.valid_guest_path?(path) do
      :ok
    else
      allowed = Enum.map_join(guest_scope_names(), " or ", &"'#{&1}/'")
      guest_error(:storage_path_denied, "Path must start with #{allowed}. Got: '#{path}'")
    end
  end

  defp guest_scope_names, do: Enum.sort(Map.keys(Arca.Storage.guest_scopes()))

  # The empty path and a bare scope name directories: only a listing or an
  # existence check may name them.
  defp mutable_depth(op, path) when op in @mutating do
    case String.split(path, "/", trim: true) do
      [_scope, _ | _] = segments ->
        mutable_unit(physical(segments), path)

      _ ->
        guest_error(
          :storage_path_denied,
          "A file path inside a scope is required (e.g. 'data/notes.txt'). Got: '#{path}'"
        )
    end
  end

  defp mutable_depth(_op, _path), do: :ok

  # A mutation inside an overlaid scope lands inside a unit, so it never
  # mints a tree shape no unit grammar owns.
  defp mutable_unit(segments, path) do
    case Arca.Storage.locate(segments) do
      :above_unit ->
        guest_error(
          :storage_path_denied,
          "Component writes must land inside a version directory " <>
            "(components/{type}s/{publisher}/{name}/{version}/...). Got: '#{path}'"
        )

      {:file, unit} ->
        unit_publisher(unit)

      {:dir, unit, _sentinel} ->
        unit_publisher(unit)

      :not_overlaid ->
        :ok
    end
  end

  defp unit_publisher(["components", _plural, publisher | _]) do
    case Compendium.NamespacePolicy.require_local_guest_write(publisher) do
      :ok -> :ok
      {:error, message} -> guest_error(:storage_path_denied, message)
    end
  end

  defp unit_publisher(_unit), do: :ok

  defp path_safe(path) do
    case Cyfr.PathSafety.validate_relative_path(path) do
      :ok -> :ok
      {:error, {_reason, message}} -> guest_error(:storage_path_denied, message)
    end
  end

  # A directory listing names the bare directory while a grant names its
  # prefix, so a path is also matched with a trailing slash.
  defp path_allowed(edge, path) do
    with_slash = if String.ends_with?(path, "/"), do: path, else: path <> "/"

    if Enum.any?(Edge.paths(edge), &grant_matches?(&1, path, with_slash)),
      do: :ok,
      else: guest_error(:storage_path_denied, "Storage path '#{path}' is not allowed by policy.")
  end

  defp grant_matches?("*", _path, _with_slash), do: true

  defp grant_matches?(grant, path, with_slash) do
    if String.ends_with?(grant, "/"),
      do: String.starts_with?(path, grant) or String.starts_with?(with_slash, grant),
      else: path == grant or with_slash == grant
  end

  # Measured on the decoded content; content that does not decode is
  # refused by the operation itself.
  defp write_size(op, content, %Limits{max_request_size: max})
       when op in @writing and is_binary(content) and is_integer(max) do
    case Base.decode64(content) do
      {:ok, decoded} when byte_size(decoded) > max ->
        guest_error(
          :request_too_large,
          "Storage write (#{byte_size(decoded)} bytes) exceeds limit (#{max} bytes)"
        )

      _ ->
        :ok
    end
  end

  defp write_size(_op, _content, _limits), do: :ok

  # Usage is the recursive count and byte total under the write's scope, and
  # the incoming size is the decoded content.
  defp public_quota(op, path, content, %{quota: %{} = quota, ctx: ctx}) when op in @writing do
    %{max_files: max_files, max_bytes: max_bytes} = quota

    incoming =
      case Base.decode64(content || "") do
        {:ok, decoded} -> byte_size(decoded)
        :error -> byte_size(content || "")
      end

    case scope_usage(ctx, path) do
      {:ok, %{files: files}} when files >= max_files ->
        guest_error(
          :storage_quota_exceeded,
          "Public profile file quota reached (#{max_files} files)"
        )

      {:ok, %{bytes: used}} when used + incoming > max_bytes ->
        guest_error(
          :storage_quota_exceeded,
          "Public profile storage quota reached (#{max_bytes} bytes)"
        )

      {:ok, _usage} ->
        :ok

      _unreadable ->
        Logger.warning(
          "[Cyfr.Execution.GuestStorage] public-quota usage unreadable for " <>
            "#{ctx.athanor_id}; refusing the write"
        )

        guest_error(:storage_quota_exceeded, "Storage usage unavailable — write refused.")
    end
  end

  defp public_quota(_op, _path, _content, _scope), do: :ok

  defp scope_files(op, path, ctx) when op in @writing do
    case scope_usage(ctx, path) do
      {:ok, %{files: files}} when files >= @max_scope_files ->
        guest_error(
          :storage_quota_exceeded,
          "Storage file ceiling reached (#{@max_scope_files} files per scope)"
        )

      _ ->
        :ok
    end
  end

  defp scope_files(_op, _path, _ctx), do: :ok

  defp scope_usage(ctx, path) do
    [scope | _] = physical(String.split(path, "/", parts: 2))
    Arca.Usage.scope_usage(Sanctum.Context.actor(ctx), scope)
  end

  # ---------------------------------------------------------------------------
  # Store calls
  # ---------------------------------------------------------------------------

  defp dispatch(:read, path, _content, scope) do
    case Arca.get(Sanctum.Context.actor(scope.ctx), segments(path)) do
      {:ok, content} ->
        with :ok <- response_size(scope.limits, "read", byte_size(content)) do
          {:ok,
           %{
             "path" => path,
             "content" => Base.encode64(content),
             "size" => byte_size(content),
             "encoding" => "base64"
           }}
        end

      {:error, :not_found} ->
        guest_error(:not_found, "File not found: #{path}")

      {:error, reason} ->
        store_fault("read file", reason)
    end
  end

  # The bare root lists the guest scopes, never the athanor's tree, where
  # the host's own roots live beside them.
  defp dispatch(:list, "", _content, _scope),
    do: {:ok, %{"path" => "", "files" => Enum.map(guest_scope_names(), &(&1 <> "/"))}}

  defp dispatch(:list, path, _content, scope) do
    case Arca.list_typed(Sanctum.Context.actor(scope.ctx), segments(path)) do
      {:ok, entries} ->
        files =
          Enum.map(entries, fn
            {name, :dir} -> name <> "/"
            {name, :file} -> name
          end)

        with :ok <- response_size(scope.limits, "listing", byte_size(Enum.join(files, "\n"))) do
          {:ok, %{"path" => path, "files" => files}}
        end

      {:error, reason} ->
        store_fault("list path", reason)
    end
  end

  defp dispatch(:exists, "", _content, _scope), do: {:ok, %{"path" => "", "exists" => true}}

  defp dispatch(:exists, path, _content, scope),
    do:
      {:ok,
       %{
         "path" => path,
         "exists" => Arca.exists?(Sanctum.Context.actor(scope.ctx), segments(path))
       }}

  defp dispatch(op, _path, nil, _scope) when op in @writing do
    guest_error(
      :invalid_request,
      "#{String.capitalize(Atom.to_string(op))} action requires 'content' field with " <>
        "base64-encoded data."
    )
  end

  defp dispatch(op, path, content, scope) when op in @writing do
    case Base.decode64(content) do
      {:ok, bytes} ->
        {verb, store} = if op == :write, do: {:put, &Arca.put/3}, else: {:append, &Arca.append/3}
        physical = segments(path)

        scope
        |> held(%{
          op: verb,
          path: physical,
          bytes: byte_size(bytes),
          io: fn -> store.(Sanctum.Context.actor(scope.ctx), physical, bytes) end
        })
        |> written(op, path, byte_size(bytes))

      :error ->
        guest_error(
          :invalid_base64,
          "Invalid base64 content. Content must be valid base64-encoded data."
        )
    end
  end

  defp dispatch(:delete, path, _content, scope) do
    physical = segments(path)

    write = %{
      op: :delete,
      path: physical,
      io: fn -> Arca.delete(Sanctum.Context.actor(scope.ctx), physical) end
    }

    case held(scope, write) do
      {:ok, {:confirmed, :ok}} -> {:ok, %{"path" => path, "deleted" => true}}
      {:ok, {:failed, {:error, :not_found}}} -> guest_error(:not_found, "File not found: #{path}")
      {:ok, {:failed, {:error, reason}}} -> store_fault("delete file", reason)
      {:ok, {:uncertain, reason}} -> uncertain("delete", path, reason)
      {:error, refusal} -> {:error, refusal}
    end
  end

  defp held(%{hold: hold}, write) do
    case hold.(write) do
      {:ok, {kind, _detail} = written} when kind in [:confirmed, :failed, :uncertain] ->
        {:ok, written}

      {:error, refusal} when refusal in [:lost, :unavailable] ->
        {:error, refusal}
    end
  end

  defp written({:ok, {:confirmed, :ok}}, :write, path, size),
    do: {:ok, %{"path" => path, "written" => true, "size" => size}}

  defp written({:ok, {:confirmed, :ok}}, :append, path, size),
    do: {:ok, %{"path" => path, "appended" => true, "size" => size}}

  defp written({:ok, {:failed, {:error, reason}}}, op, path, _size), do: refused(op, path, reason)

  defp written({:ok, {:uncertain, reason}}, op, path, _size),
    do: uncertain(Atom.to_string(op), path, reason)

  defp written({:error, refusal}, _op, _path, _size), do: {:error, refusal}

  # The store wrote nothing, and said why.
  defp refused(_op, _path, {:limit_reached, :athanor_storage_bytes, cap}),
    do: guest_error(:storage_quota_exceeded, "Athanor storage quota reached (#{cap} bytes)")

  defp refused(_op, _path, :storage_unverifiable) do
    guest_error(
      :storage_quota_exceeded,
      "Athanor storage usage cannot be verified right now — try again"
    )
  end

  defp refused(:append, path, :precondition_failed) do
    guest_error(
      :storage_conflict,
      "Append to '#{path}' kept losing to concurrent writers and appended nothing; " <>
        "appending again is safe."
    )
  end

  defp refused(_op, _path, reason), do: store_fault("write file", reason)

  # The write may or may not be in the store: never answered as written,
  # never as refused.
  defp uncertain(verb, path, :hold_lost) do
    guest_error(
      :storage_uncertain,
      "The execution attempt stopped being current while the #{verb} of '#{path}' was in " <>
        "flight; whether it landed is recorded as uncertain."
    )
  end

  defp uncertain(verb, path, :unconfirmed) do
    guest_error(
      :storage_uncertain,
      "The #{verb} of '#{path}' reached the store but could not be confirmed for the " <>
        "execution attempt; read the path before writing it again."
    )
  end

  defp uncertain(verb, path, reason) do
    Logger.error("[Cyfr.Execution.GuestStorage] a #{verb} is uncertain: #{reason}")

    guest_error(
      :storage_uncertain,
      "The store could not say whether the #{verb} of '#{path}' landed; read the path " <>
        "before writing it again."
    )
  end

  defp response_size(%Limits{max_response_size: max}, what, size)
       when is_integer(max) and size > max do
    guest_error(
      :response_too_large,
      "Storage #{what} (#{size} bytes) exceeds limit (#{max} bytes)"
    )
  end

  defp response_size(_limits, _what, _size), do: :ok

  # An adapter's reason names the backend and how it failed: the guest is
  # told only the verb.
  defp store_fault(what, reason) do
    Logger.error("[Cyfr.Execution.GuestStorage] #{what} failed: #{inspect(reason)}")
    guest_error(:storage_error, "Failed to #{what}")
  end

  # ---------------------------------------------------------------------------
  # Paths
  # ---------------------------------------------------------------------------

  # A guest scope stores under the athanor's root of the same name, a
  # sibling of the host's roots, so no guest path names one of them.
  defp segments(path), do: path |> String.split("/", trim: true) |> physical()

  defp physical([scope | rest]) do
    case Arca.Storage.guest_scopes() do
      %{^scope => root} -> [root | rest]
      _ -> [scope | rest]
    end
  end

  defp physical([]), do: []

  defp guest_error(type, message), do: {:error, {:guest_error, Atom.to_string(type), message}}
end
