# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.ContextPlaneTest do
  use ExUnit.Case, async: true

  alias Sanctum.Context

  # The D1 plane split, Context half: a context that has entered a guest
  # closure can never authorize an external-plane call — even with the :*
  # wildcard, which short-circuits every permission check. Every builder
  # defaults to :external; the guest plane is stamped one-way by
  # enter_guest/1 (Opus.Executor before a guest run, AquaLive before an
  # approved in-chain call).

  describe "defaults" do
    test "every construction path starts on the external plane" do
      assert Context.build(%{user_id: "u"}).plane == :external
      assert Context.build(user_id: "u").plane == :external
      assert Context.internal(user_id: "system").plane == :external
      assert Context.for_scheduled("u").plane == :external
      assert %Context{}.plane == :external
    end

    test "build/1 rejects unknown planes" do
      assert_raise ArgumentError, ~r/invalid plane/, fn ->
        Context.build(%{user_id: "u", plane: :internal})
      end

      assert_raise ArgumentError, ~r/invalid plane/, fn ->
        Context.build(%{user_id: "u", plane: "guest"})
      end
    end

    test "build/1 accepts explicit valid planes" do
      assert Context.build(%{user_id: "u", plane: :guest}).plane == :guest
      assert Context.build(%{user_id: "u", plane: :external}).plane == :external
    end
  end

  describe "enter_guest/1" do
    test "flips the plane and nothing else" do
      ctx = Context.build(%{user_id: "u", permissions: [:*], authenticated: true})
      guest = Context.enter_guest(ctx)

      assert guest.plane == :guest
      assert %{guest | plane: :external} == ctx
    end

    test "is idempotent and has no inverse" do
      guest = Context.enter_guest(Context.build(%{user_id: "u"}))
      assert Context.enter_guest(guest).plane == :guest
      refute function_exported?(Context, :leave_guest, 1)
      refute function_exported?(Context, :exit_guest, 1)
    end
  end

  describe "require_permission fails closed on the guest plane" do
    test "a wildcard admin context inside a guest closure authorizes nothing" do
      admin = Context.build(%{user_id: "u", permissions: [:*], authenticated: true})
      assert Context.require_permission(admin, :admin) == :ok

      guest = Context.enter_guest(admin)

      # The raw predicate still holds — it is the in-chain identity
      # conjunct — but the authorization gate does not.
      assert Context.has_permission?(guest, :admin)
      assert {:error, message} = Context.require_permission(guest, :admin)
      assert message =~ "guest-plane"
    end

    test "every permission is refused, not just wildcards" do
      guest =
        Context.enter_guest(
          Context.build(%{user_id: "u", permissions: [:execute, :vault_read]})
        )

      for permission <- [:execute, :vault_read, :component_read] do
        assert {:error, _} = Context.require_permission(guest, permission)
      end
    end
  end

  describe "require_permission_for_plane/2 (the gate providers call)" do
    test "external plane fails closed, exactly like require_permission/2" do
      external = Context.build(%{user_id: "u", permissions: [:execute]})
      assert :ok = Context.require_permission_for_plane(external, :execute)
      assert {:error, msg} = Context.require_permission_for_plane(external, :admin)
      assert msg =~ "missing required permission"
    end

    test "guest plane uses the identity conjunct, not the plane refusal" do
      guest = Context.enter_guest(Context.build(%{user_id: "u", permissions: [:execute]}))
      # Allowed when identity carries the permission (authority conjunct is
      # applied upstream at the dispatch chokepoint)...
      assert :ok = Context.require_permission_for_plane(guest, :execute)
      # ...and refused when it does not — but never with the guest-plane error.
      assert {:error, msg} = Context.require_permission_for_plane(guest, :admin)
      refute msg =~ "guest-plane"
    end
  end
end
