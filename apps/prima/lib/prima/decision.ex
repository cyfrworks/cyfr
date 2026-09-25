# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Decision do
  @moduledoc """
  One admission decision: a call the gate admitted or refused, and later,
  separately, how the admitted work ended.

  `call_id` names the call and is unique; `parent_call_id` is the call that
  admitted the execution this call runs under, nil at a root; `request_id`
  is the transport's correlation id, which every call of one chain shares.
  `user_id` and `athanor_id` attribute it, and a decision refused before
  any caller was established has neither. `plane` is the call's:
  `:external` for every ingress, `:in_chain` for a call a running chain
  makes. `tool` and `action` name the operation; `inserted_at` is when the
  gate decided.

  `admission` is `:admitted | :refused`. A refused decision carries
  `refusal_class`, one of `Prima.Refusal.classes/0`, and `reason`, the
  rostered reason rendered as a sentence for an operator — never an
  `inspect/1` of a private term. An appended decision is the admission by
  definition, so there is no stage here: a refusal made while the work ran
  is the completion's, not the admission's.

  The completion is separate: `completion` is
  `:succeeded | :failed | :cancelled | :uncertain`, `completion_class` the
  class of a failure, `completed_at` and `duration_ms` when it ended and
  how long it ran. A decision with no completion has an unknown outcome,
  never a success, and a failed execution never rewrites its admission as
  a refusal.
  """

  @enforce_keys [:call_id, :plane, :admission, :inserted_at]
  defstruct [
    :call_id,
    :parent_call_id,
    :request_id,
    :user_id,
    :athanor_id,
    :plane,
    :tool,
    :action,
    :inserted_at,
    :admission,
    :refusal_class,
    :reason,
    :completion,
    :completion_class,
    :completed_at,
    :duration_ms
  ]

  @type plane :: :external | :in_chain
  @type admission :: :admitted | :refused
  @type completion :: :succeeded | :failed | :cancelled | :uncertain

  @typedoc """
  How the admitted work ended, as `finish` records it: the outcome, the
  class of a failure (nil for a success), and when and after how long.
  """
  @type completion_record :: %{
          required(:completion) => completion(),
          optional(:completion_class) => Prima.Refusal.class() | nil,
          optional(:completed_at) => DateTime.t(),
          optional(:duration_ms) => non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          call_id: String.t(),
          parent_call_id: String.t() | nil,
          request_id: String.t() | nil,
          user_id: String.t() | nil,
          athanor_id: String.t() | nil,
          plane: plane(),
          tool: String.t() | nil,
          action: String.t() | nil,
          inserted_at: DateTime.t(),
          admission: admission(),
          refusal_class: Prima.Refusal.class() | nil,
          reason: String.t() | nil,
          completion: completion() | nil,
          completion_class: Prima.Refusal.class() | nil,
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @planes [:external, :in_chain]
  @admissions [:admitted, :refused]
  @completions [:succeeded, :failed, :cancelled, :uncertain]

  # The fields the admission is: what an append writes and what an
  # identical repeat of it must match.
  @admission_fields [
    :call_id,
    :parent_call_id,
    :request_id,
    :user_id,
    :athanor_id,
    :plane,
    :tool,
    :action,
    :inserted_at,
    :admission,
    :refusal_class,
    :reason
  ]

  @doc "Every plane a decision is made on."
  @spec planes() :: [plane()]
  def planes, do: @planes

  @doc "Every admission outcome."
  @spec admissions() :: [admission()]
  def admissions, do: @admissions

  @doc "Every completion outcome."
  @spec completions() :: [completion()]
  def completions, do: @completions

  @doc "The fields an admission consists of, which an append writes."
  @spec admission_fields() :: [atom()]
  def admission_fields, do: @admission_fields

  @doc """
  A decision from `fields`. `:inserted_at` is the caller's: this module
  reads no clock (`Prima.UUID7.generate/0` is the contracts' one reader).
  Raises `ArgumentError` for a shape outside the vocabulary: an unknown
  plane or admission, a refusal without a class or with one outside
  `Prima.Refusal.classes/0`, an admission with one, a missing call id or
  a missing time.
  """
  @spec new(keyword() | map()) :: t()
  def new(fields) when is_list(fields) or is_map(fields) do
    fields = Map.new(fields)

    decision =
      struct(
        %__MODULE__{call_id: nil, plane: nil, admission: nil, inserted_at: nil},
        fields
      )

    unknown = Map.keys(fields) -- Map.keys(Map.from_struct(decision))

    cond do
      unknown != [] ->
        raise ArgumentError, "invalid decision: unknown fields #{inspect(unknown)}"

      true ->
        case validate(decision) do
          :ok -> decision
          {:error, why} -> raise ArgumentError, "invalid decision: #{why}"
        end
    end
  end

  @doc """
  Whether `decision` is an admission in the vocabulary: `:ok`, or
  `{:error, why}` naming the first field that is not.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = d) do
    cond do
      not (is_binary(d.call_id) and d.call_id != "") ->
        {:error, "call_id must be a string"}

      d.plane not in @planes ->
        {:error, "plane must be one of #{inspect(@planes)}"}

      d.admission not in @admissions ->
        {:error, "admission must be one of #{inspect(@admissions)}"}

      not match?(%DateTime{}, d.inserted_at) ->
        {:error, "inserted_at must be a DateTime"}

      d.admission == :refused and not class?(d.refusal_class) ->
        {:error, "a refusal names its class"}

      d.admission == :admitted and not is_nil(d.refusal_class) ->
        {:error, "an admission has no class"}

      true ->
        :ok
    end
  end

  @doc """
  Whether `record` is a completion in the vocabulary: `:ok`, or
  `{:error, why}`. A success carries no class; a failure carries one.
  """
  @spec validate_completion(map()) :: :ok | {:error, String.t()}
  def validate_completion(%{completion: completion} = record) do
    class = Map.get(record, :completion_class)
    duration = Map.get(record, :duration_ms)

    cond do
      completion not in @completions ->
        {:error, "completion must be one of #{inspect(@completions)}"}

      completion == :succeeded and not is_nil(class) ->
        {:error, "a success has no class"}

      completion == :failed and not class?(class) ->
        {:error, "a failure names its class"}

      not (is_nil(class) or class?(class)) ->
        {:error, "completion_class must be one of Prima.Refusal.classes/0"}

      not (is_nil(duration) or (is_integer(duration) and duration >= 0)) ->
        {:error, "duration_ms must be a non-negative integer"}

      not (is_nil(Map.get(record, :completed_at)) or match?(%DateTime{}, record.completed_at)) ->
        {:error, "completed_at must be a DateTime"}

      true ->
        :ok
    end
  end

  def validate_completion(_record), do: {:error, "completion is required"}

  defp class?(class), do: class in Prima.Refusal.classes()
end
