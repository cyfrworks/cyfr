# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Test.ConsentFixtures do
  @moduledoc """
  Seeds the in-memory consent source with a bindable owner profile so opus
  tests can create profile-bound registrations (schedules) without walking
  the full consent sheet. Mirrors `Sanctum.Test.ConsentFixtures`, which is
  compiled only into the cyfr suite.
  """

  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @doc """
  Start the in-memory consent source if this test hasn't already.
  """
  def start_source! do
    case Process.whereis(Source.Memory) do
      nil ->
        {:ok, _} = ExUnit.Callbacks.start_supervised(Source.Memory)
        :ok

      _pid ->
        :ok
    end
  end

  @doc """
  Seed an active owner profile + head consent for `target_ref` in the
  context's tenant and return its profile id.
  """
  def bindable_profile(%Context{} = ctx, target_ref, opts \\ []) do
    {:ok, name_ref} = Sanctum.ComponentRef.to_name_ref(target_ref)
    profile_id = opts[:profile_id] || "prof-#{System.unique_integer([:positive])}"

    :ok =
      Source.Memory.put_profile(ctx, %{
        id: profile_id,
        kind: :owner,
        source_ref: name_ref,
        label: "default",
        status: :active
      })

    :ok =
      Source.Memory.put_head_consent(ctx, profile_id, %{
        id: "consent-#{profile_id}",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-#{profile_id}",
        commit_digest: "sha256:commit-#{profile_id}",
        resolved_policy: "{}",
        activation: %{name_ref => "sha256:act"},
        vault_refs: []
      })

    profile_id
  end
end
