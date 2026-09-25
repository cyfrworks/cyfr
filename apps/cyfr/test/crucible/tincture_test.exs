# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.TinctureTest do
  @moduledoc """
  `Crucible.invoke_tincture/3`: a tincture invoking one of its
  dependencies, rooted at the profile its route selects.

  The route decides the profile and nothing else does: a public profile
  never roots the protected route, and the public route needs the
  tincture's active public profile at its public address, whoever asks —
  the caller's own athanor is not consulted, and a tincture with only an
  owner profile is not there for it. The tincture and its profile are read
  on every call, so a profile revoked since a surface cached the tincture
  refuses, and so does a tincture that is gone. A guest-planed context
  refuses. Every refusal is a typed `%Prima.Refusal{}`.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @dep "reagent:local.tinc-dep"
  @dep_ref "reagent:local.tinc-dep:0.1.0"
  # `Sanctum.TestContext.athanor!/0`'s group slug.
  @address "test"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    base = Path.join(System.tmp_dir!(), "tincture_#{System.unique_integer([:positive])}")
    keys = [cyfr: :opus_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, base)

    ctx = Sanctum.TestContext.local()
    _athanor = Sanctum.TestContext.athanor!()

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)
      File.rm_rf!(base)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    {:ok, dep} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "tinc-dep",
        version: "0.1.0",
        type: "reagent"
      })

    {:ok, ctx: ctx, dep: dep}
  end

  # A registered tincture that declares the dependency; its profiles are
  # each test's own.
  defp tincture!(ctx, name) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"},
      "dependencies" => %{"static" => [%{"ref" => @dep, "reason" => "test"}]}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    "tincture:local.#{name}"
  end

  # A profile of `kind` for the tincture `node`, with a head consent that
  # binds its edge to the dependency.
  defp profile!(ctx, node, kind, status \\ :active) do
    id = "prof_#{kind}_#{System.unique_integer([:positive])}"
    {:ok, _ref, _type, component} = Crucible.Admission.inspect_component(ctx, node)
    {:ok, %{graph: activation}} = Compendium.Activation.resolve_verified(ctx, component)

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: id, kind: kind, source_ref: node, label: to_string(kind), status: status},
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
                node => %{
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

  # The gate's cast arguments for `route`: the public action also names the
  # tincture's public address, the fixture athanor's slug.
  defp args(name, route) do
    base = %{
      "publisher" => "local",
      "tincture_name" => name,
      "reference" => @dep_ref,
      "input" => %{"x" => 1}
    }

    if route == :public, do: Map.put(base, "athanor", @address), else: base
  end

  # A worker service that answers: without one every invocation refuses
  # as the engine not ready, before any profile is read.
  defp worker!(script \\ []),
    do: start_supervised!({ScriptedWorker, ref: @dep_ref, script: script})

  describe "the route selects the profile" do
    test "the protected route runs under the owner profile", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-owner")
      _owner = profile!(ctx, node, :owner)
      worker!([%{"answer" => 42}])
      ScriptedWorker.fresh_limits!(ctx, [@dep_ref])

      assert {:ok, result} =
               Crucible.invoke_tincture(ctx, args("tinc-owner", :protected), :protected)

      assert result.status == :completed
      assert is_binary(result.execution_id)
      assert is_integer(result.duration_ms)
      assert [%{execution_id: execution_id}] = ScriptedWorker.calls()
      assert execution_id == result.execution_id
    end

    test "a public profile never roots the protected route", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-pub-only")
      _public = profile!(ctx, node, :public)
      worker!()

      assert {:error, %Prima.Refusal{class: :consent_required, reason: :no_profile} = refusal} =
               Crucible.invoke_tincture(ctx, args("tinc-pub-only", :protected), :protected)

      assert refusal.message == Prima.Refusal.message(:consent_required)
      assert ScriptedWorker.calls() == []
    end

    test "an owner profile is not there for the public route, whoever asks", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-owner-only")
      _owner = profile!(ctx, node, :owner)
      worker!()

      # Indistinguishable from a tincture that does not exist, even for an
      # authenticated member of its athanor.
      assert ctx.authenticated

      assert {:error, %Prima.Refusal{class: :not_found}} =
               Crucible.invoke_tincture(ctx, args("tinc-owner-only", :public), :public)

      assert ScriptedWorker.calls() == []
    end
  end

  describe "the public route is the tincture's public address" do
    test "it runs under the address's public profile for a caller of no athanor",
         %{ctx: ctx} do
      node = tincture!(ctx, "tinc-public")
      _public = profile!(ctx, node, :public)
      worker!([%{"answer" => 7}])
      ScriptedWorker.fresh_limits!(ctx, [@dep_ref])
      anonymous = Sanctum.Context.build(authenticated: false, client_ip: "198.51.100.7")
      assert anonymous.athanor_id == nil

      assert {:ok, %{status: :completed}} =
               Crucible.invoke_tincture(anonymous, args("tinc-public", :public), :public)

      # The run is the public identity's, in the tincture's own athanor.
      assert [%{authority: authority}] = ScriptedWorker.calls()
      assert authority.profile_kind == :public
    end

    test "the caller's own athanor is not consulted", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-elsewhere")
      _public = profile!(ctx, node, :public)
      worker!()

      # An address naming no athanor is not found, whatever the caller's.
      assert {:error, %Prima.Refusal{class: :not_found}} =
               Crucible.invoke_tincture(
                 ctx,
                 Map.put(args("tinc-elsewhere", :public), "athanor", "no-such-athanor"),
                 :public
               )

      assert ScriptedWorker.calls() == []
    end
  end

  describe "a member of one athanor at another's public address" do
    setup do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:cyfr, :crucible, :tincture, :invoke, :start],
        fn _event, _measurements, meta, _ -> send(test, {ref, :start, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      {:ok, ref: ref}
    end

    test "runs as that address's public identity, never as themself", %{ctx: ctx, ref: ref} do
      {:ok, other} =
        Sanctum.Tenancy.Athanors.create(%{
          id: "ath_tinc_other",
          kind: "group",
          name: "Other",
          slug: "tinc-other",
          created_by: "system"
        })

      owner_b = %{ctx | athanor_id: other.id}

      {:ok, _dep} =
        Compendium.Registry.publish_bytes(owner_b, File.read!(@math_wasm_path), %{
          name: "tinc-dep",
          version: "0.1.0",
          type: "reagent"
        })

      node = tincture!(owner_b, "tinc-across")
      _public = profile!(owner_b, node, :public)
      worker!([%{"answer" => 3}])
      ScriptedWorker.fresh_limits!(owner_b, [@dep_ref])

      # The caller is an authenticated member of the fixture athanor; the
      # address names the other one.
      assert ctx.authenticated and ctx.athanor_id != other.id

      # The context the run is rooted under is read where the run receives
      # it: this process's own call into the root admission, traced to a
      # collector (a process's call trace is not delivered to itself).
      test = self()

      collector =
        spawn_link(fn ->
          receive do
            {:trace, _pid, :call, call} -> send(test, {:rooted, call})
          end
        end)

      :erlang.trace_pattern({Crucible, :run_root_edge, 5}, true, [:global])
      on_exit(fn -> :erlang.trace_pattern({Crucible, :run_root_edge, 5}, false, [:global]) end)
      :erlang.trace(self(), true, [:call, {:tracer, collector}])

      result =
        Crucible.invoke_tincture(
          ctx,
          Map.put(args("tinc-across", :public), "athanor", other.slug),
          :public
        )

      :erlang.trace(self(), false, [:call])
      assert {:ok, %{status: :completed}} = result

      assert_receive {:rooted, {Crucible, :run_root_edge, [run_ctx | _rest]}}

      # The run is the address's public identity: anonymous, holding
      # `[:execute]` and nothing else, the tincture's own id as its user, in
      # the address's athanor — never the caller's own standing.
      assert run_ctx.anonymous
      assert run_ctx.permissions == MapSet.new([:execute])
      assert run_ctx.athanor_id == other.id
      assert run_ctx.user_id == node
      refute run_ctx.user_id == ctx.user_id

      assert_receive {^ref, :start, start}
      assert start.athanor_id == other.id
      assert start.user_id == run_ctx.user_id

      assert [%{authority: authority}] = ScriptedWorker.calls()
      assert authority.profile_kind == :public
    end
  end

  describe "the tincture and its profile are read on every call" do
    test "a profile revoked since the tincture was read refuses as unconsented", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-stale")
      _owner = profile!(ctx, node, :owner, :revoked)
      worker!()

      assert {:error, %Prima.Refusal{class: :consent_required}} =
               Crucible.invoke_tincture(ctx, args("tinc-stale", :protected), :protected)

      assert ScriptedWorker.calls() == []
    end

    test "a profile that needs consent again refuses as unconsented, keeping its reason",
         %{ctx: ctx} do
      node = tincture!(ctx, "tinc-reconsent")
      _owner = profile!(ctx, node, :owner, :needs_consent)
      worker!()

      assert {:error,
              %Prima.Refusal{
                class: :consent_required,
                reason: {:profile_unavailable, :needs_consent}
              }} = Crucible.invoke_tincture(ctx, args("tinc-reconsent", :protected), :protected)

      assert ScriptedWorker.calls() == []
    end

    test "a public profile revoked since the page was served is not found", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-unpublished")
      _public = profile!(ctx, node, :public, :revoked)
      worker!()

      assert {:error, %Prima.Refusal{class: :not_found}} =
               Crucible.invoke_tincture(ctx, args("tinc-unpublished", :public), :public)
    end

    test "a tincture that is gone is not found on either route", %{ctx: ctx} do
      worker!()

      for route <- [:public, :protected] do
        assert {:error, %Prima.Refusal{class: :not_found}} =
                 Crucible.invoke_tincture(ctx, args("tinc-missing", route), route)
      end
    end
  end

  describe "refusals" do
    test "a guest-planed context refuses on either route, before anything is read",
         %{ctx: ctx} do
      guest = %{ctx | plane: :guest}

      for route <- [:public, :protected] do
        assert {:error,
                %Prima.Refusal{class: :forbidden, reason: {:guest_plane_call, "tincture"}}} =
                 Crucible.invoke_tincture(guest, args("tinc-any", route), route)
      end
    end

    test "an empty reference is the caller's argument refused, before anything runs",
         %{ctx: ctx} do
      node = tincture!(ctx, "tinc-empty-ref")
      _owner = profile!(ctx, node, :owner)
      worker!()

      # The gate's cast admits any string for a required string argument;
      # admission's reference grammar refuses the empty one.
      assert {:error,
              %Prima.Refusal{class: :invalid_argument, reason: {:invalid_reference, _}} =
                refusal} =
               Crucible.invoke_tincture(
                 ctx,
                 Map.put(args("tinc-empty-ref", :protected), "reference", ""),
                 :protected
               )

      assert refusal.message =~ "Invalid reference"
      assert ScriptedWorker.calls() == []
    end

    test "with no worker service answering, the engine is not ready", %{ctx: ctx} do
      node = tincture!(ctx, "tinc-no-engine")
      _owner = profile!(ctx, node, :owner)
      Application.put_env(:cyfr, :opus_workers, [])

      assert {:error, %Prima.Refusal{class: :unavailable, reason: :engine_starting}} =
               Crucible.invoke_tincture(ctx, args("tinc-no-engine", :protected), :protected)
    end
  end

  describe "telemetry" do
    setup do
      ref = make_ref()
      test = self()

      :telemetry.attach_many(
        {__MODULE__, ref},
        [
          [:cyfr, :crucible, :tincture, :invoke, :start],
          [:cyfr, :crucible, :tincture, :invoke, :stop]
        ],
        fn event, measurements, meta, _ -> send(test, {ref, event, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      {:ok, ref: ref}
    end

    test "an invocation is one start and one stop, a refusal carried as its class",
         %{ctx: ctx, ref: ref} do
      node = tincture!(ctx, "tinc-telemetry")
      _public = profile!(ctx, node, :public)
      worker!()

      assert {:error, %Prima.Refusal{class: :consent_required}} =
               Crucible.invoke_tincture(ctx, args("tinc-telemetry", :protected), :protected)

      assert_receive {^ref, [:cyfr, :crucible, :tincture, :invoke, :start], _, start}
      assert start.tincture_ref == node
      assert start.reference == @dep_ref
      assert start.athanor_id == ctx.athanor_id

      assert_receive {^ref, [:cyfr, :crucible, :tincture, :invoke, :stop], %{duration_ms: ms},
                      stop}

      assert is_integer(ms)
      assert stop.status == :error
      assert %Prima.Refusal{class: :consent_required} = stop.error
      refute_receive {^ref, _, _, _}
    end
  end
end
