defmodule Prism.TinctureRegistryTest do
  use ExUnit.Case, async: false

  alias Prism.TinctureRegistry

  setup do
    # Create a temp tincture structure
    base = Path.join(System.tmp_dir!(), "tincture_reg_test_#{:rand.uniform(1_000_000)}")
    components_dir = Path.join(base, "components")

    tincture_dir = Path.join([components_dir, "tinctures", "local", "test-dash", "1.0.0"])
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

    %{base: base, components_dir: components_dir, tincture_dir: tincture_dir}
  end

  describe "GenServer lifecycle" do
    test "starts and loads tinctures" do
      {:ok, pid} = TinctureRegistry.start_link(name: :test_tincture_reg)

      tinctures = GenServer.call(pid, {:list_tinctures, %{}})
      assert length(tinctures) == 1
      assert hd(tinctures).name == "test-dash"

      GenServer.stop(pid)
    end
  end

  describe "list_tinctures/1" do
    test "returns tinctures for the given scope" do
      {:ok, pid} = TinctureRegistry.start_link(name: :test_list)

      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: ""}})
      assert length(tinctures) == 1

      t = hd(tinctures)
      assert t.name == "test-dash"
      assert t.publisher == "local"
      assert t.version == "1.0.0"
      assert t.entry == "index.html"
      assert t.title == "Test Dashboard"
      assert t.icon == "chart-line"
      assert t.entry_url == "/t/local/test-dash"

      GenServer.stop(pid)
    end

    test "returns empty for non-matching org_id" do
      {:ok, pid} = TinctureRegistry.start_link(name: :test_empty_org)

      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: "nonexistent-org"}})
      assert tinctures == []

      GenServer.stop(pid)
    end
  end

  describe "get_tincture/3" do
    test "finds tincture by publisher and name" do
      {:ok, pid} = TinctureRegistry.start_link(name: :test_get)

      t = GenServer.call(pid, {:get_tincture, %{org_id: ""}, "local", "test-dash"})
      assert t != nil
      assert t.name == "test-dash"
      assert is_map(t.manifest)

      GenServer.stop(pid)
    end

    test "returns nil for unknown tincture" do
      {:ok, pid} = TinctureRegistry.start_link(name: :test_get_nil)

      assert nil == GenServer.call(pid, {:get_tincture, %{org_id: ""}, "local", "nonexistent"})

      GenServer.stop(pid)
    end
  end

  describe "version resolution" do
    test "picks latest version when multiple exist", %{components_dir: components_dir} do
      # Add a newer version
      v2_dir = Path.join([components_dir, "tinctures", "local", "test-dash", "2.0.0"])
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

      {:ok, pid} = TinctureRegistry.start_link(name: :test_version)

      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: ""}})
      assert length(tinctures) == 1
      assert hd(tinctures).version == "2.0.0"

      GenServer.stop(pid)
    end
  end

  describe "reload/0" do
    test "rescans filesystem", %{components_dir: components_dir} do
      {:ok, pid} = TinctureRegistry.start_link(name: :test_reload)

      assert length(GenServer.call(pid, {:list_tinctures, %{org_id: ""}})) == 1

      # Add a new tincture
      new_dir = Path.join([components_dir, "tinctures", "local", "new-tincture", "0.1.0"])
      File.mkdir_p!(new_dir)

      manifest = %{
        "name" => "new-tincture",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      }

      File.write!(Path.join(new_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      :ok = GenServer.call(pid, :reload)

      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: ""}})
      assert length(tinctures) == 2

      GenServer.stop(pid)
    end
  end

  describe "Arx org-scoped tincture loading" do
    test "discovers org-scoped tinctures in arx mode", %{components_dir: components_dir} do
      original_edition = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      # Create org-scoped tincture: components/{org_id}/tinctures/{publisher}/{name}/{version}/
      org_dir = Path.join([components_dir, "org_abc123", "tinctures", "acme", "org-dash", "0.1.0"])
      File.mkdir_p!(org_dir)

      manifest = %{
        "name" => "org-dash",
        "type" => "tincture",
        "version" => "0.1.0",
        "publisher" => "acme",
        "tincture" => %{"entry" => "index.html"}
      }

      File.write!(Path.join(org_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      {:ok, pid} = TinctureRegistry.start_link(name: :test_arx_org)

      # Org-scoped tincture visible to matching org
      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: "org_abc123"}})
      org_names = Enum.map(tinctures, & &1.name)
      assert "org-dash" in org_names

      # Not visible to different org
      other_tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: "org_other"}})
      other_names = Enum.map(other_tinctures, & &1.name)
      refute "org-dash" in other_names

      # Not visible to core scope (empty org_id)
      core_tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: ""}})
      core_names = Enum.map(core_tinctures, & &1.name)
      refute "org-dash" in core_names

      GenServer.stop(pid)

      if original_edition do
        Application.put_env(:cyfr, :edition, original_edition)
      else
        Application.delete_env(:cyfr, :edition)
      end
    end

    test "arx mode still discovers core tinctures", %{components_dir: _components_dir} do
      original_edition = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      {:ok, pid} = TinctureRegistry.start_link(name: :test_arx_core)

      # The setup's core tincture (test-dash with org_id "") should still be found
      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: ""}})
      names = Enum.map(tinctures, & &1.name)
      assert "test-dash" in names

      GenServer.stop(pid)

      if original_edition do
        Application.put_env(:cyfr, :edition, original_edition)
      else
        Application.delete_env(:cyfr, :edition)
      end
    end
  end

  describe "skips non-tincture manifests" do
    test "ignores type=app manifests", %{components_dir: components_dir} do
      app_dir = Path.join([components_dir, "tinctures", "local", "legacy-app", "1.0.0"])
      File.mkdir_p!(app_dir)

      manifest = %{
        "name" => "legacy-app",
        "type" => "app",
        "version" => "1.0.0",
        "publisher" => "local"
      }

      File.write!(Path.join(app_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      {:ok, pid} = TinctureRegistry.start_link(name: :test_skip_app)

      tinctures = GenServer.call(pid, {:list_tinctures, %{org_id: ""}})
      names = Enum.map(tinctures, & &1.name)
      refute "legacy-app" in names

      GenServer.stop(pid)
    end
  end
end
