# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Provisioning do
  @moduledoc """
  Filling an athanor's component athanor: the seed bundle copied into its
  `components/` and registered as rows, the shipped AQUA tree checked
  well-formed and copied into its `aqua/`, the published components the
  bundle depends on pulled from the registry, and the athanor's agents
  indexed — so the athanor's AQUA answers from the first prompt. The seed
  tree is the shipped default: what a release ships later is offered,
  never pushed, and a reset copies it in again.

  The registry pull runs as the person whose sign-in caused it, so their
  pull credential is used; a seed context pulls anonymously, which serves
  public components.

  ## Who asks, and who answers

  The athanor's claim, the baseline consent every fill mints, the
  readiness and failure writes on the row and the person's own athanor
  are the identity domain's (`Sanctum.Provisioning`), which this module
  calls down into. It never reads a tenancy row or mints a consent
  itself.

  Identity asks for a fill through the component-facts port
  (`Sanctum.Consent.Components.fill/3`, implemented by
  `Compendium.ConsentFacts`), and `request/3` here answers it. The
  answer is synchronous for the explicit `provision` verb — a person is
  holding the request open and gets the attempt's own answer — and
  backgrounded for the first-need hook and the sign-in retries, which no
  request path may wait on. A background attempt runs under
  `Compendium.ProvisioningSupervisor`, the task supervisor that owns
  every fill and pull this module starts.

  Every attempt ends in a state the athanor's claim and row can name. A
  step that fails, a pull cut at its deadline and an attempt that raises
  are recorded on the row as a failure (`Sanctum.Provisioning.record_failure/4`),
  which is what the explicit verb answers with and what a reader backs
  off from; a claim lost to a successor writes nothing and the athanor is
  the successor's. An attempt killed where it stands runs no code: its
  claim's keeper gives the athanor back, and the next request fills it.

  Required dependency pulls run under one deadline per attempt
  (`:provisioning_required_pull_budget_ms`); optional pulls under a
  shorter fixed one. A walk cut short stops where it is: what landed stays
  registered, the failure is recorded on the row, and the next attempt
  finds what is still missing by reading every installed component's
  manifest. A pull runs beside the attempt rather than inside it, so it is
  started and stopped by the athanor's claim
  (`Sanctum.Provisioning.bounded_work/3`) and never outlives it.
  """

  require Logger

  alias Compendium.{AutoIndexer, Pull}
  alias Sanctum.Context
  alias Sanctum.Provisioning, as: Athanor

  @typedoc "An athanor's row, as the plain map the tenancy facade answers."
  @type athanor :: %{required(:id) => String.t(), optional(atom()) => term()}

  # How long a boot's seed sync waits for an athanor another attempt holds.
  @sync_wait_ms 30_000
  @sync_poll_ms 250

  # The bundle's optional dependencies — the model catalysts — are pulled
  # as a courtesy with a budget of their own.
  @optional_pull_budget_ms 10_000

  # ---------------------------------------------------------------------------
  # The filler
  # ---------------------------------------------------------------------------

  @doc """
  The component-facts port's fill (`Sanctum.Consent.Components.fill/3`).
  `provision` is the explicit verb: the attempt runs here, in the asking
  process, and this answers with its outcome. Every other entry kind is a
  hook: the attempt is started under `Compendium.ProvisioningSupervisor`
  and this answers `:ok` at once — a request path must never wait on a
  registry.
  """
  @spec request(athanor(), Context.t() | nil, String.t()) ::
          :ok | {:ok, athanor()} | {:error, term()}
  def request(athanor, ctx, "provision"), do: provision(athanor, ctx)
  def request(athanor, ctx, "sign_in"), do: claim_then_background(athanor, ctx)

  def request(athanor, ctx, entry_kind) when is_binary(entry_kind),
    do: background(fn -> attempt(athanor, ctx, entry_kind) end)

  # The claim is taken before the task starts, so a reader arriving with
  # the session already finds the athanor being filled; the task is what
  # holds it, and `not_started` gives it back when the work will not run.
  # The member's standing is asked first: one that will not fill must not
  # take the athanor even briefly, or a reader on the member that would
  # fill it sees an attempt in progress that is not one.
  defp claim_then_background(athanor, ctx) do
    if Arca.ControlPlane.held?(), do: claim_then_fill(athanor, ctx), else: :ok
  end

  defp claim_then_fill(%{id: athanor_id} = athanor, ctx) do
    case Athanor.take_claim(athanor_id, "sign_in") do
      {:ok, claim} ->
        background(
          fn -> Athanor.hold(athanor_id, claim, &fill(&1, athanor, ctx)) end,
          fn -> Athanor.release(athanor_id, claim) end
        )

      _busy_or_unavailable ->
        :ok
    end

    :ok
  end

  # Run `fun` off the caller's process, on the member that holds its slot
  # in the cell (`Arca.ControlPlane.held?/0`, a term read and a monotonic
  # comparison — no query, so it is safe on this path). Elsewhere it is
  # not started, and the next read on a holder asks again. Under test the
  # sandbox owns the connection, so background work runs inline (the tests
  # assert on rows right after the call). `not_started` runs when the work
  # will not: what a caller took for it beforehand is given back.
  defp background(fun, not_started \\ fn -> :ok end) do
    cond do
      not Arca.ControlPlane.held?() ->
        not_started.()
        :ok

      Application.get_env(:sanctum, :provisioning_inline, false) ->
        fun.()
        :ok

      true ->
        logger_metadata = Prima.LoggerContext.capture()

        task_fun = fn ->
          Prima.LoggerContext.restore(logger_metadata)
          fun.()
        end

        case start_background(task_fun) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            # A retry the supervisor could not start is only a deferral: the
            # next sign-in (or a member's athanor.provision) tries again.
            Logger.error("[Provisioning] background provisioning not started: #{inspect(reason)}")

            not_started.()
            :ok
        end
    end
  end

  # A supervisor not yet started (a request during boot) or already gone
  # (one during shutdown) exits the caller instead of answering; either is
  # a fill that did not start.
  defp start_background(task_fun) do
    Task.Supervisor.start_child(Compendium.ProvisioningSupervisor, task_fun)
  catch
    :exit, reason -> {:error, {:supervisor_down, reason}}
  end

  @doc """
  Fill an athanor: register the bundle (the scan walking the seed overlay)
  → pull the dependency closure → baseline consents → mark provisioned.
  `acting_ctx` is the person's context focused on the athanor (their pull
  credential); `nil` provisions as the server (anonymous pulls). Returns
  the row either way; a failure is recorded on it and logged.

  Single-flighted per athanor: the fill is idempotent but the closure
  pull is not free, so two callers finding a fresh athanor at once would
  each walk it.
  """
  @spec provision(athanor(), Context.t() | nil) ::
          {:ok, athanor()} | {:error, term()}
  def provision(%{provisioned_at: %DateTime{}} = athanor, _ctx), do: {:ok, athanor}

  def provision(athanor, acting_ctx), do: attempt(athanor, acting_ctx, "provision")

  defp attempt(%{id: athanor_id} = athanor, acting_ctx, entry_kind) do
    Athanor.under_claim(athanor_id, entry_kind, &fill(&1, athanor, acting_ctx))
  end

  @doc false
  # One attempt under a claim already taken — what every filling entry
  # point runs once it holds the athanor. Public so a test can run an
  # attempt under a claim it took, and lost, itself.
  @spec fill(Athanor.claim(), athanor(), Context.t() | nil) ::
          {:ok, athanor()} | {:error, term()}
  def fill(claim, %{id: athanor_id} = athanor, acting_ctx) do
    # Re-read under the claim: the attempt that just held it may have been
    # filling this very athanor.
    case Athanor.athanor(athanor_id) do
      {:ok, %{provisioned_at: %DateTime{}} = filled} -> {:ok, filled}
      {:ok, fresh} -> do_fill(claim, fresh, acting_ctx)
      _ -> do_fill(claim, athanor, acting_ctx)
    end
  rescue
    e -> interrupted(claim, athanor, {:raised, e.__struct__})
  catch
    :exit, _reason -> interrupted(claim, athanor, :exited)
    :throw, _value -> interrupted(claim, athanor, :thrown)
  end

  # An attempt that raised is a failure like any step's, recorded on the
  # row under the claim it still holds: left unrecorded, the next reader
  # would start the same attempt at once and it would raise again. What is
  # recorded names how it ended, never the exception's words, which may
  # carry a credential or a path.
  defp interrupted(claim, athanor, how) do
    Logger.error("[Provisioning] #{athanor.id}: the attempt ended abnormally (#{inspect(how)})")
    Athanor.record_failure(claim, athanor, :interrupted, how)
  end

  defp do_fill(claim, %{id: athanor_id} = athanor, acting_ctx) do
    ctx = acting_ctx || Athanor.seed_ctx(athanor_id)

    # The agents are indexed before the consents are minted: an agent is a
    # consent source, and its revision bytes are registered by the index
    # before any consent names it.
    with :ok <- Arca.ensure_roots(Context.actor(Athanor.seed_ctx(athanor_id))),
         {:ok, _scan} <- register_bundle(athanor_id, claim),
         :ok <- aqua_definitions(athanor_id, claim),
         :ok <- index_agents(ctx, claim),
         {:ok, closure} <- pull_required_deps(ctx, claim),
         optional <- pull_optional_deps(ctx, claim),
         {:ok, bootstrap} <- Athanor.bootstrap_consents(ctx, claim),
         :ok <- Athanor.settle(athanor_id, claim, "ready", nil) do
      Logger.info(
        "[Provisioning] #{athanor_id} provisioned " <>
          "(pulled #{length(closure.pulled)} required and #{optional} optional, " <>
          "minted #{length(bootstrap.minted)})"
      )

      Athanor.mark_filled(athanor)
    else
      {:error, :claim_lost} ->
        Athanor.lost(athanor_id)

      {:error, {:closure, detail}} ->
        Athanor.record_failure(claim, athanor, :closure, detail)

      {:error, {:aqua_template, _} = reason} ->
        Athanor.record_failure(claim, athanor, :aqua_template, reason)

      # The consent walk could not read what the athanor holds. Recorded
      # as its own step: an athanor nothing could be read for is not an
      # athanor whose seed is missing.
      {:error, {:component_facts, _} = reason} ->
        Athanor.record_failure(claim, athanor, :bootstrap, reason)

      {:error, reason} ->
        Athanor.record_failure(claim, athanor, :seed, reason)

      {:unminted, skipped} ->
        Athanor.record_failure(claim, athanor, :bootstrap, skipped)
    end
  end

  # ---------------------------------------------------------------------------
  # Installing one shipped version
  # ---------------------------------------------------------------------------

  @doc """
  Copy a shipped component version into the context's athanor — a newer
  version a release brought, or one the athanor lacks — register it and
  mint its baseline consent, as the first fill did for what shipped then.
  A `local` ref names what the server ships; a versionless ref takes the
  newest shipped version. Answers what `Compendium.Pull.pull_shipped/2`
  does: `{:error, :not_shipped}` for a version the seed does not carry.
  """
  @spec install_shipped(Context.t(), String.t()) ::
          {:ok, %{status: String.t(), component_ref: String.t()}} | {:error, term()}
  def install_shipped(%Context{athanor_id: athanor_id} = ctx, reference)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(reference) do
    # The same claim every other filler takes: this mints consent, and a
    # background fill or a boot sync doing the same walk at the same moment
    # would interleave two mints over one athanor's sources. Tried once —
    # a person is holding this request open, and a refusal they can retry
    # beats queueing behind a fill. Released with no verdict on readiness.
    Athanor.under_claim(athanor_id, "install_shipped", fn claim ->
      with {:ok, pulled} <- Pull.pull_shipped(ctx, reference, claim: fence(claim)),
           :ok <- Athanor.bootstrap_consents_for(ctx, claim, pulled.component_ref) do
        {:ok, pulled}
      else
        {:error, :claim_lost} -> Athanor.lost(athanor_id)
        other -> other
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # The boot's seed sync
  # ---------------------------------------------------------------------------

  @doc """
  Make every provisioned athanor whole against the seed media a release
  shipped — without changing what the athanor chose. A shipped version a
  row names but the tree no longer holds is copied back; an athanor
  without its shipped soul gets the shipped AQUA tree; the bundle's
  published dependencies are re-pulled and baseline consents minted for
  any row still without one. Newer shipped versions are NOT copied in:
  they read as available until a person pulls them, so an upgrade never
  changes an athanor under its members.

  Runs at boot (`Cyfr.SeedOffer`); a failure logs and moves on — a sync
  must never take the server down or block another athanor's.
  """
  @spec sync_seeds() :: :ok
  def sync_seeds do
    for athanor <- Athanor.filled_athanors() do
      # The same claim every fill takes, so a boot healing an athanor and an
      # install or a retry cannot walk one athanor at once. Not `provision/2`:
      # this runs on athanors that are already filled, which is exactly what
      # that function short-circuits. The sync has no one to answer to, so
      # it waits out an attempt in progress — within a bound, since one
      # held athanor must not keep the boot from the next.
      case Athanor.await_claim(
             athanor.id,
             "seed_sync",
             @sync_wait_ms,
             @sync_poll_ms,
             &sync_seed(athanor, &1)
           ) do
        {:error, reason} ->
          Logger.warning("[Provisioning] #{athanor.id}: seed sync skipped — #{inspect(reason)}")

        _ ->
          :ok
      end
    end

    :ok
  end

  defp sync_seed(athanor, claim) do
    ctx = Athanor.seed_ctx(athanor.id)

    case Arca.ensure_roots(Context.actor(ctx)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Provisioning] #{athanor.id}: roots — #{inspect(reason)}")
    end

    heal_shipped(ctx, athanor.id, claim)

    case AutoIndexer.scan(ctx: ctx) do
      {:ok, %{registered: registered}} when registered > 0 ->
        Logger.info("[Provisioning] #{athanor.id}: registered #{registered} bundle version(s)")

      {:ok, %{errors: errors}} when errors > 0 ->
        Logger.warning("[Provisioning] #{athanor.id}: bundle sync hit #{errors} error(s)")

      {:ok, _scan} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Provisioning] #{athanor.id}: bundle sync skipped — #{inspect(reason)}")
    end

    # Deps and consents retry every boot, not only when the scan minted
    # something — a transient registry outage at the previous sync must
    # not leave the closure missing until the next release. Both are
    # cheap no-ops when nothing is missing.
    case pull_required_deps(ctx, claim) do
      {:ok, _closure} ->
        :ok

      {:error, {:closure, detail}} ->
        Logger.warning(
          "[Provisioning] #{athanor.id}: dep pull after sync failed: #{inspect(detail)}"
        )
    end

    _ = pull_optional_deps(ctx, claim)

    # The index and the mint speak for the athanor, so they are this sync's
    # only while the claim is. The index says so in the transaction that
    # writes it; the mint asks first, which is as close as it gets.
    case index_agents(ctx, claim) do
      :ok ->
        case Athanor.holding(athanor.id, claim) do
          :ok -> bootstrap_synced(ctx, claim, athanor.id)
          {:error, :claim_lost} -> Athanor.lost(athanor.id)
        end

      {:error, :claim_lost} ->
        Athanor.lost(athanor.id)
    end

    :ok
  end

  # What the athanor already chose, restored: a shipped version its rows
  # name but its tree lacks, and the shipped AQUA tree when it holds no
  # AQUA unit at all. A newer shipped version with no row is left available.
  # Each copy is the sync's, published only under its claim and slot.
  defp heal_shipped(ctx, athanor_id, claim) do
    actor = Context.actor(ctx)

    with {:ok, statuses} <- Arca.Overlay.unit_statuses(actor, "components"),
         {:ok, rows} <- Arca.ComponentStorage.list_components(actor, limit: :none) do
      registered =
        MapSet.new(rows, fn row ->
          Compendium.ComponentPath.version_dir(
            row.component_type,
            Compendium.ComponentPath.normalize_publisher(row.publisher),
            row.name,
            row.version
          )
        end)

      for {unit, :available} <- statuses, MapSet.member?(registered, unit) do
        case Arca.Overlay.pull_shipped(actor, unit, claim: fence(claim)) do
          :ok ->
            Logger.info("[Provisioning] #{athanor_id}: restored shipped #{Enum.join(unit, "/")}")

          {:error, reason} ->
            Logger.warning(
              "[Provisioning] #{athanor_id}: shipped #{Enum.join(unit, "/")} not restored: " <>
                inspect(reason)
            )
        end
      end
    else
      {:error, reason} ->
        Logger.warning("[Provisioning] #{athanor_id}: heal skipped — #{inspect(reason)}")
    end

    case Arca.Overlay.unit_statuses(Context.actor(ctx), "aqua") do
      {:ok, statuses} ->
        held? = Enum.any?(statuses, fn {_unit, status} -> status != :available end)

        if not held? and statuses != %{} do
          case Arca.Overlay.materialize_shipped(Context.actor(ctx), "aqua", claim: fence(claim)) do
            {:ok, copied} ->
              Logger.info(
                "[Provisioning] #{athanor_id}: copied #{length(copied)} shipped AQUA unit(s)"
              )

            {:error, reason} ->
              Logger.warning(
                "[Provisioning] #{athanor_id}: AQUA not restored — #{inspect(reason)}"
              )
          end
        end

      {:error, reason} ->
        Logger.warning("[Provisioning] #{athanor_id}: AQUA heal skipped — #{inspect(reason)}")
    end

    :ok
  end

  # Idempotent by construction: every already-consented ref lands in
  # `skipped`, so only what the release just added mints anything, and
  # only a bootstrap-only head the release moved is re-minted.
  defp bootstrap_synced(ctx, claim, athanor_id) do
    case Athanor.bootstrap_consents(ctx, claim) do
      {:error, :claim_lost} ->
        Athanor.lost(athanor_id)

      {:ok, %{minted: minted, revised: revised}} when minted != [] or revised != [] ->
        Logger.info(
          "[Provisioning] #{athanor_id}: baseline consents minted for " <>
            "[#{Enum.join(minted, ", ")}], re-minted for [#{Enum.join(revised, ", ")}]"
        )

      # A sync is a heal, not an attempt: a source the walk could not mint
      # leaves the athanor as it found it and is said out loud, where the
      # fill would record it on the row and stop.
      {:unminted, unminted} ->
        Logger.warning(
          "[Provisioning] #{athanor_id}: baseline consents not minted for " <>
            "#{inspect(Enum.map(unminted, &elem(&1, 0)))}; the next sync tries again"
        )

      _nothing_new ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The bundle and its closure
  # ---------------------------------------------------------------------------

  # The bundle copied in and registered as rows: every shipped version
  # directory the athanor does not hold is copied from the seed
  # (`Arca.Overlay.materialize_shipped/3`) under the attempt's claim and
  # slot, then the scan walks the athanor's `components/` and mints a row
  # per version directory. An install without its bundle cannot provision
  # anyone; say so rather than minting an empty athanor.
  defp register_bundle(athanor_id, claim) do
    ctx = Athanor.seed_ctx(athanor_id)
    actor = Context.actor(ctx)

    with :ok <- bundle_present(actor),
         {:ok, _copied} <-
           Arca.Overlay.materialize_shipped(actor, "components", claim: fence(claim)) do
      # A component that fails registration is logged by the scan and
      # skipped; the consent bootstrap's minting gate is what decides
      # whether what registered is enough to provision. A discovery outage
      # is the scan's own typed error and fails the provisioning step
      # loudly.
      AutoIndexer.scan(ctx: ctx)
    end
  end

  defp bundle_present(actor) do
    case Arca.list_recursive(actor, Arca.Storage.seed_prefix("components")) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :bundle_missing}
      {:error, reason} -> {:error, {:bundle_unreadable, reason}}
    end
  end

  # The shipped AQUA tree, checked well-formed first (a mount with no soul,
  # or a soul or role that does not parse, fails loud here, at the one
  # moment an operator is watching, instead of as an empty roster later),
  # then copied into the athanor's `aqua/` — every shipped unit it does not
  # yet hold, under the attempt's claim and slot.
  defp aqua_definitions(athanor_id, claim) do
    actor = Context.actor(Athanor.seed_ctx(athanor_id))

    with :ok <- Compendium.AquaTemplate.seed_check(),
         {:ok, _copied} <- Arca.Overlay.materialize_shipped(actor, "aqua", claim: fence(claim)) do
      :ok
    else
      {:error, reason} -> {:error, {:aqua_template, reason}}
    end
  end

  # The athanor's agents as rows, derived from the tree the seed just
  # filled or the release just moved, written in the same transaction that
  # holds the claim and verifies the member slot it was taken under: an
  # attempt a successor took over, or whose member lost that slot,
  # publishes no index, and that is the one failure here that IS
  # provisioning's, since the successor owns the athanor from that moment.
  # Anything else — a file that would not parse, a tree that could not be
  # read — leaves the rows as they were and is reported.
  defp index_agents(ctx, claim) do
    case Compendium.AgentIndex.sync(ctx, claim: fence(claim)) do
      {:ok, _} ->
        :ok

      {:error, :claim_lost} ->
        {:error, :claim_lost}

      {:error, reason} ->
        Logger.warning("[Provisioning] agent index not synced: #{inspect(reason)}")
        :ok
    end
  end

  # The attempt's fence as every write it makes for the athanor names it:
  # the claim's owner and fence, and the member slot the claim was taken
  # under — never a slot read again since.
  defp fence(claim), do: %{owner: claim.owner, fence: claim.fence, slot: claim.slot}

  # The bundle's required dependencies — everything a local component
  # declares it cannot run without — pulled under the attempt's deadline.
  # A pull that fails, times out or exits is a provisioning failure at the
  # closure step, retried by the next attempt.
  defp pull_required_deps(ctx, claim) do
    budget_ms = Application.fetch_env!(:cyfr, :provisioning_required_pull_budget_ms)

    case bounded_pull(ctx, missing_bundle_deps(ctx, :required), budget_ms, claim) do
      {:ok, %{failed: []} = closure} -> {:ok, closure}
      {:ok, %{failed: failed}} -> {:error, {:closure, failed}}
      :timeout -> {:error, {:closure, {:timeout, budget_ms}}}
      {:exit, reason} -> {:error, {:closure, {:exit, reason}}}
    end
  end

  # The bundle's optional dependencies — the model catalysts — are pulled
  # when a registry is configured to pull them from, as a courtesy with a
  # budget: a registry that is slow, unreachable or unset-by-default and
  # absent leaves the athanor provisioned on what the bundle ships, its
  # activations covering what is there, and the catalysts arrive when a
  # model is connected. An optional dependency that fails to pull is never
  # a provisioning failure.
  defp pull_optional_deps(ctx, claim) do
    optional =
      if Compendium.RegistryHost.configured?(),
        do: missing_bundle_deps(ctx, :all) -- missing_bundle_deps(ctx, :required),
        else: []

    case bounded_pull(ctx, optional, @optional_pull_budget_ms, claim) do
      {:ok, %{pulled: pulled, failed: []}} ->
        length(pulled)

      {:ok, %{pulled: pulled, failed: failed}} ->
        Logger.warning(
          "[Provisioning] #{length(failed)} optional dependencies not pulled " <>
            "(#{inspect(Enum.map(failed, &elem(&1, 0)))}); the athanor provisions without them"
        )

        length(pulled)

      :timeout ->
        Logger.warning(
          "[Provisioning] optional dependencies not pulled within " <>
            "#{@optional_pull_budget_ms} ms; the athanor provisions without them"
        )

        0

      {:exit, reason} ->
        Logger.warning(
          "[Provisioning] optional dependency pull exited (#{Prima.LogFilter.inspect_reason(reason)}); " <>
            "the athanor provisions without them"
        )

        0
    end
  end

  # Pull `refs` and their closure with `budget_ms` as the deadline for the
  # whole walk, in a task of the provisioning supervisor's. Past the
  # deadline the task is killed where it is — under the claim, so the
  # attempt has stopped before the claim settles. The
  # components it registered before the cut stay, and `missing_bundle_deps/2`
  # lists what is installed, so the next attempt finds what is still
  # missing below them. A task that exits is reported, never the caller's
  # crash: a seed sync at boot must not take the server down.
  #
  # The task is the athanor's claim's (`Sanctum.Provisioning.bounded_work/3`),
  # not this process's: unlinked so its crash stays its own, it would
  # otherwise outlive an attempt killed where it stands and go on writing
  # into an athanor a successor already holds. The claim's keeper starts it
  # and stops it before the claim goes back. Each unit it pulls commits
  # under the attempt's claim and the slot that claim was taken under, so
  # a pull that outlives the attempt's hold on either publishes nothing.
  defp bounded_pull(_ctx, [], _budget_ms, _claim),
    do: {:ok, %{pulled: [], failed: [], present: []}}

  defp bounded_pull(ctx, refs, budget_ms, claim) do
    Athanor.bounded_work(Compendium.ProvisioningSupervisor, budget_ms, fn ->
      Pull.ensure_published_deps(ctx, refs, claim: fence(claim))
    end)
  end

  # Every static dependency the athanor's components declare that is not
  # present; `include: :required` names those the bundle cannot run
  # without, `:all` adds the optional ones.
  #
  # Every component, not only the seeded ones: `Compendium.Pull` walks a
  # closure by recursion and treats an already-present ref as done, so a
  # pull cut short between a component and its own dependency would leave
  # that dependency undiscoverable — the component is present, and nothing
  # would re-read its manifest. Listing what is installed, whoever
  # published it, is what makes an interrupted closure heal on the next
  # attempt.
  defp missing_bundle_deps(ctx, include) do
    case Arca.ComponentStorage.list_components(Context.actor(ctx), limit: :none) do
      {:ok, rows} ->
        rows
        |> Enum.flat_map(&Pull.missing_deps(ctx, &1, include: include))
        |> Enum.uniq()

      _ ->
        []
    end
  end
end
