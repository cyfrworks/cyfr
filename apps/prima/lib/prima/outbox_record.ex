# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.OutboxRecord do
  @moduledoc """
  One fact a source transaction recorded for the reactions that must
  survive a crash (`Arca.Outbox`): the source it came from, the source's
  revision, the athanor it belongs to, its kind, and an immutable
  snapshot of what the fact was when it was recorded. It names no
  consumer: each consumer keeps its own receipt of what it did with it
  (`Arca.ConsumerReceipts`) and reads nothing but the snapshot.

  The kinds are closed. `schedule_outcome` is a schedule's completed
  occurrence (`schedule_outcome/1`): its source is the occurrence, its
  revision the schedule's `updated_at` at the finish, read in the
  finish's own transaction, and its snapshot holds:

    * `output` — the run's output as the run stored it, already masked by
      the close that answered it, JSON-encoded when it is not a string
      and cut to `max_output_bytes/0` on a character boundary with
      `truncated` set; nil when the schedule did not ask to keep it;
    * `sources` — the run's source ledger (`Prima.Source`) as the
      finish's own transaction read it, canonical JSON objects beside the
      output they describe, so a kept note carries the classes the run
      read without a later read of an execution row retention may have
      removed; nil when the schedule did not ask to keep the output;
    * `keep_outcome` and `note_name` — the schedule's choice at the
      finish, the pair its stored metadata states (`keep_pair/1`);
    * `schedule_revision` — the schedule's revision, the same instant as
      the record's `source_revision`;
    * `schedule_id`, `profile_id` and `consent_revision` — the authority
      the run fired under: the schedule, its bound profile, and the
      revision of that profile's head consent (nil for none);
    * `occurrence_id`, `execution_id` and `scheduled_for` — which run it
      was, and the time it was due for, the order its outcomes land in;
    * `note_revision_read` — the revision of the schedule's note as the
      run read it (0 for no note), or `"absent"` for a run that read none.

  A record's snapshot is canonical JSON text (`Prima.JCS`): the record
  as stored is the record as recorded, byte for byte. A field with no
  value is left out of the text and reads back as nil.
  """

  @kinds ~w(schedule_outcome)
  @source_kinds ~w(schedule_occurrence)
  @max_output_bytes 64 * 1024

  @enforce_keys [:source_kind, :source_id, :source_revision, :athanor_id, :kind, :snapshot]
  defstruct [:source_kind, :source_id, :source_revision, :athanor_id, :kind, :snapshot]

  @type t :: %__MODULE__{
          source_kind: String.t(),
          source_id: String.t(),
          source_revision: String.t(),
          athanor_id: String.t(),
          kind: String.t(),
          snapshot: %{String.t() => term()}
        }

  @typedoc "Which source, at which revision, a record or a receipt is about."
  @type source :: %{
          source_kind: String.t(),
          source_id: String.t(),
          source_revision: String.t()
        }

  @doc "The record kinds, a closed roster."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The source kinds a record may name, a closed roster."
  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  @doc "The cap on a `schedule_outcome` snapshot's `output`, in bytes."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc """
  The record of a completed schedule occurrence, from what the finish
  read in its transaction: `occurrence` (`id`, `athanor_id`,
  `scheduled_for`, `execution_id`, `note_revision_read`), `schedule`
  (`id`, `profile_id`, `updated_at`), `consent_revision`, the parsed
  `keep` pair `{keep_outcome, note_name}`, the run's raw `output` and
  its ledger `sources`, both kept only when the schedule asked to keep
  the output.
  """
  @spec schedule_outcome(map()) :: t()
  def schedule_outcome(%{
        occurrence: %{id: occurrence_id, athanor_id: athanor_id} = occurrence,
        schedule: %{id: schedule_id, profile_id: profile_id, updated_at: %DateTime{} = updated},
        consent_revision: consent_revision,
        keep: {keep?, note_name},
        output: output,
        sources: sources
      })
      when is_binary(occurrence_id) and is_binary(athanor_id) and athanor_id != "" and
             is_binary(schedule_id) and is_boolean(keep?) and is_list(sources) and
             (is_integer(consent_revision) or is_nil(consent_revision)) do
    revision = instant(updated)
    {output, truncated?} = if keep?, do: output(output), else: {nil, false}

    %__MODULE__{
      source_kind: "schedule_occurrence",
      source_id: occurrence_id,
      source_revision: revision,
      athanor_id: athanor_id,
      kind: "schedule_outcome",
      snapshot: %{
        "output" => output,
        "truncated" => truncated?,
        "sources" => if(keep?, do: stored_sources(sources)),
        "keep_outcome" => keep?,
        "note_name" => if(keep?, do: note_name(note_name)),
        "schedule_revision" => revision,
        "schedule_id" => schedule_id,
        "profile_id" => profile_id,
        "consent_revision" => consent_revision,
        "occurrence_id" => occurrence_id,
        "execution_id" => Map.get(occurrence, :execution_id),
        "scheduled_for" => instant(Map.fetch!(occurrence, :scheduled_for)),
        "note_revision_read" => revision_read(Map.get(occurrence, :note_revision_read))
      }
    }
  end

  @doc """
  The pair a schedule's stored metadata states, `{keep_outcome,
  note_name}`: whether its outcome is kept and under which note name
  (nil for the schedule's id), the pair a `schedule_outcome` snapshot
  copies. Absent, empty or not a JSON object is `{false, nil}`, and so is
  any `keep_outcome` but `true`; JSON that does not decode is
  `{:error, :invalid_json}`.
  """
  @spec keep_pair(term()) :: {:ok, {boolean(), String.t() | nil}} | {:error, :invalid_json}
  def keep_pair(metadata) do
    with {:ok, stored} <- stored_metadata(metadata) do
      case stored do
        %{"keep_outcome" => true} = wants -> {:ok, {true, note_name(wants["note_name"])}}
        _ -> {:ok, {false, nil}}
      end
    end
  end

  defp stored_metadata(%{} = decoded), do: {:ok, decoded}
  defp stored_metadata(nil), do: {:ok, %{}}
  defp stored_metadata(""), do: {:ok, %{}}

  defp stored_metadata(json) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:ok, %{}}
      {:error, :invalid_json} -> {:error, :invalid_json}
    end
  end

  defp stored_metadata(_other), do: {:ok, %{}}

  @doc "Which source, at which revision, `record` is about."
  @spec source(t()) :: source()
  def source(%__MODULE__{} = record),
    do: Map.take(record, [:source_kind, :source_id, :source_revision])

  @doc """
  The revision a `schedule_outcome` snapshot says its run read the note
  at, or `:absent` for a run that read none.
  """
  @spec note_revision_read(t()) :: non_neg_integer() | :absent
  def note_revision_read(%__MODULE__{snapshot: %{"note_revision_read" => read}})
      when is_integer(read) and read >= 0,
      do: read

  def note_revision_read(%__MODULE__{}), do: :absent

  @doc """
  The sources a `schedule_outcome` snapshot records for its kept output
  (`Prima.Source`). A snapshot that records none it can read is one
  unnamed outside source, never none: provenance that cannot be read is
  not the athanor's own.
  """
  @spec sources(t()) :: [Prima.Source.t()]
  def sources(%__MODULE__{snapshot: %{"sources" => sources}}) when is_list(sources),
    do: sources |> Enum.map(&Prima.Source.from_json/1) |> Prima.Source.set()

  def sources(%__MODULE__{}), do: [Prima.Source.outside(nil)]

  @doc "The snapshot as the canonical JSON text it is stored as."
  @spec encode_snapshot(t()) :: {:ok, String.t()} | {:error, :unencodable}
  def encode_snapshot(%__MODULE__{snapshot: snapshot}) when is_map(snapshot) do
    # JCS has no null: a field with no value is left out, and reads back
    # as nil.
    case snapshot |> Map.reject(fn {_key, value} -> is_nil(value) end) |> Prima.JCS.encode() do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, :unencodable}
    end
  end

  @doc """
  The record a stored row holds: its key columns and its snapshot text.
  A row whose kind is not one of `kinds/0` or whose snapshot is not a
  JSON object is `{:error, :unreadable}`.
  """
  @spec from_stored(map()) :: {:ok, t()} | {:error, :unreadable}
  def from_stored(%{
        source_kind: source_kind,
        source_id: source_id,
        source_revision: source_revision,
        athanor_id: athanor_id,
        kind: kind,
        snapshot: text
      })
      when kind in @kinds and source_kind in @source_kinds and is_binary(text) do
    case Prima.Json.decode(text) do
      {:ok, %{} = snapshot} ->
        {:ok,
         %__MODULE__{
           source_kind: source_kind,
           source_id: source_id,
           source_revision: source_revision,
           athanor_id: athanor_id,
           kind: kind,
           snapshot: snapshot
         }}

      _ ->
        {:error, :unreadable}
    end
  end

  def from_stored(_row), do: {:error, :unreadable}

  defp revision_read(read) when is_integer(read) and read >= 0, do: read
  defp revision_read(nil), do: "absent"

  # A source's canonical object without the name it does not carry: JCS
  # has no null, and `Prima.Source.from_json/1` reads an absent name as
  # none.
  defp stored_sources(sources) do
    for json <- Prima.Source.to_json_list(sources),
        do: Map.reject(json, fn {_key, value} -> is_nil(value) end)
  end

  defp note_name(name) when is_binary(name) and name != "", do: name
  defp note_name(_), do: nil

  defp instant(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp output(nil), do: {nil, false}
  defp output(text) when is_binary(text), do: cap(text)
  defp output(value), do: value |> Prima.Json.safe_encode() |> cap()

  defp cap(text) when byte_size(text) <= @max_output_bytes, do: {text, false}
  defp cap(text), do: {whole(binary_part(text, 0, @max_output_bytes)), true}

  defp whole(bin) do
    if String.valid?(bin), do: bin, else: whole(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
