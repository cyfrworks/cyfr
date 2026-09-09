# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ConsentAfterInstallTest do
  @moduledoc """
  What installing a component does to what the estate consented to.

  A baseline consent is minted against the closure that existed when the
  estate was filled. Installing a component widens that closure, so the
  consent no longer answers for it and a turn is refused until a member
  consents again. The estate reports that state rather than leaving it
  unexplained.
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
  @bundle Path.join(@repo_root, "seed/components")
  @wasm Path.join(@repo_root, "apps/cyfr/test/support/test_wasm/math.wasm")
  @providers ~w(claude openai gemini grok openrouter)

  # `claude` depends on a component NO local manifest mentions: the bundle
  # names the five providers and nothing below them. Rediscovering it is
  # only possible by reading an installed remote component's own manifest.
  @below_remote "helper"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_closure_#{:rand.uniform(1_000_000)}")
    seed_dir = Path.join(test_dir, "seed")
    bundle_dir = Path.join(seed_dir, "components")
    copy_bundle!(bundle_dir)
    # Provisioning also copies the AQUA template out of the seed tree.
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    {:ok, server} = Bandit.start_link(plug: {Registry, fixtures()}, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    prev = %{
      base_path: Application.get_env(:cyfr, :base_path),
      seed_path: Application.get_env(:cyfr, :seed_path),
      oci: Application.get_env(:cyfr, :oci_registry_url),
      registry: Application.get_env(:cyfr, :registry_url),
      egress: Application.get_env(:cyfr, :private_egress_targets),
      sigstore: Application.get_env(:cyfr, :sigstore)
    }

    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)
    # `localhost:` is the one host the OCI reference layer maps to http.
    Application.put_env(:cyfr, :oci_registry_url, "localhost:#{port}")
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")
    Application.put_env(:cyfr, :private_egress_targets, ["127.0.0.1"])
    # A cosign on PATH would try to verify; point it at nothing so it fails fast.
    Application.put_env(:cyfr, :sigstore, verification: :keyed, key_path: "/nonexistent")

    on_exit(fn ->
      for {key, value} <- [
            base_path: prev.base_path,
            seed_path: prev.seed_path,
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

  test "installing a component changes what the estate consented to, and it says so" do
    n = System.unique_integer([:positive])

    prev_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Source.DB)
    on_exit(fn -> Application.put_env(:cyfr, :consent_source, prev_source) end)

    ctx =
      Sanctum.Context.build(
        user_id: "github|https://github.com|installed-#{n}",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    prev_rest = Application.get_env(:cyfr, :registry_url)
    prev_oci = Application.get_env(:cyfr, :oci_registry_url)
    Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())
    Application.put_env(:cyfr, :oci_registry_url, Compendium.RegistryHost.none())

    {:ok, group} = Athanors.create_group(ctx.user_id, "Installed #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)

    # Filled offline: AQUA's consent covers the closure that exists, and a
    # turn can pin it.
    assert {:ok, %Sanctum.Authority{}} =
             Cyfr.Execution.authority_for(in_group, :default, "formula:local.aqua")

    assert Cyfr.ConsentDrift.state(in_group) == :ok

    # A provider is installed, as the AQUA page's Install does. That widens
    # the closure AQUA's consent was minted against, so the consent no
    # longer answers for it and a turn is refused until a member consents
    # again. The estate must SAY that rather than look unexplained.
    Application.put_env(:cyfr, :registry_url, prev_rest)
    Application.put_env(:cyfr, :oci_registry_url, prev_oci)

    assert {:ok, _} =
             Cyfr.Ops.Catalog.call_external("component", in_group, %{
               "action" => "pull",
               "reference" => "catalyst:moonmoon69.claude"
             })

    assert {:error, {:consent_required, _}} =
             Cyfr.Execution.authority_for(in_group, :default, "formula:local.aqua")

    assert Cyfr.ConsentDrift.state(in_group) == :stale
  end

  defp fixtures do
    wasm = File.read!(@wasm)

    Map.new([@below_remote | @providers], fn name ->
      deps =
        if name == "claude",
          do: %{
            "static" => [
              %{"ref" => "catalyst:moonmoon69.#{@below_remote}", "optional" => false}
            ]
          },
          else: %{"static" => []}

      config =
        Jason.encode!(%{
          "name" => name,
          "version" => "1.0.0",
          "type" => "catalyst",
          "publisher" => "moonmoon69",
          "description" => "#{name} (fixture)",
          "dependencies" => deps,
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
