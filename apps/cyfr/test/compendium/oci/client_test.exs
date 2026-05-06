defmodule Compendium.OCI.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Client, Reference}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
  end

  describe "pull_bytes/1 - input validation" do
    test "returns error for invalid OCI reference" do
      assert {:error, _} = Client.pull_bytes("")
    end
  end

  describe "pull_bytes/1 - edition enforcement" do
    test "Core edition rejects pull_bytes from non-cyfr.run registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :core)

      try do
        {:error, msg} = Client.pull_bytes("ghcr.io/alice/reagents/data-processor:1.0.0")
        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
      end
    end

    test "Arx edition allows pull_bytes from any registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      try do
        # Will fail at network level, not at edition check
        result = Client.pull_bytes("ghcr.io/alice/reagents/data-processor:1.0.0")

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
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
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :core)

      try do
        {:error, msg} =
          Client.pull(
            %Sanctum.Context{user_id: "test", org_id: "test"},
            "ghcr.io/alice/reagents/data-processor:1.0.0"
          )

        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
      end
    end

    test "Arx edition allows pull from any registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      try do
        result =
          Client.pull(
            %Sanctum.Context{user_id: "test", org_id: "test"},
            "ghcr.io/alice/reagents/data-processor:1.0.0"
          )

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
      end
    end
  end

  describe "push/3 - edition enforcement" do
    test "Core edition rejects push to non-cyfr.run registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :core)

      try do
        {:error, msg} =
          Client.push(
            %Sanctum.Context{user_id: "test", org_id: "test"},
            "local.my-tool:1.0.0",
            "ghcr.io"
          )

        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
      end
    end

    test "Arx edition allows push to any registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      try do
        result =
          Client.push(
            %Sanctum.Context{user_id: "test", org_id: "test"},
            "local.my-tool:1.0.0",
            "ghcr.io"
          )

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
      end
    end
  end

  describe "discover/2 - edition enforcement" do
    test "Core edition rejects discover with non-cyfr.run registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :core)

      try do
        {:error, msg} = Client.discover("ghcr.io")
        assert msg =~ "Core edition only supports registry.cyfr.run"
        assert msg =~ "ghcr.io"
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
      end
    end

    test "Arx edition allows discover with any registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      Application.put_env(:cyfr, :edition, :arx)

      try do
        result = Client.discover("ghcr.io")

        case result do
          {:error, msg} -> refute msg =~ "Core edition only supports"
          {:ok, _} -> :ok
        end
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)
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

  # ============================================================================
  # Tar Roundtrip Tests (validates source tarball creation/extraction logic)
  # ============================================================================

  describe "source tarball roundtrip" do
    # Helper to create tar via temp file (OTP 28 compatible)
    defp create_test_tar(entries) do
      tmp = Path.join(System.tmp_dir!(), "cyfr_test_tar_#{:rand.uniform(1_000_000)}.tar")
      :ok = :erl_tar.create(String.to_charlist(tmp), entries)
      {:ok, tar_binary} = File.read(tmp)
      File.rm!(tmp)
      tar_binary
    end

    test "tar.gz create and extract roundtrip preserves files" do
      files = [
        {"Cargo.toml", "[package]\nname = \"test\""},
        {"src/lib.rs", "fn main() {}"},
        {"src/utils/helper.rs", "pub fn help() {}"}
      ]

      tar_entries =
        Enum.map(files, fn {path, content} ->
          {String.to_charlist(path), content}
        end)

      tar_binary = create_test_tar(tar_entries)
      gzipped = :zlib.gzip(tar_binary)

      # Extract tarball (same as maybe_store_source)
      ungzipped = :zlib.gunzip(gzipped)
      {:ok, extracted} = :erl_tar.extract({:binary, ungzipped}, [:memory])

      extracted_map =
        Map.new(extracted, fn {name, content} ->
          {to_string(name), content}
        end)

      assert extracted_map["Cargo.toml"] == "[package]\nname = \"test\""
      assert extracted_map["src/lib.rs"] == "fn main() {}"
      assert extracted_map["src/utils/helper.rs"] == "pub fn help() {}"
    end

    test "empty tar creates valid gzip" do
      tar_binary = create_test_tar([])
      gzipped = :zlib.gzip(tar_binary)

      ungzipped = :zlib.gunzip(gzipped)
      {:ok, extracted} = :erl_tar.extract({:binary, ungzipped}, [:memory])
      assert extracted == []
    end

    test "tar handles binary content" do
      binary_content = :crypto.strong_rand_bytes(256)

      tar_binary = create_test_tar([{~c"binary.wasm", binary_content}])
      gzipped = :zlib.gzip(tar_binary)

      ungzipped = :zlib.gunzip(gzipped)
      {:ok, [{name, content}]} = :erl_tar.extract({:binary, ungzipped}, [:memory])
      assert to_string(name) == "binary.wasm"
      assert content == binary_content
    end
  end

  # ============================================================================
  # Pull Layer Storage Integration Tests
  # ============================================================================

  describe "pull layer storage" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "cyfr_client_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(test_dir)
      Application.put_env(:cyfr, :base_path, test_dir)
      Application.put_env(:cyfr, :components_path, Path.join(test_dir, "components"))

      ctx = Sanctum.TestContext.local()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, ctx: ctx, test_dir: test_dir}
    end

    test "Arca stores and reads manifest json", %{ctx: ctx} do
      path = ["components", "catalysts", "testpub", "my-tool", "1.0.0", "cyfr-manifest.json"]
      content = Jason.encode!(%{"name" => "my-tool", "version" => "1.0.0", "schema" => %{}})

      :ok = Arca.put(ctx, path, content)

      {:ok, read_content} = Arca.get(ctx, path)
      assert read_content == content
    end

    test "Arca stores and reads README", %{ctx: ctx} do
      path = ["components", "reagents", "cyfr", "data-proc", "2.0.0", "README.md"]
      readme = "# Data Processor\n\nProcesses data."

      :ok = Arca.put(ctx, path, readme)

      {:ok, read_content} = Arca.get(ctx, path)
      assert read_content == readme
    end

    test "Arca stores extracted source files at correct paths", %{ctx: ctx} do
      base = ["components", "catalysts", "cyfr", "tool", "1.0.0"]

      # Simulate what maybe_store_source does
      files = [
        {["src", "Cargo.toml"], "[package]\nname = \"tool\""},
        {["src", "src", "lib.rs"], "fn main() {}"}
      ]

      for {segments, content} <- files do
        path = base ++ segments
        :ok = Arca.put(ctx, path, content)
      end

      # Verify files can be read back
      {:ok, cargo_content} = Arca.get(ctx, base ++ ["src", "Cargo.toml"])
      assert cargo_content =~ "tool"

      {:ok, lib_content} = Arca.get(ctx, base ++ ["src", "src", "lib.rs"])
      assert lib_content =~ "fn main()"
    end

    test "reading non-existent file from Arca returns error", %{ctx: ctx} do
      path = ["components", "reagents", "cyfr", "nonexistent", "1.0.0", "README.md"]
      assert {:error, _} = Arca.get(ctx, path)
    end
  end

  describe "startup validation" do
    test "validate_registry_config! raises for Core + non-cyfr.run :registry_url" do
      original_arx = Application.get_env(:cyfr, :edition)
      original_url = Application.get_env(:cyfr, :registry_url)

      Application.put_env(:cyfr, :edition, :core)
      Application.put_env(:cyfr, :registry_url, "ghcr.io")

      try do
        assert_raise RuntimeError, ~r/Registry URL misconfiguration/, fn ->
          Compendium.Application.validate_registry_config!()
        end
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)

        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)
      end
    end

    test "validate_registry_config! raises for Core + non-registry.cyfr.run :oci_registry_url" do
      original_arx = Application.get_env(:cyfr, :edition)
      original_oci = Application.get_env(:cyfr, :oci_registry_url)

      Application.put_env(:cyfr, :edition, :core)
      Application.put_env(:cyfr, :oci_registry_url, "ghcr.io")

      try do
        assert_raise RuntimeError, ~r/OCI Registry URL misconfiguration/, fn ->
          Compendium.Application.validate_registry_config!()
        end
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)

        if original_oci,
          do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
          else: Application.delete_env(:cyfr, :oci_registry_url)
      end
    end

    test "validate_registry_config! allows Core + cyfr.run defaults" do
      original_arx = Application.get_env(:cyfr, :edition)
      original_url = Application.get_env(:cyfr, :registry_url)
      original_oci = Application.get_env(:cyfr, :oci_registry_url)

      Application.put_env(:cyfr, :edition, :core)
      Application.put_env(:cyfr, :registry_url, "cyfr.run")
      Application.put_env(:cyfr, :oci_registry_url, "registry.cyfr.run")

      try do
        Compendium.Application.validate_registry_config!()
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)

        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_oci,
          do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
          else: Application.delete_env(:cyfr, :oci_registry_url)
      end
    end

    test "validate_registry_config! allows Arx + any registry" do
      original_arx = Application.get_env(:cyfr, :edition)
      original_url = Application.get_env(:cyfr, :registry_url)
      original_oci = Application.get_env(:cyfr, :oci_registry_url)

      Application.put_env(:cyfr, :edition, :arx)
      Application.put_env(:cyfr, :registry_url, "api.acme.internal")
      Application.put_env(:cyfr, :oci_registry_url, "registry.acme.internal")

      try do
        Compendium.Application.validate_registry_config!()
      after
        if original_arx,
          do: Application.put_env(:cyfr, :edition, original_arx),
          else: Application.delete_env(:cyfr, :edition)

        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_oci,
          do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
          else: Application.delete_env(:cyfr, :oci_registry_url)
      end
    end
  end
end
