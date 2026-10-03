# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellTinctureUrlTest do
  @moduledoc """
  The address the console gives a tincture's frame. A private tincture's
  page is served under the person's asset credential, in the path
  (`/_s/<credential>/<publisher>/<name>/<version>/<entry>`), bound to the
  version's release digest; a public one's is its `/t/` address. No URL
  the shell builds carries a query token. An open that cannot happen
  renders a named state — unavailable, or refused — and never a URL with
  anything else in it.
  """

  use PrismWeb.ConnCase, async: false

  alias Sanctum.Test.ConsentFixtures

  @tincture "url-dash"
  @source "tincture:local.url-dash"
  @window_id "iframe_url-dash"

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_url_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    manifest = %{
      "name" => @tincture,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "media" => %{"icon" => "icon.svg"}}
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", @tincture, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html><body>url</body></html>")
    File.write!(Path.join(dir, "icon.svg"), "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")

    release_digest = register!(ctx, manifest)
    Prism.TinctureRegistry.reload_athanor(athanor.id)

    on_exit(fn ->
      Arca.ControlPlane.record(:unclaimed)
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok,
     conn: conn,
     user: user,
     athanor: athanor,
     ctx: ctx,
     release_digest: release_digest,
     segment: Sanctum.Tenancy.Athanors.route_slug(athanor)}
  end

  # The registry is one server-wide process; after the test's own checkout
  # is gone its reload runs on a checkout lent to it alone.
  defp reload_registry do
    registry = Process.whereis(Prism.TinctureRegistry)

    case Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo) do
      :ok ->
        try do
          Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
          :ok = Prism.TinctureRegistry.reload()
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)
        end

      {:already, _} ->
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
        :ok = Prism.TinctureRegistry.reload()
    end
  end

  # The version's component row, as registration writes it: what the
  # shell reads the release digest from.
  defp register!(ctx, manifest) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, @tincture), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{@tincture}_#{System.unique_integer([:positive])}",
        name: @tincture,
        version: "1.0.0",
        component_type: "tincture",
        description: @tincture,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|#{ctx.namespace}",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    release_digest
  end

  defp public_profile!(ctx) do
    policy = "{}"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_url_public",
          kind: :public,
          source_ref: @source,
          label: "public",
          status: :active
        },
        %{
          id: "cons_url_public",
          revision: 1,
          scope: :pinned,
          pinned_version: "1.0.0",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.JCS.hash_binary(policy),
          resolved_policy: policy,
          activation: %{}
        }
      )
  end

  defp frame_src(html) do
    case Regex.run(~r/<iframe[^>]*src="([^"]+)"/, html) do
      [_, src] -> src
      nil -> nil
    end
  end

  test "a private tincture's page is served under the person's asset credential, in the path", %{
    conn: conn,
    athanor: athanor,
    release_digest: release_digest
  } do
    {view, _html} = mount_athanor(conn, "/tinctures")
    picker = render(view)
    html = render_click(view, "select_tincture", %{"tincture" => @window_id})

    src = frame_src(html)
    assert {:ok, %{credential: credential, path: path}} = Prima.TinctureUrl.parse_asset_path(src)
    assert path == ["local", @tincture, "1.0.0", "index.html"]

    assert {:ok, %{athanor_id: athanor_id, version_digest: ^release_digest}} =
             Sanctum.TinctureAuth.verify_asset_credential(credential)

    assert athanor_id == athanor.id

    # The card's image is read under the same credential.
    assert picker =~
             Prima.TinctureUrl.asset_path(credential, ["local", @tincture, "1.0.0", "icon.svg"])

    refute picker =~ "_t="
    refute html =~ "_t="
  end

  test "a public tincture's page is its public address", %{
    conn: conn,
    ctx: ctx,
    segment: segment
  } do
    public_profile!(ctx)
    {view, _html} = mount_athanor(conn, "/tinctures")
    picker = render(view)
    html = render_click(view, "select_tincture", %{"tincture" => @window_id})

    assert frame_src(html) == Prima.TinctureUrl.path(segment, "local", @tincture)
    assert picker =~ Prima.TinctureUrl.path(segment, "local", @tincture) <> "/icon.svg"

    for page <- [picker, html] do
      refute page =~ "/_s/"
      refute page =~ "_t="
    end
  end

  test "an open the store or the control plane cannot serve renders unavailable", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/tinctures")
    Arca.ControlPlane.record(:lost)
    send(view.pid, :tinctures_refreshed)
    html = render_click(view, "select_tincture", %{"tincture" => @window_id})

    assert html =~ ~s(data-tincture-state="unavailable")
    refute html =~ "/_s/"
    refute frame_src(html)
  end

  # The caller bound: how long the view acts on the context it validated
  # before the guard revalidates it. The suite runs at 0.
  defp bound!(ms) do
    previous = Application.fetch_env(:sanctum, :caller_memo_ttl_ms)
    Application.put_env(:sanctum, :caller_memo_ttl_ms, ms)

    on_exit(fn ->
      Arca.Cache.delete_match({:established, :_, :_, :_})

      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :caller_memo_ttl_ms, value)
        :error -> Application.delete_env(:sanctum, :caller_memo_ttl_ms)
      end
    end)
  end

  test "an open the session can no longer make renders refused", %{conn: conn, user: user} do
    # Within the bound the view acts on the context it validated, so what
    # refuses here is the mint's own reread of the session row.
    bound!(60_000)
    {view, _html} = mount_athanor(conn, "/tinctures")

    # The session row behind the mounted view is gone; nothing has told the
    # view yet, and the mint rereads the row.
    {:ok, _} = Arca.SessionStorage.delete_by_user(user.user_id)

    send(view.pid, :tinctures_refreshed)
    html = render_click(view, "select_tincture", %{"tincture" => @window_id})

    assert html =~ ~s(data-tincture-state="refused")
    refute html =~ "/_s/"
    refute frame_src(html)
  end

  test "past the bound the guard sends the view to sign in before any mint", %{
    conn: conn,
    user: user
  } do
    bound!(0)
    {view, _html} = mount_athanor(conn, "/tinctures")

    {:ok, _} = Arca.SessionStorage.delete_by_user(user.user_id)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_click(view, "select_tincture", %{"tincture" => @window_id})
  end
end
