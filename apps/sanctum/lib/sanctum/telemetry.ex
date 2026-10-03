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
  @caller_invalidated_event [:cyfr, :sanctum, :caller, :invalidated]
  @session_created_event [:cyfr, :sanctum, :session, :created]
  @sessions_revoked_event [:cyfr, :sanctum, :sessions, :revoked]
  @membership_event [:cyfr, :sanctum, :membership, :changed]
  @vault_entry_event [:cyfr, :sanctum, :vault, :entry_changed]
  @athanor_archived_event [:cyfr, :sanctum, :athanor, :archived]
  @api_keys_event [:cyfr, :sanctum, :api_keys, :changed]
  @webhooks_event [:cyfr, :sanctum, :webhooks, :changed]

  # A remote identity's head as this home reads it from its directory.
  @identity_not_descendant_event [:cyfr, :sanctum, :identity, :not_descendant]
  @identity_stale_event [:cyfr, :sanctum, :identity, :stale]

  # A pending confirmation's lifecycle, one event per kind.
  @confirmation_events %{
    opened: [:cyfr, :sanctum, :confirmation, :opened],
    confirmed: [:cyfr, :sanctum, :confirmation, :confirmed],
    consumed: [:cyfr, :sanctum, :confirmation, :consumed],
    cancelled: [:cyfr, :sanctum, :confirmation, :cancelled],
    voided: [:cyfr, :sanctum, :confirmation, :voided],
    expired: [:cyfr, :sanctum, :confirmation, :expired]
  }

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

  Audits every platform-context construction, and nothing else: its one
  emitter is the platform-scope constructor's gate in
  `Sanctum.Context.build/1`. `metadata.sanctioned` is true for
  `Sanctum.Context.internal/1` and `Sanctum.system_context/0`; an
  unauthorized `Context.build/1` emits false before raising. A platform
  context is built for platform-scope operations. A person's platform
  capability never enters an athanor: `Sanctum.Context.focus/2` admits a
  seat alone, and a person's focus, an operator's included, builds no
  platform context and emits nothing here. An internal system context
  that works in an athanor is built for its task or narrowed by
  `Sanctum.Context.refocus/2` for `auth_method: :system`.

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

  @doc """
  The established-context memo of one session row key is no longer good.

  What travels is the session row's key — its SHA-256, which is what the
  sessions table is addressed by — and never the token itself. Every
  member drops the memos it holds for that key; the one that announced
  has already dropped its own, synchronously, before this fires.
  """
  @spec caller_invalidated(binary()) :: :ok
  def caller_invalidated(hash) when is_binary(hash),
    do: :telemetry.execute(@caller_invalidated_event, %{count: 1}, %{hash: hash})

  @doc "A session was minted. No token travels — a subscriber adopts its own."
  @spec session_created() :: :ok
  def session_created, do: :telemetry.execute(@session_created_event, %{count: 1}, %{})

  @doc "Every session of `user_id` was retired; their sockets must let go."
  @spec sessions_revoked(String.t()) :: :ok
  def sessions_revoked(user_id),
    do: :telemetry.execute(@sessions_revoked_event, %{count: 1}, %{user_id: user_id})

  @doc "One person's seat in one athanor changed — which athanors they may now reach."
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

  @doc """
  The directory `directory` served a log of `identifier` that does not
  contain the head this home verified before: the cache was left as it
  was and the head was refused. An honest directory's log only grows, so
  this is evidence about the directory, kept on the audit trail.
  """
  @spec identity_not_descendant(String.t(), String.t()) :: :ok
  def identity_not_descendant(identifier, directory)
      when is_binary(identifier) and is_binary(directory) do
    :telemetry.execute(@identity_not_descendant_event, %{count: 1}, %{
      identifier: identifier,
      directory: directory
    })
  end

  @doc """
  `identifier`'s head is past its freshness bound, `bound_seconds`, and
  its directory (`directory`, nil when this home has no locator for it)
  could not refresh it: that person's protected work here pauses. No
  person, token or key is named.
  """
  @spec identity_stale(String.t(), String.t() | nil, pos_integer()) :: :ok
  def identity_stale(identifier, directory, bound_seconds)
      when is_binary(identifier) and is_integer(bound_seconds) do
    :telemetry.execute(@identity_stale_event, %{count: 1}, %{
      identifier: identifier,
      directory: directory,
      bound_seconds: bound_seconds
    })
  end

  @typedoc "What happened to a pending confirmation."
  @type confirmation_kind :: :opened | :confirmed | :consumed | :cancelled | :voided | :expired

  @doc """
  The pending-confirmation lifecycle's announcement: the confirmation
  `ref` (`Prima.Confirmation.ref/1`) of `user_id` in `athanor_id`, for the
  operation it confirms (`tool.action`), was opened, confirmed, consumed,
  cancelled, voided or expired. Emits `[:cyfr, :sanctum, :confirmation,
  kind]` with the athanor, the person, the ref, the operation and the
  expiry, and nothing else: never the secret the asking request holds,
  the change's arguments or its preview, which a client reads under its
  own session. The host's bridge carries it to the person's own clients.
  """
  @spec confirmation(confirmation_kind(), String.t(), String.t(), %{
          ref: String.t(),
          operation: String.t(),
          expires_at: DateTime.t()
        }) :: :ok
  def confirmation(kind, athanor_id, user_id, %{
        ref: ref,
        operation: operation,
        expires_at: %DateTime{} = expires_at
      })
      when is_map_key(@confirmation_events, kind) and is_binary(athanor_id) and
             is_binary(user_id) and is_binary(ref) and is_binary(operation) do
    :telemetry.execute(Map.fetch!(@confirmation_events, kind), %{count: 1}, %{
      athanor_id: athanor_id,
      user_id: user_id,
      ref: ref,
      operation: operation,
      expires_at: expires_at
    })
  end
end
