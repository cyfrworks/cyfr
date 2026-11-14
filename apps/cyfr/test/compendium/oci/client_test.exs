# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Cache, Client, Errors, Reference, Transport}
  alias Compendium.Registry.CredentialStore

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
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

    test "a foreign host is refused with a typed error before any I/O" do
      canonical = Compendium.RegistryHost.canonical_host()

      assert :ok = Compendium.RegistryHost.validate_host(canonical)

      assert {:error, %Errors{reason: :registry_host_mismatch, registry: "ghcr.io"} = refusal} =
               Compendium.RegistryHost.validate_host("ghcr.io")

      assert Errors.to_string(refusal) =~ "only supports #{canonical}"
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

  # ============================================================================
  # Digest-Pinned Manifest Verification
  # ============================================================================

  describe "digest-pinned manifest verification" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "cyfr_oci_pin_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(test_dir)

      original_base = Application.get_env(:arca, :base_path)
      original_registry = Application.get_env(:cyfr, :oci_registry_url)

      Application.put_env(:arca, :base_path, test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
        restore_env(:arca, :base_path, original_base)
        restore_env(:oci_registry_url, original_registry)
      end)

      # A caller holding no push token: every request it makes is anonymous.
      {:ok, caller: caller("oci_pin")}
    end

    test "refuses a pinned manifest whose body does not hash to the pin, even when the header vouches for it",
         %{caller: caller} do
      wasm = wasm_module("under-test")
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Prima.Digest.sha256("entirely different content")

      # The registry lies: body doesn't match the pin but the header claims it does.
      port = start_canned_server(manifest_json, [{"docker-content-digest", pin}])
      registry = "localhost:#{port}"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      # Seed the blob cache so that, were the manifest accepted, the pull
      # would fully succeed — the only thing standing in the way is the pin.
      :ok = put_blobs(wasm_digest, wasm)

      assert {:error, msg} = Client.pull(caller, "#{registry}/alice/reagents/pinned@#{pin}")
      assert msg =~ "Digest mismatch"
    end

    test "serves a pinned manifest that hashes to the pin, preferring the computed digest over a lying header",
         %{caller: caller} do
      wasm = wasm_module("under-test")
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Prima.Digest.sha256(manifest_json)

      bogus_header = "sha256:" <> String.duplicate("0", 64)
      port = start_canned_server(manifest_json, [{"docker-content-digest", bogus_header}])
      registry = "localhost:#{port}"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      :ok = put_blobs(wasm_digest, wasm)

      assert {:ok, %{digest: ^wasm_digest, manifest_digest: ^pin}} =
               Client.pull(caller, "#{registry}/alice/reagents/pinned@#{pin}")
    end

    test "a poisoned cache entry under a digest key is discarded and refetched",
         %{caller: caller} do
      good_wasm = wasm_module("good")
      evil_wasm = wasm_module("evil")
      {good_json, good_digest} = manifest_fixture(good_wasm)
      {evil_json, evil_digest} = manifest_fixture(evil_wasm)
      pin = Prima.Digest.sha256(good_json)

      port = start_canned_server(good_json, [])
      registry = "localhost:#{port}"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      # Poisoned entry: recorded under the pin, claims the pin, but the body
      # is a different manifest. Both blobs are cached, so were the poisoned
      # manifest served, the pull would succeed with the evil bytes.
      :ok = Cache.put_manifest(registry, "alice/reagents/pinned", pin, evil_json, pin)
      :ok = put_blobs(evil_digest, evil_wasm)
      :ok = put_blobs(good_digest, good_wasm)

      assert {:ok, %{digest: ^good_digest}} =
               Client.pull(caller, "#{registry}/alice/reagents/pinned@#{pin}")
    end

    test "a verified pinned manifest is served from cache without touching the network while the entitlement stands",
         %{caller: caller} do
      wasm = wasm_module("under-test")
      {manifest_json, wasm_digest} = manifest_fixture(wasm)
      pin = Prima.Digest.sha256(manifest_json)

      # Nothing listens on port 1 — the cache must satisfy the pull.
      registry = "localhost:1"
      Application.put_env(:cyfr, :oci_registry_url, registry)

      :ok = Cache.put_manifest(registry, "alice/reagents/pinned", pin, manifest_json, pin)
      :ok = put_blobs(wasm_digest, wasm)
      :ok = Cache.entitle("anonymous", registry, "alice/reagents/pinned")

      assert {:ok, %{digest: ^wasm_digest}} =
               Client.pull(caller, "#{registry}/alice/reagents/pinned@#{pin}")
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
        ["v2", "alice", "reagents", "pinned", "tags", "list"] when is_list(state.tags) ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"name" => "alice/reagents/pinned", "tags" => state.tags})
          )

        ["v2", "alice", "reagents", "pinned", "manifests", ref]
        when state.manifest_status == 200 ->
          manifest = Map.get(state.manifests, ref, state.manifest)

          conn
          |> Plug.Conn.put_resp_header("docker-content-digest", Prima.Digest.sha256(manifest))
          |> Plug.Conn.send_resp(200, manifest)

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
    test "a private reference one caller warmed is refused to another by tag and by pin", ctx do
      %{registry: registry, a: a, b: b, ref: ref, wasm: wasm} = ctx
      allow(ctx.agent, ["Bearer tok_a"])

      # A's pull warms the cache: its blobs, and the manifest entries a
      # pull leaves under the tag and under the pin.
      assert {:ok, _} = Client.pull(a, "#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)
      :ok = Cache.put_manifest(registry, @repo, ctx.pin, ctx.manifest, ctx.pin)
      assert {:ok, ^wasm} = Cache.get_blob(ctx.wasm_digest)
      requests(ctx.agent)

      # B holds a credential the registry refuses for the repository. A
      # pull asks for a blob only once the manifest path has proven the
      # caller's entitlement, so each refusal comes before any cached blob.
      assert {:error, tag_refusal} = Client.pull(b, "#{registry}/#{@repo}:1.0.0")
      assert tag_refusal =~ "cyfr registry sync"

      assert {:error, pin_refusal} = Client.pull(b, "#{registry}/#{@repo}@#{ctx.pin}")
      assert pin_refusal =~ "cyfr registry sync"

      # Every refusal was the registry's answer to B's own credential.
      assert [_ | _] = seen = requests(ctx.agent)
      assert Enum.all?(seen, fn {_method, _path, auth} -> auth == "Bearer tok_b" end)
      refute Cache.entitled?(key(b, ref), registry, @repo)
    end

    @tag :capture_log
    test "a revoked credential is refused once its memo expires", ctx do
      %{a: a, ref: ref, wasm_digest: wasm_digest} = ctx
      pinned = "#{ctx.registry}/#{@repo}@#{ctx.pin}"
      allow(ctx.agent, ["Bearer tok_a"])
      assert {:ok, %{digest: ^wasm_digest}} = Client.pull(a, pinned)

      # Revoked at the registry: the memo still stands, and the cached
      # manifest and blobs are served without asking.
      allow(ctx.agent, [])
      requests(ctx.agent)
      assert {:ok, %{digest: ^wasm_digest}} = Client.pull(a, pinned)
      assert [] = requests(ctx.agent)

      # The memo lapses: the registry is asked again, refuses, and nothing
      # is served or remembered.
      :ok = Cache.forget_entitlement(key(a, ref), ctx.registry, @repo)

      assert {:error, refusal} = Client.pull(a, pinned)
      assert refusal =~ "cyfr registry sync"
      assert [{"HEAD", _, "Bearer tok_a"}] = requests(ctx.agent)
      refute Cache.entitled?(key(a, ref), ctx.registry, @repo)
    end

    @tag :capture_log
    test "an unreachable registry serves a cached tag while the entitlement memo holds", ctx do
      %{registry: registry, wasm_digest: wasm_digest, anonymous: anonymous} = ctx
      allow(ctx.agent, [:anonymous])

      # An anonymous 200 is a public repository's entitlement.
      assert {:ok, %{digest: ^wasm_digest}} = Client.pull(anonymous, "#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)

      stop_supervised!(:registry)
      assert {:ok, %{digest: ^wasm_digest}} = Client.pull(anonymous, "#{registry}/#{@repo}:1.0.0")
    end

    @tag :capture_log
    test "an unreachable registry serves nothing cached once the entitlement memo is gone", ctx do
      %{registry: registry, wasm_digest: wasm_digest, ref: ref, anonymous: anonymous} = ctx
      allow(ctx.agent, [:anonymous])

      assert {:ok, %{digest: ^wasm_digest}} = Client.pull(anonymous, "#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)
      :ok = Cache.forget_entitlement(key(anonymous, ref), registry, @repo)

      stop_supervised!(:registry)
      assert {:error, message} = Client.pull(anonymous, "#{registry}/#{@repo}:1.0.0")
      assert message =~ "Failed to connect"
    end

    @tag :capture_log
    test "a registry that does not hold the tag is never answered from the cache", ctx do
      %{registry: registry, wasm_digest: wasm_digest, ref: ref, anonymous: anonymous} = ctx
      allow(ctx.agent, [:anonymous])

      assert {:ok, %{digest: ^wasm_digest}} = Client.pull(anonymous, "#{registry}/#{@repo}:1.0.0")
      :ok = Cache.put_manifest(registry, @repo, "1.0.0", ctx.manifest, ctx.pin)
      assert Cache.entitled?(key(anonymous, ref), registry, @repo)

      Agent.update(ctx.agent, &%{&1 | manifest_status: 404})
      assert {:error, message} = Client.pull(anonymous, "#{registry}/#{@repo}:1.0.0")
      assert message =~ "not found"
      refute Cache.entitled?(key(anonymous, ref), registry, @repo)
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
      assert message =~ "cyfr registry sync"
    end
  end

  # A pull's README and src/ layers ride the unit it stores: the README at
  # the version's root, each source file under src/ at its own path. Its
  # src/ layer inflates under the version's ceiling: a small blob that
  # expands past it refuses the pull before anything is stored.
  describe "a pull's source layer" do
    @repo "alice/reagents/pinned"

    setup :start_registry

    test "the manifest, the README and every source file are stored in the pulled version, byte for byte",
         ctx do
      %{registry: registry, a: a} = ctx
      allow(ctx.agent, ["Bearer tok_a"])

      binary = :crypto.strong_rand_bytes(256)

      files = [
        {"Cargo.toml", "[package]\nname = \"pinned\""},
        {"src/lib.rs", "fn main() {}"},
        {"src/utils/helper.rs", "pub fn help() {}"},
        {"assets/blob.bin", binary}
      ]

      {:ok, layer} =
        Compendium.Archive.create_tar_gz(
          for {path, content} <- files, do: {String.to_charlist(path), content}
        )

      with_source(ctx.agent, layer)
      readme = "# Pinned\n\nA reagent."
      with_readme(ctx.agent, 200, readme)

      assert {:ok, %{status: "pulled"}} = Client.pull(a, "#{registry}/#{@repo}:1.0.0")

      version = Compendium.ComponentPath.version_dir("reagent", "alice", "pinned", "1.0.0")
      actor = Sanctum.Context.actor(a)

      assert {:ok, ^readme} = Arca.get(actor, version ++ ["README.md"])
      manifest = config_fixture()
      assert {:ok, ^manifest} = Arca.get(actor, version ++ ["cyfr-manifest.json"])

      for {path, content} <- files do
        assert {:ok, ^content} = Arca.get(actor, version ++ ["src" | String.split(path, "/")]),
               "src/#{path} was not stored as the layer carried it"
      end
    end

    @tag :capture_log
    test "a layer that inflates past the version's ceiling refuses the pull", ctx do
      %{registry: registry, a: a} = ctx
      allow(ctx.agent, ["Bearer tok_a"])

      original = Application.get_env(:cyfr, :tincture_max_decompressed_bytes)
      Application.put_env(:cyfr, :tincture_max_decompressed_bytes, 4096)
      on_exit(fn -> restore_env(:tincture_max_decompressed_bytes, original) end)

      # A few hundred bytes on the wire that inflate to a tar of 64 KiB.
      {:ok, layer} =
        Compendium.Archive.create_tar_gz([{~c"bundle.js", :binary.copy(<<0>>, 65_536)}])

      assert byte_size(layer) < 4096
      with_source(ctx.agent, layer)

      result = Client.pull(a, "#{registry}/#{@repo}:1.0.0")

      assert match?({:error, _}, result),
             "pulled with its source layer inflated past the ceiling: #{inspect(result)}"

      assert {:error, {:invalid_argument, message}} = result
      assert message =~ "Source layer decompresses beyond the allowed limit (4096 bytes)"

      assert {:error, :not_found} =
               Compendium.Registry.get(a, "pinned", "1.0.0", "alice", "reagent")
    end
  end

  # A caller with no registry credential pulls anonymously, and the
  # component tool adds the sign-in note to whatever refused the pull, a
  # typed refusal that `Client.pull/2` answers as itself included.
  describe "an anonymous pull through the component tool" do
    @repo "alice/reagents/pinned"

    setup :start_registry

    @tag :capture_log
    test "a typed refusal reads as its sentence, followed by the sign-in note", ctx do
      allow(ctx.agent, [:anonymous])
      anonymous = caller("oci_anonymous")

      # The pull reaches the store, whose cap refuses it with a tuple of
      # the shared table.
      Cyfr.Test.Settings.put("athanor_storage_bytes", 1)
      Arca.Usage.invalidate(Sanctum.Context.actor(anonymous))

      assert {:error, message} =
               Compendium.Provider.handle("component", anonymous, %{
                 "action" => "pull",
                 "reference" => "#{ctx.registry}/#{@repo}:1.0.0"
               })

      assert message =~ Sanctum.Refusals.render({:limit_reached, :athanor_storage_bytes, 1})
      assert message =~ "No credentials configured for"
      assert message =~ "cyfr registry sync"
    end
  end

  # A reference with no version takes the newest release the registry
  # offers, whatever version is already installed.
  describe "a pull that names no version" do
    @repo "alice/reagents/pinned"

    setup :start_registry

    test "takes the registry's newest release, not the version installed", ctx do
      allow(ctx.agent, [:anonymous])
      anonymous = caller("oci_newest")

      pull = fn reference ->
        Compendium.Provider.handle("component", anonymous, %{
          "action" => "pull",
          "reference" => reference
        })
      end

      assert {:ok, %{component_ref: "reagent:alice.pinned:1.0.0"}} =
               pull.("reagent:alice.pinned:1.0.0")

      publish(ctx.agent, "1.1.0")
      _ = requests(ctx.agent)

      assert {:ok, %{component_ref: "reagent:alice.pinned:1.1.0"}} = pull.("reagent:alice.pinned")

      assert [
               {"GET", "/v2/alice/reagents/pinned/tags/list", nil},
               {"GET", "/v2/alice/reagents/pinned/manifests/1.1.0", nil} | _
             ] = requests(ctx.agent)
    end
  end

  # ============================================================================
  # Signed pulls
  # ============================================================================

  # With signed pulls required, a pull stores a component only when cosign
  # verified the manifest the pull fetched: cosign is asked about
  # `<registry>/<repository>@<digest>` with the digest the pull stores, and
  # its answer must name that digest. A keyless verification records no
  # signer and a keyed one records its key (`Compendium.Cosign`). The
  # stand-in cosign is a script under the test's own directory, named by the
  # sigstore config.
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
    test "a keyless tag pull is verified at the digest it fetched and records no signer", ctx do
      cosign(ctx, signs: ctx.pin)

      assert {:ok, %{manifest_digest: pin}} = Client.pull(ctx.a, ctx.tag_ref)
      assert pin == ctx.pin
      assert asked(ctx) == ["#{ctx.registry}/#{@repo}@#{ctx.pin}"]

      assert {:ok, component} = Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")
      assert component.signature_verified == true
      # The answer's annotations claim a subject and issuer; a keyless
      # verification records neither.
      assert component.signer_identity == nil
      assert component.signer_issuer == nil
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

  # What a run of a pulled component is answered at admission
  # (`Opus.Admission`), entered as a client's `/mcp` tool call is
  # (`Sanctum.Gate.call_external/3`), from the row the pull recorded: with
  # signed pulls required, a row that records no verified signature is
  # refused, whenever it was pulled; a pinned signer must be the one the
  # row records, and a keyless verification records none.
  describe "signed pulls at admission" do
    @repo "alice/reagents/pinned"
    @run_ref "reagent:alice.pinned:1.0.0"
    @refused "Execution failed: The component's signature could not be verified; " <>
               "signed pulls are required."
    @pin_refused "Execution failed: The component's signer is not the one this run pins."

    setup :start_registry

    setup ctx do
      dir = Path.join(System.tmp_dir!(), "cyfr_oci_admit_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # `cosign/2` writes the sigstore setting; this restores it.
      Prima.Test.Env.delete_app_env(:cyfr, :sigstore)
      Prima.Test.Env.put_app_env(:cyfr, :require_signed_pulls, false)

      allow(ctx.agent, ["Bearer tok_a"])
      Sanctum.TestContext.ready!(ctx.a.athanor_id)

      {:ok, cosign_dir: dir, tag_ref: "#{ctx.registry}/#{@repo}:1.0.0"}
    end

    # The person's grant to the pulled component through the consent walk,
    # as they make it, admitting runs over `/mcp`.
    defp consent!(ctx) do
      person = Sanctum.TestContext.via(ctx.a, :prism)
      decisions = %{ref: @run_ref, origins: [:interactive, :programmatic]}
      {:ok, plan} = Sanctum.Consent.Plan.plan(person, %{ref: @run_ref})
      {:ok, preview} = Sanctum.Consent.Commit.preview(person, decisions)

      {:ok, _} =
        Sanctum.Consent.Commit.commit(person, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      :ok
    end

    defp run(ctx, verify \\ nil) do
      args = %{"action" => "run", "reference" => @run_ref, "input" => %{"a" => 1, "b" => 2}}
      args = if verify, do: Map.put(args, "verify", verify), else: args
      Sanctum.Gate.call_external("execution", Sanctum.TestContext.via(ctx.a, :mcp), args)
    end

    defp require_signed_pulls!, do: Prima.Test.Env.put_app_env(:cyfr, :require_signed_pulls, true)

    # A keyed signer over a stand-in key; answers the row's signer.
    defp keyed!(ctx) do
      path = cosign(ctx, signs: ctx.pin, subject: false)
      key = Path.join(ctx.cosign_dir, "cosign.pub")
      File.write!(key, "-----BEGIN PUBLIC KEY-----\nstand-in\n-----END PUBLIC KEY-----\n")

      Prima.Test.Env.put_app_env(:cyfr, :sigstore,
        verification: :keyed,
        key_path: key,
        cosign_path: path
      )

      fingerprint = :sha256 |> :crypto.hash(File.read!(key)) |> Base.encode16(case: :lower)
      %{"identity" => "key:sha256:" <> fingerprint, "issuer" => "key"}
    end

    defp completed?({:ok, %{status: "completed"}}), do: true
    defp completed?(_answer), do: false

    @tag :capture_log
    test "a component pulled unsigned before signed pulls were required is refused", ctx do
      # cosign finds no signature over the pulled manifest; with the
      # setting off the pull stores the component unverified.
      cosign(ctx, signs: "sha256:" <> String.duplicate("1", 64))
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)
      consent!(ctx)

      assert {:ok, %{source: "oci", signature_verified: false}} =
               Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")

      assert completed?(run(ctx))

      assert run(ctx, %{"identity" => "release@example.com"}) == {:error, @pin_refused}
      assert run(ctx, %{"issuer" => "https://accounts.google.com"}) == {:error, @pin_refused}

      require_signed_pulls!()
      assert run(ctx) == {:error, @refused}
      assert run(ctx, %{"identity" => "release@example.com"}) == {:error, @pin_refused}
    end

    @tag :capture_log
    test "a row whose source names no ingress is refused, whatever the setting", ctx do
      cosign(ctx, signs: "sha256:" <> String.duplicate("1", 64))
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)
      consent!(ctx)
      assert completed?(run(ctx))

      # No ingress writes "published"; a row that came to hold it by any
      # other route is not trusted by ownership.
      import Ecto.Query, only: [from: 2]

      assert {1, _} =
               Arca.Repo.update_all(
                 from(c in Arca.Schemas.Component,
                   where: c.athanor_id == ^ctx.a.athanor_id and c.name == "pinned"
                 ),
                 set: [source: "published"]
               )

      Compendium.Registry.invalidate_executor_caches(ctx.a)

      for required <- [false, true] do
        Prima.Test.Env.put_app_env(:cyfr, :require_signed_pulls, required)
        assert run(ctx) == {:error, @refused}
      end
    end

    @tag :capture_log
    test "a component whose signature did not verify is refused", ctx do
      # A signature over another manifest: cosign's answer names a digest
      # the pull did not fetch.
      cosign(ctx, answers: "sha256:" <> String.duplicate("0", 64))
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)
      consent!(ctx)

      assert {:ok, %{source: "oci", signature_verified: false}} =
               Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")

      assert completed?(run(ctx))

      require_signed_pulls!()
      assert run(ctx) == {:error, @refused}
    end

    @tag :capture_log
    test "a pin naming another signer is refused, and the key that signed runs", ctx do
      signer = keyed!(ctx)
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)
      consent!(ctx)

      other = "key:sha256:" <> String.duplicate("f", 64)

      for required <- [false, true] do
        Prima.Test.Env.put_app_env(:cyfr, :require_signed_pulls, required)

        assert run(ctx, %{signer | "identity" => other}) == {:error, @pin_refused}

        assert run(ctx, %{signer | "issuer" => "https://accounts.google.com"}) ==
                 {:error, @pin_refused}

        assert completed?(run(ctx, signer))
        assert completed?(run(ctx))
      end
    end

    @tag :capture_log
    test "a keyless-verified component runs unpinned and refuses any pin", ctx do
      cosign(ctx, signs: ctx.pin)
      assert {:ok, _} = Client.pull(ctx.a, ctx.tag_ref)
      consent!(ctx)

      assert {:ok, %{signature_verified: true, signer_identity: nil}} =
               Compendium.Registry.get(ctx.a, "pinned", "1.0.0", "alice")

      for required <- [false, true] do
        Prima.Test.Env.put_app_env(:cyfr, :require_signed_pulls, required)
        assert completed?(run(ctx))
        # The keyless signer's own subject and issuer, as its answer names them.
        assert run(ctx, %{"identity" => "release@example.com"}) == {:error, @pin_refused}
        assert run(ctx, %{"issuer" => "https://accounts.google.com"}) == {:error, @pin_refused}
      end
    end
  end

  defp start_registry(_context) do
    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_oci_entitle_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    original_base = Application.get_env(:arca, :base_path)
    original_registry = Application.get_env(:cyfr, :oci_registry_url)

    Application.put_env(:arca, :base_path, test_dir)

    # The reagent guest: a pull that gets as far as storing it stores it.
    wasm = Cyfr.Test.Guests.wasm(:reagent)
    {manifest_json, wasm_digest} = manifest_fixture(wasm)
    pin = Prima.Digest.sha256(manifest_json)

    blobs = %{
      Prima.Digest.sha256(config_fixture()) => config_fixture(),
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
     anonymous: caller("oci_entitle_anonymous"),
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
  # a verified entry for that digest only, in cosign 3's bundle-format shape
  # with a signer-written subject and issuer among its annotations (none when
  # `subject: false`), and refuses any other
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
        "type" => "https://sigstore.dev/cosign/sign/v1"
      },
      "optional" => %{
        "GIT_VERSION" => "v3.1.4",
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

      {Prima.Digest.sha256(manifest), %{state | manifest: manifest}}
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
      # A tag's own manifest, where one is published under it, and the tag
      # list the registry answers (none: no tag list).
      manifests: %{},
      tags: nil,
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
  # with `status` (with `readme` as its body under 200), and answers its
  # digest.
  defp with_readme(agent, status, readme \\ "readme-#{System.unique_integer([:positive])}") do
    digest = Prima.Digest.sha256(readme)
    blob = if status == 200, do: readme, else: {:status, status}

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

      %{state | manifest: manifest, blobs: Map.put(state.blobs, digest, blob)}
    end)

    digest
  end

  # Adds a src/ layer to the manifest whose blob the registry answers with
  # `bytes`.
  defp with_source(agent, bytes) do
    digest = Prima.Digest.sha256(bytes)

    Agent.update(agent, fn state ->
      manifest =
        state.manifest
        |> Jason.decode!()
        |> Map.update!("layers", fn layers ->
          layers ++
            [
              %{
                "mediaType" => Compendium.OCI.Manifest.source_media_type(),
                "size" => byte_size(bytes),
                "digest" => digest
              }
            ]
        end)
        |> Jason.encode!()

      %{state | manifest: manifest, blobs: Map.put(state.blobs, digest, bytes)}
    end)
  end

  defp config_fixture(version \\ "1.0.0"),
    do: Jason.encode!(%{"name" => "pinned", "version" => version, "type" => "reagent"})

  # Publishes `version` beside 1.0.0: its own manifest under its tag, the
  # same WASM layer under its own config, and both tags in the tag list.
  defp publish(agent, version) do
    config = config_fixture(version)

    Agent.update(agent, fn state ->
      manifest =
        state.manifest
        |> Jason.decode!()
        |> put_in(["config"], %{
          "mediaType" => "application/vnd.cyfr.manifest.v1+json",
          "size" => byte_size(config),
          "digest" => Prima.Digest.sha256(config)
        })
        |> Jason.encode!()

      %{
        state
        | manifests: Map.put(state.manifests, version, manifest),
          blobs: Map.put(state.blobs, Prima.Digest.sha256(config), config),
          tags: ["1.0.0", version]
      }
    end)
  end

  # The reagent guest, told apart from another by a custom section named
  # `tag` after its last section.
  defp wasm_module(tag) do
    Cyfr.Test.Guests.wasm(:reagent) <> <<0, byte_size(tag) + 1, byte_size(tag)>> <> tag
  end

  # The component's config blob and its WASM layer, in the blob cache.
  defp put_blobs(wasm_digest, wasm) do
    :ok = Cache.put_blob(Prima.Digest.sha256(config_fixture()), config_fixture())
    Cache.put_blob(wasm_digest, wasm)
  end

  # Minimal OCI image manifest wrapping the given bytes as a reagent WASM
  # layer. Returns {manifest_json, wasm_layer_digest}.
  defp manifest_fixture(wasm_bytes) do
    config = config_fixture()
    wasm_digest = Prima.Digest.sha256(wasm_bytes)

    manifest =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "artifactType" => "application/vnd.cyfr.component.v1",
        "config" => %{
          "mediaType" => "application/vnd.cyfr.manifest.v1+json",
          "size" => byte_size(config),
          "digest" => Prima.Digest.sha256(config)
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

  # `:base_path` is the storage's key; the registry URL is the host's.
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
