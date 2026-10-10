# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What the canvas proof puts in its running server beyond the release
# fixture's shared commands (tests/release-boot/fixture.exs), evaluated
# inside it by `bin/cyfr rpc` (tests/canvas-proof/run.sh). The file
# evaluates to a function of the argument list; each command prints nothing
# and answers one line, `CANVAS=` and a JSON object. Every command takes
# the session token of the fixture's person and acts in the athanor that
# session is focused on.
#
# Everything the person does goes through the release fixture's `console`
# command, the console's own path through the gate: writing a canvas
# (`canvas.write`) is that. The rest stands in for what a person cannot
# do from a browser and a run would otherwise do, and starts no execution:
#
#   source TOKEN NAME
#       The feed source `catalyst:local.NAME` at 1.0.0, published through
#       `Compendium.Registry.publish_bytes/4` as an empty core wasm module,
#       which registration takes and no run can execute (`Locus.Runtime.Engine`
#       refuses a core module). Its manifest's `results` declares the
#       shape of each operation's data: `quote`, a symbol's price and its
#       candles. Beside it, its owner profile, active, whose head consent
#       admits the `interactive` and `schedule` origins, minted through
#       Arca's one profile mint as a person's grant leaves one; a feed fires
#       under `schedule`. Answers the reference and the profile id.
#
#   write TOKEN CANVAS MODULE STREAMS_JSON
#       A new version of the canvas CANVAS written with `canvas.write`,
#       through `console`: its module the source MODULE names (below), and
#       STREAMS_JSON the streams it reads. Answers the console's answer.
#
#   accept TOKEN BINDING DATA_JSON
#       A fixed result accepted for the feed BINDING through the accept
#       path a fire takes once its run answered: the member slot read, the
#       feed's next seq claimed (`Arca.CronSchedule.claim_feed_seq/2`), the
#       envelope `{"status": 200, "data": DATA}` accepted under both
#       (`Opus.Feeds.accept/5`), and the envelope the committed accept
#       answered published on the athanor's feeds topic. No run executes:
#       the result is DATA as given. Answers the accepted revision and its
#       time, never the result.
#
#   state TOKEN BINDING
#       The feed BINDING's row as `Arca.CronSchedule` reads it: its binding
#       id, whether it is live, its claimed and accepted seqs, the runs and
#       errors its fires recorded, and its `next_run_at`, the cursor the
#       scheduler's claim of a fire advances, with the seconds until it is
#       due against the current UTC time.
#
#   bearer TOKEN REFERENCE
#       A real frame credential of another open, minted for the installed
#       tincture REFERENCE's version through the one production mint
#       (`Sanctum.TinctureAuth.mint_frame_credential/5`), on a frame id of
#       its own. The `exits` probe receives this bearer to post with it on
#       the probe's own route, which refuses it `frame_path_mismatch`
#       before any authority is read, since its frame id is not the path's.
#       Answers the bearer and its frame id; the proof keeps neither in the
#       record (the failure case "the probe's received bearer").
#
#   failed_fire TOKEN BINDING
#       The scheduler's own failed fire leaves a claim the fixture made
#       acceptable. BINDING is a feed bound at an interval of one minute
#       for this alone. The fixture claims a seq `s` under the member slot,
#       then waits, at most 150 seconds, until the scheduler's own fire at
#       a due minute has claimed a later seq and every fire's occurrence
#       has ended, both read through `Arca.CronSchedule`; the feed's
#       accepted seq must not have moved. It then accepts a fixed result
#       under `s` and the slot it read, which must answer an accepted
#       envelope. Answers the seqs, the fire's recorded outcome and the
#       accepted revision.
#
# The modules a written canvas runs (`write`'s MODULE), each answering
# trees through the toolkit's module API and nothing else:
#
#   markets   the feed `candles` drawn as a candle chart, and its two
#             actions, `buy` and `refresh`, as controls that look alike;
#   labels    the same two controls, and, when the proof asks its worker
#             (`self.__canvasLabels.forge()`), a binding record of its own
#             posted to the toolkit, labelling `buy` as "Refresh"
#             (`bound()` says whether it holds the binding to forge for);
#   measure   one line of text: it reads no stream and attempts nothing;
#   broken    tinctures/canvas-broken/canvas.js, whose failure its version's
#             declared stream chooses.
#
# A step that does not answer `{:ok, _}` raises, and the rpc exits non-zero
# naming it.

