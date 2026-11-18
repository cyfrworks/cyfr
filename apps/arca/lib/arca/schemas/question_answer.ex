# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.QuestionAnswer do
  @moduledoc """
  A person's standing answer to one action of one component, named by its
  publisher and name, for one caller's text (`Prima.Question.Caller`) or
  `any`: `allow` or `deny`, until a time or, with no `until`, always. The
  declaration's digest is the action's name and title it was given under,
  and `question_ref` the question it was given on, if any. The identity is
  the athanor, person, publisher, name, action and caller (`Arca.Questions`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @effects ~w(allow deny)
  @digest ~r/\A[0-9a-f]{64}\z/

  schema "question_answers" do
    field :athanor_id, :string
    field :user_id, :string
    field :publisher, :string
    field :name, :string
    field :action, :string
    field :declaration_digest, :string
    field :caller, :string
    field :effect, :string
    field :until, :utc_datetime_usec
    field :answered_at, :utc_datetime_usec
    field :question_ref, :string
  end

  @fields [
    :id,
    :athanor_id,
    :user_id,
    :publisher,
    :name,
    :action,
    :declaration_digest,
    :caller,
    :effect,
    :until,
    :answered_at,
    :question_ref
  ]

  @doc "The effects a standing answer may carry."
  @spec effects() :: [String.t()]
  def effects, do: @effects

  @doc """
  The row a write holds: every column but `until` and `question_ref`
  present, the effect in the vocabulary, the digest lowercase SHA-256
  hexadecimal and the caller `any` or a caller's text.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields -- [:until, :question_ref])
    |> validate_inclusion(:effect, @effects)
    |> validate_format(:declaration_digest, @digest)
    |> validate_change(:caller, fn :caller, caller ->
      if caller == Prima.Question.Caller.any() or match?({:ok, _}, decode(caller)),
        do: [],
        else: [caller: "names no caller"]
    end)
  end

  defp decode(nil), do: :error
  defp decode(text), do: Prima.Question.Caller.decode(text)
end
