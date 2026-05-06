defmodule Cyfr.PersonalSlugCache do
  @moduledoc """
  ETS cache for `PrismWeb.AuthHelpers.personal_namespace_slug/1` results.

  The slug is consulted on every authenticated LiveView mount via `LiveAuth`,
  so the underlying `CredentialStore.list_for_user/2` (which does a secret
  list + per-credential decode) was running on every sidebar click. This
  cache mirrors `EmissaryWeb.Plugs.PersonalNamespaceCache` (30s TTL, ETS
  owned by a supervised GenServer) and stores the slug value (or `nil` for
  "not claimed").
  """

  use GenServer

  @table :cyfr_personal_slug_cache
  @ttl_ms 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Read cached slug for `user_id`. Returns `{:hit, slug_or_nil}` or `:miss`."
  @spec fetch(String.t()) :: {:hit, String.t() | nil} | :miss
  def fetch(user_id) when is_binary(user_id) do
    ensure_table()

    case :ets.lookup(@table, user_id) do
      [{_, slug, stored_ms}] ->
        if System.monotonic_time(:millisecond) - stored_ms < @ttl_ms,
          do: {:hit, slug},
          else: :miss

      [] ->
        :miss
    end
  end

  @doc "Cache a slug (or `nil` for unclaimed) for `user_id`."
  @spec put(String.t(), String.t() | nil) :: :ok
  def put(user_id, slug) when is_binary(user_id) do
    ensure_table()
    :ets.insert(@table, {user_id, slug, System.monotonic_time(:millisecond)})
    :ok
  end

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end
end
