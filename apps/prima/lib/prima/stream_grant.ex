# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.StreamGrant do
  @moduledoc """
  What the gate answers when it admits a stream open: the one grant under
  which continuous data flows to its holder without passing the gate again.

    * `topic` — the `Cyfr.Bus` roster key of the topic the grant admits,
      the stream's declared `topic` (`Prima.Provider.Stream`), never a
      scoped topic: the gate never names the bus. The delivery owner turns
      the key, the holder's tenant prefix and `subject` into the concrete
      topic (`Cyfr.Bus.granted_topic/2`) and subscribes to that alone.
    * `projection` — the payload fields forwarded to the holder, the
      stream's declared projection (`Prima.Provider.Stream`); nothing else
      of a payload leaves.
    * `subject` — the subject the grant was opened for, or `nil` for a
      stream that takes none.
    * `deadline` — when the grant ends: never later than the stream's
      `deadline_bound` from the open, nor the credential it was opened
      under.
    * `grant_id` — the grant's own identifier, which a holder names to
      close it and a revocation names to end it.
  """

  @type t :: %__MODULE__{
          topic: atom(),
          projection: [String.t()],
          subject: String.t() | nil,
          deadline: DateTime.t(),
          grant_id: String.t()
        }

  @enforce_keys [:topic, :projection, :subject, :deadline, :grant_id]
  defstruct [:topic, :projection, :subject, :deadline, :grant_id]

  @doc """
  The fields of `payload` the grant forwards: the projection's, by name,
  from a map with atom or string keys; a field the payload lacks is
  absent. The one place a grant's projection is applied.
  """
  @spec project(t(), map()) :: %{String.t() => term()}
  def project(%__MODULE__{projection: fields}, payload) when is_map(payload) do
    for field <- fields,
        {:ok, value} <- [fetch(payload, field)],
        into: %{},
        do: {field, value}
  end

  @doc "Whether the grant has ended at `now`."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{deadline: deadline}, %DateTime{} = now),
    do: DateTime.compare(now, deadline) != :lt

  defp fetch(payload, field) do
    case Map.fetch(payload, field) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        # Only an atom that already exists can key a struct or an atom map;
        # a field no module ever named cannot be in the payload.
        try do
          Map.fetch(payload, String.to_existing_atom(field))
        rescue
          ArgumentError -> :error
        end
    end
  end
end
