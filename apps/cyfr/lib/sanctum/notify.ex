# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Notify do
  @moduledoc """
  One fan-in topic per athanor for the things a person's tray shows:
  members joining or leaving, invites, allowlist requests, and (later)
  executions finishing and approvals waiting. Phoenix.PubSub has no
  wildcard, so a tray subscribes to `topic/1` for every athanor the person
  belongs to and to `platform_topic/0` when they are a platform admin.

  Messages: `{:notify, athanor_id | :platform, kind, payload}`.
  """

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

  @doc "The topic for one athanor."
  @spec topic(String.t()) :: String.t()
  def topic(athanor_id) when is_binary(athanor_id) and athanor_id != "",
    do: "tenant:#{athanor_id}:notify"

  @doc "The topic platform admins subscribe to for server-level events."
  @spec platform_topic() :: String.t()
  def platform_topic, do: "platform:notify"

  @doc "Broadcast an event about one athanor."
  @spec broadcast(String.t(), kind(), map()) :: :ok
  def broadcast(athanor_id, kind, payload \\ %{}) when is_atom(kind) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      topic(athanor_id),
      {:notify, athanor_id, kind, payload}
    )
  end

  @doc "Broadcast a server-level event to platform admins."
  @spec broadcast_platform(kind(), map()) :: :ok
  def broadcast_platform(kind, payload \\ %{}) when is_atom(kind) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      platform_topic(),
      {:notify, :platform, kind, payload}
    )
  end

  @doc false
  def member_changed(athanor_id), do: broadcast(athanor_id, :member_changed)

  @doc false
  def allowlist_request(email), do: broadcast_platform(:allowlist_request, %{email: email})

  @doc "The door's list changed (an allow, deny, remove or resolve): operators re-read it."
  def allowlist_changed, do: broadcast_platform(:allowlist_changed)
end
