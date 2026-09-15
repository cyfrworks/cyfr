# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.Chain do
  @moduledoc """
  Root and child execution under the authority `Cyfr.Execution.Admission`
  decides.

  `run_root/5` is the external-ingress entry: it runs the
  reference under the authority its selected profile's consent grants.
  `run_root_edge/5` roots at a tincture's profile and runs one of its
  dependencies under that edge. `run_child/5` and `run_child_stream/5`
  are the in-chain entries: the target runs under the child authority the
  caller's authority steps to — bound, or zero. Every decision is taken
  before the run is dispatched (`Cyfr.Execution.Dispatch.run/4`); a refusal
  runs nothing.

  A spawn-shaped child's invoke-budget slot is charged by its step and
  held under the guard by the process that dispatches it, with its charge
  row; the child's attempt takes both over and gives them back when it
  stops, and a child refused before its attempt opens gives them back at
  once.
  """

  alias Cyfr.Authority
  alias Cyfr.Authority.RootSelect
  alias Cyfr.Execution.{Admission, Charge}
  alias Sanctum.Context

  @doc """
  Root an execution chain under a profile's consent.

  `profile_selector` and the options `:route`, `:consent_source`,
  `:ceiling` and `:live_shape_digest` are
  `Cyfr.Execution.Admission.authority_for/4`'s. Remaining options pass
  through to `Cyfr.Execution.Dispatch.run/4`.
  """
  @spec run_root(Context.t(), RootSelect.selector(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root(%Context{} = ctx, profile_selector, reference, input, opts \\ []) do
    with {:ok, %{authority: authority, stamp: stamp, profile: profile}} <-
           Admission.authority_and_stamp_for(ctx, profile_selector, reference, opts) do
      exec_opts =
        opts
        |> Keyword.drop([:consent_source, :route, :ceiling, :live_shape_digest])
        |> Keyword.merge(
          authority: authority,
          authority_required: true,
          activation_stamp: stamp,
          # The flat digest also rides along so the formula closure can
          # thread the chain's activation identity to every descendant row.
          activation_digest: stamp.activation_digest,
          # And the profile this root resolved to, so the row records which
          # consent it ran under instead of leaving a later caller to
          # re-select one — a selection that is only unambiguous while the
          # ref has a single owner profile.
          profile_id: profile.id
        )

      Cyfr.Execution.Dispatch.run(ctx, reference, input, exec_opts)
    end
  end

  @doc """
  Advance the caller's authority through one in-chain invocation and run
  the target synchronously under the resulting child authority.

  Required options: `:ctx` (the closure's context), `:parent_execution_id`.
  `:guest_fn` (`:call` | `:spawn`), `:root_execution_id`,
  `:declared_needs`, `:activation_digest` (the root's, for the child row
  stamp) are host-threaded by the formula closure.
  """
  @spec run_child(Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_child(%Authority{} = authority, reference, need, input, opts) do
    opts = Charge.identify(opts)

    with {:ok, decision} <- Admission.step_invoke(authority, reference, need, opts) do
      if Keyword.get(opts, :guest_fn) == :spawn do
        # A spawn-shaped step charged the invoke budget; this process holds
        # the slot under the guard until the child's attempt takes it over.
        # The hold is a row too (`Arca.BudgetReservations`), given back with
        # the slot.
        with :ok <- Charge.take(decision.authority, opts) do
          Sanctum.Authority.guard_invoke(decision.authority)
          execute_child(decision, input, opts)
        end
      else
        execute_child(decision, input, opts)
      end
    end
  end

  @doc """
  Root at a profile's source and immediately traverse one edge — the
  routed-ingress shape: a tincture (whose profile owns the authority)
  invoking one of its dependencies. The dependency executes as the root
  WASM execution, bound to the tincture→dependency edge's resources, or
  inert/denied exactly as the transition relation decides
  (`Cyfr.Execution.Admission.root_edge/4`).

  `:route` is required — `:public` | `:protected` — and IS the profile
  selection, public-first: authentication never upgrades a public route.
  There is no selector to fall back to, so a call without a route raises
  rather than reaching a default that would guess.
  """
  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root_edge(%Context{} = ctx, source_ref, reference, input, opts) do
    with {:ok, %{root: root, decision: decision}} <-
           Admission.root_edge(ctx, source_ref, reference, opts) do
      exec_opts =
        opts
        # `:profile` is not an option any more; a caller still setting it
        # must not see it forwarded to the child as if it meant something.
        |> Keyword.drop([:consent_source, :route, :ceiling, :live_shape_digest, :need, :profile])
        # A routed root records the profile it resolved to exactly as
        # `run_root/5` does — the row is the SSOT for which consent the
        # turn ran under.
        |> Keyword.merge(ctx: ctx, activation_stamp: root.stamp, profile_id: root.profile.id)

      execute_child(decision, input, exec_opts)
    end
  end

  @doc """
  Start an in-chain streamed execution: decide, then run the child under
  the process supervisor with its id pre-registered, returning immediately.

  A guest call of `execution.run_stream` returns while work continues, so
  it is spawn-shaped: the decision charges the root invoke budget and takes
  its charge row, as a spawn does (`Cyfr.Execution.Charge`), and the
  child's attempt gives both back. A denial charges nothing.
  """
  @spec run_child_stream(Authority.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_child_stream(%Authority{} = authority, reference, need, input, opts) do
    opts = opts |> Keyword.put(:guest_fn, :spawn) |> Charge.identify()

    with {:ok, decision} <- Admission.step_invoke(authority, reference, need, opts),
         :ok <- Charge.take(decision.authority, opts) do
      execution_id = Keyword.get(opts, :execution_id) || Cyfr.Execution.Record.generate_id()
      opts = Keyword.put(opts, :execution_id, execution_id)

      logger_metadata = Cyfr.LoggerContext.capture()

      start =
        Task.Supervisor.start_child(Opus.TaskSupervisor, fn ->
          Cyfr.LoggerContext.restore(logger_metadata)
          # The task holds the charged slot until the child's attempt takes
          # it over. Guard BEFORE registering: the registry is what a cancel
          # kills through, so the compensation must exist before the pid is
          # findable, or a kill in the gap leaked the slot step_invoke
          # charged.
          Sanctum.Authority.guard_invoke(decision.authority)
          Registry.register(Cyfr.Execution.Registry, execution_id, :running)
          execute_child(decision, input, opts)
        end)

      case start do
        {:ok, _pid} ->
          {:ok,
           %{execution_id: execution_id, stream_url: "/api/executions/#{execution_id}/events"}}

        {:error, reason} ->
          Sanctum.Authority.release_invoke(decision.authority)
          Charge.give_back(decision.authority, opts)
          {:error, {:stream_start_failed, reason}}
      end
    end
  end

  @doc """
  Execute a stepped invocation under its child authority.

  A bound target that no longer resolves is `setup_required` — the consent
  names a dependency the installed world cannot satisfy. An unresolvable
  *unbound* target proceeds to admission and fails there, so dynamic
  dispatch to a bad ref keeps admission's error shape.

  A spawn-shaped step (`opts[:guest_fn]` is `:spawn`) is dispatched with
  the invoke-budget slot the calling process holds (`:held_invoke`).
  """
  @spec execute_child(Admission.child_decision(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_child(decision, input, opts) do
    ctx = Keyword.fetch!(opts, :ctx)

    spawned? = Keyword.get(opts, :guest_fn) == :spawn

    if decision.bound? and is_nil(decision.component) do
      if spawned? do
        Sanctum.Authority.release_invoke(decision.authority)
        Charge.give_back(decision.authority, opts)
      end

      {:error,
       {:setup_required,
        %{
          profile_id: decision.authority.profile_id,
          node_ref: decision.reference,
          need: decision.need || "",
          reason: :unresolvable_target
        }}}
    else
      exec_opts =
        [authority: decision.authority, authority_required: true]
        |> Arca.QueryHelpers.maybe_put(
          :parent_execution_id,
          Keyword.get(opts, :parent_execution_id)
        )
        |> Arca.QueryHelpers.maybe_put(:root_execution_id, Keyword.get(opts, :root_execution_id))
        # The parent's attempt a formula's child is admitted under: a parent
        # that is no longer running admits nothing.
        |> Arca.QueryHelpers.maybe_put(:parent_attempt, parent_attempt(opts))
        |> Arca.QueryHelpers.maybe_put(:activation_digest, Keyword.get(opts, :activation_digest))
        |> Arca.QueryHelpers.maybe_put(:activation_stamp, Keyword.get(opts, :activation_stamp))
        |> Arca.QueryHelpers.maybe_put(:client_ip, Keyword.get(opts, :client_ip))
        |> Arca.QueryHelpers.maybe_put(:execution_id, Keyword.get(opts, :execution_id))
        # Only a root carries one; an in-chain child walks its parent's
        # authority and leaves the column nil.
        |> Arca.QueryHelpers.maybe_put(:profile_id, Keyword.get(opts, :profile_id))
        |> Arca.QueryHelpers.maybe_put(
          :type,
          decision.component && Map.get(decision.component, "type")
        )
        # Record the edge authorizing this hop for audit attribution.
        |> Arca.QueryHelpers.maybe_put(:dep_ref, decision.reference)
        |> Arca.QueryHelpers.maybe_put(:need, decision.need)
        # Who invoked this child, for a formula's own roster and lineage.
        |> Arca.QueryHelpers.maybe_put(:parent_reference, Keyword.get(opts, :parent_reference))
        |> Arca.QueryHelpers.maybe_put(:retention_class, Keyword.get(opts, :retention_class))
        |> Arca.QueryHelpers.maybe_put(:retained_input, Keyword.get(opts, :retained_input))
        # The barriers admission performs for a loop-dispatched child: the
        # hold row its charge names, and the step on its generation.
        |> Arca.QueryHelpers.maybe_put(:charge, hold_of(decision.authority, opts))
        |> Arca.QueryHelpers.maybe_put(:step, step_of(opts))
        # The port's clock (`Cyfr.Execution.StepSpans`), marked by the run.
        |> Arca.QueryHelpers.maybe_put(:step_spans, Keyword.get(opts, :step_spans))
        |> Arca.QueryHelpers.maybe_put(:held_invoke, spawned? || nil)

      Cyfr.Execution.Dispatch.run(ctx, decision.reference, input, exec_opts)
    end
  end

  defp parent_attempt(opts) do
    if Keyword.get(opts, :parent_execution_id), do: Keyword.get(opts, :attempt)
  end

  defp hold_of(%Authority{budget: budget}, opts) do
    case Keyword.get(opts, :charge) do
      %{id: id} -> %{reservation_id: budget.id, id: id}
      _ -> nil
    end
  end

  defp step_of(opts) do
    with step_id when is_binary(step_id) <- Keyword.get(opts, :step_id),
         %{generation: generation} <- Keyword.get(opts, :charge) do
      %{id: step_id, generation: generation}
    else
      _ -> nil
    end
  end
end
