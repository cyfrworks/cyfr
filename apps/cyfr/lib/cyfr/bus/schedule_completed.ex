# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.ScheduleCompleted do
  @moduledoc """
  A schedule's occurrence completed, on the global
  `Cyfr.Bus.schedule_completions/0`, published by the member that ran it
  only after the occurrence's close and the schedule's run record
  committed, and only while that member still held its slot.

  `issuer_member` is the slot the publishing member held
  (`Arca.ControlPlane.held/0`: its node, its boot and its generation), or
  nil where no claimant runs. A subscriber on every member hears every
  completion; only the one whose own slot is the issuer acts on it, so
  delivery to peers creates no second write.

  `output` is the run's output — already masked by the close that
  answered it — only when the schedule asked to keep its outcome
  (`keep_outcome`), JSON-encoded when it is not a string, and cut to
  64 KiB on a character boundary with `truncated` set.
  """

  alias Cyfr.Bus.Payload

  @kinds [:completed]
  @max_output_bytes 64 * 1024

  @enforce_keys [:kind, :athanor_id, :actor, :schedule_id, :execution_id]
  defstruct [
    :kind,
    :athanor_id,
    :actor,
    :issuer_member,
    :schedule_id,
    :execution_id,
    :occurrence_id,
    :completed_at,
    :note_name,
    :output,
    keep_outcome: false,
    truncated: false
  ]

  @type kind :: :completed

  @type issuer :: %{node: String.t(), owner: String.t(), generation: pos_integer()} | nil

  @type t :: %__MODULE__{
          kind: kind(),
          athanor_id: String.t(),
          actor: Cyfr.Actor.t(),
          issuer_member: issuer(),
          schedule_id: String.t(),
          execution_id: String.t(),
          occurrence_id: String.t() | nil,
          completed_at: DateTime.t() | nil,
          keep_outcome: boolean(),
          note_name: String.t() | nil,
          output: String.t() | nil,
          truncated: boolean()
        }

  @doc "The closed union: the occurrence completed."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The cap on `output`, in bytes."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc """
  The completion run for `actor`, whose athanor it names. `fields` carries
  `issuer_member`, `schedule_id`, `execution_id`, `occurrence_id`,
  `completed_at`, `keep_outcome`, `note_name` and the raw `output`, which
  is kept, encoded and capped as the module doc says.
  """
  @spec new(Cyfr.Actor.t(), map()) :: t()
  def new(%Cyfr.Actor{} = actor, %{schedule_id: schedule_id, execution_id: execution_id} = fields)
      when is_binary(schedule_id) and is_binary(execution_id) do
    keep? = Map.get(fields, :keep_outcome) == true
    {output, truncated?} = if keep?, do: output(Map.get(fields, :output)), else: {nil, false}

    %__MODULE__{
      kind: Payload.kind!(__MODULE__, :completed, @kinds),
      athanor_id: Payload.athanor!(actor),
      actor: actor,
      issuer_member: issuer(Map.get(fields, :issuer_member)),
      schedule_id: schedule_id,
      execution_id: execution_id,
      occurrence_id: Map.get(fields, :occurrence_id),
      completed_at: Map.get(fields, :completed_at),
      keep_outcome: keep?,
      note_name: note_name(Map.get(fields, :note_name)),
      output: output,
      truncated: truncated?
    }
  end

  @doc """
  The issuer a slot answers, taken the same way on both sides: the
  node, boot and generation of `Arca.ControlPlane.held/0`'s slot, or nil
  when it answers `:none`.
  """
  @spec issuer({:ok, map()} | :none | map() | nil) :: issuer()
  def issuer({:ok, slot}), do: issuer(slot)
  def issuer(:none), do: nil
  def issuer(nil), do: nil

  def issuer(%{node: node, owner: owner, generation: generation}),
    do: %{node: node, owner: owner, generation: generation}

  defp note_name(name) when is_binary(name) and name != "", do: name
  defp note_name(_), do: nil

  defp output(nil), do: {nil, false}
  defp output(text) when is_binary(text), do: Payload.cap(text, @max_output_bytes)
  defp output(value), do: value |> Cyfr.Json.safe_encode() |> Payload.cap(@max_output_bytes)
end
