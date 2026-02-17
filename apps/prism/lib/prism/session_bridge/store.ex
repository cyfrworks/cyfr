defmodule Prism.SessionBridge.Store do
  @moduledoc """
  In-memory store for session tokens created by the CLI.

  Subscribes to `sanctum:sessions` PubSub topic and holds session
  tokens in GenServer state so that `SessionBridge.load_token/0` can
  auto-detect them without reading config files from disk.

  ## Security properties

  - Tokens are encrypted on the PubSub wire using Phoenix.Token
  - Tokens are held in GenServer state (private, not in ETS)
  - Access is serialized through GenServer.call (no public table)
  - Tokens are single-use (deleted after consumption)
  - Tokens expire after 30 seconds as a safety net
  """

  use GenServer
  require Logger

  @ttl_ms :timer.seconds(30)
  @session_topic "sanctum:sessions"
  @token_salt "session_bridge_store"

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Consume the most recent bridged token, if any.

  Returns `{:ok, token}` and removes it from the store (single-use),
  or `:error` if no bridged token is available.
  """
  @spec consume :: {:ok, String.t()} | :error
  def consume do
    GenServer.call(__MODULE__, :consume)
  end

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Emissary.PubSub, @session_topic)
    {:ok, %{tokens: []}}
  end

  @impl true
  def handle_call(:consume, _from, state) do
    now = System.monotonic_time(:millisecond)

    valid =
      state.tokens
      |> Enum.filter(fn {_sealed, inserted_at} -> now - inserted_at < @ttl_ms end)
      |> Enum.sort_by(fn {_sealed, inserted_at} -> inserted_at end, :desc)

    case valid do
      [] ->
        {:reply, :error, %{state | tokens: []}}

      [{sealed, _inserted_at} | rest] ->
        case unseal(sealed) do
          {:ok, token} ->
            {:reply, {:ok, token}, %{state | tokens: rest}}

          :error ->
            Logger.warning("[SessionBridge.Store] Failed to unseal bridge token")
            {:reply, :error, %{state | tokens: rest}}
        end
    end
  end

  @impl true
  def handle_info({:session_created, sealed_token}, state) when is_binary(sealed_token) do
    entry = {sealed_token, System.monotonic_time(:millisecond)}
    Logger.debug("[SessionBridge.Store] Cached new session token for browser pickup")
    {:noreply, %{state | tokens: [entry | state.tokens]}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Sealing / Unsealing
  # ============================================================================

  @doc false
  def seal(token) when is_binary(token) do
    Phoenix.Token.sign(PrismWeb.Endpoint, @token_salt, token)
  end

  defp unseal(sealed) do
    case Phoenix.Token.verify(PrismWeb.Endpoint, @token_salt, sealed, max_age: div(@ttl_ms, 1000)) do
      {:ok, token} -> {:ok, token}
      {:error, _} -> :error
    end
  end
end
