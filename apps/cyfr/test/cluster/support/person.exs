# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Person do
  @moduledoc """
  A person's work on the cell, entered by the doors a person has.

  `Cyfr.Cluster.Fixtures` writes the rows a case races on, below every
  door. The cases that use this module ask what a person meets instead: a
  person signed in with a session of their own (`Cyfr.Cluster.Fixtures.person!/0`),
  whose context each member establishes from the session token as the
  console does (`context/1`), in an athanor filled through the explicit
  provision verb on the member that makes the person, which answers once
  the fill has run there: the shipped AQUA tree and catalysts copied in,
  indexed and the soul consented. The model's key is then entered and
  bound through the consent walk (`person!/0`). What such a
  person does then goes through the runner (`send/3`), the approvals door
  (`decide/3`), the console's opening of a thread (`open/2`), the consent
  walk (`plan/2`, `commit/3`) and the gate (`call/3`), on whichever member
  a case names.

  The model the turns run on is the shipped Claude catalyst, served by
  each member's scripted worker service (`Cyfr.Cluster.Boot.start_worker!/1`),
  so the component is the only stand-in. The seed tree the athanor is
  filled from is the run's own (`seed!/0`), laid once by the control node
  and read by both members: the suite's own seed carries the AQUA tree
  alone.
  """

  @compile {:no_warn_undefined,
            [
              Aqua.Approvals,
              Aqua.Runner,
              Aqua.Tape,
              Arca,
              Arca.ThreadStorage,
              Compendium.AgentIndex,
              Compendium.AquaPath,
              Prima.AgentRef,
              Arca.ConsentStorage,
              Sanctum.Caller,
              Sanctum.Consent.Commit,
              Sanctum.Consent.Plan,
              Sanctum.Context,
              Sanctum.Gate,
              Sanctum.Provisioning,
              Sanctum.Tenancy.Athanors,
              Sanctum.Test.ConsentFixtures
            ]}

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  # The shipped catalysts a person's first turn on the soul reaches.
  @catalysts ~w(claude files http)

  @doc "The model catalyst the turns run on, which a member's scripted worker serves."
  @spec model() :: String.t()
  def model, do: @model

  # ---------------------------------------------------------------------------
  # The seed, on the control node
  # ---------------------------------------------------------------------------

  @doc """
  The run's seed tree: the repository's AQUA tree and the newest shipped
  version of each catalyst a turn on the soul reaches, without build
  droppings. Laid once per run, at a path the run's own prefix names
  (`Cyfr.Cluster.Store.prefix/0`), under the run's temporary directory;
  a tree is whole once its marker is written, which is last. Both members
  are booted reading it in place (`Cyfr.Cluster.Cell`), since they share
  this host's filesystem.
  """
  @spec seed!() :: Path.t()
  def seed! do
    run = String.replace(Cyfr.Cluster.Store.prefix(), "/", "_")
    dir = Path.join(System.tmp_dir!(), "cyfr_#{run}_seed")
    marker = Path.join(dir, ".laid")

    unless File.exists?(marker) do
      File.rm_rf!(dir)
      lay_seed!(dir)
      File.write!(marker, "")
    end

    dir
  end

  defp lay_seed!(dir) do
    repo = Path.expand("../../../../../seed", __DIR__)
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(repo, "aqua"), Path.join(dir, "aqua"))

    for name <- @catalysts do
      unit = Cyfr.Test.SeedBundle.local_unit!(repo, "catalysts", name)
      source = Path.join([repo, "components", unit.rel])
      target = Path.join([dir, "components", unit.rel])

      for file <- Path.wildcard(Path.join(source, "**"), match_dot: false),
          not File.dir?(file),
          not String.contains?(file, "/target/") do
        destination = Path.join(target, Path.relative_to(file, source))
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(file, destination)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The person, on a member
  # ---------------------------------------------------------------------------

  @doc """
  A person signed in with a session, in an athanor of their own filled
  now, on this member, through the explicit verb, with the model's key
  entered and bound to the turns of the console and of the API. The verb
  runs the fill in this process and answers its outcome, so the athanor
  stands filled on every member before the case acts. Answers the person
  (`Cyfr.Cluster.Fixtures.person!/0`): their id, athanor and session token.
  """
  @spec person!() :: map()
  def person! do
    person = Cyfr.Cluster.Fixtures.person!()
    ctx = context!(person.token)

    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)
    {:ok, %{provisioned_at: %DateTime{}}} = Sanctum.Provisioning.provision(athanor, ctx)
    {:ok, [_soul]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @soul)

    entry =
      Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})

    Map.put(person, :key_entry_id, entry.id)
  end

  @doc """
  A crew member of the person's athanor named `name`, on the model's
  brain: its file written to the athanor's crew, indexed, and consented as
  the person consents a member the athanor made, its brain's key the one
  the model's default profile binds.
  """
  @spec crew_member!(String.t(), String.t()) :: :ok
  def crew_member!(token, name) do
    ctx = context!(token)

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{name}\ndescription: Plans.\navoid: Building.\n" <>
          "catalyst_ref: #{@model}\nmodel: claude-sonnet-5-5\n---\n\nYou are the #{name}.\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    ref = Prima.AgentRef.ref(name)
    decisions = %{ref: ref, selections: [%{dep: @model, label: "default"}]}
    %{plan: plan, preview: preview} = walk(token, %{ref: ref}, decisions)
    {:ok, _} = commit(token, decisions, plan, preview)
    :ok
  end

  @doc """
  The consent walk's first two steps as the person takes them on this
  member: the plan for `select`, and the preview of `decisions` with the
  proof a commit spends.
  """
  @spec walk(String.t(), map(), map()) :: %{plan: map(), preview: map()}
  def walk(token, select, decisions) do
    ctx = context!(token)
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, select)
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)
    %{plan: plan, preview: preview}
  end

  @doc "The consent walk's commit of `decisions` with a walk's plan and preview, on this member."
  @spec commit(String.t(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def commit(token, decisions, plan, preview) do
    Sanctum.Consent.Commit.commit(context!(token), %{
      decisions: decisions,
      plan_token: plan.plan_token,
      proof: preview.proof,
      commit_digest: preview.commit_digest,
      expected_consent_revision: plan.expected_consent_revision
    })
  end

  @doc """
  The context this member establishes from `token`, on the console's
  interactive surface, as `CyfrWeb.ContextGuard` gives a mounted view.
  """
  @spec context!(String.t()) :: Sanctum.Context.t()
  def context!(token) do
    {:ok, ctx} = Sanctum.Caller.establish(token)
    %{ctx | origin: :interactive}
  end

  @doc "A room of the person's athanor."
  @spec thread!(String.t()) :: String.t()
  def thread!(token) do
    {:ok, thread} = Arca.ThreadStorage.create(Sanctum.Context.actor(context!(token)))
    thread.id
  end

  @doc "Send `text` on `thread_id` as the person, through this member's runner."
  @spec send(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send(token, thread_id, text), do: Aqua.Runner.send_message(context!(token), thread_id, text)

  @doc """
  Open `thread_id` as the person's console does, through this member's
  runner: the live part of the thread a viewer joining reads, which starts
  the thread's runner here when no live member runs it.
  """
  @spec open(String.t(), String.t()) :: map() | {:error, term()}
  def open(token, thread_id), do: Aqua.Runner.state(thread_id, context!(token).athanor_id)

  @doc "Call the tool `name` as the person, through the gate's external entry."
  @spec call(String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(token, name, args), do: Sanctum.Gate.call_external(name, context!(token), args)

  @doc "The turn's pending approvals, as this member reads them."
  @spec pending_approvals(String.t(), String.t()) :: [String.t()]
  def pending_approvals(token, turn_id) do
    ctx = context!(token)

    with {:ok, turn} <- Aqua.Tape.turn(ctx, turn_id),
         {:ok, approvals} <- Aqua.Tape.pending_approvals(ctx, turn) do
      Enum.map(approvals, & &1.id)
    end
  end

  @doc "Decide `approval_id` as the person, through the one door for a decision."
  @spec decide(String.t(), String.t(), :approved | :declined) :: {:ok, map()} | {:error, term()}
  def decide(token, approval_id, decision),
    do: Aqua.Approvals.resolve(context!(token), approval_id, %{decision: decision})

  @doc "The messages of `thread_id`, as this member reads them: author, kind and content."
  @spec messages(String.t(), String.t()) :: [map()]
  def messages(token, thread_id) do
    token
    |> context!()
    |> Sanctum.Context.actor()
    |> Arca.ThreadStorage.messages(thread_id)
    |> Enum.map(&Map.take(&1, [:author, :sent_by, :kind, :content, :turn_id]))
  end
end
