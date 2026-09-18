# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Provisioning do
  @moduledoc """
  What turns an athanor row into a working athanor: the seed bundle
  copied into the athanor's `components/` and registered as rows, the
  shipped AQUA tree checked well-formed and copied into its `aqua/`, the
  published components the bundle depends on pulled from the registry,
  and a baseline consent minted for every executable local component —
  so the athanor's AQUA answers from the first prompt. The seed tree is
  the shipped default: what a release ships later is offered, never
  pushed, and a reset copies it in again.

  A person's own athanor is minted at admission (`after_sign_in/1`): a
  person needs no registry, no namespace and no claim to have one, and its
  slug is their namespace only when that is already known and free. A
  group is minted as a bare row (`Sanctum.Tenancy.Athanors.create_group/3`)
  and filled the first time something reads its bundle
  (`start_provisioning/1`). Provisioning is idempotent — `provisioned_at`
  marks completion and every step tolerates being repeated — and loud: a
  failure leaves the row unprovisioned with the reason in its settings,
  and the next sign-in tries again.

  The registry pull runs as the person whose sign-in caused it, so their
  pull credential is used; a seed context pulls anonymously, which serves
  public components.

  ## Entry points

  Everything that fills or heals an estate holds the estate's one claim
  row (`Arca.ProvisioningClaims`) while it works: an owner — this boot and
  the attempt's own token, so a restarted boot never resumes another's
  claim — an entry kind, a lease a keeper task renews on a tick, and a
  fence. What differs per entry point is what it does when the claim is
  held:

    * `after_sign_in/1`'s personal fill (`sign_in`): the row, the seat and
      the claim are written on the sign-in; the fill runs in a background
      task under that claim. A held claim means someone is filling
      already, and the sign-in adds nothing. The group retries claim from
      their own task, the same way. No backoff.
    * `start_provisioning/1`, `ready/1` and `status/1` (`first_need`):
      readers never claim and never wait. They read the claim once and
      answer — filled, filling, failed — and start a background fill only
      when nothing holds the claim and no fill failed within the last
      minute. Readers that start one at once coalesce on the claim.
    * `provision/2`, behind the explicit `athanor.provision`
      (`provision`): synchronous; answers `{:error, :provisioning_busy}` at
      once against a held claim. No backoff: a person who asks is never
      told to wait out a failure.
    * `install_shipped/2` (`install_shipped`): synchronous; tries the claim
      once and answers `{:error, :provisioning_busy}` without waiting.
    * `sync_seeds/0` at boot (`seed_sync`): synchronous; waits within a
      bound for the claim, then heals — without the already-filled
      short-circuit, since its job is to offer new seed media to estates
      that are filled — and skips an estate still held past the bound.

  An attempt settles its claim `ready` or `failed`; an install, a sync and
  an attempt that found the estate filled release it. Every write that
  speaks for the attempt is fenced by the claim: readiness is marked only
  after the claim settled `ready`, a failure is recorded only after it
  settled `failed`, and the consent mint and the agent index check the
  claim still reads this owner and fence before they write. An attempt
  whose lease ran out and whose claim a successor took writes none of
  them and answers `{:error, :provisioning_busy}`. An attempt that dies
  is released by its keeper, which monitors it; with the keeper gone too,
  the lease runs out.

  Required dependency pulls run under one deadline per attempt
  (`:provisioning_required_pull_budget_ms`); optional pulls under a
  shorter fixed one. A walk cut short stops where it is: what landed stays
  registered, the failure is recorded on the row, and the next attempt
  finds what is still missing by reading every installed component's
  manifest.
  """

  require Logger

  alias Arca.ProvisioningClaims, as: Claims
  alias Compendium.{AutoIndexer, Pull}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Caps, Members, Users}

  # How long a claim stands without its keeper renewing it, and how often
  # the keeper does.
  @lease_ms 60_000
  @renew_ms 20_000

  # How long a boot's seed sync waits for an estate another attempt holds.
  @sync_wait_ms 30_000
  @sync_poll_ms 250

  @doc """
  Called once the person is admitted, and again whenever their namespace
  is recorded (`Sanctum.SignIn.record_namespace/2`): mints their own
  athanor if they have none, and retries any group of theirs whose
  provisioning failed earlier. Admission is enough — a person needs no
  registry, no namespace and no claim to have a furnace of their own.
  """
  @spec after_sign_in(String.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()} | :pending
  def after_sign_in(user_id) when is_binary(user_id) do
    case Users.get(user_id) do
      {:ok, user} ->
        retry_groups_async(user_id)
        ensure_personal_athanor(user)

      {:error, :not_found} ->
        :pending

      {:error, _} = err ->
        err
    end
  end

  @doc """
  The person's own athanor: the one their `users` row records, else a
  fresh one (kind person, a slug of this server's — their namespace when
  they have one and it is free, otherwise derived from their name — the
  person its only member), provisioned if not yet, and recorded on the
  row. Idempotent.
  """
  @spec ensure_personal_athanor(Arca.Schemas.User.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def ensure_personal_athanor(%{id: user_id} = user) do
    with {:ok, athanor} <- find_or_create_personal(user),
         {:ok, _} <- Members.ensure(user_id, scope: "athanor", athanor_id: athanor.id),
         {:ok, _} <- record_personal(user, athanor) do
      # The row, its seat and the claim are the sign-in's business and are
      # written here; filling it is not, and a sign-in must not wait on a
      # registry. A failure lands on the row and the next read retries.
      # The claim is taken before the task starts, so a reader arriving
      # with the session already finds the estate being filled.
      fill_after_sign_in(athanor, person_ctx(user_id, athanor.id))
      {:ok, athanor}
    end
  end

  defp fill_after_sign_in(%{provisioned_at: %DateTime{}}, _ctx), do: :ok

  defp fill_after_sign_in(%{id: athanor_id} = athanor, ctx) do
    actor = actor(athanor_id)

    with true <- Cyfr.ControlPlane.owner?(),
         {:ok, claim} <- Claims.claim(actor, owner(), "sign_in", @lease_ms) do
      in_background(
        fn -> held(actor, claim, &fill(&1, athanor, ctx)) end,
        fn -> Claims.release(actor, claim.owner, claim.fence) end
      )
    end

    :ok
  end

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
    with_claim(athanor_id, "install_shipped", fn claim ->
      with {:ok, pulled} <- Pull.pull_shipped(ctx, reference),
           {:ok, bootstrap} <- Sanctum.Consent.Bootstrap.run(ctx, claim),
           :ok <- installed_minted(bootstrap, pulled) do
        {:ok, pulled}
      else
        {:error, :claim_lost} -> lost(athanor_id)
        other -> other
      end
    end)
  end

  # What this install answers for is its own consent. The walk covers every
  # source in the athanor, so a skip belonging to another one is that
  # source's business — and `all_minted/1`'s benign reasons (already
  # bootstrapped, not vouched, an agent whose closure is unresolved) are not
  # failures anywhere.
  defp installed_minted(bootstrap, %{component_ref: ref}) do
    case all_minted(bootstrap) do
      :ok ->
        :ok

      {:unminted, unminted} ->
        if Enum.any?(unminted, fn {skipped_ref, _reason} -> same_component?(skipped_ref, ref) end),
           do: {:error, {:consent_not_minted, ref}},
           else: :ok
    end
  end

  defp same_component?(a, b) do
    with {:ok, a_name} <- Cyfr.ComponentRef.to_name_ref(a),
         {:ok, b_name} <- Cyfr.ComponentRef.to_name_ref(b) do
      a_name == b_name
    else
      _ -> a == b
    end
  end

  @doc """
  Whether the context's athanor has been filled.

  The cheap read every consumer of the bundle makes before it reads the
  bundle itself.
  """
  @spec provisioned?(Context.t()) :: boolean()
  def provisioned?(%Context{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    match?({:ok, %{provisioned_at: %DateTime{}}}, Athanors.get(athanor_id))
  end

  def provisioned?(_ctx), do: false

  @doc """
  Start filling the context's athanor if nothing has yet, and answer at
  once — the first-need hook.

  Never waits: provisioning walks the seed overlay and may pull a
  dependency closure over the network, and no request path may hold a page
  open for that. The work is single-flighted per athanor, so a second
  caller finding it already running adds nothing.

  Deliberately **not** called from inside `Arca.Overlay`: `provision/2`
  walks the overlay itself (`register_bundle/1` → `AutoIndexer.scan/1`), so
  a hook down there would re-enter its own scan.
  """
  @spec start_provisioning(Context.t()) :: :ok
  def start_provisioning(%Context{athanor_id: athanor_id} = ctx)
      when is_binary(athanor_id) and athanor_id != "" do
    case Athanors.get(athanor_id) do
      {:ok, %{provisioned_at: %DateTime{}}} ->
        :ok

      {:ok, athanor} ->
        if fill_state(athanor) == :unfilled, do: start_fill(athanor, ctx, "first_need")
        :ok

      _ ->
        :ok
    end
  end

  def start_provisioning(_ctx), do: :ok

  @doc """
  Where the context's athanor stands, read once and answered at once —
  nothing is started and nothing is waited for.

    * `:ready` — filled.
    * `:filling` — an attempt holds the estate's claim.
    * `:failed` — a fill failed within the last minute; no automatic fill
      starts until the minute is out.
    * `:unfilled` — not filled, and nothing in the way of a fill.
    * `:unavailable` — the claim could not be read, or there is no athanor.
  """
  @spec status(Context.t()) :: :ready | :filling | :failed | :unfilled | :unavailable
  def status(%Context{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "" do
    case Athanors.get(athanor_id) do
      {:ok, %{provisioned_at: %DateTime{}}} -> :ready
      {:ok, athanor} -> fill_state(athanor)
      _ -> :unavailable
    end
  end

  def status(_ctx), do: :unavailable

  # How long an automatic fill stays out of the way after one failed.
  @retry_after_failure_ms :timer.minutes(1)

  # An unfilled estate, by its claim. A reader never takes the claim: the
  # fill it may start does, from its own task.
  defp fill_state(%{id: athanor_id} = athanor) do
    case Claims.current(actor(athanor_id)) do
      {:ok, claim} ->
        cond do
          Claims.live?(claim) -> :filling
          recently_failed?(athanor, claim) -> :failed
          true -> :unfilled
        end

      {:error, :not_found} ->
        if recently_failed?(athanor, nil), do: :failed, else: :unfilled

      {:error, _} ->
        :unavailable
    end
  end

  # A fill that failed recorded why on the row, and recording it announces
  # the row changed — which is what a console page reloads on. Without this
  # the reload's reads would start another attempt, fail the same way, and
  # announce again: a loop nobody asked for, from one failure.
  #
  # Only automatic fills back off. `athanor.provision` reaches `provision/2`
  # directly, so a person who asks is never told to wait.
  defp recently_failed?(_athanor, %{outcome: "failed"} = claim),
    do: Claims.age_ms(claim) < @retry_after_failure_ms

  defp recently_failed?(%{provisioning_failed_at: %DateTime{} = failed_at}, _claim),
    do: DateTime.diff(DateTime.utc_now(), failed_at, :millisecond) < @retry_after_failure_ms

  defp recently_failed?(_athanor, _claim), do: false

  @doc """
  Start the fill if needed, and say whether the estate can run a turn yet.

  `:ok` when the athanor is filled, `{:error, :not_provisioned}` while it
  is not — with the work started, so an estate first touched over the wire
  fills without a console ever opening it.

  Reads of the bundle do not use this: the tree reads through the seed
  overlay from the moment the row exists, so a roster is real straight
  away. What a fill adds is the baseline consent a turn pins, which is why
  `Aqua.Runner` is what waits.
  """
  @spec ready(Context.t()) :: :ok | {:error, :not_provisioned}
  def ready(%Context{} = ctx) do
    if provisioned?(ctx) do
      :ok
    else
      start_provisioning(ctx)
      {:error, :not_provisioned}
    end
  end

  @doc """
  Fill an athanor: register the bundle (the scan walking the seed overlay)
  → pull the dependency closure → baseline consents → mark provisioned.
  `acting_ctx` is the person's context focused on the athanor (their pull
  credential); `nil` provisions as the server (anonymous pulls). Returns
  the row either way; a failure is recorded on it and logged.

  Single-flighted per athanor: `provision/2` is idempotent but the closure
  pull is not free, so two callers finding a fresh estate at once would
  each walk it. Everything that fills an athanor comes through here.
  """
  @spec provision(Arca.Schemas.Athanor.t(), Context.t() | nil) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def provision(%{provisioned_at: %DateTime{}} = athanor, _ctx), do: {:ok, athanor}

  def provision(%{id: athanor_id} = athanor, acting_ctx),
    do: with_claim(athanor_id, "provision", &fill(&1, athanor, acting_ctx))

  @doc false
  # One attempt under a claim already taken — what every filling entry
  # point runs once it holds the estate. Public so a test can run an
  # attempt under a claim it took, and lost, itself.
  @spec fill(Arca.Schemas.ProvisioningClaim.t(), Arca.Schemas.Athanor.t(), Context.t() | nil) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def fill(claim, %{id: athanor_id} = athanor, acting_ctx) do
    # Re-read under the claim: the attempt that just held it may have been
    # filling this very athanor.
    case Athanors.get(athanor_id) do
      {:ok, %{provisioned_at: %DateTime{}} = filled} -> {:ok, filled}
      {:ok, fresh} -> do_provision(claim, fresh, acting_ctx)
      _ -> do_provision(claim, athanor, acting_ctx)
    end
  end

  # ---- the claim -------------------------------------------------------------

  # The owner a claim is taken under: this boot, and a token of the
  # attempt's own — never another boot's, and never another attempt's.
  defp owner, do: Cyfr.Boot.id() <> "/" <> Cyfr.UUID7.generate_id("own")

  # The claim is the athanor's, whoever acts: the actor names the tenant
  # and nothing else.
  defp actor(athanor_id), do: Context.actor(seed_ctx(athanor_id))

  # Try the estate's claim once and run `fun` holding it. A held claim is
  # answered as in progress at once, never waited out.
  defp with_claim(athanor_id, entry_kind, fun) do
    actor = actor(athanor_id)

    case Claims.claim(actor, owner(), entry_kind, @lease_ms) do
      {:ok, claim} -> held(actor, claim, fun)
      {:busy, _claim} -> {:error, :provisioning_busy}
      {:error, _} = error -> error
    end
  end

  # Run `fun` under a claim this process now answers for: a keeper renews
  # the lease while it runs, and whatever `fun` did not settle is released
  # when it ends — when the attempt ends, not when the process does, since
  # one task fills several estates in turn (a sign-in retries a person's
  # groups).
  defp held(actor, claim, fun) do
    keeper = keep(actor, claim)

    try do
      fun.(claim)
    after
      if keeper, do: send(keeper, :stop)
      Claims.release(actor, claim.owner, claim.fence)
    end
  end

  # The keeper renews the lease on a tick and watches the attempt: an
  # attempt killed where it stands runs no `after`, so the keeper is what
  # releases its claim. A renewal refused as stale means a successor holds
  # the estate, and the keeper has nothing left to keep.
  defp keep(actor, claim) do
    attempt = self()

    case Task.Supervisor.start_child(Sanctum.ProvisioningSupervisor, fn ->
           keep_loop(actor, claim, Process.monitor(attempt))
         end) do
      {:ok, keeper} ->
        keeper

      {:error, reason} ->
        Logger.warning("[Provisioning] lease keeper not started: #{inspect(reason)}")
        nil
    end
  end

  defp keep_loop(actor, claim, ref) do
    receive do
      :stop ->
        :ok

      {:DOWN, ^ref, :process, _attempt, _reason} ->
        Claims.release(actor, claim.owner, claim.fence)
    after
      @renew_ms ->
        case Claims.renew(actor, claim.owner, claim.fence, @lease_ms) do
          :ok -> keep_loop(actor, claim, ref)
          _ -> :ok
        end
    end
  end

  # Whether the claim still reads this attempt's owner and fence, asked
  # before a write the claim's own settle cannot carry.
  defp holding(actor, claim) do
    case Claims.current(actor) do
      {:ok, %{owner: owner, fence: fence, outcome: nil}}
      when owner == claim.owner and fence == claim.fence ->
        :ok

      _ ->
        {:error, :claim_lost}
    end
  end

  # An attempt whose claim a successor took: it marks nothing and records
  # nothing, and the estate is the successor's — in progress, not failed.
  defp lost(athanor_id) do
    Logger.warning("[Provisioning] #{athanor_id}: claim lost to a later attempt; nothing written")
    {:error, :provisioning_busy}
  end

  # A background fill through `entry_kind`, claimed from its own task.
  # Several readers ask on one page load; each task that finds the claim
  # held adds nothing and ends.
  defp start_fill(%{id: athanor_id} = athanor, ctx, entry_kind) do
    in_background(fn -> with_claim(athanor_id, entry_kind, &fill(&1, athanor, ctx)) end)
  end

  defp do_provision(claim, %{id: athanor_id} = athanor, acting_ctx) do
    ctx = acting_ctx || seed_ctx(athanor_id)
    actor = actor(athanor_id)

    # The agents are indexed before the consents are minted: an agent is a
    # consent source, and its revision bytes are registered by the index
    # before any consent names it.
    with :ok <- Arca.ensure_roots(seed_ctx(athanor_id)),
         {:ok, _scan} <- register_bundle(athanor_id),
         :ok <- aqua_definitions(athanor_id),
         :ok <- holding(actor, claim),
         :ok <- index_agents(ctx),
         {:ok, closure} <- pull_required_deps(ctx),
         optional <- pull_optional_deps(ctx),
         {:ok, bootstrap} <- Sanctum.Consent.Bootstrap.run(ctx, claim),
         :ok <- all_minted(bootstrap),
         :ok <- settled(actor, claim, "ready", nil) do
      Logger.info(
        "[Provisioning] #{athanor_id} provisioned " <>
          "(pulled #{length(closure.pulled)} required and #{optional} optional, " <>
          "minted #{length(bootstrap.minted)})"
      )

      # The estate's own topic, the kind every console subscriber already
      # re-reads the row on: a page rendering "still being prepared" clears
      # itself rather than waiting for a reload. Only when the mark landed —
      # announcing a fill that did not finish would have every listener read
      # the bundle again and start another attempt.
      case Athanors.mark_provisioned(athanor) do
        {:ok, filled} ->
          Sanctum.Notify.broadcast(athanor_id, :athanor_changed, %{name: filled.name})
          {:ok, filled}

        {:error, _} = error ->
          Logger.error("[Provisioning] #{athanor_id} filled but not marked: #{inspect(error)}")
          error
      end
    else
      {:error, :claim_lost} ->
        lost(athanor_id)

      {:error, {:closure, detail}} ->
        record_failure(claim, athanor, :closure, detail)

      {:error, {:aqua_template, _} = reason} ->
        record_failure(claim, athanor, :aqua_template, reason)

      {:error, reason} ->
        record_failure(claim, athanor, :seed, reason)

      {:unminted, skipped} ->
        record_failure(claim, athanor, :bootstrap, skipped)
    end
  end

  # The claim's own verdict, written only while this attempt still holds
  # it. What follows a verdict — the mark, the failure record — is written
  # only once it landed.
  defp settled(actor, claim, outcome, detail) do
    case Claims.settle(actor, claim.owner, claim.fence, outcome, detail) do
      :ok -> :ok
      :stale -> {:error, :claim_lost}
      {:error, _} = error -> error
    end
  end

  # ---- internal --------------------------------------------------------------

  # The row exists whether or not provisioning succeeded: the caller gets
  # it either way (a failure is on the row's settings and in the log), and a
  # later sign-in or focus retries.
  # The estate's agents as rows, derived from the tree the seed just
  # filled or the release just moved. Never provisioning's failure.
  defp index_agents(ctx) do
    case Compendium.AgentIndex.sync(ctx) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Provisioning] agent index not synced: #{inspect(reason)}")
    end
  end

  # A person's unprovisioned groups are retried with their credential — off
  # the sign-in path, since each retry may pull from the registry, and a
  # sign-in must not hang on an unreachable one. Bounded per sign-in; a
  # failure lands on the group's row and the next sign-in (or a member's
  # `athanor.provision`) tries again.
  @retry_groups_per_sign_in 5

  defp retry_groups_async(user_id) do
    pending =
      Athanors.list_for_user(user_id)
      |> Enum.filter(&match?(%{kind: "group", provisioned_at: nil}, &1))
      |> Enum.take(@retry_groups_per_sign_in)

    if pending != [] do
      in_background(fn ->
        Enum.each(pending, fn group ->
          with_claim(group.id, "sign_in", &fill(&1, group, person_ctx(user_id, group.id)))
        end)
      end)
    end

    :ok
  end

  # A fill runs only on the boot that owns the control plane; elsewhere it
  # is not started, and the next read on the owner starts it. Under test
  # the sandbox owns the connection, so background work runs inline (the
  # tests assert on rows right after the call). `not_started` runs when the
  # work will not: what a caller took for it beforehand is given back.
  defp in_background(fun, not_started \\ fn -> :ok end) do
    cond do
      not Cyfr.ControlPlane.owner?() ->
        not_started.()
        :ok

      Application.get_env(:cyfr, :provisioning_inline, false) ->
        fun.()
        :ok

      true ->
        logger_metadata = Cyfr.LoggerContext.capture()

        task_fun = fn ->
          Cyfr.LoggerContext.restore(logger_metadata)
          fun.()
        end

        case Task.Supervisor.start_child(Sanctum.ProvisioningSupervisor, task_fun) do
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

  # One personal athanor per owner is the store's invariant, so the owner
  # is the lookup; a person with none yet is minted one. The slug is an
  # address on this server, never an identity: the namespace is only a
  # hint for it.
  defp find_or_create_personal(%{id: user_id} = user) do
    case Athanors.get_by_owner(user_id) do
      {:ok, athanor} -> {:ok, athanor}
      {:error, :not_found} -> mint_personal(user)
      {:error, _} = err -> err
    end
  end

  # An operator's own athanor is minted past the server caps
  # (`Athanors.create_for_operator/1`): they are named in
  # `CYFR_PLATFORM_ADMIN_EMAILS` rather than arriving, and a server at
  # capacity must still admit the person who can act on it. Everyone else
  # is a stranger arriving and is capped — `CYFR_MINT_PER_HOUR` is exactly
  # how fast that may happen, and `mint_allowed/0` is its only enforcement,
  # so a refusal here must reach the door rather than being swallowed.
  defp mint_personal(%{id: user_id} = user) do
    name = personal_name(user)

    attrs_for = fn slug ->
      %{kind: "person", name: name, slug: slug, owner_user_id: user_id, created_by: user_id}
    end

    if Sanctum.Tenancy.platform_admin?(user_id) do
      with {:ok, slug} <- Athanors.person_slug(user.namespace, name) do
        Athanors.create_for_operator(attrs_for.(slug))
      end
    else
      with :ok <- mint_allowed(),
           {:ok, slug} <- Athanors.person_slug(user.namespace, name) do
        Athanors.create(attrs_for.(slug))
      end
    end
  end

  # What the athanor is called: the person's screen name, else the
  # address's local part, else the namespace, else a plain word.
  defp personal_name(user) do
    cond do
      is_binary(user.display_name) and String.trim(user.display_name) != "" ->
        String.trim(user.display_name)

      is_binary(user.email) and String.contains?(user.email, "@") ->
        user.email |> String.split("@") |> hd()

      is_binary(user.namespace) ->
        user.namespace

      true ->
        "Me"
    end
  end

  defp record_personal(%{personal_athanor_id: id} = user, %{id: id}), do: {:ok, user}
  defp record_personal(user, athanor), do: Users.set_personal_athanor(user, athanor.id)

  # The mint rate is a per-server cap on personal athanors minted per
  # hour. `check_counted/2` counts only while the cap is on, and refuses
  # (never admits) when the count cannot be answered.
  defp mint_allowed do
    Caps.check_counted(:mint_per_hour, fn ->
      Athanors.count_created_since(DateTime.add(DateTime.utc_now(), -3600))
    end)
  end

  # The person's own context, focused on the new athanor: their pull
  # credential, their attribution on the minted consents.
  #
  # Permissions are stated explicitly per `Context.for_scheduled/2`'s
  # convention — never `[:*]`, so what provisioning runs with is visible
  # here and cannot silently widen. The path performs storage acts only
  # (the seed scan, registration rows, registry pulls into `components/`);
  # it never executes a component, and the consent bootstrap mints via
  # `granted_via: "bootstrap"`, not through the consent surface gates.
  # `auth_method: :oidc` records provenance honestly — this context exists
  # because of the person's OIDC sign-in; no gate on this path requires
  # the interactive class.
  defp person_ctx(user_id, athanor_id) do
    Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: [:storage_read, :storage_write],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp seed_ctx(athanor_id) do
    Sanctum.internal_context(user_id: "_seed", athanor_id: athanor_id, scope: :athanor)
  end

  # The bundle copied in and registered as rows: every shipped version
  # directory the athanor does not hold is copied from the seed
  # (`Arca.Overlay.materialize_shipped/2`), then the scan walks the
  # athanor's `components/` and mints a row per version directory. An
  # install without its bundle cannot provision anyone; say so rather than
  # minting an empty athanor.
  defp register_bundle(athanor_id) do
    ctx = seed_ctx(athanor_id)

    with :ok <- bundle_present(ctx),
         {:ok, _copied} <- Arca.Overlay.materialize_shipped(ctx, "components") do
      # A component that fails registration is logged by the scan and
      # skipped; the consent bootstrap's `all_minted` is the gate that
      # decides whether what registered is enough to provision. A
      # discovery outage is the scan's own typed error and fails the
      # provisioning step loudly.
      AutoIndexer.scan(ctx: ctx)
    end
  end

  defp bundle_present(ctx) do
    case Arca.list_recursive(ctx, Arca.Storage.seed_prefix("components")) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :bundle_missing}
      {:error, reason} -> {:error, {:bundle_unreadable, reason}}
    end
  end

  # The shipped AQUA tree, checked well-formed first (a v2-shaped or empty
  # mount fails loud here, at the one moment an operator is watching,
  # instead of as an empty roster later), then copied into the athanor's
  # `aqua/` — every shipped unit it does not yet hold.
  defp aqua_definitions(athanor_id) do
    with :ok <- Compendium.AquaTemplate.seed_check(),
         {:ok, _copied} <- Arca.Overlay.materialize_shipped(seed_ctx(athanor_id), "aqua") do
      :ok
    else
      {:error, reason} -> {:error, {:aqua_template, reason}}
    end
  end

  @doc """
  Make every provisioned athanor whole against the seed media a release
  shipped — without changing what the athanor chose. A shipped version a
  row names but the tree no longer holds is copied back; an athanor
  without its shipped soul gets the shipped AQUA tree; the bundle's
  published dependencies are re-pulled and baseline consents minted for
  any row still without one. Newer shipped versions are NOT copied in:
  they read as available until a person pulls them, so an upgrade never
  changes an estate under its members.

  Runs at boot (`Cyfr.Bootstrap`); a failure logs and moves on — a sync
  must never take the server down or block another athanor's.
  """
  @spec sync_seeds() :: :ok
  def sync_seeds do
    for athanor <- Athanors.list_active(), not is_nil(athanor.provisioned_at) do
      # The same claim every fill takes, so a boot healing an estate and an
      # install or a retry cannot walk one estate at once. Not `provision/2`:
      # this runs on athanors that are already filled, which is exactly what
      # that function short-circuits. The sync has no one to answer to, so
      # it waits out an attempt in progress — within a bound, since one
      # held estate must not keep the boot from the next.
      actor = actor(athanor.id)

      case wait_for_claim(actor, owner(), now_ms() + @sync_wait_ms) do
        {:ok, claim} ->
          held(actor, claim, &sync_seed(athanor, &1))

        {:error, reason} ->
          Logger.warning("[Provisioning] #{athanor.id}: seed sync skipped — #{inspect(reason)}")
      end
    end

    :ok
  end

  defp wait_for_claim(actor, owner, deadline) do
    case Claims.claim(actor, owner, "seed_sync", @lease_ms) do
      {:ok, claim} ->
        {:ok, claim}

      {:busy, _claim} ->
        if now_ms() < deadline do
          Process.sleep(@sync_poll_ms)
          wait_for_claim(actor, owner, deadline)
        else
          {:error, :provisioning_busy}
        end

      {:error, _} = error ->
        error
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp sync_seed(athanor, claim) do
    ctx = seed_ctx(athanor.id)

    case Arca.ensure_roots(ctx) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Provisioning] #{athanor.id}: roots — #{inspect(reason)}")
    end

    heal_shipped(ctx, athanor.id)

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
    case pull_required_deps(ctx) do
      {:ok, _closure} ->
        :ok

      {:error, {:closure, detail}} ->
        Logger.warning(
          "[Provisioning] #{athanor.id}: dep pull after sync failed: #{inspect(detail)}"
        )
    end

    _ = pull_optional_deps(ctx)

    # The index and the mint speak for the estate, so they are this sync's
    # only while the claim is.
    case holding(actor(athanor.id), claim) do
      :ok ->
        index_agents(ctx)
        bootstrap_synced(ctx, claim, athanor.id)

      {:error, :claim_lost} ->
        lost(athanor.id)
    end

    :ok
  end

  # What the athanor already chose, restored: a shipped version its rows
  # name but its tree lacks, and the shipped AQUA tree when it holds no
  # AQUA unit at all. A newer shipped version with no row is left available.
  defp heal_shipped(ctx, athanor_id) do
    with {:ok, statuses} <- Arca.Overlay.unit_statuses(ctx, "components"),
         {:ok, rows} <- Arca.ComponentStorage.list_components(ctx, limit: :none) do
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
        case Arca.Overlay.pull_shipped(ctx, unit) do
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

    case Arca.Overlay.unit_statuses(ctx, "aqua") do
      {:ok, statuses} ->
        held? = Enum.any?(statuses, fn {_unit, status} -> status != :available end)

        if not held? and statuses != %{} do
          case Arca.Overlay.materialize_shipped(ctx, "aqua") do
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
    case Sanctum.Consent.Bootstrap.run(ctx, claim) do
      {:error, :claim_lost} ->
        lost(athanor_id)

      {:ok, %{minted: minted, revised: revised}} when minted != [] or revised != [] ->
        Logger.info(
          "[Provisioning] #{athanor_id}: baseline consents minted for " <>
            "[#{Enum.join(minted, ", ")}], re-minted for [#{Enum.join(revised, ", ")}]"
        )

      {:ok, _nothing_new} ->
        :ok
    end
  end

  # The bundle's required dependencies — everything a local component
  # declares it cannot run without — pulled under the attempt's deadline.
  # A pull that fails, times out or exits is a provisioning failure at the
  # closure step, retried by the next attempt.
  defp pull_required_deps(ctx) do
    budget_ms = Application.fetch_env!(:cyfr, :provisioning_required_pull_budget_ms)

    case bounded_pull(ctx, missing_bundle_deps(ctx, :required), budget_ms) do
      {:ok, %{failed: []} = closure} -> {:ok, closure}
      {:ok, %{failed: failed}} -> {:error, {:closure, failed}}
      :timeout -> {:error, {:closure, {:timeout, budget_ms}}}
      {:exit, reason} -> {:error, {:closure, {:exit, reason}}}
    end
  end

  # The bundle's optional dependencies — the model catalysts — are pulled
  # when a registry is configured to pull them from, as a courtesy with a
  # budget: a registry that is slow, unreachable or unset-by-default and
  # absent leaves the estate provisioned on what the bundle ships, its
  # activations covering what is there, and the catalysts arrive when a
  # model is connected. An optional dependency that fails to pull is never
  # a provisioning failure.
  @optional_pull_budget_ms 10_000

  defp pull_optional_deps(ctx) do
    optional =
      if Compendium.RegistryHost.configured?(),
        do: missing_bundle_deps(ctx, :all) -- missing_bundle_deps(ctx, :required),
        else: []

    case bounded_pull(ctx, optional, @optional_pull_budget_ms) do
      {:ok, %{pulled: pulled, failed: []}} ->
        length(pulled)

      {:ok, %{pulled: pulled, failed: failed}} ->
        Logger.warning(
          "[Provisioning] #{length(failed)} optional dependencies not pulled " <>
            "(#{inspect(Enum.map(failed, &elem(&1, 0)))}); the estate provisions without them"
        )

        length(pulled)

      :timeout ->
        Logger.warning(
          "[Provisioning] optional dependencies not pulled within " <>
            "#{@optional_pull_budget_ms} ms; the estate provisions without them"
        )

        0

      {:exit, reason} ->
        Logger.warning(
          "[Provisioning] optional dependency pull exited (#{inspect(reason)}); " <>
            "the estate provisions without them"
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
  defp bounded_pull(_ctx, [], _budget_ms), do: {:ok, %{pulled: [], failed: [], present: []}}

  defp bounded_pull(ctx, refs, budget_ms) do
    task =
      Task.Supervisor.async_nolink(Sanctum.ProvisioningSupervisor, fn ->
        Pull.ensure_published_deps(ctx, refs)
      end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> {:ok, outcome}
      {:exit, reason} -> {:exit, reason}
      nil -> :timeout
    end
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
    case Arca.ComponentStorage.list_components(ctx, limit: :none) do
      {:ok, rows} ->
        rows
        |> Enum.flat_map(&Pull.missing_deps(ctx, &1, include: include))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # Every vouched local source must hold a consent. A skip for "already
  # bootstrapped" or "not vouched" (a member-authored or edited source)
  # is not a provisioning failure: those consent through the walk. An
  # agent whose closure the bundle does not resolve is re-minted by a
  # later sync once it does.
  defp all_minted(%{skipped: skipped}) do
    case Enum.reject(skipped, fn {ref, reason} ->
           reason in [:already_bootstrapped, :not_vouched] or
             Compendium.AgentSource.agent_ref?(ref)
         end) do
      [] -> :ok
      unminted -> {:unminted, unminted}
    end
  end

  # The claim settles `failed` first, and the row records the failure only
  # once that landed: an attempt whose claim a successor took leaves the
  # successor's record alone.
  defp record_failure(claim, athanor, step, detail) do
    case settled(actor(athanor.id), claim, "failed", "#{step}: #{inspect(detail)}") do
      :ok ->
        Logger.warning(
          "[Provisioning] #{athanor.id} not provisioned at #{step}: #{inspect(detail)}"
        )

        :telemetry.execute([:cyfr, :sanctum, :provisioning, :failed], %{count: 1}, %{
          athanor_id: athanor.id,
          step: step
        })

        Athanors.record_provisioning_failure(athanor, step, inspect(detail))

        {:error, {:provisioning_failed, step, detail}}

      {:error, :claim_lost} ->
        lost(athanor.id)

      {:error, reason} ->
        # The claim could not be read, so whether this attempt still holds
        # it is unknown: the row is left as it is.
        Logger.error(
          "[Provisioning] #{athanor.id} not provisioned at #{step} (#{inspect(detail)}), " <>
            "and the failure not recorded: #{inspect(reason)}"
        )

        {:error, {:provisioning_failed, step, detail}}
    end
  end
end
