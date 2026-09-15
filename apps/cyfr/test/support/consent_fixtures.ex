# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.ConsentFixtures do
  @moduledoc """
  Seeds the in-memory consent source with a bindable owner profile so tests
  can create profile-bound registrations (webhooks, schedules) without
  walking the full consent sheet, and connects a key to a component through
  the full walk (`bind_key!/4`).

  `bindable_profile/3` requires `Sanctum.Consent.Source.Memory` to be
  running — add `start_supervised!(Sanctum.Consent.Source.Memory)` to the
  test's setup (idempotent via `start_source!/0` below).
  """

  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @doc """
  Start the in-memory consent source if this test hasn't already.

  Safe to call from any setup block; uses `ExUnit.Callbacks.start_supervised/2`
  under the hood so the server is torn down with the test.
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

  The profile is keyed at name level (binding authorizes against the
  registration's own target), and the consent is a minimal open_inert
  versionless head — enough for `RegistrationBinding.authorize/3` to pass
  for an interactive (oidc) context.
  """
  def bindable_profile(%Context{} = ctx, target_ref, opts \\ []) do
    {:ok, name_ref} = Cyfr.ComponentRef.to_name_ref(target_ref)
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
        # Derived, never a literal: `Consent.Loader` refuses a row whose
        # stored digest does not match its policy bytes, so a fixture that
        # hardcoded one would drift the moment the policy changed.
        blob_digest: Cyfr.JCS.hash_binary("{}"),
        resolved_policy: "{}",
        activation: %{name_ref => "sha256:act"},
        vault_refs: []
      })

    profile_id
  end

  @doc """
  Connect a key to `ref` as a person does: a new vault entry holding
  `fields`, bound to the component's `api_key` need through the consent
  walk (plan, preview, commit) under the profile `opts[:label]` (default
  `"default"`). The durable consent source must be the configured one.
  Answers the entry.
  """
  def bind_key!(%Context{} = ctx, ref, fields, opts \\ []) when is_map(fields) do
    label = Keyword.get(opts, :label, "default")

    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: Keyword.get(opts, :name, "key #{System.unique_integer([:positive])}"),
        kind: "api_key",
        fields: fields
      })

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref, label: label})
    decisions = %{ref: ref, label: label, bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    entry
  end
end
