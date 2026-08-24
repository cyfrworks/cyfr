# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningClosureTest do
  @moduledoc """
  The success path of provisioning against the real tracked bundle: the
  seed lands, the bundle's published dependencies (the five provider
  catalysts `formula:local.aqua` needs) are pulled from an OCI registry
  served here by a small Plug on Bandit (Bypass cannot route the `sha256:`
  in blob paths), and a baseline consent is minted for AQUA — so the
  minted athanor's AQUA is loadable, dependency closure present. The one
  thing not run is a provider call; that is the manual smoke with a real key.
  """
  use ExUnit.Case, async: false

  # The registry: five fixture catalysts under `moonmoon69/catalysts/<name>`,
  # each an OCI manifest naming a cyfr-manifest config blob and a wasm blob.
  defmodule Registry do
    @behaviour Plug

    @impl true
    def init(fixtures), do: fixtures

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, fixtures) do
      case Regex.run(~r{^/v2/(.+)/(tags/list|manifests/[^/]+|blobs/[^/]+)$}, path) do
        [_, repo, "tags/list"] when is_map_key(fixtures, repo) ->
          json(conn, 200, %{"name" => repo, "tags" => ["1.0.0"]})

        [_, repo, "manifests/" <> tag]
        when is_map_key(fixtures, repo) and tag in ["1.0.0", "latest"] ->
          %{manifest: manifest, manifest_digest: digest} = fixtures[repo]

          conn
          |> Plug.Conn.put_resp_content_type(Compendium.OCI.Manifest.manifest_media_type())
          |> Plug.Conn.put_resp_header("docker-content-digest", digest)
          |> Plug.Conn.send_resp(200, manifest)

        [_, repo, "blobs/" <> digest] when is_map_key(fixtures, repo) ->
          case fixtures[repo].blobs[digest] do
            nil -> json(conn, 404, %{"errors" => [%{"code" => "BLOB_UNKNOWN"}]})
            bytes -> Plug.Conn.send_resp(conn, 200, bytes)
          end

        _ ->
          json(conn, 404, %{"errors" => [%{"code" => "NAME_UNKNOWN", "message" => path}]})
      end
    end

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  alias Sanctum.Consent.{Loader, Source}
  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  @repo_root Path.expand("../../../..", __DIR__)
  @bundle Path.join(@repo_root, "components/_bundle")
  @wasm Path.join(@repo_root, "apps/cyfr/test/support/test_wasm/math.wasm")
  @providers ~w(claude openai gemini grok openrouter)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_closure_#{:rand.uniform(1_000_000)}")
    bundle_dir = Path.join(test_dir, "bundle")
    copy_bundle!(bundle_dir)

    {:ok, server} = Bandit.start_link(plug: {Registry, fixtures()}, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    prev = %{
      base_path: Application.get_env(:cyfr, :base_path),
      bundle_path: Application.get_env(:cyfr, :bundle_path),
      oci: Application.get_env(:cyfr, :oci_registry_url),
      registry: Application.get_env(:cyfr, :registry_url),
      egress: Application.get_env(:cyfr, :private_egress_targets),
      sigstore: Application.get_env(:cyfr, :sigstore)
    }

    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :bundle_path, bundle_dir)
    # `localhost:` is the one host the OCI reference layer maps to http.
    Application.put_env(:cyfr, :oci_registry_url, "localhost:#{port}")
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")
    Application.put_env(:cyfr, :private_egress_targets, ["127.0.0.1"])
    # A cosign on PATH would try to verify; point it at nothing so it fails fast.
    Application.put_env(:cyfr, :sigstore, verification: :keyed, key_path: "/nonexistent")

    on_exit(fn ->
      for {key, value} <- [
            base_path: prev.base_path,
            bundle_path: prev.bundle_path,
            oci_registry_url: prev.oci,
            registry_url: prev.registry,
            private_egress_targets: prev.egress,
            sigstore: prev.sigstore
          ] do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(test_dir)
      Process.exit(server, :normal)
    end)

    :ok
  end

  test "a group is provisioned from the real bundle with its closure pulled, and AQUA is loadable" do
    n = System.unique_integer([:positive])
    user_id = "github|https://github.com|closure-#{n}"

    ctx =
      Sanctum.Context.build(
        user_id: user_id,
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    assert {:ok, group} = Provisioning.ensure_group_athanor(ctx, "Closure #{n}")
    assert %DateTime{} = group.provisioned_at, inspect(Athanors.settings(group))

    in_group = %{ctx | athanor_id: group.id}

    # every provider catalyst the bundle depends on is now a row in the athanor
    for name <- @providers do
      assert {:ok, %{publisher: "moonmoon69"}} =
               Compendium.Registry.get_latest(in_group, name, "moonmoon69", "catalyst"),
             "catalyst:moonmoon69.#{name} was not pulled"
    end

    # and AQUA — the bundled formula — is consented and loads with the closure present
    assert {:ok, [profile]} = Source.DB.profiles(in_group, "formula:local.aqua")
    {:ok, aqua} = Compendium.Registry.get_latest(in_group, "aqua", "local", "formula")
    assert {:ok, live} = Compendium.Activation.resolve_verified(in_group, aqua)

    assert {:ok, %Sanctum.Authority{} = auth, _stamp} =
             Loader.load_root(in_group, profile, source: Source.DB, live: {:ok, live})

    assert auth.cursor == {:bound, "formula:local.aqua"}

    # a second provisioning is a no-op
    assert {:ok, %{provisioned_at: at}} = Provisioning.provision(group, in_group)
    assert at == group.provisioned_at
  end

  # ---- fixtures ---------------------------------------------------------------

  # One fixture catalyst per provider: a cyfr manifest (the OCI config blob),
  # a valid wasm (the content blob) and the OCI manifest that names both.
  defp fixtures do
    wasm = File.read!(@wasm)

    Map.new(@providers, fn name ->
      config =
        Jason.encode!(%{
          "name" => name,
          "version" => "1.0.0",
          "type" => "catalyst",
          "publisher" => "moonmoon69",
          "description" => "#{name} (fixture)",
          "caps" => %{
            "egress" => %{"domains" => ["api.#{name}.example"], "methods" => ["GET", "POST"]},
            "limits" => %{"timeout" => "1m"}
          }
        })

      {:ok, manifest_json, config_digest, wasm_digest} =
        Compendium.OCI.Manifest.build(config, wasm, "catalyst")

      {"moonmoon69/catalysts/#{name}",
       %{
         manifest: manifest_json,
         manifest_digest: Compendium.OCI.Blob.compute_digest(manifest_json),
         blobs: %{config_digest => config, wasm_digest => wasm}
       }}
    end)
  end

  # The tracked bundle, minus Rust build output that may sit beside a source tree.
  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      rel = Path.relative_to(src, @bundle)
      target = Path.join(dest, rel)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
