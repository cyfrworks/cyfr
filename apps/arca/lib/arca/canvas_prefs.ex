# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CanvasPrefs do
  @moduledoc """
  The preferences documents (`Prima.CanvasPrefs`): one per person per
  canvas in an athanor, published fenced (`Arca.FencedPublication`), as
  `Arca.Layouts` publishes a person's layout.

  A document is a fenced document,
  `{:document, athanor_id, "prefs/<user_id>/<canvas_id>"}`, the person id
  in `Arca.Layouts.person?/1`'s grammar and the canvas id in
  `Prima.Layout.canvas_id?/1`'s. The `fenced_documents` row is its
  reference, revision and digest, and the bytes are the document's
  canonical JSON (`Prima.CanvasPrefs.encode/1`), staged where
  `Arca.Storage.stage/3` wrote them; no table of its own is needed.

  `write/6` validates what a desktop sends against the schema the
  caller names, reads the stored document and, when it is still at the
  revision the writer read, publishes the stored document projected to
  that schema with the incoming one merged over it
  (`Prima.CanvasPrefs.merge/2`), under this member's slot. A writer that
  read an older revision, or that loses to a racing one, merges nothing
  and is answered the current document projected to the schema with its
  revision, to merge again from. A document never published reads as
  `:not_found`, revision 0, the empty document. `get/3` answers the
  document as stored; projecting it to a schema is the caller's.

  Every function takes the actor first and reads or writes the actor's
  athanor alone. Which person may read or write whose preferences is the
  caller's decision; this module keeps the rows.
  """

  alias Arca.FencedPublication

  @prefix "prefs/"
  @attempt "prefs"

  @typedoc "A stored document: the document, the revision it is at and its digest."
  @type stored :: %{document: Prima.CanvasPrefs.t(), revision: pos_integer(), digest: String.t()}

  @typedoc "The document a writer is answered to merge again from, and its revision."
  @type current :: %{document: Prima.CanvasPrefs.t(), revision: non_neg_integer()}

  @typedoc "Why a read answered no document."
  @type read_refusal ::
          :not_found
          | :corrupt
          | :no_person
          | :invalid_canvas
          | :no_athanor
          | :database_error
          | {:storage, term()}

  @typedoc "Why a write published nothing."
  @type write_refusal ::
          {:invalid, String.t()}
          | {:stale, current()}
          | :too_large
          | :corrupt
          | :no_person
          | :invalid_canvas
          | :no_athanor
          | :not_owner
          | :expired
          | :budget
          | :database_error
          | {:storage, term()}

  @doc "The fenced document key of `user_id`'s preferences for the canvas `canvas_id`."
  @spec key(String.t(), String.t()) :: String.t()
  def key(user_id, canvas_id) when is_binary(user_id) and is_binary(canvas_id),
    do: @prefix <> user_id <> "/" <> canvas_id

  @doc """
  The preferences of the person `user_id` for the canvas `canvas_id` in
  the actor's athanor, as stored, with their revision and digest.

  `{:error, :not_found}` where none was ever published (read it as
  revision 0, `Prima.CanvasPrefs.empty/0`); `:corrupt` where the stored
  bytes no longer hold the digest their reference records or are not a
  document `Prima.CanvasPrefs.decode/1` reads; `:no_person` for an id
  that names nobody; `:invalid_canvas` for a canvas id outside its
  grammar; `:no_athanor` for an actor naming none; `:database_error` or
  `{:storage, reason}` when the store cannot answer.
  """
  @spec get(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, stored()} | {:error, read_refusal()}
  def get(%Prima.Actor{} = actor, user_id, canvas_id) do
    with :ok <- names(user_id, canvas_id) do
      case FencedPublication.document(actor, key(user_id, canvas_id)) do
        %{revision: revision, blob_key: blob_key, digest: digest} ->
          read(actor, blob_key, revision, digest)

        :not_found ->
          {:error, :not_found}

        {:error, _} = refusal ->
          refusal
      end
    end
  end

  @doc """
  Merge `incoming`, what a desktop sends, into the person `user_id`'s
  preferences for the canvas `canvas_id`, held to `schema` (the active
  version's `prefs`), over `revision_read`, the revision the writer read
  (0 for none), under this member's slot.

  Answers `{:ok, %{document: merged, revision: revision}}`, the document
  now stored and its revision; or, writing nothing:

    * `{:invalid, sentence}` — `incoming` is refused by
      `Prima.CanvasPrefs.validate/2`;
    * `{:stale, %{document: document, revision: revision}}` — the stored
      document is no longer at `revision_read`, or a racing writer
      published first: the current document, projected to `schema`, and
      its revision;
    * `:too_large` — the merged document's bytes exceed
      `Prima.CanvasPrefs.max_bytes/0`;
    * `:corrupt`, `:no_person`, `:invalid_canvas`, `:no_athanor`,
      `:database_error` and `{:storage, reason}` as `get/3` answers them;
    * the other refusals of `Arca.FencedPublication.publish/3`:
      `:not_owner`, `:expired`, `:budget`.

  A refused publication's staged bytes have their reservation ended, for
  the sweep to remove.
  """
  @spec write(
          Prima.Actor.t(),
          String.t(),
          String.t(),
          term(),
          Prima.CanvasPrefs.schema(),
          non_neg_integer()
        ) :: {:ok, current()} | {:error, write_refusal()}
  def write(%Prima.Actor{} = actor, user_id, canvas_id, incoming, schema, revision_read)
      when is_integer(revision_read) and revision_read >= 0 do
    with :ok <- names(user_id, canvas_id),
         {:ok, incoming} <- validated(incoming, schema),
         {:ok, %{document: stored}} <- fresh(actor, user_id, canvas_id, schema, revision_read),
         merged = Prima.CanvasPrefs.merge(stored, incoming),
         bytes = Prima.CanvasPrefs.encode(merged),
         :ok <- within_cap(bytes),
         {:ok, revision} <- publish(actor, key(user_id, canvas_id), bytes, revision_read) do
      {:ok, %{document: merged, revision: revision}}
    else
      # Only the publication answers a bare `:stale`: a racing writer
      # published over the revision this one read.
      {:error, :stale} -> stale(actor, user_id, canvas_id, schema)
      {:error, _} = refused -> refused
    end
  end

  # ---- internals -------------------------------------------------------------

  defp validated(incoming, schema) do
    case Prima.CanvasPrefs.validate(incoming, schema) do
      {:ok, incoming} -> {:ok, incoming}
      {:error, sentence} -> {:error, {:invalid, sentence}}
    end
  end

  # The stored document projected to `schema`, when it is still at the
  # revision the writer read; the stale refusal otherwise.
  defp fresh(actor, user_id, canvas_id, schema, revision_read) do
    case current(actor, user_id, canvas_id, schema) do
      {:ok, %{revision: ^revision_read}} = read -> read
      {:ok, current} -> {:error, {:stale, current}}
      {:error, _} = refusal -> refusal
    end
  end

  defp stale(actor, user_id, canvas_id, schema) do
    case current(actor, user_id, canvas_id, schema) do
      {:ok, current} -> {:error, {:stale, current}}
      {:error, _} = refusal -> refusal
    end
  end

  defp current(actor, user_id, canvas_id, schema) do
    case get(actor, user_id, canvas_id) do
      {:ok, %{document: document, revision: revision}} ->
        {:ok, %{document: Prima.CanvasPrefs.project(document, schema), revision: revision}}

      {:error, :not_found} ->
        {:ok, %{document: Prima.CanvasPrefs.empty(), revision: 0}}

      {:error, _} = refusal ->
        refusal
    end
  end

  defp within_cap(bytes) do
    if byte_size(bytes) > Prima.CanvasPrefs.max_bytes(),
      do: {:error, :too_large},
      else: :ok
  end

  defp publish(actor, key, bytes, revision_read) do
    with {:ok, slot} <- slot(),
         {:ok, staged} <- stage(actor, bytes) do
      change = %FencedPublication.Change{
        resource: {:document, actor.athanor_id, key},
        staged: staged,
        digest: Prima.Digest.sha256(bytes)
      }

      case FencedPublication.publish(change, revision_read, slot) do
        {:ok, revision} ->
          {:ok, revision}

        {:error, _} = refused ->
          _ = Arca.Storage.cancel_stage(actor, staged)
          refused
      end
    end
  end

  # The bytes the reference names, held to the digest it records and to
  # the codec: bytes that changed under their reference, or that the codec
  # did not write, are not this person's preferences.
  defp read(actor, blob_key, revision, digest) do
    case Arca.get(actor, String.split(blob_key, "/")) do
      {:ok, bytes} when is_binary(bytes) ->
        with true <- Prima.Digest.sha256(bytes) == digest,
             {:ok, document} <- Prima.CanvasPrefs.decode(bytes) do
          {:ok, %{document: document, revision: revision, digest: digest}}
        else
          _ -> {:error, :corrupt}
        end

      {:error, reason} ->
        {:error, {:storage, reason}}
    end
  end

  defp stage(actor, bytes) do
    case Arca.Storage.stage(actor, @attempt, bytes) do
      {:ok, staged} -> {:ok, staged}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, :database_error} -> {:error, :database_error}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp slot do
    case Arca.ControlPlane.member_slot() do
      {:ok, slot} -> {:ok, slot}
      {:error, :not_owner} -> {:error, :not_owner}
    end
  end

  defp names(user_id, canvas_id) do
    cond do
      not Arca.Layouts.person?(user_id) -> {:error, :no_person}
      not Prima.Layout.canvas_id?(canvas_id) -> {:error, :invalid_canvas}
      true -> :ok
    end
  end
end
