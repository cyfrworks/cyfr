# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Question do
  @moduledoc """
  One run's ask about one action its component declares, keyed by the
  asking attempt and the ask's number in the run (`ask_no`). The row is
  written with its first state and the state only ever leaves `open`:
  `allowed` or `denied` by a person (`decided_by`) or by a standing answer
  (`standing_answer_id`), `none` with its reason, or `ended` by the write
  that ended its run. `Arca.Questions` is its store; `Sanctum.Questions`
  its only reader.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:ref, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @states ~w(open allowed denied none ended)
  @none_reasons ~w(unattended invalid unavailable)
  @digest ~r/\A[0-9a-f]{64}\z/
  @ref ~r/\A[A-Za-z0-9_-]{1,64}\z/

  schema "questions" do
    field :athanor_id, :string
    field :user_id, :string
    field :execution_id, :string
    field :attempt_id, :string
    field :root_execution_id, :string
    field :ask_no, :integer
    field :request_digest, :string
    field :component_ref, :string
    field :release_digest, :string
    field :action, :string
    field :title, :string
    field :summary, :string
    field :operation, :string
    field :masked, :boolean
    field :caller, :string
    field :deadline, :utc_datetime_usec
    field :state, :string
    field :none_reason, :string
    field :decided_by, :string
    field :standing_answer_id, :string
    field :decided_at, :utc_datetime_usec
  end

  @fields [
    :ref,
    :athanor_id,
    :user_id,
    :execution_id,
    :attempt_id,
    :root_execution_id,
    :ask_no,
    :request_digest,
    :component_ref,
    :release_digest,
    :action,
    :title,
    :summary,
    :operation,
    :masked,
    :caller,
    :deadline,
    :state,
    :none_reason,
    :standing_answer_id,
    :decided_at
  ]

  @required @fields -- [:none_reason, :standing_answer_id, :decided_at]

  @doc "Every state a question can carry."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Why a question was answered `none`."
  @spec none_reasons() :: [String.t()]
  def none_reasons, do: @none_reasons

  @doc """
  The row an admission writes: every column present but who decided it,
  the first state any but `ended`, a reason exactly when the state is
  `none`, a standing answer only beside `allowed` or `denied`, a URL-safe
  ref of at most 64 characters, a positive ask number, both digests
  lowercase SHA-256 hexadecimal, and a caller's text
  (`Prima.Question.Caller`).
  """
  @spec admit_changeset(map()) :: Ecto.Changeset.t()
  def admit_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@required)
    |> validate_format(:ref, @ref)
    |> validate_number(:ask_no, greater_than: 0)
    |> validate_format(:request_digest, @digest)
    |> validate_format(:release_digest, @digest)
    |> validate_inclusion(:state, @states -- ["ended"])
    |> validate_reason()
    |> validate_standing()
    |> validate_change(:caller, fn :caller, text ->
      case Prima.Question.Caller.decode(text) do
        {:ok, _caller} -> []
        {:error, _} -> [caller: "names no caller"]
      end
    end)
    |> unique_constraint([:athanor_id, :attempt_id, :ask_no],
      name: :questions_athanor_id_attempt_id_ask_no_index
    )
  end

  defp validate_reason(changeset) do
    case {get_field(changeset, :state), get_field(changeset, :none_reason)} do
      {"none", reason} when reason in @none_reasons -> changeset
      {"none", _} -> add_error(changeset, :none_reason, "names why no answer was given")
      {_state, nil} -> changeset
      {_state, _reason} -> add_error(changeset, :none_reason, "is only a none's")
    end
  end

  defp validate_standing(changeset) do
    case {get_field(changeset, :state), get_field(changeset, :standing_answer_id)} do
      {_state, nil} -> changeset
      {state, _id} when state in ["allowed", "denied"] -> changeset
      _ -> add_error(changeset, :standing_answer_id, "names the answer that decided it")
    end
  end
end
