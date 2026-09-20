# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Telemetry do
  @moduledoc """
  Telemetry events for Sanctum.

  ## Events

  - `[:cyfr, :sanctum, :auth]` - Authentication events
    - Measurements: `%{count: 1}`
    - Metadata: `%{provider: atom(), outcome: :success | :failure}`

  - `[:cyfr, :sanctum, :platform_context]` - Platform-scope context built
    - Measurements: `%{count: 1}`
    - Metadata: `%{user_id, auth_method, namespace, sanctioned: boolean(), caller}`

  ## Usage

  Attach a handler to receive events:

      :telemetry.attach(
        "my-handler",
        [:cyfr, :sanctum, :auth],
        &MyModule.handle_event/4,
        nil
      )

  ## Example Event Flow

      # Successful GitHub auth
      Sanctum.Telemetry.auth_event(:github, :success)
      # => Emits [:cyfr, :sanctum, :auth] with %{provider: :github, outcome: :success}

      # Failed auth with reason
      Sanctum.Telemetry.auth_event(:github, :failure, %{reason: :invalid_token})
      # => Emits [:cyfr, :sanctum, :auth] with %{provider: :github, outcome: :failure, reason: :invalid_token}
  """

  @auth_event [:cyfr, :sanctum, :auth]
  @platform_context_event [:cyfr, :sanctum, :platform_context]

  # The standing changes this domain announces. Sanctum never broadcasts:
  # a foundation below the host emits telemetry, and the host's bridge is
  # the one place an event becomes a bus message
  # (`Cyfr.Telemetry.Catalog` lists each with its consumer).
  @notify_event [:cyfr, :sanctum, :notify]
  @session_created_event [:cyfr, :sanctum, :session, :created]
  @sessions_revoked_event [:cyfr, :sanctum, :sessions, :revoked]
  @membership_event [:cyfr, :sanctum, :membership, :changed]
  @vault_entry_event [:cyfr, :sanctum, :vault, :entry_changed]
  @athanor_archived_event [:cyfr, :sanctum, :athanor, :archived]
  @api_keys_event [:cyfr, :sanctum, :api_keys, :changed]
  @webhooks_event [:cyfr, :sanctum, :webhooks, :changed]

  @doc """
  Emit an authentication event.

  ## Parameters

  - `provider` - Authentication provider (e.g., `:github`, `:google`, `:oidc`, `:api_key`)
  - `outcome` - Result of authentication (`:success` or `:failure`)
  - `metadata` - Additional metadata map (optional)

  ## Examples

      # Successful auth
      Sanctum.Telemetry.auth_event(:github, :success)

      # Failed auth with reason
      Sanctum.Telemetry.auth_event(:github, :failure, %{reason: :invalid_credentials})
  """
  @spec auth_event(atom(), :success | :failure, map()) :: :ok
  def auth_event(provider, outcome, metadata \\ %{}) when outcome in [:success, :failure] do
    :telemetry.execute(
      @auth_event,
      %{count: 1},
      Map.merge(%{provider: provider, outcome: outcome}, metadata)
    )
  end

  @doc """
  Emit a platform-context construction event.

  Audits every platform-context construction. `metadata.sanctioned` is true
  for `Sanctum.Context.internal/1` and `Sanctum.system_context/0`; an
  unauthorized `Context.build/1` emits false before raising.

  Emits `[:cyfr, :sanctum, :platform_context]`.
  """
  @spec platform_context_event(map()) :: :ok
  def platform_context_event(metadata) when is_map(metadata) do
    :telemetry.execute(@platform_context_event, %{count: 1}, metadata)
  end

  @doc """
  Something happened in an athanor that its members' trays show, or —
  with `athanor_id: nil` — something server-level its operators do.
  `kind` and `payload` are `Sanctum.Notify`'s vocabulary.
  """
  @spec notify(String.t() | nil, atom(), map()) :: :ok
  def notify(athanor_id, kind, payload) when is_atom(kind) and is_map(payload) do
    :telemetry.execute(@notify_event, %{count: 1}, %{
      athanor_id: athanor_id,
      kind: kind,
      payload: payload
    })
  end

  @doc "A session was minted. No token travels — a subscriber adopts its own."
  @spec session_created() :: :ok
  def session_created, do: :telemetry.execute(@session_created_event, %{count: 1}, %{})

  @doc "Every session of `user_id` was retired; their sockets must let go."
  @spec sessions_revoked(String.t()) :: :ok
  def sessions_revoked(user_id),
    do: :telemetry.execute(@sessions_revoked_event, %{count: 1}, %{user_id: user_id})

  @doc "One person's seat in one athanor changed — which estates they may now reach."
  @spec membership_changed(String.t(), String.t() | nil, term()) :: :ok
  def membership_changed(user_id, athanor_id, change) when is_binary(user_id) do
    :telemetry.execute(@membership_event, %{count: 1}, %{
      user_id: user_id,
      athanor_id: athanor_id,
      change: change
    })
  end

  @doc """
  A vault entry of `athanor_id` changed. `meta` carries the entry's
  `name` for every verb — a deleted row can no longer be read for it —
  and `old_name` too on a rename.
  """
  @spec vault_entry_changed(String.t(), String.t(), atom() | String.t(), map()) :: :ok
  def vault_entry_changed(athanor_id, entry_id, verb, meta) when is_map(meta) do
    :telemetry.execute(@vault_entry_event, %{count: 1}, %{
      athanor_id: athanor_id,
      entry_id: entry_id,
      verb: verb,
      meta: meta
    })
  end

  @doc """
  An athanor was archived: whatever serves it from outside any tenant
  topic must stop. Announced after the archive's own synchronous work —
  the credentials revoked, the caller memos dropped — so nothing reads
  this as permission to keep going.
  """
  @spec athanor_archived(String.t()) :: :ok
  def athanor_archived(athanor_id) when is_binary(athanor_id),
    do: :telemetry.execute(@athanor_archived_event, %{count: 1}, %{athanor_id: athanor_id})

  @doc "The API key rows of `athanor_id` changed; readers re-read them."
  @spec api_keys_changed(String.t()) :: :ok
  def api_keys_changed(athanor_id) when is_binary(athanor_id),
    do: :telemetry.execute(@api_keys_event, %{count: 1}, %{athanor_id: athanor_id})

  @doc "The webhook rows of `athanor_id` changed; readers re-read them."
  @spec webhooks_changed(String.t()) :: :ok
  def webhooks_changed(athanor_id) when is_binary(athanor_id),
    do: :telemetry.execute(@webhooks_event, %{count: 1}, %{athanor_id: athanor_id})
end
