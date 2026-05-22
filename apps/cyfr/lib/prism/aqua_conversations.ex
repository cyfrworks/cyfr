# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaConversations do
  @moduledoc """
  Conversation persistence for AQUA, routed through the `catalyst:local.files`
  WASM component.

  Mirrors the storage layer used by Porta (the Tauri desktop client) so both
  surfaces share the same on-disk format, the same path scope (`data/`), and
  the same policy gate. Direct `Arca.get_json/2` calls are intentionally
  avoided — using the catalyst means writes flow through Opus' policy
  enforcement and show up in the executions audit log, matching what Porta
  already does in `apps/porta/src-ui/src/state/conversation-store.ts`.

  ## Layout

      data/agent_conversations/index.json   # {entries: [%{id, title, updated_at, status}]}
      data/agent_conversations/<id>.json    # full conversation payload

  ## Usage

      {:ok, entries} = Prism.AquaConversations.read_index_or_rebuild(ctx)
      :ok = Prism.AquaConversations.write_index(ctx, entries)
      {:ok, conv} = Prism.AquaConversations.read_conversation(ctx, id)
      :ok = Prism.AquaConversations.write_conversation(ctx, id, conv_map)
      :ok = Prism.AquaConversations.delete_conversation(ctx, id)

  Reads are synchronous — call from a `Task` if you don't want to block.
  Writes already run through Opus' executor pipeline and are themselves
  short-lived.
  """

  require Logger

  alias Sanctum.Context

  @catalyst_ref "catalyst:local.files"

  @conversations_dir "data/agent_conversations"
  @index_path "data/agent_conversations/index.json"

  @type entry :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:updated_at) => String.t(),
          optional(:status) => String.t()
        }

  @doc """
  Read `index.json`. Returns `{:ok, entries}` or `{:error, reason}`. Returns
  `{:ok, []}` when the file simply doesn't exist yet.
  """
  @spec read_index(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def read_index(%Context{} = ctx) do
    case files_call(ctx, %{"action" => "read_text", "path" => @index_path}) do
      {:ok, %{"content" => content}} when is_binary(content) ->
        decode_index(content)

      {:error, %{kind: :not_found}} ->
        {:ok, []}

      {:error, reason} ->
        if not_found?(reason) do
          {:ok, []}
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Read the index, falling back to a directory scan + rebuild when the index
  is missing or empty. Mirrors Porta's `loadConversations` flow
  (`conversation-store.ts:90-145`).
  """
  @spec read_index_or_rebuild(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def read_index_or_rebuild(%Context{} = ctx) do
    case read_index(ctx) do
      {:ok, []} -> rebuild_index(ctx)
      {:ok, entries} -> {:ok, entries}
      {:error, _} = err -> err
    end
  end

  @doc "Write `index.json` (overwrites)."
  @spec write_index(Context.t(), [map()]) :: :ok | {:error, term()}
  def write_index(%Context{} = ctx, entries) when is_list(entries) do
    case files_call(ctx, %{
           "action" => "write_text",
           "path" => @index_path,
           "content" => Jason.encode!(%{"entries" => entries})
         }) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Read a single conversation file."
  @spec read_conversation(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_conversation(%Context{} = ctx, id) when is_binary(id) do
    case files_call(ctx, %{"action" => "read_text", "path" => conv_path(id)}) do
      {:ok, %{"content" => content}} when is_binary(content) -> Jason.decode(content)
      {:error, _} = err -> err
    end
  end

  @doc "Write a single conversation file."
  @spec write_conversation(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def write_conversation(%Context{} = ctx, id, %{} = conv_data) when is_binary(id) do
    case files_call(ctx, %{
           "action" => "write_text",
           "path" => conv_path(id),
           "content" => Jason.encode!(conv_data)
         }) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Delete a conversation file."
  @spec delete_conversation(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete_conversation(%Context{} = ctx, id) when is_binary(id) do
    case files_call(ctx, %{"action" => "delete", "path" => conv_path(id)}) do
      {:ok, _} -> :ok
      {:error, reason} ->
        if not_found?(reason), do: :ok, else: {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp conv_path(id), do: "#{@conversations_dir}/#{id}.json"

  defp decode_index(content) do
    case Jason.decode(content) do
      {:ok, %{"entries" => entries}} when is_list(entries) -> {:ok, entries}
      {:ok, _} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  defp rebuild_index(ctx) do
    with {:ok, %{"files" => files}} when is_list(files) <-
           files_call(ctx, %{"action" => "list", "path" => @conversations_dir <> "/"}) do
      entries =
        files
        |> Enum.filter(fn f ->
          is_binary(f) and String.ends_with?(f, ".json") and f != "index.json"
        end)
        |> Enum.map(fn f -> entry_from_file(ctx, f) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1["updated_at"], :desc)

      {:ok, entries}
    else
      {:error, reason} ->
        if not_found?(reason), do: {:ok, []}, else: {:error, reason}

      _ ->
        {:ok, []}
    end
  end

  defp entry_from_file(ctx, filename) do
    id = String.trim_trailing(filename, ".json")

    case read_conversation(ctx, id) do
      {:ok, %{"id" => ^id} = conv} ->
        %{
          "id" => id,
          "title" => conv["title"] || "Untitled",
          "updated_at" => conv["updated_at"] || conv["created_at"] || "",
          "status" =>
            if(conv["running"] && conv["execution_id"], do: "running", else: "idle")
        }

      _ ->
        nil
    end
  end

  defp files_call(ctx, input) do
    case Emissary.MCP.ToolRegistry.call("execution", ctx, %{
           "action" => "run",
           "reference" => @catalyst_ref,
           "input" => input,
           "type" => "catalyst"
         }) do
      {:ok, %{result: result}} -> normalize_result(result)
      {:ok, %{"result" => result}} -> normalize_result(result)
      {:ok, result} when is_map(result) -> normalize_result(result)
      {:error, _} = err -> err
    end
  end

  # The catalyst output may arrive with atom or string keys depending on the
  # serializer that brought it back across the BEAM boundary. Normalize to
  # string-keyed maps so the rest of this module has one shape to handle.
  defp normalize_result(result) when is_map(result) do
    {:ok,
     Map.new(result, fn
       {k, v} when is_atom(k) -> {Atom.to_string(k), v}
       {k, v} -> {k, v}
     end)}
  end

  defp normalize_result(result), do: {:ok, result}

  # Catalyst surfaces "not found" through assorted shapes — be lenient.
  defp not_found?({:error, reason}), do: not_found?(reason)
  defp not_found?(reason) when is_binary(reason), do: String.contains?(reason, "not found") or String.contains?(reason, "ENOENT")
  defp not_found?(%{kind: :not_found}), do: true
  defp not_found?(%{"kind" => "not_found"}), do: true
  defp not_found?(_), do: false
end