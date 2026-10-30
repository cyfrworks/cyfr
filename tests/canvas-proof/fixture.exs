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
#       `Compendium.Registry.publish_bytes/4` as the suite's catalyst guest
#       (apps/cyfr/test/support/test_wasm/guests/), whose answer,
#       `{"ran":true}`, is no feed envelope, so a fire's result is refused
#       and a feed's result is only ever one the fixture accepts. Its
#       manifest's `results` declares the shape of each operation's data:
#       `quote`, a symbol's price and its candles. Beside it, its owner
#       profile, active, whose head consent admits the `interactive` and
#       `schedule` origins, minted through Arca's one profile mint as a
#       person's grant leaves one; a feed fires under `schedule`. Answers
#       the reference and the profile id.
#
#   write TOKEN CANVAS KIND STREAMS_JSON
#       A new version of the canvas CANVAS written with `canvas.write`,
#       through `console`: its page the files KIND names (below), on the
#       vanilla template, and STREAMS_JSON the streams it reads. Answers the
#       console's answer.
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
#       its own. The `policy` step posts with it on a canvas's own data
#       path, which refuses it `frame_path_mismatch` because its frame id is
#       not the path's, and on the shared data routes, which refuse a canvas
#       credential `canvas_path_required`; both refusals come before any
#       authority is read. Answers the bearer and its frame id; the proof
#       keeps neither in the record.
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
# The pages a written canvas runs (`write`'s KIND), each an ordinary HTML
# page on the vanilla template (`index.html` and `app.js`), which the
# SDK the controller injects into the page gives `window.cyfr`:
#
#   markets       reads the feed `candles` and draws its candles as its own
#                 SVG; a button the person presses calls `cyfr.press` on the
#                 feed's binding, and `window.__canvas` offers the presses
#                 the activation step drives from a timer and the self-focus
#                 it records;
#   measure       one line of text: it reads no stream and becomes ready at
#                 once (the measurement opens it);
#   written       one line naming its own version, then ready;
#   broken-quiet  draws a line and never becomes ready: validation records
#                 `not_ready` at its deadline;
#   broken-die    throws from a timer before ready: validation records
#                 `died` (the SDK reports `failed` at stage `load`);
#   broken-crash  becomes ready, then reloads its own frame from a timer:
#                 shown live its frame loads a second time, which the bridge
#                 reports as `frame_gone`, the frame's death, which falls
#                 the canvas back to the shipped one. Its reload comes well
#                 after a
#                 validation frame is torn down, so validation activates it
#                 first.
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

  # The page an ordinary vanilla canvas serves: its head carries only its
  # own title (the controller puts the `<base>` and the SDK script first),
  # its body an empty `#root` the page's module fills, and its one module.
  index_html = fn title ->
    ~s(<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><title>) <>
      title <>
      ~s(</title></head><body><main id="root"></main>) <>
      ~s(<script type="module" src="app.js"></script></body></html>\n)
  end

  # Each written canvas's module, by the kind `write` is asked for. The
  # version a page draws is read from its own served path.
  version_from_url = ~S|const version = new URL(import.meta.url).pathname.split("/").filter(Boolean).slice(-2)[0]|

  modules = %{
    "markets" => ~S"""
    // A written canvas on the vanilla template: it reads the feed `candles`
    // and draws its candles as its own SVG, and presses the feed's refresh
    // action from a button the person clicks, and asks for a component's
    // grant from another. `window.__canvas` offers the presses and the
    // grant the activation and grant steps drive from a timer, so one can
    // leave with no person input, and the self-focus it records.
    const root = document.getElementById("root")
    root.innerHTML =
      '<h1>markets</h1><p id="seen">no result yet</p>' +
      '<svg id="chart" width="320" height="140"></svg>' +
      '<p><button id="press" type="button">Refresh</button>' +
      '<button id="press3" type="button">Refresh three</button>' +
      '<button id="later" type="button">Refresh later</button>' +
      '<button id="grant" type="button">Grant claude</button></p>'
    const chart = document.getElementById("chart")
    const seen = document.getElementById("seen")
    let binding = null
    const press = () => {
      if (!binding) return false
      cyfr.press(binding, "refresh")
      return true
    }
    document.getElementById("press").addEventListener("click", () => press())
    document.getElementById("press3").addEventListener("click", () => {
      press()
      press()
      press()
    })
    document.getElementById("later").addEventListener("click", () => setTimeout(() => press(), 8000))
    const grant = () => cyfr.grant("catalyst:local.claude")
    document.getElementById("grant").addEventListener("click", () => grant())

    function onEvent(event) {
      const data = event && event.data
      if (!data || data.feed !== "candles") return
      binding = data.binding
      seen.textContent = "revision " + data.revision + (data.refresh === true ? " (refresh)" : "")
      const candles = data.result && Array.isArray(data.result.candles) ? data.result.candles : []
      while (chart.firstChild) chart.removeChild(chart.firstChild)
      candles.forEach((_candle, i) => {
        const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect")
        rect.setAttribute("class", "candle")
        rect.setAttribute("x", String(8 + i * 28))
        rect.setAttribute("y", "10")
        rect.setAttribute("width", "16")
        rect.setAttribute("height", "110")
        chart.appendChild(rect)
      })
    }

    // Keep the stream open: when the shell suspends the canvas its stream
    // closes, and when it is shown again it opens again from its refresh, so
    // a feed rebound while it was away reaches it as the new binding's latest.
    function follow() {
      cyfr.stream("feed.results", "candles", onEvent).then(
        (handle) => {
          const again = () => setTimeout(follow, 600)
          handle.closed.then(again, again)
        },
        () => setTimeout(follow, 600)
      )
    }
    follow()

    window.__canvas = Object.freeze({
      bound: () => binding !== null,
      current: () => binding,
      // A press sent from a timer, so it leaves no evaluation's user gesture
      // behind: with no person input near it, the shell drops it.
      pressAfter: (ms) => {
        setTimeout(() => press(), ms)
      },
      // A grant asked from a timer, with no person input near it.
      grantAfter: (ms) => {
        setTimeout(() => grant(), ms)
      },
      // The canvas focuses itself and then presses from a timer: the
      // activation step records what each browser does with a press that
      // follows a click elsewhere and the canvas's own focus.
      scheduleFocusPress: (mode, ms) => {
        setTimeout(() => {
          if (mode === "window") {
            try {
              window.focus()
            } catch (_error) {
              /* denied */
            }
          } else if (mode === "element") {
            try {
              document.getElementById("press").focus()
            } catch (_error) {
              /* denied */
            }
          }
          press()
        }, ms)
      }
    })
    cyfr.ready()
    """,
    "measure" => ~S"""
    // The measured canvas: one line of text, no stream, ready at once.
    document.getElementById("root").textContent = "measure"
    cyfr.ready()
    """,
    "written" => """
    // A written canvas that names its own version and becomes ready.
    #{version_from_url}
    document.getElementById("root").textContent = "written " + version
    cyfr.ready()
    """,
    "broken-quiet" => """
    // Never becomes ready: validation records `not_ready` at its deadline.
    #{version_from_url}
    document.getElementById("root").textContent = "broken " + version + " (quiet)"
    """,
    "broken-die" => """
    // Throws from a timer before ready: the SDK reports `failed` at stage
    // `load`, so validation records `died`.
    #{version_from_url}
    document.getElementById("root").textContent = "broken " + version + " (die)"
    setTimeout(() => {
      throw new Error("canvas-broken dies before ready")
    }, 0)
    """,
    "broken-crash" => """
    // Becomes ready, then reloads its own frame from a timer: shown live
    // the frame loads a second time, its death, which falls the canvas
    // back; a page that only throws after ready does not. The delay is
    // well past a validation frame's teardown, so validation activates
    // this version before any reload, and only the live frame dies.
    #{version_from_url}
    document.getElementById("root").textContent = "broken " + version + " (crash)"
    cyfr.ready()
    setTimeout(() => {
      location.reload()
    }, 2500)
    """
  }

  # The files `write` commits for a kind: the vanilla page's `index.html`
  # and its one module.
  canvas_files = fn kind ->
    module = Map.fetch!(modules, kind)
    %{"index.html" => index_html.(kind), "app.js" => module}
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
          next_run_in_s: next && DateTime.diff(next, DateTime.utc_now(), :millisecond) / 1000
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
      Cyfr.Bus.broadcast(
        actor,
        Cyfr.Bus.feeds(actor),
        Cyfr.Bus.FeedPublished.new(actor, envelope)
      )

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
          "description" =>
            "The canvas proof's feed source: it declares its results and answers none.",
          "results" => %{"quote" => candle_shape}
        })

      wasm =
        File.read!(
          Path.expand("../../apps/cyfr/test/support/test_wasm/guests/catalyst.wasm", __DIR__)
        )

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
            blob_digest: Prima.Digest.sha256(policy),
            resolved_policy: policy,
            activation: Jason.encode!(%{}),
            admitted_origins: [:interactive, :schedule],
            granted_by: ctx.user_id,
            granted_via: "interactive"
          },
          []
        )

      answer.(%{reference: reference, profile_id: profile_id})

    ["write", token, canvas, kind, streams] ->
      {template, files} = {"vanilla", canvas_files.(kind)}

      arguments = %{
        "name" => canvas,
        "template" => template,
        "files" => files,
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

      {:ok, revision} =
        Compendium.tincture_grant_revision(
          ctx,
          Prima.ComponentRef.build("tincture", parsed.namespace, parsed.name, parsed.version)
        )

      frame_id = "frm_" <> Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)

      {:ok, minted} =
        Sanctum.TinctureAuth.mint_frame_credential(ctx, ref, digest, revision, frame_id)

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
