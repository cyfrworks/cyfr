# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.SettingsTest do
  @moduledoc """
  The `settings` tool through the gate: the server's operators alone may
  list, set and reset the platform settings, and each refusal of
  `Cyfr.Platform.Settings` reaches the caller as its class and sentence.
  """

  use ExUnit.Case, async: false

  alias Arca.PlatformSettings, as: Store
  alias Grimoire.Error
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    pinned = Application.get_env(:cyfr, :deployment_pinned)
    level = Logger.level()

    on_exit(fn ->
      if pinned,
        do: Application.put_env(:cyfr, :deployment_pinned, pinned),
        else: Application.delete_env(:cyfr, :deployment_pinned)

      Logger.configure(level: level)
      Store.invalidate(:all)
    end)

    Application.put_env(:cyfr, :deployment_pinned, [])

    ctx = fn admin? ->
      Context.build(
        user_id: "github|https://github.com|ops-#{System.unique_integer([:positive])}",
        athanor_id: Sanctum.TestContext.athanor_id(),
        provider: "github",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true,
        platform_admin: admin?
      )
    end

    {:ok, admin: ctx.(true), member: ctx.(false)}
  end

  defp call(ctx, args), do: Grimoire.call_external("settings", ctx, args)

  defp class({:error, reason}), do: Error.classify(reason).class

  test "the tool is the operator's: refused for a member, hidden from its tools, open to an admin",
       %{admin: admin, member: member} do
    for action <- ["list", "set", "reset"] do
      assert {:error, %Prima.Refusal{stage: :admission, reason: :platform_admin_required}} =
               call(member, %{"action" => action, "key" => "device_label", "value" => "x"})
    end

    assert Grimoire.Visibility.filter_for_context(Grimoire.Catalog.list_tools(), member)
           |> Enum.all?(&(&1["name"] != "settings"))

    assert {:ok, %{settings: settings, count: count, revision: revision, ttl_ms: ttl}} =
             call(admin, %{"action" => "list"})

    assert count == length(settings) and count == length(Cyfr.Platform.Settings.Roster.entries())
    assert is_integer(revision) and ttl == Store.ttl_ms()
  end

  test "set and reset write through the store, against the revision list answered",
       %{admin: admin} do
    {:ok, %{revision: read}} = call(admin, %{"action" => "list"})

    assert {:ok, %{key: "mcp_rate_limit_max", value: 240, revision: set_at, pending: false}} =
             call(admin, %{
               "action" => "set",
               "key" => "mcp_rate_limit_max",
               "value" => "240",
               "revision" => read
             })

    assert set_at == read + 1
    assert Store.effective("mcp_rate_limit_max") == {:ok, 240}

    # A second operator who read the same revision is refused, and told why.
    stale =
      call(admin, %{
        "action" => "set",
        "key" => "mcp_rate_limit_max",
        "value" => "300",
        "revision" => read
      })

    assert class(stale) == :conflict
    assert Error.render(elem(stale, 1)) =~ "changed since they were read"

    assert {:ok, %{value: 120, revision: reset_at}} =
             call(admin, %{"action" => "reset", "key" => "mcp_rate_limit_max"})

    assert reset_at == set_at + 1

    # The row is gone, so the key reads its installed default: the suite's
    # own (`Cyfr.Test.Settings.suite/0`) over the roster's 120.
    assert Store.get("mcp_rate_limit_max") == {:error, :not_found}

    assert Store.effective("mcp_rate_limit_max") ==
             {:ok, Cyfr.Test.Settings.suite()["mcp_rate_limit_max"]}
  end

  test "each refusal reaches the caller as its class", %{admin: admin} do
    invalid = call(admin, %{"action" => "set", "key" => "mcp_rate_limit_max", "value" => "0"})
    assert class(invalid) == :invalid_argument

    assert Error.render(elem(invalid, 1)) ==
             "mcp_rate_limit_max must be a whole number of requests from 1 to 1000000000"

    unknown = call(admin, %{"action" => "set", "key" => "no_such", "value" => "1"})
    assert class(unknown) == :not_found

    Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 5}])
    pinned = call(admin, %{"action" => "reset", "key" => "max_athanors"})
    assert class(pinned) == :conflict
    assert Error.render(elem(pinned, 1)) =~ "set by the deployment"
  end
end
