# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.AquaTool do
  @moduledoc """
  The `aqua` tool as a test calls it: through the gate on `ctx`'s
  external plane, its answer deep-stringified, as the Aqua page reads it
  (`PrismWeb.AquaLive.Section.call_aqua/2`).
  """

  @doc "Call the `aqua` tool and answer its result with string keys."
  @spec call(Sanctum.Context.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(ctx, args) do
    case Sanctum.Gate.call_external("aqua", ctx, args) do
      {:ok, result} -> {:ok, stringify(result)}
      other -> other
    end
  end

  @doc """
  Switch `key` of Aqua's list as the Aqua page's switch does, on when it
  is off and off when it is on, granting nothing: what Aqua and its crew
  members may use moves past Aqua's grant.
  """
  @spec switch!(Sanctum.Context.t(), String.t()) :: :ok
  def switch!(ctx, key) do
    {:ok, %{agent: %{tools: tools}}} = Compendium.agent_snapshot(ctx, Prima.AgentRef.soul_name())
    edit = if key in tools, do: "tools_remove", else: "tools_add"
    {:ok, _} = call(ctx, %{"action" => "update", "name" => "aqua", edit => [key]})
    :ok
  end

  @doc """
  Aqua's grant under `label` revoked by its person, as `profile.revoke`
  takes it from them.
  """
  @spec revoke!(Sanctum.Context.t(), String.t()) :: :ok
  def revoke!(ctx, label \\ "default") do
    {:ok, profiles} = Sanctum.Consent.profiles(ctx, Prima.AgentRef.soul_ref())
    %{id: id} = Enum.find(profiles, &(&1.label == label and &1.status != :revoked))

    {:ok, %{status: "revoked"}} =
      Sanctum.Providers.Profile.handle(ctx, %{"action" => "revoke", "profile_id" => id})

    :ok
  end

  @doc "Aqua's grant given by its person under `label`, through the consent walk."
  @spec grant!(Sanctum.Context.t(), String.t()) :: :ok
  def grant!(ctx, label \\ "default") do
    ref = Prima.AgentRef.soul_ref()
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref, label: label})
    decisions = %{ref: ref, label: label, selections: []}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    :ok
  end

  @doc """
  Every grant of Aqua's still standing taken by a removal, as the removal
  of its component's last version takes them, never by its person.
  """
  @spec remove!(Sanctum.Context.t()) :: :ok
  def remove!(ctx) do
    {:ok, %{revoked: [_ | _]}} = Sanctum.Consent.revoke_source(ctx, Prima.AgentRef.soul_ref())
    :ok
  end

  @doc """
  Aqua's grant revoked by its person, given again, then taken by a
  removal: no grant stands, and the last to end was the removal's.
  """
  @spec revoked_then_removed!(Sanctum.Context.t()) :: :ok
  def revoked_then_removed!(ctx) do
    :ok = revoke!(ctx)
    :ok = grant!(ctx)
    remove!(ctx)
  end

  @doc """
  Aqua's grant revoked by its person, then given again under two labels:
  two grants stand, an ambiguity a turn refuses, never an absence.
  """
  @spec revoked_then_two_standing!(Sanctum.Context.t()) :: :ok
  def revoked_then_two_standing!(ctx) do
    :ok = revoke!(ctx)
    :ok = grant!(ctx)
    grant!(ctx, "work")
  end

  @doc """
  Aqua's grant revoked by its person, its row then damaged past the
  profile vocabulary (a kind no profile has): the grant a turn reads,
  standing rows alone, is absent, and why it is absent cannot be read.
  """
  @spec revoked_then_unreadable!(Sanctum.Context.t()) :: :ok
  def revoked_then_unreadable!(ctx) do
    require Ecto.Query
    athanor = ctx.athanor_id
    {:ok, [%{id: id}]} = Sanctum.Consent.profiles(ctx, Prima.AgentRef.soul_ref())
    :ok = revoke!(ctx)

    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^athanor and p.id == ^id
        ),
        set: [kind: "sideways"]
      )

    :ok
  end

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
