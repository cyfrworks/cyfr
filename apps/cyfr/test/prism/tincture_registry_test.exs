# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.TinctureRegistryTest do
  use ExUnit.Case, async: false

  alias Arca.Test.UnitFixtures
  alias Prism.TinctureRegistry

  # The registry resolves every tincture's athanor to a route segment, so the
  # rows behind the athanor ids used here must exist: the test context's own
  # (`ath_test`, slug "test") plus the ones each test creates.
  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    athanor = Sanctum.TestContext.athanor!()

    # Create a temp tincture structure under an isolated storage root
    base = Path.join(System.tmp_dir!(), "tincture_reg_test_#{:rand.uniform(1_000_000)}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

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

    on_exit(fn ->
      if original_path do
        Application.put_env(:arca, :base_path, original_path)
      else
        Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(base)
    end)

    unit =
      lay!(athanor.id, "local", "test-dash", "1.0.0", manifest, [
        {"index.html", "<html><body>Test</body></html>"}
      ])

    %{base: base, unit: unit, athanor: athanor}
  end

  # A tincture unit committed in `athanor_id`'s tree through the facade,
  # the one way a unit lands. Returns its path segments.
  defp lay!(athanor_id, publisher, name, version, manifest, files \\ []) do
    UnitFixtures.tenant_component!(fixture_ctx(athanor_id), "tincture", publisher, name, version,
      manifest: manifest,
      files: files
    )
  end

  defp fixture_ctx(athanor_id),
    do: Sanctum.Context.build(user_id: "fixture", athanor_id: athanor_id, authenticated: true)

  describe "GenServer lifecycle" do
    test "starts and loads tinctures" do
      name = :test_tincture_reg
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      assert length(tinctures) == 1
      assert hd(tinctures).name == "test-dash"

      GenServer.stop(pid)
    end
  end

  describe "list_tinctures/1" do
    test "returns tinctures for the given scope" do
      name = :test_list
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
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

    # The setup's manifest declares `tincture.window`, as the shipped seed
    # versions still do: an extra nothing reads, registered without it.
    test "a manifest declaring window hints registers, and its entry carries none", %{
      unit: unit
    } do
      manifest =
        Jason.decode!(
          UnitFixtures.unit_file!(fixture_ctx("ath_test"), unit, "cyfr-manifest.json")
        )

      assert %{"window" => %{"width" => 800}} = manifest["tincture"]

      name = :test_window_extra

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} = TinctureRegistry.start_link(name: name)
          # The initial scan runs in handle_continue; a call synchronizes with it.
          :sys.get_state(pid)
          send(self(), {:listed, TinctureRegistry.list_tinctures(name, lookup("ath_test"))})
          GenServer.stop(pid)
        end)

      assert_received {:listed, [entry]}
      assert {entry.name, entry.version} == {"test-dash", "1.0.0"}
      refute Map.has_key?(entry, :window)
      assert entry.manifest["tincture"]["window"] == manifest["tincture"]["window"]
      refute log =~ "TinctureRegistry"
    end

    test "a window hint of any shape registers, ignored and unrefused", %{
      athanor: athanor,
      unit: unit
    } do
      index = UnitFixtures.unit_file!(fixture_ctx(athanor.id), unit, "index.html")

      for {window, n} <- Enum.with_index(["800x600", 800]) do
        name = "hinted-#{n}"

        manifest = %{
          "name" => name,
          "type" => "tincture",
          "version" => "1.0.0",
          "publisher" => "local",
          "tincture" => %{"entry" => "index.html", "window" => window}
        }

        lay!(athanor.id, "local", name, "1.0.0", manifest, [{"index.html", index}])
      end

      name = :test_window_any_shape

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} = TinctureRegistry.start_link(name: name)
          # The initial scan runs in handle_continue; a call synchronizes with it.
          :sys.get_state(pid)
          send(self(), {:listed, TinctureRegistry.list_tinctures(name, lookup("ath_test"))})
          GenServer.stop(pid)
        end)

      assert_received {:listed, listed}
      hinted = Enum.filter(listed, &String.starts_with?(&1.name, "hinted-"))
      assert Enum.sort(Enum.map(hinted, & &1.name)) == ["hinted-0", "hinted-1"]

      for entry <- hinted do
        refute Map.has_key?(entry, :window)
        assert entry.manifest["tincture"]["window"] in ["800x600", 800]
      end

      refute log =~ "TinctureRegistry"
    end

    test "returns empty for a non-matching athanor" do
      name = :test_empty_athanor
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_nonexistent"))
      assert tinctures == []

      GenServer.stop(pid)
    end
  end

  describe "version resolution" do
    test "picks latest version when multiple exist" do
      # Add a newer version
      manifest = %{
        "name" => "test-dash",
        "type" => "tincture",
        "version" => "2.0.0",
        "publisher" => "local",
        "description" => "Test Dashboard v2",
        "tincture" => %{"entry" => "index.html", "public" => true}
      }

      lay!("ath_test", "local", "test-dash", "2.0.0", manifest)

      name = :test_version
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      assert length(tinctures) == 1
      assert hd(tinctures).version == "2.0.0"

      GenServer.stop(pid)
    end

    # A release must sort after its prereleases regardless of storage listing order.
    test "a prerelease never outranks its release" do
      for version <- ["1.0.0-rc1", "1.0.0"] do
        manifest = %{
          "name" => "test-pre",
          "type" => "tincture",
          "version" => version,
          "publisher" => "local",
          "description" => "Prerelease ordering",
          "tincture" => %{"entry" => "index.html", "public" => true}
        }

        lay!("ath_test", "local", "test-pre", version, manifest)
      end

      name = :test_prerelease
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      :sys.get_state(pid)

      served =
        name
        |> TinctureRegistry.list_tinctures(lookup("ath_test"))
        |> Enum.find(&(&1.name == "test-pre"))

      assert served.version == "1.0.0"

      GenServer.stop(pid)
    end
  end

  describe "reload/0" do
    test "rescans filesystem" do
      name = :test_reload
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      assert length(TinctureRegistry.list_tinctures(name, lookup("ath_test"))) == 1

      unheard!(pid, Sanctum.Context.actor(lookup("ath_test")))

      # Add a new tincture
      manifest = %{
        "name" => "new-tincture",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      }

      lay!("ath_test", "local", "new-tincture", "0.1.0", manifest)

      assert {:ok, _} = Compendium.acknowledged_projection_epoch(lookup("ath_test"), "components")
      assert held(name, "ath_test") == ["test-dash"]
      :ok = TinctureRegistry.reload(name)
      assert held(name, "ath_test") == ["new-tincture", "test-dash"]

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      assert length(tinctures) == 2

      GenServer.stop(pid)
    end
  end

  describe "reload_athanor/2" do
    # An athanor-scoped reload must pick up its changes without reading other athanors.
    test "picks up one athanor's change and leaves the others alone" do
      {:ok, other} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Bystander",
          slug: "bystander",
          created_by: "test"
        })

      lay!(other.id, "bystander", "other-dash", "0.1.0", %{
        "name" => "other-dash",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "bystander",
        "tincture" => %{"entry" => "index.html"}
      })

      name = :test_reload_scoped
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      :sys.get_state(pid)

      assert length(TinctureRegistry.list_tinctures(name, lookup(other.id))) == 1
      before_count = length(TinctureRegistry.list_tinctures(name, lookup("ath_test")))
      unheard!(pid, Sanctum.Context.actor(lookup("ath_test")))

      lay!("ath_test", "local", "scoped-add", "0.1.0", %{
        "name" => "scoped-add",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      })

      assert {:ok, _} = Compendium.acknowledged_projection_epoch(lookup("ath_test"), "components")
      assert held(name, "ath_test") == ["test-dash"]
      :ok = TinctureRegistry.reload_athanor(name, "ath_test")
      assert held(name, "ath_test") == ["scoped-add", "test-dash"]
      assert held(name, other.id) == ["other-dash"]

      assert length(TinctureRegistry.list_tinctures(name, lookup("ath_test"))) ==
               before_count + 1

      # The bystander's rows were neither re-read nor pruned.
      assert length(TinctureRegistry.list_tinctures(name, lookup(other.id))) == 1

      GenServer.stop(pid)
    end

    test "an athanor's own removal is pruned by its own reload", %{unit: unit} do
      name = :test_reload_prune
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      :sys.get_state(pid)

      assert length(TinctureRegistry.list_tinctures(name, lookup("ath_test"))) == 1

      unheard!(pid, Sanctum.Context.actor(lookup("ath_test")))
      :ok = Arca.delete_tree(Sanctum.Context.actor(fixture_ctx("ath_test")), unit)
      assert {:ok, _} = Compendium.acknowledged_projection_epoch(lookup("ath_test"), "components")
      assert held(name, "ath_test") == ["test-dash"]
      :ok = TinctureRegistry.reload_athanor(name, "ath_test")
      assert held(name, "ath_test") == []

      assert TinctureRegistry.list_tinctures(name, lookup("ath_test")) == []

      GenServer.stop(pid)
    end
  end

  describe "athanor-scoped tincture loading" do
    test "discovers another athanor's tinctures under its own id" do
      {:ok, other} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Acme",
          slug: "acme",
          created_by: "test"
        })

      manifest = %{
        "name" => "acme-dash",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "acme",
        "tincture" => %{"entry" => "index.html"}
      }

      lay!(other.id, "acme", "acme-dash", "0.1.0", manifest)

      name = :test_ext_athanor
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      # Visible to the matching athanor, with its own route segment
      tinctures = TinctureRegistry.list_tinctures(name, lookup(other.id))
      assert [%{name: "acme-dash", entry_url: "/t/acme/acme/acme-dash"}] = tinctures

      # Not visible to a different athanor
      other_tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_other"))
      refute "acme-dash" in Enum.map(other_tinctures, & &1.name)

      # Not visible to the test athanor
      core_tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      refute "acme-dash" in Enum.map(core_tinctures, & &1.name)

      GenServer.stop(pid)
    end

    test "a tincture whose athanor row is missing or archived has no route" do
      {:ok, archived} =
        Sanctum.Tenancy.Athanors.create(%{
          kind: "group",
          name: "Gone",
          slug: "gone",
          created_by: "test"
        })

      # Each tree holds a committed tincture; the archive comes after, as
      # an athanor holding units is archived.
      for athanor_id <- [archived.id, "ath_ghost"] do
        manifest = %{
          "name" => "orphan",
          "type" => "tincture",
          "version" => "0.1.0",
          "publisher" => "local",
          "tincture" => %{"entry" => "index.html"}
        }

        lay!(athanor_id, "local", "orphan", "0.1.0", manifest)
      end

      {:ok, _} = Sanctum.Tenancy.Athanors.archive(archived)

      name = :test_orphans
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      assert TinctureRegistry.list_tinctures(name, lookup(archived.id)) == []
      assert TinctureRegistry.list_tinctures(name, lookup("ath_ghost")) == []

      GenServer.stop(pid)
    end

    test "the seed bundle is never a tincture source", %{base: base} do
      # A tincture-shaped manifest inside the bundle source must never be
      # scanned: the roster walk only enumerates athanor rows.
      seed_dir = Path.join(base, "seed_fixture")
      bundle_dir = Path.join(seed_dir, "components")
      prev_seed = Application.get_env(:arca, :seed_path)
      Application.put_env(:arca, :seed_path, seed_dir)
      on_exit(fn -> Application.put_env(:arca, :seed_path, prev_seed) end)

      dir = Path.join([bundle_dir, "tinctures", "local", "bundled", "0.1.0"])
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
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      assert TinctureRegistry.list_tinctures(name, lookup("_bundle")) == []

      GenServer.stop(pid)
    end

    test "still discovers the test athanor's tinctures" do
      name = :test_ext_core
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      names = Enum.map(tinctures, & &1.name)
      assert "test-dash" in names

      GenServer.stop(pid)
    end
  end

  describe "skips non-tincture manifests" do
    test "ignores type=app manifests" do
      manifest = %{
        "name" => "legacy-app",
        "type" => "app",
        "version" => "1.0.0",
        "publisher" => "local"
      }

      lay!("ath_test", "local", "legacy-app", "1.0.0", manifest)

      name = :test_skip_app
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      names = Enum.map(tinctures, & &1.name)
      refute "legacy-app" in names

      GenServer.stop(pid)
    end
  end

  # Launch constraint: raster image assets in tinctures are rejected until
  # CSAM hash matching ships. Blocks .png/.jpg/.jpeg/.gif/.webp in manifest
  # `tincture.media.icon` or `tincture.media.previews`. SVG is allowed.
  describe "raster image-asset reject — launch constraint" do
    test "rejects tincture with manifest-declared PNG icon" do
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

      lay!("ath_test", "local", "has-png-icon", "1.0.0", manifest)

      name = :test_reject_png_icon
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      names =
        TinctureRegistry.list_tinctures(name, lookup("ath_test"))
        |> Enum.map(& &1.name)

      refute "has-png-icon" in names
      GenServer.stop(pid)
    end

    test "rejects tincture with JPEG preview" do
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

      lay!("ath_test", "local", "has-jpg-preview", "1.0.0", manifest)

      name = :test_reject_jpg_preview
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      names =
        TinctureRegistry.list_tinctures(name, lookup("ath_test"))
        |> Enum.map(& &1.name)

      refute "has-jpg-preview" in names
      GenServer.stop(pid)
    end

    test "rejects tincture with convention-discovered PNG icon" do
      manifest = %{
        "name" => "conv-png",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      }

      # discover_media/1 auto-finds this icon by convention even though the
      # manifest doesn't declare it — the validator must still reject it.
      lay!("ath_test", "local", "conv-png", "1.0.0", manifest, [
        {"public/media/icon.png", <<137, 80, 78, 71>>}
      ])

      name = :test_reject_conv_png
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      names =
        TinctureRegistry.list_tinctures(name, lookup("ath_test"))
        |> Enum.map(& &1.name)

      refute "conv-png" in names
      GenServer.stop(pid)
    end

    test "allows SVG icon" do
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

      lay!("ath_test", "local", "svg-ok", "1.0.0", manifest)

      name = :test_allow_svg
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      names =
        TinctureRegistry.list_tinctures(name, lookup("ath_test"))
        |> Enum.map(& &1.name)

      assert "svg-ok" in names
      GenServer.stop(pid)
    end

    test "extension check is case-insensitive" do
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

      lay!("ath_test", "local", "upper-png", "1.0.0", manifest)

      name = :test_upper_png
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # The initial scan runs in handle_continue; a call synchronizes with it.
      :sys.get_state(pid)

      names =
        TinctureRegistry.list_tinctures(name, lookup("ath_test"))
        |> Enum.map(& &1.name)

      refute "upper-png" in names
      GenServer.stop(pid)
    end
  end

  describe "the declared frame" do
    defp lay(name, tincture) do
      manifest = %{
        "name" => name,
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => Map.put(tincture, "entry", "index.html")
      }

      lay!("ath_test", "local", name, "1.0.0", manifest, [{"index.html", "<html></html>"}])
    end

    defp listed(server) do
      {:ok, pid} = TinctureRegistry.start_link(name: server)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      Map.new(TinctureRegistry.list_tinctures(server, lookup("ath_test")), &{&1.name, &1})
    end

    test "each row carries the frame its manifest declares, as the frame's rules read it" do
      frame = %{
        "capabilities" => ["pointer_lock", "fullscreen", "audio_autoplay"],
        "background" => true,
        "size" => %{"preferred" => %{"w" => 400, "h" => 640}, "tile" => "right"}
      }

      lay("declares-frame", %{"frame" => frame})
      rows = listed(:test_declared_frame)

      assert {:ok, declared} =
               Compendium.tincture_declaration(%{"tincture" => %{"frame" => frame}})

      row = rows["declares-frame"]
      assert row.frame == declared.frame
      assert Enum.sort(row.frame.capabilities) == ~w(audio_autoplay fullscreen pointer_lock)
      assert row.frame.placement == nil
      assert row.frame.background == true

      assert row.frame.size == %Prima.Manifest.Tincture.Size{
               preferred: %{w: 400, h: 640},
               tile: "right"
             }

      # A tincture that declares no frame holds none of its capabilities.
      assert rows["test-dash"].frame.capabilities == []
      assert rows["test-dash"].frame.background == false
    end

    test "a canvas is listed with its placement, its page as its entry" do
      manifest = %{
        "name" => "home-canvas",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{
          "frame" => %{"placement" => "canvas"},
          "entry" => "index.html",
          "streams" => [%{"name" => "runs.changes"}]
        }
      }

      lay!("ath_test", "local", "home-canvas", "1.0.0", manifest, [
        {"index.html", "<html><head></head><body></body></html>"}
      ])

      row = listed(:test_canvas_row)["home-canvas"]
      assert %{placement: "canvas", background: false, capabilities: []} = row.frame
      assert row.entry == "index.html"
    end

    test "a tincture whose declaration the rules refuse is listed with no frame to grant" do
      lay("undeclarable", %{"frame" => %{"capabilities" => ["camera"]}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          rows = listed(:test_refused_frame)
          assert Map.has_key?(rows, "undeclarable")
          assert rows["undeclarable"].frame == nil
        end)

      assert log =~ "declares a frame the rules refuse"
    end
  end

  describe "reads bypass the GenServer" do
    test "list and get answer from ETS while the server is suspended" do
      name = :test_suspended_reads
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      # Populate (and mark) the athanor first; the suspended read below
      # must then come straight from ETS.
      :ok = TinctureRegistry.reload_athanor(name, "ath_test")

      :ok = :sys.suspend(pid)

      tinctures = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      assert [%{name: "test-dash"}] = tinctures

      :ok = :sys.resume(pid)
      GenServer.stop(pid)
    end
  end

  describe "the registry's acknowledged epoch" do
    # Another member's commit: it moves the athanor's components epoch, and
    # its announcement goes out on that member's bus, never this node's. The
    # registry is made that member's bystander from inside its own process
    # (`:sys.replace_state/2` runs the function there): it stops listening
    # to the athanor's tinctures topic and forgets it watched it, so its
    # next scan subscribes again.
    defp unheard!(pid, actor) do
      :sys.replace_state(pid, fn state ->
        :ok = Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.tinctures(actor))
        %{state | watching: MapSet.delete(state.watching, actor.athanor_id)}
      end)
    end

    defp held(table, athanor_id) do
      table
      |> :ets.match_object({{athanor_id, :_, :_}, :_})
      |> Enum.map(fn {_key, tincture} -> tincture.name end)
      |> Enum.sort()
    end

    test "a read that finds it moved rescans the athanor, with no announcement heard" do
      name = :test_epoch_marker
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      ctx = lookup("ath_test")
      actor = Sanctum.Context.actor(ctx)

      assert ["test-dash"] = Enum.map(TinctureRegistry.list_tinctures(name, ctx), & &1.name)

      unheard!(pid, actor)
      # The positive control: this process hears the announcement the
      # registry does not.
      :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.tinctures(actor))

      lay!("ath_test", "local", "quiet-dash", "0.1.0", %{
        "name" => "quiet-dash",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      })

      # The commit is acknowledged, and announced, before the registry is
      # read again.
      assert {:ok, _moved} = Compendium.acknowledged_projection_epoch(ctx, "components")
      assert_receive %Cyfr.Bus.Tinctures{kind: :changed}, 5_000

      # The registry heard nothing and rescanned nothing: its table still
      # holds what its scan found, at the epoch the scan began from.
      _ = :sys.get_state(pid)
      assert {:messages, []} = Process.info(pid, :messages)
      assert held(name, "ath_test") == ["test-dash"]

      # The next read finds the epoch moved past the marker and rescans.
      assert ["quiet-dash", "test-dash"] =
               name |> TinctureRegistry.list_tinctures(ctx) |> Enum.map(& &1.name) |> Enum.sort()

      assert held(name, "ath_test") == ["quiet-dash", "test-dash"]

      GenServer.stop(pid)
    end
  end

  describe "startup" do
    test "the table starts empty and the first list populates its athanor" do
      # init only creates the table — there is no boot walk. The first
      # read for an athanor scans exactly that athanor and marks it.
      name = :test_async_init
      {:ok, pid} = TinctureRegistry.start_link(name: name)

      assert :ets.info(name, :size) == 0
      assert [_ | _] = TinctureRegistry.list_tinctures(name, lookup("ath_test"))
      GenServer.stop(pid)
    end

    test "an unresolved athanor lists nothing" do
      name = :test_unresolved
      {:ok, pid} = TinctureRegistry.start_link(name: name)
      :sys.get_state(pid)

      anon = Sanctum.Context.build(user_id: "anon", athanor_id: nil, authenticated: false)
      assert TinctureRegistry.list_tinctures(name, anon) == []
      GenServer.stop(pid)
    end
  end

  # The registry is shell-plane only: every reader carries the member's
  # Context, and the athanor it names is the one listed.
  defp lookup(athanor_id) do
    Sanctum.Context.internal(user_id: "_test", athanor_id: athanor_id, scope: :athanor)
  end
end
