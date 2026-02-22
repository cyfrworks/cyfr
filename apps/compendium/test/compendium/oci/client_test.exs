defmodule Compendium.OCI.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Client, Reference}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
  end

  describe "pull_bytes/1 - input validation" do
    test "returns error for invalid OCI reference" do
      assert {:error, _} = Client.pull_bytes("")
    end
  end

  describe "pull_bytes/1 - edition enforcement" do
    test "Core edition rejects pull_bytes from non-cyfr.run registry" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} = Client.pull_bytes("ghcr.io/alice/reagents/data-processor:1.0.0")
        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition allows pull_bytes from any registry" do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        # Will fail at network level, not at edition check
        result = Client.pull_bytes("ghcr.io/alice/reagents/data-processor:1.0.0")

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end
  end

  describe "OCI reference detection in pull routing" do
    test "oci_ref? detects OCI-style references" do
      assert Reference.oci_ref?("ghcr.io/cyfr/reagents/test:1.0.0")
      assert Reference.oci_ref?("docker.io/library/nginx:latest")
      assert Reference.oci_ref?("localhost:5000/repo/name:v1")
    end

    test "oci_ref? rejects non-OCI references" do
      refute Reference.oci_ref?("catalyst:local.claude:0.1.0")
      refute Reference.oci_ref?("local.claude:0.1.0")
      refute Reference.oci_ref?("./components/test.wasm")
      refute Reference.oci_ref?("/absolute/path.wasm")
    end
  end

  describe "pull/2 - edition enforcement" do
    test "Core edition rejects pull from non-cyfr.run registry" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} = Client.pull(%Sanctum.Context{user_id: "test", org_id: "test"},
                                     "ghcr.io/alice/reagents/data-processor:1.0.0")
        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition allows pull from any registry" do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        result = Client.pull(%Sanctum.Context{user_id: "test", org_id: "test"},
                              "ghcr.io/alice/reagents/data-processor:1.0.0")

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end
  end

  describe "push/3 - edition enforcement" do
    test "Core edition rejects push to non-cyfr.run registry" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} = Client.push(%Sanctum.Context{user_id: "test", org_id: "test"},
                                     "local.my-tool:1.0.0", "ghcr.io")
        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition allows push to any registry" do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        result = Client.push(%Sanctum.Context{user_id: "test", org_id: "test"},
                              "local.my-tool:1.0.0", "ghcr.io")

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end
  end

  describe "discover/2 - edition enforcement" do
    test "Core edition rejects discover with non-cyfr.run registry" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)

      try do
        {:error, msg} = Client.discover("ghcr.io")
        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end

    test "Arx edition allows discover with any registry" do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      Application.put_env(:sanctum_arx, :edition, :arx)

      try do
        result = Client.discover("ghcr.io")

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
      end
    end
  end

  describe "discover/2 - input validation" do
    # Note: actual network calls will fail in test without a running registry,
    # but we can test that the function handles errors gracefully.
    test "returns error when registry is unreachable" do
      result = Client.discover("nonexistent-registry.invalid")
      assert {:error, _reason} = result
    end
  end

  describe "startup validation" do
    test "validate_registry_config! raises for Core + non-cyfr.run registry" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      original_registry = Application.get_env(:compendium, :registry)

      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)
      Application.put_env(:compendium, :registry, url: "ghcr.io", username: nil, password: nil)

      try do
        assert_raise RuntimeError, ~r/Registry misconfiguration detected/, fn ->
          # Restart the app to trigger validation
          # Instead, test the validation function directly via Application start
          Compendium.Application.start(:normal, [])
        end
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
        if original_registry, do: Application.put_env(:compendium, :registry, original_registry),
          else: Application.delete_env(:compendium, :registry)
      end
    end

    test "validate_registry_config! allows Core + cyfr.run registry" do
      original_sanctum = Application.get_env(:sanctum, :edition)
      original_arx = Application.get_env(:sanctum_arx, :edition)
      original_registry = Application.get_env(:compendium, :registry)

      Application.put_env(:sanctum, :edition, :community)
      Application.put_env(:sanctum_arx, :edition, :community)
      Application.put_env(:compendium, :registry, url: "registry.cyfr.run", username: nil, password: nil)

      try do
        # Should not raise — cyfr.run is fine for Core
        # We can't fully start the app (already running), but we can verify
        # the validation doesn't raise by calling start which will fail
        # at supervision tree level (already started), not at validation
        case Compendium.Application.start(:normal, []) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, _} -> :ok  # Any error that's NOT a RuntimeError is fine
        end
      after
        if original_sanctum, do: Application.put_env(:sanctum, :edition, original_sanctum),
          else: Application.delete_env(:sanctum, :edition)
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
        if original_registry, do: Application.put_env(:compendium, :registry, original_registry),
          else: Application.delete_env(:compendium, :registry)
      end
    end

    test "validate_registry_config! allows Arx + any registry" do
      original_arx = Application.get_env(:sanctum_arx, :edition)
      original_registry = Application.get_env(:compendium, :registry)

      Application.put_env(:sanctum_arx, :edition, :arx)
      Application.put_env(:compendium, :registry, url: "ghcr.io", username: nil, password: nil)

      try do
        case Compendium.Application.start(:normal, []) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, _} -> :ok
        end
      after
        if original_arx, do: Application.put_env(:sanctum_arx, :edition, original_arx),
          else: Application.delete_env(:sanctum_arx, :edition)
        if original_registry, do: Application.put_env(:compendium, :registry, original_registry),
          else: Application.delete_env(:compendium, :registry)
      end
    end
  end
end
