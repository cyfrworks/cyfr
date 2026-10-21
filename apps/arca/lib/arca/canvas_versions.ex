# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CanvasVersions do
  @moduledoc """
  The versions document of each canvas: one per canvas per athanor,
  published fenced (`Arca.FencedPublication`), as `Arca.Layouts` publishes
  a person's layout.

  A canvas's document is a fenced document,
  `{:document, athanor_id, "canvases/<name>"}`, `name` being the canvas's
  component name (`Prima.ComponentRef.validate_name/1`). It reads

      %{version: 1, allocated: v | nil, working: v | nil, kept: v | nil,
        failed: %{version: v, outcome: "no_tree" | "died", at: iso8601} | nil}

    * `allocated` — the newest version a write allocated;
    * `working` — the version a glass opens;
    * `kept` — the version the last activation replaced;
    * `failed` — the last validation that answered no tree, or whose
      candidate died: its version, its outcome and when, in UTC to the
      second (`2026-10-09T12:00:00Z`).

  Every version is a `MAJOR.MINOR.PATCH` string (`version?/1`).

  This module is the document's codec. The bytes are the document's
  canonical JSON (`Prima.JCS`), absent fields omitted since canonical JSON
  has no null, and the digest is `Prima.Digest.sha256/1` of those bytes.
  Stored bytes that no longer hold the digest their reference records, or
  that are not exactly what this codec writes for a document, read as
  `:corrupt`.

  `publish/4` stages the document and publishes it over the revision the
  writer read, under this member's slot: a publication over a newer
  revision is `:stale` and merges nothing, and a member that no longer
  owns its slot publishes nothing (`:not_owner`). A document never
  published reads as `:not_found`, revision 0.

  Every function takes the actor first and reads or writes the actor's
  athanor alone. Which caller may read or change a canvas's versions is
  the caller's decision; this module keeps the document.
  """

  alias Arca.FencedPublication

  @prefix "canvases/"
  @attempt "canvases"
  @outcomes ~w(no_tree died)
  @fields ~w(version allocated working kept failed)
  @failure_fields ~w(at outcome version)

  @version ~r/\A(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z/
  @instant ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc "A canvas version: `MAJOR.MINOR.PATCH`."
  @type version :: String.t()

  @typedoc "The last validation that failed: its version, its outcome and when."
  @type failure :: %{version: version(), outcome: String.t(), at: String.t()}

  @typedoc "A canvas's versions document."
  @type document :: %{
          version: 1,
          allocated: version() | nil,
          working: version() | nil,
          kept: version() | nil,
          failed: failure() | nil
        }

  @typedoc "A stored document: the document, the revision it is at and its digest."
  @type stored :: %{document: document(), revision: pos_integer(), digest: String.t()}

  @typedoc "Why a publication wrote nothing."
  @type refusal ::
          FencedPublication.refusal()
          | :invalid_name
          | :invalid_document
          | :no_athanor
          | {:storage, term()}

  @doc "The fenced document key of the canvas `name`'s versions."
  @spec key(String.t()) :: String.t()
  def key(name) when is_binary(name), do: @prefix <> name

  @doc "The document of a canvas no write has allocated a version for."
  @spec empty() :: document()
  def empty, do: %{version: 1, allocated: nil, working: nil, kept: nil, failed: nil}

  @doc "Whether `version` is a canvas version: `MAJOR.MINOR.PATCH`, with no leading zero."
  @spec version?(term()) :: boolean()
  def version?(version), do: is_binary(version) and Regex.match?(@version, version)

  @doc """
  The canonical JSON bytes of `document`, or `{:error, :invalid_document}`
  for a term that is not a document as the module doc describes it.
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, :invalid_document}
  def encode(document) do
    with true <- document?(document),
         {:ok, bytes} <- Prima.JCS.encode(to_json(document)) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_document}
    end
  end

  @doc """
  The document `bytes` hold, or `{:error, :invalid_document}` for bytes
  that are not exactly what `encode/1` writes for one.
  """
  @spec decode(term()) :: {:ok, document()} | {:error, :invalid_document}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, %{} = json} <- Jason.decode(bytes),
         {:ok, document} <- from_json(json),
         {:ok, ^bytes} <- encode(document) do
      {:ok, document}
    else
      _ -> {:error, :invalid_document}
    end
  end

  def decode(_bytes), do: {:error, :invalid_document}

  @doc """
  The versions document of the canvas `name` in the actor's athanor, with
  its revision and digest.

  `{:error, :not_found}` where none was ever published (read it as
  revision 0); `:corrupt` where the stored bytes no longer read as a
  document or no longer hold the digest their reference records;
  `:invalid_name` for a name outside the component-name grammar;
  `:no_athanor` for an actor naming none; `:database_error` or
  `{:storage, reason}` when the store cannot answer.
  """
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, stored()}
          | {:error,
             :not_found
             | :corrupt
             | :invalid_name
             | :no_athanor
             | :database_error
             | {:storage, term()}}
  def get(%Prima.Actor{} = actor, name) do
    with :ok <- name(name) do
      case FencedPublication.document(actor, key(name)) do
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
  Publish `document` as the canvas `name`'s versions, over
  `revision_read`, the revision the writer read (0 for none), under this
  member's slot.

  Answers `{:ok, revision}`, the revision the document now holds; or the
  refusals of `Arca.FencedPublication.publish/3` (`:stale` for a
  publication over a newer revision, `:not_owner`, `:expired`, `:budget`,
  `:database_error`), `{:storage, reason}` when the bytes could not be
  staged, `:invalid_name`, `:invalid_document` or `:no_athanor`. A
  refused publication's staged bytes have their reservation ended, for
  the sweep to remove.
  """
  @spec publish(Prima.Actor.t(), String.t(), document(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, refusal()}
  def publish(%Prima.Actor{} = actor, name, document, revision_read)
      when is_integer(revision_read) and revision_read >= 0 do
    with :ok <- name(name),
         {:ok, bytes} <- encode(document),
         :ok <- athanor(actor),
         {:ok, slot} <- slot(),
         {:ok, staged} <- stage(actor, bytes) do
      change = %FencedPublication.Change{
        resource: {:document, actor.athanor_id, key(name)},
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

  # ---- the codec ---------------------------------------------------------------

  defp document?(%{version: 1, allocated: a, working: w, kept: k, failed: f} = document)
       when map_size(document) == 5,
       do: Enum.all?([a, w, k], &optional_version?/1) and failure?(f)

  defp document?(_term), do: false

  defp optional_version?(nil), do: true
  defp optional_version?(version), do: version?(version)

  defp failure?(nil), do: true

  defp failure?(%{version: version, outcome: outcome, at: at} = failure)
       when map_size(failure) == 3,
       do: version?(version) and outcome in @outcomes and instant?(at)

  defp failure?(_term), do: false

  defp instant?(at) when is_binary(at) do
    Regex.match?(@instant, at) and match?({:ok, _, 0}, DateTime.from_iso8601(at))
  end

  defp instant?(_at), do: false

  defp to_json(document) do
    %{"version" => 1}
    |> put_present("allocated", document.allocated)
    |> put_present("working", document.working)
    |> put_present("kept", document.kept)
    |> put_present("failed", failure_json(document.failed))
  end

  defp failure_json(nil), do: nil

  defp failure_json(failure),
    do: %{"version" => failure.version, "outcome" => failure.outcome, "at" => failure.at}

  defp from_json(%{"version" => 1} = json) do
    failed = Map.get(json, "failed")

    if Enum.all?(Map.keys(json), &(&1 in @fields)) and failure_json?(failed) do
      {:ok,
       %{
         version: 1,
         allocated: Map.get(json, "allocated"),
         working: Map.get(json, "working"),
         kept: Map.get(json, "kept"),
         failed: failure_from_json(failed)
       }}
    else
      :error
    end
  end

  defp from_json(_json), do: :error

  defp failure_json?(nil), do: true
  defp failure_json?(%{} = failed), do: Enum.sort(Map.keys(failed)) == @failure_fields
  defp failure_json?(_failed), do: false

  defp failure_from_json(nil), do: nil

  defp failure_from_json(failed),
    do: %{version: failed["version"], outcome: failed["outcome"], at: failed["at"]}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ---- storage -----------------------------------------------------------------

  # The bytes the reference names, held to the digest it records and to
  # the codec: bytes that changed under their reference, or that this
  # module did not write, are not this canvas's versions.
  defp read(actor, blob_key, revision, digest) do
    case Arca.get(actor, String.split(blob_key, "/")) do
      {:ok, bytes} when is_binary(bytes) ->
        with true <- Prima.Digest.sha256(bytes) == digest,
             {:ok, document} <- decode(bytes) do
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

  defp name(name) do
    if is_binary(name) and Prima.ComponentRef.validate_name(name) == :ok,
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp athanor(%Prima.Actor{athanor_id: athanor_id})
       when is_binary(athanor_id) and athanor_id != "",
       do: :ok

  defp athanor(%Prima.Actor{}), do: {:error, :no_athanor}
end