fn args ->
  answer = fn map -> "CANVAS=" <> Jason.encode!(map) end

  establish = fn token ->
    {:ok, ctx} = Sanctum.Caller.establish({:session, token})
    ctx
  end

  # The release fixture's `console`: the one definition of a console call.
  console = fn token, tool, arguments ->
    release = Path.expand("../release-boot/fixture.exs", __DIR__)
    {release_fixture, _} = Code.eval_file(release)
    "FIXTURE=" <> json = release_fixture.(["console", token, tool, Jason.encode!(arguments)])
    Jason.decode!(json)
  end

  candle_shape = %{
    "type" => "object",
    "fields" => %{
      "symbol" => %{"type" => "string", "max" => 16},
      "price" => %{"type" => "number"},
      "change" => %{"type" => "number", "nullable" => true},
      "at" => %{"type" => "time"},
      "candles" => %{
        "type" => "list",
        "max" => 500,
        "of" => %{
          "type" => "object",
          "fields" => %{
            "t" => %{"type" => "time"},
            "o" => %{"type" => "number"},
            "h" => %{"type" => "number"},
            "l" => %{"type" => "number"},
            "c" => %{"type" => "number"}
          },
          "required" => ["t", "o", "h", "l", "c"]
        }
      }
    },
    "required" => ["symbol", "price", "at"]
  }

  modules = %{
    "markets" => ~S"""
    // A written canvas: the feed `candles` drawn by the chart element, and
    // the feed's two actions as controls of one tone and size, each labelled
    // by the toolkit from the binding.
    export default function markets(canvas) {
      let envelope = null
      const draw = () => canvas.render(tree(envelope))
      canvas.stream("feed.results", "candles", (event) => {
        const data = event && event.data
        if (data && data.feed === "candles") {
          envelope = data
          draw()
        }
      }).catch(() => {})
      draw()
    }

    function tree(envelope) {
      const result = envelope && envelope.result
      const candles = result && Array.isArray(result.candles) ? result.candles : []
      const seen = envelope
        ? "revision " + envelope.revision + (envelope.refresh === true ? " (refresh)" : "")
        : "no result yet"
      return {
        type: "stack",
        direction: "column",
        gap: "m",
        children: [
          {type: "text", value: "markets", size: "l", weight: "strong"},
          {type: "text", value: seen, tone: "muted"},
          candles.length > 0
            ? {
                type: "chart",
                kind: "candle",
                series: [
                  {
                    name: result.symbol || "candles",
                    points: candles.map((c) => ({t: c.t, o: c.o, h: c.h, l: c.l, c: c.c}))
                  }
                ]
              }
            : {type: "text", value: "no candles yet", tone: "muted"},
          {
            type: "stack",
            direction: "row",
            gap: "s",
            children: [
              {type: "control", effect: {press: {feed: "candles", action: "buy"}}},
              {type: "control", effect: {press: {feed: "candles", action: "refresh"}}}
            ]
          }
        ]
      }
    }
    """,
    "labels" => ~S"""
    // A written canvas that draws the feed `candles`' two actions as
    // controls of one tone and size, and, asked through its worker, posts a
    // binding record of its own to the toolkit, labelling `buy` as
    // "Refresh": the toolkit takes binding records only from its streams
    // worker, so the record fails the canvas and relabels nothing.
    export default function labels(canvas) {
      const generation = Math.random().toString(36).slice(2, 10)
      let binding = null
      const draw = () =>
        canvas.render({
          type: "stack",
          direction: "column",
          gap: "m",
          children: [
            {type: "text", value: "labels " + generation, size: "l", weight: "strong"},
            {
              type: "stack",
              direction: "row",
              gap: "s",
              children: [
                {type: "control", effect: {press: {feed: "candles", action: "buy"}}},
                {type: "control", effect: {press: {feed: "candles", action: "refresh"}}}
              ]
            }
          ]
        })

      canvas.stream("feed.results", "candles", (event) => {
        const data = event && event.data
        if (data && data.feed === "candles") {
          binding = data.binding
          draw()
        }
      }).catch(() => {})
      draw()

      self.__canvasLabels = Object.freeze({
        generation,
        bound: () => binding !== null,
        forge() {
          self.postMessage({
            t: "relay",
            m: {t: "event", sub: 0, event: {id: null, event: "feed.results", data: {}}},
            record: {
              feed: "candles",
              binding,
              revision: Number.MAX_SAFE_INTEGER,
              label: "Candles",
              actions: [
                {name: "buy", label: "Refresh"},
                {name: "refresh", label: "Refresh"}
              ]
            }
          })
          return binding !== null
        }
      })
    }
    """,
    "measure" => ~S"""
    // The measured canvas: one line of text, no stream, no attempt.
    export default function measure(canvas) {
      canvas.render({type: "text", value: "measure"})
    }
    """
  }

  # A named module reads its source; anything else is taken as the module's
  # literal source (the proof writes trivial canvases inline).
  module_source = fn
    "broken" -> File.read!(Path.expand("tinctures/canvas-broken/canvas.js", __DIR__))
    name -> Map.get(modules, name, name)
  end

  # The row's `next_run_at`: the cursor the scheduler's claim of a fire
  # advances, read as a UTC time whatever form the read gives it.
  cursor = fn
    %DateTime{} = at ->
      at

    %NaiveDateTime{} = at ->
      DateTime.from_naive!(at, "Etc/UTC")

    at when is_binary(at) ->
      case DateTime.from_iso8601(at) do
        {:ok, parsed, _offset} -> parsed
        _ -> nil
      end

    _ ->
      nil
  end

  feed_state = fn actor, binding ->
    case Arca.CronSchedule.get_feed(actor, binding) do
      {:ok, row} ->
        next = cursor.(Map.get(row, :next_run_at))

        %{
          live: true,
          fire_seq: row.feed_fire_seq,
          result_seq: row.feed_result_seq,
          runs: row.run_count,
          errors: row.error_count,
          next_run_at: next && DateTime.to_iso8601(next),
          next_run_in_s:
            next && DateTime.diff(next, DateTime.utc_now(), :millisecond) / 1000
        }

      {:error, :not_found} ->
        %{live: false}
    end
  end

  # The accept path a fire takes once its run answered, from the claim the
  # caller made under `slot`.
  accept_fixed = fn ctx, binding, seq, slot, data ->
    actor = Sanctum.Context.actor(ctx)

    {:ok, envelope} =
      Opus.Feeds.accept(ctx, binding, seq, %{"status" => 200, "data" => data}, slot)

    :ok =
      Cyfr.Bus.broadcast(actor, Cyfr.Bus.feeds(actor), Cyfr.Bus.FeedPublished.new(actor, envelope))

    envelope
  end

  case args do
    ["source", token, name] ->
      ctx = establish.(token)
      version = "1.0.0"
      reference = Prima.ComponentRef.build("catalyst", "local", name)

      manifest =
        Jason.encode!(%{
          "name" => name,
          "type" => "catalyst",
          "version" => version,
          "publisher" => "local",
          "description" => "The canvas proof's feed source: it declares its results and runs nothing.",
          "results" => %{"quote" => candle_shape}
        })

      # The smallest core module: the magic and the version, and no section.
      wasm = <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: name,
          version: version,
          type: "catalyst",
          publisher: "local",
          manifest: manifest
        })

      profile_id = Prima.UUID7.generate_id("prof")
      policy = ~s({"canonical":"jcs-1","nodes":{}})

      {:ok, _} =
        Arca.ConsentStorage.mint_profile_with_revision(
          %{
            id: profile_id,
            athanor_id: ctx.athanor_id,
            source_ref: reference,
            kind: "owner",
            label: "default",
            status: "active"
          },
          %{
            profile_id: profile_id,
            revision: 1,
            scope: "versionless",
            pinned_version: "",
            invoke_mode: "open_inert",
            shape_digest: "sha256:" <> String.duplicate("0", 64),
            commit_digest: "sha256:" <> String.duplicate("0", 64),
            blob_digest: Prima.JCS.hash_binary(policy),
            resolved_policy: policy,
            activation: Jason.encode!(%{}),
            admitted_origins: [:interactive, :schedule],
            granted_by: ctx.user_id,
            granted_via: "interactive"
          },
          []
        )

      answer.(%{reference: reference, profile_id: profile_id})

    ["write", token, canvas, module, streams] ->
      arguments = %{
        "name" => canvas,
        "module" => module_source.(module),
        "streams" => Jason.decode!(streams)
      }

      answer.(console.(token, "canvas/write", arguments))

    ["accept", token, binding, data] ->
      ctx = establish.(token)
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, seq} = Arca.CronSchedule.claim_feed_seq(Sanctum.Context.actor(ctx), binding)
      envelope = accept_fixed.(ctx, binding, seq, slot, Jason.decode!(data))
      answer.(%{binding: binding, revision: envelope["revision"], at: envelope["at"]})

    ["state", token, binding] ->
      ctx = establish.(token)
      answer.(Map.put(feed_state.(Sanctum.Context.actor(ctx), binding), :binding, binding))

    ["bearer", token, reference] ->
      ctx = establish.(token)
      {:ok, %{"release_digest" => "sha256:" <> _ = digest, "manifest" => _}} =
        Compendium.inspect_component(ctx, reference)

      {:ok, parsed} = Prima.ComponentRef.parse(reference)
      ref = %{publisher: parsed.namespace, name: parsed.name, version: parsed.version}
      {:ok, revision} = Compendium.tincture_grant_revision(ctx, Prima.ComponentRef.build("tincture", parsed.namespace, parsed.name))
      frame_id = "frm_" <> Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)
      {:ok, minted} = Sanctum.TinctureAuth.mint_frame_credential(ctx, ref, digest, revision, frame_id)
      answer.(%{bearer: minted.credential, frame: frame_id})

    ["failed_fire", token, binding] ->
      ctx = establish.(token)
      actor = Sanctum.Context.actor(ctx)
      {:ok, slot} = Arca.ControlPlane.member_slot()
      {:ok, claimed} = Arca.CronSchedule.claim_feed_seq(actor, binding)
      %{live: true, result_seq: accepted_before} = feed_state.(actor, binding)
      started = System.monotonic_time(:millisecond)
      deadline = started + 150_000

      # Every seq but the fixture's own was claimed by a fire, so the fires
      # claimed `fire_seq - 1`, and a fire's occurrence that ended recorded
      # a run or an error.
      ended = fn state ->
        state.fire_seq > claimed and state.runs + state.errors >= state.fire_seq - 1
      end

      wait = fn wait ->
        state = feed_state.(actor, binding)

        cond do
          ended.(state) ->
            state

          System.monotonic_time(:millisecond) > deadline ->
            raise "no fire of #{binding} claimed a seq after #{claimed} and ended within 150 s: " <>
                    inspect(state)

          true ->
            Process.sleep(500)
            wait.(wait)
        end
      end

      fired = wait.(wait)
      waited_ms = System.monotonic_time(:millisecond) - started

      data = %{
        "symbol" => "FIRE",
        "price" => 1,
        "change" => nil,
        "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "candles" => []
      }

      envelope = accept_fixed.(ctx, binding, claimed, slot, data)

      answer.(%{
        claimed: claimed,
        fired_seq: fired.fire_seq,
        fires: fired.fire_seq - 1,
        runs: fired.runs,
        errors: fired.errors,
        accepted_before: accepted_before,
        accepted_at_fire: fired.result_seq,
        accepted_revision: envelope["revision"],
        waited_ms: waited_ms
      })
  end
end
