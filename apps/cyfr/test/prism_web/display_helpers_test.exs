defmodule PrismWeb.DisplayHelpersTest do
  use ExUnit.Case, async: true

  import PrismWeb.DisplayHelpers

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
