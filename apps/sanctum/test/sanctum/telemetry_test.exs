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

      events = []

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

  describe "attach_default_logger/0" do
    test "attaches a handler" do
      # Detach first in case it was attached during app startup
      Telemetry.detach_default_logger()

      assert :ok = Telemetry.attach_default_logger()
      # Second attach should fail
      assert {:error, :already_exists} = Telemetry.attach_default_logger()
    end

    test "can be detached" do
      Telemetry.attach_default_logger()
      assert :ok = Telemetry.detach_default_logger()
      # Should be able to attach again after detach
      assert :ok = Telemetry.attach_default_logger()
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
end
