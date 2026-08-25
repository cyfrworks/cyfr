# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Blob, Cache, Client, Reference}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
  end

  describe "pull_bytes/1 - input validation" do
    test "returns error for invalid OCI reference" do
      assert {:error, _} = Client.pull_bytes("")
    end
  end

  describe "pull_bytes/1 - registry-config enforcement" do
    test "rejects pull_bytes from non-cyfr.run registry" do
      {:error, msg} = Client.pull_bytes("ghcr.io/alice/reagents/data-processor:1.0.0")
      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
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

  describe "pull/2 - registry-config enforcement" do
    test "rejects pull from non-cyfr.run registry" do
      {:error, msg} =
        Client.pull(
          %Sanctum.Context{user_id: "test", athanor_id: "ath_test"},
          "ghcr.io/alice/reagents/data-processor:1.0.0"
        )

      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
    end
  end

  describe "push/3 - registry-config enforcement" do
    test "rejects push to non-cyfr.run registry" do
      {:error, msg} =
        Client.push(
          %Sanctum.Context{user_id: "test", athanor_id: "ath_test"},
          "local.my-tool:1.0.0",
          "ghcr.io"
        )

      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
    end
  end

  describe "discover/2 - registry-config enforcement" do
    test "rejects discover with non-cyfr.run registry" do
      {:error, msg} = Client.discover("ghcr.io")
      assert msg =~ "only supports registry.cyfr.run"
      assert msg =~ "ghcr.io"
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

      ctx = Sanctum.TestContext.local()

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, ctx: ctx, test_dir: test_dir}
    end

    test "Arca stores and reads manifest json", %{ctx: ctx} do
      path =
        ["components", "catalysts", "testpub", "my-tool", "1.0.0"] ++
          ["cyfr-manifest.json"]

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
      path =
        ["components", "reagents", "cyfr", "nonexistent", "1.0.0", "README.md"]

      assert {:error, _} = Arca.get(ctx, path)
    end
  end

  # ============================================================================
  # Digest-Pinned Manifest Verification
  # ============================================================================

  describe "digest-pinned manifest verification" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "cyfr_oci_pin_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(test_dir)

      original_base = Application.get_env(:cyfr, :base_path)
      original_registry = Application.get_env(:cyfr, :oci_registry_url)
      original_auth = Application.get_env(:cyfr, :auth_provider)

      Application.put_env(:cyfr, :base_path, test_dir)
      # No auth provider → localhost registries are reachable (allow_private).
      Application.delete_env(:cyfr, :auth_provider)

      on_exit(fn ->
        File.rm_rf!(test_dir)
        restore_env(:base_path, original_base)
        restore_env(:oci_registry_url, original_registry)
        restore_env(:auth_provider, original_auth)
      end)

      :ok
    end

    test "refuses a pinned manifest whose body does not hash to the pin, even when the header vouches for it" do
      wasm = "wasm-bytes-under-test"
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Blob.compute_digest("entirely different content")

      # The registry lies: body doesn't match the pin but the header claims it does.
      port = start_canned_server(manifest_json, [{"docker-content-digest", pin}])
      registry = "localhost:#{port}"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      # Seed the blob cache so that, were the manifest accepted, the pull
      # would fully succeed — the only thing standing in the way is the pin.
      :ok = Cache.put_blob(wasm_digest, wasm)

      assert {:error, msg} = Client.pull_bytes("#{registry}/alice/reagents/pinned@#{pin}")
      assert msg =~ "Digest mismatch"
    end

    test "serves a pinned manifest that hashes to the pin, preferring the computed digest over a lying header" do
      wasm = "wasm-bytes-under-test"
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Blob.compute_digest(manifest_json)

      bogus_header = "sha256:" <> String.duplicate("0", 64)
      port = start_canned_server(manifest_json, [{"docker-content-digest", bogus_header}])
      registry = "localhost:#{port}"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      :ok = Cache.put_blob(wasm_digest, wasm)

      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/alice/reagents/pinned@#{pin}")
    end

    test "a poisoned cache entry under a digest key is discarded and refetched" do
      good_wasm = "good-wasm-bytes"
      evil_wasm = "evil-wasm-bytes"
      {good_json, good_digest} = manifest_fixture(good_wasm)
      {evil_json, evil_digest} = manifest_fixture(evil_wasm)
      pin = Blob.compute_digest(good_json)

      port = start_canned_server(good_json, [])
      registry = "localhost:#{port}"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      # Poisoned entry: recorded under the pin, claims the pin, but the body
      # is a different manifest. Both blobs are cached, so were the poisoned
      # manifest served, the pull would succeed with the evil bytes.
      :ok = Cache.put_manifest(registry, "alice/reagents/pinned", pin, evil_json, pin)
      :ok = Cache.put_blob(evil_digest, evil_wasm)
      :ok = Cache.put_blob(good_digest, good_wasm)

      assert {:ok, bytes} = Client.pull_bytes("#{registry}/alice/reagents/pinned@#{pin}")
      assert bytes == good_wasm
    end

    test "a verified pinned manifest is served from cache without touching the network" do
      wasm = "wasm-bytes-under-test"
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Blob.compute_digest(manifest_json)

      # Nothing listens on port 1 — the cache must satisfy the pull.
      registry = "localhost:1"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      :ok = Cache.put_manifest(registry, "alice/reagents/pinned", pin, manifest_json, pin)
      :ok = Cache.put_blob(wasm_digest, wasm)

      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/alice/reagents/pinned@#{pin}")
    end
  end

  # Minimal OCI image manifest wrapping the given bytes as a reagent WASM
  # layer. Returns {manifest_json, wasm_layer_digest}.
  defp manifest_fixture(wasm_bytes) do
    config = Jason.encode!(%{"name" => "pinned", "version" => "1.0.0", "type" => "reagent"})
    wasm_digest = Blob.compute_digest(wasm_bytes)

    manifest =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "artifactType" => "application/vnd.cyfr.component.v1",
        "config" => %{
          "mediaType" => "application/vnd.cyfr.manifest.v1+json",
          "size" => byte_size(config),
          "digest" => Blob.compute_digest(config)
        },
        "layers" => [
          %{
            "mediaType" => "application/vnd.cyfr.reagent.v1+wasm",
            "size" => byte_size(wasm_bytes),
            "digest" => wasm_digest
          }
        ],
        "annotations" => %{}
      })

    {manifest, wasm_digest}
  end

  # Tiny HTTP responder: answers every request on the listen socket with a
  # 200 carrying `body` plus `extra_headers`. Returns the bound port; the
  # listener is closed via on_exit.
  defp start_canned_server(body, extra_headers) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn(fn -> accept_loop(listen, body, extra_headers) end)
    on_exit(fn -> :gen_tcp.close(listen) end)

    port
  end

  defp accept_loop(listen, body, extra_headers) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        drain_request(sock, "")

        headers = Enum.map_join(extra_headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "content-length: #{byte_size(body)}\r\n" <>
            headers <>
            "connection: close\r\n\r\n" <> body

        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
        accept_loop(listen, body, extra_headers)

      {:error, _} ->
        :ok
    end
  end

  defp drain_request(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        unless String.contains?(acc, "\r\n\r\n"), do: drain_request(sock, acc)

      {:error, _} ->
        :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:cyfr, key)
  defp restore_env(key, value), do: Application.put_env(:cyfr, key, value)
end
