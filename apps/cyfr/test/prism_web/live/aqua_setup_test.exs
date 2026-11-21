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

  setup tags do
    Arca.Cache.init()

    run_dir = Path.join(System.tmp_dir!(), "aqua_setup_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(run_dir) end)

    seed =
      Fixture.lay_seed!(Path.join(run_dir, "seed"),
        mode: :attach,
        seated: Map.get(tags, :seated, true)
      )

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

  # CYFR's own seed ships no crew member: the setup offers to make one on
  # the brain the shared key connects, which the person makes under a
  # name of their own with a model from that brain's own listing. A member holds no grant of its own:
  # making it asks nothing and it is ready at once, and choosing it for
  # Aqua asks nothing and leaves Aqua's grant as it was. Aqua then
  # answers. A second Make under the name of the member made writes
  # nothing.
  #
  # Without Aqua's grant (here, the person revoked it), the brain's own
  # grant standing, choosing grants nothing either: the step for Aqua is
  # not done and says the grant is what Aqua waits on, with its Grant,
  # which opens Aqua's own confirmation; granted there, the step is done
  # and Aqua answers.
  for grant <- [:standing, :revoked] do
    @tag seated: false, grant: grant
    test "a newcomer with no crew makes a member under a name of their own on the shared key, " <>
           "chooses it for Aqua, and Aqua answers, Aqua's grant #{grant}",
         %{conn: conn, ctx: ctx, port: port, grant: grant} do
      walk!(conn, ctx, port, grant)
    end
  end

  defp walk!(conn, ctx, port, grant) do
    actor = Sanctum.Context.actor(ctx)

    if grant == :revoked do
      {:ok, %{revoked: [_ | _]}} = Sanctum.Consent.revoke_source(ctx, Prima.AgentRef.soul_ref())
    end

    person = %{ctx | origin: :interactive}
    member = "Opus"
    key = "catalyst:chat-fixture"
    new = "#aqua-setup-new-member"
    made = "#aqua-setup-made-" <> member
    sheet = ~s(#system-layer-dialog [data-kind="grant"])

    conn =
      log_in_user(conn, %{user_id: ctx.user_id, email: "newcomer@example.com", namespace: nil},
        claim: false,
        athanor_id: ctx.athanor_id
      )

    {view, _html} = mount_athanor(conn, "/aqua?setup=1")

    # The shared key's brain stands connected; the crew's step offers to
    # make a member on it, with the key's own models once it is chosen, and
    # Aqua's waits for one.
    assert has_element?(view, ~s(#aqua-setup-brain-chat-fixture[data-state="ready"]))
    assert has_element?(view, ~s([data-test="setup-aqua-waits"]), "Make a crew member first.")

    wait_until(
      fn -> has_element?(view, new <> ~s| select[name="brain"] option[value="#{key}"]|) end,
      10_000,
      "the key offered"
    )

    view |> form(new, %{"name" => member, "brain" => key}) |> render_change()

    [model | _] =
      for option <-
            view
            |> render()
            |> LazyHTML.from_fragment()
            |> LazyHTML.query(new <> ~s| select[name="model"] option|),
          [value] = LazyHTML.attribute(option, "value"),
          value != "",
          do: value

    view |> form(new, %{"name" => member, "brain" => key, "model" => model}) |> render_submit()

    # Made, it asks nothing, holds no grant of its own and is ready, since
    # its brain is connected.
    assert {:ok, %{"catalyst_ref" => "catalyst:local.chat-fixture", "model" => ^model}} =
             Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => member})

    wait_until(fn -> has_element?(view, made, "ready.") end, 10_000, "the member ready")
    refute has_element?(view, sheet)
    assert {:ok, []} = Arca.ConsentStorage.profiles(actor, Prima.AgentRef.ref(member))

    # Chosen for Aqua, it asks nothing either, and Aqua's grant is what it
    # was before the choice.
    granted = aqua_grant!(actor)
    # Revoked, Aqua holds no grant at all; standing, the one the fill made.
    assert granted == [] == (grant == :revoked)
    view |> form("#aqua-setup-member", %{"member" => member}) |> render_change()

    if grant == :revoked do
      grant_on_page!(view, sheet, fn -> assert aqua_grant!(actor) == granted end)
    end

    wait_until(
      fn -> has_element?(view, ~s([data-test="setup-aqua-done"]), "Aqua runs on #{member}.") end,
      10_000,
      "Aqua seated"
    )

    assert has_element?(view, ~s(#aqua-setup-step-aqua[data-done="true"]))
    refute has_element?(view, ~s([data-test="setup-aqua-grant"]))
    refute has_element?(view, sheet)
    if grant == :standing, do: assert(aqua_grant!(actor) == granted)

    # Aqua answers through the key it was shared, attached on the way to
    # the upstream.
    said = "Hello from your brain."
    {:ok, thread} = Arca.Test.Days.thread(actor)

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
               %{turn_id: ^turn_id, author: "aqua"} = row <- Threads.messages(actor, thread.id),
               do: row
             )

    sent = Fixture.upstream_request!()
    assert for({"x-api-key", value} <- sent.headers, do: value) == [@key]

    # Read again, a second Make under the member's name writes nothing over
    # it.
    {again, _html} = mount_athanor(conn, "/aqua?setup=1")

    wait_until(
      fn ->
        has_element?(again, ~s(#aqua-card-#{member}-model option[value^="chat-fixture::"]))
      end,
      10_000,
      "the catalogue read again"
    )

    {:ok, bytes} = Arca.get(actor, Compendium.AquaPath.crew_file(member))

    html =
      again
      |> with_target("#aqua-agents")
      |> render_submit("make_member", %{"name" => member, "brain" => key, "model" => model})

    assert html =~ "Make failed: Crew member &#39;#{member}&#39; already exists"
    assert {:ok, ^bytes} = Arca.get(actor, Compendium.AquaPath.crew_file(member))
    {:ok, agents, []} = Compendium.AquaAgent.list(ctx)
    assert for(%{name: name} <- agents, name != "aqua", do: name) == [member]

    Cyfr.Test.Sandbox.end_views()
  end

  # Aqua chosen without its grant: the step is not done, and says what
  # Aqua waits on with its Grant, the choice having granted nothing
  # (`unchanged`); the Grant opens Aqua's own confirmation, confirmed.
  defp grant_on_page!(view, sheet, unchanged) do
    line = ~s([data-test="setup-aqua-grant"])

    wait_until(fn -> has_element?(view, line) end, 10_000, "Aqua's grant asked")
    assert has_element?(view, ~s(#aqua-setup-step-aqua[data-done="false"]))
    refute has_element?(view, ~s([data-test="setup-aqua-done"]))

    assert has_element?(
             view,
             line,
             "You have not granted yet what Aqua and its crew members may use."
           )

    refute has_element?(view, sheet)
    unchanged.()

    view |> element(line <> " button", "Grant") |> render_click()
    assert has_element?(view, sheet)
    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
    wait_until(fn -> render(view) =~ "aqua consented." end, 10_000, "the grant said")
  end

  # Aqua's grant as it is stored: each of its profiles with the head
  # consent it holds, whole.
  defp aqua_grant!(actor) do
    {:ok, profiles} = Arca.ConsentStorage.profiles(actor, Prima.AgentRef.soul_ref())

    for profile <- profiles do
      {:ok, head, refs} = Arca.ConsentStorage.get_head(actor, profile.id)
      {profile, head, refs}
    end
  end
end
