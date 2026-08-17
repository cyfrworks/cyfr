# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.LabelsTest do
  use ExUnit.Case, async: false

  alias Prism.Labels

  setup do
    prev = Application.get_env(:cyfr, :auth_provider)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :auth_provider, prev),
        else: Application.delete_env(:cyfr, :auth_provider)
    end)

    :ok
  end

  test "on a private box everyone lands in dev" do
    Application.delete_env(:cyfr, :auth_provider)
    assert Labels.default(%{platform_admin: false}) == "dev"
    assert Labels.mode(nil, %{platform_admin: false}) == "dev"
  end

  test "behind a door a person lands in lite and the operator in dev; a saved preference wins" do
    Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OAuth)
    assert Labels.default(%{platform_admin: false}) == "lite"
    assert Labels.default(%{platform_admin: true}) == "dev"
    assert Labels.mode(nil, %{platform_admin: false}) == "lite"
    assert Labels.mode("dev", %{platform_admin: false}) == "dev"
    assert Labels.mode("garbage", %{platform_admin: true}) == "dev"
  end

  test "lite speaks the everyday vocabulary, dev the runtime's" do
    assert Labels.label(:tincture, "lite") == "App"
    assert Labels.label(:tincture, "dev") == "Tincture"
    refute Labels.dev?("lite")
    assert Labels.dev?("dev")
  end
end
