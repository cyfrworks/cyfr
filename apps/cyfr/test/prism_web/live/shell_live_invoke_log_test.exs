# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveInvokeLogTest do
  @moduledoc """
  The console shell's invoke is a run ingress like the HTTP tincture
  route, so it files the same request-log row: the gate's, one per call,
  naming the declared action it called.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query

  @tincture "log-dash"
  @window_id "iframe_log-dash"

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    estate = seated_athanor()

    base = Path.join(System.tmp_dir!(), "shell_log_#{System.unique_integer([:positive])}")
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

    File.write!(Path.join(dir, "index.html"), "<html><body>log</body></html>")

    # Reload the registry after writing fixtures directly to disk without an AutoIndexer notification.
    Prism.TinctureRegistry.reload_athanor(estate.id)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, user: user, estate: estate}
  end

  # The registry is one server-wide process; it is left holding the real
  # components root. The reload runs on a checkout of its own, lent to the
  # registry alone: the test's owner may already have lost its connection
  # to a query the invoke still had in flight when the test process
  # exited, and the pool's shared mode is not this callback's to move.
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

  test "an invoke files one request-log row, the gate's", %{conn: conn, estate: estate} do
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
        from(l in Arca.Schemas.McpLog,
          where: l.tool == "tincture" and l.athanor_id == ^estate.id
        )
      )

    # One row: nothing but the gate logs the call.
    assert [row] = rows
    assert row.method == "tools/call"
    assert row.action == "invoke_protected"
    assert row.id == row.request_id
    # This tincture has no granted profile, so the invoke fails — and the
    # failure is on the row, with its duration, like the HTTP ingress.
    assert row.status in ["error", "failed"]
    assert is_integer(row.duration_ms)
  end
end
