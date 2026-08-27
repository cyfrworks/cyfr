# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Provisioning do
  @moduledoc """
  What turns an athanor row into a working athanor: the seed bundle
  registered as rows (its bytes stay in the seed tree — `Arca.Overlay`
  reads them through the athanor's `components/` until a write
  materializes a copy), the AQUA agent definitions checked well-formed
  (never copied — the overlay serves the shipped template in place), the
  published components the bundle depends on pulled from the registry,
  and a baseline consent minted for every executable local component —
  so the athanor's AQUA answers from the first prompt.

  A person's own athanor is minted here on their first admitted sign-in
  (`after_sign_in/1`, once their cyfr.run namespace is known — the athanor's
  slug is the namespace); a group's when a member creates it
  (`ensure_group_athanor/3`); Home at boot (`Cyfr.Bootstrap`). Provisioning
  is idempotent — `provisioned_at` marks completion and every step tolerates
  being repeated — and loud: a failure leaves the row unprovisioned with the
  reason in its settings, and the next sign-in tries again.

  The registry pull runs as the person whose sign-in caused it, so their
  pull credential is used; a server-side mint (Home at boot) pulls
  anonymously, which serves public components.
  """

  require Logger

  alias Compendium.{AutoIndexer, Pull}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Caps, Members, Users}

  @doc """
  Called once the person is admitted and whenever their namespace is
  recorded (`Sanctum.SignIn.record_namespace/2`): mints their own athanor,
  and retries any group of theirs whose provisioning failed earlier. A
  person without a namespace yet (the claim gate is ahead of them) gets
  theirs on the next call.
  """
  @spec after_sign_in(String.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()} | :pending
  def after_sign_in(user_id) when is_binary(user_id) do
    case Users.get(user_id) do
      {:ok, user} ->
        retry_groups_async(user_id)

        case user.namespace do
          nil -> :pending
          _ -> ensure_personal_athanor(user)
        end

      {:error, :not_found} ->
        :pending

      {:error, _} = err ->
        err
    end
  end

  @doc """
  The person's own athanor: created (kind person, slug = namespace, the
  person its only member) if missing, provisioned if not yet, and recorded
  on the `users` row. Idempotent.
  """
  @spec ensure_personal_athanor(Arca.Schemas.User.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def ensure_personal_athanor(%{namespace: nil}), do: {:error, :no_namespace}

  def ensure_personal_athanor(%{id: user_id, namespace: namespace} = user) do
    with {:ok, athanor} <- find_or_create_personal(user_id, namespace, user.display_name),
         {:ok, _} <- Members.ensure(user_id, scope: "athanor", athanor_id: athanor.id),
         {:ok, _} <- record_personal(user, athanor) do
      row_after(provision(athanor, person_ctx(user_id, athanor.id)), athanor)
    end
  end

  @doc """
  Home is provisioned at boot as the server, pulling anonymously; when that
  failed (the registry was unreachable, or a bundled dependency is not
  public), the operator's first sign-in retries it with their own credential.
  """
  @spec retry_home(String.t()) :: {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def retry_home(user_id) when is_binary(user_id) do
    with {:ok, home} <- Athanors.home() do
      provision(home, person_ctx(user_id, home.id))
    end
  end

  @doc """
  `retry_home/1` off the sign-in path: a boot that could not reach the
  registry is retried with the operator's credential without holding their
  sign-in on the pull. The outcome lands on Home's row.
  """
  @spec retry_home_async(String.t()) :: :ok
  def retry_home_async(user_id) when is_binary(user_id) do
    case Athanors.home() do
      {:ok, %{provisioned_at: nil}} -> in_background(fn -> retry_home(user_id) end)
      _ -> :ok
    end
  end

  @doc """
  Mint a group athanor for the caller and provision it before answering —
  the group is usable the moment it exists.
  """
  @spec ensure_group_athanor(Context.t(), String.t(), keyword()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def ensure_group_athanor(%Context{user_id: user_id} = ctx, name, opts \\ []) do
    with {:ok, athanor} <- Athanors.create_group(user_id, name, opts) do
      focused = %{ctx | athanor_id: athanor.id, scope: :athanor}
      row_after(provision(athanor, focused), athanor)
    end
  end

  @doc """
  Fill an athanor: register the bundle (the scan walking the seed overlay)
  → pull the dependency closure → baseline consents → mark provisioned.
  `acting_ctx` is the person's context focused on the athanor (their pull
  credential); `nil` provisions as the server (anonymous pulls). Returns
  the row either way; a failure is recorded on it and logged.
  """
  @spec provision(Arca.Schemas.Athanor.t(), Context.t() | nil) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def provision(%{provisioned_at: %DateTime{}} = athanor, _ctx), do: {:ok, athanor}

  def provision(%{id: athanor_id} = athanor, acting_ctx) do
    ctx = acting_ctx || seed_ctx(athanor_id)

    with {:ok, _scan} <- register_bundle(athanor_id),
         :ok <- aqua_definitions(ctx),
         %{failed: []} = closure <- Pull.ensure_published_deps(ctx, missing_bundle_deps(ctx)),
         {:ok, bootstrap} <- Sanctum.Consent.Bootstrap.run(ctx),
         :ok <- all_minted(bootstrap) do
      Logger.info(
        "[Sanctum.Provisioning] #{athanor_id} provisioned " <>
          "(pulled #{length(closure.pulled)}, minted #{length(bootstrap.minted)})"
      )

      Athanors.mark_provisioned(athanor)
    else
      %{failed: failed} ->
        record_failure(athanor, :closure, failed)

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
  defp row_after({:ok, athanor}, _), do: {:ok, athanor}

  defp row_after({:error, _}, athanor) do
    case Athanors.get(athanor.id) do
      {:ok, current} -> {:ok, current}
      _ -> {:ok, athanor}
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
        Enum.each(pending, fn group -> provision(group, person_ctx(user_id, group.id)) end)
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
      {:ok, _pid} = Task.Supervisor.start_child(Sanctum.ProvisioningSupervisor, fun)
      :ok
    end
  end

  defp find_or_create_personal(user_id, namespace, display_name) do
    case Athanors.get_by_slug("person", namespace) do
      {:ok, %{owner_user_id: ^user_id} = athanor} ->
        {:ok, athanor}

      {:ok, _other_owner} ->
        {:error, :namespace_owned_by_another_identity}

      {:error, :not_found} ->
        with :ok <- mint_allowed() do
          Athanors.create(%{
            kind: "person",
            name: display_name || namespace,
            slug: namespace,
            owner_user_id: user_id,
            created_by: user_id
          })
        end

      {:error, _} = err ->
        err
    end
  end

  defp record_personal(%{personal_athanor_id: id} = user, %{id: id}), do: {:ok, user}
  defp record_personal(user, athanor), do: Users.set_personal_athanor(user, athanor.id)

  # The mint rate is a per-server cap on personal athanors minted per hour.
  defp mint_allowed do
    case Caps.get(:mint_per_hour) do
      nil ->
        :ok

      _cap ->
        hour_ago = DateTime.add(DateTime.utc_now(), -3600)
        Caps.check(:mint_per_hour, Athanors.count_created_since(hour_ago))
    end
  end

  # The person's own context, focused on the new athanor: their pull
  # credential, their attribution on the minted consents.
  defp person_ctx(user_id, athanor_id) do
    Context.build(
      user_id: user_id,
      athanor_id: athanor_id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp seed_ctx(athanor_id) do
    Sanctum.internal_context(user_id: "_seed", athanor_id: athanor_id, scope: :athanor)
  end

  # The bundle registered as rows: the scan walks the athanor's
  # `components/` union (its own tree over the seed bundle — `Arca.Overlay`)
  # and mints a row per version directory. No bytes move. An install
  # without its bundle cannot provision anyone; say so rather than minting
  # an empty athanor.
  defp register_bundle(athanor_id) do
    ctx = seed_ctx(athanor_id)

    with :ok <- bundle_present(ctx) do
      # A component that fails registration is logged by the scan and
      # skipped; the consent bootstrap's `all_minted` is the gate that
      # decides whether what registered is enough to provision.
      {:ok, AutoIndexer.scan(ctx: ctx)}
    end
  end

  defp bundle_present(ctx) do
    case Arca.list_recursive(ctx, Arca.Storage.seed_prefix("components")) do
      {:ok, [_ | _]} -> :ok
      {:ok, []} -> {:error, :bundle_missing}
      {:error, reason} -> {:error, {:bundle_unreadable, reason}}
    end
  end

  # The AQUA template is served in place through the seed overlay — no
  # copy is made. What provisioning checks is that the install SHIPS a
  # well-formed template (a v2-shaped or empty mount fails loud here, at
  # the one moment an operator is watching, instead of as an empty roster
  # later). `ctx` is unused — the check is the seed's, not the athanor's.
  defp aqua_definitions(_ctx) do
    case Compendium.AquaTemplate.seed_check() do
      :ok -> :ok
      {:error, reason} -> {:error, {:aqua_template, reason}}
    end
  end

  @doc """
  Sync every provisioned athanor with the seed media a release shipped:
  the scan re-walks the `components/` union so bundle versions the release
  added get rows, their published deps pulled, AND their baseline consents
  minted — a row without a profile is uninvocable, and nothing after boot
  would ever mint one. No bytes move, the overlay serves them in place.
  AQUA needs no sync step at all: the same overlay serves its tree, so a
  new release's agents and skills are simply visible, per-file, everywhere
  they were not edited.

  The sync also collapses pristine copies: a materialized unit that is
  byte-identical to what the release now ships serves nothing — deleting
  it reclaims the athanor's quota and lets the unit track upgrades again.
  Edited copies are kept.

  Why per-file for aqua and per-version for components: the upgrade rule
  lives with the layout table (`Arca.Storage`) — a release only ever
  changes what an UNmaterialized unit reads through to, and the unit
  granularity IS the upgrade granularity.

  Runs at boot (`Cyfr.Bootstrap`); a failure logs and moves on — a sync
  must never take the server down or block another athanor's.
  """
  @spec sync_seeds() :: :ok
  def sync_seeds do
    for athanor <- Athanors.list_active(), not is_nil(athanor.provisioned_at) do
      ctx = seed_ctx(athanor.id)

      case AutoIndexer.scan(ctx: ctx) do
        %{registered: registered} when registered > 0 ->
          Logger.info("[Provisioning] #{athanor.id}: registered #{registered} bundle version(s)")

          case Pull.ensure_published_deps(ctx, missing_bundle_deps(ctx)) do
            %{failed: []} ->
              :ok

            %{failed: failed} ->
              Logger.warning(
                "[Provisioning] #{athanor.id}: dep pull after sync failed: #{inspect(failed)}"
              )
          end

          bootstrap_synced(ctx, athanor.id)

        %{errors: errors} when errors > 0 ->
          Logger.warning("[Provisioning] #{athanor.id}: bundle sync hit #{errors} error(s)")

        _scan ->
          :ok
      end

      collapse_pristine(ctx, athanor.id)
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

  defp collapse_pristine(ctx, athanor_id) do
    for root <- Arca.Storage.seed_roots(),
        {unit, :materialized} <- Arca.Overlay.unit_statuses(ctx, root) do
      case Arca.Overlay.collapse_unit(ctx, unit) do
        :collapsed ->
          Logger.info(
            "[Provisioning] #{athanor_id}: collapsed pristine copy #{Enum.join(unit, "/")}"
          )

        {:error, reason} ->
          Logger.warning(
            "[Provisioning] #{athanor_id}: collapse of #{Enum.join(unit, "/")} failed: " <>
              inspect(reason)
          )

        _kept_or_absent ->
          :ok
      end
    end

    :ok
  end

  # Every static dependency the athanor's local components declare that
  # is not present — the published catalysts the bundled AQUA depends on.
  defp missing_bundle_deps(ctx) do
    case Arca.ComponentStorage.list_components(ctx,
           publisher: Compendium.ComponentPath.default_publisher(),
           limit: :none
         ) do
      {:ok, rows} ->
        rows
        |> Enum.flat_map(&Pull.missing_deps(ctx, &1))
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
    Logger.warning(
      "[Sanctum.Provisioning] #{athanor.id} not provisioned at #{step}: #{inspect(detail)}"
    )

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
