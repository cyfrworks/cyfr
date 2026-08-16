# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Provisioning do
  @moduledoc """
  What turns an athanor row into a working athanor: the seed bundle copied
  in and registered, the AQUA agent definitions copied from the shipped
  template, the published components the bundle depends on pulled from the
  registry, and a baseline consent minted for every executable local
  component — so the athanor's AQUA answers from the first prompt.

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

  alias Compendium.{AthanorSeeder, Pull}
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Caps, Members, Users}

  @doc """
  Called once the person is admitted and their namespace may be known:
  records the namespace, mints their own athanor, and retries any group of
  theirs whose provisioning failed earlier. A person without a namespace
  yet (the claim gate is ahead of them) gets theirs on the next call.
  """
  @spec after_sign_in(String.t()) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()} | :pending
  def after_sign_in(user_id) when is_binary(user_id) do
    with {:ok, user} <- Users.get(user_id),
         {:ok, user} <- record_namespace(user) do
      retry_groups(user_id)

      case user.namespace do
        nil -> :pending
        _ -> ensure_personal_athanor(user)
      end
    else
      {:error, :not_found} -> :pending
      {:error, _} = err -> err
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
    home = Athanors.home!()
    provision(home, person_ctx(user_id, home.id))
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
  Fill an athanor: seed bundle → register → pull the dependency closure →
  baseline consents → mark provisioned. `acting_ctx` is the person's
  context focused on the athanor (their pull credential); `nil` provisions
  as the server (anonymous pulls). Returns the row either way; a failure is
  recorded on it and logged.
  """
  @spec provision(Arca.Schemas.Athanor.t(), Context.t() | nil) ::
          {:ok, Arca.Schemas.Athanor.t()} | {:error, term()}
  def provision(%{provisioned_at: %DateTime{}} = athanor, _ctx), do: {:ok, athanor}

  def provision(%{id: athanor_id} = athanor, acting_ctx) do
    ctx = acting_ctx || seed_ctx(athanor_id)

    with :ok <- AthanorSeeder.seed(athanor),
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

  defp retry_groups(user_id) do
    for %{kind: "group", provisioned_at: nil} = group <- Athanors.list_for_user(user_id) do
      provision(group, person_ctx(user_id, group.id))
    end

    :ok
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

  defp record_namespace(%{namespace: ns} = user) when is_binary(ns), do: {:ok, user}

  defp record_namespace(user) do
    case Sanctum.Namespace.lookup(user.id) do
      slug when is_binary(slug) -> Users.set_namespace(user, slug)
      _ -> {:ok, user}
    end
  end

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

  # The athanor's own AQUA agent definitions, from the shipped template. A
  # copy already there (a retry after a later step failed) is kept as is.
  defp aqua_definitions(ctx) do
    case Compendium.AquaTemplate.ensure(ctx) do
      :ok -> :ok
      {:error, reason} -> {:error, {:aqua_template, reason}}
    end
  end

  # Every static dependency the athanor's local components declare that
  # is not present — the published catalysts the bundled AQUA depends on.
  defp missing_bundle_deps(ctx) do
    case Arca.ComponentStorage.list_components(ctx, publisher: "local", limit: 1_000) do
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
