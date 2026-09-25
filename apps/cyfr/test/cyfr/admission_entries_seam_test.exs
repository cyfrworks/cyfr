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
  a due schedule whose run admission fails.
  """

  # Flips rate limits, ownership standing and scheduler configuration.
  use EmissaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Cyfr.Boundaries

  @mcp_unknown_tool_class "not_found"

  setup do
    Prima.RateLimiter.reset()

    keys = [
      cyfr: :mcp_rate_limit_max,
      cyfr: :mcp_rate_limit_window_ms,
      cyfr: :tincture_rate_limit_max,
      cyfr: :webhook_per_ip_rate_limit_max,
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
      Prima.RateLimiter.reset()
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
    {Grimoire, :call_external} => :gate_external_head,
    {Grimoire, :call_in_chain} => :gate_in_chain_head,
    {Emissary.MCP.Router, :dispatch} => :router_unknown_tool,
    {EmissaryWeb.MCPController, :handle} => :mcp_batch,
    {EmissaryWeb.MCPController, :method_not_allowed} => :mcp_get,
    {EmissaryWeb.Plugs.Authenticate, :call} => :invalid_api_key,
    {EmissaryWeb.Plugs.MCPOrigin, :call} => :origin_rejected,
    {EmissaryWeb.Plugs.MCPRateLimit, :call} => :mcp_rate_limited,
    {EmissaryWeb.Plugs.MCPRequestMetadata, :call} => :missing_protocol_header,
    {EmissaryWeb.Plugs.ControlPlaneOwnership, :call} => :slot_lost,
    {EmissaryWeb.TinctureController, :index} => :tincture_index_unknown,
    {EmissaryWeb.TinctureController, :invoke} => :tincture_invoke_unknown,
    {EmissaryWeb.TinctureController, :access_token} => :tincture_mint_refused,
    {EmissaryWeb.Plugs.TinctureRateLimit, :call} => :tincture_rate_limited,
    {EmissaryWeb.WebhookController, :invoke} => :webhook_archived_athanor,
    {EmissaryWeb.Plugs.VerifyWebhookSignature, :call} => :webhook_unsigned,
    {EmissaryWeb.Plugs.WebhookIdempotency, :call} => :webhook_missing_idempotency_key,
    {EmissaryWeb.Plugs.WebhookRateLimit, :call} => :webhook_rate_limited,
    {Crucible.Schedules.Scheduler, :handle_info} => :schedule_fire_refused,
    {Crucible.Host.Children, :call} => :host_api_lost_attempt
  }

  test "every roster row has one driver and every driver a row" do
    roster = Enum.map(Boundaries.admission_entries(), &{&1.module, &1.site})
    assert Enum.sort(roster) == Enum.sort(Map.keys(@drivers))
  end

  for %{module: module, site: site, plane: plane} <- Boundaries.admission_entries() do
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
             Grimoire.call_external("system", guest, %{"action" => "status"})

    {{:request, request_id}, refused("forbidden", :established)}
  end

  def gate_in_chain_head(_conn, ctx) do
    request_id = Prima.UUID7.request_id()

    assert {:error, %Prima.Refusal{stage: :admission, class: :invalid_argument}} =
             Grimoire.call_in_chain(
               "system",
               %{ctx | request_id: request_id},
               "not an object",
               %Prima.Authority{},
               []
             )

    {{:request, request_id}, refused("invalid_argument", :established)}
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
        EmissaryWeb.Endpoint,
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

  def mcp_rate_limited(conn, _ctx) do
    Application.put_env(:cyfr, :mcp_rate_limit_max, 1)
    Application.put_env(:cyfr, :mcp_rate_limit_window_ms, 60_000)
    Prima.RateLimiter.reset()

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

  def tincture_invoke_unknown(conn, _ctx) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/t/test/local/" <> unique("no-such-tincture") <> "/invoke", %{"input" => %{}})

    assert conn.status == 404
    {request_id_of(conn), refused(api_class(conn), :none)}
  end

  def tincture_mint_refused(conn, _ctx) do
    # No credential that may mint, and no tincture named: refused either way.
    conn = get(conn, "/t/access-token")
    {request_id_of(conn), refused(api_class(conn), :none)}
  end

  def tincture_rate_limited(conn, _ctx) do
    Application.put_env(:cyfr, :tincture_rate_limit_max, 1)
    Prima.RateLimiter.reset()
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
      Sanctum.Webhook.create(
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
    Application.put_env(:cyfr, :webhook_per_ip_rate_limit_max, 1)
    Prima.RateLimiter.reset()
    %{slug: slug, secret: secret} = hook!(ctx, %{replay_protection: "none"})

    _first = post_signed(conn, slug, secret, ~s({}))
    second = conn |> recycle() |> post_signed(slug, secret, ~s({}))
    assert second.status == 429
    {request_id_of(second), refused("rate_limited", :none)}
  end

  # ==========================================================================
  # Drivers: the scheduler and the HostAPI
  # ==========================================================================

  def schedule_fire_refused(_conn, ctx) do
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)
    reference = "reagent:local.#{unique("seam-missing")}:1.0.0"

    {:ok, _schedule} =
      Arca.CronSchedule.create(%{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: unique("seam-schedule"),
        cron_expression: "0 * * * *",
        reference: reference,
        resolved_reference: reference,
        profile_id: "prof_seam",
        next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    start_supervised!(Crucible.Schedules.Scheduler)

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
      service: "opus",
      boot: "boot_seam",
      runner: "runner_seam",
      member: "member_seam",
      ts: System.system_time(:second)
    }

    assert {:error, reason} =
             Crucible.Host.Children.call(
               caller,
               {:tool_call, %{name: tool, args: %{}, guest_fn: :call}}
             )

    assert reason in [:lost, :unavailable]

    class = Atom.to_string(Grimoire.Error.classify(reason).class)
    {{:tool, tool}, refused(class, :none)}
  end
end
