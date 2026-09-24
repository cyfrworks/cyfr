# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Progress do
  @moduledoc """
  One step of a long-running piece of work — a build, a registration, a
  pull or publish — on `Cyfr.Bus.progress/2`. The same struct rides the
  subject's own topic and, when the work runs for an MCP request, that
  request's topic, where the transport renders it as
  `notifications/progress`.

  `subject` names the work; its kind is this struct's closed union.
  `request_id` is the request the work runs for, when it runs for one.
  `data` carries the step's own fields (a pull's reference, a push's
  digest), plain values only. Progress is display state: a subscriber
  whose mailbox is backed up has it dropped and counted
  (`Cyfr.Bus.BoundedDispatcher`), never queued without bound.
  """

  alias Cyfr.Bus.Payload

  @kinds [:build, :register, :pull]
  @fields [:request_id, :phase, :message, :data, :at]

  @enforce_keys [:athanor_id, :subject]
  defstruct [:athanor_id, :subject | @fields]

  @type kind :: :build | :register | :pull

  @type t :: %__MODULE__{
          athanor_id: String.t(),
          subject: {kind(), String.t()},
          request_id: String.t() | nil,
          phase: atom() | String.t() | nil,
          message: String.t() | nil,
          data: map() | nil,
          at: String.t() | nil
        }

  @doc "The closed union of the work a progress step names."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  A step of `subject`'s work in `actor`'s athanor. `at` defaults to now.
  A subject kind outside `kinds/0`, an empty subject id or a field this
  struct does not declare raises.
  """
  @spec new(Prima.Actor.t(), {kind(), String.t()}, map() | keyword()) :: t()
  def new(%Prima.Actor{} = actor, {kind, id}, fields \\ %{}) when is_binary(id) and id != "" do
    fields = Map.new(fields) |> Map.put_new_lazy(:at, &now/0)

    Payload.build(__MODULE__, @fields, fields, %{
      athanor_id: Payload.athanor!(actor),
      subject: {Payload.kind!(__MODULE__, kind, @kinds), id}
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
