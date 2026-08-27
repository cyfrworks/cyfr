# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Compiled only in :test (and :dev to keep IEx playable). The production
# release MUST NOT contain this module — Sanctum.TestContext.local/0
# synthesises a permissive single-user Context with namespace `"testns"`,
# which would violate the "every authenticated user has a real claimed
# namespace" invariant if reachable from production code paths.
#
# Cross-app sharing rationale: lives in cyfr/lib/ rather than
# apps/cyfr/test/support/ so opus, locus, and add-on tests can call
# `Sanctum.TestContext.local/0` without each app maintaining its own copy.
# The compile-time guard is the safety mechanism, not the directory.
if Mix.env() in [:test, :dev] do
  defmodule Sanctum.TestContext do
    @moduledoc """
    Test/dev-only Context helpers. Not compiled into `:prod`.

    Production code must build contexts via `Sanctum.Context.build/1`
    (with a real namespace claimed via cyfr.run) or use
    `Sanctum.system_context/0` for platform-scope tasks.
    """

    alias Sanctum.Context

    # The athanor every permissive test context works in. Tenant rows carry
    # no foreign key, so most fixtures need no row; the standing-channel
    # gates (API keys, webhooks, schedules) do read the athanor's status, so
    # the suite seeds the well-known test athanors once (`seed_athanors!/0`)
    # and `athanor!/0` returns this one.
    @athanor_id "ath_test"

    # The athanor ids test fixtures name by hand. Seeded once per test run,
    # outside any sandbox, so every context that names one works against a
    # real (active) row.
    @well_known [
      {"ath_test", "test"},
      {"ath_a", "ath-a"},
      {"ath_b", "ath-b"},
      {"ath_acme", "ath-acme"},
      {"ath_other", "ath-other"},
      {"ath_1", "ath-1"},
      {"ath_alpha", "ath-alpha"},
      {"ath_x", "ath-x"},
      {"ath_evt_x", "ath-evt-x"},
      {"ath_o", "ath-o"},
      {"ath_o1", "ath-o1"},
      {"ath_gamma", "ath-gamma"},
      {"ath_myorg", "ath-myorg"},
      {"ath_reg", "ath-reg"},
      {"ath_scaffold", "ath-scaffold"},
      {"ath_stub", "ath-stub"},
      {"ath_sweep", "ath-sweep"}
    ]

    @doc "The athanor id `local/0` contexts carry."
    def athanor_id, do: @athanor_id

    @doc """
    Insert the well-known test athanor rows (idempotent). Called from each
    app's `test_helper.exs` after the migrations ran, before ExUnit starts.
    """
    def seed_athanors! do
      # Outside the sandbox: the rows must be committed and visible to every
      # test's connection, and the pool may already be in manual mode when a
      # second app's helper runs in the same BEAM.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fn ->
        for {id, slug} <- @well_known do
          case Sanctum.Tenancy.Athanors.get(id) do
            {:ok, _} ->
              :ok

            {:error, :not_found} ->
              {:ok, _} =
                Sanctum.Tenancy.Athanors.create(%{
                  id: id,
                  kind: "group",
                  name: "Test #{slug}",
                  slug: slug,
                  created_by: "system"
                })
          end
        end
      end)

      :ok
    end

    @doc """
    Ensure the athanor row behind `local/0` exists and return it.
    """
    def athanor! do
      case Sanctum.Tenancy.Athanors.get(@athanor_id) do
        {:ok, athanor} ->
          athanor

        {:error, :not_found} ->
          {:ok, athanor} =
            Sanctum.Tenancy.Athanors.create(%{
              id: @athanor_id,
              kind: "group",
              name: "Test",
              slug: "test",
              created_by: "system"
            })

          athanor
      end
    end

    @doc """
    Build a permissive single-user test Context with namespace `"testns"`
    (override via `:cyfr, :default_test_namespace`), working in the
    `"ath_test"` athanor.

    Impersonates a logged-in user (`auth_method: :oidc`) so tests exercise
    the same authorization path production does.
    Use this in tests, factories, fixtures, and IEx sessions.
    """
    def local do
      ns = Application.get_env(:cyfr, :default_test_namespace, "testns")

      Context.build(
        user_id: "local|local|#{ns}",
        provider: "local",
        namespace: ns,
        athanor_id: @athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )
    end

    @doc """
    Build a platform-scope test Context through the one sanctioned
    construction path (`Sanctum.Context.internal/1`) — `build/1` refuses
    `scope: :platform` from anywhere else.

    Defaults are `internal/1`'s (`user_id: "system"`, `auth_method: :system`,
    the four system permissions); fixtures that need the wildcard pass
    `permissions: [:*]`, and `platform_admin: true` marks the operator
    capability on the returned struct.
    """
    def platform(opts \\ []) do
      {admin?, opts} = Keyword.pop(opts, :platform_admin, false)
      ctx = Context.internal(opts)
      %{ctx | platform_admin: admin? == true}
    end
  end
end
