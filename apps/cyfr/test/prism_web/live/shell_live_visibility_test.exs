# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveVisibilityTest do
  @moduledoc """
  Whether a tincture is public is read through `Sanctum.Consent.profiles/2`,
  and a read that cannot answer renders a third state — "unavailable" —
  never "private". A store that is down, or a profile row that cannot be
  decoded, says nothing about whether the tincture is published. No
  control offers to make an app public; a public app's address, at the
  home's own origin, is offered to copy, and a private app's never.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query

  import Prima.Test.Wait

  alias Sanctum.Test.ConsentFixtures

  @tincture "visibility-dash"

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_visibility_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", @tincture, "1.0.0",
      manifest: %{
        "name" => @tincture,
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      },
      files: [{"index.html", "<html><body>visibility</body></html>"}]
    )

    Prism.TinctureRegistry.reload_athanor(athanor.id)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry(athanor.id)
    end)

    {:ok, conn: conn, ctx: ctx}
  end

  defp public_profile!(ctx, status \\ :active, publisher \\ "local") do
    policy = "{}"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_vis_public_#{publisher}",
          kind: :public,
          source_ref: "tincture:#{publisher}.#{@tincture}",
          label: "public",
          status: status
        },
        %{
          id: "cons_vis_public_#{publisher}",
          revision: 1,
          scope: :pinned,
          pinned_version: "1.0.0",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.Digest.sha256(policy),
          resolved_policy: policy,
          activation: %{}
        }
      )
  end

  defp visibility(html) do
    case Regex.run(~r/data-tincture-visibility="([^"]+)"/, html) do
      [_, state] -> state
      nil -> nil
    end
  end

  # No page makes an app public, so the picker offers no step toward one.
  defp offers_publishing?(html), do: html =~ ~r/Make Public|Make Private|toggle_visibility/

  defp copies_url?(html), do: html =~ "Copy URL"

  test "a tincture with no public profile reads private, with nothing offering to publish it",
       %{conn: conn} do
    {_view, html} = mount_desktop(conn)

    assert visibility(html) == "private"
    refute offers_publishing?(html)
    refute copies_url?(html)
  end

  test "an active public profile reads public", %{conn: conn, ctx: ctx} do
    public_profile!(ctx)

    {_view, html} = mount_desktop(conn)

    assert visibility(html) == "public"
    refute offers_publishing?(html)
    assert copies_url?(html)
  end

  @tag :capture_log
  test "a profile store that cannot answer reads unavailable, never private", %{conn: conn} do
    {view, html} = mount_desktop(conn)
    assert visibility(html) == "private"

    Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")
    send(view.pid, :tinctures_refreshed)
    html = render(view)

    assert visibility(html) == "unavailable"
    refute offers_publishing?(html)
    refute copies_url?(html)
  end

  test "a public profile row that cannot be decoded reads unavailable", %{conn: conn, ctx: ctx} do
    public_profile!(ctx)

    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^ctx.athanor_id and p.id == "prof_vis_public_local"
        ),
        set: [kind: "sideways"]
      )

    {_view, html} = mount_desktop(conn)

    assert visibility(html) == "unavailable"
  end

  # What a person reads of an app on the desktop says app, never tincture.
  test "the desktop's picker and its notices say app", %{conn: conn, ctx: ctx} do
    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", "visibility-two", "1.0.0",
      manifest: %{
        "name" => "visibility-two",
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      },
      files: [{"index.html", "<html><body>two</body></html>"}]
    )

    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)

    {view, html} = mount_desktop(conn)

    assert html =~ ~s(title="Refresh apps")
    assert html =~ ~s(aria-label="Refresh apps")
    assert html =~ "Previous app (←)"
    assert html =~ "Next app (→)"
    assert html =~ ~s(aria-label="App 1 of 2")

    refute html =~
             ~r/[Tt]incture( \d| not|s installed|s registered)|this tincture|Refresh tinctures|(Previous|Next) tincture/

    flash = render_click(view, "open_report", %{"tincture" => "iframe_none"})
    assert flash =~ "App not found; refresh and try again."

    assert render_click(view, "refresh_tinctures", %{}) =~ "Refreshing apps…"

    wait_until(
      fn -> render(view) =~ "Apps registered and refreshed" end,
      10_000,
      "the refresh"
    )
  end

  # `config/test.exs` configures a registry that is not cyfr.run.
  test "a tincture's report goes to the registry's moderators, never cyfr.run's", %{conn: conn} do
    {view, html} = mount_desktop(conn)
    assert html =~ "Report this app to the registry&#39;s moderators"

    render_click(view, "open_report", %{"tincture" => "iframe_#{@tincture}"})
    html = render(view)
    assert html =~ "Your report goes to the registry&#39;s moderators."
    refute html =~ "cyfr.run"
  end

  # The address a person copies to share a public tincture is the home's
  # own (`Sanctum.origin/0`), its public URL with a browser address,
  # never the endpoint's own listener address; a private one copies nothing.
  test "a public tincture's copied URL is at the home's own address, a private one's is none",
       %{conn: conn, ctx: ctx} do
    original = Application.fetch_env(:sanctum, :browser_address)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:sanctum, :browser_address, value)
        :error -> Application.delete_env(:sanctum, :browser_address)
      end
    end)

    home = "https://cyfr.tail1a2b3c.ts.net"
    Application.put_env(:sanctum, :browser_address, home)

    {view, _html} = mount_desktop(conn)
    render_click(view, "copy_url", %{"publisher" => "local", "name" => @tincture})
    refute_push_event(view, "clipboard", %{})

    public_profile!(ctx)
    {view, _html} = mount_desktop(conn)
    render_click(view, "copy_url", %{"publisher" => "local", "name" => @tincture})

    assert_push_event(view, "clipboard", %{text: url})
    assert String.starts_with?(url, home <> "/")
    assert String.ends_with?(url, "/local/#{@tincture}")
  end

  # Two publishers' apps of one name share a card id: the address copied is
  # the pressed app's, by its publisher and name, and only the public one's.
  test "the copied URL is the pressed app's when two publishers' apps share a name",
       %{conn: conn, ctx: ctx} do
    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "acme", @tincture, "1.0.0",
      manifest: %{
        "name" => @tincture,
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "acme",
        "tincture" => %{"entry" => "index.html"}
      },
      files: [{"index.html", "<html><body>acme</body></html>"}]
    )

    public_profile!(ctx, :active, "acme")
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)

    {view, _html} = mount_desktop(conn)

    render_click(view, "copy_url", %{"publisher" => "local", "name" => @tincture})
    refute_push_event(view, "clipboard", %{})

    render_click(view, "copy_url", %{"publisher" => "acme", "name" => @tincture})
    assert_push_event(view, "clipboard", %{text: url})
    assert String.ends_with?(url, "/acme/#{@tincture}")
  end
end
