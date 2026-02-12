defmodule Emissary.MCP.SessionTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.Session
  alias Emissary.UUID7
  alias Sanctum.Context

  setup do
    Arca.Cache.init()
    :ok
  end

  describe "session ID format" do
    test "generates sess_<uuid7> format" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      assert String.starts_with?(session.id, "sess_")
      # sess_ prefix + 36 char UUID = 41 chars
      assert String.length(session.id) == 41

      # Verify it's a valid UUID7 by extracting timestamp
      {:ok, timestamp} = UUID7.extract_timestamp(session.id)
      assert is_integer(timestamp)
      assert timestamp > 0
    end

    test "session IDs are time-ordered" do
      ctx = Context.local()

      {:ok, session1} = Session.create(ctx)
      # Small delay to ensure different timestamps
      Process.sleep(2)
      {:ok, session2} = Session.create(ctx)

      assert UUID7.before?(session1.id, session2.id)

      # Cleanup
      Session.terminate(session1.id)
      Session.terminate(session2.id)
    end

    test "session IDs are unique" do
      ctx = Context.local()

      sessions =
        for _ <- 1..10 do
          {:ok, session} = Session.create(ctx)
          session
        end

      ids = Enum.map(sessions, & &1.id)
      assert length(Enum.uniq(ids)) == 10

      # Cleanup
      Enum.each(sessions, fn s -> Session.terminate(s.id) end)
    end
  end

  describe "session lifecycle" do
    test "create/2 stores session in cache" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      assert session.context == ctx
      assert session.created_at
      assert session.expires_at
      assert DateTime.compare(session.expires_at, session.created_at) == :gt

      # Verify it can be retrieved
      assert {:ok, ^session} = Session.get(session.id)

      Session.terminate(session.id)
    end

    test "create/3 accepts transport option" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx, %{}, transport: :sse)

      assert session.id
      Session.terminate(session.id)
    end

    test "get/1 returns error for non-existent session" do
      assert {:error, :not_found} = Session.get("sess_nonexistent")
    end

    test "exists?/1 returns true for valid session" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      assert Session.exists?(session.id)

      Session.terminate(session.id)
      refute Session.exists?(session.id)
    end

    test "terminate/1 removes session" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      assert :ok = Session.terminate(session.id)
      assert {:error, :not_found} = Session.get(session.id)
    end

    test "update_capabilities/2 updates session" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx, %{})

      new_caps = %{"tools" => %{"listChanged" => true}}
      {:ok, updated} = Session.update_capabilities(session.id, new_caps)

      assert updated.capabilities == new_caps

      Session.terminate(session.id)
    end
  end

  describe "telemetry" do
    test "emits session created event" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :session]])

      ctx = Context.local()
      {:ok, session} = Session.create(ctx, %{}, transport: :http)

      assert_receive {[:cyfr, :emissary, :session], ^ref, %{count: 1}, metadata}
      assert metadata.lifecycle == :created
      assert metadata.transport == :http
      assert metadata.session_id == session.id

      Session.terminate(session.id)
    end

    test "emits session terminated event" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      ref = :telemetry_test.attach_event_handlers(self(), [[:cyfr, :emissary, :session]])

      Session.terminate(session.id)

      assert_receive {[:cyfr, :emissary, :session], ^ref, %{count: 1}, metadata}
      assert metadata.lifecycle == :terminated
      assert metadata.session_id == session.id
    end
  end

  describe "session expiration (PRD §4.2)" do
    test "sessions have 24h TTL by default" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      # expires_at should be ~24 hours after created_at
      expected_expiry = DateTime.add(session.created_at, 24, :hour)
      diff_seconds = DateTime.diff(session.expires_at, expected_expiry)

      # Allow 1 second tolerance for test execution time
      assert abs(diff_seconds) <= 1

      Session.terminate(session.id)
    end

    test "expired cache entry returns not_found" do
      ctx = Context.local()
      # Store with 1ms TTL to force immediate expiry
      session = %Session{
        id: "sess_test-expiry-#{:rand.uniform(100_000)}",
        context: ctx,
        capabilities: %{},
        created_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      }

      Arca.Cache.put({:session, session.id}, session, 1)
      Process.sleep(5)

      assert {:error, :not_found} = Session.get(session.id)
      refute Session.exists?(session.id)
    end

    test "non-expired session remains accessible" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      # Session should be accessible immediately
      {:ok, retrieved} = Session.get(session.id)
      assert retrieved.id == session.id

      Session.terminate(session.id)
    end
  end

  describe "edge cases" do
    test "update_capabilities on non-existent session returns error" do
      result = Session.update_capabilities("sess_nonexistent_session_id", %{"new" => "caps"})

      assert {:error, :not_found} = result
    end

    test "double terminate is idempotent" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      # First terminate should succeed
      assert :ok = Session.terminate(session.id)

      # Second terminate should also succeed (idempotent)
      assert :ok = Session.terminate(session.id)

      # Session should be gone
      assert {:error, :not_found} = Session.get(session.id)
    end

    test "get returns not_found after terminate" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      # Session exists
      assert {:ok, _} = Session.get(session.id)

      # Terminate
      Session.terminate(session.id)

      # Session no longer exists
      assert {:error, :not_found} = Session.get(session.id)
    end

    test "exists? returns false for terminated session" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx)

      assert Session.exists?(session.id)

      Session.terminate(session.id)

      refute Session.exists?(session.id)
    end

    test "create with empty capabilities" do
      ctx = Context.local()
      {:ok, session} = Session.create(ctx, %{})

      assert session.capabilities == %{}

      Session.terminate(session.id)
    end

    test "create with complex capabilities" do
      ctx = Context.local()
      caps = %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true, "listChanged" => true}
      }
      {:ok, session} = Session.create(ctx, caps)

      assert session.capabilities == caps

      Session.terminate(session.id)
    end
  end
end
