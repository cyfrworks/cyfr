# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S6PolicyFailClosedTest do
  @moduledoc """
  Phase 2 S6: `Sanctum.Policy.get_effective/2` fails closed on an
  un-normalizable component_ref (`{:error, {:invalid_ref, _}}` + telemetry)
  instead of silently substituting a type-default policy. A resolved ref with
  no stored policy still returns the deny-by-default policy (unchanged).
  """
  use ExUnit.Case, async: false

  alias Sanctum.Policy

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "fail-closed on un-normalizable ref" do
    test "missing type prefix → {:error, {:invalid_ref, _}}", %{ctx: ctx} do
      assert {:error, {:invalid_ref, reason}} =
               Policy.get_effective(ctx, "local.some-component:1.0.0")

      assert is_binary(reason)
    end

    test "emits [:cyfr, :sanctum, :policy, :resolve_error] telemetry", %{ctx: ctx} do
      handler = "s6-test-handler-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :policy, :resolve_error],
        fn _event, meas, meta, _ -> send(parent, {:tele, meas, meta}) end,
        nil
      )

      Policy.get_effective(ctx, "untyped-ref-no-prefix")

      assert_received {:tele, %{count: 1}, %{class: :invalid_ref, component_ref: _}}
      :telemetry.detach(handler)
    end
  end

  describe "unchanged paths (regression guards)" do
    test ":not_found — a resolved typed ref with no stored policy still defaults",
         %{ctx: ctx} do
      assert {:ok, policy, %{source: source}} =
               Policy.get_effective(ctx, "catalyst:local.no-such:1.0.0")

      assert policy.allowed_domains == []
      assert source in [:type_default, :hardcoded_default]
    end

    test "a name-level typed ref with no stored policy still defaults", %{ctx: ctx} do
      assert {:ok, _policy, %{source: source}} =
               Policy.get_effective(ctx, "reagent:local.no-such")

      assert source in [:type_default, :hardcoded_default, :name_level]
    end
  end
end
