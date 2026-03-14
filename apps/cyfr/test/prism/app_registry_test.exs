defmodule Prism.AppRegistryTest do
  use ExUnit.Case, async: false

  alias Prism.AppRegistry

  @test_apps_dir "test/fixtures/apps"

  setup do
    # Create fixture directory with a sample app
    app_dir = Path.join(@test_apps_dir, "local/testapp/1.0.0")
    File.mkdir_p!(app_dir)

    manifest = %{
      "name" => "testapp",
      "type" => "app",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Test App",
      "setup" => %{
        "policy" => %{
          "allowed_tools" => ["execution.list"],
          "timeout" => "0"
        }
      },
      "app" => %{
        "entry" => "index.html",
        "icon" => "cube",
        "window" => %{"width" => 600, "height" => 400}
      }
    }

    File.write!(Path.join(app_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(app_dir, "index.html"), "<html><body>Test</body></html>")

    # Also create a non-app manifest that should be ignored
    non_app_dir = Path.join(@test_apps_dir, "local/notanapp/1.0.0")
    File.mkdir_p!(non_app_dir)

    non_app_manifest = %{"name" => "notanapp", "type" => "catalyst", "version" => "1.0.0"}
    File.write!(Path.join(non_app_dir, "cyfr-manifest.json"), Jason.encode!(non_app_manifest))

    # Terminate the supervised AppRegistry so we can start with test config.
    # Use Supervisor.terminate_child to prevent auto-restart.
    Supervisor.terminate_child(Cyfr.Supervisor, Prism.AppRegistry)

    {:ok, pid} = AppRegistry.start_link(apps_dir: @test_apps_dir)

    on_exit(fn ->
      File.rm_rf!(@test_apps_dir)
      if Process.alive?(pid), do: GenServer.stop(pid)
      # Restart the supervised instance
      Supervisor.restart_child(Cyfr.Supervisor, Prism.AppRegistry)
    end)

    :ok
  end

  describe "list_apps/0" do
    test "returns parsed app manifests" do
      apps = AppRegistry.list_apps()
      assert length(apps) == 1

      [app] = apps
      assert app.name == "testapp"
      assert app.publisher == "local"
      assert app.version == "1.0.0"
      assert app.title == "Test App"
      assert app.icon == "cube"
      assert app.entry == "index.html"
      assert app.entry_url == "/apps/local/testapp/1.0.0/index.html"
    end

    test "ignores non-app manifests" do
      apps = AppRegistry.list_apps()
      refute Enum.any?(apps, &(&1.name == "notanapp"))
    end
  end

  describe "get_app/1" do
    test "finds app by name" do
      assert %{name: "testapp"} = AppRegistry.get_app("testapp")
    end

    test "strips iframe_ prefix" do
      assert %{name: "testapp"} = AppRegistry.get_app("iframe_testapp")
    end

    test "returns nil for unknown app" do
      assert nil == AppRegistry.get_app("nonexistent")
    end
  end

  describe "reload/0" do
    test "rescans the filesystem" do
      assert :ok = AppRegistry.reload()
      assert length(AppRegistry.list_apps()) == 1
    end
  end

  describe "manifest parsing" do
    test "preserves manifest data for permission checks" do
      [app] = AppRegistry.list_apps()
      assert app.manifest["setup"]["policy"]["allowed_tools"] == ["execution.list"]
    end

    test "resolves entry URL with publisher/name/version path" do
      [app] = AppRegistry.list_apps()
      assert app.entry_url =~ "/apps/local/testapp/1.0.0/"
    end
  end
end
