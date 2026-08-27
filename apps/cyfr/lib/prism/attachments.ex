# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.Attachments do
  @moduledoc """
  The files members attach to chat messages, stored as blobs under the
  athanor's own storage — `conversations/<conversation>/<message>/<n>-<name>`
  through `Arca` — and referenced from the message row's payload as
  `%{"filename", "stored_name", "media_type", "size"}`. No storage path is
  ever persisted: a ref names its blob only by `stored_name`, and
  `blob_path/3` rebuilds the location from the row's own identity — the
  layout stays in code, and a replayed ref cannot point outside its
  message's blobs. The bytes are the record; a second device reads them
  back through `PrismWeb.AttachmentController`, and the model call
  receives them base64-encoded from `load/3`.

  Filenames are the uploader's and are reduced to a safe basename: `Cyfr.PathSafety`
  refuses traversal but not an embedded `/`, and the local adapter would turn one
  into a subdirectory. Two uploads with the same name in one message get
  distinct paths (an index prefix). The athanor's storage cap
  (`Sanctum.Tenancy.Caps.check_storage/2`) is checked before the first byte
  is written.
  """

  require Logger

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
  broken, and a write that fails mid-batch removes the files already
  written — a message never references a partial set.
  """
  @spec store(Context.t(), String.t(), String.t(), [file()]) ::
          {:ok, [ref()]}
          | {:error,
             :too_many_attachments
             | :attachment_too_large
             | :storage_full
             | :storage_unverifiable
             | :storage_error}
  def store(_ctx, _conversation_id, _message_id, []), do: {:ok, []}

  def store(%Context{} = ctx, conversation_id, message_id, files) when is_list(files) do
    with :ok <- check_count(files),
         :ok <- check_sizes(files),
         :ok <- check_quota(ctx, files) do
      files
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, refs} ->
        # The index prefix makes two same-named uploads distinct blobs —
        # and distinctly addressable. The path is blob_path/3's — the
        # same spelling the read side and the rollback resolve.
        stored_name = "#{index}-#{safe_filename(file["filename"])}"
        {:ok, path} = blob_path(conversation_id, message_id, %{"stored_name" => stored_name})
        bytes = file["bytes"] || ""

        case Arca.put(ctx, path, bytes) do
          :ok ->
            ref = %{
              "filename" => safe_filename(file["filename"]),
              "stored_name" => stored_name,
              "media_type" => file["media_type"] || "application/octet-stream",
              "size" => byte_size(bytes)
            }

            {:cont, {:ok, [ref | refs]}}

          {:error, reason} ->
            Logger.warning(
              "[Prism.Attachments] storing #{inspect(stored_name)} failed: " <>
                "#{inspect(reason)}; removing #{length(refs)} already-written file(s)"
            )

            Enum.each(refs, fn written ->
              with {:ok, blob} <- blob_path(conversation_id, message_id, written) do
                Arca.delete(ctx, blob)
              end
            end)

            {:halt, {:error, :storage_error}}
        end
      end)
      |> case do
        {:ok, refs} -> {:ok, Enum.reverse(refs)}
        error -> error
      end
    end
  end

  @doc """
  One ref's blob location, rebuilt from the owning row's identity — the
  only spelling of an attachment path outside `store/4`. `:error` for a
  ref without a stored name (it references no blob).
  """
  @spec blob_path(String.t(), String.t(), ref()) :: {:ok, [String.t()]} | :error
  def blob_path(conversation_id, message_id, ref)
      when is_binary(conversation_id) and is_binary(message_id) do
    case ref["stored_name"] do
      name when is_binary(name) and name != "" ->
        {:ok, Arca.ConversationStorage.blob_root(conversation_id) ++ [message_id, name]}

      _ ->
        :error
    end
  end

  @doc """
  Every attachment in a list of message rows, paired with the message
  that owns it — the shape `load/3` resolves.
  """
  @spec attachments_of([Arca.Schemas.Message.t()]) :: [%{message_id: String.t(), ref: ref()}]
  def attachments_of(rows) when is_list(rows) do
    Enum.flat_map(rows, fn msg ->
      Enum.map(refs_of(msg), &%{message_id: msg.id, ref: &1})
    end)
  end

  @doc """
  A turn's attachments as the model input wants them —
  `[%{"filename", "media_type", "data"}]`, base64. A blob that has gone
  missing is skipped rather than failing the turn.
  """
  @spec load(Context.t(), String.t(), [%{message_id: String.t(), ref: ref()}]) :: [map()]
  def load(%Context{} = ctx, conversation_id, attachments) when is_list(attachments) do
    Enum.flat_map(attachments, fn %{message_id: message_id, ref: ref} ->
      with {:ok, path} <- blob_path(conversation_id, message_id, ref),
           {:ok, bytes} <- Arca.get(ctx, path) do
        [
          %{
            "filename" => ref["filename"],
            "media_type" => ref["media_type"],
            "data" => Base.encode64(bytes)
          }
        ]
      else
        _ -> []
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
      |> String.normalize(:nfc)
      |> String.replace(~r/[\/\\]/, "_")
      |> String.replace(~r/[\x00-\x1f\x7f]/, "")
      |> String.trim()

    base =
      if byte_size(base) > @name_max,
        do: base |> truncate_bytes(@name_max) |> String.trim(),
        else: base

    # Arca reserves `<name>.tmp.<n>` as its in-flight write marker
    # ({:error, :reserved_name} on put) — an upload named like one must
    # still store. After truncation, which could otherwise re-mint the
    # shape; the extra byte stays far under PathSafety's segment cap.
    base = if Arca.Storage.tmp_name?(base), do: base <> "_", else: base

    case base do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      other -> other
    end
  end

  def safe_filename(_), do: "file"

  # The cap is in BYTES (the filesystem's unit — NAME_MAX is 255 bytes, and
  # a grapheme cut of a multibyte name can run several times over it), so cut
  # at the byte and drop the trailing bytes of a split codepoint.
  defp truncate_bytes(string, max) do
    cut = binary_part(string, 0, max)

    case String.valid?(cut) do
      true -> cut
      false -> truncate_bytes(cut, byte_size(cut) - 1)
    end
  end

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
      # Pass through — the cap layer worked to tell "over the cap" from
      # "cannot verify"; collapsing them here would cost the member the
      # honest message (transient — retry, not delete-your-files).
      {:error, :storage_unverifiable} -> {:error, :storage_unverifiable}
    end
  end
end
