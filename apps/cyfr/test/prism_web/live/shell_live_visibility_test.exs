# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveVisibilityTest do
  @moduledoc """
  Whether a tincture is public is read through `Sanctum.Consent.profiles/2`,
  and a read that cannot answer renders a third state — "unavailable",
  with no toggle — never "private". A store that is down, or a profile row
  that cannot be decoded, says nothing about whether the tincture is
  published.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query

  alias Sanctum.Test.ConsentFixtures

  @tincture "visibility-dash"
  @source "tincture:local.visibility-dash"

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    estate = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: estate.id}

    base = Path.join(System.tmp_dir!(), "shell_visibility_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", @tincture, "1.0.0"]
      )

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "cyfr-manifest.json"),
      Jason.encode!(%{
        "name" => @tincture,
        "type" => "tincture",
        "version" => "1.0.0",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html"}
      })
    )

    File.write!(Path.join(dir, "index.html"), "<html><body>visibility</body></html>")
    Prism.TinctureRegistry.reload_athanor(estate.id)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      Prism.TinctureRegistry.reload()
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
          blob_digest: Cyfr.JCS.hash_binary(policy),
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

  # The toggle's own `disabled` attribute — not the `disabled:` style
  # variants its class carries either way.
  defp toggle_disabled?(html) do
    [tag] = Regex.run(~r/<button[^>]*phx-click="toggle_visibility"[^>]*>/s, html)
    tag |> String.replace(~r/class="[^"]*"/, "") |> String.match?(~r/\sdisabled[\s>=]/)
  end

  test "a tincture with no public profile reads private, with its toggle", %{conn: conn} do
    {_view, html} = mount_athanor(conn, "/tinctures")

    assert visibility(html) == "private"
    assert html =~ "Make Public"
    refute toggle_disabled?(html)
  end

  test "an active public profile reads public", %{conn: conn, ctx: ctx} do
    public_profile!(ctx)

    {_view, html} = mount_athanor(conn, "/tinctures")

    assert visibility(html) == "public"
    assert html =~ "Make Private"
    refute toggle_disabled?(html)
  end

  @tag :capture_log
  test "a profile store that cannot answer reads unavailable, never private", %{conn: conn} do
    {view, html} = mount_athanor(conn, "/tinctures")
    assert visibility(html) == "private"

    Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")
    send(view.pid, :tinctures_refreshed)
    html = render(view)

    assert visibility(html) == "unavailable"
    refute html =~ "Make Public"
    assert toggle_disabled?(html)

    flash = render_click(view, "toggle_visibility", %{"tincture" => "iframe_#{@tincture}"})
    assert flash =~ "can&#39;t be read right now"
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

    {_view, html} = mount_athanor(conn, "/tinctures")

    assert visibility(html) == "unavailable"
    assert toggle_disabled?(html)
  end
end
