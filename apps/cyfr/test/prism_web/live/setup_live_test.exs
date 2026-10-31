# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SetupLiveTest do
  @moduledoc """
  `/setup`: the setup link's token, handed over from the fragment, opens
  the two screens. Screen 1 takes the first person's name, checked
  against cyfr.run, and their passkey, whose registration with the name
  and the browser's recovery secret and request id makes the person,
  their athanor, the passkey, the platform grant and their enrollment.
  Screen 2 registers them at cyfr.run before any session cookie, pushes
  their recovery code once to the page's hook, and "I saved it" signs
  them in with the offer of another code. Each answer of cyfr.run leaves
  screen 2 in its state, and a page that ends before "I saved it"
  resumes in Settings. A token that is not this CYFR's, and a CYFR set up
  already, are one answer, and no ceremony starts.
  """

  # The setup token is process-wide configuration.
  use PrismWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import PrismWeb.AdmissionScreens

  alias Arca.Schemas.{IdentityAttempt, Membership, Passkey, User}

  @token String.duplicate("5e", 32)
  @saved "Saved. You can add another recovery code in Settings, and keep it apart from this one."

  setup do
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)

    # The installation holds no person inside this test's transaction,
    # whatever the suite committed: the first person is the question.
    Arca.Repo.delete_all(User)
    :ok
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp passkeys, do: Arca.Repo.aggregate(Passkey, :count)

  defp grants,
    do: Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)

  defp person do
    [person] = Arca.Repo.all(User)
    person
  end

  defp attempt(user_id),
    do: Arca.Repo.get_by!(IdentityAttempt, user_id: user_id, kind: "enrollment")

  # The page with the link's token handed over, as its script does.
  defp opened(conn, token \\ @token) do
    browser = get(conn, ~p"/setup")
    {:ok, view, _html} = live(browser, ~p"/setup")
    render_hook(view, "setup_token", %{"token" => token})
    {browser, view}
  end

  # Screen 1 with `name` typed and the passkey made: screen 2, driven.
  defp created(conn, name) do
    {browser, view} = opened(conn)
    name!(view, name)
    identity = admit!(view, "setup")
    {browser, view, identity}
  end

  describe "screen 1" do
    @tag :capture_log
    test "checks the name against cyfr.run, and Create a passkey waits for a name that may go on",
         %{conn: conn} do
      directory!()
      registry!(%{"held" => :taken, "quiet" => :close})
      {_browser, view} = opened(conn)

      assert has_element?(view, "h1", "Set up CYFR")
      assert has_element?(view, "p", "You are the first person on this CYFR, and you run it.")
      assert has_element?(view, ~s(label[for="admission-name-input"]), "Your name")
      assert has_element?(view, ~s([data-test="admission-name-input"]))

      assert has_element?(
               view,
               "p",
               "People find you by this name on every CYFR. It is yours for life and cannot be changed."
             )

      assert has_element?(view, "p", "This creates your name at cyfr.run under its terms.")
      assert has_element?(view, ~s([data-test="admission-create"][disabled]), "Create a passkey")
      assert has_element?(view, ~s([data-test="admission-create"][data-webauthn-start]))
      refute_vocabulary(render(view))

      for {typed, check, sentence, disabled} <- [
            {"", "idle", "Lowercase letters, digits and hyphens.", true},
            {"held", "taken", "Taken. Choose another.", true},
            {"Not A Name", "invalid",
             "A name is lowercase letters and digits joined by single hyphens, at most 39 characters.",
             true},
            {"mira", "free", "Free. Lowercase letters, digits and hyphens.", false},
            {"quiet", "unavailable",
             "cyfr.run did not answer, so your name is checked again when you create it.", false}
          ] do
        name!(view, typed)

        assert has_element?(
                 view,
                 ~s([data-test="admission-name-check"][data-check="#{check}"]),
                 sentence
               )

        assert has_element?(view, ~s([data-test="admission-create"][disabled])) == disabled,
               typed

        refute_vocabulary(render(view))
      end

      # The event, not the disabled button: the page holds the order.
      name!(view, "held")
      render_hook(view, "setup_start", %{})
      assert_reply(view, %{error: true})
      assert people() == 0
    end

    test "a wrong token, a missing one and a CYFR with no setup token are one answer, and start no ceremony",
         %{conn: conn} do
      for token <- [String.duplicate("0f", 32), "", "not-hex"] do
        {_browser, view} = opened(conn, token)

        assert has_element?(
                 view,
                 ~s([data-test="setup-closed"]),
                 "not valid, or setup is complete"
               )

        refute has_element?(view, ~s([data-test="admission-create"]))
        refute_vocabulary(render(view))

        render_hook(view, "setup_start", %{})
        assert_reply(view, %{error: true})
      end

      Prima.Test.Env.delete_app_env(:sanctum, :setup_token)
      {_browser, view} = opened(conn)
      assert has_element?(view, ~s([data-test="setup-closed"]))
      assert people() == 0
    end

    test "a cancelled ceremony writes nothing and the passkey can be created again", %{
      conn: conn
    } do
      directory!()
      registry!()
      {_browser, view} = opened(conn)
      name!(view, "mira")
      render_hook(view, "setup_start", %{})
      render_hook(view, "setup_error", %{})

      assert has_element?(
               view,
               ~s([data-test="admission-error"]),
               "The passkey was not created, so nothing was saved. Try again."
             )

      assert has_element?(view, ~s([data-test="admission-create"]))
      assert {people(), passkeys(), grants()} == {0, 0, 0}

      admit!(view, "setup")
      assert screen_2?(view, :code)
      assert people() == 1
    end

    test "a registration that does not verify writes nothing", %{conn: conn} do
      directory!()
      registry!()
      {_browser, view} = opened(conn)
      name!(view, "mira")
      credential = view |> ceremony("setup") |> put_in(["response", "clientDataJSON"], "e30")

      admit!(view, "setup", credential)
      assert has_element?(view, ~s([data-test="admission-error"]), "could not be registered")
      assert {people(), passkeys(), grants()} == {0, 0, 0}
    end

    test "with no directory pinned, the no-registry sentence and nothing made", %{conn: conn} do
      Prima.Test.Env.delete_app_env(:sanctum, :directory_url)
      registry!()
      {_browser, view} = opened(conn)
      name!(view, "mira")
      admit!(view, "setup")

      assert has_element?(
               view,
               ~s([data-test="admission-error"]),
               "This CYFR does not reach cyfr.run, so it cannot make your name. Ask whoever runs this CYFR."
             )

      refute has_element?(view, ~s([data-test="admission-code"]))
      assert {people(), passkeys(), grants()} == {0, 0, 0}
      refute_vocabulary(render(view))
    end

    test "a second tab after setup is sent to sign in, and its ceremony writes nothing", %{
      conn: conn
    } do
      directory!()
      registry!()
      {_browser, first} = opened(conn)
      {_browser, second} = opened(conn)
      name!(first, "mira")
      name!(second, "nova")
      second_credential = ceremony(second, "setup")

      admit!(first, "setup")
      assert {people(), passkeys()} == {1, 1}

      # The open tab's registration is refused at the admission, which
      # holds the person's passkey now.
      admit!(second, "setup", second_credential)
      assert has_element?(second, ~s([data-test="setup-closed"]))
      assert has_element?(second, ~s(a[href="/login"]))
      assert {people(), passkeys()} == {1, 1}

      # A tab opened now is told so before any ceremony.
      {_browser, third} = opened(conn)
      assert has_element?(third, ~s([data-test="setup-closed"]))
    end
  end

  describe "screen 2" do
    test "registers the name, pushes the code once and never renders it, and I saved it signs the person in with the offer of another code",
         %{conn: conn} do
      directory!()
      registry!()

      {{browser, view, identity}, log} = with_log(fn -> created(conn, "mira") end)

      assert {people(), passkeys(), grants()} == {1, 1, 1}
      %{id: user_id, admission: "setup", namespace: "mira"} = person()
      assert %{phase: "accepted", name: "mira"} = attempt = attempt(user_id)

      code = code!(view)
      assert code == Prima.RecoveryCode.encode(attempt.identifier, identity.recovery_secret)
      refute_push_event(view, "admission_code", %{})

      assert screen_2?(view, :code)
      assert has_element?(view, "h2", "Your recovery code")
      assert has_element?(view, ~s([data-test="recovery-code"]))
      refute has_element?(view, ~s([data-test="recovery-code"]), "CYFR-")

      assert has_element?(
               view,
               "p",
               "If this CYFR is ever lost, this is the one thing that brings you back. Save it in " <>
                 "your password manager, or print this page. Once you say you saved it, CYFR forgets it."
             )

      assert has_element?(view, ~s([data-test="admission-copy"]), "Copy")
      assert has_element?(view, ~s([data-test="admission-saved"]), "I saved it")
      refute_vocabulary(render(view))

      # The code and the secret are in no render, no state the page
      # inspects to, and no log line.
      secret = Base.url_encode64(identity.recovery_secret, padding: false)
      state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

      for text <- [render(view), state, log] do
        refute text =~ code
        refute text =~ secret
      end

      # No session cookie until the code is saved.
      assert get_session(browser, :sanctum_session_token) == nil

      view |> element(~s([data-test="admission-saved"])) |> render_click()
      {path, _flash} = assert_redirect(view)
      assert "/auth/passkey/complete/" <> _ticket = path

      assert %{phase: "completed", kit_seed_sealed: nil} = attempt(user_id)

      landed = get(browser, path)
      assert redirected_to(landed) == "/"
      assert Phoenix.Flash.get(landed.assigns.flash, :info) == @saved
      token = get_session(landed, :sanctum_session_token)
      assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(token)

      # A finished person lands in the chat, the offer with them.
      assert {:error, {:live_redirect, %{to: "/chat" <> _, flash: flash}}} =
               live(recycle(landed), ~p"/")

      assert flash["info"] == @saved
    end

    @tag :capture_log
    test "cyfr.run's directory silent: Try again, and the repeat finishes", %{conn: conn} do
      directory = directory!()
      registry!()
      {_browser, view} = opened(conn)
      name!(view, "mira")
      next_genesis(directory, :drop)
      admit!(view, "setup")

      assert screen_2?(view, :silent)

      assert has_element?(
               view,
               ~s([data-test="admission-code"]),
               "cyfr.run did not answer. Try again."
             )

      assert has_element?(view, ~s([data-test="admission-retry"]), "Try again")
      refute has_element?(view, ~s([data-test="admission-saved"]))
      refute_push_event(view, "admission_code", %{})
      %{id: user_id, namespace: nil} = person()
      assert %{phase: "submitted"} = attempt(user_id)
      refute_vocabulary(render(view))

      view |> element(~s([data-test="admission-retry"])) |> render_click()
      render(view)
      assert screen_2?(view, :code)
      assert code!(view) =~ "CYFR-"
      assert %{namespace: "mira"} = person()
    end

    test "cyfr.run's directory refuses: the sentence, and no way on", %{conn: conn} do
      directory = directory!()
      registry!()
      {_browser, view} = opened(conn)
      name!(view, "mira")
      next_genesis(directory, :refuse)
      admit!(view, "setup")

      assert screen_2?(view, :refused)

      assert has_element?(
               view,
               ~s([data-test="admission-code"]),
               "cyfr.run refused this identity. Ask whoever runs this CYFR."
             )

      for control <- ~w(admission-retry admission-saved admission-rename) do
        refute has_element?(view, ~s([data-test="#{control}"])), control
      end

      refute_push_event(view, "admission_code", %{})
      assert %{phase: "refused"} = attempt(person().id)
      refute_vocabulary(render(view))
    end

    @tag :capture_log
    test "cyfr.run's registry silent, or its terms unreadable: Try again, with the identity registered and no name",
         %{conn: conn} do
      directory!()
      registry = registry!(%{}, version: :close)
      {_browser, view} = opened(conn)
      name!(view, "mira")
      admit!(view, "setup")

      assert screen_2?(view, :silent)
      assert has_element?(view, ~s([data-test="admission-retry"]))
      %{id: user_id, namespace: nil} = person()
      assert %{phase: "accepted"} = attempt(user_id)
      refute_vocabulary(render(view))

      script(registry, version: :unreadable)
      view |> element(~s([data-test="admission-retry"])) |> render_click()
      render(view)
      assert screen_2?(view, :silent)
      assert %{namespace: nil} = person()

      script(registry, version: :answer)
      view |> element(~s([data-test="admission-retry"])) |> render_click()
      render(view)
      assert screen_2?(view, :code)
      assert %{namespace: "mira"} = person()
    end

    test "a name taken at the claim asks for another, which is claimed in its place", %{
      conn: conn
    } do
      directory!()
      registry!(%{}, claims: [:taken, :taken])
      {_browser, view} = opened(conn)
      name!(view, "mira")
      admit!(view, "setup")

      assert screen_2?(view, :taken)

      assert has_element?(
               view,
               ~s([data-test="admission-code"]),
               "Someone took @mira a moment ago. Choose another name."
             )

      assert has_element?(view, ~s([data-test="admission-rename-input"]))
      assert has_element?(view, ~s([data-test="admission-rename"]), "Use this name")
      refute_push_event(view, "admission_code", %{})
      %{id: user_id, namespace: nil} = person()
      assert %{phase: "accepted"} = attempt(user_id)
      refute_vocabulary(render(view))

      # A name that is no name is said, and sends nothing.
      view |> element("#admission-rename") |> render_submit(%{"name" => "Not A Name"})
      assert screen_2?(view, :taken)
      assert has_element?(view, ~s([data-test="admission-error"]), "at most 39 characters")

      view |> element("#admission-rename") |> render_submit(%{"name" => "nova"})
      render(view)
      assert screen_2?(view, :taken)
      assert has_element?(view, ~s([data-test="admission-code"]), "Someone took @nova")

      view |> element("#admission-rename") |> render_submit(%{"name" => "stella"})
      render(view)
      assert screen_2?(view, :code)
      assert code!(view) =~ "CYFR-"
      assert %{namespace: "stella"} = person()
      assert %{name: "stella"} = attempt(user_id)
    end

    test "a name cyfr.run keeps for itself asks for another", %{conn: conn} do
      directory!()
      registry!(%{}, claims: [:reserved])
      {_browser, view} = opened(conn)
      name!(view, "mira")
      admit!(view, "setup")

      assert screen_2?(view, :reserved)

      assert has_element?(
               view,
               ~s([data-test="admission-code"]),
               "cyfr.run keeps @mira for itself. Choose another name."
             )

      assert has_element?(view, ~s([data-test="admission-rename"]), "Use this name")
      assert %{namespace: nil} = person()
      refute_vocabulary(render(view))

      view |> element("#admission-rename") |> render_submit(%{"name" => "nova"})
      render(view)
      assert screen_2?(view, :code)
      assert %{namespace: "nova"} = person()
    end

    test "with no registry, the identity is registered, no name is made, and there is no way on",
         %{conn: conn} do
      directory!()
      registry!()
      for app <- [:sanctum, :cyfr], do: Prima.Test.Env.put_app_env(app, :registry_url, "none")
      {_browser, view} = opened(conn)
      name!(view, "mira")
      admit!(view, "setup")

      assert screen_2?(view, :no_registry)

      assert has_element?(
               view,
               ~s([data-test="admission-code"]),
               "This CYFR does not reach cyfr.run, so it cannot make your name. Ask whoever runs this CYFR."
             )

      for control <- ~w(admission-retry admission-saved admission-rename) do
        refute has_element?(view, ~s([data-test="#{control}"])), control
      end

      %{id: user_id, namespace: nil} = person()
      assert %{phase: "accepted"} = attempt(user_id)
      refute_vocabulary(render(view))
    end

    test "a page that ends before I saved it set no cookie; signed in by the passkey, the person lands on Settings, which finishes them",
         %{conn: conn} do
      directory!()
      registry!()
      {browser, view, identity} = created(conn, "mira")
      assert screen_2?(view, :code)
      assert get_session(browser, :sanctum_session_token) == nil

      # The page reloaded: setup is complete, and the person signs in.
      {_browser, again} = opened(conn)
      assert has_element?(again, ~s([data-test="setup-closed"]))

      %{id: user_id} = person()

      signed_in =
        log_in_user(build_conn(), %{user_id: user_id, email: nil, namespace: nil}, claim: false)

      {:error, {:live_redirect, %{to: to}}} = live(signed_in, ~p"/")
      assert to == athanor_path("/settings")

      {:ok, settings, _html} = live(signed_in, to)
      render(settings)
      assert has_element?(settings, ~s([data-test="identity"][data-state="unfinished"]))
      assert has_element?(settings, ~s([data-test="admission-code"][data-state="code"]))

      settings |> element(~s([data-test="identity-show-code"])) |> render_click()
      render(settings)
      assert has_element?(settings, ~s(#system-layer [data-test="recovery"][data-kind="kit"]))
      refute render(settings) =~ Base.url_encode64(identity.recovery_secret, padding: false)
    end

    test "a person set up from the command line registers their passkey here, the same person and the same code",
         %{conn: conn} do
      directory!()
      registry!()
      first = Sanctum.Test.Newcomers.identity("mira")

      {:ok, %{person: %{id: person_id}, recovery: %{code: first_code}}} =
        Sanctum.Newcomer.admit({:setup, @token}, {:command_line, "laptop", first})

      {_browser, view} = opened(conn)
      name!(view, "nova")
      admit!(view, "setup")

      assert [%{id: ^person_id, namespace: "mira"}] = Arca.Repo.all(User)
      assert [%{user_id: ^person_id}] = Arca.Repo.all(Passkey)
      assert screen_2?(view, :code)
      assert code!(view) == first_code

      # The passkey closes setup.
      {_browser, again} = opened(conn)
      assert has_element?(again, ~s([data-test="setup-closed"]))
    end
  end
end
