# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaSetupTest do
  @moduledoc """
  Aqua's setup for a newcomer whose administrator shared a key with
  everyone: the brain that key fits stands first, already bound and named
  as the administrator's with its daily cap, so it is connected; a crew
  member made on it, its model picked and the member chosen as Aqua's
  ask nothing, since every member runs under the crew's one grant, and
  Aqua then answers. The brain is the chat fixture
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

  test "a newcomer makes a crew member on the brain their administrator's shared key binds, " <>
         "chooses it as Aqua's, and Aqua answers with no sheet",
       %{conn: conn, ctx: ctx, port: port} do
    # The newcomer makes a crew member on the connected brain.
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => "scout",
        "title" => "Scout",
        "catalyst_ref" => Fixture.ref(),
        "model" => "elsewhere"
      })

    conn =
      log_in_user(conn, %{user_id: ctx.user_id, email: "newcomer@example.com", namespace: nil},
        claim: false,
        athanor_id: ctx.athanor_id
      )

    {view, _html} = mount_athanor(conn, "/aqua")

    # Aqua's member's brain is connected by the shared key, so Aqua reads
    # ready, and no card says a grant is out of date: a member holds none.
    assert has_element?(view, "#aqua-card-aqua", "Model connected")
    refute has_element?(view, "#aqua-card-aqua", "changed since you granted it")
    refute has_element?(view, "#aqua-card-scout", "changed since")

    # The setup's brains: the shared key stands first, bound.
    {view, _html} = mount_athanor(conn, "/aqua?setup=1")
    assert has_element?(view, "#aqua-setup[open]")

    [first | _] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#aqua-setup-brains > li")
      |> Enum.map(&LazyHTML.attribute(&1, "id"))

    assert first == ["aqua-setup-brain-chat-fixture"]

    # The member's model is picked on its own setup, the shared key first
    # there too: picking asks nothing.
    {view, _html} = mount_athanor(conn, "/aqua?setup=1&agent=scout")

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
    _ = render(view)
    refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

    # Aqua's step: the member it runs on, chosen here, asks nothing either.
    {view, _html} = mount_athanor(conn, "/aqua?setup=1")
    view |> form("#aqua-setup-member", %{"member" => "scout"}) |> render_change()
    _ = render(view)
    refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
    assert {:ok, %{member: "scout"}} = Compendium.agent(ctx, "aqua")

    # The soul's brain is connected through the key it was shared, read as
    # the person reads it on the screen, whose origin the grant admits.
    person = %{ctx | origin: :interactive}

    assert %{"aqua" => {:ready, _}} =
             Aqua.model_status(person, [%{"name" => "aqua", "catalyst_ref" => Fixture.ref()}])

    # Aqua answers. The share is attach-only, so the brain never holds the
    # key: its request goes to the upstream with the key CYFR attaches.
    said = "Hello from your brain."
    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))

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
