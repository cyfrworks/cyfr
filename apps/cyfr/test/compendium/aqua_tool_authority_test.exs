# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.AquaToolAuthorityTest do
  # Agent definitions are instance-global state (the aqua/ storage prefix
  # bypasses tenant segmentation), so on a deployment with an auth provider
  # a tenant-scoped caller must not be able to mutate them.
  use ExUnit.Case, async: false

  alias Compendium.MCP.AquaTool
  alias Sanctum.Context

  setup do
    original = Application.get_env(:cyfr, :auth_provider)

    # An isolated aqua root: the default points at the repo's tracked
    # aqua/ directory, and the update path re-serializes agent.json on
    # write — a test must never touch the shipped seed.
    aqua_path = Path.join(System.tmp_dir!(), "aqua_authority_#{:rand.uniform(1_000_000)}")
    original_aqua_path = Application.get_env(:cyfr, :aqua_path)
    Application.put_env(:cyfr, :aqua_path, aqua_path)

    on_exit(fn ->
      File.rm_rf!(aqua_path)

      if original_aqua_path,
        do: Application.put_env(:cyfr, :aqua_path, original_aqua_path),
        else: Application.delete_env(:cyfr, :aqua_path)

      if original,
        do: Application.put_env(:cyfr, :auth_provider, original),
        else: Application.delete_env(:cyfr, :auth_provider)
    end)

    :ok
  end

  defp ctx(scope) do
    Context.build(
      user_id: "local|idp|user1",
      provider: "oidc",
      athanor_id: Sanctum.TestContext.athanor_id(),
      permissions: [:*],
      scope: scope,
      auth_method: :oidc,
      authenticated: true
    )
  end

  test "members cannot mutate agent definitions when auth is configured" do
    Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OIDC)

    for action <- ["create", "update", "delete"] do
      assert {:error, message} =
               AquaTool.handle(ctx(:athanor), %{"action" => action, "name" => "aqua"})

      assert message =~ "operator's act"
    end
  end

  test "the operator passes the definition gate when auth is configured" do
    Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OIDC)

    # The gate is what is under test: an operator must get past it — as a
    # platform admin focused on an athanor, or as the server itself. (The
    # update then fails later on the missing manifest — any error is
    # acceptable as long as it is not the operator refusal.)
    admin = %{ctx(:athanor) | platform_admin: true}
    refute platform_refusal?(AquaTool.handle(admin, %{"action" => "update", "name" => "aqua"}))

    refute platform_refusal?(
             AquaTool.handle(ctx(:platform), %{"action" => "update", "name" => "aqua"})
           )
  end

  test "single-user deployments keep the permission check as the only gate" do
    Application.delete_env(:cyfr, :auth_provider)

    result = AquaTool.handle(ctx(:athanor), %{"action" => "update", "name" => "aqua"})

    refute platform_refusal?(result)
  end

  defp platform_refusal?({:error, message}) when is_binary(message),
    do: message =~ "operator's act"

  defp platform_refusal?(_), do: false
end
