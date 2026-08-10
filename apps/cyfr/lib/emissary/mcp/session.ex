# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Session do
  @moduledoc """
  MCP session lifecycle management.

  Sessions track:
  - Session ID (`sess_<uuid7>` format, time-ordered)
  - Associated Sanctum context (user identity, permissions)
  - Negotiated capabilities
  - Expiration time

  Sessions are stored in Arca.Cache for fast access and automatic cleanup.

  ## Telemetry Events

  - `[:cyfr, :emissary, :session]` - Emitted on session create/terminate
    - Measurements: `%{count: 1}`
    - Metadata: `%{lifecycle: :created | :terminated, transport: :http | :sse}`

  ## Examples

      iex> ctx = Sanctum.TestContext.local()
      iex> {:ok, session} = Emissary.MCP.Session.create(ctx)
      iex> session.context.namespace
      "testns"
      iex> String.starts_with?(session.id, "sess_")
      true

  """

  alias Emissary.UUID7
  alias Sanctum.Context

  @type t :: %__MODULE__{
          id: String.t(),
          sanctum_token: String.t() | nil,
          context: Context.t(),
          capabilities: map(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  # `sanctum_token` is a live bearer credential and this struct is stored in a
  # `:public` ETS table, so it travels through plugs, crash reports and error
  # terms that end up stringified into logs. Keep it out of every `inspect/1`.
  @derive {Inspect, except: [:sanctum_token]}
  defstruct [:id, :sanctum_token, :context, :capabilities, :created_at, :expires_at]

  @default_ttl_hours 24
  @ttl_ms :timer.hours(@default_ttl_hours)

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new session for the given context.

  Returns `{:ok, session}` with a time-ordered `sess_<uuid7>` session ID.

  Emits telemetry event `[:cyfr, :emissary, :session]` with `lifecycle: :created`.
  """
  def create(%Context{} = context, capabilities \\ %{}, opts \\ []) do
    transport = Keyword.get(opts, :transport, :http)

    session = %__MODULE__{
      id: generate_session_id(),
      context: context,
      capabilities: capabilities,
      created_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), @default_ttl_hours, :hour)
    }

    Arca.Cache.put({:session, session.id}, session, @ttl_ms)

    :telemetry.execute(
      [:cyfr, :emissary, :session],
      %{count: 1},
      %{lifecycle: :created, transport: transport, session_id: session.id}
    )

    {:ok, session}
  end

  @doc """
  Hydrate a session from an existing ID (e.g., a persistent Sanctum token).

  Unlike create/3, this uses the provided ID instead of generating a new one.
  The `sanctum_token` field is set to the session ID itself, since hydrated
  sessions are backed by a real Sanctum token in the database.
  """
  def hydrate(session_id, %Context{} = context, capabilities \\ %{}, opts \\ []) do
    transport = Keyword.get(opts, :transport, :http)

    session = %__MODULE__{
      id: session_id,
      sanctum_token: session_id,
      context: context,
      capabilities: capabilities,
      created_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), @default_ttl_hours, :hour)
    }

    Arca.Cache.put({:session, session.id}, session, @ttl_ms)

    :telemetry.execute(
      [:cyfr, :emissary, :session],
      %{count: 1},
      %{lifecycle: :hydrated, transport: transport, session_id: session.id}
    )

    {:ok, session}
  end

  @doc """
  Create an ephemeral session for API key authentication.

  Unlike `create/3`, this session is NOT stored in Arca.Cache and exists only
  for the lifetime of the request. No telemetry is emitted.

  The session ID uses an `"ephemeral_"` prefix to distinguish from persisted
  `"sess_"` sessions in logs.
  """
  def ephemeral(%Context{} = context) do
    %__MODULE__{
      id: "ephemeral_" <> UUID7.generate(),
      context: context,
      capabilities: %{},
      created_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now()
    }
  end

  @doc """
  Build an uncached session whose id is derived from the caller's credential.

  A bearer-authenticated request establishes no session, but two requests from
  the same caller still need a shared key: `POST /mcp` starts a build while
  `GET /mcp` streams its progress, and the progress buffer is keyed by
  `context.session_id`. A per-request id would break that correlation.

  The id is a SHA-256 of the credential, so it is stable for a caller, opaque,
  and not reversible into the credential. That also fixes an older leak: the
  hydration path this replaces used the caller's **raw** session token as the
  session id, which `mcp_logs.session_id` then persisted verbatim.

  This exists to keep the standalone progress stream working while it is on its
  way out; request-scoped progress on the originating response stream removes
  the need for a shared key entirely.
  """
  @spec for_credential(Context.t(), String.t()) :: t()
  def for_credential(%Context{} = context, credential) when is_binary(credential) do
    digest =
      :crypto.hash(:sha256, credential)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 32)

    %__MODULE__{
      id: "cred_" <> digest,
      context: context,
      capabilities: %{},
      created_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now()
    }
  end

  @doc """
  Get a session by ID.

  Returns `{:ok, session}` if found and not expired, `{:error, :not_found}` otherwise.
  """
  def get(session_id) when is_binary(session_id) do
    case Arca.Cache.get({:session, session_id}) do
      {:ok, session} ->
        {:ok, session}

      :miss ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if a session exists and is valid.
  """
  def exists?(session_id) when is_binary(session_id) do
    case get(session_id) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Terminate a session.

  Emits telemetry event `[:cyfr, :emissary, :session]` with `lifecycle: :terminated`.
  """
  def terminate(session_id) when is_binary(session_id) do
    Arca.Cache.invalidate({:session, session_id})

    :telemetry.execute(
      [:cyfr, :emissary, :session],
      %{count: 1},
      %{lifecycle: :terminated, session_id: session_id}
    )

    :ok
  end

  @doc """
  Invalidate a session when the security context changes.

  Must be called when org_id or project_id changes to prevent cross-tenant
  session reuse. The caller should create a new session with the updated context.

  Returns `:ok` always. Emits telemetry with `lifecycle: :context_invalidated`.
  """
  def invalidate_on_context_change(session_id, reason \\ "context_changed")
      when is_binary(session_id) do
    Arca.Cache.invalidate({:session, session_id})

    :telemetry.execute(
      [:cyfr, :emissary, :session],
      %{count: 1},
      %{lifecycle: :context_invalidated, session_id: session_id, reason: reason}
    )

    :ok
  end

  @doc """
  Update session capabilities (called after initialization handshake).
  """
  def update_capabilities(session_id, capabilities) when is_binary(session_id) do
    case get(session_id) do
      {:ok, session} ->
        updated = %{session | capabilities: capabilities}
        Arca.Cache.put({:session, session_id}, updated, @ttl_ms)
        {:ok, updated}

      error ->
        error
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_session_id do
    UUID7.session_id()
  end
end
