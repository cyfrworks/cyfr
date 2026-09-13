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
      assert "sha256:" <> hex = result.digest
      assert byte_size(hex) == 64
      assert result.size > 0
      assert result.exports == []
    end

    test "returns error for missing manifest", %{base: base} do
      dir = Path.join(base, "no-manifest")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "index.html"), "<html></html>")

      assert {:error, "cyfr-manifest.json not found"} = TinctureValidator.validate(dir)
    end

    test "rejects a tincture containing a symlink", %{base: base} do
      # The digest and store walkers follow links; a self-referential one
      # recurses forever and an absolute-target one reads host files into
      # the archive. lstat-based refusal must fire before either walk.
      dir = setup_valid_tincture(base, "symlinked")
      File.mkdir_p!(Path.join(dir, "assets"))
      :ok = File.ln_s(dir, Path.join(dir, "assets/loop"))

      assert {:error, message} = TinctureValidator.validate(dir)
      assert message =~ "symlink"
      assert message =~ "assets/loop"
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

    test "data.db is included in digest computation (cyfr no longer manages tincture state)", %{
      base: base
    } do
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

  describe "excluded files" do
    test "the two walkers agree on the digest, and the excluded bytes are in neither",
         %{base: base} do
      # Hash the same filtered files that publication stores.
      dir = setup_valid_tincture(base, "with-sqlite-artifacts")
      assert {:ok, clean} = TinctureValidator.validate(dir)

      File.write!(Path.join(dir, "data.db-wal"), String.duplicate("w", 4096))
      File.write!(Path.join(dir, "data.db-shm"), String.duplicate("s", 512))

      assert {:ok, with_artifacts} = TinctureValidator.validate(dir)

      assert with_artifacts.digest == clean.digest,
             "a file that is never stored must not change the digest"

      assert with_artifacts.size == clean.size

      # The pair-based path — the one that re-reads the STORED tree — must
      # land on the same digest, which is the whole point.
      pairs =
        for path <- Path.wildcard(Path.join(dir, "**/*")),
            not File.dir?(path),
            do: {path |> Path.relative_to(dir) |> String.split("/"), File.read!(path)}

      assert {:ok, from_pairs} = TinctureValidator.validate_from_pairs(pairs)
      assert from_pairs.digest == clean.digest
      assert from_pairs.size == clean.size
    end

    test "data.db itself is a shipped asset and is hashed", %{base: base} do
      dir = setup_valid_tincture(base, "with-db")
      assert {:ok, before} = TinctureValidator.validate(dir)

      File.write!(Path.join(dir, "data.db"), "sqlite-bytes")
      assert {:ok, after_db} = TinctureValidator.validate(dir)

      refute after_db.digest == before.digest
      assert after_db.size > before.size
    end

    test "excluded?/1 decides on the basename" do
      assert TinctureValidator.excluded?("data.db-wal")
      assert TinctureValidator.excluded?("nested/dir/data.db-shm")
      refute TinctureValidator.excluded?("data.db")
      refute TinctureValidator.excluded?("index.html")
    end
  end

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

  describe "the entry rule is one rule" do
    # Publish checked path safety only; serve added a denylist and refused
    # dotfiles; the indexer checked nothing. So `entry: "cyfr-manifest.json"`
    # published cleanly, indexed cleanly, and 404'd the first time anyone
    # opened it — the author finding out last, from a blank page.
    test "an entry the serve side refuses does not pass validation" do
      for entry <- ["cyfr-manifest.json", "data.db", "schema.sql", ".env"] do
        assert {:error, _} = Cyfr.TinctureHelpers.validate_entry(entry),
               "#{entry} must be refused at publish, not only at serve"

        assert Cyfr.TinctureHelpers.resolve_entry(%{
                 manifest: %{"tincture" => %{"entry" => entry}}
               }) == :error
      end
    end

    test "an ordinary entry passes both, and an absent one defaults" do
      assert {:ok, "app.html"} = Cyfr.TinctureHelpers.validate_entry("app.html")
      assert {:ok, "index.html"} = Cyfr.TinctureHelpers.validate_entry(nil)
      assert {:ok, "index.html"} = Cyfr.TinctureHelpers.entry_of(%{})

      assert Cyfr.TinctureHelpers.resolve_entry(%{manifest: %{}}) ==
               {:ok, Cyfr.TinctureHelpers.default_entry()}
    end

    test "path safety speaks before the dotfile rule" do
      # `../escape.html` is a dotfile by prefix and a traversal by meaning;
      # the traversal is what the author needs told.
      assert {:error, message} = Cyfr.TinctureHelpers.validate_entry("../escape.html")
      assert message =~ "'..'"
    end
  end
end
