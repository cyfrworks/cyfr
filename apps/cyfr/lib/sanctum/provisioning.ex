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

  Every fill shares one per-athanor lock (`Arca.Overlay.UnitLock`, keyed
  `{athanor_id, :provisioning}`); background attempts also hold a claim in
  `Sanctum.ProvisioningRegistry`, so concurrent first needs coalesce on
  one attempt instead of queueing behind the lock. Both are node-local.

    * `start_provisioning/1`, and `ready/1` on an unfilled estate:
      asynchronous; claim, then lock; stands off for a minute after a
      recorded failure.
    * `after_sign_in/1`'s personal fill and group retries: asynchronous;
      claim, then lock; no backoff.
    * `provision/2`, behind the explicit `athanor.provision`: synchronous;
      no claim of its own. Answers `{:error, :provisioning_busy}` at once
      while a background attempt holds the claim, and after a bounded
      wait when the lock is held otherwise.
    * `sync_seeds/0` at boot: synchronous; lock only, and without the
      already-filled short-circuit, since its job is to offer new seed
      media to estates that are filled.

  Required dependency pulls run under one deadline per attempt
  (`:provisioning_required_pull_budget_ms`); optional pulls under a
  shorter fixed one. A walk cut short stops where it is: what landed stays
  registered, the failure is recorded on the row, and the next attempt
  finds what is still missing by reading every installed component's
  manifest.
  """

  require Logger

  alias Compendium.{AutoIndexer, Pull}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Caps, Members, Users}

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
      # The row and its seat are the sign-in's business and are written
      # here; filling it is not, and a sign-in must not wait on a registry.
      # A failure lands on the row and the next read retries. Claimed like
      # every other filler, so a reader arriving mid-fill joins it rather
      # than queueing a second attempt behind the same lock.
      in_background(fn -> claim_and_provision(athanor, person_ctx(user_id, athanor.id)) end)
      {:ok, athanor}
    end
  end

  # How long any caller waits for another already filling this athanor.
  # Nothing waits on a request path now, so this bounds contention between
  # a background fill and an explicit retry rather than a page's mount.
  @lock_wait_ms 30_000

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
  def install_shipped(%Context{} = ctx, reference) when is_binary(reference) do
    with {:ok, pulled} <- Pull.pull_shipped(ctx, reference),
         {:ok, _bootstrap} <- Sanctum.Consent.Bootstrap.run(ctx) do
      {:ok, pulled}
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
        unless recently_failed?(athanor) do
          in_background(fn -> claim_and_provision(athanor, ctx) end)
        end

        :ok

      _ ->
        :ok
    end
  end

  def start_provisioning(_ctx), do: :ok

  # How long an automatic fill stays out of the way after one failed.
  @retry_after_failure_ms :timer.minutes(1)

  # A fill that failed recorded why on the row, and recording it announces
  # the row changed — which is what a console page reloads on. Without this
  # the reload's reads would start another attempt, fail the same way, and
  # announce again: a loop nobody asked for, from one failure.
  #
  # Only automatic fills back off. `athanor.provision` reaches `provision/2`
  # directly, so a person who asks is never told to wait.
  # `settings` is a document members write through `athanor.settings`, so
  # nothing here may assume the shape provisioning left: anything that is
  # not a timestamp reads as "no recent failure", and the next attempt
  # replaces it with one that is.
  defp recently_failed?(athanor) do
    with %{"at" => at} when is_binary(at) <- Athanors.settings(athanor)["provisioning_error"],
         {:ok, failed_at, _} <- DateTime.from_iso8601(at) do
      DateTime.diff(DateTime.utc_now(), failed_at, :millisecond) < @retry_after_failure_ms
    else
      _ -> false
    end
  end

  @doc """
  Start the fill if needed, and say whether the estate can run a turn yet.

  `:ok` when the athanor is filled, `{:error, :not_provisioned}` while it
  is not — with the work started, so an estate first touched over the wire
  fills without a console ever opening it.

  Reads of the bundle do not use this: the tree reads through the seed
  overlay from the moment the row exists, so a roster is real straight
  away. What a fill adds is the baseline consent a turn pins, which is why
  `Aqua.Turn.begin/5` is what waits.
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

  def provision(%{id: athanor_id} = athanor, acting_ctx) do
    if filling_elsewhere?(athanor_id) do
      {:error, :provisioning_busy}
    else
      with_provisioning_lock(athanor_id, fn ->
        # Re-read inside the lock: the caller that just held it may have been
        # filling this very athanor.
        case Athanors.get(athanor_id) do
          {:ok, %{provisioned_at: %DateTime{}} = filled} -> {:ok, filled}
          {:ok, fresh} -> do_provision(fresh, acting_ctx)
          _ -> do_provision(athanor, acting_ctx)
        end
      end)
    end
  end

  # Whether another process holds this athanor's claim. An attempt that is
  # already doing the work is answered as in progress, not waited out; the
  # caller's own claim (`claim_and_provision/2` reaches here holding it) is
  # not contention.
  defp filling_elsewhere?(athanor_id) do
    Sanctum.ProvisioningRegistry
    |> Registry.lookup(athanor_id)
    |> Enum.any?(fn {pid, _value} -> pid != self() end)
  end

  # One attempt per athanor at a time, and the only way a fill is started.
  # Several readers ask on one page load, and a sign-in fills the estate it
  # just minted; without this each would start a task that waits out the
  # lock and then repeats work another attempt already did — or already
  # failed. A caller that finds an attempt running adds nothing and says so.
  #
  # The lock still serializes what the claim lets through: `sync_seeds/0`
  # takes it for estates that are already filled, which is not an attempt.
  defp claim_and_provision(%{id: athanor_id} = athanor, ctx) do
    case Registry.register(Sanctum.ProvisioningRegistry, athanor_id, :filling) do
      {:ok, _} ->
        # Released when this attempt ends, not when the process does: one
        # task fills several estates in turn (a sign-in retries a person's
        # groups), and a key held past its own attempt would keep the next
        # caller out of an estate nobody is filling.
        try do
          provision(athanor, ctx)
        after
          Registry.unregister(Sanctum.ProvisioningRegistry, athanor_id)
        end

      {:error, {:already_registered, _}} ->
        {:error, :provisioning_busy}
    end
  end

  # The lock every filler shares. `sync_seeds/0` takes it too, but not
  # `provision/2`'s already-filled short-circuit above: its whole job is to
  # offer new seed media to estates that ARE filled.
  defp with_provisioning_lock(athanor_id, fun) do
    case Arca.Overlay.UnitLock.with_lock({athanor_id, :provisioning}, fun, @lock_wait_ms) do
      {:error, :unit_locked} ->
        Logger.warning("[Provisioning] #{athanor_id} is already being filled by another caller")
        {:error, :provisioning_busy}

      result ->
        result
    end
  end

  defp do_provision(%{id: athanor_id} = athanor, acting_ctx) do
    ctx = acting_ctx || seed_ctx(athanor_id)

    with :ok <- Arca.ensure_roots(seed_ctx(athanor_id)),
         {:ok, _scan} <- register_bundle(athanor_id),
         :ok <- aqua_definitions(athanor_id),
         {:ok, closure} <- pull_required_deps(ctx),
         optional <- pull_optional_deps(ctx),
         {:ok, bootstrap} <- Sanctum.Consent.Bootstrap.run(ctx),
         :ok <- all_minted(bootstrap) do
      Logger.info(
        "[Provisioning] #{athanor_id} provisioned " <>
          "(pulled #{length(closure.pulled)} required and #{optional} optional, " <>
          "minted #{length(bootstrap.minted)})"
      )

      index_agents(ctx)

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
      {:error, {:closure, detail}} ->
        record_failure(athanor, :closure, detail)

      {:error, {:aqua_template, _} = reason} ->
        record_failure(athanor, :aqua_template, reason)

      {:error, reason} ->
        record_failure(athanor, :seed, reason)

      {:unminted, skipped} ->
        record_failure(athanor, :bootstrap, skipped)
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
          claim_and_provision(group, person_ctx(user_id, group.id))
        end)
      end)
    end

    :ok
  end

  # Under test the sandbox owns the connection, so background work runs
  # inline (the tests assert on rows right after the call).
  defp in_background(fun) do
    if Application.get_env(:cyfr, :provisioning_inline, false) do
      fun.()
      :ok
    else
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
      # The same lock every fill takes, so a boot healing an estate and a
      # first-need fill cannot walk one estate at once. Not `provision/2`:
      # this runs on athanors that are already filled, which is exactly what
      # that function short-circuits.
      with_provisioning_lock(athanor.id, fn -> sync_seed(athanor) end)
    end

    :ok
  end

  defp sync_seed(athanor) do
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

    bootstrap_synced(ctx, athanor.id)
    index_agents(ctx)
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
  # `skipped`, so only what the release just added mints anything.
  defp bootstrap_synced(ctx, athanor_id) do
    case Sanctum.Consent.Bootstrap.run(ctx) do
      {:ok, %{minted: [_ | _] = minted}} ->
        Logger.info(
          "[Provisioning] #{athanor_id}: minted baseline consents for #{Enum.join(minted, ", ")}"
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
  # deadline the task is killed where it is — inside the lock, so the
  # attempt has stopped before any coordination is released. The
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

  # Every executable local component must hold a consent; a skip for any
  # reason other than "already bootstrapped" is a provisioning failure.
  defp all_minted(%{skipped: skipped}) do
    case Enum.reject(skipped, &match?({_, :already_bootstrapped}, &1)) do
      [] -> :ok
      unminted -> {:unminted, unminted}
    end
  end

  defp record_failure(athanor, step, detail) do
    Logger.warning("[Provisioning] #{athanor.id} not provisioned at #{step}: #{inspect(detail)}")

    :telemetry.execute([:cyfr, :sanctum, :provisioning, :failed], %{count: 1}, %{
      athanor_id: athanor.id,
      step: step
    })

    Athanors.put_settings(athanor, %{
      "provisioning_error" => %{
        "step" => to_string(step),
        "detail" => inspect(detail),
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })

    {:error, {:provisioning_failed, step, detail}}
  end
end
