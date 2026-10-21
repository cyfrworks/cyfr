# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.FrameGrantOriginTest do
  @moduledoc """
  A grant made through the consent walk that admits only the schedule
  origin opens no interactive frame, and a frame's data request under it
  is refused for want of a grant that admits the frame path's origin.
  """

  use CyfrWeb.ConnCase, async: false

  alias Sanctum.Consent.{Commit, Components, Loader, Plan, ShapeDerivation}

  @name "schedule-only"
  @ref "tincture:local.schedule-only"
  @version "1.0.0"

  setup do
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.RateLimiter.reset!()

    _athanor = Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)
    source = %{source | origin: :interactive}

    manifest = %{
      "name" => @name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "actions" => ["system.status"]}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, @name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(source), %{
        id: "cmp_schedule_only_#{System.unique_integer([:positive])}",
        name: @name,
        version: @version,
        component_type: "tincture",
        description: @name,
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

    # Use the consent producer, rather than hand-writing an invalid head.
    decisions = %{ref: @ref, origins: [:schedule]}
    assert {:ok, plan} = Plan.plan(source, %{ref: @ref})
    assert {:ok, preview} = Commit.preview(source, decisions)

    assert {:ok, committed} =
             Commit.commit(source, %{
               decisions: decisions,
               plan_token: plan.plan_token,
               proof: preview.proof,
               commit_digest: preview.commit_digest,
               expected_consent_revision: plan.expected_consent_revision
             })

    {:ok, [profile]} = Sanctum.Consent.profiles(source, @ref)
    {:ok, consent} = Sanctum.Consent.head_consent(source, profile.id)
    assert consent.admitted_origins == [:schedule]

    # Control: the root loader rejects this exact grant on the interactive
    # path, before constructing authority.
    {:ok, row} = Components.get_component(source, @name, @version, "local", "tincture")
    live = Components.resolve_verified(source, row)
    {:ok, shape} = ShapeDerivation.version_digest(source, @ref, @version)

    assert {:error, {:consent_required, _}} =
             Loader.load_root(source, profile, live: live, live_shape_digest: shape)

    {:ok,
     source: source, manifest: manifest, digest: release_digest, revision: committed.revision}
  end

  test "a schedule-only grant refuses an interactive frame open", %{
    source: source,
    manifest: manifest
  } do
    card = %{
      id: "iframe_schedule_only",
      publisher: "local",
      name: @name,
      version: @version,
      entry: "index.html",
      athanor_segment: "home",
      public: false,
      manifest: manifest
    }

    frames = Prism.Frames.launch(source, Prism.Frames.new(), card)
    frame = Prism.Frames.get(frames, {:full, card.id})
    assert %{state: :refused, refusal: :ungranted} = frame
  end

  test "a frame's action cannot use a schedule-only grant", %{
    source: source,
    digest: digest,
    revision: revision
  } do
    reference = %{publisher: "local", name: @name, version: @version}

    {:ok, %{credential: bearer}} =
      Sanctum.TinctureAuth.mint_frame_credential(
        source,
        reference,
        digest,
        revision,
        "frm_schedule_only_#{System.unique_integer([:positive])}"
      )

    body = Prima.TinctureWire.request(:action, %{operation: "system.status", args: %{}})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "null")
      |> put_req_header("authorization", Prima.TinctureWire.bearer(bearer))
      |> post(Prima.TinctureWire.route(:action), Jason.encode!(body))

    assert conn.status >= 400,
           "interactive data request under a schedule-only grant answered #{conn.status}: " <>
             conn.resp_body

    assert {:refused, %{class: "consent_required"}} =
             Prima.TinctureWire.decode_answer(:action, Jason.decode!(conn.resp_body))
  end
end
