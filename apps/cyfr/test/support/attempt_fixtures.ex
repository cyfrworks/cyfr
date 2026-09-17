# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.AttemptFixtures do
  @moduledoc """
  A real execution attempt reached through host calls: an admitted row, its
  `Cyfr.Execution.Attempt` open with the calling process as its waiter, a
  signed assignment, and a runner attached through
  `Cyfr.Execution.Host.call/2`.

  The attached map carries what a runner's client needs (the attempt's
  `athanor_id`, `execution_id`, `attempt`, `fence`, `generation` and
  `service`, the `boot` and `runner` presenting its calls, the attempt's
  `keys` as `Cyfr.WorkerAuth.attempt_keys/2` answers them and its
  `call_key`)
  together with the row's `record`, its `close` state, the attempt `pid`,
  the `ctx`, `authority` and `component_ref` it runs under, its `input`,
  the signed `assignment` and the `secrets` attach answered.
  """

  import ExUnit.Assertions

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Execution.{Assignments, Attempt, Close, Delegation, Keys, Record}

  @doc """
  Admit, open, sign and attach. Options:

  - `:ctx` — the admission context (default `Sanctum.TestContext.local/0`);
  - `:authority` — default `Cyfr.Authority.zero/0`;
  - `:vault` — attributes of a vault entry to create
    (`Sanctum.Vault.create/2`); the authority's edge is bound to it and
    pinned to an active profile, so attach unseals its fields;
  - `:component_ref` — default a reference of its own, so no two fixtures
    share a rate bucket;
  - `:component_type` — the row's type (default `:catalyst`);
  - `:limits` — the node's limits (default the authority's);
  - `:stream_id` — the stream its events go on (default the execution's);
  - `:runner` — the attaching runner's id (default a fresh one);
  - `:service_id` — the worker service the attempt is dispatched to: the
    row's, the assignment's and the one its keys are bound to (default
    `"wrk_fixture"`);
  - `:boot_id` — the boot of that worker service: the row's and the
    assignment's, which every host call presents (default this boot's id);
  - `:timeout_ms` — the run's timeout, from which its subtree deadline is
    set (default 60 s);
  - `:worker` — the `Cyfr.WorkerAPI` module the attempt kills its runner
    through (default none);
  - `:digest` — the digest of the component's artifact, in the assignment
    and the attempt (default the digest of the reference's own bytes);
  - `:input` — the input the row is admitted with (default
    `%{"fixture" => true}`); a formula's delegation roster is its
    `sub_agents` (`Cyfr.Execution.Delegation.roster/1`);
  - `:declared_needs` and `:activation_digest` — the resolver's transition
    inputs its guest's children are stepped with (default `[]` and none);
  - `:reservation` — `true` to admit the row with the invocation
    reservation its authority's budget names, as a root is admitted;
  - `:attach` — `false` to stop before attaching.
  """
  @spec attached!(keyword()) :: map()
  def attached!(opts \\ []) do
    ctx = Keyword.get_lazy(opts, :ctx, &Sanctum.TestContext.local/0)
    {authority, entry} = authority(ctx, opts)

    component_type = Keyword.get(opts, :component_type, :catalyst)

    component_ref =
      Keyword.get_lazy(opts, :component_ref, fn ->
        "#{component_type}:local.attempt-fixture-#{System.unique_integer([:positive])}:0.1.0"
      end)

    limits = Keyword.get_lazy(opts, :limits, fn -> Authority.limits(authority) end)
    digest = Keyword.get_lazy(opts, :digest, fn -> Cyfr.Digest.sha256(component_ref) end)
    input = Keyword.get(opts, :input, %{"fixture" => true})

    record =
      Record.new(ctx, component_ref, input,
        component_type: component_type,
        reservation: reservation(authority, opts)
      )

    service_id = Keyword.get(opts, :service_id, "wrk_fixture")
    boot_id = Keyword.get_lazy(opts, :boot_id, &Record.boot_id/0)
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    deadline = System.system_time(:millisecond) + timeout_ms
    :ok = Record.write_started(record, service_id: service_id, boot_id: boot_id)
    close = %Close{ctx: ctx, record: record, limits: limits, started: true}

    {:ok, pid} =
      Attempt.open(
        execution_id: record.id,
        attempt: record.attempt,
        ctx: ctx,
        authority: authority,
        component_ref: component_ref,
        limits: limits,
        close: close,
        stream_id: Keyword.get(opts, :stream_id, record.id),
        declared_needs: Keyword.get(opts, :declared_needs, []),
        activation_digest: Keyword.get(opts, :activation_digest),
        roster: if(component_type == :formula, do: Delegation.roster(input), else: []),
        service_id: service_id,
        boot_id: boot_id,
        deadline: deadline,
        worker: Keyword.get(opts, :worker),
        digest: digest
      )

    {:ok, issued} =
      Assignments.issue(%{
        ctx: ctx,
        record: record,
        authority: authority,
        component: %{
          ref: component_ref,
          type: Atom.to_string(component_type),
          digest: digest,
          declared_needs: Keyword.get(opts, :declared_needs, []),
          activation_digest: Keyword.get(opts, :activation_digest)
        },
        input: input,
        timeout_ms: timeout_ms,
        deadline: deadline,
        service: service_id,
        boot: boot_id
      })

    fixture =
      Map.merge(issued.attempt_keys.attempt, %{
        boot: boot_id,
        deadline: deadline,
        runner: Keyword.get_lazy(opts, :runner, fn -> Cyfr.UUID7.generate_id("runner") end),
        keys: issued.attempt_keys,
        call_key: issued.attempt_keys.call,
        assignment: issued.assignment,
        record: record,
        close: close,
        pid: pid,
        ctx: ctx,
        authority: authority,
        component_ref: component_ref,
        entry: entry,
        input: input,
        secrets: nil
      })

    if Keyword.get(opts, :attach, true) do
      assert %{"ok" => secrets} = call(fixture, "attach", %{"assignment" => fixture.assignment})
      %{fixture | secrets: secrets}
    else
      fixture
    end
  end

  @doc """
  Sign and send one host call for `fixture`'s attempt, answering the decoded
  JSON. Options override the header's fields (`:runner`, `:boot`, `:nonce`,
  `:ts`, `:generation`, `:fence`, `:service`) or the `:call_key` it is
  signed with (default the fixture's); `:body` sends that exact body.
  """
  @spec call(map(), String.t(), map(), keyword()) :: map()
  def call(fixture, op, args, opts \\ []) do
    body = Keyword.get_lazy(opts, :body, fn -> body(op, args) end)
    fixture |> header(body, opts) |> Cyfr.Execution.Host.call(body) |> Jason.decode!()
  end

  @doc "The JSON body of a host call of `op` with `args`."
  @spec body(String.t(), map()) :: String.t()
  def body(op, args), do: Jason.encode!(%{"op" => op, "args" => args})

  @doc "A signed header for `body` on `fixture`'s attempt; options as `call/4`'s."
  @spec header(map(), String.t(), keyword()) :: String.t()
  def header(fixture, body, opts \\ []) do
    fields = %{
      athanor_id: fixture.athanor_id,
      execution_id: fixture.execution_id,
      attempt: fixture.attempt,
      fence: Keyword.get(opts, :fence, fixture.fence),
      generation: Keyword.get(opts, :generation, fixture.generation),
      service: Keyword.get(opts, :service, fixture.service),
      boot: Keyword.get(opts, :boot, fixture.boot),
      runner: Keyword.get(opts, :runner, fixture.runner),
      ts: Keyword.get_lazy(opts, :ts, fn -> System.system_time(:millisecond) end),
      nonce: Keyword.get_lazy(opts, :nonce, &nonce/0)
    }

    key = Keyword.get(opts, :call_key, fixture.call_key)
    {:ok, header} = Cyfr.WorkerAuth.host_call_header(key, fields, body)
    header
  end

  @doc "The verified header fields a host call of `fixture`'s runner carries."
  @spec caller(map()) :: Cyfr.WorkerAuth.host_call()
  def caller(fixture) do
    fixture
    |> Map.take([
      :athanor_id,
      :execution_id,
      :attempt,
      :fence,
      :generation,
      :service,
      :boot,
      :runner
    ])
    |> Map.merge(%{ts: System.system_time(:millisecond), nonce: nonce()})
  end

  @doc """
  The host-call fields of the attempt that currently owns `execution_id`,
  as its claimant presents them: usable with `call/4` from a process that
  holds no client, such as a telemetry handler inside a run. An attempt the
  control plane holds itself was dispatched to no worker service; its
  fields name the placeholder service `wrk_none`, which no row matches, so
  every call made with them is lost.
  """
  @spec current!(String.t(), String.t()) :: map()
  def current!(athanor_id, execution_id) do
    %Arca.Schemas.ExecutionAttempt{} =
      row = Arca.ExecutionAttempts.current(athanor_id, execution_id)

    {:ok, generation} = Keys.generation()

    {:ok, keys} =
      Keys.attempt_keys(%{
        athanor_id: athanor_id,
        execution_id: execution_id,
        attempt: row.attempt,
        fence: row.fence,
        generation: generation,
        service: row.service_id || "wrk_none"
      })

    Map.merge(keys.attempt, %{
      boot: row.boot_id,
      runner: row.claimed_by,
      keys: keys,
      call_key: keys.call
    })
  end

  @doc "A delta of `event` (JSON text) naming `fixture`'s attempt, as its wire map."
  @spec delta(map(), String.t()) :: map()
  def delta(fixture, event) do
    %{
      "execution_id" => fixture.execution_id,
      "attempt" => fixture.attempt,
      "fence" => fixture.fence,
      "event" => event
    }
  end

  @doc "An outcome wire map naming `fixture`'s attempt."
  @spec outcome(map(), String.t(), map()) :: map()
  def outcome(fixture, status, fields) do
    Map.merge(fields, %{
      "execution_id" => fixture.execution_id,
      "attempt" => fixture.attempt,
      "fence" => fixture.fence,
      "status" => status
    })
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp reservation(%Authority{budget: %Authority.Budget{id: id, cap: cap}}, opts) do
    if Keyword.get(opts, :reservation, false), do: %{budget_id: id, cap: cap}
  end

  defp authority(ctx, opts) do
    authority = Keyword.get(opts, :authority, Authority.zero())

    case Keyword.get(opts, :vault) do
      nil -> {authority, nil}
      %{} = attrs -> vault_authority!(ctx, attrs, authority)
    end
  end

  @doc """
  `authority` with its edge bound to a new vault entry made from `attrs` in
  `ctx`'s athanor, and pinned to an active profile at its head consent, so
  an attach unseals the entry. Answers the authority and the entry.
  """
  @spec vault_authority!(Sanctum.Context.t(), map(), Authority.t()) ::
          {Authority.t(), Arca.Schemas.VaultEntry.t()}
  def vault_authority!(ctx, attrs, authority \\ Authority.zero()) do
    {:ok, view} =
      Sanctum.Vault.create(
        ctx,
        Map.put_new(attrs, :name, "attempt-fixture-#{System.unique_integer([:positive])}")
      )

    {:ok, entry} = Arca.VaultStorage.get(ctx.athanor_id, view.id)
    {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)
    consent_id = Cyfr.UUID7.generate_id("cons")

    {:ok, profile} =
      Arca.ProfileStorage.put(%{
        athanor_id: ctx.athanor_id,
        source_ref: "catalyst:local.attempt-fixture",
        kind: "owner",
        label: "fixture-#{System.unique_integer([:positive])}",
        status: "active",
        head_consent_id: consent_id
      })

    vault = %{entry_id: entry.id, binding_digest: digest, projection: nil}

    {%{
       authority
       | profile_id: profile.id,
         consent_id: consent_id,
         resources: %Edge{vault: vault}
     }, entry}
  end
end
