# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TinctureRegistryTest do
  use ExUnit.Case, async: false

  alias Prism.TinctureRegistry

  # The registry resolves every tincture's athanor to a route segment, so the
  # rows behind the athanor ids used here must exist: the test context's own
  # (`ath_test`, slug "test") plus the ones each test creates.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    athanor = Sanctum.TestContext.athanor!()

    # Create a temp tincture structure
    base = Path.join(System.tmp_dir!(), "tincture_reg_test_#{:rand.uniform(1_000_000)}")
    components_dir = Path.join(base, "components")

    tincture_dir =
      Path.join([components_dir, athanor.id, "tinctures", "local", "test-dash", "1.0.0"])

    File.mkdir_p!(tincture_dir)

    manifest = %{
      "name" => "test-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Test Dashboard",
      "tincture" => %{
        "entry" => "index.html",
        "icon" => "chart-line",
        "public" => true,
        "window" => %{"width" => 800, "height" => 600}
      },
      "schema" => %{
        "tables" => %{},
        "queries" => %{}
      }
    }

    File.write!(Path.join(tincture_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(tincture_dir, "index.html"), "<html><body>Test</body></html>")

    # Set components_path to our temp dir
    original_path = Application.get_env(:cyfr, :components_path)
    Application.put_env(:cyfr, :components_path, components_dir)

    on_exit(fn ->
      if original_path do
        Application.put_env(:cyfr, :components_path, original_path)
      else
        Application.delete_env(:cyfr, :components_path)
      end

      File.rm_rf!(base)
    end)

    %{base: base, components_dir: components_dir, tincture_dir: tincture_dir, athanor: athanor}
  end

  describe "GenServer lifecycle" do
    test "starts and loads tinctures" do
      name = :test_tincture_reg
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      assert length(tinctures) == 1
      assert hd(tinctures).name == "test-dash"

      GenServer.stop(pid)
    end
  end

  describe "list_tinctures/1" do
    test "returns tinctures for the given scope" do
      name = :test_list
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      assert length(tinctures) == 1

      t = hd(tinctures)
      assert t.name == "test-dash"
      assert t.publisher == "local"
      assert t.version == "1.0.0"
      assert t.entry == "index.html"
      assert t.title == "Test Dashboard"
      assert t.icon == "chart-line"
      assert t.entry_url == "/t/test/local/test-dash"
      assert t.athanor_id == "ath_test"
      assert t.athanor_segment == "test"

      GenServer.stop(pid)
    end

    test "returns empty for a non-matching athanor" do
      name = :test_empty_athanor
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_nonexistent"})
      assert tinctures == []

      GenServer.stop(pid)
    end
  end

  describe "version resolution" do
    test "picks latest version when multiple exist", %{components_dir: components_dir} do
      # Add a newer version
      v2_dir =
        Path.join([
          components_dir,
          "ath_test",
          "tinctures",
          "local",
          "test-dash",
          "2.0.0"
        ])

      File.mkdir_p!(v2_dir)

      manifest = %{
        "name" => "test-dash",
        "type" => "tincture",
        "version" => "2.0.0",
        "publisher" => "local",
        "description" => "Test Dashboard v2",
        "tincture" => %{"entry" => "index.html", "public" => true}
      }

      File.write!(Path.join(v2_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_version
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      assert length(tinctures) == 1
      assert hd(tinctures).version == "2.0.0"

      GenServer.stop(pid)
    end
  end

  describe "reload/0" do
    test "rescans filesystem", %{components_dir: components_dir} do
      name = :test_reload
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      assert length(TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})) == 1

      # Add a new tincture
      new_dir =
        Path.join([
          components_dir,
          "ath_test",
          "tinctures",
          "local",
          "new-tincture",
          "0.1.0"
        ])

      File.mkdir_p!(new_dir)

      manifest = %{
        "name" => "new-tincture",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      }

      File.write!(Path.join(new_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      :ok = TinctureRegistry.reload(name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      assert length(tinctures) == 2

      GenServer.stop(pid)
    end
  end

  describe "athanor-scoped tincture loading" do
    test "discovers another athanor's tinctures under its own id", %{
      components_dir: components_dir
    } do
      {:ok, other} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Acme",
          slug: "acme",
          created_by: "test"
        })

      # Layout: components/{athanor_id}/tinctures/{publisher}/{name}/{version}/
      other_dir = Path.join([components_dir, other.id, "tinctures", "acme", "acme-dash", "0.1.0"])
      File.mkdir_p!(other_dir)

      manifest = %{
        "name" => "acme-dash",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "acme",
        "tincture" => %{"entry" => "index.html"}
      }

      File.write!(Path.join(other_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_ext_athanor
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      # Visible to the matching athanor, with its own route segment
      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: other.id})
      assert [%{name: "acme-dash", entry_url: "/t/acme/acme/acme-dash"}] = tinctures

      # Not visible to a different athanor
      other_tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_other"})
      refute "acme-dash" in Enum.map(other_tinctures, & &1.name)

      # Not visible to the test athanor
      core_tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      refute "acme-dash" in Enum.map(core_tinctures, & &1.name)

      GenServer.stop(pid)
    end

    test "a tincture whose athanor row is missing or archived has no route", %{
      components_dir: components_dir
    } do
      {:ok, archived} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Gone",
          slug: "gone",
          created_by: "test"
        })

      {:ok, _} = Sanctum.Tenancy.Athanors.archive(archived)

      for athanor_id <- [archived.id, "ath_ghost"] do
        dir = Path.join([components_dir, athanor_id, "tinctures", "local", "orphan", "0.1.0"])
        File.mkdir_p!(dir)

        manifest = %{
          "name" => "orphan",
          "type" => "tincture",
          "version" => "0.1.0",
          "publisher" => "local",
          "tincture" => %{"entry" => "index.html"}
        }

        File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      end

      name = :test_orphans
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      assert TinctureRegistry.list_tinctures(name, %{athanor_id: archived.id}) == []
      assert TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_ghost"}) == []

      GenServer.stop(pid)
    end

    test "the seed bundle is never a tincture source", %{components_dir: components_dir} do
      dir = Path.join([components_dir, "_bundle", "tinctures", "local", "bundled", "0.1.0"])
      File.mkdir_p!(dir)

      manifest = %{
        "name" => "bundled",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_bundle_skip
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      assert TinctureRegistry.list_tinctures(name, %{athanor_id: "_bundle"}) == []

      GenServer.stop(pid)
    end

    test "still discovers the test athanor's tinctures", %{components_dir: _components_dir} do
      name = :test_ext_core
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      names = Enum.map(tinctures, & &1.name)
      assert "test-dash" in names

      GenServer.stop(pid)
    end
  end

  describe "skips non-tincture manifests" do
    test "ignores type=app manifests", %{components_dir: components_dir} do
      app_dir =
        Path.join([
          components_dir,
          "ath_test",
          "tinctures",
          "local",
          "legacy-app",
          "1.0.0"
        ])

      File.mkdir_p!(app_dir)

      manifest = %{
        "name" => "legacy-app",
        "type" => "app",
        "version" => "1.0.0",
        "publisher" => "local"
      }

      File.write!(Path.join(app_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_skip_app
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      names = Enum.map(tinctures, & &1.name)
      refute "legacy-app" in names

      GenServer.stop(pid)
    end
  end

  # Launch constraint: raster image assets in tinctures are rejected until
  # CSAM hash matching ships. Blocks .png/.jpg/.jpeg/.gif/.webp in manifest
  # `tincture.media.icon` or `tincture.media.previews`. SVG is allowed.
  describe "raster image-asset reject — launch constraint" do
    test "rejects tincture with manifest-declared PNG icon", %{components_dir: components_dir} do
      dir =
        Path.join([
          components_dir,
          "ath_test",
          "tinctures",
          "local",
          "has-png-icon",
          "1.0.0"
        ])

      File.mkdir_p!(dir)

      manifest = %{
        "name" => "has-png-icon",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{
          "entry" => "index.html",
          "media" => %{"icon" => "public/media/icon.png"}
        }
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_reject_png_icon
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      names =
        TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
        |> Enum.map(& &1.name)

      refute "has-png-icon" in names
      GenServer.stop(pid)
    end

    test "rejects tincture with JPEG preview", %{components_dir: components_dir} do
      dir =
        Path.join([
          components_dir,
          "ath_test",
          "tinctures",
          "local",
          "has-jpg-preview",
          "1.0.0"
        ])

      File.mkdir_p!(dir)

      manifest = %{
        "name" => "has-jpg-preview",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{
          "entry" => "index.html",
          "media" => %{"previews" => ["public/media/preview-1.jpg"]}
        }
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_reject_jpg_preview
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      names =
        TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
        |> Enum.map(& &1.name)

      refute "has-jpg-preview" in names
      GenServer.stop(pid)
    end

    test "rejects tincture with convention-discovered PNG icon", %{components_dir: components_dir} do
      dir =
        Path.join([components_dir, "ath_test", "tinctures", "local", "conv-png", "1.0.0"])

      File.mkdir_p!(Path.join(dir, "public/media"))

      manifest = %{
        "name" => "conv-png",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      # discover_media/1 auto-finds this icon by convention even though the
      # manifest doesn't declare it — the validator must still reject it.
      File.write!(Path.join([dir, "public/media/icon.png"]), <<137, 80, 78, 71>>)

      name = :test_reject_conv_png
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      names =
        TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
        |> Enum.map(& &1.name)

      refute "conv-png" in names
      GenServer.stop(pid)
    end

    test "allows SVG icon", %{components_dir: components_dir} do
      dir =
        Path.join([components_dir, "ath_test", "tinctures", "local", "svg-ok", "1.0.0"])

      File.mkdir_p!(dir)

      manifest = %{
        "name" => "svg-ok",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{
          "entry" => "index.html",
          "media" => %{"icon" => "public/media/icon.svg"}
        }
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_allow_svg
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      names =
        TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
        |> Enum.map(& &1.name)

      assert "svg-ok" in names
      GenServer.stop(pid)
    end

    test "extension check is case-insensitive", %{components_dir: components_dir} do
      dir =
        Path.join([
          components_dir,
          "ath_test",
          "tinctures",
          "local",
          "upper-png",
          "1.0.0"
        ])

      File.mkdir_p!(dir)

      manifest = %{
        "name" => "upper-png",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{
          "entry" => "index.html",
          "media" => %{"icon" => "public/media/ICON.PNG"}
        }
      }

      File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      name = :test_upper_png
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      names =
        TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
        |> Enum.map(& &1.name)

      refute "upper-png" in names
      GenServer.stop(pid)
    end
  end

  describe "reads bypass the GenServer" do
    test "list and get answer from ETS while the server is suspended" do
      name = :test_suspended_reads
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      :ok = :sys.suspend(pid)

      tinctures = TinctureRegistry.list_tinctures(name, %{athanor_id: "ath_test"})
      assert [%{name: "test-dash"}] = tinctures

      :ok = :sys.resume(pid)
      GenServer.stop(pid)
    end
  end
end
