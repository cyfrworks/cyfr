# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellTinctureUrlTest do
  @moduledoc """
  The console renders a tincture's frame from the same derived access token
  the HTTP mint hands out: one `?_t=` token per tincture, minted from the
  person's session and good for exactly that tincture. A mint that does not
  happen renders a named state — unavailable, or refused — and never a URL
  with anything else in it.
  """

  use PrismWeb.ConnCase, async: false

  @tincture "url-dash"
  @window_id "iframe_url-dash"

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    estate = seated_athanor()

    base = Path.join(System.tmp_dir!(), "shell_url_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(%{Sanctum.TestContext.local() | athanor_id: estate.id}),
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

    File.write!(Path.join(dir, "index.html"), "<html><body>url</body></html>")
    Prism.TinctureRegistry.reload_athanor(estate.id)

    on_exit(fn ->
      Arca.ControlPlane.record(:unclaimed)
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      Prism.TinctureRegistry.reload()
    end)

    {:ok, conn: conn, user: user, estate: estate}
  end

  defp frame_src(html) do
    case Regex.run(~r/<iframe[^>]*id="#{@window_id}"[^>]*src="([^"]+)"/, html) ||
           Regex.run(~r/<iframe[^>]*src="([^"]+)"[^>]*id="#{@window_id}"/, html) do
      [_, src] -> src
      nil -> nil
    end
  end

  test "the frame carries a token the tincture surface accepts, for this tincture alone", %{
    conn: conn,
    estate: estate
  } do
    {view, _html} = mount_athanor(conn, "/tinctures")
    html = render_click(view, "select_tincture", %{"tincture" => @window_id})

    src = frame_src(html)
    assert src =~ "/local/#{@tincture}?_t="
    [_, token] = Regex.run(~r/\?_t=([^&"]+)/, src)

    assert {:ok, %Sanctum.Context{auth_method: :tincture, athanor_id: athanor_id}} =
             Sanctum.TinctureAuth.authenticate(%Plug.Conn{
               query_string: "_t=#{token}",
               remote_ip: {127, 0, 0, 1},
               path_params: %{"publisher" => "local", "tincture_name" => @tincture}
             })

    assert athanor_id == estate.id

    # The HTTP mint and the console mint are the one codec.
    assert {:ok, seconds} = Sanctum.TinctureAuth.expires_in(token)
    assert seconds in 3590..3600
  end

  test "a mint the store or the control plane cannot serve renders unavailable", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/tinctures")
    Arca.ControlPlane.record(:lost)
    send(view.pid, :tinctures_refreshed)
    html = render_click(view, "select_tincture", %{"tincture" => @window_id})

    assert html =~ ~s(data-tincture-state="unavailable")
    refute html =~ "?_t="
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

  test "a mint the session can no longer make renders refused", %{conn: conn, user: user} do
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
    refute html =~ "?_t="
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
