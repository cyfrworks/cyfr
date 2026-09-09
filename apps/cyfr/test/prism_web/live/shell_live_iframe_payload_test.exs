# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveIframePayloadTest do
  @moduledoc """
  What a sandboxed tincture may put in a `postMessage`.

  `iframe_bridge.js` forwards any object whose `type` starts with `cyfr:`
  verbatim, so `payload` is whatever the frame's own scripts wrote. The shell
  read it with `msg["payload"]["title"]` and `get_in(msg, ["payload", …])`,
  both of which raise when `payload` is not a map — one message killed
  `ShellLive` and took every open tincture window's state with it, and it is
  repeatable in a loop.
  """

  use PrismWeb.ConnCase, async: false

  @tincture "payload-dash"
  @window_id "iframe_payload-dash"

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    home = Sanctum.Tenancy.Athanors.home!()

    base = Path.join(System.tmp_dir!(), "shell_payload_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    dir =
      Arca.Adapters.Local.build_path(
        %{Sanctum.TestContext.local() | athanor_id: home.id},
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

    File.write!(Path.join(dir, "index.html"), "<html><body>payload</body></html>")

    # Reload the registry after writing fixtures directly to disk without an AutoIndexer notification.
    Prism.TinctureRegistry.reload_athanor(home.id)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, original_path)
      File.rm_rf(base)
      Prism.TinctureRegistry.reload()
    end)

    {:ok, conn: conn}
  end

  defp send_message(view, action, payload) do
    render_hook(view, "iframe_message", %{
      "window_id" => @window_id,
      "message" => %{
        "type" => "cyfr:request",
        "action" => action,
        "id" => "req-#{System.unique_integer([:positive])}",
        "payload" => payload
      }
    })
  end

  test "a non-map payload does not kill the shell", %{conn: conn} do
    {view, html} = mount_athanor(conn, "/tinctures")
    assert html =~ @tincture

    for action <- ["set_title", "invoke"],
        payload <- ["a string", 42, ["a", "list"], nil, true] do
      send_message(view, action, payload)

      assert Process.alive?(view.pid),
             "#{action} with payload #{inspect(payload)} killed the shell"
    end

    # ...and the view still works afterwards.
    assert render(view) =~ @tincture
  end

  test "a well-formed set_title still lands", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/tinctures")

    send_message(view, "set_title", %{"title" => "Renamed"})

    assert_push_event(view, "iframe_response:#{@window_id}", %{result: %{ok: true}})
    assert render(view) =~ "Renamed"
  end

  test "an invoke with no reference is refused, not raised", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/tinctures")

    send_message(view, "invoke", %{"input" => %{}})

    assert Process.alive?(view.pid)
  end
end
