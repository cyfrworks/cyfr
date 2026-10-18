# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AdmissionEntriesSeamTest do
  @moduledoc """
  Every admission entry `Cyfr.Boundaries.admission_entries/0` rosters,
  driven to its refusal: exactly one decision is recorded for the request,
  with the refusal's class, a null tenant and no request-log row when no
  caller had been established, and no second row from the transport.

  One driver per roster row: a row without a driver, or a driver without
  a row, fails the seam. HTTP entries are driven through the endpoint;
  the gate heads and the HostAPI entry by direct call; the scheduler by
  a due schedule whose run admission fails; the device channel through
  its transport callbacks, since no WebSocket client is in the
  dependencies.
  """

  # Flips rate limits, ownership standing and scheduler configuration.
  use Emissary.Web.ConnCase, async: false

  @moduletag auth: :person

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Cyfr.Boundaries
  alias Emissary.Web.DeviceChannel

  @mcp_unknown_tool_class "not_found"

  # The rows this seam drives: every entry.
  @entries Boundaries.admission_entries()

  setup do
    Prima.Test.RateLimiter.reset!()

    keys = [
      cyfr: :tincture_rate_limit_max,
      cyfr: :cron_scheduler_enabled
    ]

    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end

      Arca.ControlPlane.record(:unclaimed)
      Prima.Test.RateLimiter.reset!()
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # ==========================================================================
  # The roster and its drivers agree
  # ==========================================================================

  # Each driver answers `{where, expected}`: `where` finds the request's
  # decisions (`{:request, id}` by the transport's correlation id, `{:tool,
  # name}` by a name only this run used), and `expected` is the admission
  # and class the row must carry, and whether a caller had been established.
  @drivers %{
    {Sanctum.Gate, :call_external} => :gate_external_head,
    {Sanctum.Gate, :call_in_chain} => :gate_in_chain_head,
    {Sanctum.Gate, :open_stream} => :gate_stream_undeclared,
    {Emissary.MCP.Router, :dispatch} => :router_unknown_tool,
    {Emissary.Web.MCPController, :handle} => :mcp_batch,
    {Emissary.Web.MCPController, :method_not_allowed} => :mcp_get,
    {CyfrWeb.Plugs.Authenticate, :call} => :invalid_api_key,
    {CyfrWeb.Plugs.FrameRequest, :call} => :frame_request,
    {CyfrWeb.Plugs.MCPOrigin, :call} => :origin_rejected,
    {CyfrWeb.Plugs.MCPRateLimit, :call} => :mcp_rate_limited,
    {Emissary.Web.Plugs.MCPRequestMetadata, :call} => :missing_protocol_header,
    {CyfrWeb.Plugs.ControlPlaneOwnership, :call} => :slot_lost,
    {Emissary.Web.TinctureController, :index} => :tincture_index_unknown,
    {CyfrWeb.Plugs.TinctureRateLimit, :call} => :tincture_rate_limited,
    {Emissary.Web.TinctureDataController, :invoke} => :tincture_data_invoke_no_frame,
    {Emissary.Web.TinctureDataController, :system_action} => :tincture_data_action_no_frame,
    {Emissary.Web.TinctureDataController, :stream} => :tincture_data_stream_no_frame,
    {Emissary.Web.TinctureDataController, :canvas_stream} => :tincture_data_canvas_no_frame,
    {Emissary.Web.WebhookController, :invoke} => :webhook_archived_athanor,
    {CyfrWeb.Plugs.VerifyWebhookSignature, :call} => :webhook_unsigned,
    {CyfrWeb.Plugs.WebhookIdempotency, :call} => :webhook_missing_idempotency_key,
    {CyfrWeb.Plugs.WebhookRateLimit, :call} => :webhook_rate_limited,
    {Emissary.Web.ExecutionEventsController, :stream} => :execution_events_unknown,
    {Emissary.Web.DirectoryController, :register} => :directory_register_unserved,
    {Emissary.Web.DirectoryController, :resolve} => :directory_resolve_bad_position,
    {Emissary.Web.DirectoryController, :append} => :directory_append_unserved,
    {Emissary.Web.DirectoryController, :recover} => :directory_recover_unserved,
    {Emissary.Web.DirectoryController, :outcome} => :directory_outcome_unserved,
    {Emissary.Web.RestoreController, :restore} => :restore_disabled,
    {Emissary.Web.RestoreController, :challenge} => :restore_challenge_disabled,
    {Emissary.Web.RestoreController, :reproof} => :restore_reproof_disabled,
    {Emissary.Web.RestoreController, :kit_challenge} => :restore_kit_challenge_not_recovering,
    {Emissary.Web.RestoreController, :kit} => :restore_kit_invalid_proof,
    {Emissary.Web.RestoreController, :kit_reenable} => :restore_kit_reenable_unnamed,
    {Emissary.Web.OAuthCallbackController, :callback} => :oauth_callback_unknown_state,
    {CyfrWeb.Plugs.AuthRateLimit, :call} => :restore_rate_limited,
    {PrismWeb.AuthController, :link_start} => :sign_in_link_unsigned,
    {PrismWeb.AuthController, :request} => :sign_in_cyfr_hop_expired,
    {PrismWeb.AuthController, :device_complete} => :sign_in_device_ticket_unknown,
    {PrismWeb.AuthController, :cyfr_callback} => :sign_in_cyfr_callback_expired,
    {PrismWeb.AuthController, :callback} => :sign_in_callback_empty,
    {PrismWeb.AuthController, :post_legal_accept} => :sign_in_post_legal_no_probe,
    {PrismWeb.PasskeyController, :complete} => :sign_in_passkey_ticket_unknown,
    {PrismWeb.ReauthController, :callback} => :reauth_callback_unstated,
    {PrismWeb.ReauthController, :decide} => :reauth_decide_no_ticket,
    {PrismWeb.LegalAcceptController, :show} => :legal_show_registry_unreachable,
    {PrismWeb.LegalAcceptController, :submit} => :legal_submit_no_version,
    {Opus.Schedules.Scheduler, :handle_info} => :schedule_fire_refused,
    {Opus.Host.Children, :call} => :host_api_lost_attempt,
    {Emissary.Web.DeviceChannel, :handle_in} => :device_channel_unproven
  }

  test "every roster row has one driver and every driver a row" do
    roster = Enum.map(@entries, &{&1.module, &1.site})
    assert Enum.sort(roster) == Enum.sort(Map.keys(@drivers))
  end

  test "no row is marked pending, so none goes undriven" do
    refute Enum.any?(@entries, &Map.has_key?(&1, :pending))
  end

  test "the device channel's row is driven" do
    assert [_row] = Enum.filter(@entries, &(&1.module == DeviceChannel))
    assert Map.fetch!(@drivers, {DeviceChannel, :handle_in}) == :device_channel_unproven
  end

  for %{module: module, site: site, plane: plane} <- @entries do
    @tag entry: {module, site}, plane: plane
    test "#{inspect(module)}.#{site} refuses as one recorded decision on the #{plane} plane",
         %{conn: conn, ctx: ctx, entry: entry, plane: plane} do
      driver = Map.fetch!(@drivers, entry)
      {where, expected} = apply(__MODULE__, driver, [conn, ctx])
      assert_one_decision(where, expected, plane)
    end
  end

  # ==========================================================================
  # The assertion
  # ==========================================================================

  defp assert_one_decision(where, expected, plane) do
    assert [decision] = decisions(where),
           "#{inspect(where)}: expected one decision, found #{inspect(decisions(where))}"

    assert decision.plane == Atom.to_string(plane)
    assert decision.admission == expected.admission

    case expected do
      %{class: class} -> assert decision.refusal_class == class
      %{completion: completion} -> assert decision.completion == completion
    end

    case expected.caller do
      :none ->
        # No caller was established: no actor, a null tenant, and no
        # request-log row (the table's tenant columns stay non-null).
        assert is_nil(decision.athanor_id)
        assert is_nil(decision.user_id)
        assert mcp_rows(where) == []

      :established ->
        refute is_nil(decision.athanor_id)
        # The transport writes no row of its own: the decision's is the one.
        assert [row] = mcp_rows(where)
        assert row.id == decision.call_id
    end
  end

  defp decisions({:request, request_id}),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.request_id == ^request_id))

  defp decisions({:tool, tool}),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == ^tool))

  defp mcp_rows({:request, request_id}),
    do: Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.request_id == ^request_id))

  defp mcp_rows({:tool, tool}),
    do: Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.tool == ^tool))

  defp refused(class, caller), do: %{admission: "refused", class: class, caller: caller}

  defp request_id_of(conn) do
    assert [request_id] = get_resp_header(conn, "x-request-id")
    assert "req_" <> _ = request_id
    {:request, request_id}
  end

  # The wire's own answer names the class: the row must carry the same.
  defp api_class(conn) do
    assert conn.status >= 400
    Jason.decode!(conn.resp_body)["code"]
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ==========================================================================
  # Drivers: the gate's heads
  # ==========================================================================

  def gate_external_head(_conn, ctx) do
    request_id = Prima.UUID7.request_id()
    guest = Sanctum.Context.enter_guest(%{ctx | request_id: request_id})

    assert {:error, %Prima.Refusal{stage: :admission, class: :forbidden}} =
             Sanctum.Gate.call_external("system", guest, %{"action" => "status"})

    {{:request, request_id}, refused("forbidden", :established)}
  end

  def gate_in_chain_head(_conn, ctx) do
    request_id = Prima.UUID7.request_id()

    assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
             Sanctum.Gate.call_in_chain(
               "system",
               %{ctx | request_id: request_id},
               "not an object",
               %Prima.Authority{},
               []
             )

    {{:request, request_id}, refused("invalid_argument", :established)}
  end

  def gate_stream_undeclared(_conn, ctx) do
    request_id = Prima.UUID7.request_id()

    assert {:error, %Prima.Refusal{stage: :admission, class: :not_found}} =
             Sanctum.Gate.open_stream(%{ctx | request_id: request_id}, "nobody.declares")

    {{:request, request_id}, refused("not_found", :established)}
  end

  # ==========================================================================
  # Drivers: the MCP transport
  # ==========================================================================

  defp mcp_call(conn, name, arguments) do
    conn
    |> put_req_header("content-type", "application/json")
    |> mcp_post(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  def router_unknown_tool(conn, _ctx) do
    conn = mcp_call(conn, unique("no-such-tool"), %{"action" => "x"})
    assert json_response(conn, 400)["error"]["code"] == -32_602
    {request_id_of(conn), refused(@mcp_unknown_tool_class, :established)}
  end

  def mcp_batch(conn, _ctx) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(
        CyfrWeb.Endpoint,
        :post,
        "/mcp",
        Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover"}])
      )

    assert json_response(conn, 400)["error"]["code"] == -32_600
    {request_id_of(conn), refused("invalid_argument", :established)}
  end

  def mcp_get(conn, _ctx) do
    conn = get(conn, "/mcp")
    assert json_response(conn, 405)
    {request_id_of(conn), refused("invalid_argument", :established)}
  end

  def invalid_api_key(conn, _ctx) do
    conn =
      conn
      |> put_req_header("authorization", "Bearer cyfr_sk_" <> unique("nope"))
      |> mcp_call("system", %{"action" => "status"})

    assert json_response(conn, 401)
    {request_id_of(conn), refused("unauthenticated", :none)}
  end

  def origin_rejected(conn, _ctx) do
    conn =
      conn
      |> put_req_header("origin", "http://evil.example")
      |> mcp_call("system", %{"action" => "status"})

    assert json_response(conn, 403)
    {request_id_of(conn), refused("forbidden", :none)}
  end

  def frame_request(conn, _ctx) do
    conn =
      conn
      |> put_req_header("sec-fetch-dest", "iframe")
      |> mcp_call("system", %{"action" => "status"})

    assert json_response(conn, 403)
    {request_id_of(conn), refused("forbidden", :none)}
  end

  def mcp_rate_limited(conn, _ctx) do
    Cyfr.Test.Settings.put("mcp_rate_limit_max", 1)
    Cyfr.Test.Settings.put("mcp_rate_limit_window_ms", 60_000)
    Prima.Test.RateLimiter.reset!()

    first = mcp_call(conn, "system", %{"action" => "status"})
    assert first.status == 200

    second = conn |> recycle() |> mcp_call("system", %{"action" => "status"})
    assert json_response(second, 429)
    {request_id_of(second), refused("rate_limited", :none)}
  end

  def missing_protocol_header(conn, _ctx) do
    # `post/3` rather than `mcp_post/2`: no protocol version anywhere.
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "system", "arguments" => %{"action" => "status"}}
      })

    assert json_response(conn, 400)["error"]["code"] == -32_020
    {request_id_of(conn), refused("invalid_argument", :established)}
  end

  def slot_lost(conn, _ctx) do
    Arca.ControlPlane.record(:lost)
    conn = mcp_call(conn, "system", %{"action" => "status"})
    Arca.ControlPlane.record(:unclaimed)

    assert json_response(conn, 503)["code"] == "not_owner"
    {request_id_of(conn), refused("not_owner", :none)}
  end

  # ==========================================================================
  # Drivers: the tincture routes
  # ==========================================================================

  def tincture_index_unknown(conn, _ctx) do
    conn = get(conn, "/t/test/local/" <> unique("no-such-tincture"))
    assert conn.status == 404
    {request_id_of(conn), refused(api_class(conn), :none)}
  end

  # A data request with no frame credential and no public tincture: the
  # wire's own refusal, whose class the row carries.
  defp tincture_data_no_frame(conn, kind, fields, path \\ nil) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "null")
      |> post(path || Prima.TinctureWire.route(kind), Prima.TinctureWire.request(kind, fields))

    assert conn.status == 401

    assert {:refused, %{class: class, stage: "admission"}} =
             Prima.TinctureWire.decode_answer(kind, Jason.decode!(conn.resp_body))

    {request_id_of(conn), refused(class, :none)}
  end

  def tincture_data_invoke_no_frame(conn, _ctx),
    do: tincture_data_no_frame(conn, :invoke, %{ref: "c:local.echo", operation: "run", args: %{}})

  def tincture_data_action_no_frame(conn, _ctx),
    do: tincture_data_no_frame(conn, :action, %{operation: "system.status", args: %{}})

  def tincture_data_stream_no_frame(conn, _ctx),
    do: tincture_data_no_frame(conn, :stream_open, %{stream: "mcp_servers.changes", subject: nil})

  # A canvas's own data path, asked with no bearer.
  def tincture_data_canvas_no_frame(conn, _ctx) do
    tincture_data_no_frame(
      conn,
      :stream_open,
      %{stream: "mcp_servers.changes", subject: nil},
      Prima.CanvasWire.stream_path("frm_seam_" <> unique("canvas"))
    )
  end

  def tincture_rate_limited(conn, _ctx) do
    Application.put_env(:cyfr, :tincture_rate_limit_max, 1)
    Prima.Test.RateLimiter.reset!()
    path = "/t/test/local/" <> unique("no-such-tincture")

    _first = get(conn, path)
    second = conn |> recycle() |> get(path)
    assert second.status == 429
    {request_id_of(second), refused("rate_limited", :none)}
  end

  # ==========================================================================
  # Drivers: the webhook route
  # ==========================================================================

  defp hook!(ctx, opts) do
    comp = unique("seam-target")
    Sanctum.Test.ComponentHelpers.register_test_component(comp, "1.0.0", "formula", %{}, ctx)
    profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "f:local.#{comp}")

    {:ok, hook} =
      Sanctum.TestContext.create_webhook(
        ctx,
        Map.merge(
          %{name: unique("seam"), target_ref: "f:local.#{comp}", profile_id: profile},
          opts
        )
      )

    hook
  end

  defp post_signed(conn, slug, secret, body) do
    sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-cyfr-signature", sig)
    |> post("/hooks/" <> slug, body)
  end

  def webhook_archived_athanor(conn, ctx) do
    n = System.unique_integer([:positive])
    {ctx, _creator} = Sanctum.TestContext.person!(ctx, %{email: "seam#{n}@example.com"})
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(ctx.user_id, "Seam #{n}")
    in_group = %{ctx | athanor_id: group.id}
    %{slug: slug, secret: secret} = hook!(in_group, %{replay_protection: "none"})

    {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)
    conn = post_signed(conn, slug, secret, ~s({}))
    {:ok, _} = Sanctum.Tenancy.Athanors.unarchive(group)

    assert conn.status == 404
    {request_id_of(conn), refused(api_class(conn), :none)}
  end

  def webhook_unsigned(conn, ctx) do
    %{slug: slug} = hook!(ctx, %{replay_protection: "none"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/hooks/" <> slug, ~s({}))

    assert conn.status == 401
    {request_id_of(conn), refused(api_class(conn), :none)}
  end

  def webhook_missing_idempotency_key(conn, ctx) do
    %{slug: slug, secret: secret} = hook!(ctx, %{idempotency_key_header: "idempotency-key"})
    conn = post_signed(conn, slug, secret, ~s({}))
    assert conn.status == 400
    {request_id_of(conn), refused(api_class(conn), :none)}
  end

  def webhook_rate_limited(conn, ctx) do
    Cyfr.Test.Settings.put("webhook_per_ip_rate_limit_max", 1)
    Prima.Test.RateLimiter.reset!()
    %{slug: slug, secret: secret} = hook!(ctx, %{replay_protection: "none"})

    _first = post_signed(conn, slug, secret, ~s({}))
    second = conn |> recycle() |> post_signed(slug, secret, ~s({}))
    assert second.status == 429
    {request_id_of(second), refused("rate_limited", :none)}
  end

  # ==========================================================================
  # Drivers: the entries that admit for themselves
  # ==========================================================================

  # This node serves no directory, so each of its routes refuses as
  # `not_served`; a malformed position is refused before the directory is
  # asked.
  defp directory_unserved(method, path) do
    Cyfr.Test.Settings.put("directory_serve", "off")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, method, path, "{}")

    assert json_response(conn, 404) == %{"error" => "not_served"}
    {request_id_of(conn), refused("not_found", :none)}
  end

  def directory_register_unserved(_conn, _ctx),
    do: directory_unserved(:post, "/directory/v1/genesis")

  def directory_append_unserved(_conn, _ctx),
    do: directory_unserved(:post, "/directory/v1/per_seam/entries")

  def directory_recover_unserved(_conn, _ctx),
    do: directory_unserved(:post, "/directory/v1/per_seam/recover")

  def directory_outcome_unserved(_conn, _ctx),
    do: directory_unserved(:get, "/directory/v1/per_seam/requests/req_seam")

  def directory_resolve_bad_position(_conn, _ctx) do
    conn = get(build_conn(), "/directory/v1/per_seam?after=x")
    assert %{"error" => "invalid", "field" => "after"} = json_response(conn, 422)
    {request_id_of(conn), refused("invalid_argument", :none)}
  end

  # This node configures no restore token, so the capability's routes
  # refuse as `restore_disabled`; the kit's routes need no token and refuse
  # what they were given.
  defp restore_post(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp restore_disabled_at(path) do
    conn = restore_post(path, %{})
    assert json_response(conn, 404) == %{"error" => "restore_disabled"}
    {request_id_of(conn), refused("not_found", :none)}
  end

  def restore_disabled(_conn, _ctx), do: restore_disabled_at("/restore")
  def restore_challenge_disabled(_conn, _ctx), do: restore_disabled_at("/restore/challenge")
  def restore_reproof_disabled(_conn, _ctx), do: restore_disabled_at("/restore/reproof")

  def restore_kit_challenge_not_recovering(_conn, _ctx) do
    conn = restore_post("/restore/kit/challenge", %{"identifier" => "per_seam"})
    assert json_response(conn, 404) == %{"error" => "not_recovering"}
    {request_id_of(conn), refused("not_found", :none)}
  end

  def restore_kit_invalid_proof(_conn, _ctx) do
    conn = restore_post("/restore/kit", %{"proof" => "not a proof"})
    assert json_response(conn, 422) == %{"error" => "invalid_proof"}
    {request_id_of(conn), refused("invalid_argument", :none)}
  end

  def restore_kit_reenable_unnamed(_conn, _ctx) do
    conn = restore_post("/restore/kit/reenable", %{})
    assert json_response(conn, 403) == %{"error" => "operation_not_permitted"}
    {request_id_of(conn), refused("forbidden", :none)}
  end

  # The restore routes' budget is ten requests a minute an address.
  def restore_rate_limited(_conn, _ctx) do
    Prima.Test.RateLimiter.reset!()
    for _ <- 1..10, do: assert(restore_post("/restore/kit", %{}).status == 422)

    conn = restore_post("/restore/kit", %{})
    assert conn.status == 429
    {request_id_of(conn), refused("rate_limited", :none)}
  end

  def oauth_callback_unknown_state(_conn, _ctx) do
    conn = get(build_conn(), "/auth/oauth/callback", %{"code" => "c", "state" => "no-such-state"})
    assert conn.status == 400
    assert conn.resp_body =~ "invalid or expired state parameter"
    {request_id_of(conn), refused("not_found", :none)}
  end

  # The browser's sign-in, re-authentication and policy acceptance: each
  # refused before any person's context exists.
  defp sign_in_refused(conn, status, class) do
    assert conn.status == status
    {request_id_of(conn), refused(class, :none)}
  end

  def sign_in_link_unsigned(_conn, _ctx),
    do: build_conn() |> post("/auth/link/oidcc", %{}) |> sign_in_refused(302, "unauthenticated")

  def sign_in_cyfr_hop_expired(_conn, _ctx),
    do: build_conn() |> get("/auth/cyfr") |> sign_in_refused(302, "not_found")

  def sign_in_device_ticket_unknown(_conn, _ctx),
    do: build_conn() |> get("/auth/device/complete/nope") |> sign_in_refused(302, "not_found")

  def sign_in_cyfr_callback_expired(_conn, _ctx),
    do: build_conn() |> post("/auth/cyfr/callback", %{}) |> sign_in_refused(302, "not_found")

  def sign_in_callback_empty(_conn, _ctx),
    do:
      build_conn()
      |> get("/auth/nobody/callback")
      |> sign_in_refused(400, "invalid_argument")

  def sign_in_post_legal_no_probe(_conn, _ctx),
    do: build_conn() |> get("/auth/post-legal-accept") |> sign_in_refused(302, "not_found")

  def sign_in_passkey_ticket_unknown(_conn, _ctx),
    do: build_conn() |> get("/auth/passkey/complete/nope") |> sign_in_refused(302, "not_found")

  def reauth_callback_unstated(_conn, _ctx),
    do: build_conn() |> get("/auth/oidcc/reauth") |> sign_in_refused(401, "unauthenticated")

  def reauth_decide_no_ticket(_conn, _ctx),
    do: build_conn() |> post("/auth/oidcc/reauth", %{}) |> sign_in_refused(409, "conflict")

  # The registry at an address nothing answers on: its policies cannot be
  # read.
  def legal_show_registry_unreachable(_conn, _ctx) do
    original = Application.get_env(:cyfr, :registry_url)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :registry_url, original),
        else: Application.delete_env(:cyfr, :registry_url)
    end)

    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")
    build_conn() |> get("/legal/accept") |> sign_in_refused(502, "unavailable")
  end

  def legal_submit_no_version(_conn, _ctx),
    do:
      build_conn()
      |> post("/legal/accept/submit", %{})
      |> sign_in_refused(400, "invalid_argument")

  # ==========================================================================
  # Drivers: the execution-events stream
  # ==========================================================================

  def execution_events_unknown(conn, _ctx) do
    conn = get(conn, "/api/executions/exec_nope/events")
    assert conn.status == 404
    {request_id_of(conn), refused(api_class(conn), :established)}
  end

  # ==========================================================================
  # Drivers: the scheduler and the HostAPI
  # ==========================================================================

  def schedule_fire_refused(_conn, ctx) do
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)
    reference = "reagent:local.#{unique("seam-missing")}:1.0.0"

    {:ok, _schedule} =
      Arca.CronSchedule.create(Sanctum.Context.actor(ctx), %{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: unique("seam-schedule"),
        cron_expression: "0 * * * *",
        reference: reference,
        resolved_reference: reference,
        profile_id: "prof_seam",
        next_run_at: DateTime.add(DateTime.utc_now(), -5, :second),
        cap: 1_000
      })

    start_supervised!(Opus.Schedules.Scheduler)

    # The sandbox holds this run's rows alone, so the fire's decision is
    # the one "schedule" decision there is.
    where = {:tool, "schedule"}
    wait_until(fn -> match?([%{completion: "failed"}], decisions(where)) end)

    # The fire's own admission is the claimed occurrence; the run's
    # admission refusal is its failed completion.
    {where, %{admission: "admitted", completion: "failed", caller: :established}}
  end

  def host_api_lost_attempt(_conn, ctx) do
    tool = unique("seam-tool")

    caller = %{
      athanor_id: ctx.athanor_id,
      execution_id: Prima.UUID7.execution_id(),
      attempt: "att_" <> unique("seam"),
      fence: 1,
      generation: 1,
      service: "wrk_locus",
      boot: "boot_seam",
      runner: "runner_seam",
      member: "member_seam",
      ts: System.system_time(:second)
    }

    assert {:error, reason} =
             Opus.Host.Children.call(
               caller,
               {:tool_call, %{name: tool, args: %{}, guest_fn: :call}}
             )

    assert reason in [:lost, :unavailable]

    class = Atom.to_string(Sanctum.Refusals.classify(reason).class)
    {{:tool, tool}, refused(class, :none)}
  end

  # ==========================================================================
  # Drivers: the device channel
  # ==========================================================================

  # A glass connects under a certificate, is challenged, and proves its key;
  # the verifier refuses the proof, and the refusal is the decision under
  # the call id the channel assigned the proof. The transport still
  # delivers what arrives before the peer's close: the connect's deadline
  # and more frames record nothing, so the connection, counted by its
  # request id, holds that one decision.
  def device_channel_unproven(_conn, _ctx) do
    {device_key, device_private} = :crypto.generate_key(:eddsa, :ed25519)
    {_live_key, live_private} = :crypto.generate_key(:eddsa, :ed25519)
    home = Sanctum.origin()
    now = System.system_time(:millisecond)
    client_id = Prima.UUID7.generate_id("pcl")

    {:ok, cert} =
      Prima.DeviceCert.new(
        device_key: device_key,
        client_id: client_id,
        subject: %{kind: :local, user_id: Prima.UUID7.generate_id("usr")},
        issuer: home,
        audience: home,
        athanor: Prima.UUID7.generate_id("ath"),
        not_before: now,
        expires_at: now + 3_600_000
      )

    connect =
      {:connect, %{client_id: client_id, certificate: Prima.DeviceCert.sign(cert, live_private)}}

    {:ok, state} =
      DeviceChannel.connect(%{
        endpoint: CyfrWeb.Endpoint,
        transport: :websocket,
        options: [],
        params: %{},
        connect_info: %{peer_data: %{address: {127, 0, 0, 1}, port: 50_000, ssl_cert: nil}}
      })

    {:ok, state} = DeviceChannel.init(state)

    {:reply, :ok, {:text, json}, state} =
      DeviceChannel.handle_in({device_frame(connect), [opcode: :text]}, state)

    {:ok, {:challenge, %{challenge: challenge}}} =
      Prima.Device.decode(Jason.decode!(json), :home)

    proof = {:proof, %{proof: Prima.DeviceCert.Proof.sign(challenge, device_private)}}
    {deadline, _timer} = state.deadline

    assert {:stop, :normal, {4401, "unauthenticated"}, closed} =
             DeviceChannel.handle_in({device_frame(proof), [opcode: :text]}, state)

    after_close = [
      fn -> DeviceChannel.handle_info({DeviceChannel, :deadline, deadline}, closed) end,
      fn -> DeviceChannel.handle_in({device_frame(proof), [opcode: :text]}, closed) end,
      fn -> DeviceChannel.handle_in({"{}", [opcode: :text]}, closed) end
    ]

    # Whatever arrives after the close stops the connection and records
    # nothing.
    for delivered <- after_close,
        do: assert(delivered.() == {:stop, {:shutdown, :closed}, closed})

    where = {:request, closed.ctx.request_id}
    assert [%{call_id: call_id}] = decisions(where)
    assert call_id == closed.call_id

    {where, refused("unauthenticated", :none)}
  end

  defp device_frame(message), do: message |> Prima.Device.encode() |> Jason.encode!()
end
