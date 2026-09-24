# SPDX-License-Identifier: FSL-1.1-Apache-2.0
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

  @doc "The athanor id `local/0` contexts carry."
  def athanor_id, do: @athanor_id

  @doc """
  Insert the well-known test athanor rows (idempotent). Called from each
  app's `test_helper.exs` after the migrations ran, before ExUnit starts.

  The roster is `Arca.Test.Actor`'s: an `athanors` row is the persistence
  layer's, and both suites name the same ids.
  """
  defdelegate seed_athanors!(), to: Arca.Test.Actor

  @doc "Two contexts working in different athanors."
  @spec two_contexts() :: {Context.t(), Context.t()}
  def two_contexts do
    {context_in("ath_a", "user_a"), context_in("ath_b", "user_b")}
  end

  defp context_in(athanor_id, user_id) do
    Context.build(
      user_id: user_id,
      namespace: user_id,
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
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
  (override via `:sanctum, :default_test_namespace`), working in the
  `"ath_test"` athanor.

  Impersonates a logged-in user (`auth_method: :oidc`) so tests exercise
  the same authorization path production does.
  Use this in tests, factories and fixtures.
  """
  def local do
    ns = Application.get_env(:sanctum, :default_test_namespace, "testns")

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
  The generations the context's person and athanor stand at, read from
  their rows (`Sanctum.Tenancy.generation_snapshot/2`): what a fixture
  that builds an issuing context by hand passes as `generation_snapshot:`
  to `Sanctum.Session.create/2` or `Sanctum.ApiKey.create/3`. The
  issuance still locks and rereads both rows.
  """
  def snapshot!(%Context{user_id: user_id, athanor_id: athanor_id}) do
    {:ok, snapshot} = Sanctum.Tenancy.generation_snapshot(user_id, athanor_id)
    snapshot
  end

  @doc """
  `Sanctum.Session.create/2` for a context a fixture built by hand, with
  the `generation_snapshot:` its rows stand at now (`snapshot!/1`).
  """
  def create_session(%Context{} = ctx),
    do: Sanctum.Session.create(ctx, generation_snapshot: snapshot!(ctx))

  @doc """
  `Sanctum.ApiKey.create/3` for a context a fixture built by hand, with
  the `generation_snapshot:` its rows stand at now (`snapshot!/1`).
  """
  def create_key(%Context{} = ctx, attrs),
    do: Sanctum.ApiKey.create(ctx, attrs, generation_snapshot: snapshot!(ctx))

  @doc """
  The context as an issuer: its identity signed in (`person!/2`) unless it
  already names a person, the test athanor's row present when it works
  there, the person seated in the athanor it works in, and the binding an
  admitted sign-in carries (`t:Sanctum.Context.credential_binding/0`,
  `source_kind: :identity`, focused through that seat) stamped from
  `snapshot!/1` — the suite's one hand-bound issuer, for the tests that
  issue through a tool rather than by calling the issuer.
  """
  def issuer!(%Context{} = ctx, attrs \\ %{}) do
    ctx =
      if Prima.PersonId.person?(ctx.user_id),
        do: ctx,
        else: ctx |> person!(attrs) |> elem(0)

    if ctx.athanor_id == @athanor_id, do: athanor!()
    snapshot = snapshot!(ctx)

    %{
      ctx
      | credential_binding: %{
          source_kind: :identity,
          source_id: nil,
          focus_basis: seat!(ctx),
          user_generation: snapshot.user_generation,
          athanor_generation: snapshot.athanor_generation
        }
    }
  end

  defp seat!(%Context{athanor_id: nil}), do: nil

  defp seat!(%Context{user_id: user_id, athanor_id: athanor_id}) do
    {:ok, seat} =
      Sanctum.Tenancy.Members.ensure(user_id, scope: "athanor", athanor_id: athanor_id)

    seat.id
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
