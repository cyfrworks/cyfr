# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentDetailLiveTest do
  @moduledoc """
  The component detail page renders what `component/inspect` answers,
  its dependencies as the tree the resolver reads.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait, only: [wait_until: 3]

  # How long a test waits for the registry's answer to reach the page.
  @answered_ms 5_000

  # How long a test waits for a run started from the page to end.
  @run_ms 30_000

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

  # The store made unable to read `table` for the rest of the test: the
  # table renamed inside the test's sandbox transaction, which the sandbox
  # rolls back on every exit of the test, the table's name with it. No
  # restore is made inside the transaction: on postgres the first failed
  # read aborts it, and nothing the test runs after that reaches the
  # database, so the outage is the test's last step that does. This file
  # is synchronous (`async: false`) because the rename is seen by every
  # process on the test's connection.
  defp unreadable!(table) do
    Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unreadable")
    :ok
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

    @acknowledgements %{
      "good_faith" =>
        "I believe in good faith that the use I report is not authorised by the copyright owner, its agent or the law.",
      "accuracy" =>
        "The information in this report is accurate, and under penalty of perjury I am the copyright owner or authorised to act for the owner of an exclusive right that is allegedly infringed.",
      "identified" => "I have identified the copyrighted work and the material that infringes it."
    }

    defp copyright_claim(ticked) do
      %{
        "category" => "dmca",
        "details" => "It copies my published work.",
        "acknowledgements" => Map.new(ticked, &{&1, "true"})
      }
    end

    defp report_bodies do
      receive do
        {:registry_request, %{method: "POST", path: "/v1/abuse-reports", body: body}} ->
          [Jason.decode!(body) | report_bodies()]

        {:registry_request, _other} ->
          report_bodies()
      after
        0 -> []
      end
    end

    test "the sheet shows the three acknowledgements for a copyright claim alone",
         %{conn: conn, ctx: ctx} do
      publish_reportable!(ctx)
      view = reporting!(conn)
      form = element(view, ~s(form[phx-submit="submit_report"]))

      html = render_change(form, %{"category" => "dmca", "details" => "Mine."})
      for {_key, sentence} <- @acknowledgements, do: assert(html =~ html_escape(sentence))

      html = render_change(form, %{"category" => "ip_infringement", "details" => "Mine."})
      for {_key, sentence} <- @acknowledgements, do: refute(html =~ html_escape(sentence))
      # What was written stays through the change of category.
      assert html =~ "Mine."
    end

    test "a copyright claim ticked in full is sent with the statement",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, :nothing_held)
      view = reporting!(conn)

      render_submit(
        element(view, ~s(form[phx-submit="submit_report"])),
        copyright_claim(Map.keys(@acknowledgements))
      )

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Report submitted. Thanks." end,
        @answered_ms,
        "the registry's answer to reach the page"
      )

      assert report_bodies() == [
               %{
                 "category" => "dmca",
                 "target_namespace" => nil,
                 "target_component_id" => "cmp_reportable",
                 "details" => "It copies my published work.",
                 "attestations_signed" => true
               }
             ]
    end

    test "a copyright claim not ticked in full is refused and nothing is sent",
         %{conn: conn, ctx: ctx, user: user} do
      publish_reportable!(ctx)
      registry!(ctx, user, :nothing_held)
      view = reporting!(conn)

      render_submit(
        element(view, ~s(form[phx-submit="submit_report"])),
        copyright_claim(["good_faith", "identified"])
      )

      Prima.Test.Wait.wait_until(
        fn ->
          render(view) =~
            html_escape(
              "A copyright claim needs the report sheet's three acknowledgements ticked before it is sent."
            )
        end,
        @answered_ms,
        "the refusal to reach the page"
      )

      assert has_element?(view, "#report-modal")
      assert report_bodies() == []
    end

    defp html_escape(text),
      do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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
        # sleep-ok: twice the browser's 1 s push wait, in which the dialog must not leave
        # "Sending…"
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

  describe "the run form" do
    setup %{ctx: ctx} do
      Cyfr.Test.SeedBundle.isolate!()

      {:ok, _} =
        Arca.Test.UnitFixtures.ship_bytes!(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
          name: "run-probe",
          version: "0.1.0",
          type: "reagent",
          description: "answers every input but a trap"
        })

      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
      :ok
    end

    defp runs(ctx) do
      {:ok, %{count: count}} =
        Sanctum.Gate.call_external("execution", ctx, %{"action" => "list"})

      count
    end

    test "sends typed JSON as the run's input and shows the run's result", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/components/reagent:local.run-probe:0.1.0")

      view |> form("#run-form", %{"input" => ~s({"a": 1})}) |> render_submit()

      wait_until(fn -> has_element?(view, "#run-result") end, @run_ms, "the run's result")
      assert has_element?(view, "#run-result", "Completed")
      assert has_element?(view, "#run-result pre", ~s("ran": true))
      refute has_element?(view, "#run-error")
    end

    test "a run that fails says so, and the form takes the next run", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/components/reagent:local.run-probe:0.1.0")

      view |> form("#run-form", %{"input" => ~s({"trap": true})}) |> render_submit()
      wait_until(fn -> not has_element?(view, "#run-going") end, @run_ms, "the run's end")
      assert has_element?(view, "#run-result", "Failed") or has_element?(view, "#run-error")
      refute has_element?(view, "#run-result pre", ~s("ran": true))

      view |> form("#run-form", %{"input" => ~s({"a": 1})}) |> render_submit()

      wait_until(
        fn -> has_element?(view, "#run-result", "Completed") end,
        @run_ms,
        "the next run"
      )

      refute has_element?(view, "#run-error")
    end

    test "input that is not a JSON object runs nothing and says why", %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/components/reagent:local.run-probe:0.1.0")
      before = runs(ctx)

      view |> form("#run-form", %{"input" => "[1, 2]"}) |> render_submit()
      assert has_element?(view, "#run-error", "The input must be a JSON object")

      view |> form("#run-form", %{"input" => "{oops"}) |> render_submit()
      assert has_element?(view, "#run-error", "The input is not valid JSON.")

      refute has_element?(view, "#run-result")
      assert runs(ctx) == before
    end

    @tag :capture_log
    test "a grant whose head the store cannot answer says so and offers to read it again",
         %{conn: conn} do
      path = "/components/reagent:local.run-probe:0.1.0"

      {view, _html} = mount_athanor(conn, path)
      assert has_element?(view, "#grants li", "Granted · revision")

      # One read of the grants once the heads cannot be read, the list's own.
      :ok = unreadable!("consents")
      view |> with_target("#grants") |> render_click("reload", %{})

      assert has_element?(view, "#grants li", "Could not be read just now.")
      assert has_element?(view, "#grants li button", "Try again")
      refute has_element?(view, "#grants li", "Granted")
      Cyfr.Test.Sandbox.end_views()
    end

    test "lists the component's grants, each with Revoke", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/components/reagent:local.run-probe:0.1.0")

      assert has_element?(view, "#grants li", "Your grant")
      assert has_element?(view, "#grants li button", "Revoke")
    end
  end

  describe "a run that asks its person" do
    alias Cyfr.Test.QuestionFixtures, as: Q

    @probe Path.expand(
             "../../../../locus/test/support/runtime/test_wasm/question_probe/question_probe.wasm",
             __DIR__
           )

    @page "/components/catalyst:local.question-probe:1.0.0"

    # The question probe (`test_wasm/question_probe`), which asks before
    # each statement it is handed and reports what it was told, run by
    # the runtime from the page as a person starts it.
    setup %{ctx: ctx} do
      Q.isolate!()
      Sanctum.Test.Newcomers.directory!()

      {:ok, _} =
        Arca.Test.UnitFixtures.ship_bytes!(ctx, File.read!(@probe), %{
          name: "question-probe",
          version: "1.0.0",
          type: "catalyst",
          manifest: %{"asks" => Q.asks()}
        })

      # A second component of the same athanor, to move the page to.
      {:ok, _} =
        Arca.Test.UnitFixtures.ship_bytes!(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
          name: "run-probe",
          version: "0.1.0",
          type: "reagent",
          description: "answers every input but a trap"
        })

      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
      :ok
    end

    @other "/components/reagent:local.run-probe:0.1.0"

    defp patch!(view, path), do: render_patch(view, PrismWeb.ConnCase.athanor_path(path, nil))

    # The form free: no run going, the button pressable, the box empty.
    defp free?(view) do
      not has_element?(view, "#run-going") and
        not has_element?(view, ~s(#run-form button[disabled])) and
        not has_element?(view, "#run-result") and
        view
        |> element("#run-form textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim() == ""
    end

    # The page has taken its run task's answer: LiveView forgets the task
    # once its answer is handled, whatever the page does with it.
    defp taken!(view) do
      wait_until(
        fn -> is_nil(:sys.get_state(view.pid).socket.private[:live_async][:run]) end,
        @answered_ms,
        "the run's answer taken by the page"
      )
    end

    defp completed!(ctx) do
      wait_until(
        fn -> match?([%{status: "completed"}], probe_runs(ctx)) end,
        @run_ms,
        "the run's end"
      )
    end

    defp statements(list),
      do: Jason.encode!(%{"operation" => "run", "params" => %{"statements" => list}})

    # The run form's submit, as the browser pushes it: waited on no
    # longer than the browser waits (`@push_timeout_ms`).
    defp start(view, list) do
      form = form(view, "#run-form", %{"input" => statements(list)})
      task = Task.async(fn -> render_submit(form) end)

      case Task.yield(task, @push_timeout_ms) do
        {:ok, html} -> html
        nil -> :unanswered
      end
    end

    defp card!(view),
      do:
        wait_until(
          fn -> has_element?(view, ~s([data-test="question"])) end,
          @answered_ms,
          "the card on the page that started the run"
        )

    defp answers_shown(view) do
      wait_until(fn -> has_element?(view, "#run-result") end, @run_ms, "the run's result")

      view
      |> element("#run-result pre")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> Jason.decode!()
      |> get_in(["data", "results"])
      |> Enum.map(& &1["answer"])
    end

    defp choose(view, choice),
      do:
        view
        |> element(~s([data-test="question-choice"][data-choice="#{choice}"]))
        |> render_click()

    defp questions_of(id) do
      import Ecto.Query
      from(q in Arca.Schemas.Question, where: q.execution_id == ^id)
    end

    # The probe's runs, read from the store: every one the test started.
    defp probe_runs(ctx) do
      import Ecto.Query

      Arca.Repo.all(
        from(e in Arca.Schemas.Execution,
          where: e.athanor_id == ^ctx.athanor_id and like(e.reference, "%question-probe%")
        )
      )
    end

    for {choice, answer} <- [allow_once: "allowed", deny_always_this_caller: "denied"] do
      test "the page stays live while its run waits on the card, draws the card itself, and " <>
             "shows the run's result once it is #{answer}",
           %{conn: conn} do
        {view, _html} = mount_athanor(conn, @page)

        assert is_binary(start(view, ["DROP TABLE users"])), "the page answered the press"
        assert has_element?(view, "#run-going")
        assert has_element?(view, ~s(#run-form button[disabled]), "Running")

        card!(view)
        refute has_element?(view, "#run-result")

        choose(view, unquote(to_string(choice)))
        assert answers_shown(view) == [unquote(answer)]
        refute has_element?(view, "#run-going")
        refute has_element?(view, ~s([data-test="question"]))

        # What the person typed is still in the form.
        assert view |> element("#run-form textarea") |> render() =~ "DROP TABLE users"
      end
    end

    test "a run that asks nothing shows its result with no card", %{conn: conn} do
      {view, _html} = mount_athanor(conn, @page)

      assert is_binary(start(view, ["TRUNCATE users"]))
      assert answers_shown(view) == ["declined"]
      refute has_element?(view, ~s([data-test="question"]))
    end

    test "a second press while a run is going starts nothing", %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, @page)

      assert is_binary(start(view, ["DROP TABLE users"]))
      card!(view)
      assert is_binary(start(view, ["DROP TABLE logs"]))

      assert [_one] = probe_runs(ctx)

      assert [_one_card] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s([data-test="question"]))
               |> Enum.to_list()

      choose(view, "allow_once")
      assert answers_shown(view) == ["allowed"]
      assert [_one] = probe_runs(ctx)
    end

    test "a run whose page moved to another component shows its result on neither page, " <>
           "and the other's form runs on its own",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, @page)
      assert is_binary(start(view, ["DROP TABLE users"]))
      card!(view)

      patch!(view, @other)
      assert has_element?(view, "h2", "reagent:local.run-probe:0.1.0")
      assert free?(view)

      # The first run, answered on its card, ends on Executions alone.
      choose(view, "allow_once")
      completed!(ctx)
      taken!(view)
      [%{id: id}] = probe_runs(ctx)
      assert [%{state: "allowed"}] = Arca.Repo.all(questions_of(id))
      assert free?(view)

      # The other component's own run shows on its page.
      view |> form("#run-form", %{"input" => ~s({"a": 1})}) |> render_submit()
      wait_until(fn -> has_element?(view, "#run-result", "Completed") end, @run_ms, "its run")
      assert has_element?(view, "#run-result pre", ~s("ran": true))
    end

    test "a page that comes back to a component while its run still goes shows its result " <>
           "on Executions alone",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, @page)
      assert is_binary(start(view, ["DROP TABLE users"]))
      card!(view)

      patch!(view, @other)
      patch!(view, @page)
      assert free?(view)

      choose(view, "allow_once")
      completed!(ctx)
      taken!(view)
      refute has_element?(view, "#run-result")
      assert free?(view)
    end

    test "a page closed while its run waits leaves the run to its end, answered on another screen",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, @page)
      assert is_binary(start(view, ["DROP TABLE users"]))
      card!(view)

      # The browser's connection gone: the page stops as a closed socket
      # stops it.
      {_ref, _topic, proxy} = view.proxy
      Process.unlink(proxy)
      page = Process.monitor(view.pid)
      GenServer.stop(view.pid, {:shutdown, :closed})
      assert_receive {:DOWN, ^page, :process, _pid, {:shutdown, :closed}}, @answered_ms

      {other, _html} = mount_athanor(conn, @page)
      card!(other)
      choose(other, "allow_once")

      completed!(ctx)
      [%{id: id}] = probe_runs(ctx)
      assert [%{state: "allowed"}] = Arca.Repo.all(questions_of(id))

      # Its result is on Executions, not on a page that did not start it.
      refute has_element?(other, "#run-result")
    end
  end

  describe "a catalyst's permissions" do
    alias Cyfr.Test.QuestionFixtures, as: Q
    alias Sanctum.TestContext.Authenticator

    setup %{user: user} do
      Q.isolate!()
      Sanctum.Test.Newcomers.directory!()

      person =
        Sanctum.Context.build(
          user_id: user.user_id,
          athanor_id: seated_athanor().id,
          permissions: Sanctum.Context.person_permissions(),
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      %{person: person, component: Q.catalyst!(person)}
    end

    @page "/components/catalyst:local.tables:1.0.0"

    defp permission(view, action),
      do: element(view, ~s([data-test="permission"][data-action="#{action}"]))

    defp set!(view, action, values) do
      view
      |> form(~s([data-test="permission"][data-action="#{action}"] form), values)
      |> render_submit()
    end

    defp answers(view, action) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-action="#{action}"] [data-test="permission-answer"]))
      |> Enum.map(
        &{hd(LazyHTML.attribute(&1, "data-effect")), hd(LazyHTML.attribute(&1, "data-caller"))}
      )
    end

    test "lists each action the developer says it asks about, each with no answer kept", %{
      conn: conn
    } do
      {view, html} = mount_athanor(conn, @page)
      assert html =~ "The developer says tables asks you before each of these."

      assert has_element?(
               view,
               ~s([data-test="permission"][data-action="delete_table"] p),
               "tables wants to delete a table"
             )

      assert view
             |> element(~s([data-action="delete_rows"] [data-test="permission-none"]))
             |> has_element?()
    end

    test "sets an answer for anyone before any question, changes it, and removes it", %{
      conn: conn,
      person: person
    } do
      {view, _html} = mount_athanor(conn, @page)

      set!(view, "delete_rows", %{"effect" => "deny", "caller" => "any", "lasts" => "always"})
      assert answers(view, "delete_rows") == [{"deny", "any"}]
      assert render(view) =~ "Never allowed when anyone starts it"

      assert [%{action: "delete_rows", caller: "any", effect: "deny", until: nil}] =
               Q.standing(person)

      set!(view, "delete_rows", %{"effect" => "allow", "caller" => "any", "lasts" => "hour"})
      assert [%{effect: "allow", until: %DateTime{} = until}] = Q.standing(person)
      assert DateTime.diff(until, DateTime.utc_now(), :second) in 3500..3600
      assert answers(view, "delete_rows") == [{"allow", "any"}]

      view |> element(~s([data-test="permission-forget"])) |> render_click()
      assert Q.standing(person) == []
      assert answers(view, "delete_rows") == []
    end

    test "offers the callers its questions have had, and sets an answer for one of them", %{
      conn: conn,
      person: person,
      component: component
    } do
      {run, _ref} = Q.open!(person, component, caller: "agent:aqua")
      Q.end!(person, run, :withdrawn)
      {run, _ref} = Q.open!(person, component, caller: "unknown")
      Q.end!(person, run, :withdrawn)

      {view, html} = mount_athanor(conn, @page)
      assert html =~ "when the assistant aqua starts it"
      refute html =~ ~s(value="unknown")

      set!(view, "delete_table", %{
        "effect" => "allow",
        "caller" => "agent:aqua",
        "lasts" => "always"
      })

      # An allow for one caller needs the session alone.
      assert [%{caller: "agent:aqua", effect: "allow", until: nil}] = Q.standing(person)
      assert answers(view, "delete_table") == [{"allow", "agent:aqua"}]
      assert render(view) =~ "Allowed when the assistant aqua starts it, always"
    end

    test "allowing an action always for anyone asks for its confirmation, and is set once it is given",
         %{conn: conn, person: person, user: user} do
      authenticator = Sanctum.TestContext.passkey!(user.user_id)
      {view, _html} = mount_athanor(conn, @page)

      set!(view, "delete_table", %{"effect" => "allow", "caller" => "any", "lasts" => "always"})
      assert Q.standing(person) == []

      html = render(view)
      assert html =~ ~s(data-kind="confirmation")
      assert html =~ ~s(data-own="true")
      [_, ref] = Regex.run(~r/data-prompt-id="confirmation-([^"]+)"/, html)

      # Titled by what it allows, as the card's own confirmation is.
      assert has_element?(
               view,
               "#system-layer-title",
               "Always allow tables to delete a table, for everyone"
             )

      view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()
      assert_push_event(view, "system_layer:hop", %{layer: "system-layer", url: url})
      [_page, fragment] = String.split(url, "#", parts: 2)

      {:ok, request} =
        fragment |> Prima.SignIn.parse_fragment() |> elem(1) |> Prima.SignIn.decode()

      ctx = :sys.get_state(view.pid).socket.assigns.context
      account = Sanctum.TestContext.account!(ctx.user_id)

      assert {:ok, %{purpose: :confirm}} =
               Sanctum.SignIn.answer(
                 Authenticator.answer(authenticator, request, account.identifier),
                 {:session, ctx.session_token_hash}
               )

      Prima.Test.Wait.wait_until(
        fn -> answers(view, "delete_table") == [{"allow", "any"}] end,
        2_000,
        "the answer set after its confirmation"
      )

      assert [%{caller: "any", effect: "allow", until: nil}] = Q.standing(person)
    end

    test "marks an allow whose title was reworded, and lists apart an answer for an action no longer declared",
         %{conn: conn, person: person} do
      put = fn attrs ->
        {:ok, _row} =
          Arca.Questions.put_standing(
            Sanctum.Context.actor(person),
            Map.merge(
              %{
                publisher: "local",
                name: "tables",
                caller: "any",
                effect: "allow",
                until: nil
              },
              attrs
            ),
            verify: fn -> :ok end
          )
      end

      put.(%{
        action: "delete_table",
        declaration_digest:
          Prima.Manifest.Asks.digest(%{name: "delete_table", title: "drop a table"})
      })

      put.(%{
        action: "drop_database",
        declaration_digest:
          Prima.Manifest.Asks.digest(%{name: "drop_database", title: "drop a database"})
      })

      {view, _html} = mount_athanor(conn, @page)

      assert permission(view, "delete_table")
             |> has_element?()

      assert has_element?(
               view,
               ~s([data-action="delete_table"] [data-test="permission-reworded"])
             )

      assert has_element?(
               view,
               ~s([data-test="permissions-retired"] [data-test="permission-answer"])
             )

      refute has_element?(view, ~s([data-test="permission"][data-action="drop_database"]))
    end

    test "an answer set on an older version's page binds the words that page showed", %{
      conn: conn,
      person: person
    } do
      Q.catalyst!(person, "tables", "2.0.0", [
        %{"name" => "delete_table", "title" => "delete every table"}
      ])

      {view, _html} = mount_athanor(conn, @page)

      assert has_element?(
               view,
               ~s([data-test="permission"][data-action="delete_table"] p),
               "tables wants to delete a table"
             )

      set!(view, "delete_table", %{"effect" => "allow", "caller" => "any", "lasts" => "hour"})

      assert [%{declaration_digest: digest}] = Q.standing(person)

      assert digest ==
               Prima.Manifest.Asks.digest(%{name: "delete_table", title: "delete a table"})
    end

    test "an answer whose words were reworded since the page showed them is refused", %{
      conn: conn,
      person: person
    } do
      {view, _html} = mount_athanor(conn, @page)

      # The version the page showed is replaced by one that rewords it.
      Q.catalyst!(person, "tables", "2.0.0", [
        %{"name" => "delete_table", "title" => "delete every table"}
      ])

      :ok =
        Arca.ComponentStorage.delete_component(
          Sanctum.Context.actor(person),
          "tables",
          "1.0.0",
          "local",
          "catalyst"
        )

      set!(view, "delete_table", %{"effect" => "allow", "caller" => "any", "lasts" => "hour"})
      assert Q.standing(person) == []

      assert has_element?(
               view,
               ~s([data-test="permission-error"]),
               "in the words you were shown"
             )
    end

    test "a permission given on the page's own card is listed at once", %{
      conn: conn,
      person: person,
      component: component
    } do
      {view, _html} = mount_athanor(conn, @page)
      {_run, ref} = Q.open!(person, component)

      Prima.Test.Wait.wait_until(
        fn -> has_element?(view, ~s([data-test="question"][data-ref="#{ref}"])) end,
        2_000,
        "the card"
      )

      view |> element(~s([data-choice="allow_hour_this_caller"])) |> render_click()
      assert [_answer] = Q.standing(person)

      Prima.Test.Wait.wait_until(
        fn -> answers(view, "delete_table") == [{"allow", "person"}] end,
        2_000,
        "the list read again"
      )
    end

    # A second screen of the same person: another session of theirs, on a
    # page whose layer draws the card too.
    defp other_screen!(user) do
      other = log_in_user(Phoenix.ConnTest.build_conn(), user, claim: false)
      {view, _html} = mount_athanor(other, "/executions")
      view
    end

    defp card!(view, ref),
      do:
        Prima.Test.Wait.wait_until(
          fn -> has_element?(view, ~s([data-test="question"][data-ref="#{ref}"])) end,
          2_000,
          "the card"
        )

    defp card_gone!(view, ref),
      do:
        Prima.Test.Wait.wait_until(
          fn -> not has_element?(view, ~s([data-test="question"][data-ref="#{ref}"])) end,
          2_000,
          "the card gone"
        )

    test "a permission given on another screen is listed without a reload", %{
      conn: conn,
      user: user,
      person: person,
      component: component
    } do
      {view, _html} = mount_athanor(conn, @page)
      other = other_screen!(user)
      {_run, ref} = Q.open!(person, component)
      card!(view, ref)
      card!(other, ref)

      other |> element(~s([data-choice="allow_hour_this_caller"])) |> render_click()
      assert [_answer] = Q.standing(person)

      Prima.Test.Wait.wait_until(
        fn -> answers(view, "delete_table") == [{"allow", "person"}] end,
        2_000,
        "the list read again"
      )
    end

    # The first screen busy while the question opens and is answered on
    # the second: it never draws the card, and still reads its list again.
    test "a permission given on another screen while this one was busy is listed without a reload",
         %{conn: conn, user: user, person: person, component: component} do
      {view, _html} = mount_athanor(conn, @page)
      other = other_screen!(user)

      :ok = :sys.suspend(view.pid)
      {_run, ref} = Q.open!(person, component)
      card!(other, ref)
      other |> element(~s([data-choice="allow_hour_this_caller"])) |> render_click()
      assert [_answer] = Q.standing(person)
      :ok = :sys.resume(view.pid)

      Prima.Test.Wait.wait_until(
        fn -> answers(view, "delete_table") == [{"allow", "person"}] end,
        2_000,
        "the list read again"
      )

      refute has_element?(view, ~s([data-test="question"]))
    end

    test "an answer given once on another screen leaves the list as it was", %{
      conn: conn,
      user: user,
      person: person,
      component: component
    } do
      {view, _html} = mount_athanor(conn, @page)
      set!(view, "delete_rows", %{"effect" => "deny", "caller" => "any", "lasts" => "always"})
      other = other_screen!(user)
      {_run, ref} = Q.open!(person, component)
      card!(view, ref)

      other |> element(~s([data-choice="allow_once"])) |> render_click()
      card_gone!(view, ref)

      assert answers(view, "delete_table") == []
      assert answers(view, "delete_rows") == [{"deny", "any"}]
      assert [%{action: "delete_rows"}] = Q.standing(person)
    end

    test "an answer for another component's question leaves this page's list as it was", %{
      conn: conn,
      user: user,
      person: person
    } do
      other_component = Q.catalyst!(person, "rows")
      {view, _html} = mount_athanor(conn, @page)
      other = other_screen!(user)
      {_run, ref} = Q.open!(person, other_component)
      card!(view, ref)

      other |> element(~s([data-choice="allow_hour_this_caller"])) |> render_click()
      card_gone!(view, ref)

      assert [_answer] = Q.standing(person, "rows")
      assert answers(view, "delete_table") == []
      assert Q.standing(person) == []
    end

    test "a removal on another screen takes its answers off the list", %{
      conn: conn,
      ctx: ctx,
      person: person
    } do
      # Published, not shipped with the server, so it can be deleted.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "removable",
          version: "1.0.0",
          type: "catalyst",
          publisher: "local",
          manifest:
            Jason.encode!(%{
              "name" => "removable",
              "type" => "catalyst",
              "version" => "1.0.0",
              "publisher" => "local",
              "asks" => Q.asks()
            })
        })

      {view, _html} = mount_athanor(conn, "/components/catalyst:local.removable:1.0.0")
      set!(view, "delete_table", %{"effect" => "allow", "caller" => "any", "lasts" => "hour"})
      assert answers(view, "delete_table") == [{"allow", "any"}]

      assert {:ok, _deleted} =
               PrismWeb.Ops.call_tool(person, "component/delete", %{
                 "reference" => "catalyst:local.removable:1.0.0"
               })

      assert Q.standing(person, "removable") == []

      Prima.Test.Wait.wait_until(
        fn -> answers(view, "delete_table") == [] end,
        2_000,
        "the list read again"
      )
    end

    test "a denial for an hour reads as one, and Never allowed is a denial that lasts", %{
      conn: conn
    } do
      {view, html} = mount_athanor(conn, @page)
      assert html =~ ~s(<option value="deny">Deny</option>)
      refute html =~ "Never allow</option>"

      set!(view, "delete_table", %{"effect" => "deny", "caller" => "any", "lasts" => "hour"})
      assert render(view) =~ "Denied when anyone starts it, until"
      refute render(view) =~ "Never allowed"

      set!(view, "delete_rows", %{"effect" => "deny", "caller" => "any", "lasts" => "always"})
      assert render(view) =~ "Never allowed when anyone starts it"
    end

    test "a time an answer lasts until is marked to show in the person's own time zone", %{
      conn: conn,
      person: person
    } do
      {view, _html} = mount_athanor(conn, @page)
      assert has_element?(view, ~s(#permissions[phx-hook="LocalTimes"]))

      set!(view, "delete_table", %{"effect" => "allow", "caller" => "any", "lasts" => "hour"})
      [%{until: until}] = Q.standing(person)

      assert [time] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s([data-action="delete_table"] time[data-local]))
               |> Enum.to_list()

      assert LazyHTML.attribute(time, "datetime") == [DateTime.to_iso8601(until)]
      assert render(view) =~ "Allowed when anyone starts it,"
    end

    test "each answer for an action no longer declared names its action", %{
      conn: conn,
      person: person
    } do
      for action <- ["drop_database", "drop_schema"] do
        {:ok, _row} =
          Arca.Questions.put_standing(
            Sanctum.Context.actor(person),
            %{
              publisher: "local",
              name: "tables",
              action: action,
              declaration_digest:
                Prima.Manifest.Asks.digest(%{name: action, title: "drop something"}),
              caller: "any",
              effect: "deny",
              until: nil
            },
            verify: fn -> :ok end
          )
      end

      {view, _html} = mount_athanor(conn, @page)

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-test="permissions-retired"] [data-test="permission-answer"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

      assert length(rows) == 2
      assert Enum.any?(rows, &(&1 =~ "drop_database:"))
      assert Enum.any?(rows, &(&1 =~ "drop_schema:"))
      assert Enum.uniq(rows) == rows
    end

    test "a reagent's page lists no permissions", %{conn: conn, ctx: ctx} do
      publish_reportable!(ctx)
      {view, _html} = mount_athanor(conn, "/components/reagent:local.reportable:1.0.0")
      refute has_element?(view, ~s([data-test="permissions"]))
    end
  end
end
