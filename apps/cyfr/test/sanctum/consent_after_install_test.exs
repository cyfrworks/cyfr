# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ConsentAfterInstallTest do
  @moduledoc """
  What installing a component does to what the estate consented to.

  A baseline consent is minted against the closure that exists when the
  estate is filled. Installing a component a formula names as an optional
  dependency widens that closure, so the consent no longer answers for it
  and a turn is refused until a member consents again. The estate reports
  that state rather than leaving it unexplained — and only for the
  formula the install touched: the bundled assistant's closure ships in
  the seed and stands.
  """
  use ExUnit.Case, async: false

  # The registry: one fixture catalyst under `moonmoon69/catalysts/claude`,
  # an OCI manifest naming a cyfr-manifest config blob and a wasm blob.
  defmodule OCIRegistry do
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

  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  @repo_root Path.expand("../../../..", __DIR__)
  @bundle Path.join(@repo_root, "seed/components")
  @wasm File.read!(Path.join(@repo_root, "apps/cyfr/test/support/test_wasm/math.wasm"))
  @formula "formula:local.uses-remote"
  @remote "catalyst:moonmoon69.claude"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_install_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    bundle_dir = Path.join(seed_dir, "components")
    copy_bundle!(bundle_dir)
    write_formula!(bundle_dir)
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    {:ok, server} =
      Bandit.start_link(plug: {OCIRegistry, fixtures()}, ip: {127, 0, 0, 1}, port: 0)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    keys = [
      arca: :base_path,
      arca: :seed_path,
      cyfr: :oci_registry_url,
      cyfr: :registry_url,
      cyfr: :sigstore
    ]

    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    Application.put_env(:arca, :base_path, test_dir)
    Application.put_env(:arca, :seed_path, seed_dir)
    # A cosign on PATH would try to verify; point it at nothing so it fails fast.
    Application.put_env(:cyfr, :sigstore, verification: :keyed, key_path: "/nonexistent")

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      File.rm_rf!(test_dir)
      Process.exit(server, :normal)
    end)

    {:ok, port: port}
  end

  test "installing a component changes what the estate consented to, and it says so", %{
    port: port
  } do
    n = System.unique_integer([:positive])

    ctx =
      Sanctum.Context.build(
        user_id: "github|https://github.com|installed-#{n}",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # Filled offline: each consent covers the closure that exists, and a
    # turn can pin it.
    Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())
    Application.put_env(:cyfr, :oci_registry_url, Compendium.RegistryHost.none())

    {:ok, group} = Athanors.create_group(ctx.user_id, "Installed #{n}")
    in_group = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(in_group)
    {:ok, group} = Athanors.get(group.id)
    assert %DateTime{} = group.provisioned_at, inspect(Athanors.settings(group))

    assert {:ok, %Prima.Authority{}} =
             Cyfr.Execution.authority_for(in_group, :default, @formula)

    assert Aqua.consent_state(in_group, @formula) == {:ok, :current}

    # The optional provider is installed, as the console's Install does.
    # That widens the closure the formula's consent was minted against, so
    # the consent no longer answers for it and a turn is refused until a
    # member consents again. The estate must SAY that rather than look
    # unexplained.
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")
    # `localhost:` is the one host the OCI reference layer maps to http.
    Application.put_env(:cyfr, :oci_registry_url, "localhost:#{port}")

    assert {:ok, _} =
             Cyfr.Ops.Catalog.call_external("component", in_group, %{
               "action" => "pull",
               "reference" => @remote
             })

    assert {:error, {:consent_required, _}} =
             Cyfr.Execution.authority_for(in_group, :default, @formula)

    assert Aqua.consent_state(in_group, @formula) == {:ok, :stale}
    assert Aqua.stale_consent_refs(in_group) == {:ok, [{@formula, :stale}]}

    # The bundled assistant names nothing the install touched: its closure
    # ships in the seed, so its consent stands and a turn still pins it.
    assert Aqua.consent_state(in_group) == {:ok, :current}

    assert {:ok, %Prima.Authority{}} =
             Cyfr.Execution.authority_for(in_group, :default, "agent:local.aqua")
  end

  # A local formula that may use the published provider once it is installed.
  defp write_formula!(bundle_dir) do
    dir = Path.join([bundle_dir, "formulas", "local", "uses-remote", "1.0.0"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "formula.wasm"), @wasm)

    manifest = %{
      "name" => "uses-remote",
      "type" => "formula",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Uses a published provider when one is installed",
      "caps" => %{"tools" => ["execution.run"], "limits" => %{"timeout" => "1m"}},
      "dependencies" => %{
        "static" => [
          %{"ref" => "catalyst:local.http", "optional" => false, "reason" => "HTTP"},
          %{"ref" => @remote, "optional" => true, "reason" => "a provider installed later"}
        ]
      },
      "schema" => %{"input" => %{"type" => "object"}, "output" => %{"type" => "object"}}
    }

    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
  end

  defp fixtures do
    config =
      Jason.encode!(%{
        "name" => "claude",
        "version" => "1.0.0",
        "type" => "catalyst",
        "publisher" => "moonmoon69",
        "description" => "claude (fixture)",
        "dependencies" => %{"static" => []},
        "caps" => %{
          "egress" => %{"domains" => ["api.claude.example"], "methods" => ["GET", "POST"]},
          "limits" => %{"timeout" => "1m"}
        }
      })

    {:ok, manifest_json, config_digest, wasm_digest} =
      Compendium.OCI.Manifest.build(config, @wasm, "catalyst")

    %{
      "moonmoon69/catalysts/claude" => %{
        manifest: manifest_json,
        manifest_digest: Compendium.OCI.Blob.compute_digest(manifest_json),
        blobs: %{config_digest => config, wasm_digest => @wasm}
      }
    }
  end

  # The tracked bundle, minus Rust build output that may sit beside a source tree.
  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Prima.Test.SourceTree.files!(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      target = Path.join(dest, Path.relative_to(src, @bundle))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
