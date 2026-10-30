# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.PulledTinctureTest do
  # A tincture installed through the OCI pull's publish path
  # (`Compendium.Registry.publish_tincture_archive/4`) is held to the
  # publish check as it is installed: the manifest the pull supplies and
  # the files its layers carry, not only the archive's own. Each case
  # publishes, then reads what the asset route serves for what landed.
  use CyfrWeb.ConnCase, async: false

  defp archive(files) do
    tmp =
      Path.join(System.tmp_dir!(), "pulled_tincture_#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(tmp),
        Enum.map(files, fn {path, content} -> {String.to_charlist(path), content} end)
      )

    tar = File.read!(tmp)
    File.rm!(tmp)
    :zlib.gzip(tar)
  end

  defp manifest(name, tincture),
    do:
      Jason.encode!(%{
        "name" => name,
        "version" => "1.0.0",
        "type" => "tincture",
        "publisher" => "acme",
        "tincture" => tincture
      })

  @page "<html><head></head><body>page</body></html>"

  setup do
    base = Path.join(System.tmp_dir!(), "pulled_tincture_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)
    _ = Sanctum.TestContext.athanor!()

    on_exit(fn ->
      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)

      File.rm_rf!(base)
    end)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure("usr_keeper", scope: "athanor", athanor_id: "ath_test")

    reader = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(reader)
    {:ok, rctx} = Sanctum.Caller.establish(session.token)
    {:ok, rctx: rctx, ctx: Sanctum.TestContext.local()}
  end

  defp publish(ctx, name, archive, manifest, opts \\ []) do
    Compendium.Registry.publish_tincture_archive(
      ctx,
      archive,
      %{name: name, version: "1.0.0", type: "tincture", publisher: "acme", manifest: manifest},
      [allow_overwrite: true, origin: :remote] ++ opts
    )
  end

  # What the asset route serves for a file of an installed version, or
  # nil when the publish installed nothing.
  defp served({:ok, _component}, rctx, ctx, name, file) do
    {:ok, row} = Compendium.inspect_component(ctx, "tincture:acme.#{name}:1.0.0")

    {:ok, %{credential: credential}} =
      Sanctum.TinctureAuth.mint_asset_credential(rctx, row["release_digest"])

    conn =
      get(build_conn(), Prima.TinctureUrl.asset_path(credential, ["acme", name, "1.0.0" | file]))

    %{
      status: conn.status,
      type: get_resp_header(conn, "content-type"),
      csp: get_resp_header(conn, "content-security-policy")
    }
  end

  defp served(_refused, _rctx, _ctx, _name, _file), do: nil

  test "a layer's file counts toward the version the publish check measures", %{
    rctx: rctx,
    ctx: ctx
  } do
    original = Application.get_env(:cyfr, :tincture_max_decompressed_bytes)
    Application.put_env(:cyfr, :tincture_max_decompressed_bytes, 4096)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :tincture_max_decompressed_bytes, original),
        else: Application.delete_env(:cyfr, :tincture_max_decompressed_bytes)
    end)

    m = manifest("pulled-layer", %{"entry" => "index.html"})

    result =
      publish(ctx, "pulled-layer", archive([{"cyfr-manifest.json", m}, {"index.html", @page}]), m,
        unit_files: [{["src", "bundle.js"], String.duplicate("x", 8192)}]
      )

    served = served(result, rctx, ctx, "pulled-layer", ["src", "bundle.js"])

    assert match?({:error, _}, result),
           "installed past the ceiling; its layer's file is served as #{inspect(served)}"

    {:error, message} = result
    assert message =~ "over the registry's ceiling of 4096 bytes"
    assert {:error, :not_found} = Compendium.Registry.get(ctx, "pulled-layer", "1.0.0")
  end

  test "the manifest the pull supplies is the one its files are checked under", %{
    rctx: rctx,
    ctx: ctx
  } do
    # The archive's own manifest is an app's page; the config blob makes
    # it a canvas that reaches an origin, which the frame's rules refuse.
    app = manifest("pulled-swap", %{"entry" => "index.html"})

    canvas =
      manifest("pulled-swap", %{
        "frame" => %{"placement" => "canvas"},
        "entry" => "index.html",
        "connect" => ["api.example.com"]
      })

    result =
      publish(
        ctx,
        "pulled-swap",
        archive([
          {"cyfr-manifest.json", app},
          {"index.html", @page},
          {"app.js", "export default () => {}"}
        ]),
        canvas
      )

    served = served(result, rctx, ctx, "pulled-swap", ["index.html"])

    assert match?({:error, _}, result),
           "installed the supplied manifest unchecked; its page is served as #{inspect(served)}"

    {:error, message} = result
    assert message =~ "a canvas declares no tincture.connect origin"
    assert {:error, :not_found} = Compendium.Registry.get(ctx, "pulled-swap", "1.0.0")
  end
end
