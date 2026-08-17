# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Attachments do
  @moduledoc """
  The files members attach to chat messages, stored as blobs under the
  athanor's own storage — `conversations/<conversation>/<message>/<n>-<name>`
  through `Arca` — and referenced from the message row's payload as
  `%{"filename", "media_type", "size", "path"}`. The bytes are the record;
  a second device reads them back through `PrismWeb.AttachmentController`,
  and the model call receives them base64-encoded from `load/2`.

  Filenames are the uploader's and are reduced to a safe basename: `Cyfr.PathSafety`
  refuses traversal but not an embedded `/`, and the local adapter would turn one
  into a subdirectory. Two uploads with the same name in one message get
  distinct paths (an index prefix). The athanor's storage cap
  (`Sanctum.Tenancy.Caps.check_storage/2`) is checked before the first byte
  is written.
  """

  alias Sanctum.Context
  alias Sanctum.Tenancy.Caps

  @max_files 10
  @max_file_bytes 20_000_000
  @name_max 120

  @type file :: %{required(String.t()) => term()}
  @type ref :: %{required(String.t()) => term()}

  @doc "Per-message bounds: files and bytes per file."
  @spec limits() :: %{max_files: pos_integer(), max_file_bytes: pos_integer()}
  def limits, do: %{max_files: @max_files, max_file_bytes: @max_file_bytes}

  @doc """
  Store `files` (`[%{"filename", "media_type", "bytes"}]`) for a message
  and return their refs, in order. Nothing is written when any bound is
  broken.
  """
  @spec store(Context.t(), String.t(), String.t(), [file()]) ::
          {:ok, [ref()]} | {:error, :too_many_attachments | :attachment_too_large | :storage_full}
  def store(_ctx, _conversation_id, _message_id, []), do: {:ok, []}

  def store(%Context{} = ctx, conversation_id, message_id, files) when is_list(files) do
    with :ok <- check_count(files),
         :ok <- check_sizes(files),
         :ok <- check_quota(ctx, files) do
      refs =
        files
        |> Enum.with_index()
        |> Enum.map(fn {file, index} ->
          name = "#{index}-#{safe_filename(file["filename"])}"
          path = Arca.ConversationStorage.blob_root(conversation_id) ++ [message_id, name]
          bytes = file["bytes"] || ""
          :ok = Arca.put(ctx, path, bytes)

          %{
            "filename" => safe_filename(file["filename"]),
            "media_type" => file["media_type"] || "application/octet-stream",
            "size" => byte_size(bytes),
            "path" => path
          }
        end)

      {:ok, refs}
    end
  end

  @doc """
  The refs of a message's payload as the model input wants them —
  `[%{"filename", "media_type", "data"}]`, base64. A blob that has gone
  missing is skipped rather than failing the turn.
  """
  @spec load(Context.t(), [ref()]) :: [map()]
  def load(%Context{} = ctx, refs) when is_list(refs) do
    Enum.flat_map(refs, fn ref ->
      case ref["path"] do
        path when is_list(path) ->
          case Arca.get(ctx, path) do
            {:ok, bytes} ->
              [
                %{
                  "filename" => ref["filename"],
                  "media_type" => ref["media_type"],
                  "data" => Base.encode64(bytes)
                }
              ]

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  @doc "The refs stored on a message row's payload (`[]` when none)."
  @spec refs_of(Arca.Schemas.Message.t()) :: [ref()]
  def refs_of(msg) do
    case Arca.ConversationStorage.payload(msg)["attachments"] do
      refs when is_list(refs) -> refs
      _ -> []
    end
  end

  @doc """
  A filename reduced to one safe path segment: the basename, control
  characters and separators removed, capped in length, never empty or a
  dot-name.
  """
  @spec safe_filename(term()) :: String.t()
  def safe_filename(name) when is_binary(name) do
    base =
      name
      |> String.replace(~r/[\/\\]/, "_")
      |> String.replace(~r/[\x00-\x1f\x7f]/, "")
      |> String.trim()

    base =
      if byte_size(base) > @name_max,
        do: base |> String.slice(0, @name_max) |> String.trim(),
        else: base

    case base do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      other -> other
    end
  end

  def safe_filename(_), do: "file"

  # ---- bounds -----------------------------------------------------------------

  defp check_count(files) when length(files) > @max_files, do: {:error, :too_many_attachments}
  defp check_count(_files), do: :ok

  defp check_sizes(files) do
    if Enum.any?(files, fn f -> byte_size(f["bytes"] || "") > @max_file_bytes end),
      do: {:error, :attachment_too_large},
      else: :ok
  end

  defp check_quota(ctx, files) do
    incoming = files |> Enum.map(&byte_size(&1["bytes"] || "")) |> Enum.sum()

    case Caps.check_storage(ctx, incoming) do
      :ok -> :ok
      {:error, {:limit_reached, :athanor_storage_bytes, _cap}} -> {:error, :storage_full}
    end
  end
end
