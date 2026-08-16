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

    # The athanor every permissive test context works in. No row is needed
    # for tenant-scoped storage or queries (there is no foreign key on tenant
    # rows); `athanor!/0` inserts one for tests that read the athanor itself.
    @athanor_id "ath_test"

    @doc "The athanor id `local/0` contexts carry."
    def athanor_id, do: @athanor_id

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
  end
end
