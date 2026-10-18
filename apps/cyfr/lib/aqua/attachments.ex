# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Attachments do
  @moduledoc """
  The files members attach to chat messages, stored as blobs under the
  athanor's own storage — `threads/<thread>/<message>/<n>-<name>`
  through `Arca` — and referenced from the message row's payload as
  `%{"filename", "stored_name", "media_type", "size"}`. No storage path is
  ever persisted: a ref names its blob only by `stored_name`, and
  `blob_path/3` rebuilds the location from the row's own identity — the
  layout stays in code, and a replayed ref cannot point outside its
  message's blobs. The bytes are the record; a second device reads them
  back through `PrismWeb.AttachmentController`, and the model call
  receives them base64-encoded from `load/3`.

  Filenames are the uploader's and are reduced to a safe basename: `Prima.PathSafety`
  refuses traversal but not an embedded `/`, and the local adapter would turn one
  into a subdirectory. Two uploads with the same name in one message get
  distinct paths (an index prefix). The athanor's storage cap is asked of
  the cap port (`Prima.Caps.check_storage/2`) before the first byte is
  written.
  """

  require Logger

  alias Sanctum.Context

  @max_files 10
  @max_file_bytes 20_000_000
  @name_max 120
  @unsent_ttl_ms 24 * 60 * 60 * 1000

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

  The files go only under a message that has not been sent, and each is
  created only where nothing is (`Arca.put_if_none_match/4`): no call,
  the storing session's own included, writes over a file already under
  the message, which `discard_unsent/3` removes first. A file found there
  refuses the call as `:attachment_exists`, and the files it already wrote
  go. What a session stored is remembered for it (`discard_unsent/3`).
  """
  @spec store(Context.t(), String.t(), String.t(), [file()]) ::
          {:ok, [ref()]}
          | {:error,
             :too_many_attachments
             | :attachment_too_large
             | :storage_full
             | :storage_unverifiable
             | :storage_error
             | :message_sent
             | :attachment_exists
             | :database_error}
  def store(_ctx, _thread_id, _message_id, []), do: {:ok, []}

  def store(%Context{} = ctx, thread_id, message_id, files) when is_list(files) do
    with :ok <- check_count(files),
         :ok <- check_sizes(files),
         :ok <- check_quota(ctx, files),
         :ok <- unsent(ctx, message_id) do
      files
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, refs} ->
        # The index prefix makes two same-named uploads distinct blobs —
        # and distinctly addressable. The path is blob_path/3's — the
        # same spelling the read side and the rollback resolve.
        stored_name = stored_name(file, index)
        {:ok, path} = blob_path(thread_id, message_id, %{"stored_name" => stored_name})
        bytes = file["bytes"] || ""

        # Created only where nothing is: the check and the write are one
        # step, so a member racing another on the same name never writes
        # over the other's bytes, sent or not.
        case Arca.put_if_none_match(Sanctum.Context.actor(ctx), path, bytes) do
          :ok ->
            ref = %{
              "filename" => safe_filename(file["filename"]),
              "stored_name" => stored_name,
              "media_type" => file["media_type"] || Prima.MediaType.binary(),
              "size" => byte_size(bytes)
            }

            {:cont, {:ok, [ref | refs]}}

          {:error, reason} ->
            Logger.warning(
              "[Aqua.Attachments] storing #{inspect(stored_name)} failed: " <>
                "#{inspect(reason)}; removing #{length(refs)} already-written file(s)"
            )

            Enum.each(refs, fn written ->
              with {:ok, blob} <- blob_path(thread_id, message_id, written) do
                Arca.delete(Sanctum.Context.actor(ctx), blob)
              end
            end)

            {:halt, {:error, if(reason == :exists, do: :attachment_exists, else: :storage_error)}}
        end
      end)
      |> case do
        {:ok, refs} ->
          refs = Enum.reverse(refs)
          remember(ctx, thread_id, message_id, refs)
          {:ok, refs}

        error ->
          error
      end
    end
  end

  @doc """
  Remove the files `refs` names under a message whose row never landed,
  for a caller holding refs `store/4` just answered it in the same
  process (`Aqua.Aloud`), never refs a client names: a client's discard
  is `discard_unsent/3`.
  """
  @spec discard(Context.t(), String.t(), String.t(), [ref()]) :: :ok
  def discard(%Context{} = ctx, thread_id, message_id, refs) when is_list(refs) do
    Enum.each(refs, fn ref ->
      with {:ok, blob} <- blob_path(thread_id, message_id, ref) do
        Arca.delete(Sanctum.Context.actor(ctx), blob)
      end
    end)
  end

  @doc """
  Remove the files the caller's own session stored for a message that has
  not been sent: a send refused after its files were stored, or a held
  send the person gives up. Only the names `store/4` remembered for this
  session under this thread and message are removed, never what a
  caller names, so no one removes another session's files; a message
  already sent keeps its files (`:message_sent`).

  The memory is the node's (`Arca.Cache`, for a day): it only narrows
  what a discard reaches, so a session whose memory is gone, or that
  stored on another node, removes nothing and its files stay counted
  against the athanor's storage. Answers the names removed.
  """
  @spec discard_unsent(Context.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :message_sent | :database_error}
  def discard_unsent(%Context{} = ctx, thread_id, message_id)
      when is_binary(thread_id) and is_binary(message_id) do
    with :ok <- unsent(ctx, message_id) do
      case holder(ctx) do
        nil ->
          {:ok, []}

        holder ->
          case Arca.Cache.take(unsent_key(holder, message_id)) do
            {:ok, %{thread_id: ^thread_id, names: names}} ->
              for name <- names do
                {:ok, blob} = blob_path(thread_id, message_id, %{"stored_name" => name})
                Arca.delete(Sanctum.Context.actor(ctx), blob)
              end

              {:ok, names}

            _none ->
              {:ok, []}
          end
      end
    end
  end

  # A message with a row was sent: its files are its record.
  defp unsent(ctx, message_id) do
    case Arca.ThreadStorage.get_message(Sanctum.Context.actor(ctx), message_id) do
      {:ok, _sent} -> {:error, :message_sent}
      {:error, :not_found} -> :ok
      {:error, :database_error} -> {:error, :database_error}
      {:error, :no_athanor} -> {:error, :message_sent}
    end
  end

  defp owned(ctx, thread_id, message_id) do
    with holder when holder != nil <- holder(ctx),
         {:ok, %{thread_id: ^thread_id, names: names}} <-
           Arca.Cache.get(unsent_key(holder, message_id)) do
      names
    else
      _ -> []
    end
  end

  defp remember(ctx, thread_id, message_id, refs) do
    case holder(ctx) do
      nil ->
        :ok

      holder ->
        names =
          Enum.uniq(owned(ctx, thread_id, message_id) ++ for(r <- refs, do: r["stored_name"]))

        Arca.Cache.put(
          unsent_key(holder, message_id),
          %{thread_id: thread_id, names: names},
          @unsent_ttl_ms
        )
    end
  end

  # The session a call came from: its session, its key or its paired
  # client, with its person and athanor. A context with none of them
  # stores no memory and discards nothing.
  defp holder(%Context{user_id: user_id, athanor_id: athanor_id} = ctx)
       when is_binary(user_id) and is_binary(athanor_id) do
    case ctx.session_token_hash || ctx.api_key_id || ctx.client_id do
      nil -> nil
      credential -> {athanor_id, user_id, credential}
    end
  end

  defp holder(_ctx), do: nil

  defp unsent_key(holder, message_id), do: {:aqua_unsent_attachments, holder, message_id}

  defp stored_name(file, index), do: "#{index}-#{safe_filename(file["filename"])}"

  @doc """
  One ref's blob location, rebuilt from the owning row's identity — the
  only spelling of an attachment path outside `store/4`. `:error` for a
  ref without a stored name (it references no blob).
  """
  @spec blob_path(String.t(), String.t(), ref()) :: {:ok, [String.t()]} | :error
  def blob_path(thread_id, message_id, ref)
      when is_binary(thread_id) and is_binary(message_id) do
    case ref["stored_name"] do
      name when is_binary(name) and name != "" ->
        {:ok, Arca.ThreadStorage.blob_root(thread_id) ++ [message_id, name]}

      _ ->
        :error
    end
  end

  @doc """
  Every attachment in a list of message rows, paired with the message
  that owns it — the shape `load/3` resolves.
  """
  @spec attachments_of([Aqua.Tape.row()]) :: [%{message_id: String.t(), ref: ref()}]
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
  def load(%Context{} = ctx, thread_id, attachments) when is_list(attachments) do
    Enum.flat_map(attachments, fn %{message_id: message_id, ref: ref} ->
      with {:ok, path} <- blob_path(thread_id, message_id, ref),
           {:ok, bytes} <- Arca.get(Sanctum.Context.actor(ctx), path) do
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
  @spec refs_of(Aqua.Tape.row()) :: [ref()]
  def refs_of(msg) do
    case Arca.ThreadStorage.payload(msg)["attachments"] do
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
      |> strip_controls()
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

  @doc """
  Strip C0 control characters and DEL from a filename.
  Content-Disposition callers must also filter quotes and backslashes.
  """
  @spec strip_controls(String.t()) :: String.t()
  def strip_controls(name) when is_binary(name) do
    String.replace(name, ~r/[\x00-\x1f\x7f]/, "")
  end

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

    case Prima.Caps.check_storage(Context.actor(ctx), incoming) do
      :ok -> :ok
      {:error, {:limit_reached, :athanor_storage_bytes, _cap}} -> {:error, :storage_full}
      # Pass through — the cap layer worked to tell "over the cap" from
      # "cannot verify"; collapsing them here would cost the member the
      # honest message (transient — retry, not delete-your-files).
      {:error, :storage_unverifiable} -> {:error, :storage_unverifiable}
    end
  end
end
