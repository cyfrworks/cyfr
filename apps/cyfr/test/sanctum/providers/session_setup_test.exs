# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.SessionSetupTest do
  @moduledoc """
  `session.setup` through the gate as the command line reaches it
  (`cyfr login --setup`): anonymous, the installation's setup token, the
  new person's name, the recovery secret and the request id the command
  line drew its arguments. It makes the first person, their administrator
  grant, their enrollment and a command-line session for the machine, and
  answers their recovery code; it signs the same person in again while
  they hold no sign-in method, answering the enrollment that stands; from
  their first passkey on, and for any token that is not this CYFR's, it
  answers `setup_closed`; and a CYFR that pins no directory makes no one.
  """

  # The setup token is process-wide configuration.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{IdentityAttempt, Membership, User}
  alias Sanctum.Context
  alias Sanctum.Test.Newcomers
  alias Sanctum.TestContext.Authenticator

  @token String.duplicate("5e", 32)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    previous = Application.fetch_env(:sanctum, :setup_token)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end)

    Application.put_env(:sanctum, :setup_token, @token)
    Newcomers.directory!()
    Arca.Repo.delete_all(User)
    :ok
  end

  defp command_line, do: Context.build(%{authenticated: false, client_ip: "198.51.100.62"})

  # The call the command line makes: `args` over a fresh identity's fields.
  defp set_up(args, identity \\ Newcomers.identity()) do
    args = Map.merge(Newcomers.fields(identity), Map.put(args, "action", "setup"))
    Sanctum.Gate.call_external("session", command_line(), args)
  end

  defp grants,
    do: Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)

  defp refused_reason({:error, %Prima.Refusal{reason: reason}}), do: reason
  defp refused_reason({:error, reason}) when is_atom(reason), do: reason

  test "the first call makes the first person with a command-line session, and a repeat signs them in again" do
    identity = Newcomers.identity("mira")
    assert {:ok, first} = set_up(%{"setup_token" => @token, "machine" => "laptop"}, identity)
    assert %{readmitted: false, user_id: user_id, session_token: token} = first
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(token)
    assert [%{id: ^user_id, admission: "setup"}] = Arca.Repo.all(User)
    assert grants() == 1

    attempt = Arca.Repo.get_by!(IdentityAttempt, user_id: user_id, kind: "enrollment")
    assert %{phase: "staged", name: "mira"} = attempt
    assert Map.keys(first) |> Enum.sort() == [:readmitted, :recovery, :session_token, :user_id]

    assert first.recovery == %{
             attempt_id: attempt.id,
             identifier: attempt.identifier,
             name: "mira",
             code: Prima.RecoveryCode.encode(attempt.identifier, identity.recovery_secret)
           }

    # Another secret on the repeat is not used: the attempt that stands is
    # answered, with its code.
    assert {:ok, %{readmitted: true, user_id: ^user_id, session_token: again} = second} =
             set_up(%{"setup_token" => @token, "machine" => "laptop"}, Newcomers.identity("x"))

    assert second.recovery == first.recovery
    assert again != token
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(again)
    assert Arca.Repo.aggregate(User, :count) == 1
    assert Arca.Repo.aggregate(IdentityAttempt, :count) == 1
    assert grants() == 1
  end

  test "an identity that does not read is refused before any row" do
    for {field, value} <- [
          {"name", "Not A Name"},
          {"recovery_secret", "short"},
          {"request_id", "no spaces allowed"}
        ] do
      args = Map.merge(Newcomers.fields(), %{"setup_token" => @token, "machine" => "laptop"})

      assert {:error, reason} =
               Sanctum.Gate.call_external(
                 "session",
                 command_line(),
                 Map.merge(args, %{"action" => "setup", field => value})
               )

      assert %Prima.Refusal{class: :invalid_argument} = Sanctum.Refusals.classify(reason), field
    end

    for field <- ~w(name recovery_secret request_id) do
      args =
        Newcomers.fields()
        |> Map.merge(%{"setup_token" => @token, "machine" => "laptop", "action" => "setup"})
        |> Map.delete(field)

      assert {:error, %Prima.Refusal{class: :invalid_argument}} =
               Sanctum.Gate.call_external("session", command_line(), args),
             field
    end

    assert Arca.Repo.aggregate(User, :count) == 0
  end

  test "a CYFR that pins no directory makes no first person, in words its operator reads" do
    Prima.Test.Env.delete_app_env(:sanctum, :directory_url)

    assert {:error, %Prima.Refusal{class: :setup_required, reason: :no_directory, message: m}} =
             set_up(%{"setup_token" => @token, "machine" => "laptop"})

    assert m ==
             "This CYFR does not reach cyfr.run, so it cannot make your name. Ask whoever " <>
               "runs this CYFR."

    assert Arca.Repo.aggregate(User, :count) == 0
  end

  test "a wrong token and a CYFR with no setup token answer setup_closed, writing nothing" do
    assert refused_reason(
             set_up(%{"setup_token" => String.duplicate("0f", 32), "machine" => "m"})
           ) ==
             :setup_closed

    # A present null is a wrong token; a missing one is refused at the gate,
    # before the admission.
    assert refused_reason(set_up(%{"setup_token" => nil, "machine" => "laptop"})) ==
             :setup_closed

    assert {:error, %Prima.Refusal{class: :invalid_argument}} = set_up(%{"machine" => "m"})

    Application.delete_env(:sanctum, :setup_token)
    assert refused_reason(set_up(%{"setup_token" => @token, "machine" => "m"})) == :setup_closed
    assert Arca.Repo.aggregate(User, :count) == 0
  end

  test "once the person holds a passkey, the token opens nothing" do
    {:ok, %{user_id: user_id}} = set_up(%{"setup_token" => @token, "machine" => "laptop"})

    {:ok, options} = Sanctum.Passkeys.newcomer_options()
    registration = Authenticator.registration(Authenticator.new("cli|#{user_id}"), options)

    assert {:ok, %{person: %{id: ^user_id}, readmitted: true}} =
             Sanctum.Newcomer.admit(
               {:setup, @token},
               {:passkey, registration, Newcomers.identity()}
             )

    assert refused_reason(set_up(%{"setup_token" => @token, "machine" => "laptop"})) ==
             :setup_closed
  end

  test "a machine name the command line cannot be listed by is refused before any row" do
    assert {:error, _invalid} =
             set_up(%{"setup_token" => @token, "machine" => String.duplicate("x", 300)})

    assert Arca.Repo.aggregate(User, :count) == 0
  end
end
