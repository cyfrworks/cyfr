# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TestContext do
  @moduledoc """
  Permissive Context helpers for the suite. It lives in `test/support`,
  which only `MIX_ENV=test` compiles, so no other build holds it.

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
  Mark `athanor_id` filled — what a test says when it drives a turn —
  with the shipped AQUA tree and bundle copied in, as a fill copies
  them, so the estate has a soul to answer with.

  A turn pins the baseline consent provisioning mints, so an estate a
  test chats in is one that has been set up. Left off by default: the
  seeded rows are bare estates, as a fresh server's are, and a
  server-wide sweep must not find work on every one of them.
  """
  def provisioned!(athanor_id) when is_binary(athanor_id) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(athanor_id)
    shipped!(athanor_id)

    case athanor.provisioned_at do
      nil ->
        {:ok, filled} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
        filled

      _ ->
        athanor
    end
  end

  @doc """
  Copy every shipped unit the estate lacks into `athanor_id` — the
  shipped AQUA tree and the bundle — without marking it provisioned.
  """
  def shipped!(athanor_id) when is_binary(athanor_id) do
    ctx = Sanctum.internal_context(user_id: "_seed", athanor_id: athanor_id, scope: :athanor)

    for root <- Arca.Storage.overlay_roots() do
      {:ok, _copied} = Arca.Overlay.materialize_shipped(Sanctum.Context.actor(ctx), root)
    end

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
  Use this in tests, factories and fixtures.
  """
  def local do
    ns = Application.get_env(:cyfr, :default_test_namespace, "testns")

    Context.build(
      user_id: "local|local|#{ns}",
      provider: "local",
      namespace: ns,
      athanor_id: @athanor_id,
      permissions: Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  @doc """
  The context's identity signed in: the `users` row minted (or found)
  for `ctx.user_id` read as an IdP identity key, and the context re-named
  by the person's own id — what every request carries after admission.
  Returns the context and the row.
  """
  def person!(%Context{} = ctx, attrs \\ %{}) do
    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(
        Map.merge(
          %{
            id: ctx.user_id,
            provider: ctx.provider || "local",
            email: ctx.email,
            verified: true
          },
          attrs
        )
      )

    {%{ctx | user_id: user.id}, user}
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
