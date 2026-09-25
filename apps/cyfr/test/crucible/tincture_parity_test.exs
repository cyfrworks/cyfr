# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.TinctureParityTest do
  @moduledoc """
  The two tincture surfaces a person reaches — the HTTP invoke route and
  the console shell's iframe bridge — are two adapters of one declared
  operation, so one fixture answers the same through both: the same result
  for a run, and the same class, sentence and status for a refusal. Each
  call is filed once, by the gate, under the action it named.

  The HTTP route is driven with the person's session as a bearer, on a
  tincture with no active public profile, so it takes the protected route
  the shell always takes. Neither adapter can present a guest-planed
  context, so the guest plane is asserted at the gate both call, with each
  adapter's rendering of its refusal.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @dep "reagent:local.parity-dep"
  @dep_ref "reagent:local.parity-dep:0.1.0"
  @name "parity-dash"
  @node "tincture:local.parity-dash"
  @window_id "iframe_parity-dash"

  setup %{conn: conn} do
    Arca.Cache.init()
    user = test_user()
    conn = log_in_user(conn, user)
    estate = seated_athanor()

    base = Path.join(System.tmp_dir!(), "tincture_parity_#{System.unique_integer([:positive])}")
    keys = [cyfr: :opus_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, base)

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        namespace: user.namespace,
        athanor_id: estate.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, estate.id)
      File.rm_rf(base)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      reload_registry()
    end)

    {:ok, _dep} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "parity-dep",
        version: "0.1.0",
        type: "reagent"
      })

    tincture!(ctx)

    {:ok,
     conn: conn,
     ctx: ctx,
     token: Plug.Conn.get_session(conn, PrismWeb.ConnCase.session_key()),
     segment: Sanctum.Tenancy.Athanors.route_slug(estate)}
  end

  # The tincture as the component store holds it (what the gate's handler
  # reads) and as the shell lists it (the registry's scan of the tree).
  defp tincture!(ctx) do
    manifest = %{
      "name" => @name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"},
      "dependencies" => %{"static" => [%{"ref" => @dep, "reason" => "parity"}]}
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", @name, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html><head></head><body>parity</body></html>")

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, @name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{@name}_#{System.unique_integer([:positive])}",
        name: @name,
        version: "1.0.0",
        component_type: "tincture",
        description: @name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|#{ctx.namespace}",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
  end

  # A profile of `kind` in `status`, with a head consent binding the
  # tincture's edge to its dependency.
  defp profile!(ctx, kind, status) do
    id = "prof_parity_#{kind}_#{System.unique_integer([:positive])}"
    {:ok, _ref, _type, component} = Crucible.Admission.inspect_component(ctx, @node)
    {:ok, %{graph: activation}} = Compendium.Activation.resolve_verified(ctx, component)

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: id, kind: kind, source_ref: @node, label: to_string(kind), status: status},
        %{
          id: "consent_#{id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: if(kind == :public, do: :edge_only, else: :open_inert),
          shape_digest: "sha256:shape-#{id}",
          commit_digest: "sha256:commit-#{id}",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                @node => %{
                  "limits" => AuthorityFixtures.limits_map(),
                  "edges" => %{"@ingress" => %{}, @dep => %{}}
                },
                @dep => %{"limits" => AuthorityFixtures.limits_map(), "edges" => %{}}
              }
            }),
          activation: activation,
          vault_refs: []
        }
      )

    id
  end

  defp worker!(script),
    do: start_supervised!({ScriptedWorker, ref: @dep_ref, script: script})

  # The HTTP route, with the person's session as the bearer: its status
  # and its decoded body.
  defp http_invoke(token, segment) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/t/#{segment}/local/#{@name}/invoke",
        Jason.encode!(%{reference: @dep_ref, input: %{"x" => 1}})
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  # The shell's bridge: the `cyfr:response` it pushes to the frame.
  defp iframe_invoke(view) do
    id = "req-#{System.unique_integer([:positive])}"

    render_hook(view, "iframe_message", %{
      "window_id" => @window_id,
      "message" => %{
        "type" => "cyfr:request",
        "action" => "invoke",
        "id" => id,
        "payload" => %{"reference" => @dep_ref, "input" => %{"x" => 1}}
      }
    })

    assert_push_event(view, "iframe_response:" <> @window_id, %{id: ^id} = response)
    response
  end

  defp shell!(conn) do
    {view, html} = mount_athanor(conn, "/tinctures")
    assert html =~ @name
    view
  end

  # The same refusal, answered the same through both: the class is the
  # iframe's code and the HTTP body's, the sentence is both messages, and
  # the HTTP status is the class's.
  defp assert_same_refusal({status, body}, %{error: iframe}, class) do
    assert iframe == %{code: Atom.to_string(class), message: body["message"]}
    assert body["code"] == Atom.to_string(class)
    assert status == EmissaryWeb.ApiError.status(class)
  end

  defp rows(ctx) do
    Arca.Repo.all(
      from(l in Arca.Schemas.McpLog,
        where: l.tool == "tincture" and l.athanor_id == ^ctx.athanor_id,
        order_by: l.timestamp
      )
    )
  end

  test "a run answers the same result through both, each filed once by the gate",
       %{conn: conn, ctx: ctx, token: token, segment: segment} do
    _owner = profile!(ctx, :owner, :active)
    worker!([%{"answer" => 42}, %{"answer" => 42}])
    ScriptedWorker.fresh_limits!(ctx, [@dep_ref])
    view = shell!(conn)

    {200, http} = http_invoke(token, segment)
    %{result: iframe} = iframe_invoke(view)
    iframe = iframe |> Jason.encode!() |> Jason.decode!()

    assert Map.take(http, ["status", "output"]) == Map.take(iframe, ["status", "output"])
    assert http["status"] == "completed"
    assert Enum.sort(Map.keys(http)) == Enum.sort(Map.keys(iframe))
    assert is_binary(http["execution_id"]) and is_binary(iframe["execution_id"])
    refute http["execution_id"] == iframe["execution_id"]

    # One row per call, the gate's, naming the action: nothing else logs.
    assert [first, second] = rows(ctx)

    for row <- [first, second] do
      assert row.action == "invoke_protected"
      assert row.method == "tools/call"
      assert row.status == "success"
    end

    refute first.request_id == second.request_id
  end

  test "a public profile through the protected route refuses the same through both",
       %{conn: conn, ctx: ctx, token: token, segment: segment} do
    # The tincture's only profile is a public one that is not active, so
    # the HTTP route falls back to the protected route the shell takes.
    _public = profile!(ctx, :public, :needs_consent)
    worker!([])
    view = shell!(conn)

    assert_same_refusal(http_invoke(token, segment), iframe_invoke(view), :consent_required)
    assert ScriptedWorker.calls() == []
  end

  test "a profile gone stale since the shell listed the tincture refuses the same through both",
       %{conn: conn, ctx: ctx, token: token, segment: segment} do
    owner = profile!(ctx, :owner, :active)
    worker!([])
    view = shell!(conn)

    # Revoked after the card was cached: the gate's handler reads again.
    assert {:ok, %{revoked: [^owner]}} = Sanctum.Consent.revoke_source(ctx, @node)

    assert_same_refusal(http_invoke(token, segment), iframe_invoke(view), :consent_required)
    assert ScriptedWorker.calls() == []
  end

  test "a guest-planed context is refused both actions, rendered the same by both adapters",
       %{ctx: ctx, segment: segment} do
    guest = %{ctx | plane: :guest}

    for {action, address} <- [
          {"invoke_public", %{"athanor" => segment}},
          {"invoke_protected", %{}}
        ] do
      arguments =
        Map.merge(address, %{
          "action" => action,
          "publisher" => "local",
          "tincture_name" => @name,
          "reference" => @dep_ref,
          "input" => %{}
        })

      assert {:error, %Prima.Refusal{class: :forbidden, stage: :admission} = refusal} =
               Grimoire.call_external("tincture", guest, arguments)

      http = EmissaryWeb.ApiError.refuse(build_conn(), refusal)

      assert_same_refusal(
        {http.status, Jason.decode!(http.resp_body)},
        PrismWeb.ShellLive.iframe_refusal("req", refusal),
        :forbidden
      )
    end

    # The gate refuses a guest-planed context at its entry, before its
    # request log opens: neither call files a row, refused or otherwise.
    assert rows(ctx) == []
  end

  # The registry is one server-wide process, left holding the real
  # components root. Its reload runs on a checkout lent to it alone.
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
end
