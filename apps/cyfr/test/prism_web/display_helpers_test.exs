# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.DisplayHelpersTest do
  use ExUnit.Case, async: true

  import PrismWeb.DisplayHelpers

  describe "principal_label/1" do
    test "the server's synthetic principals read as what they are" do
      assert principal_label("system") == "System"
      assert principal_label("_seed") == "System (seed)"
      assert principal_label("_health_probe") == "System (health probe)"
      assert principal_label("_system_scan") == "System (scan)"
      assert principal_label("_tincture") == "Public tincture"
      assert principal_label("webhook:orders") == "Webhook orders"
      assert principal_label("aqua") == "AQUA"
      assert principal_label(nil) == "-"
    end

    test "an unknown person id is shortened, never shown raw in full" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      id = "github|https://github.com|" <> String.duplicate("9", 40)
      label = principal_label(id)
      assert String.ends_with?(label, "…")
      assert byte_size(label) < byte_size(id)
    end
  end

  describe "format_ref/1" do
    test "nil returns dash" do
      assert format_ref(nil) == "-"
    end

    test "binary string passes through" do
      assert format_ref("catalyst:local.gemini:0.1.0") == "catalyst:local.gemini:0.1.0"
    end

    test "formula string passes through" do
      assert format_ref("formula:local.list-models:0.1.0") == "formula:local.list-models:0.1.0"
    end

    test "reagent string passes through" do
      assert format_ref("reagent:cyfr.json-transform:1.0.0") ==
               "reagent:cyfr.json-transform:1.0.0"
    end

    test "non-string value falls back to inspect" do
      ref = %{"unknown" => "something"}
      assert format_ref(ref) == inspect(ref)
    end

    test "integer value falls back to inspect" do
      assert format_ref(42) == "42"
    end
  end
end
