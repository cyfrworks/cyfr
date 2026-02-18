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

    test "registry map extracts value" do
      assert format_ref(%{"registry" => "formula:local.list-models:0.1.0"}) ==
               "formula:local.list-models:0.1.0"
    end

    test "local map with valid path converts to canonical ref" do
      ref = %{"local" => "components/catalysts/local/gemini/0.1.0/catalyst.wasm"}
      assert format_ref(ref) == "catalyst:local.gemini:0.1.0"
    end

    test "arca map with valid path converts to canonical ref" do
      ref = %{"arca" => "components/reagents/local/sentiment/1.0.0/reagent.wasm"}
      assert format_ref(ref) == "reagent:local.sentiment:1.0.0"
    end

    test "oci map with valid typed ref normalizes" do
      ref = %{"oci" => "catalyst:local.gemini:0.1.0"}
      assert format_ref(ref) == "catalyst:local.gemini:0.1.0"
    end

    test "local map with invalid path falls back to path string" do
      ref = %{"local" => "some/random/path.wasm"}
      assert format_ref(ref) == "some/random/path.wasm"
    end

    test "oci map with untyped ref falls back to raw value" do
      ref = %{"oci" => "local.gemini:0.1.0"}
      assert format_ref(ref) == "local.gemini:0.1.0"
    end

    test "unknown map key falls back to inspect" do
      ref = %{"unknown" => "something"}
      assert format_ref(ref) == inspect(ref)
    end
  end
end
