# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Notify do
  @moduledoc """
  What a person's tray shows: members joining or leaving, invites,
  allowlist requests, executions finishing, approvals waiting and
  schedules failing — about one athanor, or, for its operators, about the
  server.

  This module owns the vocabulary (`t:kind/0`, `kinds/0`) and the
  announcements; it names no topic and never broadcasts. A foundation
  below the host emits `:telemetry` (`[:cyfr, :sanctum, :notify]`) and the
  host's bridge is the one place that becomes a bus message, so a tray
  update travels the same path as every other standing change.
  """

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

  @doc "The tray's closed vocabulary, in the order `t:kind/0` names it."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Announce an event about one athanor."
  @spec broadcast(String.t(), kind(), map()) :: :ok
  def broadcast(athanor_id, kind, payload \\ %{})
      when is_binary(athanor_id) and is_atom(kind) and is_map(payload),
      do: Sanctum.Telemetry.notify(athanor_id, kind, payload)

  @doc "Announce a server-level event to platform admins."
  @spec broadcast_platform(kind(), map()) :: :ok
  def broadcast_platform(kind, payload \\ %{}) when is_atom(kind) and is_map(payload),
    do: Sanctum.Telemetry.notify(nil, kind, payload)

  @doc false
  def member_changed(athanor_id), do: broadcast(athanor_id, :member_changed)

  @doc false
  def allowlist_request(email), do: broadcast_platform(:allowlist_request, %{email: email})

  @doc "The door's list changed (an allow, deny, remove or resolve): operators re-read it."
  def allowlist_changed, do: broadcast_platform(:allowlist_changed)
end
