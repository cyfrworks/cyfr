# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A store that cannot give the Aqua crew listing; every other read is the
# local adapter's.
defmodule PrismWeb.ThreadPaneLiveTest.UnreadableCrew do
  @moduledoc false
  use Arca.Storage.TestDouble

  @crew Compendium.AquaPath.crew_root()

  def list_typed(_actor, @crew), do: {:error, :eacces}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

defmodule PrismWeb.ThreadPaneLiveTest do
  # The pane on its own: what it says when the session is gone, that what
  # it pushes names the pane it is for and a page it points at is a link,
  # and that a kept model catalogue is read without a run; and in its
  # host, Aqua's panel on the desktop, where a grant is asked and a crew
  # thread opens. On the person's own athanor.
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Tenancy.Athanors

  # A text size under the 12 px a 720×720 glass is held to (WCAG 2.2 AA at
  # that viewport). A test here renders markup and sees no stylesheet: it
  # holds the pane to the shared size classes (`text-xs` and up, `min-h-6`
  # targets) with nothing beside them that could size an element
  # differently — an arbitrary size under 12 px, or an inline style, which
  # outranks every class. The size the classes come to is a browser's to
  # measure.
  @under_12px ~r/text-\[(?:\d|1[01])(?:\.\d+)?px\]/
  @inline_style ~r/\sstyle=/

  # The empty state's way to a model: the Aqua page, named.
  @connect "Connect one on your Aqua page."

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "pane_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      # A turn the test left finishing may still write under the path; the
      # runners are stopped after this callback, so the removal tolerates it.
      File.rm_rf(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    user = test_user()
    athanor = Sanctum.Test.People.athanor!(user.user_id)
    conn = log_in_user(conn, user, athanor_id: athanor.id)
    here = %{Sanctum.TestContext.local(:prism) | user_id: user.user_id, athanor_id: athanor.id}

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(here))

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: user.user_id,
        sent_by: "person",
        content: "hello"
      })

    {:ok, thread} = Threads.get(Sanctum.Context.actor(here), thread.id)

    {:ok, conn: conn, user: user, athanor: athanor, here: here, thread: thread}
  end

  defp route(athanor), do: Athanors.route_slug(athanor)

  # A post's files stored where its refs name them, so the pane draws them
  # as kept: a file whose bytes are gone is drawn as removed.
  defp kept!(actor, row) do
    for ref <- Aqua.Attachments.refs_of(row),
        {:ok, path} <- [Aqua.attachment_blob_path(row.thread_id, row.id, ref)],
        do: :ok = Arca.put(actor, path, "bytes")

    row
  end

  # A nested view mounts after its host renders; look again until it has.
  defp child!(parent, id, tries \\ 50) do
    render(parent)

    case find_live_child(parent, id) do
      nil when tries > 0 ->
        # sleep-ok: poll interval of child!'s bounded wait (50 tries) for the nested view to mount
        Process.sleep(20)
        child!(parent, id, tries - 1)

      nil ->
        flunk("no child #{id} under #{parent.id}")

      child ->
        child
    end
  end

  # The pane on `thread`, mounted on its own; `session` adds to what its
  # host names.
  # What an empty thread shows in place of posts, whichever words its
  # model's state gives it.
  @empty_state ~s([phx-hook="ScrollBottom"] > div.justify-center)

  defp open_pane(conn, athanor, thread, session \\ %{}) do
    {:ok, pane, _} =
      live_isolated(conn, PrismWeb.ThreadPaneLive,
        session: Map.merge(%{"athanor_id" => athanor.id, "thread_id" => thread.id}, session)
      )

    pane
  end

  # A pane turns to a thread by message; look again until it has.
  defp on_thread!(pane, id, tries \\ 50) do
    case :sys.get_state(pane.pid).socket.assigns.thread do
      %{id: ^id} ->
        pane

      _ when tries > 0 ->
        # sleep-ok: poll interval of on_thread!'s bounded wait (50 tries) for the pane to turn
        Process.sleep(20)
        on_thread!(pane, id, tries - 1)

      other ->
        flunk("the pane is on #{inspect(other && other.id)}, not #{id}")
    end
  end

  # The pane in its host: Aqua's panel on the desktop, opened at `thread`
  # as a canvas's `aqua` setting opens it. Answers the panel and its pane.
  defp panel_pane(conn, thread) do
    {desktop, _html} = mount_desktop(conn)
    panel = child!(desktop, "aqua-panel")
    send(panel.pid, {:open, thread.id})
    render(panel)
    {panel, on_thread!(child!(panel, "aqua-panel-pane"), thread.id)}
  end

  # The pages the pane offers as links, by their addresses.
  defp links(pane) do
    pane
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id$="-links"] a))
    |> LazyHTML.attribute("href")
  end

  test "a session that no longer establishes is sent to sign in", %{athanor: athanor} do
    stale =
      Plug.Test.init_test_session(build_conn(), %{
        to_string(CyfrWeb.SignInResponse.session_key()) => "not-a-session"
      })

    assert {:error, {:redirect, %{to: "/login"}}} =
             live_isolated(stale, PrismWeb.ThreadPaneLive, session: %{"athanor_id" => athanor.id})
  end

  test "a thread opens only in its own athanor, and only for that athanor's person",
       %{conn: conn, athanor: athanor} do
    bob = test_user()
    theirs = Sanctum.Test.People.athanor!(bob.user_id)
    bobs = %{Sanctum.TestContext.local(:prism) | user_id: bob.user_id, athanor_id: theirs.id}
    {:ok, secret} = Arca.Test.Days.thread(Sanctum.Context.actor(bobs))

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(bobs), secret.id, %{
        author: bob.user_id,
        sent_by: "person",
        content: "secret plan"
      })

    # Named Bob's thread, the pane on this person's athanor opens nothing of
    # it: the id is not one of its threads.
    pane = open_pane(conn, athanor, secret)
    refute render(pane) =~ "secret plan"
    assert :sys.get_state(pane.pid).socket.assigns.thread == nil

    # Bob's athanor is not this person's to focus a pane on at all.
    assert {:error, {:redirect, %{to: "/"}}} =
             live_isolated(conn, PrismWeb.ThreadPaneLive,
               session: %{"athanor_id" => theirs.id, "thread_id" => secret.id}
             )

    Cyfr.Test.Sandbox.end_views()
  end

  test "a schedule's fire is drawn as that schedule's, never as the person's own line, and is not offered to paste",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    {:ok, fire} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: Prima.Author.system(),
        sent_by: "person",
        content: "summarise what is unread",
        payload: %{"schedule" => %{"id" => "sched_brief", "name" => "Morning brief"}}
      })

    room = PrismWeb.RoomFeed.room("sthr_beside", "Plans")
    pane = open_pane(conn, athanor, thread, %{"room" => room})
    shown = ~s([id$="-m-#{fire.id}"])

    assert has_element?(pane, shown, "Schedule · Morning brief")
    assert has_element?(pane, shown, "summarise what is unread")
    assert has_element?(pane, "#{shown} .items-start")
    refute has_element?(pane, "#{shown} .items-end")
    refute has_element?(pane, "#{shown} .bg-indigo-600")
    refute has_element?(pane, ~s(#{shown} button[phx-click="paste"]))

    # The person's own line beside it is theirs, and theirs to paste.
    assert has_element?(pane, ~s(button[phx-click="paste"]), "Paste to Plans")
  end

  test "a workspace thread's pointer and report are cards with its state as it is now and Open, which opens its layer; a deleted one takes them away",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, %{workspace: workspace}} =
      Arca.TurnStorage.open_workspace(actor, %{
        daily_id: thread.id,
        id: Prima.UUID7.generate_id("thread"),
        title: "Moon report",
        opening: %{
          id: Prima.UUID7.generate_id("msg"),
          author: here.user_id,
          content: "write the moon report",
          payload: %{"ask" => "write the moon report"}
        },
        pointer: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          content: "Moon report",
          payload: %{"workspace" => "w", "title" => "Moon report"}
        },
        files: fn _thread, _message -> {:ok, []} end,
        person_id: here.user_id,
        origin: :interactive
      })

    # A report written as done, of a thread at work again since: the card
    # says what it is now, never the outcome it was written with.
    {:ok, %{message: report}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "report",
          workspace_id: workspace.id,
          content: "The moon report is written.",
          payload: %{
            "workspace" => workspace.id,
            "title" => "Moon report",
            "outcome" => "done",
            "attachments" => [
              %{
                "filename" => "moon.png",
                "stored_name" => "0-moon.png",
                "media_type" => "image/png",
                "size" => 4
              }
            ],
            "links" => [%{"url" => "https://example.com/moon", "title" => "The moon"}]
          }
        }
      })

    kept!(actor, report)
    [pointer] = Enum.filter(Threads.messages(actor, thread.id), &(&1.kind == "pointer"))
    {panel, pane} = panel_pane(conn, thread)

    card = fn msg -> ~s([id$="-m-#{msg.id}"]) end

    assert has_element?(pane, card.(pointer), "Workspace thread")
    assert has_element?(pane, ~s(#{card.(pointer)} [data-raw-content="Moon report"]))
    assert has_element?(pane, ~s(#{card.(pointer)} [data-state="open"]), "Working")
    assert has_element?(pane, ~s(#{card.(report)} [data-state="open"]), "Working")
    refute has_element?(pane, ~s(#{card.(report)} [data-state="done"]))

    # The report keeps its summary, its picture and its link.
    assert has_element?(pane, card.(report), "Report · Moon report")

    assert has_element?(
             pane,
             ~s(#{card.(report)} [data-raw-content="The moon report is written."])
           )

    assert has_element?(pane, ~s(#{card.(report)} img))
    assert has_element?(pane, ~s(#{card.(report)} a[href="https://example.com/moon"]))

    # A move the person's list announces draws both cards again.
    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Thread, where: t.id == ^workspace.id),
        set: [workspace_state: "needs_you"]
      )

    Aqua.ThreadList.changed(here, workspace.id)

    Prima.Test.Wait.wait_until(fn ->
      has_element?(pane, ~s(#{card.(pointer)} [data-state="needs_you"]), "Needs you") and
        has_element?(pane, ~s(#{card.(report)} [data-state="needs_you"]), "Needs you")
    end)

    # Each way its work ends reads as a person reads it.
    for {state, label} <- [{"done", "Finished"}, {"stopped", "Stopped"}, {"error", "Error"}] do
      {1, _} =
        Arca.Repo.update_all(
          from(t in Arca.Schemas.Thread, where: t.id == ^workspace.id),
          set: [workspace_state: state]
        )

      Aqua.ThreadList.changed(here, workspace.id)

      Prima.Test.Wait.wait_until(fn ->
        has_element?(pane, ~s(#{card.(pointer)} [data-state="#{state}"]), label) and
          has_element?(pane, ~s(#{card.(report)} [data-state="#{state}"]), label)
      end)
    end

    # Open opens the workspace thread at its layer, and the panel gives way.
    pane |> element(~s(#{card.(pointer)} button[phx-click="open_thread"])) |> render_click()
    assert_push_event(panel, "navigate", %{to: to})
    assert to == PrismWeb.WorkspaceLive.address(route(athanor), workspace.id)
    refute has_element?(panel, "#aqua-panel-sheet")

    # Deleted, its pointer and reports go from a pane that shows them.
    {_panel, pane} = panel_pane(conn, thread)
    assert has_element?(pane, card.(pointer))
    {:ok, _} = Aqua.Tape.delete_thread(here, workspace.id)

    Prima.Test.Wait.wait_until(fn ->
      not has_element?(pane, card.(pointer)) and not has_element?(pane, card.(report))
    end)

    Cyfr.Test.Sandbox.end_views()
  end

  test "a workspace thread's card opened again behind 500 of a turn's own rows says its state as it is now and keeps Open",
       %{conn: conn, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, %{workspace: _workspace}} =
      Arca.TurnStorage.open_workspace(actor, %{
        daily_id: thread.id,
        id: Prima.UUID7.generate_id("thread"),
        title: "Moon report",
        opening: %{
          id: Prima.UUID7.generate_id("msg"),
          author: here.user_id,
          content: "write the moon report",
          payload: %{"ask" => "write the moon report"}
        },
        pointer: %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          content: "Moon report",
          payload: %{"workspace" => "w", "title" => "Moon report"}
        },
        files: fn _thread, _message -> {:ok, []} end,
        person_id: here.user_id,
        origin: :interactive
      })

    [pointer] = Enum.filter(Threads.messages(actor, thread.id), &(&1.kind == "pointer"))

    for n <- 1..500 do
      {:ok, _} =
        Threads.append(actor, thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "tool_call",
          content: "call #{n}"
        })
    end

    {_panel, pane} = panel_pane(conn, thread)
    card = ~s([id$="-m-#{pointer.id}"])
    assert has_element?(pane, ~s(#{card} [data-state="open"]), "Working")
    assert has_element?(pane, ~s(#{card} button[phx-click="open_thread"]))
    refute render(pane) =~ "was deleted"
  end

  test "a card whose workspace thread cannot be found has no Open",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    # A report as the tape announces it, naming a workspace thread that no
    # longer stands.
    {:ok, %{message: said}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: Prima.Author.agent(), sent_by: "aqua", content: "Done."}
      })

    # The row as a store whose thread went would hand it over.
    report = %{said | kind: "report", workspace_id: "thr_gone"}
    pane = open_pane(conn, athanor, thread)

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: athanor.id,
      thread_id: thread.id,
      kind: :message,
      data: report
    })

    Prima.Test.Wait.wait_until(fn ->
      has_element?(pane, ~s([id$="-m-#{report.id}"]), "This workspace thread was deleted")
    end)

    refute has_element?(pane, ~s([id$="-m-#{report.id}"] button[phx-click="open_thread"]))
  end

  test "a row a turn writes for itself, a page's call's answer among them, is no post as it lands",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, %{message: said}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: Prima.Author.agent(), sent_by: "aqua", content: "a post"}
      })

    pane = open_pane(conn, athanor, thread)

    for kind <- ~w(page_call page_result tool_call tool_result) do
      row = %{said | id: "msg_#{kind}", kind: kind, content: ~s({"ok":true,"v":1})}

      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: athanor.id,
        thread_id: thread.id,
        kind: :message,
        data: row
      })
    end

    # A post sent after them lands, so they were taken first.
    landed = %{said | id: "msg_later", content: "a later post"}

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: athanor.id,
      thread_id: thread.id,
      kind: :message,
      data: landed
    })

    Prima.Test.Wait.wait_until(fn -> has_element?(pane, ~s([id$="-m-msg_later"])) end)

    for kind <- ~w(page_call page_result tool_call tool_result),
        do: refute(has_element?(pane, ~s([id$="-m-msg_#{kind}"])))
  end

  test "the menu shows the model a program's turn ran and its tokens, saying when they are " <>
         "partial or unknown",
       %{conn: conn, athanor: athanor, thread: thread} do
    pane = open_pane(conn, athanor, thread)

    told = fn usage ->
      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: athanor.id,
        thread_id: thread.id,
        kind: :usage,
        data: usage
      })

      menu = pane |> element(~s([id$="-menu"])) |> render()
      menu |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")
    end

    assert told.(%{input: 0, output: 0, models: [], accounting: :unavailable}) =~
             "Model default"

    assert told.(%{input: 0, output: 0, models: [], accounting: :unavailable}) =~
             "Tokens unknown"

    menu = told.(%{input: 12, output: 3, models: ["claude-opus-5-5"], accounting: :partial})
    assert menu =~ "claude-opus-5-5"
    assert menu =~ "Tokens 12 in · 3 out, partial"

    menu = told.(%{input: 20, output: 5, models: ["claude-opus-5-5"], accounting: :complete})
    assert menu =~ "Tokens 20 in · 5 out"
    refute menu =~ "partial"

    # An API brain's turn tells its tokens alone.
    assert told.(%{input: 7, output: 2}) =~ "Model default"
    assert told.(%{input: 7, output: 2}) =~ "Tokens 7 in · 2 out"
  end

  test "the line a stopped turn leaves is drawn as it lands, as the thread draws it on open, " <>
         "as the server's and never as the person's",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    pane = open_pane(conn, athanor, thread)

    {:ok, stopped} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: Prima.Author.system(),
        sent_by: "aqua",
        kind: "turn_aborted",
        content: "stopped"
      })

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: athanor.id,
      thread_id: thread.id,
      kind: :message,
      data: stopped
    })

    landed = ~s([id$="-m-#{stopped.id}"])
    Prima.Test.Wait.wait_until(fn -> has_element?(pane, landed, "stopped") end)

    for pane <- [pane, open_pane(conn, athanor, thread)] do
      assert has_element?(pane, landed <> " .italic", "stopped")
      refute has_element?(pane, landed <> " .bg-indigo-600")
      refute has_element?(pane, landed <> " .items-end")
    end
  end

  test "a thread opened again draws what the live thread drew: a turn's calls, their results " <>
         "and its compaction are no posts",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, said} =
      Threads.append(actor, thread.id, %{
        author: Prima.Author.agent(),
        sent_by: "aqua",
        content: "a post"
      })

    kept =
      for kind <- ~w(tool_call tool_result page_call page_result compaction) do
        {:ok, row} =
          Threads.append(actor, thread.id, %{
            author: Prima.Author.agent(),
            sent_by: "aqua",
            kind: kind,
            content: "#{kind} words"
          })

        row
      end

    pane = open_pane(conn, athanor, thread)
    assert has_element?(pane, ~s([id$="-m-#{said.id}"]))

    for row <- kept do
      refute has_element?(pane, ~s([id$="-m-#{row.id}"]))
      refute render(pane) =~ row.content
    end
  end

  test "a thread opened again draws its latest posts, however many of a turn's own rows follow them",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, said} =
      Threads.append(actor, thread.id, %{
        author: Prima.Author.agent(),
        sent_by: "aqua",
        content: "a post"
      })

    for n <- 1..500 do
      {:ok, _} =
        Threads.append(actor, thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "tool_call",
          content: "call #{n}"
        })
    end

    pane = open_pane(conn, athanor, thread)
    assert has_element?(pane, ~s([id$="-m-#{said.id}"] [data-raw-content="a post"]))
    refute has_element?(pane, @empty_state)
  end

  test "a thread holding only a turn's own rows opens as an empty thread",
       %{conn: conn, athanor: athanor, here: here} do
    actor = Sanctum.Context.actor(here)
    {:ok, thread} = Arca.Test.Days.thread(actor)
    assert has_element?(open_pane(conn, athanor, thread), @empty_state)

    for kind <- ~w(tool_call tool_result compaction) do
      {:ok, _} =
        Threads.append(actor, thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: kind,
          content: "#{kind} words"
        })
    end

    assert has_element?(open_pane(conn, athanor, thread), @empty_state)
  end

  describe "the menu's tokens, opened again" do
    # A turn of the thread, over, whose model step told `usage`: no runner
    # holds what it counted.
    defp counted_turn!(here, thread, usage) do
      actor = Sanctum.Context.actor(here)
      turn = turn!(here, thread)

      {:ok, model} =
        Arca.TurnStorage.put_step(actor, turn.id, %{kind: "model", fence: turn.fence})

      {:ok, _} =
        Arca.TurnStorage.commit_events(
          actor,
          %{thread: turn.thread_id, agent: turn.agent, turn: %{id: turn.id, fence: turn.fence}},
          %{
            events: [
              {:text, %{text: "done"}},
              {:usage,
               %{"models" => [%{"model" => "m", "counts" => usage}], "accounting" => "complete"}}
            ],
            position: {:step, model.id}
          }
        )

      ended!(turn)
    end

    # A turn of the thread on a program, over: its `program.start` step,
    # keyed as the loop keys it, holds `usage` as the program's counts
    # store it, or none.
    defp program_turn!(here, thread, usage) do
      turn = turn!(here, thread)

      {:ok, step} =
        Arca.TurnStorage.put_step(Sanctum.Context.actor(here), turn.id, %{
          kind: "tool",
          purpose: "brain",
          tool: "program",
          action: "start",
          idempotency_key: Arca.TurnStorage.admission_key(turn.id),
          fence: turn.fence
        })

      if usage,
        do:
          {1, _} =
            Arca.Repo.update_all(from(s in Arca.Schemas.TurnStep, where: s.id == ^step.id),
              set: [usage: Jason.encode!(usage)]
            )

      ended!(turn)
    end

    defp turn!(here, thread) do
      {:ok, %{turn: turn}} =
        Arca.TurnStorage.accept_message(Sanctum.Context.actor(here), thread.id, %{
          message: %{author: here.user_id, sent_by: "person", content: "count it"},
          turn: %{agent: "aqua", requested_by: here.user_id, origin: :interactive}
        })

      # Started as `Arca.TurnStorage.start/3` starts it: running, with
      # the recovery limit only a start writes.
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [status: "running", recovery_limit: 1]
        )

      turn
    end

    defp ended!(turn, status \\ "completed") do
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [status: status]
        )

      turn
    end

    defp menu_text(pane) do
      pane
      |> element(~s([id$="-menu"]))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "an API brain's counted turn reads its stored tokens",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      counted_turn!(here, thread, %{"input_tokens" => 40, "output_tokens" => 9})
      assert menu_text(open_pane(conn, athanor, thread)) =~ "Tokens 40 in · 9 out"
    end

    test "a program's counted turn reads its stored model and tokens",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      program_turn!(here, thread, %{
        "models" => %{
          "claude-opus-5-5" => %{"input_tokens" => 120, "output_tokens" => 30}
        },
        "results" => 1,
        "partial" => 0,
        "unknown" => 0
      })

      menu = menu_text(open_pane(conn, athanor, thread))
      assert menu =~ "claude-opus-5-5"
      assert menu =~ "Tokens 120 in · 30 out"
    end

    test "a turn stopped while it waited behind a counted one never ran: the menu reads the counted turn's",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      counted =
        program_turn!(here, thread, %{
          "models" => %{
            "claude-opus-5-5" => %{"input_tokens" => 120, "output_tokens" => 30}
          },
          "results" => 1,
          "partial" => 0,
          "unknown" => 0
        })

      # A Stop cancels the running turn and the one queued behind it.
      ended!(counted, "cancelled")

      {:ok, %{turn: queued}} =
        Arca.TurnStorage.accept_message(Sanctum.Context.actor(here), thread.id, %{
          message: %{author: here.user_id, sent_by: "person", content: "and then"},
          turn: %{agent: "aqua", requested_by: here.user_id, origin: :interactive}
        })

      ended!(queued, "cancelled")

      menu = menu_text(open_pane(conn, athanor, thread))
      assert menu =~ "claude-opus-5-5"
      assert menu =~ "Tokens 120 in · 30 out"
    end

    test "a program's turn that counted nothing reads unknown, never zero",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      program_turn!(here, thread, nil)
      assert menu_text(open_pane(conn, athanor, thread)) =~ "Tokens unknown"
    end
  end

  test "a nudge, the server's line to the thread's Aqua, is drawn as the server's as it lands",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, %{message: said}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: Prima.Author.agent(), sent_by: "aqua", content: "a post"}
      })

    pane = open_pane(conn, athanor, thread)

    line = %{
      said
      | id: "msg_nudge",
        kind: "nudge",
        author: Prima.Author.system(),
        sent_by: Prima.Author.system(),
        content: "Nothing has happened in this workspace thread."
    }

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: athanor.id,
      thread_id: thread.id,
      kind: :message,
      data: line
    })

    Prima.Test.Wait.wait_until(fn ->
      has_element?(
        pane,
        ~s([id$="-m-msg_nudge"]),
        "Nothing has happened in this workspace thread."
      )
    end)

    assert has_element?(pane, ~s([id$="-m-msg_nudge"] .italic))
    refute has_element?(pane, ~s([id$="-m-msg_nudge"] .bg-indigo-600))
  end

  test "a post of the server's own on a daily thread counts as unread, and is drawn as the server's " <>
         "on opening the pane and as it lands, never as the person's or the assistant's",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)
    {:ok, unseen} = Threads.get(actor, thread.id)
    {:ok, before} = Threads.unread(actor, unseen)

    post = fn content ->
      {:ok, row} =
        Aqua.Tape.append(here, thread.id, %{
          author: Prima.Author.system(),
          sent_by: Prima.Author.system(),
          content: content
        })

      row
    end

    kept = post.("Needs your attention: the workspace thread Moon report is waiting on you.")
    {:ok, unseen} = Threads.get(actor, thread.id)
    assert {:ok, count} = Threads.unread(actor, unseen)
    assert count == before + 1

    pane = open_pane(conn, athanor, thread)
    landed = post.("Needs your attention: the workspace thread Sun report ran into an error.")
    Prima.Test.Wait.wait_until(fn -> has_element?(pane, ~s([id$="-m-#{landed.id}"])) end)

    for row <- [kept, landed] do
      shown = ~s([id$="-m-#{row.id}"])
      assert has_element?(pane, shown, row.content)
      assert has_element?(pane, ~s(#{shown} [class*="bg-sky-950"]))
      assert has_element?(pane, "#{shown} .items-start")
      refute has_element?(pane, "#{shown} .items-end")
      refute has_element?(pane, "#{shown} .bg-indigo-600")
      refute has_element?(pane, ~s(#{shown} [phx-hook="MarkdownContent"]))
      refute has_element?(pane, shown, "Schedule ·")
    end
  end

  test "the thread shown is read to its newest row as it opens and as each row lands, never back",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, said} =
      Threads.append(actor, thread.id, %{
        author: Prima.Author.agent(),
        sent_by: "aqua",
        content: "an answer"
      })

    {:ok, unseen} = Threads.get(actor, thread.id)
    assert {:ok, 1} = Threads.unread(actor, unseen)

    pane = open_pane(conn, athanor, thread)
    assert {:ok, %{read_seq: seq}} = Threads.get(actor, thread.id)
    assert seq == said.seq

    {:ok, later} =
      Aqua.Tape.append(here, thread.id, %{
        author: Prima.Author.agent(),
        sent_by: "aqua",
        content: "a later answer"
      })

    landed = later.seq

    Prima.Test.Wait.wait_until(
      fn -> match?({:ok, %{read_seq: ^landed}}, Threads.get(actor, thread.id)) end,
      5_000,
      "the read mark at the row that landed"
    )

    # A row heard again, behind the mark, moves nothing.
    Aqua.Tape.announce(here, thread.id, :message, said)
    _ = render(pane)
    assert {:ok, %{read_seq: ^landed} = seen} = Threads.get(actor, thread.id)
    assert {:ok, 0} = Threads.unread(actor, seen)
  end

  test "what the pane pushes names the pane it is for, and a page it points at is a link, never pushed",
       %{conn: conn, user: user, athanor: athanor, thread: thread} do
    # The pages these navigate to are dev's, the mode the host names.
    pane = open_pane(conn, athanor, thread, %{"ui_mode" => "dev"})
    pane_id = pane.id <> "-pane"
    intents = [%{kind: "copy_clipboard", text: "friday"}, %{kind: "navigate", to: "/activities"}]

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: user.user_id}
    })

    render(pane)

    assert_push_event(pane, "aqua:intents", %{pane: ^pane_id, intents: pushed})
    assert [%{kind: "copy_clipboard"}] = pushed
    assert links(pane) == [PrismWeb.Focus.path(route(athanor), "/activities")]

    pane |> element(~s(button[phx-click="dismiss_link"])) |> render_click()
    assert links(pane) == []

    # Another person's intents are theirs alone.
    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: "someone-else"}
    })

    render(pane)
    refute_push_event(pane, "aqua:intents", %{intents: _})
    assert links(pane) == []
  end

  test "a navigate is offered only for a page the console serves", %{
    conn: conn,
    user: user,
    athanor: athanor,
    thread: thread
  } do
    # The pages these navigate to are dev's, the mode the host names.
    pane = open_pane(conn, athanor, thread, %{"ui_mode" => "dev"})

    intents = [
      %{kind: "navigate", to: "/etc/passwd"},
      # Under a page the nav offers, but no route serves it.
      %{kind: "navigate", to: "/components/not/a/page"},
      %{kind: "navigate", to: "/executions?id=exec_a"}
    ]

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: user.user_id}
    })

    render(pane)

    assert links(pane) == [PrismWeb.Focus.path(route(athanor), "/executions?id=exec_a")]
    refute_push_event(pane, "aqua:intents", %{intents: _})
  end

  test "a kept model catalogue is read on mount without a run", %{
    conn: conn,
    athanor: athanor,
    thread: thread,
    here: here
  } do
    :ok = PrismWeb.ModelCatalog.remember(athanor.id, %{"models" => %{"kept" => ["kept-model-1"]}})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(athanor.id) end)

    # A hit answers the caller at once — the result is in the mailbox before
    # `load/1` returns, so no run was spawned and no deadline armed — with
    # or without an engine on the box.
    assert :ok = PrismWeb.ModelCatalog.load(here)

    assert_received {:list_models_result, _tag,
                     {:ok, %{"models" => %{"kept" => ["kept-model-1"]}}}}

    pane = open_pane(conn, athanor, thread)
    assert has_element?(pane, ~s(select[name="model"] option[value="kept-model-1"]))
  end

  test "the pane's copy: its chrome and the composer's stop", %{
    conn: conn,
    athanor: athanor,
    thread: thread
  } do
    html = render(open_pane(conn, athanor, thread))
    assert html =~ "Aqua or the crew member this thread is on"
    refute html =~ "autofocus"
    refute html =~ ~r/\bagent\b/
    refute html =~ "A.Q.U.A."
  end

  test "a line says once that what Aqua reads in a shared thread goes to the person's model provider, until they dismiss it",
       %{conn: conn, user: user, athanor: athanor, thread: thread} do
    sentence =
      "Aqua reads your shared threads when you ask about them. What it reads there, other people's words included, goes to your model provider."

    pane = open_pane(conn, athanor, thread)
    assert has_element?(pane, ~s([id$="-reads-notice"]), sentence)

    # Another mount, before it is dismissed, says it again.
    again = open_pane(conn, athanor, thread)
    assert has_element?(again, ~s([id$="-reads-notice"]), sentence)

    again |> element(~s(button[phx-click="dismiss_reads_notice"])) |> render_click()
    refute has_element?(again, ~s([id$="-reads-notice"]))

    {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
    assert Sanctum.Tenancy.Users.prefs(row)["aqua_reads_threads_seen"] == true

    # Kept on the person's own row: no mount says it again.
    refute has_element?(open_pane(conn, athanor, thread), ~s([id$="-reads-notice"]))
  end

  test "at 720×720 an open thread's text and small targets carry the shared size classes alone",
       %{
         conn: conn,
         athanor: athanor,
         thread: thread
       } do
    room = PrismWeb.RoomFeed.room("sthr_beside", "Plans")
    pane = open_pane(conn, athanor, thread, %{"room" => room})
    html = render(pane)
    assert html =~ "hello"

    # Every text class the pane draws is `text-xs` or larger, and its small
    # targets carry `min-h-6`: the line's author, its paste onto the shared
    # thread beside it, and the box that reads that thread. Nothing is
    # sized inline.
    refute html =~ @under_12px
    refute html =~ @inline_style
    assert has_element?(pane, "span.text-xs", "You")
    assert has_element?(pane, "button.min-h-6.text-xs", "Paste to Plans")
    assert has_element?(pane, ~s(label[id$="-read-room"].text-xs input.h-6.w-6))
  end

  test "at 720×720 every state the pane draws holds the same size classes", %{
    conn: conn,
    user: user,
    athanor: athanor,
    here: here,
    thread: thread
  } do
    # A state no test here reaches — a held send, the panel's links and
    # its read-the-thread box — is held by the template itself: no text
    # class under 12 px and no inline style anywhere, and each of those
    # small targets on `min-h-6`.
    source =
      PrismWeb.ThreadPaneLive.module_info(:compile)[:source] |> to_string() |> File.read!()

    refute source =~ @under_12px
    refute source =~ @inline_style

    for click <- ~w(retry_send discard_send dismiss_link dismiss_reads_notice) do
      assert source =~ ~r/phx-click="#{click}"[^>]*class="[^"]*min-h-6/,
             "the #{click} control is under 24 px"
    end

    assert source =~ ~r/phx-click="toggle_read_room"[^>]*class="h-6 w-6/

    {:ok, two} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: user.user_id,
        sent_by: "person",
        content: "two files",
        payload: %{
          "attachments" => [
            %{"filename" => "notes.md", "stored_name" => "abc_notes.md"},
            %{"filename" => "kept-elsewhere.txt"}
          ]
        }
      })

    kept!(Sanctum.Context.actor(here), two)

    pane = open_pane(conn, athanor, thread)

    event = fn kind, data ->
      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: thread.athanor_id,
        thread_id: thread.id,
        kind: kind,
        data: data
      })
    end

    # A turn running for this person with a message queued behind it, its
    # tools at work and the prompt to send again.
    event.(:turn_starting, user.user_id)
    event.(:queued, 2)
    event.(:tool_activity, [%{tool: "files.read", status: :running, preview: "notes.md"}])
    event.(:restart_prompt, %{text: "two files", user_id: user.user_id})

    # A file on its way up.
    pane
    |> file_input("form[phx-submit=submit]", :attachments, [
      %{name: "draft.txt", content: "x", type: "text/plain"}
    ])
    |> render_upload("draft.txt", 40)

    html = render(pane)

    for drawn <- [
          "You are asking…",
          "2 queued",
          "files.read",
          "send it again",
          "draft.txt",
          "kept-elsewhere.txt"
        ],
        do: assert(html =~ drawn, "#{drawn} is not drawn")

    refute html =~ @under_12px
    refute html =~ @inline_style

    assert has_element?(pane, ~s(button.min-h-6.min-w-6[phx-click="cancel_upload"]))
    assert has_element?(pane, ~s(button.min-h-6[phx-click="restart_send"]))
    assert has_element?(pane, ~s(button.min-h-6[phx-click="dismiss_restart"]))
    assert has_element?(pane, "a.min-h-6.text-xs[download]", "notes.md")
    assert has_element?(pane, "span.text-xs", "kept-elsewhere.txt")
  end

  test "a file the composer refuses says why beside it, until it is removed", %{
    conn: conn,
    athanor: athanor,
    thread: thread
  } do
    pane = open_pane(conn, athanor, thread)

    files = [
      %{
        name: "big.bin",
        content: :binary.copy("x", Aqua.attachment_limits().max_file_bytes + 1),
        type: "application/octet-stream"
      }
    ]

    # The refusal is the upload's own, made as it is announced.
    pane |> file_input("form[phx-submit=submit]", :attachments, files) |> preflight_upload()

    assert has_element?(pane, ~s([data-test="upload-refusal"]), "too large, remove it")

    pane |> element(~s(button[phx-click="cancel_upload"])) |> render_click()

    refute has_element?(pane, ~s([data-test="upload-refusal"]))
  end

  test "more files than a message takes are said in the composer, until one is removed", %{
    conn: conn,
    athanor: athanor,
    thread: thread
  } do
    pane = open_pane(conn, athanor, thread)

    files =
      for n <- 0..Aqua.attachment_limits().max_files,
          do: %{name: "f#{n}.txt", content: "x", type: "text/plain"}

    pane |> file_input("form[phx-submit=submit]", :attachments, files) |> preflight_upload()

    assert has_element?(pane, ~s([data-test="upload-refusal"]), "too many files, remove some")

    pane
    |> element(~s(div:first-child > button[phx-click="cancel_upload"]))
    |> render_click()

    refute has_element?(pane, ~s([data-test="upload-refusal"]))
  end

  test "the person a running turn is for is named with the verb that agrees with them", %{
    conn: conn,
    user: user,
    athanor: athanor,
    thread: thread
  } do
    pane = open_pane(conn, athanor, thread)
    other = "usr_" <> Ecto.UUID.generate()

    starting = fn user_id ->
      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: thread.athanor_id,
        thread_id: thread.id,
        kind: :turn_starting,
        data: user_id
      })

      render(pane)
    end

    html = starting.(user.user_id)
    assert html =~ "You are asking…"
    refute html =~ "You is asking"

    assert starting.(other) =~ "#{PrismWeb.People.label(other, nil)} is asking…"
  end

  test "a screenshot Aqua posted is drawn in place, opens large, and its address gives the picture",
       %{conn: conn, athanor: athanor, here: here, thread: thread} do
    actor = Sanctum.Context.actor(here)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: here.user_id, sent_by: "person", content: "look at the moon"},
        turn: %{agent: "aqua", requested_by: here.user_id, origin: :interactive}
      })

    root = "exe_shot_root_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: root, status: "running"]
      )

    {:ok, turn} = Aqua.Tape.turn(here, turn.id)
    png = <<137, 80, 78, 71, 13, 10, 26, 10, "the moon">>
    file = %{"filename" => "screenshot.png", "media_type" => "image/png", "bytes" => png}

    {:ok, shot, _ref} = Aqua.Attachments.draft(here, turn, file, [])

    {:ok, %{posted: post_id}} =
      Aqua.Providers.Thread.handle("thread", Sanctum.Context.enter_guest(here), %{
        "action" => "post",
        "thread_id" => thread.id,
        "root_execution_id" => root,
        "parent_execution_id" => root,
        "screenshot" => shot
      })

    pane = open_pane(conn, athanor, thread)
    picture = PrismWeb.Focus.path(route(athanor), "/attachments/#{post_id}/0-screenshot.png")

    assert has_element?(
             pane,
             ~s(button[aria-label="Open screenshot.png large"] img[src="#{picture}"])
           )

    assert has_element?(
             pane,
             ~s([id$="-msg-#{post_id}-picture-0"].hidden [role=dialog] img[src="#{picture}"])
           )

    assert conn |> get(picture) |> response(200) == png
  end

  describe "a post draws what it holds" do
    setup %{here: here, thread: thread, user: user} do
      pictures = fn n ->
        [
          %{
            "filename" => "shot #{n}.png",
            "stored_name" => "0-shot_#{n}.png",
            "media_type" => "image/png"
          },
          %{
            "filename" => "logo.svg",
            "stored_name" => "1-logo.svg",
            "media_type" => "image/svg+xml"
          },
          %{
            "filename" => "report.pdf",
            "stored_name" => "2-report.pdf",
            "media_type" => "application/pdf"
          },
          %{"filename" => "gone.png", "media_type" => "image/png"}
        ]
      end

      links = [
        %{"url" => "https://example.com/plan", "title" => "The plan"},
        %{"url" => "http://example.org/raw"},
        %{"url" => "javascript:alert(1)", "title" => "a script"},
        %{"url" => "data:text/html,<p>x</p>", "title" => "a data address"},
        %{"url" => "https://", "title" => "no host"},
        %{"title" => "no address"}
      ]

      {:ok, mine} =
        Threads.append(Sanctum.Context.actor(here), thread.id, %{
          author: user.user_id,
          sent_by: "person",
          content: "my screenshot",
          payload: %{"attachments" => pictures.(1), "links" => links}
        })

      {:ok, aquas} =
        Threads.append(Sanctum.Context.actor(here), thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          # A post may hold no text at all.
          content: "",
          payload: %{"attachments" => pictures.(2), "links" => links}
        })

      Enum.each([mine, aquas], &kept!(Sanctum.Context.actor(here), &1))

      {:ok, posts: [mine, aquas]}
    end

    test "a picture is shown in place and opens large, any other file is a chip that downloads, " <>
           "and a link is a link, whoever wrote the post",
         %{conn: conn, athanor: athanor, thread: thread, posts: posts} do
      pane = open_pane(conn, athanor, thread)

      for {post, n} <- Enum.zip(posts, [1, 2]) do
        href = &PrismWeb.Focus.path(route(athanor), "/attachments/#{post.id}/#{&1}")
        large = ~s([id$="-msg-#{post.id}-picture-0"])

        # The PNG: drawn in place, at the attachment address, and drawn
        # large in a dialog that starts hidden.
        picture = href.("0-shot_#{n}.png")

        assert has_element?(
                 pane,
                 ~s(button[aria-label="Open shot #{n}.png large"] img[src="#{picture}"])
               )

        assert has_element?(
                 pane,
                 ~s(#{large}.hidden [role=dialog][aria-label="shot #{n}.png"] img[src="#{picture}"])
               )

        assert has_element?(pane, ~s(#{large} button[id$="-picture-0-close"].min-h-6), "Close")
        refute has_element?(pane, ~s(a[download="shot #{n}.png"]))

        # An SVG runs script and a PDF is no picture: each is a chip that
        # downloads.
        assert has_element?(
                 pane,
                 ~s(a.min-h-6[href="#{href.("1-logo.svg")}"][download="logo.svg"])
               )

        assert has_element?(
                 pane,
                 ~s(a.min-h-6[href="#{href.("2-report.pdf")}"][download="report.pdf"])
               )

        refute has_element?(pane, ~s(img[src="#{href.("1-logo.svg")}"]))
        refute has_element?(pane, ~s(img[alt="gone.png"]))

        # Links: an http or https address with a host, under its title or
        # itself, opened apart from the page; nothing else is a link.
        assert has_element?(
                 pane,
                 ~s(a.min-h-6[href="https://example.com/plan"][target=_blank][rel="noopener noreferrer"]),
                 "The plan"
               )

        assert has_element?(pane, ~s(a[href="http://example.org/raw"]), "http://example.org/raw")
      end

      # A file not stored is a chip with no address.
      assert has_element?(pane, "span.text-xs", "gone.png")
      refute has_element?(pane, ~s(a[download="gone.png"]))

      html = render(pane)

      for gone <- [
            "javascript:",
            "data:text/html",
            "a script",
            "a data address",
            "no host",
            "no address"
          ],
          do: refute(html =~ gone, "#{gone} is drawn")

      refute html =~ @under_12px
      refute html =~ @inline_style
    end

    test "Escape closes a picture opened large from where opening it put the focus, " <>
           "and gives the focus back to the picture",
         %{conn: conn, athanor: athanor, thread: thread} do
      doc = conn |> open_pane(athanor, thread) |> render() |> LazyHTML.from_fragment()

      opens =
        doc |> LazyHTML.query(~s(button[aria-label$=" large"])) |> LazyHTML.attribute("phx-click")

      # One picture in each of the two posts.
      assert length(opens) == 2

      for open <- opens do
        ops = Jason.decode!(open)
        [large] = for ["remove_class", %{"names" => ["hidden"], "to" => to}] <- ops, do: to
        [focused] = for ["focus", %{"to" => to}] <- ops, do: to
        assert ["push_focus", _] = hd(ops)

        # LiveView reads a key binding from the key's own target alone, never
        # an ancestor's: the element opening puts the focus on carries it.
        held = LazyHTML.query(doc, focused)
        assert LazyHTML.attribute(held, "phx-key") == ["Escape"]
        assert [escape] = LazyHTML.attribute(held, "phx-keydown")
        escape = Jason.decode!(escape)

        assert ["add_class", %{"names" => ["hidden"], "to" => ^large}] =
                 Enum.find(escape, &(hd(&1) == "add_class"))

        assert Enum.any?(escape, &(hd(&1) == "pop_focus"))

        # It sits inside the large view's own dialog, whose Escape the panel
        # leaves to it (`aqua_panel/index.js`).
        assert doc |> LazyHTML.query(~s(#{large} [role=dialog] #{focused})) |> Enum.count() == 1
      end
    end
  end

  test "a turn stopped on an unknown outcome shows so until it goes on", %{
    conn: conn,
    athanor: athanor,
    thread: thread,
    user: user
  } do
    pane = open_pane(conn, athanor, thread)

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_starting,
      data: user.user_id
    })

    assert render(pane) =~ "Thinking"

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_paused,
      data: %{turn_id: "trn_x", reason: :uncertain}
    })

    html = render(pane)
    assert html =~ "Stopped: a tool"
    assert html =~ "Your next message continues this turn"
    refute html =~ "Thinking"
    assert has_element?(pane, ~s(button[phx-click="stop"]))

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_starting,
      data: user.user_id
    })

    refute render(pane) =~ "Stopped: a tool"

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_finished
    })

    refute has_element?(pane, ~s(button[phx-click="stop"]))
  end

  test "a turn's end is announced as a reply only when the turn wrote one", %{
    conn: conn,
    athanor: athanor,
    thread: thread,
    user: user,
    here: here
  } do
    pane = open_pane(conn, athanor, thread)

    turn = fn kind, data ->
      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: thread.athanor_id,
        thread_id: thread.id,
        kind: kind,
        data: data
      })
    end

    announced = fn ->
      pane
      |> element(~s([id$="-announcer"]))
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()
    end

    # A turn that ends with no reply (a refused key, a failure) is not
    # announced as one.
    turn.(:turn_starting, user.user_id)
    turn.(:turn_finished, nil)
    assert announced.() == "Aqua stopped without a reply."

    {:ok, reply} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: "aqua",
        sent_by: "aqua",
        content: "Here it is."
      })

    turn.(:turn_starting, user.user_id)
    turn.(:turn_started, "trn_replied")
    turn.(:message, reply)
    turn.(:turn_finished, nil)
    assert announced.() == "Aqua replied."
  end

  # A component in `ctx`'s athanor a turn can ask a grant for.
  defp grantable!(ctx) do
    name = "pane-grant-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A component a turn asks a grant for",
        manifest: Jason.encode!(%{})
      })

    {"catalyst:local.#{name}", "catalyst:local.#{name}:0.1.0"}
  end

  defp consent_required(pane, thread, ref, user_id) do
    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :consent_required,
      data: %{ref: ref, user_id: user_id}
    })

    render(pane)
  end

  test "a grant the turn needs is asked in the layer of the view that renders the pane, never on the pane",
       %{conn: conn, user: user, thread: thread, here: here} do
    {name_ref, ref} = grantable!(here)
    {panel, pane} = panel_pane(conn, thread)
    dialog = "#system-layer-panel-dialog"

    # Another person's turn asks them, not this person.
    consent_required(pane, thread, ref, "someone-else")
    refute render(panel) =~ ~s(data-kind="grant")

    consent_required(pane, thread, ref, user.user_id)
    render(panel)
    assert has_element?(panel, ~s(#{dialog} [data-kind="grant"]))
    assert has_element?(panel, ~s(#{dialog} [data-test="grant-sheet"]))
    refute has_element?(pane, ".consent-sheet")

    # Said again while it is open: the open prompt already asks it.
    consent_required(pane, thread, ref, user.user_id)
    refute render(panel) =~ "waiting."

    # Granted in the panel's layer, under the panel's context in the pane's
    # athanor; the pane hears it and lets the prompt go.
    panel |> element(~s(#{dialog} button[phx-click="confirm"])) |> render_click()

    # The layer asks its sheet for the walk and commits; the panel takes its
    # layer's report, then the pane the one it hands on.
    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the pane to hear its grant"
    )

    refute render(panel) =~ ~s(data-kind="grant")
    assert {:ok, [_profile | _]} = Sanctum.Consent.profiles(here, name_ref)

    Cyfr.Test.Sandbox.end_views()
  end

  # An app in `ctx`'s athanor whose own calls carry one credential need,
  # with an entry of its provider in the vault for the grant to suggest.
  defp needy_app!(ctx) do
    name = "pane-account-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "0.1.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "required" => true,
          "fields" => ["KEY"],
          "hosts" => ["api.example.com"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    {:ok, _entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "#{name} key",
        kind: "api_key",
        provider_hint: "example.com",
        fields: %{"KEY" => "k"},
        destination: %{"hosts" => ["api.example.com"]},
        disclose: true
      })

    {"catalyst:local.#{name}", "catalyst:local.#{name}:0.1.0"}
  end

  # The text line of `thread` whose content is `content`: the message a
  # turn answered.
  defp line_id!(here, thread, content) do
    rows = Threads.latest_messages(Sanctum.Context.actor(here), thread.id, 500)
    assert %{id: id} = Enum.find(rows, &(&1.kind == "text" and &1.content == content))
    id
  end

  # A launch's account the ended turn (its message `message_id`) asked
  # for, asked in the panel's layer on a fresh app's own profile and
  # granted there. Answers the panel and the pane once the pane has heard
  # its grant.
  defp grant_launch_account!(conn, thread, user, here, message_id) do
    {_name_ref, ref} = needy_app!(here)
    {panel, pane} = panel_pane(conn, thread)
    dialog = "#system-layer-panel-dialog"

    data = %{ref: ref, user_id: user.user_id, account: %{name: "Supabase 2", need: nil}}

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :consent_required,
      data: if(message_id, do: Map.put(data, :message_id, message_id), else: data)
    })

    render(pane)
    render(panel)
    assert has_element?(panel, ~s(#{dialog} [data-kind="grant"]))

    # The prompt is for the app's own calls, opened on the account the
    # launch named.
    assert %{grant_prompt: prompt_id} = :sys.get_state(pane.pid).socket.assigns
    assert is_binary(prompt_id)
    assert render(panel) =~ "Supabase 2"

    panel |> element(~s(#{dialog} button[phx-click="confirm"])) |> render_click()

    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the pane to hear its grant"
    )

    {panel, pane}
  end

  # Whether the pane asked to cut the thread's turn for a new consent.
  defp restarts_for_consent do
    Arca.Repo.all(
      from(l in Arca.Schemas.McpLog,
        where: l.tool == "thread" and l.action == "restart_for_consent",
        select: l.id
      )
    )
  end

  test "a launch's account is asked on the app's own profile, opened on that account, and the " <>
         "pane then offers the ended turn's message again as a new turn",
       %{conn: conn, user: user, thread: thread, here: here} do
    hello = line_id!(here, thread, "hello")
    {_panel, pane} = grant_launch_account!(conn, thread, user, here, hello)

    # The turn that asked already ended: nothing is cut, and its message
    # is offered again, to be sent as a new turn.
    assigns = :sys.get_state(pane.pid).socket.assigns
    assert assigns.restart_prompt == "hello"
    html = render(pane)
    assert html =~ "send that message again, as a new turn"
    assert has_element?(pane, ~s(button[phx-click="restart_send"]))
    assert restarts_for_consent() == []

    Cyfr.Test.Sandbox.end_views()
  end

  test "the retry offered is the ended turn's own message, never a line queued while it ran",
       %{conn: conn, user: user, thread: thread, here: here} do
    hello = line_id!(here, thread, "hello")

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: user.user_id,
        sent_by: "person",
        content: "and one more thing"
      })

    {_panel, pane} = grant_launch_account!(conn, thread, user, here, hello)

    assert :sys.get_state(pane.pid).socket.assigns.restart_prompt == "hello"
    assert restarts_for_consent() == []

    Cyfr.Test.Sandbox.end_views()
  end

  test "the retry offered is the ended turn's own message, however many rows follow it",
       %{conn: conn, user: user, thread: thread, here: here} do
    hello = line_id!(here, thread, "hello")

    for n <- 1..55 do
      {:ok, _} =
        Threads.append(Sanctum.Context.actor(here), thread.id, %{
          author: "aqua",
          sent_by: "aqua",
          content: "reply #{n}"
        })
    end

    {_panel, pane} = grant_launch_account!(conn, thread, user, here, hello)

    # Nothing is cut: the turn that asked has ended, and no other turn is
    # the grant's to cut.
    assert :sys.get_state(pane.pid).socket.assigns.restart_prompt == "hello"
    assert restarts_for_consent() == []

    Cyfr.Test.Sandbox.end_views()
  end

  # A person's message refused because what Aqua and its crew members may
  # use moved past Aqua's grant: the pane asks for Aqua's grant there, and
  # once it is given offers that message again as a new turn, cutting
  # nothing.
  test "Aqua's grant asked for a refused message offers the message again once given",
       %{conn: conn, user: user, athanor: athanor, thread: thread, here: here} do
    ctx = connected!(athanor, user)
    :ok = Cyfr.Test.AquaTool.switch!(ctx, "native_search")

    {_panel, pane} = grant_aqua!(conn, user, thread, line_id!(here, thread, "hello"))

    assert :sys.get_state(pane.pid).socket.assigns.restart_prompt == "hello"
    assert render(pane) =~ "Granted — send that message again, as a new turn?"
    assert has_element?(pane, ~s(button[phx-click="restart_send"]))
    assert restarts_for_consent() == []

    # Given for the list as it stands: a turn's start holds it covered.
    {:ok, authority} = Opus.authority_for(ctx, :default, Prima.AgentRef.soul_ref())
    {:ok, %{agent: agent}} = Compendium.agent_snapshot(ctx, "aqua")
    assert :ok = Aqua.Loop.Turn.consented(ctx, authority, agent.tools, [])

    Cyfr.Test.Sandbox.end_views()
  end

  # Only the person's own line is sent again as theirs, its sender and its
  # author both theirs: a schedule's line, sent as the person's and written
  # by the server, is offered by no grant the pane asks, Aqua's or a
  # launch's account's.
  test "a schedule's line is offered again by no grant",
       %{conn: conn, user: user, athanor: athanor, thread: thread, here: here} do
    ctx = connected!(athanor, user)
    :ok = Cyfr.Test.AquaTool.switch!(ctx, "native_search")

    {:ok, fired} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: Prima.Author.system(),
        sent_by: "person",
        content: "read the daily totals",
        payload: %{"schedule" => %{"id" => "sch_daily", "name" => "Daily"}}
      })

    {_panel, pane} = grant_aqua!(conn, user, thread, fired.id)
    offers_nothing!(pane)
    Cyfr.Test.Sandbox.end_views()

    {_panel, pane} = grant_launch_account!(conn, thread, user, here, fired.id)
    offers_nothing!(pane)
    Cyfr.Test.Sandbox.end_views()
  end

  # A send again would carry a line's words alone, so a line with files is
  # not offered, with words or without: its thread's line says to send it
  # again.
  test "a refused message with files is not offered again, with words or without",
       %{conn: conn, user: user, athanor: athanor, thread: thread} do
    ctx = connected!(athanor, user)
    actor = Sanctum.Context.actor(ctx)

    for text <- ["Describe my attached note.", ""] do
      :ok = Cyfr.Test.AquaTool.switch!(ctx, "native_search")
      id = Prima.UUID7.generate_id("msg")
      file = %{"filename" => "notes.txt", "bytes" => "hello", "media_type" => "text/plain"}
      {:ok, refs} = Aqua.Attachments.store(ctx, thread.id, id, [file])

      {:ok, row} =
        Threads.append(actor, thread.id, %{
          id: id,
          author: user.user_id,
          sent_by: "person",
          content: text,
          payload: %{"attachments" => refs}
        })

      assert [_file] = Aqua.Attachments.refs_of(row)
      {_panel, pane} = grant_aqua!(conn, user, thread, row.id)
      offers_nothing!(pane)
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # Aqua's grant asked for the refused turn whose message is `message_id`,
  # in the panel's layer, and given there. Answers the panel and the pane
  # once the pane has heard its grant.
  defp grant_aqua!(conn, user, thread, message_id) do
    {panel, pane} = panel_pane(conn, thread)
    dialog = "#system-layer-panel-dialog"

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :consent_required,
      data: %{ref: Prima.AgentRef.soul_ref(), user_id: user.user_id, message_id: message_id}
    })

    render(pane)
    render(panel)
    assert has_element?(panel, ~s(#{dialog} [data-kind="grant"]))
    panel |> element(~s(#{dialog} button[phx-click="confirm"])) |> render_click()

    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the pane to hear its grant"
    )

    {panel, pane}
  end

  # Granted, the pane offers nothing to send again, says the turn ended and
  # cuts nothing.
  defp offers_nothing!(pane) do
    assigns = :sys.get_state(pane.pid).socket.assigns
    assert assigns.restart_prompt == nil
    assert assigns.flash["info"] =~ "The turn that asked has ended"
    refute has_element?(pane, ~s(button[phx-click="restart_send"]))
    assert restarts_for_consent() == []
  end

  test "with no message of the turn that asked to offer, the pane cuts nothing and says so",
       %{conn: conn, user: user, thread: thread, here: here} do
    # A line of another thread is no message of this thread's turn.
    {:ok, elsewhere} = Arca.Test.Days.thread(Sanctum.Context.actor(here))

    {:ok, foreign} =
      Threads.append(Sanctum.Context.actor(here), elsewhere.id, %{
        author: user.user_id,
        sent_by: "person",
        content: "a line of another thread"
      })

    # A line of Aqua's or a crew member's, a reply that opened the turn, is
    # no line of the person's to send again as theirs.
    {:ok, theirs} =
      Threads.append(Sanctum.Context.actor(here), thread.id, %{
        author: "aqua",
        sent_by: "aqua",
        content: "Aqua's own line"
      })

    for message_id <- [nil, foreign.id, theirs.id] do
      {_panel, pane} = grant_launch_account!(conn, thread, user, here, message_id)
      assigns = :sys.get_state(pane.pid).socket.assigns

      assert assigns.restart_prompt == nil
      assert assigns.grant_retry == nil
      assert assigns.flash["info"] =~ "The turn that asked has ended"
      refute has_element?(pane, ~s(button[phx-click="restart_send"]))
      assert restarts_for_consent() == []
    end

    Cyfr.Test.Sandbox.end_views()
  end

  # The pane on the athanor with no thread open: its empty state.
  defp empty_pane(conn, athanor) do
    {:ok, pane, _} =
      live_isolated(conn, PrismWeb.ThreadPaneLive, session: %{"athanor_id" => athanor.id})

    pane
  end

  describe "the pane's empty state over the model's consent" do
    # The athanor is ready, and its soul's model is installed with an owner
    # profile whose head exists: the empty state reads the model through
    # `Aqua.model_status/2`. Aqua runs on a crew member on that model.
    setup %{athanor: athanor, here: here} do
      {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
      :ok = soul_on_claude!(here)

      {:ok, _} =
        Compendium.Registry.publish_bytes(here, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "claude",
          version: "0.1.0",
          type: "catalyst",
          manifest:
            Jason.encode!(%{
              "needs" => %{
                "api_key" => %{
                  "type" => "api_key:anthropic.com",
                  "reason" => "to call the model with your key",
                  "fields" => ["ANTHROPIC_API_KEY"],
                  "required" => true,
                  "hosts" => ["api.anthropic.com"]
                }
              },
              "caps" => %{"egress" => %{"domains" => ["api.anthropic.com"]}}
            })
        })

      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          here,
          %{
            id: "prof_soul_claude",
            source_ref: "catalyst:local.claude",
            kind: :owner,
            label: "default",
            status: :active
          },
          %{
            id: "cons_soul_claude",
            revision: 1,
            scope: :versionless,
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            resolved_policy: "{}",
            activation: %{"catalyst:local.claude" => "sha256:act"},
            vault_refs: []
          }
        )

      :ok
    end

    test "a consent that exists but is damaged is said as such, never as no model",
         %{conn: conn, athanor: athanor, here: here} do
      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(here, "prof_soul_claude", scope: "sideways")

      pane = empty_pane(conn, athanor)

      assert has_element?(
               pane,
               ~s([data-test="model-consent"]),
               "A consent this model runs under is damaged and cannot be used — " <>
                 "revoke the damaged profile and grant it again."
             )

      refute render(pane) =~ "has no model yet"
      refute render(pane) =~ @connect

      Cyfr.Test.Sandbox.end_views()
    end

    @tag :capture_log
    test "a consent the store cannot answer is said as such, never as no model",
         %{conn: conn, athanor: athanor} do
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
      pane = empty_pane(conn, athanor)

      assert has_element?(
               pane,
               ~s([data-test="model-consent"]),
               "A consent this model runs under cannot be read right now — try again."
             )

      refute render(pane) =~ "has no model yet"
      refute render(pane) =~ @connect

      Cyfr.Test.Sandbox.end_views()
    end

    # Aqua with no crew member, or one that does not stand, has no model
    # to connect: the pane says why in the sentence Aqua's card says and
    # its turn is refused with (`Prima.Refusal`), with the way to the
    # Aqua page.
    test "Aqua with no member, or one that does not stand, says why, never no model", %{
      conn: conn,
      athanor: athanor,
      here: here
    } do
      actor = Sanctum.Context.actor(here)
      crew = Compendium.AquaPath.crew_file("claude")

      claude =
        "---\ntitle: Claude\ncatalyst_ref: catalyst:local.claude\nmodel: claude-sonnet-5-5\n"

      seat =
        &Arca.put(actor, Compendium.AquaPath.soul_file(), "---\ntitle: Aqua\n#{&1}---\n\nsoul\n")

      cases = [
        {fn -> seat.("") end, {:aqua_runs_on, :none, nil}},
        {fn -> seat.("member: ghost\n") end, {:aqua_runs_on, :missing, "ghost"}},
        {fn -> seat.("member: Claude Code\n") end, {:aqua_runs_on, :invalid, "Claude Code"}},
        {fn ->
           :ok = seat.("member: claude\n")
           Arca.put(actor, crew, claude <> "disabled: true\n---\n")
         end, {:aqua_runs_on, :disabled, "claude"}},
        {fn -> Arca.put(actor, crew, claude <> "---\n\nYou are Claude.\n") end,
         {:aqua_runs_on, :refused, "claude"}}
      ]

      for {make, reason} <- cases do
        :ok = make.()
        {:ok, _} = Compendium.AgentIndex.sync(here)
        pane = empty_pane(conn, athanor)
        refute render(pane) =~ "has no model yet"

        assert has_element?(pane, ~s([data-test="model-unseated"]), Prima.Refusal.message(reason))

        assert has_element?(
                 pane,
                 ~s(a[data-test="model-connect"][href="#{athanor_path("/aqua?setup=1", athanor)}"])
               )

        Cyfr.Test.Sandbox.end_views()
      end
    end

    # An athanor made before Aqua ran on a crew member: Aqua's file still
    # names a brain of its own, and the list refuses the soul with the
    # sentence the Aqua page and the turn say, never as a list that could
    # not be read.
    test "Aqua's file that still names a brain says the file's own sentence, never unread", %{
      conn: conn,
      athanor: athanor,
      here: here
    } do
      :ok =
        Arca.put(
          Sanctum.Context.actor(here),
          Compendium.AquaPath.soul_file(),
          "---\ntitle: Aqua\ncatalyst_ref: catalyst:local.claude\nmodel: claude-sonnet-5-5\n" <>
            "---\n\nsoul\n"
        )

      {:ok, _} = Compendium.AgentIndex.sync(here)
      pane = empty_pane(conn, athanor)

      assert has_element?(
               pane,
               ~s([data-test="model-unseated"]),
               Prima.AgentRef.seat_has_brain()
             )

      refute has_element?(pane, ~s([data-test="agents-unavailable"]))
      refute render(pane) =~ "has no model yet"
      Cyfr.Test.Sandbox.end_views()
    end

    test "a model whose head binds no key is still one to connect", %{
      conn: conn,
      athanor: athanor
    } do
      pane = empty_pane(conn, athanor)

      assert render(pane) =~ "has no model yet"

      # The way to a model is a link to Aqua's setup.
      assert has_element?(
               pane,
               ~s(a[data-test="model-connect"][href="#{athanor_path("/aqua?setup=1", athanor)}"]),
               @connect
             )

      refute has_element?(pane, ~s([data-test="model-consent"]))

      Cyfr.Test.Sandbox.end_views()
    end
  end

  # On a ready athanor, Aqua on a crew member whose brain is a catalyst
  # that needs nothing of the person, never granted: the person's grant is
  # all it waits on, given on the Aqua page, never a model to connect.
  test "a model that needs only the grant says so, given on the Aqua page",
       %{conn: conn, athanor: athanor, here: here} do
    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
    :ok = soul_on_claude!(here)
    Arca.Test.UnitFixtures.chat_catalyst!(here, "claude")

    pane = empty_pane(conn, athanor)

    assert has_element?(
             pane,
             ~s([data-test="model-grant"]),
             "your Aqua's model needs only your grant."
           )

    assert has_element?(
             pane,
             ~s(a[href="#{athanor_path("/aqua?setup=1", athanor)}"]),
             "Grant it on your Aqua page."
           )

    refute render(pane) =~ "has no model yet"
    refute render(pane) =~ @connect

    Cyfr.Test.Sandbox.end_views()
  end

  describe "the pane's empty state over a model that runs a program" do
    # The athanor is ready; each test seats Aqua on a crew member whose
    # brain is the program row named `claude`.
    setup %{athanor: athanor} do
      {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
      :ok
    end

    # A soul whose brain is a program names its row by name: the pane reads
    # the row of that name, and one that stands as a brain's is never no
    # model; with no grant for Aqua on this athanor, the grant is what
    # Aqua then waits on.
    test "a soul whose brain is a program reads the row of its name standing, then Aqua's grant",
         %{conn: conn, athanor: athanor, here: here} do
      actor = Sanctum.Context.actor(here)

      :ok = soul_on_program!(actor)

      {:ok, _} = Compendium.AgentIndex.sync(here)

      {:ok, _row} =
        Arca.McpServerStorage.insert(actor, %{
          cap: 0,
          name: "claude",
          transport: "program",
          mark: "driven",
          url: nil,
          home: "kept",
          config_json: Jason.encode!(%{"command" => "cyfr-claude-code claude", "env" => %{}})
        })

      pane = empty_pane(conn, athanor)
      refute render(pane) =~ "has no model yet"
      refute render(pane) =~ @connect
      refute has_element?(pane, ~s([data-test="model-program"]))

      assert has_element?(
               pane,
               ~s([data-test="model-consent"]),
               "You have not granted yet what Aqua and its crew members may use."
             )

      Cyfr.Test.Sandbox.end_views()
    end

    # The row of the soul's program's name that the athanor lacks, or that
    # stands disabled or as no brain's, is said as a turn on it is refused,
    # never as no model to connect.
    test "a soul whose program is not installed, disabled or unfit says which, never no model",
         %{conn: conn, athanor: athanor, here: here} do
      actor = Sanctum.Context.actor(here)

      :ok = soul_on_program!(actor)

      {:ok, _} = Compendium.AgentIndex.sync(here)

      said = fn ->
        pane = empty_pane(conn, athanor)
        html = render(pane)
        refute html =~ "has no model yet"
        refute html =~ @connect

        [line] =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(~s([data-test="model-program"]))
          |> Enum.map(&String.trim(LazyHTML.text(&1)))

        Cyfr.Test.Sandbox.end_views()
        line
      end

      row! = fn command, enabled ->
        {:ok, _row} =
          Arca.McpServerStorage.insert(actor, %{
            cap: 0,
            name: "claude",
            transport: "program",
            mark: "driven",
            url: nil,
            home: "kept",
            enabled: enabled,
            config_json: Jason.encode!(%{"command" => command, "env" => %{}})
          })
      end

      missing = said.()
      _off = row!.("cyfr-claude-code claude", false)
      disabled = said.()
      {:ok, _} = Arca.McpServerStorage.delete(actor, "claude")
      _bare = row!.("npx -y claude", true)
      unfit = said.()

      # Named by the crew member Aqua runs on, whose card installs or opens
      # it, as Aqua's turn and card name it.
      assert [missing, disabled, unfit] == [
               "Coder's program is not installed here — install it from its card on the " <>
                 "Aqua page",
               "Coder's program is disabled — enable it on the Programs page",
               "Coder's program is not one a crew member can run on — on the Programs page, make " <>
                 "it a driven program with a kept folder whose command starts with its driver"
             ]

      assert [missing, disabled, unfit] ==
               for(
                 state <- [:program_missing, :program_disabled, :program_unfit],
                 do: Prima.Refusal.message({:crew_unready, "Coder", state})
               )
    end
  end

  # Aqua seated on a crew member whose brain is the catalyst named
  # `claude`: Aqua runs on its member's brain.
  defp soul_on_claude!(here) do
    actor = Sanctum.Context.actor(here)

    :ok =
      Arca.put(
        actor,
        Compendium.AquaPath.crew_file("claude"),
        "---\ntitle: Claude\ncatalyst_ref: catalyst:local.claude\nmodel: claude-sonnet-5-5\n---\n"
      )

    :ok =
      Arca.put(
        actor,
        Compendium.AquaPath.soul_file(),
        "---\ntitle: Aqua\nmember: claude\n---\n\nsoul\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(here)
    :ok
  end

  # Aqua seated on a crew member whose brain is the program row named
  # `claude`: Aqua runs on its member's brain.
  defp soul_on_program!(actor) do
    :ok =
      Arca.put(
        actor,
        Compendium.AquaPath.crew_file("coder"),
        "---\ntitle: Coder\nprogram: claude\nmodel: opus\n---\n"
      )

    Arca.put(
      actor,
      Compendium.AquaPath.soul_file(),
      "---\ntitle: Aqua\nmember: coder\n---\n\nsoul\n"
    )
  end

  # The athanor as a fill leaves it, its soul's model connected
  # (`ready_athanor!/2`): the shipped Aqua tree and the components the
  # soul depends on (the suite's own seed tree ships the Aqua template
  # alone), the soul's consent selecting its model's default
  # profile, and a key bound to that profile. The seed path it moves is
  # restored only once the work the test's views started has stopped.
  defp connected!(athanor, user) do
    {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
    ctx = ready_athanor!(athanor.id, user.user_id)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    ctx
  end

  # The pane read its model's status from the roster, which names no model,
  # so its empty state offered a model to connect over one connected. It
  # reads the agents with their model now.
  test "a connected model reads ready, and the empty state offers no model to connect",
       %{athanor: athanor, user: user, conn: conn} do
    connected!(athanor, user)
    pane = empty_pane(conn, athanor)

    assert render(pane) =~ "anything."
    refute render(pane) =~ "has no model yet"
    refute render(pane) =~ @connect

    Cyfr.Test.Sandbox.end_views()
  end

  # Aqua's grant revoked, its brain's own grant standing: the grant is all
  # Aqua waits on, said as its stale state is, pointing at the Aqua page,
  # never a model to connect and never ready.
  test "Aqua without its grant says so, granted on the Aqua page",
       %{athanor: athanor, user: user, conn: conn} do
    ctx = connected!(athanor, user)
    {:ok, %{revoked: [_ | _]}} = Sanctum.Consent.revoke_source(ctx, Prima.AgentRef.soul_ref())
    pane = empty_pane(conn, athanor)

    assert has_element?(
             pane,
             ~s([data-test="model-consent"]),
             "You have not granted yet what Aqua and its crew members may use."
           )

    assert has_element?(
             pane,
             ~s(a[href="#{athanor_path("/aqua", athanor)}"]),
             "Grant it on your Aqua page."
           )

    refute render(pane) =~ "anything."
    refute render(pane) =~ "has no model yet"
    refute render(pane) =~ @connect

    Cyfr.Test.Sandbox.end_views()
  end

  # Aqua's grant revoked by its person, as the profile's revoke records it:
  # the empty state says it was revoked, in the sentence a turn refused for
  # it says (`Prima.Refusal`), and points at the Aqua page to grant it
  # again, never that it was never granted.
  test "Aqua whose grant its person revoked says so, granted again on the Aqua page",
       %{athanor: athanor, user: user, conn: conn} do
    ctx = connected!(athanor, user)
    {:ok, %{profile_id: id}} = Opus.authority_for(ctx, :default, Prima.AgentRef.soul_ref())

    assert {:ok, %{status: "revoked"}} =
             Sanctum.Providers.Profile.handle(ctx, %{"action" => "revoke", "profile_id" => id})

    pane = empty_pane(conn, athanor)

    assert has_element?(
             pane,
             ~s([data-test="model-consent"]),
             "You revoked your grant of what Aqua and its crew members may use."
           )

    assert has_element?(
             pane,
             ~s(a[href="#{athanor_path("/aqua", athanor)}"]),
             "Grant it again on your Aqua page."
           )

    refute render(pane) =~ "You have not granted yet"
    refute render(pane) =~ @connect

    Cyfr.Test.Sandbox.end_views()
  end

  # The empty state tells why no grant stands now, never an older
  # revocation: a grant its person revoked, given again and then taken by
  # a removal, and two grants standing under two labels, an ambiguity, each
  # read as a grant to give, never as one the person revoked.
  for {scenario, made} <- [
        {"given again and then removed", :revoked_then_removed!},
        {"given again under two labels", :revoked_then_two_standing!}
      ] do
    test "Aqua whose grant its person once revoked, #{scenario}, is never said as revoked",
         %{athanor: athanor, user: user, conn: conn} do
      ctx = connected!(athanor, user)
      :ok = apply(Cyfr.Test.AquaTool, unquote(made), [ctx])
      pane = empty_pane(conn, athanor)

      assert has_element?(
               pane,
               ~s([data-test="model-consent"]),
               "You have not granted yet what Aqua and its crew members may use."
             )

      assert has_element?(
               pane,
               ~s(a[href="#{athanor_path("/aqua", athanor)}"]),
               "Grant it on your Aqua page."
             )

      refute render(pane) =~ "You revoked"
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # Why a revoked grant is absent read from a record the store cannot
  # answer: the empty state says the grant cannot be read, never that it
  # was not granted.
  test "Aqua whose revoked grant's record cannot be read says it cannot be read",
       %{athanor: athanor, user: user, conn: conn} do
    ctx = connected!(athanor, user)
    :ok = Cyfr.Test.AquaTool.revoked_then_unreadable!(ctx)
    pane = empty_pane(conn, athanor)

    assert has_element?(
             pane,
             ~s([data-test="model-consent"]),
             "A consent this model runs under cannot be read right now — try again."
           )

    refute render(pane) =~ "You have not granted yet"
    refute render(pane) =~ "You revoked"
    Cyfr.Test.Sandbox.end_views()
  end

  # Before its socket connects the pane has read no model: its first render
  # says the status is pending, never that a ready athanor has no model, and
  # the connected mount reads it.
  test "the disconnected render of a ready athanor is pending, and offers no model to connect",
       %{athanor: athanor, user: user, conn: conn} do
    connected!(athanor, user)

    html =
      conn
      |> Plug.Conn.put_private(:phoenix_endpoint, @endpoint)
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.LiveView.Router.fetch_live_flash([])
      |> Phoenix.LiveView.Controller.live_render(PrismWeb.ThreadPaneLive,
        session: %{"athanor_id" => athanor.id}
      )
      |> html_response(200)

    refute html =~ "has no model yet"
    refute html =~ @connect
    assert html =~ ~s(data-test="model-pending")

    pane = empty_pane(conn, athanor)
    assert render(pane) =~ "anything."
    refute has_element?(pane, ~s([data-test="model-pending"]))

    Cyfr.Test.Sandbox.end_views()
  end

  @damaged "A consent this model runs under is damaged and cannot be used — " <>
             "revoke the damaged profile and grant it again."
  @unanswered "A consent this model runs under cannot be read right now — try again."

  # What the pane's empty state and the Aqua page's agents panel each say
  # of the athanor's model: `sentence`, with no model to connect and no key
  # to change over a consent that exists.
  defp model_consent_reads!(conn, athanor, sentence) do
    pane = empty_pane(conn, athanor)
    assert has_element?(pane, ~s([data-test="model-consent"]), sentence)
    refute render(pane) =~ "has no model yet"
    refute render(pane) =~ "anything."
    refute render(pane) =~ @connect

    # The soul's card: each crew member's card says its own brain's state.
    {panel, _html} = mount_athanor(conn, "/aqua", athanor)
    assert has_element?(panel, "#aqua-card-aqua span", sentence)
    refute has_element?(panel, "#aqua-card-aqua", "Model connected")
    refute has_element?(panel, "#aqua-card-aqua", "the model has no key yet")

    refute has_element?(panel, ~s(#aqua-card-aqua a[data-test="connect"]))

    refute has_element?(panel, "#aqua-card-aqua button[phx-click=open_consent]", "Change the key")

    Cyfr.Test.Sandbox.end_views()
  end

  describe "a connected model whose assistant cannot load its consent" do
    # The soul's model reads ready on its own setup plan; what stands in
    # the way is the assistant's own load, as a turn makes it. A load
    # refused for damage, or because the store could not answer, is said
    # as such by the pane and by the agents panel alike, never as a model
    # to connect, and a launch is refused for the same reason.
    setup %{athanor: athanor, user: user} do
      ctx = connected!(athanor, user)
      soul = Prima.AgentRef.soul_ref()
      {:ok, %{profile_id: soul_profile}} = Opus.authority_for(ctx, :default, soul)
      {:ok, ctx: ctx, soul: soul, soul_profile: soul_profile}
    end

    test "the assistant's own head damaged reads damaged",
         %{conn: conn, athanor: athanor, ctx: ctx, soul: soul, soul_profile: soul_profile} do
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, soul_profile, scope: "sideways")

      assert {:error, {:head_corrupt, ^soul_profile}} =
               Opus.authority_for(ctx, :default, soul)

      model_consent_reads!(conn, athanor, @damaged)
    end

    test "a damaged second profile row of the model's catalyst reads damaged",
         %{conn: conn, athanor: athanor, ctx: ctx} do
      :ok =
        Sanctum.Test.ConsentFixtures.seed_profile!(ctx, %{
          id: "prof_claude_twin",
          source_ref: "catalyst:local.claude",
          kind: :owner,
          label: "twin",
          status: :active
        })

      {1, _} =
        Arca.Repo.update_all(
          from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^ctx.athanor_id and p.id == "prof_claude_twin"
          ),
          set: [kind: "sideways"]
        )

      # The model's own grant, the one its calls run under, cannot be
      # chosen past the damaged row.
      assert {:error, refused} = Opus.authority_for(ctx, :default, "catalyst:local.claude")
      assert {:error, :corrupt} = Aqua.ConsentStatus.classify_refusal(refused)

      model_consent_reads!(conn, athanor, @damaged)
    end

    @tag :capture_log
    test "an outage of the assistant's own head reads unanswered",
         %{conn: conn, athanor: athanor, ctx: ctx, soul: soul, soul_profile: soul_profile} do
      _handler = Sanctum.Test.ConsentFixtures.head_outage!(ctx, soul_profile)

      assert {:error, {:head_unavailable, ^soul_profile}} =
               Opus.authority_for(ctx, :default, soul)

      model_consent_reads!(conn, athanor, @unanswered)
    end

    test "a blob digest mismatch on the assistant's own head reads damaged",
         %{conn: conn, athanor: athanor, ctx: ctx, soul: soul, soul_profile: soul_profile} do
      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, soul_profile,
          blob_digest: "sha256:" <> String.duplicate("0", 64)
        )

      assert {:error, {:head_corrupt, ^soul_profile}} =
               Opus.authority_for(ctx, :default, soul)

      model_consent_reads!(conn, athanor, @damaged)
    end
  end

  @model_unread "This model cannot be read right now — try again."

  # The pane's empty state over a model that could not be read: it says
  # so, and offers nothing but to try again.
  defp pane_reads_unread!(conn, athanor) do
    pane = empty_pane(conn, athanor)
    assert has_element?(pane, ~s([data-test="model-unavailable"]), @model_unread)
    refute render(pane) =~ "has no model yet"
    refute render(pane) =~ "anything."
    refute render(pane) =~ @connect
  end

  # The Aqua page's agents panel over the same: no model to install, no
  # key to connect or change, on the soul's card.
  defp panel_reads_unread!(conn, athanor) do
    {panel, _html} = mount_athanor(conn, "/aqua", athanor)
    assert has_element?(panel, "#aqua-card-aqua span", @model_unread)
    refute has_element?(panel, "#aqua-card-aqua", "not installed here yet")
    refute has_element?(panel, "#aqua-card-aqua button[phx-click=install_catalyst]")
    refute has_element?(panel, "#aqua-card-aqua button[phx-click=open_consent]")
  end

  # Runs `inject` each time the gate admits a `component.setup_plan`
  # call: after the catalyst listing has read and resolved the model, and
  # before the plan's own read.
  defp on_setup_plan!(inject) do
    handler = "pane-setup-plan-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :sanctum, :decision, :admitted],
        fn _event, _measurements, meta, _config ->
          if meta[:tool] == "component" and meta[:action] == "setup_plan", do: inject.()
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "a model whose catalysts or setup cannot be read" do
    # The athanor is connected (`ready_athanor!/2`). A store that cannot give
    # the athanor's catalysts, or the model's setup plan, leaves whether
    # the model is installed unknown: it is said as such, never as a model
    # to install or to connect. The outage is the component index left
    # behind by an edit (`Arca.StorageProjectionChanges.begin_edit/3`), as
    # `Aqua.ModelsTest` leaves it.
    setup %{athanor: athanor, user: user} do
      ctx = connected!(athanor, user)
      {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
    end

    @tag :capture_log
    test "a catalyst listing that cannot be read reads unread, never a model to install",
         %{conn: conn, athanor: athanor, ctx: ctx, actor: actor} do
      {:ok, _pending} =
        Arca.StorageProjectionChanges.begin_edit(
          actor,
          "components",
          "catalysts/local/claude/0.0.0"
        )

      assert {:error, :catalyst_lookup_failed} = Aqua.AgentConfig.catalyst_listing(ctx)

      pane_reads_unread!(conn, athanor)
      panel_reads_unread!(conn, athanor)
      Cyfr.Test.Sandbox.end_views()
    end

    @tag :capture_log
    test "a setup plan the store cannot answer reads unread, never a model to install",
         %{conn: conn, athanor: athanor, actor: actor} do
      test = self()
      unit = "catalysts/local/claude/0.0.0"

      on_setup_plan!(fn ->
        {:ok, generation} = Arca.StorageProjectionChanges.begin_edit(actor, "components", unit)
        send(test, {:index_behind, generation})
      end)

      pane_reads_unread!(conn, athanor)
      assert_received {:index_behind, generation}

      # The panel's own listing reads; its setup plan meets the outage again.
      {:ok, _} = Arca.StorageProjectionChanges.finish_edit(actor, "components", unit, generation)
      panel_reads_unread!(conn, athanor)
      assert_received {:index_behind, _again}
      Cyfr.Test.Sandbox.end_views()
    end

    test "a setup plan that finds no such component still reads missing, with Install",
         %{conn: conn, athanor: athanor, ctx: ctx} do
      test = self()
      athanor_id = ctx.athanor_id

      named = fn name, to ->
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component,
            where:
              c.athanor_id == ^athanor_id and c.component_type == "catalyst" and c.name == ^name
          ),
          set: [name: to]
        )
      end

      on_setup_plan!(fn -> send(test, {:gone, named.("claude", "claude-gone")}) end)

      pane = empty_pane(conn, athanor)
      assert_received {:gone, {n, _}} when n > 0
      assert render(pane) =~ "has no model yet"
      assert render(pane) =~ @connect
      refute has_element?(pane, ~s([data-test="model-unavailable"]))

      # The panel's own listing names the model; its setup plan finds none.
      {^n, _} = named.("claude-gone", "claude")
      {panel, _html} = mount_athanor(conn, "/aqua", athanor)
      assert_received {:gone, {^n, _}}
      assert has_element?(panel, "#aqua-card-aqua", "not installed here yet")
      assert has_element?(panel, "#aqua-card-aqua button[phx-click=install_catalyst]", "Install")
      refute has_element?(panel, "#aqua-card-aqua", @model_unread)
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # The storage adapter for the rest of the test.
  defp storage!(adapter) do
    original = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, adapter)

    on_exit(fn ->
      if original,
        do: Application.put_env(:arca, :storage_adapter, original),
        else: Application.delete_env(:arca, :storage_adapter)
    end)
  end

  describe "an agents list that cannot be read" do
    # A store that cannot give the athanor's agents leaves whether it has a
    # model unknown: the pane says so and offers nothing but to try again.
    # A store that answers with no agents is an athanor with no model, which
    # is one to connect.
    setup %{athanor: athanor} do
      {:ok, _} = Sanctum.TestContext.mark_provisioned(athanor)
      :ok
    end

    @tag :capture_log
    test "reads unread, never no model, with no link", %{conn: conn, athanor: athanor} do
      storage!(PrismWeb.ThreadPaneLiveTest.UnreadableCrew)
      pane = empty_pane(conn, athanor)

      assert has_element?(
               pane,
               ~s([data-test="agents-unavailable"]),
               "Aqua and its crew members cannot be read right now — try again."
             )

      refute render(pane) =~ "has no model yet"
      refute render(pane) =~ @connect
      refute has_element?(pane, ~s([id$="-thread"] > div.justify-center a))
      Cyfr.Test.Sandbox.end_views()
    end

    test "a store that answers with no agents still offers a model to connect",
         %{conn: conn, athanor: athanor, here: here} do
      # Every agent the fill shipped goes, unit by unit, as a reset of the
      # whole root would take them.
      assert :ok =
               Arca.Overlay.with_internal_writes(fn ->
                 Arca.delete_tree(Sanctum.Context.actor(here), ["aqua"])
               end)

      # The athanor's list reads, and holds the guides alone: no soul, no crew.
      assert {:ok, %{guides: guides}} =
               Aqua.Ops.call_tool("aqua", here, %{"action" => "list", "detail" => true})

      assert Enum.all?(guides, &(&1.type == "doc"))

      pane = empty_pane(conn, athanor)

      assert render(pane) =~ "has no model yet"
      assert render(pane) =~ @connect
      refute has_element?(pane, ~s([data-test="agents-unavailable"]))
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # Rows as the crew writes them, through the tape, which tells the
  # thread's viewers: a person's request to `member` and the member's
  # reply (answering `answers`, its own request first).
  defp request!(here, room, member, task) do
    {:ok, %{message: row}} =
      Aqua.Tape.accept(here, room.id, %{
        message: %{
          author: here.user_id,
          sent_by: "person",
          addressee: member,
          status: "pending",
          content: task
        }
      })

    row
  end

  defp reply!(here, room, request, child, text, answers \\ [], outcome \\ "done") do
    answers = [request.id | answers]

    {:ok, %{message: row}} =
      Aqua.Tape.accept(here, room.id, %{
        message: %{
          author: "aqua",
          sent_by: request.addressee,
          addressee: "person",
          reply_to: request.id,
          outcome: outcome,
          content: text,
          payload: %{"from_thread" => child.id, "answers" => answers}
        },
        answers: answers
      })

    row
  end

  # A crew member standing in the athanor's roster, as the person makes one.
  defp member!(here, name) do
    :ok =
      Arca.put(
        Sanctum.Context.actor(here),
        Compendium.AquaPath.crew_file(name),
        "---\ntitle: #{name}\ndescription: Builds.\n" <>
          "catalyst_ref: catalyst:local.claude\nmodel: claude-sonnet-5-5\n---\n"
      )

    {:ok, _} = Compendium.AgentIndex.sync(here)
  end

  describe "the archive" do
    test "a daily thread's menu archives it through thread.archive and then reads Archived; " <>
           "new work there, announced on the person's list, brings the Archive row back",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      actor = Sanctum.Context.actor(here)
      pane = open_pane(conn, athanor, thread)
      archive = ~s([id$="-menu"] button[phx-click="archive"])
      assert has_element?(pane, archive, "Archive")

      pane |> element(archive) |> render_click()

      assert [_] =
               Arca.Repo.all(
                 from(l in Arca.Schemas.McpLog,
                   where: l.tool == "thread" and l.action == "archive",
                   select: l.input
                 )
               )

      assert {:ok, %{archived_at: %DateTime{}}} = Threads.get(actor, thread.id)
      assert has_element?(pane, ~s([id$="-menu"]), "Archived")
      refute has_element?(pane, archive)

      # The person's post takes it out of the archive, and their list says so.
      {:ok, _} =
        Arca.TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: here.user_id, sent_by: "person", content: "and one more thing"},
          turn: %{agent: "aqua", requested_by: here.user_id, origin: :interactive}
        })

      assert {:ok, %{archived_at: nil}} = Threads.get(actor, thread.id)
      :ok = Aqua.ThreadList.changed(here, thread.id)
      assert has_element?(pane, archive, "Archive")
      refute has_element?(pane, ~s([id$="-menu"]), "Archived")

      # While that turn is open the thread works, and the archive is refused.
      pane |> element(archive) |> render_click()
      assert :sys.get_state(pane.pid).socket.assigns.flash["error"] =~ "still working"
      assert {:ok, %{archived_at: nil}} = Threads.get(actor, thread.id)
      assert has_element?(pane, archive, "Archive")

      Cyfr.Test.Sandbox.end_views()
    end

    test "a crew member's thread has no Archive row in the menu: its strip retires it",
         %{conn: conn, here: here, thread: room} do
      member!(here, "explorer")
      {:ok, explorer} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")
      {_panel, pane} = panel_pane(conn, room)
      assert has_element?(pane, ~s([id$="-menu"] button[phx-click="archive"]))

      pane |> element(~s([id$="-crew-#{explorer.id}"])) |> render_click()
      on_thread!(pane, explorer.id)
      refute has_element?(pane, ~s([id$="-menu"] button[phx-click="archive"]))
      assert has_element?(pane, ~s([id$="-crew-thread"] button[phx-click="archive"]))

      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "the delete" do
    @delete ~s([id$="-menu"] button[phx-click="delete"])

    test "deleting a member's queued job answers the request in its surviving room",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      actor = Sanctum.Context.actor(here)
      {:ok, child} = Threads.crew_thread(actor, room.id, "explorer")
      pane = open_pane(conn, athanor, child)

      {:ok, %{message: request}} =
        Arca.TurnStorage.accept_message(actor, room.id, %{
          message: %{
            author: "aqua",
            sent_by: "aqua",
            addressee: "explorer",
            status: "pending",
            content: "read the plan"
          },
          request: %{
            member: "explorer",
            task: "read the plan",
            tools: nil,
            options: %{},
            person_id: here.user_id,
            origin: :interactive
          }
        })

      {:ok, %{turn: turn}} =
        Arca.TurnStorage.accept_message(actor, child.id, %{
          message: %{
            author: "aqua",
            sent_by: "aqua",
            addressee: "explorer",
            content: request.content,
            payload: %{"request_id" => request.id}
          },
          turn: %{agent: "explorer", requested_by: here.user_id, origin: :interactive},
          reply_address: %{asking_thread_id: room.id, request_id: request.id}
        })

      assert turn.status == "accepted"
      refute :sys.get_state(pane.pid).socket.assigns.running
      assert {:ok, %{status: "accepted"}} = Aqua.Tape.turn(here, turn.id)
      assert {:ok, []} = Arca.Outbox.pending(actor, "crew_delivery", "crew_reply")
      before = Threads.get(actor, room.id)

      pane |> element(@delete) |> render_click()

      assert {:error, :not_found} = Threads.get(actor, child.id)
      assert Threads.get(actor, room.id) == before
      assert {:ok, [reply]} = Arca.Outbox.pending(actor, "crew_delivery", "crew_reply")
      assert reply.snapshot["request_ids"] == [request.id]
      assert reply.snapshot["outcome"] == "cancelled"
      Cyfr.Test.Sandbox.end_views()
    end

    test "a pane that cannot read a foreign thread offers no Delete and ignores a forged event",
         %{conn: conn, athanor: athanor, here: here} do
      other_user = test_user()
      other_athanor = Sanctum.Test.People.athanor!(other_user.user_id)

      other_actor = %{
        Sanctum.Context.actor(here)
        | athanor_id: other_athanor.id,
          user_id: other_user.user_id
      }

      {:ok, foreign} = Arca.Test.Days.thread(other_actor)
      before = Threads.list(other_actor)
      pane = open_pane(conn, athanor, foreign)
      refute has_element?(pane, @delete)
      render_click(pane, "delete", %{"thread" => foreign.id})
      assert Threads.list(other_actor) == before
      Cyfr.Test.Sandbox.end_views()
    end

    test "deleting a crew thread from a workspace pane returns that pane to its room",
         %{conn: conn, athanor: athanor, here: here, thread: daily} do
      actor = Sanctum.Context.actor(here)

      {:ok, %{workspace: room}} =
        Arca.TurnStorage.open_workspace(actor, %{
          daily_id: daily.id,
          id: Prima.UUID7.generate_id("thread"),
          title: "Review",
          opening: %{
            id: Prima.UUID7.generate_id("msg"),
            author: here.user_id,
            content: "review",
            payload: %{"ask" => "review"}
          },
          pointer: %{author: "aqua", sent_by: "aqua", content: "Review"},
          files: fn _thread, _message -> {:ok, []} end,
          person_id: here.user_id,
          origin: :interactive
        })

      member!(here, "explorer")
      {:ok, child} = Threads.crew_thread(actor, room.id, "explorer")
      {:ok, view, _} = live(conn, PrismWeb.WorkspaceLive.address(route(athanor), room.id))
      pane = on_thread!(child!(view, "workspace-pane"), room.id)
      pane |> element("#workspace-pane-crew-#{child.id}") |> render_click()
      on_thread!(pane, child.id)
      pane |> element(@delete) |> render_click()
      assert {:error, :not_found} = Threads.get(actor, child.id)
      on_thread!(pane, room.id)
      Cyfr.Test.Sandbox.end_views()
    end

    test "a daily thread's menu asks first, saying what goes and what stays, and a yes " <>
           "removes it and its crew threads through thread.delete; the list shows neither",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      actor = Sanctum.Context.actor(here)
      {:ok, explorer} = Threads.crew_thread(actor, room.id, "explorer")
      {:ok, reviewer} = Threads.crew_thread(actor, room.id, "reviewer")
      {:ok, kept} = Arca.Test.Days.thread(actor)
      pane = open_pane(conn, athanor, room)
      # As the pane left them, its read mark moved on open.
      listed = Threads.list(actor)

      question =
        "Delete this thread? Its posts, files and turns go, with explorer's and reviewer's " <>
          "threads under it, and any record a program keeps of them. The records of what ran " <>
          "stay on the Executions page and in the logs, as do a program's sign-in and every " <>
          "other thread. This cannot be undone."

      assert has_element?(pane, ~s(#{@delete}[data-confirm="#{question}"]), "Delete")
      # Asked and not said yes to, nothing was sent: every thread stands.
      assert Threads.list(actor) == listed

      pane |> element(@delete) |> render_click()

      assert [_] =
               Arca.Repo.all(
                 from(l in Arca.Schemas.McpLog,
                   where: l.tool == "thread" and l.action == "delete",
                   select: l.input
                 )
               )

      gone = [room.id, explorer.id, reviewer.id]
      for id <- gone, do: assert({:error, :not_found} = Threads.get(actor, id))
      assert Threads.list(actor) == Enum.reject(listed, &(&1.id in gone))
      assert Enum.any?(Threads.list(actor), &(&1.id == kept.id))
      assert :sys.get_state(pane.pid).socket.assigns.flash == %{}

      Cyfr.Test.Sandbox.end_views()
    end

    test "a crew member's thread asks without threads under it, and a thread with work " <>
           "running says that work stops",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      {:ok, explorer} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")
      pane = open_pane(conn, athanor, explorer)

      alone =
        "Delete this thread? Its posts, files and turns go, and any record a program keeps " <>
          "of it. The records of what ran stay on the Executions page and in the logs, as do " <>
          "a program's sign-in and every other thread. This cannot be undone."

      assert has_element?(pane, ~s(#{@delete}[data-confirm="#{alone}"]))

      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: explorer.athanor_id,
        thread_id: explorer.id,
        kind: :turn_starting,
        data: here.user_id
      })

      running =
        "Delete this thread? The work running in it stops. Its posts, files and turns go, " <>
          "and any record a program keeps of it. The records of what ran stay on the " <>
          "Executions page and in the logs, as do a program's sign-in and every other thread. " <>
          "This cannot be undone."

      assert has_element?(pane, ~s(#{@delete}[data-confirm="#{running}"]))

      Cyfr.Test.Sandbox.end_views()
    end

    test "a program member's thread owes the removal of its session from the program's " <>
           "folder; the member's other thread and the program's row are untouched",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      actor = Sanctum.Context.actor(here)
      row = program_row!(actor)
      {:ok, other_room} = Arca.Test.Days.thread(actor)
      {:ok, mine} = Threads.crew_thread(actor, room.id, "claude-code")
      {:ok, other} = Threads.crew_thread(actor, other_room.id, "claude-code")
      held!(mine, row, "session-mine")
      held!(other, row, "session-other")
      {:ok, other_before} = Threads.get(actor, other.id)
      {:ok, row_before} = Arca.McpServerStorage.get(actor, row.name)
      {:ok, mine_before} = Threads.get(actor, mine.id)
      pane = open_pane(conn, athanor, mine)

      pane |> element(@delete) |> render_click()

      assert {:error, :not_found} = Threads.get(actor, mine.id)

      assert {:ok, [owed]} = Arca.Outbox.pending(actor, "brain_cleanup", "brain_forget")

      assert owed ==
               Prima.OutboxRecord.brain_forget(%{
                 athanor_id: actor.athanor_id,
                 thread_id: mine.id,
                 row_id: row.id,
                 session: "session-mine",
                 generation: mine_before.brain_generation
               })

      assert {:ok, ^other_before} = Threads.get(actor, other.id)
      assert {:ok, ^row_before} = Arca.McpServerStorage.get(actor, row.name)

      Cyfr.Test.Sandbox.end_views()
    end

    test "a screen still on a thread deleted elsewhere shows the tool's refusal and removes nothing",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      actor = Sanctum.Context.actor(here)
      pane = open_pane(conn, athanor, room)
      {:ok, _} = Aqua.Tape.delete_thread(here, room.id)
      listed = Threads.list(actor)

      pane |> element(@delete) |> render_click()

      assert :sys.get_state(pane.pid).socket.assigns.flash["error"] ==
               "Could not delete it: " <>
                 PrismWeb.Ops.error_message({:not_found, "thread", room.id})

      assert Threads.list(actor) == listed

      Cyfr.Test.Sandbox.end_views()
    end
  end

  # A program row a brain runs on, driven in a kept folder.
  defp program_row!(actor) do
    {:ok, row} =
      Arca.McpServerStorage.insert(actor, %{
        cap: 0,
        name: "claude-code",
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json:
          Jason.encode!(%{
            "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
            "env" => %{}
          })
      })

    row
  end

  # `session` held on `thread` as a driver's batch stores it, with its row.
  defp held!(thread, row, session) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
        set: [brain_session: session, brain_progress: Jason.encode!(%{"row" => row.id})]
      )
  end

  describe "the crew" do
    test "a room shows a request with the reply under it, by the member's name and its outcome",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")
      request = request!(here, room, "explorer", "Build the site")
      reply = reply!(here, room, request, child, "Built it")

      pane = open_pane(conn, athanor, room)
      asked = ~s([id$="-m-#{request.id}"])

      assert has_element?(pane, asked, "You asked explorer · done")
      assert has_element?(pane, asked, "Build the site")
      assert has_element?(pane, ~s(#{asked} [id$="-reply-#{reply.id}"]), "explorer · done")
      refute has_element?(pane, ~s([id$="-m-#{reply.id}"]))

      Cyfr.Test.Sandbox.end_views()
    end

    test "a request and the reply under it each draw what they hold, at their own message's address",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")

      held = fn name ->
        %{
          "attachments" => [
            %{
              "filename" => "#{name}.png",
              "stored_name" => "0-#{name}.png",
              "media_type" => "image/png"
            },
            %{
              "filename" => "#{name}.pdf",
              "stored_name" => "1-#{name}.pdf",
              "media_type" => "application/pdf"
            }
          ],
          "links" => [%{"url" => "https://example.com/#{name}", "title" => "The #{name}"}]
        }
      end

      {:ok, %{message: request}} =
        Aqua.Tape.accept(here, room.id, %{
          message: %{
            author: here.user_id,
            sent_by: "person",
            addressee: "explorer",
            status: "pending",
            content: "Build the site",
            payload: held.("brief")
          }
        })

      {:ok, %{message: reply}} =
        Aqua.Tape.accept(here, room.id, %{
          message: %{
            author: "aqua",
            sent_by: "explorer",
            addressee: "person",
            reply_to: request.id,
            outcome: "done",
            content: "Built it",
            payload:
              Map.merge(held.("result"), %{"from_thread" => child.id, "answers" => [request.id]})
          },
          answers: [request.id]
        })

      Enum.each([request, reply], &kept!(Sanctum.Context.actor(here), &1))

      pane = open_pane(conn, athanor, room)
      href = &PrismWeb.Focus.path(route(athanor), "/attachments/#{&1}/#{&2}")
      asked = ~s([id$="-m-#{request.id}"])
      answered = ~s(#{asked} [id$="-reply-#{reply.id}"])

      for {scope, row, name} <- [{asked, request, "brief"}, {answered, reply, "result"}] do
        assert has_element?(
                 pane,
                 ~s(#{scope} button img[src="#{href.(row.id, "0-#{name}.png")}"])
               )

        assert has_element?(
                 pane,
                 ~s(#{scope} [id$="-msg-#{row.id}-picture-0"].hidden img[src="#{href.(row.id, "0-#{name}.png")}"])
               )

        assert has_element?(
                 pane,
                 ~s(#{scope} a[href="#{href.(row.id, "1-#{name}.pdf")}"][download="#{name}.pdf"])
               )

        assert has_element?(
                 pane,
                 ~s(#{scope} a[href="https://example.com/#{name}"]),
                 "The #{name}"
               )
      end

      Cyfr.Test.Sandbox.end_views()
    end

    test "a reply heard on the room marks every request it answers answered, under the one it replies to",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")
      first = request!(here, room, "explorer", "Build the site")
      second = request!(here, room, "explorer", "And test it")

      pane = open_pane(conn, athanor, room)
      assert has_element?(pane, ~s([id$="-m-#{first.id}"]), "You asked explorer · pending")
      assert has_element?(pane, ~s([id$="-m-#{second.id}"]), "You asked explorer · pending")

      reply = reply!(here, room, first, child, "Built and tested", [second.id])
      render(pane)

      assert has_element?(pane, ~s([id$="-m-#{first.id}"]), "You asked explorer · done")
      assert has_element?(pane, ~s([id$="-m-#{second.id}"]), "You asked explorer · done")

      assert has_element?(
               pane,
               ~s([id$="-m-#{first.id}"] [id$="-reply-#{reply.id}"]),
               "explorer · done"
             )

      refute has_element?(pane, ~s([id$="-m-#{second.id}"] [id$="-reply-#{reply.id}"]))
      refute has_element?(pane, ~s([id$="-m-#{reply.id}"]))

      Cyfr.Test.Sandbox.end_views()
    end

    test "a room lists its crew threads, and a crew thread leads back to its room and retires through thread.archive",
         %{conn: conn, here: here, thread: room} do
      actor = Sanctum.Context.actor(here)
      for name <- ["explorer", "reviewer"], do: member!(here, name)
      {:ok, explorer} = Threads.crew_thread(actor, room.id, "explorer")
      {:ok, reviewer} = Threads.crew_thread(actor, room.id, "reviewer")
      {:ok, _} = Threads.retire(actor, reviewer.id)
      {_panel, pane} = panel_pane(conn, room)

      assert has_element?(pane, ~s([id$="-crew-#{explorer.id}"]), "explorer")
      refute has_element?(pane, ~s([id$="-crew-#{explorer.id}"]), "archived")
      assert has_element?(pane, ~s([id$="-crew-#{reviewer.id}"]), "reviewer · archived")
      refute has_element?(pane, ~s([id$="-crew-thread"]))

      pane |> element(~s([id$="-crew-#{explorer.id}"])) |> render_click()
      on_thread!(pane, explorer.id)

      strip = ~s([id$="-crew-thread"])
      assert has_element?(pane, strip, "explorer's thread")

      # The room, a daily thread, by its day's date in words, never the
      # ISO date its row's title holds.
      assert has_element?(
               pane,
               ~s(#{strip} button[phx-click="open_thread"]),
               "Back to #{PrismWeb.DisplayHelpers.day_name(room.day)}"
             )

      refute pane |> element(strip) |> render() =~ room.title

      refute has_element?(pane, ~s([id$="-crew-#{explorer.id}"]))

      pane |> element(~s(#{strip} button[phx-click="archive"])) |> render_click()

      assert [_] =
               Arca.Repo.all(
                 from(l in Arca.Schemas.McpLog,
                   where: l.tool == "thread" and l.action == "archive",
                   select: l.input
                 )
               )

      assert {:ok, %{retired_at: %DateTime{}}} = Threads.get(actor, explorer.id)
      assert has_element?(pane, strip, "Archived")
      refute has_element?(pane, ~s(button[phx-click="archive"]))

      pane |> element(~s(#{strip} button[phx-click="open_thread"])) |> render_click()
      on_thread!(pane, room.id)
      assert has_element?(pane, ~s([id$="-crew-#{explorer.id}"]), "explorer · archived")

      Cyfr.Test.Sandbox.end_views()
    end

    test "a request reads the outcome of the reply that resolved it, its own or another " <>
           "request's, as the reply lands and as the thread opens again",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")

      for {outcome, words} <- [
            {"failed", "failed"},
            {"cancelled", "cancelled"},
            {"uncertain", "outcome unknown"}
          ] do
        first = request!(here, room, "explorer", "Build the #{outcome} site")
        second = request!(here, room, "explorer", "And test the #{outcome} site")
        live = open_pane(conn, athanor, room)
        assert has_element?(live, ~s([id$="-m-#{first.id}"]), "You asked explorer · pending")

        reply = reply!(here, room, first, child, "It ended #{outcome}", [second.id], outcome)
        render(live)
        opened = open_pane(conn, athanor, room)

        for pane <- [live, opened] do
          for request <- [first, second] do
            assert has_element?(
                     pane,
                     ~s([id$="-m-#{request.id}"]),
                     "You asked explorer · #{words}"
                   )
          end

          assert has_element?(
                   pane,
                   ~s([id$="-m-#{first.id}"] [id$="-reply-#{reply.id}"]),
                   "explorer · #{words}"
                 )
        end
      end

      Cyfr.Test.Sandbox.end_views()
    end

    test "a request reads the outcome its stored resolver holds, whichever reply was announced",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")
      first = request!(here, room, "explorer", "Build the site")
      second = request!(here, room, "explorer", "And test it")
      live = open_pane(conn, athanor, room)
      assert has_element?(live, ~s([id$="-m-#{second.id}"]), "You asked explorer · pending")

      # A failed reply resolves the second request, its announcement lost:
      # written by the store alone, which broadcasts nothing.
      {:ok, _failed} =
        Arca.TurnStorage.accept_message(Sanctum.Context.actor(here), room.id, %{
          message: %{
            author: "aqua",
            sent_by: "explorer",
            addressee: "person",
            reply_to: second.id,
            outcome: "failed",
            content: "It broke",
            payload: %{"from_thread" => child.id, "answers" => [second.id]}
          },
          answers: [second.id]
        })

      # A later successful reply names it too, and is announced.
      _done = reply!(here, room, first, child, "Built it", [second.id])
      render(live)

      assert has_element?(live, ~s([id$="-m-#{first.id}"]), "You asked explorer · done")
      assert has_element?(live, ~s([id$="-m-#{second.id}"]), "You asked explorer · failed")

      Cyfr.Test.Sandbox.end_views()
    end

    test "a request's card opens its member's thread", %{conn: conn, here: here, thread: room} do
      {:ok, child} = Threads.crew_thread(Sanctum.Context.actor(here), room.id, "explorer")
      request = request!(here, room, "explorer", "Build the site")
      {_panel, pane} = panel_pane(conn, room)

      open =
        ~s([id$="-m-#{request.id}"] button[phx-click="open_thread"][phx-value-id="#{child.id}"])

      assert has_element?(pane, open, "Open explorer's thread")
      pane |> element(open) |> render_click()
      on_thread!(pane, child.id)

      Cyfr.Test.Sandbox.end_views()
    end

    test "a room lists the threads of its standing crew members alone; a member taken out " <>
           "of the crew keeps its thread",
         %{conn: conn, athanor: athanor, here: here, thread: room} do
      actor = Sanctum.Context.actor(here)
      for name <- ["explorer", "reviewer"], do: member!(here, name)
      {:ok, explorer} = Threads.crew_thread(actor, room.id, "explorer")
      {:ok, reviewer} = Threads.crew_thread(actor, room.id, "reviewer")
      :ok = Arca.delete(actor, Compendium.AquaPath.crew_file("reviewer"))
      {:ok, _} = Compendium.AgentIndex.sync(here)

      pane = open_pane(conn, athanor, room)
      assert has_element?(pane, ~s([id$="-crew-#{explorer.id}"]), "explorer")
      refute has_element?(pane, ~s([id$="-crew-#{reviewer.id}"]))
      assert {:ok, %{id: id}} = Threads.get(actor, reviewer.id)
      assert id == reviewer.id

      Cyfr.Test.Sandbox.end_views()
    end

    test "the pane in Aqua's panel leaves its menu to the panel's hook: no press away or " <>
           "Escape of its own closes it",
         %{conn: conn, thread: room} do
      {_panel, pane} = panel_pane(conn, room)
      assert has_element?(pane, "#aqua-panel-pane-menu[hidden]")
      refute has_element?(pane, "#aqua-panel-pane-menu[phx-click-away]")
      refute has_element?(pane, "#aqua-panel-pane-menu[phx-window-keydown]")

      Cyfr.Test.Sandbox.end_views()
    end
  end

  # A scroll a turn proposed waits for the person: the pane draws its
  # result row as a card under its turn, showing the name, description and
  # body a save writes, and Save as scroll writes exactly those from the
  # person's own session, or says why it did not.
  describe "a scroll a turn proposed" do
    # A proposal's result row as the loop writes it (`Aqua.Loop`): a model's
    # `tool_result`, `proposed`. (`kind` writes a page's `page_result` row
    # holding one, which no page's call makes: a page proposes nothing.)
    defp proposed!(here, thread, proposal, kind \\ "tool_result") do
      {:ok, row} =
        Threads.append(Sanctum.Context.actor(here), thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: kind,
          status: "proposed",
          content: Jason.encode!(proposal),
          payload: %{
            "tool_call_id" => "c1",
            "name" => "aqua",
            "is_error" => false,
            "proposal" => proposal
          }
        })

      row
    end

    defp card(row, part), do: ~s([id$="-proposal-#{row.id}-#{part}"])

    test "a pending update to the unchanged shipped planner can still be saved", %{
      conn: conn,
      athanor: athanor,
      here: here,
      thread: thread
    } do
      assert :ok = Compendium.Packs.settle(here)
      {:ok, %{bytes: original}} = Compendium.Packs.manifest(here, "cyfr:planner")

      row =
        proposed!(here, thread, %{
          "name" => "planner",
          "description" => "custom",
          "content" => "my edit",
          "against" => Prima.Digest.sha256(original)
        })

      pane = open_pane(conn, athanor, thread)
      assert pane |> element(card(row, "name")) |> render() =~ "mine:planner"
      pane |> element(card(row, "save")) |> render_click()
      assert has_element?(pane, card(row, "saved"))
    end

    test "a proposal to make a new pack says so, and its Save is refused when the pack is there",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      actor = Sanctum.Context.actor(here)

      {:ok, _} =
        Arca.Files.write(
          actor,
          "aqua/scrolls/garden/skills/roses/SKILL.md",
          "---\nname: roses\n---\nred"
        )

      row =
        proposed!(here, thread, %{
          "name" => "garden:tulips",
          "description" => "How tulips are kept",
          "content" => "Plant them in autumn.",
          "against" => "none",
          "new_pack" => true
        })

      pane = open_pane(conn, athanor, thread)

      assert render(pane) =~
               "Aqua proposes a new pack with this scroll as its first. Nothing is kept until you save it."

      pane |> element(card(row, "save")) |> render_click()
      assert has_element?(pane, card(row, "refused"))
      refute has_element?(pane, card(row, "saved"))

      assert {:error, :not_found} =
               Arca.get(actor, ~w(aqua scrolls garden skills tulips SKILL.md))
    end

    # A card proposed before scrolls had packs names its scroll bare; it is
    # the first pack's, `mine`, where the release moved every made scroll.
    test "its card shows what Save as scroll writes, and a save writes exactly that",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      proposal = %{
        "name" => "fern-care",
        "description" => "How the fern is kept",
        "content" => "Water it weekly.\nTurn it monthly.",
        "against" => "none"
      }

      row = proposed!(here, thread, proposal)
      pane = open_pane(conn, athanor, thread)

      assert pane |> element(card(row, "name")) |> render() =~ "mine:fern-care"
      assert pane |> element(card(row, "description")) |> render() =~ "How the fern is kept"

      assert pane |> element(card(row, "content")) |> render() =~
               "Water it weekly.\nTurn it monthly."

      assert {:error, {:not_found, "Scroll", "mine:fern-care"}} =
               Compendium.Providers.Aqua.handle(here, %{
                 "action" => "skill_get",
                 "name" => "mine:fern-care"
               })

      pane |> element(card(row, "save")) |> render_click()

      assert pane |> element(card(row, "saved")) |> render() =~ "Saved as a scroll."
      refute has_element?(pane, card(row, "save"))

      assert {:ok,
              %{
                description: "How the fern is kept",
                content: "Water it weekly.\nTurn it monthly."
              }} =
               Compendium.Providers.Aqua.handle(here, %{
                 "action" => "skill_get",
                 "name" => "mine:fern-care"
               })

      # A change proposed over a scroll that changed since is refused, in
      # the sentence the card shows, and nothing is written.
      stale =
        proposed!(here, thread, %{
          "name" => "mine:fern-care",
          "description" => "How the fern stays green",
          "content" => "Water it weekly.\nTurn it monthly.",
          "against" => Prima.Digest.sha256("an older manifest")
        })

      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        thread_id: thread.id,
        athanor_id: athanor.id,
        kind: :message,
        data: stale
      })

      pane |> element(card(stale, "save")) |> render_click()

      assert pane |> element(card(stale, "refused")) |> render() =~
               "changed since Aqua proposed this"

      assert {:ok, %{description: "How the fern is kept"}} =
               Compendium.Providers.Aqua.handle(here, %{
                 "action" => "skill_get",
                 "name" => "mine:fern-care"
               })
    end

    # The pane reads the thread's proposals as such: one behind more than
    # the pane's window of newer results has its card while its row can be
    # seen. A page proposes nothing (`Arca.TurnStorage.own_turn/3`), so a
    # page's result row is drawn as no card, whatever it holds.
    test "a proposal has its card behind many newer results, and a page's result is no proposal",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      actor = Sanctum.Context.actor(here)

      older =
        proposed!(here, thread, %{
          "name" => "older-way",
          "description" => "d",
          "content" => "c",
          "against" => "none"
        })

      for n <- 1..501 do
        {:ok, _result} =
          Threads.append(actor, thread.id, %{
            author: Prima.Author.agent(),
            sent_by: "aqua",
            kind: "tool_result",
            content: "result #{n}",
            payload: %{"tool_call_id" => "c#{n}", "name" => "files", "is_error" => false}
          })
      end

      paged =
        proposed!(
          here,
          thread,
          %{"name" => "paged-way", "description" => "d", "content" => "c", "against" => "none"},
          "page_result"
        )

      pane = open_pane(conn, athanor, thread)

      assert pane |> element(card(older, "name")) |> render() =~ "older-way"
      refute has_element?(pane, card(paged, "name"))
    end
  end

  # A file a turn proposed beside a scroll waits for the person: its card
  # shows its path, its size and digest, what it replaces, the whole text,
  # and the two things true of a script, each by its rule; Save file keeps
  # the proposal on that row as the card showed it, from the person's own
  # session, or says why it did not.
  describe "a file a turn proposed" do
    defp file_proposed!(here, thread, proposal) do
      {:ok, row} =
        Threads.append(Sanctum.Context.actor(here), thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "tool_result",
          status: "proposed",
          content: "proposed",
          payload: %{
            "tool_call_id" => "c1",
            "name" => "aqua",
            "is_error" => false,
            "proposal" => proposal
          }
        })

      row
    end

    defp file_card(row, part), do: ~s([id$="-proposal-#{row.id}-#{part}"])

    # A proposal as the loop keeps it on its row (`Aqua.Loop`).
    defp a_file(path, bytes, extra \\ %{}) do
      runs = match?(<<"#!", _::binary>>, bytes)

      Map.merge(
        %{
          "name" => "mine:fern",
          "path" => path,
          "content" => bytes,
          "size" => byte_size(bytes),
          "sha256" => Prima.Digest.sha256(bytes),
          "against" => "none",
          "against_size" => nil,
          "runs" => runs,
          "script" => runs or String.contains?(path, "/scripts/")
        },
        extra
      )
    end

    defp fern!(here) do
      {:ok, _} =
        Arca.Files.write(
          Sanctum.Context.actor(here),
          "aqua/scrolls/mine/skills/fern/SKILL.md",
          "---\nname: fern\ndescription: d\n---\n\nWater it.\n"
        )
    end

    test "a script's card shows all of it and what is true of it, and Save file writes exactly it",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      fern!(here)
      actor = Sanctum.Context.actor(here)
      lines = for n <- 1..3_000, do: "echo line #{n}\n"
      script = IO.iodata_to_binary(["#!/bin/sh\n" | lines])
      path = "skills/fern/scripts/water.sh"
      row = file_proposed!(here, thread, a_file(path, script))
      pane = open_pane(conn, athanor, thread)

      assert pane |> element(file_card(row, "path")) |> render() =~ path
      size = pane |> element(file_card(row, "size")) |> render()
      assert size =~ "#{byte_size(script)} bytes"
      assert size =~ Prima.Digest.sha256(script)
      refute has_element?(pane, file_card(row, "replaces"))

      assert pane |> element(file_card(row, "executable")) |> render() =~
               "It begins with #!, so it will be executable."

      may = pane |> element(file_card(row, "script")) |> render()
      assert may =~ "your programs may run it in their sessions."
      assert may =~ "Bring in only packs you trust."

      # The whole script, its last line among it, never a cut view.
      shown = pane |> element(file_card(row, "content")) |> render()
      assert shown =~ "echo line 1\n"
      assert shown =~ "echo line 3000\n"

      assert {:error, :not_found} =
               Arca.get(actor, ~w(aqua scrolls mine skills fern scripts water.sh))

      pane |> element(file_card(row, "save")) |> render_click()
      assert pane |> element(file_card(row, "saved")) |> render() =~ "Saved beside the scroll."
      assert {:ok, ^script} = Arca.get(actor, ~w(aqua scrolls mine skills fern scripts water.sh))

      # A second proposal that read the same absence is refused once the
      # first is saved, and the first stays.
      again = file_proposed!(here, thread, a_file(path, "#!/bin/sh\necho other\n"))

      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        thread_id: thread.id,
        athanor_id: athanor.id,
        kind: :message,
        data: again
      })

      pane |> element(file_card(again, "save")) |> render_click()

      assert pane |> element(file_card(again, "refused")) |> render() =~
               "changed since Aqua proposed this"

      assert {:ok, ^script} = Arca.get(actor, ~w(aqua scrolls mine skills fern scripts water.sh))
    end

    # Each line is said by its own rule: a reference under scripts/ that
    # does not begin with `#!` is no executable file, while a program may
    # still run it; a file beside the scroll is neither. A replacement says
    # what it replaces, by the old file's size and digest.
    test "a card says only what is true of its file, and what a replacement replaces",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      fern!(here)
      readme = file_proposed!(here, thread, a_file("skills/fern/scripts/README.txt", "Notes.\n"))

      notes =
        file_proposed!(
          here,
          thread,
          a_file("skills/fern/notes.md", "Shade.\n", %{
            "against" => Prima.Digest.sha256("Sun.\n"),
            "against_size" => 5
          })
        )

      pane = open_pane(conn, athanor, thread)

      refute has_element?(pane, file_card(readme, "executable"))
      assert has_element?(pane, file_card(readme, "script"))
      refute has_element?(pane, file_card(notes, "executable"))
      refute has_element?(pane, file_card(notes, "script"))

      assert pane |> element(file_card(notes, "replaces")) |> render() =~
               "It replaces the file as Aqua read it: 5 bytes, #{Prima.Digest.sha256("Sun.\n")}."
    end

    # Save keeps the proposal as the card showed it: a row changed after the
    # card was drawn is not saved by the old card.
    test "a card whose row changed after it was drawn saves nothing",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      fern!(here)
      actor = Sanctum.Context.actor(here)
      path = "skills/fern/notes.txt"
      row = file_proposed!(here, thread, a_file(path, "version one"))
      pane = open_pane(conn, athanor, thread)
      assert pane |> element(file_card(row, "content")) |> render() =~ "version one"

      next = Map.put(Threads.payload(row), "proposal", a_file(path, "version two"))
      {:ok, _} = Threads.update_message(actor, row.id, %{payload: next})

      pane |> element(file_card(row, "save")) |> render_click()

      assert pane |> element(file_card(row, "refused")) |> render() =~
               "This proposal is not the file its card showed"

      assert {:error, :not_found} = Arca.get(actor, ~w(aqua scrolls mine skills fern notes.txt))
    end

    test "a file whose scroll is not saved yet is refused, saying to save the scroll first",
         %{conn: conn, athanor: athanor, here: here, thread: thread} do
      row =
        file_proposed!(
          here,
          thread,
          a_file("skills/tulip/notes.md", "Plant in autumn.\n", %{"name" => "mine:tulip"})
        )

      pane = open_pane(conn, athanor, thread)
      assert pane |> element(file_card(row, "content")) |> render() =~ "Plant in autumn."
      pane |> element(file_card(row, "save")) |> render_click()

      assert pane |> element(file_card(row, "refused")) |> render() =~
               "Save the scroll `mine:tulip` first: this file belongs to it"
    end
  end

  describe "a question's choices as buttons" do
    defp choices_block(tag, lines \\ ["- PostgreSQL", "- SQLite"], question \\ "Which database?"),
      do: "```choices #{tag}\n#{question}\n" <> Enum.join(lines, "\n") <> "\n```"

    # A soul turn of `thread` the person's line opened, at `status`.
    defp soul_turn!(here, thread, status) do
      {:ok, %{turn: turn}} =
        Arca.TurnStorage.accept_message(Sanctum.Context.actor(here), thread.id, %{
          message: %{author: here.user_id, sent_by: "person", content: "export"},
          turn: %{agent: "aqua", requested_by: here.user_id, origin: :interactive}
        })

      turn_status!(turn, status)
    end

    defp turn_status!(turn, status) do
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [status: status]
        )

      turn
    end

    # A row the turn's brain says, through the tape, which tells the pane.
    defp brain_said!(here, thread, turn, content, payload \\ %{"step_id" => "stp_said"}) do
      {:ok, row} =
        Aqua.Tape.append(here, thread.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "text",
          content: content,
          payload: payload,
          turn_id: turn.id
        })

      row
    end

    defp choices(row), do: ~s([id$="-choices-#{row.id}"])
    defp choice(row, at), do: ~s([id$="-choices-#{row.id}-#{at}"])

    defp turn_finished(pane, athanor, thread) do
      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: athanor.id,
        thread_id: thread.id,
        kind: :turn_finished,
        data: %{}
      })
    end

    defp presses(here, thread),
      do:
        for(
          m <- Threads.messages(Sanctum.Context.actor(here), thread.id),
          Threads.payload(m)["choice"] != nil,
          do: m
        )

    test "a final reply's block is drawn as buttons once its turn is over, live and opened " <>
           "again, its question as plain text; a press answers Aqua with the choice, and the " <>
           "card stays as it is for another press",
         %{conn: conn, athanor: athanor, here: here} do
      Sanctum.TestContext.ready!(athanor.id)
      Cyfr.Test.Sandbox.stop_work_on_exit()
      {:ok, today} = Aqua.Day.current(here)
      # The pane's runner is up before the turn is, so it recovers none.
      pane = open_pane(conn, athanor, today)
      turn = soul_turn!(here, today, "running")
      asked = "Keep **both** [versions](https://example.com)?"

      row =
        brain_said!(
          here,
          today,
          turn,
          "Pick one.\n\n" <> choices_block(turn.id, ["- PostgreSQL", "- SQLite"], asked)
        )

      # While its turn runs it may not be the final reply: text, no buttons.
      Prima.Test.Wait.wait_until(fn -> render(pane) =~ "Pick one." end)
      refute has_element?(pane, choices(row))

      turn_status!(turn, "completed")
      turn_finished(pane, athanor, today)

      Prima.Test.Wait.wait_until(fn -> has_element?(pane, choice(row, 1), "SQLite") end)
      second = open_pane(conn, athanor, today)

      for view <- [pane, second] do
        assert view |> element(~s([id$="-choices-#{row.id}-question"])) |> render() =~
                 "Keep **both** [versions](https://example.com)?"

        assert has_element?(view, choice(row, 0) <> ":not([disabled])", "PostgreSQL")
      end

      pane |> element(choice(row, 1)) |> render_click()
      [pressed] = presses(here, today)
      assert %{content: "SQLite", sent_by: "person", author: author} = pressed
      assert author == here.user_id

      assert Threads.payload(pressed)["choice"] == %{
               "row" => row.id,
               "index" => 1,
               "question" => asked,
               "label" => "SQLite"
             }

      Prima.Test.Wait.wait_until(fn ->
        has_element?(pane, ~s([id$="-m-#{pressed.id}"]), "You chose «SQLite»")
      end)

      # The other tab presses too, after the first: its own press.
      assert has_element?(second, choice(row, 0) <> ":not([disabled])")
      second |> element(choice(row, 0)) |> render_click()
      assert [_, %{content: "PostgreSQL"}] = presses(here, today)
      Cyfr.Test.Sandbox.end_views()
    end

    test "a card is read once: a row that arrives after it reads it no more, and its file " <>
           "line reads no file's bytes",
         %{conn: conn, athanor: athanor, here: here} do
      {:ok, today} = Aqua.Day.current(here)
      path = "data/aqua/plans/plan-1-export.md"
      :ok = Arca.put(Sanctum.Context.actor(here), String.split(path, "/"), "# Export\n")
      pane = open_pane(conn, athanor, today)
      turn = soul_turn!(here, today, "running")

      row =
        brain_said!(here, today, turn, choices_block(turn.id, ["- Proceed", "file: " <> path]))

      Prima.Test.Wait.wait_until(fn -> render(pane) =~ "Which database?" end)

      # What the pane's process calls from here on, as the trace sees it.
      tracer = self()
      :erlang.trace(pane.pid, true, [:call, {:tracer, tracer}])
      :erlang.trace_pattern({Aqua.Choices, :read, 2}, true, [])
      :erlang.trace_pattern({Arca.Files, :read, 2}, true, [])

      on_exit(fn ->
        :erlang.trace_pattern({Aqua.Choices, :read, 2}, false, [])
        :erlang.trace_pattern({Arca.Files, :read, 2}, false, [])
      end)

      turn_status!(turn, "completed")
      turn_finished(pane, athanor, today)

      Prima.Test.Wait.wait_until(fn -> has_element?(pane, choice(row, 0), "Proceed") end)

      card_id = row.id
      assert_receive {:trace, _, :call, {Aqua.Choices, :read, [_, %{id: ^card_id}]}}

      {:ok, _later} =
        Aqua.Tape.append(here, today.id, %{
          author: here.user_id,
          sent_by: "person",
          kind: "text",
          content: "later"
        })

      Prima.Test.Wait.wait_until(fn -> render(pane) =~ "later" end)
      :erlang.trace(pane.pid, false, [:call])

      refute_received {:trace, _, :call, {Aqua.Choices, :read, [_, %{id: ^card_id}]}}
      refute_received {:trace, _, :call, {Arca.Files, :read, _}}
      Cyfr.Test.Sandbox.end_views()
    end

    test "a file line shows Download while Files lists the file, and says so when it does " <>
           "not, the choices kept",
         %{conn: conn, athanor: athanor, here: here} do
      {:ok, today} = Aqua.Day.current(here)
      path = "data/aqua/plans/plan-1-export.md"
      :ok = Arca.put(Sanctum.Context.actor(here), String.split(path, "/"), "# Export\n")
      kept = soul_turn!(here, today, "completed")

      held =
        brain_said!(here, today, kept, choices_block(kept.id, ["- Proceed", "file: " <> path]))

      gone = soul_turn!(here, today, "completed")

      missing =
        brain_said!(
          here,
          today,
          gone,
          choices_block(gone.id, ["- Proceed", "file: data/gone.md"])
        )

      pane = open_pane(conn, athanor, today)
      assert has_element?(pane, ~s([id$="-choices-#{held.id}-download"]), "Download")
      assert has_element?(pane, choice(missing, 0), "Proceed")

      assert has_element?(
               pane,
               ~s([id$="-choices-#{missing.id}-missing"]),
               "This file is not in Files"
             )

      refute has_element?(pane, ~s([id$="-choices-#{missing.id}-download"]))
      Cyfr.Test.Sandbox.end_views()
    end

    test "a person's line, a post a tool wrote and an intermediate reply carrying the turn's " <>
           "block are text, live and opened again",
         %{conn: conn, athanor: athanor, here: here} do
      {:ok, today} = Aqua.Day.current(here)
      pane = open_pane(conn, athanor, today)
      turn = soul_turn!(here, today, "running")

      {:ok, person} =
        Aqua.Tape.append(here, today.id, %{
          author: here.user_id,
          sent_by: "person",
          kind: "text",
          content: choices_block(turn.id),
          turn_id: turn.id
        })

      early = brain_said!(here, today, turn, choices_block(turn.id))
      posted = brain_said!(here, today, turn, choices_block(turn.id), %{"post" => true})
      _final = brain_said!(here, today, turn, "Done.")
      turn_status!(turn, "completed")
      turn_finished(pane, athanor, today)

      Prima.Test.Wait.wait_until(fn -> render(pane) =~ "Done." end)
      again = open_pane(conn, athanor, today)

      for view <- [pane, again], row <- [person, early, posted] do
        refute has_element?(view, choices(row))
      end

      Cyfr.Test.Sandbox.end_views()
    end
  end
end
