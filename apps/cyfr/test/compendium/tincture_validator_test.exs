# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.TinctureValidatorTest do
  use ExUnit.Case, async: true

  alias Compendium.TinctureValidator

  setup do
    base = Path.join(System.tmp_dir!(), "tincture_validator_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(base)

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base}
  end

  describe "validate/1" do
    test "validates a valid tincture directory", %{base: base} do
      dir = setup_valid_tincture(base)

      assert {:ok, result} = TinctureValidator.validate(dir)
      assert is_binary(result.digest)
      assert byte_size(result.digest) == 64
      assert result.size > 0
      assert result.exports == []
    end

    test "returns error for missing manifest", %{base: base} do
      dir = Path.join(base, "no-manifest")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "index.html"), "<html></html>")

      assert {:error, "cyfr-manifest.json not found"} = TinctureValidator.validate(dir)
    end

    test "returns error for invalid JSON manifest", %{base: base} do
      dir = Path.join(base, "bad-json")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "cyfr-manifest.json"), "not json")
      File.write!(Path.join(dir, "index.html"), "<html></html>")

      assert {:error, "invalid manifest JSON:" <> _} = TinctureValidator.validate(dir)
    end

    test "returns error for wrong type", %{base: base} do
      dir = Path.join(base, "wrong-type")
      File.mkdir_p!(dir)

      manifest = %{"name" => "test", "type" => "catalyst", "version" => "1.0.0"}
      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(dir, "index.html"), "<html></html>")

      assert {:error, "expected type 'tincture', got 'catalyst'"} =
               TinctureValidator.validate(dir)
    end

    test "returns error for missing type field", %{base: base} do
      dir = Path.join(base, "no-type")
      File.mkdir_p!(dir)

      manifest = %{"name" => "test", "version" => "1.0.0"}
      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(dir, "index.html"), "<html></html>")

      assert {:error, "manifest missing 'type' field"} = TinctureValidator.validate(dir)
    end

    test "returns error for missing entry file", %{base: base} do
      dir = Path.join(base, "no-entry")
      File.mkdir_p!(dir)

      manifest = %{
        "name" => "test",
        "type" => "tincture",
        "version" => "1.0.0",
        "tincture" => %{"entry" => "app.html"}
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      assert {:error, "entry file 'app.html' not found"} = TinctureValidator.validate(dir)
    end

    test "returns error for entry with path traversal", %{base: base} do
      dir = Path.join(base, "traversal")
      File.mkdir_p!(dir)

      manifest = %{
        "name" => "test",
        "type" => "tincture",
        "version" => "1.0.0",
        "tincture" => %{"entry" => "../etc/passwd"}
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      assert {:error, "entry must not contain '..'"} = TinctureValidator.validate(dir)
    end

    test "returns error for entry with absolute path", %{base: base} do
      dir = Path.join(base, "abs-path")
      File.mkdir_p!(dir)

      manifest = %{
        "name" => "test",
        "type" => "tincture",
        "version" => "1.0.0",
        "tincture" => %{"entry" => "/etc/passwd"}
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      assert {:error, "entry must be a relative path"} = TinctureValidator.validate(dir)
    end

    test "data.db is included in digest computation (cyfr no longer manages tincture state)", %{base: base} do
      dir = setup_valid_tincture(base)

      {:ok, result_without_db} = TinctureValidator.validate(dir)

      # Adding data.db changes the digest — it's a regular shipped asset.
      File.write!(Path.join(dir, "data.db"), "fake db content")

      {:ok, result_with_db} = TinctureValidator.validate(dir)

      refute result_without_db.digest == result_with_db.digest
    end

    test "digest is deterministic for same content", %{base: base} do
      dir1 = setup_valid_tincture(base, "det1")
      dir2 = setup_valid_tincture(base, "det2")

      {:ok, r1} = TinctureValidator.validate(dir1)
      {:ok, r2} = TinctureValidator.validate(dir2)

      assert r1.digest == r2.digest
    end

    test "digest changes when content changes", %{base: base} do
      dir = setup_valid_tincture(base)
      {:ok, r1} = TinctureValidator.validate(dir)

      # Modify a file
      File.write!(Path.join(dir, "app.js"), "console.log('modified')")
      {:ok, r2} = TinctureValidator.validate(dir)

      assert r1.digest != r2.digest
    end
  end

  # -- Helpers --

  defp setup_valid_tincture(base, suffix \\ "valid") do
    dir = Path.join(base, suffix)
    File.mkdir_p!(dir)

    manifest = %{
      "name" => "test-tincture",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "icon" => "palette"},
      "schema" => %{"tables" => %{}, "queries" => %{}}
    }

    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html><body>Hello</body></html>")
    File.write!(Path.join(dir, "app.js"), "console.log('hello')")
    File.write!(Path.join(dir, "style.css"), "body { margin: 0; }")

    dir
  end
end
