# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.SessionSetupTest do
  @moduledoc """
  `session.setup` through the gate as the command line reaches it
  (`cyfr login --setup`): anonymous, the installation's setup token its
  argument. It makes the first person, their administrator grant and a
  command-line session for the machine; it signs the same person in again
  while they hold no sign-in method; and from their first passkey on, and
  for any token that is not this CYFR's, it answers `setup_closed`.
  """

  # The setup token is process-wide configuration.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Membership, User}
  alias Sanctum.Context
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
    Arca.Repo.delete_all(User)
    :ok
  end

  defp command_line, do: Context.build(%{authenticated: false, client_ip: "198.51.100.62"})

  defp set_up(args),
    do: Sanctum.Gate.call_external("session", command_line(), Map.put(args, "action", "setup"))

  defp grants,
    do: Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)

  defp refused_reason({:error, %Prima.Refusal{reason: reason}}), do: reason
  defp refused_reason({:error, reason}) when is_atom(reason), do: reason

  test "the first call makes the first person with a command-line session, and a repeat signs them in again" do
    assert {:ok, first} = set_up(%{"setup_token" => @token, "machine" => "laptop"})
    assert %{readmitted: false, user_id: user_id, session_token: token} = first
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(token)
    assert [%{id: ^user_id, admission: "setup"}] = Arca.Repo.all(User)
    assert grants() == 1

    assert {:ok, %{readmitted: true, user_id: ^user_id, session_token: again}} =
             set_up(%{"setup_token" => @token, "machine" => "laptop"})

    assert again != token
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(again)
    assert Arca.Repo.aggregate(User, :count) == 1
    assert grants() == 1
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
             Sanctum.Newcomer.admit({:setup, @token}, {:passkey, registration})

    assert refused_reason(set_up(%{"setup_token" => @token, "machine" => "laptop"})) ==
             :setup_closed
  end

  test "a machine name the command line cannot be listed by is refused before any row" do
    assert {:error, _invalid} =
             set_up(%{"setup_token" => @token, "machine" => String.duplicate("x", 300)})

    assert Arca.Repo.aggregate(User, :count) == 0
  end
end
