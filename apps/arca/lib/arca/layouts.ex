# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Layouts do
  @moduledoc """
  The per-person layout documents (`Prima.Layout`): one per person per
  athanor, published fenced (`Arca.FencedPublication`).

  A layout is a fenced document, `{:document, athanor_id, "layouts/<user_id>"}`:
  the `fenced_documents` row is its reference, revision and digest, and
  the bytes are the document's canonical JSON (`Prima.Layout.encode/1`),
  staged where `Arca.Storage.stage/3` wrote them. No table of its own is
  needed: the reference row already holds the athanor, the key naming the
  person, the revision, the staged bytes' key, their digest and the
  timestamps.

  `publish/4` stages the document and publishes it over the revision the
  writer read, under this member's slot: a publication over a newer
  revision is `:stale`, and a member that no longer owns its slot
  publishes nothing (`:not_owner`). A document never published reads as
  `:not_found`, revision 0.

  Every function takes the actor first and reads or writes the actor's
  athanor alone. Which person may read or arrange which layout is the
  caller's decision; this module keeps the rows.
  """

  alias Arca.FencedPublication

  @prefix "layouts/"
  @attempt "layouts"
  @person ~r/\A[A-Za-z0-9_:-]{1,128}\z/

  @typedoc "A stored layout: the document, the revision it is at and its digest."
  @type stored :: %{document: Prima.Layout.t(), revision: pos_integer(), digest: String.t()}

  @typedoc "Why a publication wrote nothing."
  @type refusal ::
          FencedPublication.refusal() | :no_athanor | :no_person | {:storage, term()}

  @doc "The fenced document key of `user_id`'s layout."
  @spec key(String.t()) :: String.t()
  def key(user_id) when is_binary(user_id), do: @prefix <> user_id

  @doc """
  The layout of the person `user_id` in the actor's athanor, with its
  revision and digest.

  `{:error, :not_found}` where none was ever published (read it as
  revision 0); `:corrupt` where the stored bytes no longer read as a
  layout or no longer hold the digest their reference records;
  `:no_person` for an id that names nobody; `:no_athanor` for an actor
  naming none; `:database_error` or `{:storage, reason}` when the store
  cannot answer.
  """
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, stored()}
          | {:error,
             :not_found
             | :corrupt
             | :no_person
             | :no_athanor
             | :database_error
             | {:storage, term()}}
  def get(%Prima.Actor{} = actor, user_id) do
    with :ok <- person(user_id) do
      case FencedPublication.document(actor, key(user_id)) do
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
  Publish `layout` as the person `user_id`'s, over `revision_read`, the
  revision the writer read (0 for none), under this member's slot.

  Answers `{:ok, revision}`, the revision the layout now holds; or the
  refusals of `Arca.FencedPublication.publish/3` (`:stale` for a
  publication over a newer revision, `:not_owner`, `:expired`, `:budget`,
  `:database_error`), `{:storage, reason}` when the bytes could not be
  staged, `:no_person` or `:no_athanor`. A refused publication's staged
  bytes have their reservation ended, for the sweep to remove.
  """
  @spec publish(Prima.Actor.t(), String.t(), Prima.Layout.t(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, refusal()}
  def publish(%Prima.Actor{} = actor, user_id, %Prima.Layout{} = layout, revision_read)
      when is_integer(revision_read) and revision_read >= 0 do
    with :ok <- person(user_id),
         :ok <- athanor(actor),
         {:ok, slot} <- slot(),
         {:ok, staged} <- stage(actor, Prima.Layout.encode(layout)) do
      change = %FencedPublication.Change{
        resource: {:document, actor.athanor_id, key(user_id)},
        staged: staged,
        digest: Prima.Layout.digest(layout)
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

  # ---- internals -------------------------------------------------------------

  # The bytes the reference names, held to the digest it records: bytes
  # that changed under their reference are not this layout.
  defp read(actor, blob_key, revision, digest) do
    case Arca.get(actor, String.split(blob_key, "/")) do
      {:ok, bytes} when is_binary(bytes) ->
        with true <- Prima.Digest.sha256(bytes) == digest,
             {:ok, document} <- Prima.Layout.decode(bytes) do
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

  defp person(user_id) do
    if is_binary(user_id) and Regex.match?(@person, user_id),
      do: :ok,
      else: {:error, :no_person}
  end

  defp athanor(%Prima.Actor{athanor_id: athanor_id})
       when is_binary(athanor_id) and athanor_id != "",
       do: :ok

  defp athanor(%Prima.Actor{}), do: {:error, :no_athanor}
end
