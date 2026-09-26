# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Blob, Cache, Client, Errors, Reference, Transport}
  alias Compendium.Registry.CredentialStore

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
      assert msg =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
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

      assert msg =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
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

      assert msg =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert msg =~ "ghcr.io"
    end
  end

  describe "discover/2 - registry-config enforcement" do
    test "rejects discover with non-cyfr.run registry, typed" do
      assert {:error, %Errors{reason: :registry_host_mismatch, message: msg}} =
               Client.discover("ghcr.io")

      assert msg =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert msg =~ "ghcr.io"
    end

    test "a foreign host is refused with the same typed error before any I/O" do
      canonical = Compendium.RegistryHost.canonical_host()

      assert :ok = Compendium.RegistryHost.validate_host(canonical)

      assert {:error, %Errors{reason: :registry_host_mismatch, registry: "ghcr.io"} = refusal} =
               Compendium.RegistryHost.validate_host("ghcr.io")

      assert Errors.to_string(refusal) =~ "only supports #{canonical}"
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
      previous_base = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, test_dir)

      ctx = Sanctum.TestContext.local()

      on_exit(fn ->
        if previous_base,
          do: Application.put_env(:arca, :base_path, previous_base),
          else: Application.delete_env(:arca, :base_path)

        File.rm_rf!(test_dir)
      end)

      {:ok, ctx: ctx, test_dir: test_dir}
    end

    test "Arca stores and reads manifest json", %{ctx: ctx} do
      path =
        ["components", "catalysts", "testpub", "my-tool", "1.0.0"] ++
          ["cyfr-manifest.json"]

      content = Jason.encode!(%{"name" => "my-tool", "version" => "1.0.0", "schema" => %{}})

      :ok = Arca.put(Sanctum.Context.actor(ctx), path, content)

      {:ok, read_content} = Arca.get(Sanctum.Context.actor(ctx), path)
      assert read_content == content
    end

    test "Arca stores and reads README", %{ctx: ctx} do
      path = ["components", "reagents", "cyfr", "data-proc", "2.0.0", "README.md"]
      readme = "# Data Processor\n\nProcesses data."

      :ok = Arca.put(Sanctum.Context.actor(ctx), path, readme)

      {:ok, read_content} = Arca.get(Sanctum.Context.actor(ctx), path)
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
        :ok = Arca.put(Sanctum.Context.actor(ctx), path, content)
      end

      # Verify files can be read back
      {:ok, cargo_content} = Arca.get(Sanctum.Context.actor(ctx), base ++ ["src", "Cargo.toml"])
      assert cargo_content =~ "tool"

      {:ok, lib_content} = Arca.get(Sanctum.Context.actor(ctx), base ++ ["src", "src", "lib.rs"])
      assert lib_content =~ "fn main()"
    end

    test "reading non-existent file from Arca returns error", %{ctx: ctx} do
      path =
        ["components", "reagents", "cyfr", "nonexistent", "1.0.0", "README.md"]

      assert {:error, _} = Arca.get(Sanctum.Context.actor(ctx), path)
    end
  end

  # ============================================================================
  # Digest-Pinned Manifest Verification
  # ============================================================================

  describe "digest-pinned manifest verification" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "cyfr_oci_pin_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(test_dir)

      original_base = Application.get_env(:arca, :base_path)
      original_registry = Application.get_env(:cyfr, :oci_registry_url)
      original_auth = Application.get_env(:sanctum, :auth_provider)

      Application.put_env(:arca, :base_path, test_dir)
      # No auth provider → localhost registries are reachable (private_policy: :allow_all).
      Application.delete_env(:sanctum, :auth_provider)

      on_exit(fn ->
        File.rm_rf!(test_dir)
        restore_env(:arca, :base_path, original_base)
        restore_env(:oci_registry_url, original_registry)
        restore_env(:sanctum, :auth_provider, original_auth)
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

    test "a verified pinned manifest is served from cache without touching the network while the entitlement stands" do
      wasm = "wasm-bytes-under-test"
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Blob.compute_digest(manifest_json)

      # Nothing listens on port 1 — the cache must satisfy the pull.
      registry = "localhost:1"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      :ok = Cache.put_manifest(registry, "alice/reagents/pinned", pin, manifest_json, pin)
      :ok = Cache.put_blob(wasm_digest, wasm)
      :ok = Cache.entitle("anonymous", registry, "alice/reagents/pinned")

      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/alice/reagents/pinned@#{pin}")
    end
  end

  # ============================================================================
  # Cache authorization
  # ============================================================================

  # A registry that answers only the credentials it is told to allow:
  # 401 to an anonymous caller, 403 to a credential it does not know.
  defmodule Registry do
    @moduledoc false
    @behaviour Plug

    alias Compendium.OCI.Blob

    @impl Plug
    def init(agent), do: agent

    @impl Plug
    def call(conn, agent) do
      auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()

      state =
        Agent.get_and_update(agent, fn state ->
          {state, %{state | requests: [{conn.method, conn.request_path, auth} | state.requests]}}
        end)

      cond do
        (auth || :anonymous) in state.allowed -> serve(conn, state)
        auth == nil -> Plug.Conn.send_resp(conn, 401, "")
        true -> Plug.Conn.send_resp(conn, 403, "")
      end
    end

    defp serve(conn, state) do
      case conn.path_info do
        ["v2", "alice", "reagents", "pinned", "manifests", _ref]
        when state.manifest_status == 200 ->
          conn
          |> Plug.Conn.put_resp_header(
            "docker-content-digest",
            Blob.compute_digest(state.manifest)
          )
          |> Plug.Conn.send_resp(200, state.manifest)

        ["v2", "alice", "reagents", "pinned", "manifests", _ref] ->
          Plug.Conn.send_resp(conn, state.manifest_status, "")

        ["v2", "alice", "reagents", "pinned", "blobs", digest] ->
          case Map.get(state.blobs, digest) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            {:status, status} -> Plug.Conn.send_resp(conn, status, "")
            bytes -> Plug.Conn.send_resp(conn, 200, bytes)
          end

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end
  end

  # The cache is shared by digest, the permission to read it is not: a
  # caller is served cached bytes only once the registry has answered its
  # own credential for the repository.
  describe "cache authorization" do
    @repo "alice/reagents/pinned"

    setup :start_registry

    @tag :capture_log
    test "a private reference one caller warmed is refused to another on every path", ctx do
      %{registry: registry, a: a, b: b, ref: ref, wasm: wasm} = ctx
      allow(ctx.agent, ["Bearer tok_a"])

      # A's reads warm the cache: its blobs, and the manifest entries a
      # pull leaves under the tag and under the pin.
      for digest <- Map.keys(Agent.get(ctx.agent, & &1.blobs)) do
        assert {:ok, _} = Client.fetch_blob(a, ref, digest)
      end

      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)
      :ok = Cache.put_manifest(registry, @repo, ctx.pin, ctx.manifest, ctx.pin)
      assert {:ok, ^wasm} = Cache.get_blob(ctx.wasm_digest)
      requests(ctx.agent)

      # B holds a credential the registry refuses for the repository.
      assert {:error, tag_refusal} = Client.pull(b, "#{registry}/#{@repo}:1.0.0")
      assert tag_refusal =~ "cyfr login"

      assert {:error, pin_refusal} = Client.pull(b, "#{registry}/#{@repo}@#{ctx.pin}")
      assert pin_refusal =~ "cyfr login"

      assert {:error, %Errors{reason: :unauthorized, status: 403}} =
               Client.fetch_blob(b, ref, ctx.wasm_digest)

      # Every refusal was the registry's answer to B's own credential.
      assert [_ | _] = seen = requests(ctx.agent)
      assert Enum.all?(seen, fn {_method, _path, auth} -> auth == "Bearer tok_b" end)
      refute Cache.entitled?(key(b, ref), registry, @repo)
    end

    @tag :capture_log
    test "a revoked credential is refused once its memo expires", ctx do
      %{a: a, ref: ref, wasm: wasm} = ctx
      allow(ctx.agent, ["Bearer tok_a"])
      assert {:ok, ^wasm} = Client.fetch_blob(a, ref, ctx.wasm_digest)

      # Revoked at the registry: the memo still stands, and the cached
      # blob is served without asking.
      allow(ctx.agent, [])
      requests(ctx.agent)
      assert {:ok, ^wasm} = Client.fetch_blob(a, ref, ctx.wasm_digest)
      assert [] = requests(ctx.agent)

      # The memo lapses: the registry is asked again, refuses, and nothing
      # is served or remembered.
      :ok = Cache.forget_entitlement(key(a, ref), ctx.registry, @repo)

      assert {:error, %Errors{reason: :unauthorized}} =
               Client.fetch_blob(a, ref, ctx.wasm_digest)

      assert [{"HEAD", _, "Bearer tok_a"}] = requests(ctx.agent)
      refute Cache.entitled?(key(a, ref), ctx.registry, @repo)
    end

    @tag :capture_log
    test "an unreachable registry serves a cached tag while the entitlement memo holds", ctx do
      %{registry: registry, wasm: wasm} = ctx
      allow(ctx.agent, [:anonymous])

      # An anonymous 200 is a public repository's entitlement.
      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)

      stop_supervised!(:registry)
      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/#{@repo}:1.0.0")
    end

    @tag :capture_log
    test "an unreachable registry serves nothing cached once the entitlement memo is gone", ctx do
      %{registry: registry, wasm: wasm, ref: ref} = ctx
      allow(ctx.agent, [:anonymous])

      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)
      :ok = Cache.forget_entitlement(key(nil, ref), registry, @repo)

      stop_supervised!(:registry)
      assert {:error, message} = Client.pull_bytes("#{registry}/#{@repo}:1.0.0")
      assert message =~ "Failed to connect"
    end

    @tag :capture_log
    test "a registry that no longer holds the tag is never answered from the cache", ctx do
      %{registry: registry, wasm: wasm, ref: ref} = ctx
      allow(ctx.agent, [:anonymous])

      assert {:ok, ^wasm} = Client.pull_bytes("#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)
      assert Cache.entitled?(key(nil, ref), registry, @repo)

      Agent.update(ctx.agent, &%{&1 | manifest_status: 404})
      assert {:error, message} = Client.pull_bytes("#{registry}/#{@repo}:1.0.0")
      assert message =~ "not found"
      refute Cache.entitled?(key(nil, ref), registry, @repo)
    end

    @tag :capture_log
    test "an optional layer the registry does not hold is skipped", ctx do
      %{registry: registry, a: a} = ctx
      allow(ctx.agent, ["Bearer tok_a"])
      readme = with_readme(ctx.agent, 404)

      assert {:ok, %{status: "pulled"}} = Client.pull(a, "#{registry}/#{@repo}:1.0.0")
      assert {"GET", "/v2/#{@repo}/blobs/#{readme}", "Bearer tok_a"} in requests(ctx.agent)
    end

    @tag :capture_log
    test "an optional layer the registry refuses fails the pull", ctx do
      %{registry: registry, a: a} = ctx
      allow(ctx.agent, ["Bearer tok_a"])
      _readme = with_readme(ctx.agent, 401)

      assert {:error, message} = Client.pull(a, "#{registry}/#{@repo}:1.0.0")
      assert message =~ "cyfr login"
    end
  end

  # ============================================================================
  # Signed pulls
  # ============================================================================

  # With signed pulls required, a pull stores a component only when cosign
  # verified the manifest the pull fetched: cosign is asked about
  # `<registry>/<repository>@<digest>` with the digest the pull stores, and
  # its answer must name that digest and a signer. The stand-in cosign is a
  # script under the test's own directory, named by the sigstore config.
  describe "signed pulls" do
    @repo "alice/reagents/pinned"

    setup :start_registry

    setup ctx do
      dir = Path.join(System.tmp_dir!(), "cyfr_oci_cosign_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      original_sigstore = Application.get_env(:cyfr, :sigstore)
      original_required = Application.get_env(:cyfr, :require_signed_pulls)
      Application.put_env(:cyfr, :require_signed_pulls, true)

      on_exit(fn ->
        File.rm_rf!(dir)
        restore_env(:sigstore, original_sigstore)
        restore_env(:require_signed_pulls, original_required)
      end)

      allow(ctx.agent, ["Bearer tok_a"])
      {:ok, cosign_dir: dir, tag_ref: "#{ctx.registry}/#{@repo}:1.0.0"}
    end

    @tag :capture_log
    test "a tag pull is verified at the digest it fetched and records the signer", ctx do
      cosign(ctx, signs: ctx.pin)

      assert {:ok, %{manifest_digest: pin}} = Client.pull(ctx.a, ctx.tag_ref)
      assert pin == ctx.pin
      assert asked(ctx) == ["#{ctx.registry}/#{@repo}@#{ctx.pin}"]

      assert {:ok, component} = Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")
      assert component.signature_verified == true
      assert component.signer_identity == "release@example.com"
      assert component.signer_issuer == "https://accounts.google.com"
    end

    @tag :capture_log
    test "a keyed pull records the key's fingerprint as the signer", ctx do
      path = cosign(ctx, signs: ctx.pin, subject: false)
      key = Path.join(ctx.cosign_dir, "cosign.pub")
      File.write!(key, "-----BEGIN PUBLIC KEY-----\nstand-in\n-----END PUBLIC KEY-----\n")

      Application.put_env(:cyfr, :sigstore,
        verification: :keyed,
        key_path: key,
        cosign_path: path
      )

      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)
      assert asked(ctx) == ["#{ctx.registry}/#{@repo}@#{ctx.pin}"]

      fingerprint = :sha256 |> :crypto.hash(File.read!(key)) |> Base.encode16(case: :lower)
      assert {:ok, component} = Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")
      assert component.signature_verified == true
      assert component.signer_identity == "key:sha256:" <> fingerprint
      assert component.signer_issuer == "key"
    end

    @tag :capture_log
    test "a cached manifest is verified at its stored digest", ctx do
      cosign(ctx, signs: ctx.pin)
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)

      # The second pull is answered from the cache after the registry's
      # HEAD agrees; cosign is asked about the same stored digest.
      requests(ctx.agent)
      assert {:ok, %{manifest_digest: pin}} = Client.pull(ctx.a, ctx.tag_ref)
      assert pin == ctx.pin
      refute {"GET", "/v2/#{@repo}/manifests/1.0.0", "Bearer tok_a"} in requests(ctx.agent)
      assert asked(ctx) == List.duplicate("#{ctx.registry}/#{@repo}@#{ctx.pin}", 2)
    end

    @tag :capture_log
    test "a cached tag whose body does not hash to its digest is refetched", ctx do
      cosign(ctx, signs: ctx.pin)

      # The entry records the signed digest over other bytes: served, the
      # pull would store bytes the signature does not cover.
      forged = ctx.manifest |> Jason.decode!() |> Map.put("annotations", %{"x" => "y"})
      :ok = Cache.put_manifest(ctx.registry, @repo, "1.0.0", Jason.encode!(forged), ctx.pin)
      requests(ctx.agent)

      assert {:ok, %{manifest_digest: pin}} = Client.pull(ctx.a, ctx.tag_ref)
      assert pin == ctx.pin
      assert {"GET", "/v2/#{@repo}/manifests/1.0.0", "Bearer tok_a"} in requests(ctx.agent)
      assert {:ok, manifest, ^pin} = Cache.get_manifest(ctx.registry, @repo, "1.0.0")
      assert manifest == ctx.manifest
    end

    @tag :capture_log
    test "a tag that moved is verified at its new digest, not the signed one", ctx do
      cosign(ctx, signs: ctx.pin)
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)

      moved = move_tag(ctx.agent)
      assert {:error, message} = Client.pull(ctx.a, ctx.tag_ref)
      assert message =~ "no matching signatures"
      assert message =~ "requires signed pulls"
      assert List.last(asked(ctx)) == "#{ctx.registry}/#{@repo}@#{moved}"
    end

    @tag :capture_log
    test "an answer naming a different digest is refused", ctx do
      cosign(ctx, answers: "sha256:" <> String.duplicate("0", 64))

      assert {:error, message} = Client.pull(ctx.a, ctx.tag_ref)
      assert message =~ "different manifest digest"
      assert {:error, :not_found} = Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")
    end

    @tag :capture_log
    test "a cosign that hangs refuses the pull as unavailable in bounded time", ctx do
      cosign(ctx, hangs: true)

      {micros, result} = :timer.tc(fn -> Client.pull(ctx.a, ctx.tag_ref) end)
      assert {:error, message} = result
      assert message =~ "cosign is unavailable"
      assert micros < 10_000_000
    end

    @tag :capture_log
    test "an absent cosign refuses the pull as unavailable", ctx do
      Application.put_env(:cyfr, :sigstore, signer(Path.join(ctx.cosign_dir, "absent")))

      assert {:error, message} = Client.pull(ctx.a, ctx.tag_ref)
      assert message =~ "cosign is unavailable"
    end

    @tag :capture_log
    test "an unset signer refuses the pull before cosign runs", ctx do
      path = cosign(ctx, signs: ctx.pin)
      Application.put_env(:cyfr, :sigstore, verification: :keyless, cosign_path: path)

      assert {:error, message} = Client.pull(ctx.a, ctx.tag_ref)
      assert message =~ "CYFR_COSIGN_IDENTITY and CYFR_COSIGN_ISSUER"
      assert asked(ctx) == []
    end
  end

  defp start_registry(_context) do
    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_oci_entitle_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    original_base = Application.get_env(:arca, :base_path)
    original_registry = Application.get_env(:cyfr, :oci_registry_url)
    original_auth = Application.get_env(:sanctum, :auth_provider)

    Application.put_env(:arca, :base_path, test_dir)
    Application.delete_env(:sanctum, :auth_provider)

    # The smallest valid module: a pull that gets as far as storing it
    # stores it.
    wasm = <<0, ?a, ?s, ?m, 1, 0, 0, 0>>
    {manifest_json, wasm_digest} = manifest_fixture(wasm)
    pin = Blob.compute_digest(manifest_json)

    blobs = %{
      Blob.compute_digest(config_fixture()) => config_fixture(),
      wasm_digest => wasm
    }

    agent = start_supervised!({Agent, fn -> registry_state(manifest_json, blobs) end})

    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__.Registry, agent}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :registry
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    registry = "localhost:#{port}"
    Application.put_env(:cyfr, :oci_registry_url, registry)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      restore_env(:arca, :base_path, original_base)
      restore_env(:oci_registry_url, original_registry)
      restore_env(:sanctum, :auth_provider, original_auth)
    end)

    a = caller("oci_entitle_a")
    b = caller("oci_entitle_b")
    :ok = CredentialStore.put_push_token(a, registry, "alice", "tok_a", "personal")
    :ok = CredentialStore.put_push_token(b, registry, "alice", "tok_b", "personal")

    {:ok,
     registry: registry,
     agent: agent,
     a: a,
     b: b,
     wasm: wasm,
     wasm_digest: wasm_digest,
     manifest: manifest_json,
     pin: pin,
     ref: %Reference{registry: registry, repository: @repo, tag: "1.0.0"}}
  end

  defp signer(cosign_path, extra \\ []) do
    [
      verification: :keyless,
      identity: "^release@example\\.com$",
      issuer: "^https://accounts\\.google\\.com$",
      cosign_path: cosign_path
    ] ++ extra
  end

  # Writes the stand-in cosign and points the sigstore config at it. It
  # appends the reference it is asked about to `refs`, then: `signs:` answers
  # a verified entry for that digest only (without certificate claims when
  # `subject: false`, as a keyed signature answers) and refuses any other
  # reference as real cosign would; `answers:` names the given digest whatever it was
  # asked; `hangs:` never answers (a short timeout keeps the test bounded;
  # the production default stays 30 s).
  defp cosign(ctx, opts) do
    dir = ctx.cosign_dir
    path = Path.join(dir, "cosign")
    answer = Path.join(dir, "answer")
    record = "for ref; do :; done\necho \"$ref\" >> '#{dir}/refs'\n"

    body =
      cond do
        opts[:hangs] ->
          "exec sleep 60\n"

        digest = opts[:signs] ->
          entry = signature_entry(digest)
          entry = if opts[:subject] == false, do: Map.delete(entry, "optional"), else: entry
          File.write!(answer, Jason.encode!([entry]))

          "case \"$ref\" in\n" <>
            "  *@#{digest}) cat '#{answer}' ;;\n" <>
            "  *) echo 'Error: no matching signatures' >&2; exit 1 ;;\n" <>
            "esac\n"

        digest = opts[:answers] ->
          File.write!(answer, Jason.encode!([signature_entry(digest)]))
          "cat '#{answer}'\n"
      end

    File.write!(path, "#!/bin/sh\n" <> record <> body)
    File.chmod!(path, 0o755)

    extra = if opts[:hangs], do: [timeout_ms: 300], else: []
    Application.put_env(:cyfr, :sigstore, signer(path, extra))
    path
  end

  defp signature_entry(digest) do
    %{
      "critical" => %{
        "identity" => %{"docker-reference" => "registry"},
        "image" => %{"docker-manifest-digest" => digest},
        "type" => "cosign container image signature"
      },
      "optional" => %{
        "Subject" => "release@example.com",
        "Issuer" => "https://accounts.google.com"
      }
    }
  end

  # The references the stand-in cosign was asked about, oldest first.
  defp asked(ctx) do
    case File.read(Path.join(ctx.cosign_dir, "refs")) do
      {:ok, refs} -> String.split(refs, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  # Points the tag at a different manifest (same layers, one more
  # annotation) and answers its digest.
  defp move_tag(agent) do
    Agent.get_and_update(agent, fn state ->
      manifest =
        state.manifest
        |> Jason.decode!()
        |> Map.put("annotations", %{"moved" => "true"})
        |> Jason.encode!()

      {Blob.compute_digest(manifest), %{state | manifest: manifest}}
    end)
  end

  defp caller(user_id) do
    Sanctum.Context.build(
      user_id: "#{user_id}_#{System.unique_integer([:positive])}",
      athanor_id: Sanctum.TestContext.local().athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      namespace: "alice",
      authenticated: true
    )
  end

  defp key(ctx, ref) do
    {:ok, key} = Transport.credential_key(ctx, ref)
    key
  end

  defp registry_state(manifest_json, blobs) do
    %{
      allowed: [],
      manifest: manifest_json,
      manifest_status: 200,
      blobs: blobs,
      requests: []
    }
  end

  defp allow(agent, credentials), do: Agent.update(agent, &%{&1 | allowed: credentials})

  # The requests the registry saw since the last call, oldest first.
  defp requests(agent),
    do: Agent.get_and_update(agent, &{Enum.reverse(&1.requests), %{&1 | requests: []}})

  # Adds a README layer to the manifest whose blob the registry answers
  # with `status`, and answers its digest.
  defp with_readme(agent, status) do
    readme = "readme-#{System.unique_integer([:positive])}"
    digest = Blob.compute_digest(readme)

    Agent.update(agent, fn state ->
      manifest =
        state.manifest
        |> Jason.decode!()
        |> Map.update!("layers", fn layers ->
          layers ++
            [
              %{
                "mediaType" => "application/vnd.cyfr.readme.v1+markdown",
                "size" => byte_size(readme),
                "digest" => digest
              }
            ]
        end)
        |> Jason.encode!()

      %{state | manifest: manifest, blobs: Map.put(state.blobs, digest, {:status, status})}
    end)

    digest
  end

  defp config_fixture,
    do: Jason.encode!(%{"name" => "pinned", "version" => "1.0.0", "type" => "reagent"})

  # Minimal OCI image manifest wrapping the given bytes as a reagent WASM
  # layer. Returns {manifest_json, wasm_layer_digest}.
  defp manifest_fixture(wasm_bytes) do
    config = config_fixture()
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
  # 200 carrying `body` plus `extra_headers`, telling `observer` (when one
  # is given) of each connection before it answers. Returns the bound
  # port; the listener is closed via on_exit.
  defp start_canned_server(body, extra_headers, observer \\ nil) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn(fn -> accept_loop(listen, body, extra_headers, observer) end)
    on_exit(fn -> :gen_tcp.close(listen) end)

    port
  end

  defp accept_loop(listen, body, extra_headers, observer) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        if observer, do: send(observer, {:registry_contacted, sock})
        drain_request(sock, "")

        headers = Enum.map_join(extra_headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

        response =
          "HTTP/1.1 200 OK\r\n" <>
            "content-length: #{byte_size(body)}\r\n" <>
            headers <>
            "connection: close\r\n\r\n" <> body

        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
        accept_loop(listen, body, extra_headers, observer)

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

  defp restore_env(key, value), do: restore_env(:cyfr, key, value)

  # `:auth_provider` is the identity domain's key and `:base_path` the
  # storage's; the registry URL is the host's.
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
