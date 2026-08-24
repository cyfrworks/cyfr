# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveInvokeLogTest do
  @moduledoc """
  The console shell's invoke is a run ingress like the HTTP tincture
  route, so it files the same request-log rows. It was the one run
  ingress that logged nothing.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query

  @tincture "log-dash"
  @window_id "iframe_log-dash"

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    home = Sanctum.Tenancy.Athanors.home!()

    base = Path.join(System.tmp_dir!(), "shell_log_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.TestContext.local(),
        ["components", home.id, "tinctures", "local", @tincture, "1.0.0"]
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

    File.write!(Path.join(dir, "index.html"), "<html><body>log</body></html>")

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, original_path)
      File.rm_rf(base)
      Prism.TinctureRegistry.reload()
    end)

    {:ok, conn: conn, user: user, home: home}
  end

  test "an invoke files started and finished request-log rows", %{conn: conn, home: home} do
    {view, html} = mount_athanor(conn, "/tinctures")
    assert html =~ @tincture

    render_hook(view, "iframe_message", %{
      "window_id" => @window_id,
      "message" => %{
        "type" => "cyfr:request",
        "action" => "invoke",
        "id" => "req-log-1",
        "payload" => %{"reference" => "reagent:local.echo", "input" => %{}}
      }
    })

    rows =
      Arca.Repo.all(
        from(l in Arca.McpLog,
          where: l.method == "LIVE /shell/invoke" and l.athanor_id == ^home.id
        )
      )

    assert [row] = rows
    assert row.tool == "tincture"
    assert row.action == "invoke"
    # This tincture has no granted profile, so the invoke fails — and the
    # failure is on the row, with its duration, like the HTTP ingress.
    assert row.status in ["error", "failed"]
    assert is_integer(row.duration_ms)
  end
end
