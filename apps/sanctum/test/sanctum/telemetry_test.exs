# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TelemetryTest do
  use ExUnit.Case, async: false

  alias Sanctum.Telemetry

  setup do
    # Detach any existing handlers
    :telemetry.detach("test-auth-handler")

    on_exit(fn ->
      :telemetry.detach("test-auth-handler")
    end)

    :ok
  end

  describe "auth_event/3" do
    test "emits telemetry event with correct event name" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-auth-handler",
        [:cyfr, :sanctum, :auth],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, ref, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.auth_event(:github, :success)

      assert_receive {:telemetry_event, ^ref, [:cyfr, :sanctum, :auth], measurements, metadata}
      assert measurements == %{count: 1}
      assert metadata.provider == :github
      assert metadata.outcome == :success
    end

    test "includes failure outcome" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-auth-handler",
        [:cyfr, :sanctum, :auth],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:event, ref, metadata})
        end,
        nil
      )

      Telemetry.auth_event(:github, :failure)

      assert_receive {:event, ^ref, metadata}
      assert metadata.provider == :github
      assert metadata.outcome == :failure
    end

    test "includes additional metadata" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-auth-handler",
        [:cyfr, :sanctum, :auth],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:event, ref, metadata})
        end,
        nil
      )

      Telemetry.auth_event(:api_key, :failure, %{reason: :invalid_key, key_type: :secret})

      assert_receive {:event, ^ref, metadata}
      assert metadata.provider == :api_key
      assert metadata.outcome == :failure
      assert metadata.reason == :invalid_key
      assert metadata.key_type == :secret
    end

    test "works with various providers" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-auth-handler",
        [:cyfr, :sanctum, :auth],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:event, ref, metadata.provider})
        end,
        nil
      )

      providers = [:github, :google, :oidc, :session, :api_key]

      for provider <- providers do
        Telemetry.auth_event(provider, :success)
        assert_receive {:event, ^ref, ^provider}
      end
    end
  end

  describe "integration with auth providers" do
    test "telemetry auth_event can be called directly" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "test-auth-handler",
        [:cyfr, :sanctum, :auth],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:event, ref, metadata})
        end,
        nil
      )

      # Call telemetry directly (auth providers emit this on authenticate)
      Telemetry.auth_event(:github, :success)

      assert_receive {:event, ^ref, metadata}
      assert metadata.provider == :github
      assert metadata.outcome == :success
    end
  end
  # The identity domain announces its standing changes as telemetry and
  # never broadcasts: what it hands the host's bridge is data, and naming
  # no topic is the point.
  describe "the standing announcements" do
    defp capture(events) do
      test = self()
      handler = "sanctum-announce-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _config ->
          send(test, {:announced, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "a tray entry names its athanor, kind and payload, and the platform's names none" do
      capture([[:cyfr, :sanctum, :notify]])

      :ok = Sanctum.Notify.broadcast("ath_1", :member_changed, %{name: "x"})

      assert_receive {:announced, [:cyfr, :sanctum, :notify], %{count: 1},
                      %{athanor_id: "ath_1", kind: :member_changed, payload: %{name: "x"}}}

      :ok = Sanctum.Notify.allowlist_changed()

      assert_receive {:announced, [:cyfr, :sanctum, :notify], _,
                      %{athanor_id: nil, kind: :allowlist_changed, payload: %{}}}
    end

    test "the tray's vocabulary is closed and is the kind type's" do
      assert Sanctum.Notify.kinds() == [
               :member_changed,
               :athanor_changed,
               :allowlist_request,
               :allowlist_changed,
               :execution_finished,
               :execution_failed,
               :approval_pending,
               :approval_resolved,
               :schedule_failed
             ]

      refute function_exported?(Sanctum.Notify, :topic, 1)
      refute function_exported?(Sanctum.Notify, :platform_topic, 0)
    end

    test "a membership change names the person, the athanor and the change" do
      capture([[:cyfr, :sanctum, :membership, :changed]])

      :ok = Telemetry.membership_changed("user_1", "ath_1", :joined)

      assert_receive {:announced, [:cyfr, :sanctum, :membership, :changed], %{count: 1},
                      %{user_id: "user_1", athanor_id: "ath_1", change: :joined}}

      refute function_exported?(Sanctum.Tenancy.Members, :topic, 1)
    end

    test "a session minted carries nothing, and a revocation names only the person" do
      capture([[:cyfr, :sanctum, :session, :created], [:cyfr, :sanctum, :sessions, :revoked]])

      :ok = Telemetry.session_created()
      assert_receive {:announced, [:cyfr, :sanctum, :session, :created], %{count: 1}, meta}
      assert meta == %{}

      :ok = Telemetry.sessions_revoked("user_1")

      assert_receive {:announced, [:cyfr, :sanctum, :sessions, :revoked], %{count: 1},
                      %{user_id: "user_1"}}

      refute function_exported?(Sanctum.Session, :topic, 0)
    end

    test "a dropped caller memo names the session row key, never a token" do
      capture([[:cyfr, :sanctum, :caller, :invalidated]])
      key = :crypto.hash(:sha256, "a-session-token")

      :ok = Telemetry.caller_invalidated(key)

      assert_receive {:announced, [:cyfr, :sanctum, :caller, :invalidated], %{count: 1},
                      %{hash: ^key} = meta}

      assert Map.keys(meta) == [:hash]
    end

    test "nothing in the identity domain names the PubSub server or a topic module" do
      refute Code.ensure_loaded?(Sanctum.PubSub)

      lib = Path.expand("../../lib", __DIR__)

      found =
        for path <- Path.wildcard(Path.join(lib, "**/*.ex")),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            line =~ ~r/\bPhoenix\.PubSub\b|\bCyfr\.PubSub\b|\bEmissary\.PubSub\b/,
            do: "#{Path.relative_to(path, lib)}:#{n}"

      assert found == []
    end
  end
end
