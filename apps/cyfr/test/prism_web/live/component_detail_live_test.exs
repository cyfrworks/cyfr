# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentDetailLiveTest do
  @moduledoc """
  The component detail page renders what `component/inspect` answers,
  its dependencies as the tree the resolver reads.
  """
  use PrismWeb.ConnCase, async: false

  # How long a test waits for the registry's answer to reach the page.
  @answered_ms 5_000

  # The browser gives up on a pushed event it waits on for 30 seconds and
  # reloads (the shipped script's push timeout); a test stands that wait
  # in with this one.
  @push_timeout_ms 1_000

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    ctx = %{Sanctum.TestContext.local(:prism) | athanor_id: seated_athanor().id}
    %{conn: conn, ctx: ctx, user: user}
  end

  defp publish_reportable!(ctx) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(
        ctx,
        Cyfr.Test.Guests.wasm(:reagent),
        %{
          name: "reportable",
          version: "1.0.0",
          type: "reagent",
          publisher: "local",
          description: "",
          tags: [],
          manifest: "{}"
        },
        source: "filesystem"
      )
  end

  test "a component with dependencies renders each one", %{conn: conn, ctx: ctx} do
    manifest = %{
      "dependencies" => %{
        "static" => [
          %{"ref" => "reagent:local.missing-dep:1.0.0"},
          %{"ref" => "reagent:local.optional-dep:1.0.0", "optional" => true}
        ]
      }
    }

    {:ok, _} =
      Compendium.Registry.publish_bytes(
        ctx,
        Cyfr.Test.Guests.wasm(:reagent),
        %{
          name: "with-deps",
          version: "1.0.0",
          type: "reagent",
          publisher: "local",
          description: "",
          tags: [],
          manifest: Jason.encode!(manifest)
        },
        source: "filesystem"
      )

    {_view, html} = mount_athanor(conn, "/components/reagent:local.with-deps:1.0.0")
    assert html =~ "Dependencies"
    assert html =~ "reagent:local.missing-dep:1.0.0"
    assert html =~ ~r{optional-dep:1\.0\.0</span>\s*<span[^>]*>optional</span>}
    refute html =~ ~r{missing-dep:1\.0\.0</span>\s*<span[^>]*>optional</span>}
  end

  # `config/test.exs` configures a registry that is not cyfr.run: the
  # report goes to its moderators, named as the registry's.
  test "a report goes to the registry's moderators, never cyfr.run's", %{conn: conn, ctx: ctx} do
    publish_reportable!(ctx)

    {view, html} = mount_athanor(conn, "/components/reagent:local.reportable:1.0.0")
    assert html =~ "Report this component to the registry&#39;s moderators"

    render_click(view, "open_report", %{})
    html = render(view)
    assert html =~ "Your report goes to the registry&#39;s moderators."
    refute html =~ "cyfr.run"
  end

  describe "a report sent to the registry" do
    # The registry the report goes to, holding the request at `held` until
    # the test releases it (the test is told `{:held, stub}`), and the
    # person's push token for it.
    defp registry!(ctx, user, held) do
      test = self()

      hold = fn path ->
        if path == held do
          send(test, {:held, self()})

          receive do
            :release -> :ok
          end
        end
      end

      Sanctum.Test.RegistryStub.start!(fn
        %{method: "GET", path: "/v1/components/" <> _ = path} ->
          hold.(path)
          {200, Jason.encode!(%{"id" => "cmp_reportable"})}

        %{method: "POST", path: "/v1/abuse-reports" = path} ->
          hold.(path)
          {201, Jason.encode!(%{"id" => "rep_1"})}
      end)

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          %{ctx | user_id: user.user_id},
          Compendium.RegistryHost.canonical_host(),
          user.namespace,
          "cyfr_pt_reporter",
          "personal"
        )
    end

    defp reporting!(conn) do
      {view, _html} = mount_athanor(conn, "/components/reagent:local.reportable:1.0.0")
      render_click(view, "open_report", %{})
      view
    end

    # The dialog's submit, as the browser pushes it: waited on no longer
    # than the browser waits (`@push_timeout_ms`).
    defp submitted(view) do
      form = element(view, ~s(form[phx-submit="submit_report"]))
      params = %{"category" => "malware", "details" => "It reads keys it was never given."}
      task = Task.async(fn -> render_submit(form, params) end)

      case Task.yield(task, @push_timeout_ms) do
        {:ok, html} -> html
        nil -> :unanswered
      end
    end

    defp reports_sent do
      receive do
        {:registry_request, %{method: "POST", path: "/v1/abuse-reports"}} -> 1 + reports_sent()
        {:registry_request, _other} -> reports_sent()
      after
        0 -> 0
      end
    end

    test "the dialog answers at once, says it is sending, takes no second submit or close, and the answer closes it",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, "/v1/abuse-reports")
      view = reporting!(conn)

      html = submitted(view)
      assert_receive {:held, stub}, @answered_ms

      try do
        assert is_binary(html), "the dialog did not answer while the registry held the report"
        assert html =~ "Sending…"

        # A second submit and a close while it is sent change nothing.
        assert submitted(view) =~ "Sending…"
        render_keydown(element(view, "#report-modal"), %{"key" => "Escape"})
        assert has_element?(view, "#report-modal")

        # Held past the browser's wait, and past it twice, the dialog still
        # waits for the registry.
        Process.sleep(2 * @push_timeout_ms)
        assert render(view) =~ "Sending…"
      after
        send(stub, :release)
      end

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Report submitted. Thanks." end,
        @answered_ms,
        "the registry's answer to reach the page"
      )

      refute has_element?(view, "#report-modal")
      assert reports_sent() == 1
      # A second submit would reach the registry once the first is answered.
      refute_receive {:registry_request, _second}, 500
    end

    test "an answer that comes when the person's session cannot be checked changes nothing",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, "/v1/abuse-reports")
      view = reporting!(conn)
      assert is_binary(submitted(view))
      assert_receive {:held, stub}, @answered_ms
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

      try do
        send(stub, :release)
        render_async(view, @answered_ms)

        assert has_element?(view, "#report-modal"),
               "the async answer changed the dialog without revalidating its session context"

        html = render(view)
        refute html =~ "Report submitted. Thanks."
        assert html =~ "Your session could not be checked just now."
      after
        Arca.Repo.query!("ALTER TABLE sessions_unavailable RENAME TO sessions")
      end
    end

    # A component's own flash shows only when it also redirects; the
    # guard's sentence is shown by the page the dialog is on.
    test "a submit when the person's session cannot be checked says so and sends nothing",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, "/v1/abuse-reports")
      view = reporting!(conn)
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

      try do
        html = submitted(view)
        assert is_binary(html)
        assert has_element?(view, "#report-modal")
        assert render(view) =~ "Your session could not be checked just now."
        assert has_element?(view, "#report-modal button[type=submit]", "Submit report")
      after
        Arca.Repo.query!("ALTER TABLE sessions_unavailable RENAME TO sessions")
      end

      refute_receive {:registry_request, _}, 200
    end

    # A stated limit: the registry keeps every report it is sent as its own
    # (it merges none), and nothing here remembers a report in flight past
    # the page that sent it. A person who leaves while one is sent, comes
    # back and sends it again before the first is answered files two.
    test "a report sent again from a reopened page while the first is in flight is filed as a second",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, "/v1/components/reagent/local/reportable/1.0.0")
      view = reporting!(conn)
      assert is_binary(submitted(view))
      assert_receive {:held, first}, @answered_ms
      {_ref, _topic, proxy} = view.proxy
      Process.unlink(proxy)
      GenServer.stop(view.pid, {:shutdown, :closed})
      again = reporting!(conn)
      assert is_binary(submitted(again))
      # This stub serves connections in order: release the first read
      # before it can accept the second read already in flight.
      send(first, :release)
      assert_receive {:held, second}, @answered_ms
      send(second, :release)

      Prima.Test.Wait.wait_until(
        fn -> render(again) =~ "Report submitted. Thanks." end,
        @answered_ms
      )

      assert_receive {:registry_request, %{method: "POST", path: "/v1/abuse-reports"}},
                     @answered_ms

      assert_receive {:registry_request, %{method: "POST", path: "/v1/abuse-reports"}},
                     @answered_ms
    end

    test "a report the person left while it was sent is filed once",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, "/v1/components/reagent/local/reportable/1.0.0")
      view = reporting!(conn)

      assert is_binary(submitted(view))
      assert_receive {:held, stub}, @answered_ms

      # The browser's connection gone before the report itself is sent:
      # the page stops as a closed socket stops it.
      {_ref, _topic, proxy} = view.proxy
      Process.unlink(proxy)
      page = Process.monitor(view.pid)
      GenServer.stop(view.pid, {:shutdown, :closed})
      assert_receive {:DOWN, ^page, :process, _pid, {:shutdown, :closed}}, @answered_ms

      send(stub, :release)

      assert_receive {:registry_request, %{method: "POST", path: "/v1/abuse-reports"}},
                     @answered_ms

      assert reports_sent() == 0
    end
  end
end
