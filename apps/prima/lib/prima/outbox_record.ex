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

  `crew_request` is a hand-off to a crew member (`crew_request/1`): its
  source is the request row (`message`), its revision the row's
  insertion instant, and its snapshot holds `room_thread_id` (the thread
  that asks), `request_id` (the request row), `member` (the crew member
  asked), `task`, `tools` (the tool names the hand-off narrows the job
  to; absent for the whole arsenal), `options` (the brain options set
  for the job, an object), `person_id` and `origin` (whose request it is
  and how it started, `Prima.Origin`'s spelling).

  `crew_reply` is the answer of a crew member's turn (`crew_reply/1`):
  its source is the child turn (`turn`), its revision the turn's
  terminal instant, and its snapshot holds `asking_thread_id`,
  `request_ids` (the opening request and every request steered into the
  turn), `member`, `outcome` (one of `reply_outcomes/0`), `text` (the
  final text, cut to `max_reply_bytes/0` on a character boundary with
  `truncated` set; the rest stays on the turn), `person_id` and `origin`.

  A record's snapshot is canonical JSON text (`Prima.JCS`): the record
  as stored is the record as recorded, byte for byte. A field with no
  value is left out of the text and reads back as nil.
  """

  @kinds ~w(schedule_outcome crew_request crew_reply)
  @source_kinds ~w(schedule_occurrence message turn)
  @max_output_bytes 64 * 1024
  # A reply is delivered as a message to the asking thread, so it is cut
  # to the one bound every message passes (`Aqua.Runner.Admission`).
  @max_reply_bytes 32 * 1024
  @reply_outcomes ~w(done failed cancelled uncertain needs_you)
  @origins Prima.Origin.values()

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

  @doc "The cap on a `crew_reply` snapshot's `text`, in bytes."
  @spec max_reply_bytes() :: pos_integer()
  def max_reply_bytes, do: @max_reply_bytes

  @doc "The outcomes a `crew_reply` may carry, a closed roster."
  @spec reply_outcomes() :: [String.t()]
  def reply_outcomes, do: @reply_outcomes

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
  The record of a hand-off to a crew member, from what the request's
  transaction wrote: `athanor_id`, the request row's `request_id` and
  `inserted_at`, `room_thread_id`, `member`, `task`, `tools` (nil for
  the whole arsenal), `options`, `person_id` and `origin`.
  """
  @spec crew_request(map()) :: t()
  def crew_request(%{
        athanor_id: athanor_id,
        request_id: request_id,
        inserted_at: %DateTime{} = inserted_at,
        room_thread_id: room_thread_id,
        member: member,
        task: task,
        tools: tools,
        options: options,
        person_id: person_id,
        origin: origin
      })
      when is_binary(athanor_id) and athanor_id != "" and is_binary(request_id) and
             request_id != "" and is_binary(room_thread_id) and room_thread_id != "" and
             is_binary(member) and member != "" and is_binary(task) and task != "" and
             (is_nil(tools) or is_list(tools)) and is_map(options) and is_binary(person_id) and
             person_id != "" and origin in @origins do
    names!(tools || [], "tools")

    %__MODULE__{
      source_kind: "message",
      source_id: request_id,
      source_revision: instant(inserted_at),
      athanor_id: athanor_id,
      kind: "crew_request",
      snapshot: %{
        "room_thread_id" => room_thread_id,
        "request_id" => request_id,
        "member" => member,
        "task" => task,
        "tools" => tools,
        "options" => options,
        "person_id" => person_id,
        "origin" => Prima.Origin.to_wire(origin)
      }
    }
  end

  @doc """
  The record of a crew member's turn ending, from what its terminal
  transaction read: `athanor_id`, the turn's `turn_id` and `ended_at`,
  its reply address (`asking_thread_id`, `request_ids`), `member`,
  `outcome` (one of `reply_outcomes/0`), the final `text`, `person_id`
  and `origin`; a `needs_you` record also names the card's `approval_id`,
  which the notice it becomes is resolved with.
  """
  @spec crew_reply(map()) :: t()
  def crew_reply(
        %{
          athanor_id: athanor_id,
          turn_id: turn_id,
          ended_at: %DateTime{} = ended_at,
          asking_thread_id: asking_thread_id,
          request_ids: [_ | _] = request_ids,
          member: member,
          outcome: outcome,
          text: text,
          person_id: person_id,
          origin: origin
        } = attrs
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and turn_id != "" and
             is_binary(asking_thread_id) and asking_thread_id != "" and is_binary(member) and
             member != "" and outcome in @reply_outcomes and is_binary(text) and
             is_binary(person_id) and person_id != "" and origin in @origins do
    names!(request_ids, "request_ids")
    {text, truncated?} = cap(text, @max_reply_bytes)

    %__MODULE__{
      source_kind: "turn",
      source_id: turn_id,
      source_revision: instant(ended_at),
      athanor_id: athanor_id,
      kind: "crew_reply",
      snapshot:
        %{
          "asking_thread_id" => asking_thread_id,
          "request_ids" => request_ids,
          "member" => member,
          "outcome" => outcome,
          "text" => text,
          "truncated" => truncated?,
          "person_id" => person_id,
          "origin" => Prima.Origin.to_wire(origin)
        }
        |> card(outcome, Map.get(attrs, :approval_id))
    }
  end

  defp card(snapshot, "needs_you", approval_id) when is_binary(approval_id) and approval_id != "",
    do: Map.put(snapshot, "approval_id", approval_id)

  defp card(snapshot, _outcome, _approval_id), do: snapshot

  defp names!(names, member) do
    unless Enum.all?(names, &(is_binary(&1) and &1 != "")),
      do: raise(ArgumentError, "a crew record's #{member} are non-empty strings")

    :ok
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
  defp output(text) when is_binary(text), do: cap(text, @max_output_bytes)
  defp output(value), do: value |> Prima.Json.safe_encode() |> cap(@max_output_bytes)

  defp cap(text, max) when byte_size(text) <= max, do: {text, false}
  defp cap(text, max), do: {whole(binary_part(text, 0, max)), true}

  defp whole(bin) do
    if String.valid?(bin), do: bin, else: whole(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
