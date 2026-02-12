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

      iex> ctx = Sanctum.Context.local()
      iex> {:ok, session} = Emissary.MCP.Session.create(ctx)
      iex> session.context.user_id
      "local_user"
      iex> String.starts_with?(session.id, "sess_")
      true

  """

  alias Emissary.UUID7
  alias Sanctum.Context

  @type t :: %__MODULE__{
          id: String.t(),
          context: Context.t(),
          capabilities: map(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  defstruct [:id, :context, :capabilities, :created_at, :expires_at]

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
  """
  def hydrate(session_id, %Context{} = context, capabilities \\ %{}, opts \\ []) do
    transport = Keyword.get(opts, :transport, :http)

    session = %__MODULE__{
      id: session_id,
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
