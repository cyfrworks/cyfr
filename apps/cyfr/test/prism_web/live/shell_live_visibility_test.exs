# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveVisibilityTest do
  @moduledoc """
  Whether a tincture is public is read through `Sanctum.Consent.profiles/2`,
  and a read that cannot answer renders a third state — "unavailable" —
  never "private". A store that is down, or a profile row that cannot be
  decoded, says nothing about whether the tincture is published. No
  control offers to make an app public or to copy a public address: an
  app cannot be made public yet.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query

  import Prima.Test.Wait

  alias Sanctum.Test.ConsentFixtures

  @tincture "visibility-dash"
  @source "tincture:local.visibility-dash"

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

  defp public_profile!(ctx, status \\ :active) do
    policy = "{}"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_vis_public",
          kind: :public,
          source_ref: @source,
          label: "public",
          status: status
        },
        %{
          id: "cons_vis_public",
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

  # Nothing a person can reach finishes a publish, so the picker offers
  # no step toward one and no public address to copy.
  defp offers_publishing?(html),
    do: html =~ ~r/Make Public|Make Private|Copy URL|toggle_visibility|copy_url/

  test "a tincture with no public profile reads private, with nothing offering to publish it",
       %{conn: conn} do
    {_view, html} = mount_desktop(conn)

    assert visibility(html) == "private"
    refute offers_publishing?(html)
  end

  test "an active public profile reads public", %{conn: conn, ctx: ctx} do
    public_profile!(ctx)

    {_view, html} = mount_desktop(conn)

    assert visibility(html) == "public"
    refute offers_publishing?(html)
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
  end

  test "a public profile row that cannot be decoded reads unavailable", %{conn: conn, ctx: ctx} do
    public_profile!(ctx)

    {1, _} =
      Arca.Repo.update_all(
        from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^ctx.athanor_id and p.id == "prof_vis_public"
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
end
