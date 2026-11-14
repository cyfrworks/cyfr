# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaSetupTest do
  @moduledoc """
  Aqua's setup for a newcomer whose administrator shared a key with
  everyone: the brain that key fits stands first, already bound and named
  as the administrator's with its daily cap; picking it for Aqua asks one
  confirmation, and Aqua then answers. The brain is the chat fixture
  (`Cyfr.Test.ChatFixture`) in attach mode, run by the runtime for real,
  and the key goes only to its loopback upstream.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ChatFixture, as: Fixture

  @moduletag timeout: 180_000

  setup do
    Arca.Cache.init()

    run_dir = Path.join(System.tmp_dir!(), "aqua_setup_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, arca: :seed_path, cyfr: :registry_url]
    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    seed = Fixture.lay_seed!(Path.join(run_dir, "seed"), mode: :attach)

    Application.put_env(:arca, :base_path, Path.join(run_dir, "data"))
    Application.put_env(:arca, :seed_path, seed)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    on_exit(fn ->
      for {{app, key}, value} <- previous do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The administrator shares a key before the newcomer's first sign-in,
    # which binds it to the brain it fits.
    port = Fixture.upstream!(~s({"id":"msg_upstream","content":"answered upstream"}))
    admin = Fixture.administrator!()
    _share = Fixture.share_key!(admin, port, "sk-shared-7f3a", %{person_daily: 25})
    ctx = Fixture.athanor!()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    {:ok, ctx: ctx}
  end

  test "a newcomer picks the brain their administrator's shared key binds, and Aqua answers " <>
         "after one confirmation",
       %{conn: conn, ctx: ctx} do
    # The soul's model moved since its first fill consented it, so its
    # consent no longer covers it.
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "model" => "elsewhere"
      })

    conn =
      log_in_user(conn, %{user_id: ctx.user_id, email: "newcomer@example.com", namespace: nil},
        claim: false,
        athanor_id: ctx.athanor_id
      )

    {view, _html} = mount_athanor(conn, "/aqua")

    # A stale consent reads as stale and is consented again, never a key
    # to connect.
    assert has_element?(
             view,
             "#aqua-card-aqua",
             "Its consent is out of date: what it runs on changed since it was consented."
           )

    assert has_element?(view, "#aqua-card-aqua button[phx-click=open_consent]", "Consent again")
    refute has_element?(view, "#aqua-card-aqua", "the model has no key yet")
    refute has_element?(view, ~s(#aqua-card-aqua a[data-test="connect"]))

    # The setup is the first step, and the shared key stands first, bound.
    assert has_element?(view, "#aqua-setup[open]")

    [first | _] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#aqua-setup-brains > li")
      |> Enum.map(&LazyHTML.attribute(&1, "id"))

    assert first == ["aqua-setup-brain-chat-fixture"]

    assert has_element?(
             view,
             ~s(#aqua-setup-brain-chat-fixture[data-state="ready"] [data-test="setup-shared"]),
             "key, shared with you, up to 25 requests a day"
           )

    wait_until(
      fn -> has_element?(view, "#aqua-setup-pick option[value^=\"chat-fixture::\"]") end,
      10_000,
      "the fixture's models"
    )

    [choice | _] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(#aqua-setup-pick option[value^="chat-fixture::"]))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))

    view |> form("#aqua-setup-pick", %{"value" => choice}) |> render_change()

    # One confirmation: the soul's consent, asked again for its new brain.
    wait_until(
      fn ->
        has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]), "agent:local.aqua")
      end,
      10_000,
      "the soul's grant"
    )

    # The grant reopens on what the soul's head bound for its brain.
    assert has_element?(
             view,
             ~s(#system-layer-dialog [data-test="grant-pick"][aria-pressed="true"])
           )

    tracer = trace_consent!(ctx)
    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
    wait_until(fn -> render(view) =~ "aqua consented again." end, 10_000, "the soul's consent")
    refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

    # The soul's brain is connected through the key it was shared, read as
    # the person reads it on the screen, whose origin the grant admits.
    person = %{ctx | origin: :interactive}
    status = Aqua.model_status(person, [%{"name" => "aqua", "catalyst_ref" => Fixture.ref()}])
    assert match?(%{"aqua" => {:ready, _}}, status), consent_state(person, status)

    # Aqua answers.
    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
             Aqua.Runner.send_message(%{ctx | origin: :interactive}, thread.id, "@aqua hello")

    wait_until(
      fn ->
        match?(
          {:ok, %{status: status}} when status in ~w(completed failed cancelled),
          Tape.turn(ctx, turn_id)
        )
      end,
      90_000,
      "the turn"
    )

    {:ok, turn} = Tape.turn(ctx, turn_id)
    print_trace!(tracer)
    assert turn.status == "completed", edges_state(person, turn)

    assert [%{kind: "text", content: "The fixture answers."}] =
             for(
               %{turn_id: ^turn_id, author: "aqua"} = row <-
                 Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               do: row
             )

    Cyfr.Test.Sandbox.end_views()
  end

  # Diagnostic: every consent write from the person's confirmation through
  # the turn, and every `Opus.Attempt.fetch_secrets/1` and
  # `Sanctum.Consent.Loader.pinned_intact?/2` call with its return, each
  # beside the live heads of the soul's profile and of every lender the
  # call names, read the moment the tracer hears it.
  @traced [
    {Opus.Attempt, :fetch_secrets, 1},
    {Sanctum.Consent.Loader, :pinned_intact?, 2},
    {Arca.ConsentStorage, :insert_revision, 4},
    {Arca.ConsentStorage, :mint_profile_with_revision, 4}
  ]

  defp trace_consent!(ctx) do
    actor = Sanctum.Context.actor(ctx)

    profiles =
      for {name, ref} <- [soul: "agent:local.aqua", brain: Fixture.ref()],
          {:ok, [profile | _]} <- [Arca.ConsentStorage.profiles(actor, ref)],
          into: %{},
          do: {name, profile.id}

    tracer = spawn(fn -> trace_loop(actor, profiles, []) end)
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])

    for mfa <- @traced,
        do:
          :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}, {:exception_trace}]}], [:local])

    tracer
  end

  defp print_trace!(tracer) do
    :erlang.trace(:all, false, [:call])
    for mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:local])
    send(tracer, {:done, self()})

    receive do
      {:trace_lines, lines} -> Enum.each(lines, &IO.puts("TRACE| " <> &1))
    after
      10_000 -> IO.puts("TRACE| the tracer did not answer")
    end
  end

  defp trace_loop(actor, profiles, lines) do
    receive do
      {:done, from} ->
        send(from, {:trace_lines, Enum.reverse(lines)})

      {:trace, pid, :call, {m, f, args}} ->
        line = "#{inspect(pid)} CALL #{inspect(m)}.#{f} #{described_args(f, args)}"
        trace_loop(actor, profiles, [heads_line(actor, profiles, args), line | lines])

      {:trace, pid, :return_from, {m, f, a}, value} ->
        line = "#{inspect(pid)} RETURN #{inspect(m)}.#{f}/#{a} #{whole(redacted(f, value))}"
        trace_loop(actor, profiles, [heads_line(actor, profiles, []), line | lines])

      {:trace, pid, :exception_from, {m, f, a}, value} ->
        line = "#{inspect(pid)} EXCEPTION #{inspect(m)}.#{f}/#{a} #{whole(value)}"
        trace_loop(actor, profiles, [line | lines])

      other ->
        trace_loop(actor, profiles, ["OTHER #{whole(other)}" | lines])
    end
  end

  # What a run was handed is named, never shown.
  defp redacted(:fetch_secrets, {:ok, secrets}) when is_map(secrets),
    do: {:ok, {:fields, Map.keys(secrets)}}

  defp redacted(_f, value), do: value

  defp described_args(:fetch_secrets, [state]) do
    whole(%{
      authority: authority_pins(Map.get(state, :authority)),
      ctx: context_coords(Map.get(state, :ctx)),
      close_ctx: context_coords(state |> Map.get(:close) |> then(&(&1 && Map.get(&1, :ctx))))
    })
  end

  defp described_args(:pinned_intact?, [ctx, authority]),
    do: whole(%{ctx: context_coords(ctx), authority: authority_pins(authority)})

  defp described_args(_commit, args), do: whole(args)

  defp context_coords(%Sanctum.Context{} = ctx),
    do: Map.take(ctx, [:user_id, :athanor_id, :plane, :origin, :auth_method, :anonymous])

  defp context_coords(other), do: other

  defp authority_pins(%Prima.Authority{} = auth) do
    %{
      profile_id: auth.profile_id,
      consent_id: auth.consent_id,
      source_ref: auth.source_ref,
      cursor: auth.cursor,
      vault: auth.resources |> then(&(is_map(&1) && Map.get(&1, :vault))),
      policy_lenders: policy_lenders(auth.policy)
    }
  end

  defp authority_pins(other), do: other

  defp policy_lenders(%Prima.Authority.Blob{nodes: nodes}) do
    for {node, %{edges: edges}} <- nodes,
        {key, %{vault: %{lender: lender} = vault}} <- edges,
        do: %{node: node, edge: key, lender: lender, binding_digest: vault[:binding_digest]}
  end

  defp policy_lenders(other), do: other

  # The live heads of the soul's and the brain's profiles, and of every
  # profile the call names as a lender.
  defp heads_line(actor, profiles, args) do
    named =
      for %{profile_id: id} <- List.flatten([lenders_in(args)]), is_binary(id), do: {id, id}

    heads =
      for {name, id} <- Map.to_list(profiles) ++ named, into: %{} do
        profile =
          case Arca.ProfileStorage.get(actor, id) do
            {:ok, row} -> Map.take(row, [:status, :head_consent_id])
            other -> other
          end

        head =
          case Arca.ConsentStorage.get_head(actor, id) do
            {:ok, row, _refs} -> Map.take(row, [:id, :revision, :shape_digest, :granted_via])
            other -> other
          end

        {name, %{profile_id: id, profile: profile, head: head}}
      end

    "  HEADS #{whole(heads)}"
  end

  defp lenders_in([state]) when is_map(state), do: lenders_of(Map.get(state, :authority))
  defp lenders_in([_ctx, authority]), do: lenders_of(authority)
  defp lenders_in(_args), do: []

  defp lenders_of(%Prima.Authority{} = auth) do
    from_resources =
      case auth.resources do
        %{vault: %{lender: lender}} -> [lender]
        _ -> []
      end

    from_policy =
      case policy_lenders(auth.policy) do
        list when is_list(list) -> Enum.map(list, & &1.lender)
        _ -> []
      end

    from_resources ++ from_policy
  end

  defp lenders_of(_other), do: []

  defp whole(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  # The soul's edge into its brain as its head stores it and as the loader
  # resolves it, for a failure's message.
  defp edges_state(ctx, turn) do
    soul = "agent:local.aqua"
    {:ok, [profile | _]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), soul)
    {:ok, row} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile.id)
    {:ok, head, refs} = Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile.id)

    stored =
      with {:ok, blob} <- Prima.Authority.Blob.parse(head.resolved_policy),
           {:ok, edge} <- Prima.Authority.Blob.lookup_edge(blob, soul, Fixture.ref(), "") do
        edge.vault
      end

    loaded =
      case Opus.authority_for(ctx, :default, soul) do
        {:ok, authority} -> authority.consent_id
        refused -> refused
      end

    inspect(
      %{
        turn: Map.take(turn, [:consent_id, :error, :origin, :agent_capability_digest]),
        profile: Map.take(row, [:status, :head_consent_id]),
        loaded_consent: loaded,
        granted_via: head.granted_via,
        stored: stored,
        refs: refs,
        resolved: Opus.authority_for(ctx, :default, soul) |> brain_edge(soul)
      },
      limit: :infinity,
      printable_limit: 4000
    )
  end

  # The soul's edge into its brain as the loader resolved it, or why it
  # refused.
  defp brain_edge({:ok, authority}, soul) do
    case Prima.Authority.Blob.lookup_edge(authority.policy, soul, Fixture.ref(), "") do
      {:ok, edge} -> edge.vault
      other -> other
    end
  end

  defp brain_edge(refused, _soul), do: refused

  # What the soul's consent holds against what it is now, for a failure's
  # message.
  defp consent_state(ctx, status) do
    soul = "agent:local.aqua"
    {:ok, [profile | _]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), soul)
    {:ok, head, _refs} = Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile.id)

    fresh =
      with {:ok, input} <- Sanctum.Consent.ShapeDerivation.shape_input(ctx, soul),
           do: Sanctum.Consent.ShapeDigest.compute(input)

    inspect(
      %{
        status: status,
        head: Map.take(head, [:revision, :scope, :shape_digest, :granted_via, :activation]),
        live: Sanctum.Consent.ShapeDerivation.live_digest(ctx, soul),
        fresh: fresh,
        loaded: Opus.authority_for(ctx, :default, soul) |> elem(0),
        refused: Opus.authority_for(ctx, :default, soul) |> brain_edge(soul)
      },
      limit: :infinity,
      printable_limit: 4000
    )
  end
end
