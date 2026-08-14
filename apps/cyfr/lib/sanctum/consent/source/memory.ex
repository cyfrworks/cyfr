# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Source.Memory do
  @moduledoc """
  In-memory consent source for tests.

  Holds profiles and head consents keyed by tenant, seeded per test. Not
  supervised in production — a test starts it (`start_supervised!`) and the
  tenant keying keeps concurrently seeded fixtures apart.
  """

  @behaviour Sanctum.Consent.Source

  use GenServer

  alias Sanctum.Context

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Seed a profile (RootSelect summary shape) for a tenant."
  @spec put_profile(Context.t(), map()) :: :ok
  def put_profile(%Context{} = ctx, profile) do
    GenServer.call(__MODULE__, {:put_profile, tenant(ctx), profile})
  end

  @doc "Seed the head consent for a profile id."
  @spec put_head_consent(Context.t(), String.t(), Sanctum.Consent.Source.consent()) :: :ok
  def put_head_consent(%Context{} = ctx, profile_id, consent) do
    GenServer.call(__MODULE__, {:put_head, tenant(ctx), profile_id, consent})
  end

  @doc "Drop everything — test isolation between cases sharing the server."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # An unstarted server means no fixtures were seeded: no profiles, no
  # heads. Tests that never touch consent then get empty results instead
  # of crashing into a missing GenServer.
  @impl Sanctum.Consent.Source
  def profiles(%Context{} = ctx, source_ref) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:profiles, tenant(ctx), source_ref})
    else
      {:ok, []}
    end
  end

  @impl Sanctum.Consent.Source
  def head_consent(%Context{} = ctx, profile_id) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:head_consent, tenant(ctx), profile_id})
    else
      {:error, :not_found}
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{profiles: %{}, heads: %{}}}

  @impl GenServer
  def handle_call({:put_profile, tenant, profile}, _from, state) do
    key = {tenant, profile.source_ref}
    existing = Map.get(state.profiles, key, [])
    kept = Enum.reject(existing, &(&1.id == profile.id))
    {:reply, :ok, put_in(state.profiles[key], kept ++ [profile])}
  end

  def handle_call({:put_head, tenant, profile_id, consent}, _from, state) do
    {:reply, :ok, put_in(state.heads[{tenant, profile_id}], consent)}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{profiles: %{}, heads: %{}}}
  end

  def handle_call({:profiles, tenant, source_ref}, _from, state) do
    {:reply, {:ok, Map.get(state.profiles, {tenant, source_ref}, [])}, state}
  end

  def handle_call({:head_consent, tenant, profile_id}, _from, state) do
    case Map.fetch(state.heads, {tenant, profile_id}) do
      {:ok, consent} -> {:reply, {:ok, consent}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  defp tenant(%Context{org_id: org_id, project_id: project_id}), do: {org_id, project_id}
end
