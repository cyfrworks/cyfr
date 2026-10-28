# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.LabelsTest do
  use ExUnit.Case, async: true

  alias Prism.Labels

  test "a person lands in lite and the administrator in dev; a saved preference wins" do
    assert Labels.default(%{platform_admin: false}) == "lite"
    assert Labels.default(nil) == "lite"
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
