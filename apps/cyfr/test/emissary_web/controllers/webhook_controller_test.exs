# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.WebhookControllerTest do
  use EmissaryWeb.ConnCase, async: false

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
    Sanctum.Test.ConsentFixtures.start_source!()
    profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.#{comp}")

    {:ok, result} =
      Webhook.create(
        ctx,
        Map.merge(%{name: name, target_ref: "f:local.#{comp}", profile_id: profile}, opts)
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
      assert json_response(conn, 404)["error"] == "not_found"
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

      Sanctum.Test.ConsentFixtures.start_source!()
      profile = Sanctum.Test.ConsentFixtures.bindable_profile(in_group, "f:local.#{comp}")

      {:ok, %{slug: slug, secret: secret}} =
        Webhook.create(in_group, %{
          name: "channel",
          target_ref: "f:local.#{comp}",
          profile_id: profile
        })

      # the creator leaving the group (another member remains) changes nothing
      {:ok, :added} = Sanctum.Tenancy.Members.add(group, [user_id: "other-#{n}"], ctx.user_id)
      :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: ctx.user_id)
      refute post_signed(conn, slug, secret, ~s({})).status == 404

      # an archived athanor closes it, without leaking existence
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)
      conn2 = post_signed(conn, slug, secret, ~s({}))
      assert conn2.status == 404
      assert json_response(conn2, 404)["error"] == "not_found"
      {:ok, _} = Sanctum.Tenancy.Athanors.unarchive(group)

      # a denied creator closes it too
      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: ctx.user_id,
          provider: "github",
          email: "hooks#{n}@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      assert post_signed(conn, slug, secret, ~s({})).status == 404
    end

    test "401 on missing signature header", %{conn: conn, ctx: ctx} do
      %{slug: slug} = create_hook!(ctx, "no-sig")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/hooks/" <> slug, ~s({}))

      assert conn.status == 401
      assert json_response(conn, 401)["error"] == "unauthorized"
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

    @tag :requires_opus
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
      # `Opus.Executor.run/3` is still mid-query (would yank the Ecto sandbox
      # connection and produce noisy crash logs).
      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                      %{request_id: ^request_id}},
                     2_000
    end
  end

  describe "POST /hooks/:slug — async dispatch on valid signature" do
    @tag :requires_opus
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

      # Async path: target component does not exist, so Opus.Executor returns
      # `{:error, _}`. The spawned task records this via `[:invoke, :stop]`
      # telemetry with `status: :error`. The HTTP response went out before
      # this fired — async dispatch is the whole point of P0.2.
      assert_receive {:telemetry, [:cyfr, :emissary, :webhook, :invoke, :stop], _measurements,
                      %{request_id: ^request_id, status: :error}},
                     2_000
    end

    test "an unbound registration is unrepresentable", %{ctx: ctx} do
      # A webhook fires under its bound profile's consent or not at all.
      # `create/2` and `update/3` both refuse a nil profile_id, and the
      # column is NOT NULL — even a raw write cannot mint an unbound row.
      %{slug: slug} = create_hook!(ctx, "unbound")

      # Adapter-portable NOT NULL assertion (Exqlite.Error vs Postgrex.Error).
      message =
        try do
          Arca.Repo.update_all(unbind_query(slug), set: [profile_id: nil])
          flunk("expected the unbind to violate the NOT NULL constraint")
        rescue
          e in [Exqlite.Error, Postgrex.Error] -> Exception.message(e)
        end

      assert message =~ ~r/not.?null/i
    end

    @tag :requires_opus
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
    @tag :requires_opus
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
end
