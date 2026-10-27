# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SlugTest do
  use ExUnit.Case, async: true

  alias Sanctum.Slug

  doctest Sanctum.Slug

  describe "from_name/1" do
    test "normalizes a display name" do
      assert Slug.from_name("Home & Family!") == "home-family"
    end

    test "returns nil when nothing usable remains" do
      assert Slug.from_name(nil) == nil
      assert Slug.from_name("") == nil
      assert Slug.from_name("---") == nil
    end
  end
end
