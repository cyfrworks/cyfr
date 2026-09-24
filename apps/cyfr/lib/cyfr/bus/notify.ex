# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.Notify do
  @moduledoc """
  What a person's tray shows, on an athanor's `Cyfr.Bus.notify/1` or, for
  a server-level event its operators see, on `Cyfr.Bus.platform_notify/0`
  with `athanor_id: :platform`.

  The kinds are the identity domain's tray vocabulary, pinned equal to it
  by test. The payload keeps only the keys below, and a `reason` is
  bounded (`Cyfr.Bus.bounded_reason/1`): a tray entry names what happened
  and where, never an arbitrary term.
  """

  alias Cyfr.Bus.Payload

  @kinds [
    :member_changed,
    :athanor_changed,
    :allowlist_request,
    :allowlist_changed,
    :execution_finished,
    :execution_failed,
    :approval_pending,
    :approval_resolved,
    :schedule_failed
  ]

  @payload_keys [
    :name,
    :email,
    :execution_id,
    :reference,
    :schedule_id,
    :reason,
    :thread_id,
    :message_id,
    :approval_id,
    :decision
  ]

  @enforce_keys [:athanor_id, :kind]
  defstruct [:athanor_id, :kind, payload: %{}]

  @type kind ::
          :member_changed
          | :athanor_changed
          | :allowlist_request
          | :allowlist_changed
          | :execution_finished
          | :execution_failed
          | :approval_pending
          | :approval_resolved
          | :schedule_failed

  @type t :: %__MODULE__{
          athanor_id: String.t() | :platform,
          kind: kind(),
          payload: %{optional(atom()) => term()}
        }

  @doc "The tray's closed vocabulary."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The payload keys a tray entry may carry."
  @spec payload_keys() :: [atom()]
  def payload_keys, do: @payload_keys

  @doc "A tray entry for `actor`'s athanor. A kind outside `kinds/0` raises."
  @spec new(Cyfr.Actor.t(), kind(), map()) :: t()
  def new(%Cyfr.Actor{} = actor, kind, payload \\ %{}) when is_map(payload) do
    %__MODULE__{
      athanor_id: Payload.athanor!(actor),
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      payload: payload(payload)
    }
  end

  @doc "A server-level entry for the operators. A kind outside `kinds/0` raises."
  @spec platform(kind(), map()) :: t()
  def platform(kind, payload \\ %{}) when is_map(payload) do
    %__MODULE__{
      athanor_id: :platform,
      kind: Payload.kind!(__MODULE__, kind, @kinds),
      payload: payload(payload)
    }
  end

  defp payload(payload) do
    payload
    |> Map.take(@payload_keys)
    |> then(fn kept ->
      if Map.has_key?(kept, :reason),
        do: Map.update!(kept, :reason, &Cyfr.Bus.bounded_reason/1),
        else: kept
    end)
  end
end
