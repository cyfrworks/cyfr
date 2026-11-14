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

  @key "sk-shared-7f3a"

  setup do
    Arca.Cache.init()

    run_dir = Path.join(System.tmp_dir!(), "aqua_setup_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(run_dir) end)
    seed = Fixture.lay_seed!(Path.join(run_dir, "seed"), mode: :attach)

    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(run_dir, "data"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, seed)
    # The seed names no published component, and nothing may be dialled
    # but the attach-mode upstream.
    Prima.Test.Env.put_app_env(:cyfr, :registry_url, "127.0.0.1:19")

    Cyfr.Test.Sandbox.stop_work_on_exit()

    # The administrator shares a key before the newcomer's first sign-in,
    # which binds it to the brain it fits.
    port = Fixture.upstream!(~s({"id":"msg_upstream","content":"answered upstream"}))
    admin = Fixture.administrator!()
    _share = Fixture.share_key!(admin, port, @key, %{person_daily: 25})
    ctx = Fixture.athanor!()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)

    {:ok, ctx: ctx, port: port}
  end

  test "a newcomer picks the brain their administrator's shared key binds, and Aqua answers " <>
         "after one confirmation",
       %{conn: conn, ctx: ctx, port: port} do
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

    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
    wait_until(fn -> render(view) =~ "aqua consented again." end, 10_000, "the soul's consent")
    refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

    # The soul's brain is connected through the key it was shared, read as
    # the person reads it on the screen, whose origin the grant admits.
    person = %{ctx | origin: :interactive}

    assert %{"aqua" => {:ready, _}} =
             Aqua.model_status(person, [%{"name" => "aqua", "catalyst_ref" => Fixture.ref()}])

    # Aqua answers. The share is attach-only, so the brain never holds the
    # key: its request goes to the upstream with the key CYFR attaches.
    said = "Hello from your brain."
    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    script = [
      %{
        "attached_request" =>
          Fixture.attached_request(port, "/v1/messages", ~s({"said":"#{said}"})),
        "emit" => [Fixture.text(said), Fixture.stop("end_turn")],
        "answer" => Fixture.answer([Fixture.text_block(said)], "end_turn", Fixture.tokens(1, 1))
      }
    ]

    assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
             Aqua.Runner.send_message(person, thread.id, Fixture.message(script, "@aqua hello"))

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

    assert {:ok, %{status: "completed"}} = Tape.turn(ctx, turn_id)

    assert [%{kind: "text", content: ^said}] =
             for(
               %{turn_id: ^turn_id, author: "aqua"} = row <-
                 Threads.messages(Sanctum.Context.actor(ctx), thread.id),
               do: row
             )

    sent = Fixture.upstream_request!()
    assert %{method: "POST", path: "/v1/messages"} = sent
    assert for({"x-api-key", value} <- sent.headers, do: value) == [@key]

    Cyfr.Test.Sandbox.end_views()
  end
end
