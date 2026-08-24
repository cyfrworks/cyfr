# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveInvokeThrottleTest do
  @moduledoc """
  The shell's postMessage invoke path carries its own rate limit, keyed by
  person rather than by IP like the HTTP route's.

  It had no coverage at all: `config/test.exs` sets
  `:tincture_rate_limit_max` to 1_000_000 for the whole suite, and
  `invoke_throttled?/2` reads that key — so the limiter answered `false` in
  every test and could have been deleted without turning anything red. This
  drives it through the socket with the budget turned down.
  """

  use PrismWeb.ConnCase, async: false

  @tincture "throttle-dash"
  @window_id "iframe_throttle-dash"

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    home = Sanctum.Tenancy.Athanors.home!()

    base = Path.join(System.tmp_dir!(), "shell_throttle_#{System.unique_integer([:positive])}")
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

    File.write!(Path.join(dir, "index.html"), "<html><body>throttle</body></html>")

    original_max = Application.get_env(:cyfr, :tincture_rate_limit_max)
    Application.put_env(:cyfr, :tincture_rate_limit_max, 1)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, original_path)

      if original_max,
        do: Application.put_env(:cyfr, :tincture_rate_limit_max, original_max),
        else: Application.delete_env(:cyfr, :tincture_rate_limit_max)

      File.rm_rf(base)
      # The registry is a single server-wide GenServer; leave it holding the
      # real components root rather than this test's tmp one.
      Prism.TinctureRegistry.reload()
    end)

    {:ok, conn: conn, user: user}
  end

  defp invoke(view) do
    render_hook(view, "iframe_message", %{
      "window_id" => @window_id,
      "message" => %{
        "type" => "cyfr:request",
        "action" => "invoke",
        "id" => "req-#{System.unique_integer([:positive])}",
        "payload" => %{"reference" => "reagent:local.echo", "input" => %{}}
      }
    })
  end

  test "a second invoke inside the window is refused", %{conn: conn} do
    {view, html} = mount_athanor(conn, "/tinctures")
    assert html =~ @tincture

    # The first spends the budget. Whatever the execution answers is beside
    # the point — the limiter runs before it.
    invoke(view)

    invoke(view)

    assert_push_event(view, "iframe_response:#{@window_id}", %{
      error: "rate limited — retry shortly"
    })
  end

  test "the budget is the person's, so a second person is unaffected", %{conn: conn} do
    {view, _html} = mount_athanor(conn, "/tinctures")
    invoke(view)
    invoke(view)
    assert_push_event(view, "iframe_response:#{@window_id}", %{error: "rate limited" <> _})

    # A different person mounting the same tincture starts with a full budget:
    # the key is {:live, user_id}, not the tincture alone.
    other = test_user()
    other_conn = log_in_user(Phoenix.ConnTest.build_conn(), other)
    {other_view, _html} = mount_athanor(other_conn, "/tinctures")

    invoke(other_view)

    refute_push_event(other_view, "iframe_response:#{@window_id}", %{
      error: "rate limited — retry shortly"
    })
  end
end
