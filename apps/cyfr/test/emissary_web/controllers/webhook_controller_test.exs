# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.WebhookControllerTest do
  use EmissaryWeb.ConnCase, async: false

  require Arca.Repo.Errors

  alias Sanctum.Webhook

  setup do
    # Each hook targets a unique registered-but-artifact-less component:
    # create-time target validation passes, while execution still fails
    # cleanly (blob fetch finds nothing). The controller dispatches async,
    # so that failure surfaces as `[:invoke, :stop]` telemetry with
    # `status: :error` from inside the spawned task — the HTTP response is
    # always `200 {"status":"accepted",...}` regardless.

    # Attach a single telemetry handler (per-test, detached on exit) so tests
    # can synchronize on the async invoke completing.
    handler_id = "wh-ctrl-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:cyfr, :emissary, :webhook, :invoke, :stop],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp create_hook!(ctx, name, opts \\ %{}) do
    comp = "wh-target-#{System.unique_integer([:positive])}"
    Sanctum.Test.ComponentHelpers.register_test_component(comp, "1.0.0", "formula", %{})
    profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.#{comp}")

    {:ok, result} =
      Webhook.create(
        ctx,
        Map.merge(%{name: name, target_ref: "f:local.#{comp}", profile_id: profile}, opts)
        |> Map.put_new(:replay_protection, "none")
      )

    result
  end

  # Ecto.Query's `where` is a macro, so the pin lives inside a function that
  # imports it rather than at the call site.
  defp unbind_query(slug) do
    import Ecto.Query, only: [where: 3]
    where(Arca.Schemas.Webhook, [w], w.slug == ^slug)
  end

  defp hmac_hex(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp post_signed(conn, slug, secret, body, header \\ "x-cyfr-signature") do
    sig = "sha256=" <> hmac_hex(secret, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header(header, sig)
    |> post("/hooks/" <> slug, body)
  end

  describe "POST /hooks/:slug — auth boundaries" do
    test "404 on unknown slug", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cyfr-signature", "sha256=deadbeef")
        |> post("/hooks/wh_does_not_exist", ~s({}))

      assert conn.status == 404
      assert json_response(conn, 404)["code"] == "not_found"
    end

    test "404 on disabled webhook (no enumeration leak)", %{conn: conn, ctx: ctx} do
      %{slug: slug, secret: secret} = create_hook!(ctx, "disabled")
      :ok = Webhook.revoke(ctx, "disabled")

      body = ~s({})
      conn = post_signed(conn, slug, secret, body)

      assert conn.status == 404
    end

    test "the channel is the athanor's: a departed creator leaves it running, an archived athanor or a denied creator closes it (no enumeration leak)",
         %{conn: conn, ctx: ctx} do
      n = System.unique_integer([:positive])
      # The creator is a person this server knows, named by their own id.
      {ctx, creator} = Sanctum.TestContext.person!(ctx, %{email: "hooks#{n}@example.com"})
      {:ok, group} = Sanctum.Tenancy.Athanors.create_group(ctx.user_id, "Hooks #{n}")
      in_group = %{ctx | athanor_id: group.id}

      comp = "wh-chan-#{n}"

      Sanctum.Test.ComponentHelpers.register_test_component(
        comp,
        "1.0.0",
        "formula",
        %{},
        in_group
      )

      profile = Sanctum.Test.ConsentFixtures.bindable_profile(in_group, "f:local.#{comp}")

      {:ok, %{slug: slug, secret: secret}} =
        Webhook.create(in_group, %{
          name: "channel",
          replay_protection: "none",
          target_ref: "f:local.#{comp}",
          profile_id: profile
        })

      # the creator leaving the group (another member remains) changes nothing
      other = "github|https://github.com|other-#{n}"

      {:ok, _} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: other,
          provider: "github",
          email: "other#{n}@example.com",
          verified: true
        })

      {:ok, :added} = Sanctum.Tenancy.Members.add(group, [user_id: other], ctx.user_id)
      :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: ctx.user_id)
      refute post_signed(conn, slug, secret, ~s({})).status == 404

      # an archived athanor closes it, without leaking existence
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)
      conn2 = post_signed(conn, slug, secret, ~s({}))
      assert conn2.status == 404
      assert json_response(conn2, 404)["code"] == "not_found"
      {:ok, _} = Sanctum.Tenancy.Athanors.unarchive(group)

      # a denied creator closes it too
      {:ok, _} = Sanctum.Tenancy.Users.deny(creator)
      assert post_signed(conn, slug, secret, ~s({})).status == 404
    end

    test "401 on missing signature header", %{conn: conn, ctx: ctx} do
      %{slug: slug} = create_hook!(ctx, "no-sig")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/hooks/" <> slug, ~s({}))

      assert conn.status == 401
      assert json_response(conn, 401)["code"] == "unauthenticated"
    end

    test "401 on signature mismatch", %{conn: conn, ctx: ctx} do
      %{slug: slug} = create_hook!(ctx, "mismatch")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cyfr-signature", "sha256=0000")
        |> post("/hooks/" <> slug, ~s({"x":1}))

      assert conn.status == 401
    end

    test "401 on tampered body (signature was for different bytes)", %{conn: conn, ctx: ctx} do
      %{slug: slug, secret: secret} = create_hook!(ctx, "tamper")
      signed_body = ~s({"original":true})
      sig = "sha256=" <> hmac_hex(secret, signed_body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cyfr-signature", sig)
        |> post("/hooks/" <> slug, ~s({"tampered":true}))

      assert conn.status == 401
    end

    test "401 with default header when webhook configured to use custom header", %{
      conn: conn,
      ctx: ctx
    } do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "custom-header", %{signature_header: "X-Hub-Signature-256"})

      body = ~s({})
      sig = "sha256=" <> hmac_hex(secret, body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-cyfr-signature", sig)
        |> post("/hooks/" <> slug, body)

      assert conn.status == 401
    end

    test "passes signature check with custom header configured", %{conn: conn, ctx: ctx} do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "github-style", %{signature_header: "X-Hub-Signature-256"})

      body = ~s({"github":"event"})

      conn = post_signed(conn, slug, secret, body, "x-hub-signature-256")

      # Signature OK → controller accepts and dispatches async → 200 accepted.
      # (Pre-async: this would hit the controller and return 500 on missing
      # component; now the missing-component error surfaces via telemetry.)
      assert conn.status == 200
      response = json_response(conn, 200)
      assert response["status"] == "accepted"
      request_id = response["request_id"]

      # Sync on the spawned task so the test process doesn't exit while
      # `Crucible.Dispatch.run/4` is still mid-query (would yank the Ecto sandbox
      # connection and produce noisy crash logs).
      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                      %{request_id: ^request_id}},
                     2_000
    end
  end

  describe "POST /hooks/:slug — async dispatch on valid signature" do
    test "returns 200 accepted with request_id immediately; missing component surfaces via :invoke, :stop telemetry",
         %{
           conn: conn,
           ctx: ctx
         } do
      %{slug: slug, secret: secret} = create_hook!(ctx, "valid")
      body = ~s({"event":"x"})

      conn = post_signed(conn, slug, secret, body)

      # HTTP path: 200 accepted with correlation request_id.
      assert conn.status == 200
      response = json_response(conn, 200)
      assert response["status"] == "accepted"
      request_id = response["request_id"]
      assert is_binary(request_id)

      # The missing target produces an async execution error reported through
      # [:invoke, :stop] telemetry after the HTTP response has been sent.
      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                      %{request_id: ^request_id, status: :error}},
                     2_000
    end

    test "an unbound registration is unrepresentable", %{ctx: ctx} do
      # A webhook fires under its bound profile's consent or not at all.
      # `create/2` and `update/3` both refuse a nil profile_id, and the
      # column is NOT NULL — even a raw write cannot mint an unbound row.
      %{slug: slug} = create_hook!(ctx, "unbound")

      # Adapter-portable NOT NULL assertion: the storage layer owns which
      # driver's error a constraint violation arrives as.
      message =
        try do
          Arca.Repo.update_all(unbind_query(slug), set: [profile_id: nil])
          flunk("expected the unbind to violate the NOT NULL constraint")
        rescue
          e in Arca.Repo.Errors.db_errors() -> Exception.message(e)
        end

      assert message =~ ~r/not.?null/i
    end

    test "valid signature with input_template merges into invoke envelope", %{
      conn: conn,
      ctx: ctx
    } do
      %{slug: slug, secret: secret} =
        create_hook!(ctx, "with-template", %{
          input_template: %{"channel" => "alerts", "priority" => "high"}
        })

      body = ~s({"event":"deploy"})

      conn = post_signed(conn, slug, secret, body)

      # 200 accepted; the merge/envelope path is exercised by the spawned
      # task and surfaces as `[:invoke, :stop]` (status: :error because the
      # target component doesn't exist).
      assert conn.status == 200
      request_id = json_response(conn, 200)["request_id"]

      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                      %{request_id: ^request_id}},
                     2_000
    end
  end

  describe "POST /hooks/:slug — body integrity" do
    test "raw body preservation across Plug.Parsers (signature verifies because body_reader cached the bytes)",
         %{
           conn: conn,
           ctx: ctx
         } do
      %{slug: slug, secret: secret} = create_hook!(ctx, "raw-body")

      # Exact-byte-match scenario: parsers decode JSON and rebuild body_params,
      # but signature MUST verify against the raw bytes. If body_reader didn't
      # cache the raw body, signature would fail → 401. The 200 accepted
      # response (and the subsequent telemetry) proves body_reader cached
      # correctly.
      body = ~s({"a":1,"b":2})

      conn = post_signed(conn, slug, secret, body)

      assert conn.status == 200
      request_id = json_response(conn, 200)["request_id"]

      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                      %{request_id: ^request_id}},
                     2_000
    end
  end

  describe "POST /hooks/:slug — the delivery is one recorded decision" do
    defp decisions_for(request_id) do
      import Ecto.Query, only: [from: 2]

      Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id))
    end

    defp log_rows_for(request_id) do
      import Ecto.Query, only: [from: 2]
      Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.request_id == ^request_id))
    end

    defp executions_for(call_id) do
      import Ecto.Query, only: [from: 2]
      Arca.Repo.all(from(e in Arca.Schemas.Execution, where: e.call_id == ^call_id))
    end

    @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)

    # A hook whose target runs: a published component, its profile's head
    # consent activating that release, and a scripted worker service that
    # answers the run.
    defp runnable_hook!(ctx) do
      name = "wh-run-#{System.unique_integer([:positive])}"
      reference = "reagent:local.#{name}"

      {:ok, component} =
        Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
          name: name,
          version: "1.0.0",
          type: "reagent"
        })

      profile_id = "prof_#{name}"

      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          ctx,
          %{
            id: profile_id,
            kind: :owner,
            source_ref: reference,
            label: "default",
            status: :active
          },
          %{
            id: "consent-#{profile_id}",
            revision: 1,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: "sha256:shape-#{profile_id}",
            commit_digest: "sha256:commit-#{profile_id}",
            resolved_policy:
              Jason.encode!(%{
                "canonical" => "jcs-1",
                "nodes" => %{
                  reference => %{
                    "limits" => Prima.Test.AuthorityFixtures.limits_map(),
                    "edges" => %{"@ingress" => %{}}
                  }
                }
              }),
            activation: %{reference => component.release_digest},
            vault_refs: []
          }
        )

      previous = Application.get_env(:cyfr, :opus_workers)
      on_exit(fn -> Application.put_env(:cyfr, :opus_workers, previous) end)

      Application.put_env(
        :cyfr,
        :opus_workers,
        Cyfr.Test.ScriptedWorker.workers(reference, previous)
      )

      start_supervised!({Cyfr.Test.ScriptedWorker, ref: reference, script: [%{"ran" => true}]})

      {:ok, hook} =
        Webhook.create(ctx, %{
          name: "audited",
          target_ref: "#{reference}:1.0.0",
          profile_id: profile_id,
          replay_protection: "none"
        })

      hook
    end

    # Every loss of a decision or its completion; a second completion that
    # differed from the first would be one (a conflict).
    defp watch_losses do
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:cyfr, :grimoire, :decision, :lost],
        fn _event, _measurements, metadata, test -> send(test, {:decision_lost, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "a signed delivery is one admitted decision with its row, its run's execution and one completion",
         %{conn: conn, ctx: ctx} do
      watch_losses()
      %{slug: slug, secret: secret} = runnable_hook!(ctx)

      conn = post_signed(conn, slug, secret, ~s({"event":"x"}))
      request_id = json_response(conn, 200)["request_id"]

      # The completion is recorded before the task's stop telemetry.
      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _,
                      %{request_id: ^request_id}},
                     5_000

      assert [decision] = decisions_for(request_id)
      assert "call_" <> _ = decision.call_id
      assert decision.tool == "webhook"
      assert decision.action == "invoke"
      assert decision.plane == "external"
      assert decision.admission == "admitted"
      # Attributed as the delivery was established: the webhook's athanor
      # and its own identity.
      assert decision.athanor_id == ctx.athanor_id
      assert decision.user_id == "webhook:" <> slug
      assert decision.completion == "succeeded"
      assert %DateTime{} = decision.completed_at

      assert [row] = log_rows_for(request_id)
      assert row.id == decision.call_id
      assert row.method == "POST /hooks/:slug"
      assert row.status == "success"

      # The run the delivery started names the decision it was admitted under.
      assert [execution] = executions_for(decision.call_id)
      assert execution.request_id == request_id
      assert execution.status == "completed"

      refute_received {:decision_lost, _}
    end

    test "a delivery refused for want of an engine is closed once, failed", %{
      conn: conn,
      ctx: ctx
    } do
      watch_losses()
      %{slug: slug, secret: secret} = create_hook!(ctx, "no-engine")

      previous = Application.get_env(:cyfr, :opus_workers)
      Application.put_env(:cyfr, :opus_workers, [])
      on_exit(fn -> Application.put_env(:cyfr, :opus_workers, previous) end)

      conn = post_signed(conn, slug, secret, ~s({"event":"x"}))
      assert conn.status == 503
      Application.put_env(:cyfr, :opus_workers, previous)

      assert [decision] = Arca.Repo.all(Arca.Schemas.DecisionLog)
      assert decision.tool == "webhook"
      assert decision.admission == "admitted"
      assert decision.completion == "failed"
      assert is_binary(decision.completion_class)

      assert [row] = log_rows_for(decision.request_id)
      assert row.id == decision.call_id
      assert row.status == "error"
      assert executions_for(decision.call_id) == []

      refute_received {:decision_lost, _}
    end

    @tag capture_log: true
    test "a run that raises is closed once, failed, by the task's rescue", %{
      conn: conn,
      ctx: ctx
    } do
      watch_losses()
      %{slug: slug, secret: secret} = create_hook!(ctx, "raises")

      # A worker roster the availability check reads past, whose first
      # service does not run this component and whose rest is not a list:
      # the delivery is accepted, and the run's own lookup of a worker for
      # the component raises inside the task.
      previous = Application.get_env(:cyfr, :opus_workers)
      [endpoint | _] = previous
      on_exit(fn -> Application.put_env(:cyfr, :opus_workers, previous) end)

      Application.put_env(:cyfr, :opus_workers, [
        Map.put(endpoint, :components, ["no-such-component"]) | :not_a_worker
      ])

      conn = post_signed(conn, slug, secret, ~s({"event":"x"}))
      request_id = json_response(conn, 200)["request_id"]

      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _,
                      %{request_id: ^request_id, error: "execution_crashed"}},
                     5_000

      Application.put_env(:cyfr, :opus_workers, previous)

      assert [decision] = decisions_for(request_id)
      assert decision.completion == "failed"
      assert decision.completion_class == "internal"

      assert [row] = log_rows_for(request_id)
      assert row.status == "error"

      refute_received {:decision_lost, _}
    end
  end
end
