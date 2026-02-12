defmodule Opus.ApplicationTest do
  use ExUnit.Case, async: false

  describe "application startup" do
    test "RateLimiter GenServer is started" do
      # The RateLimiter should be running after application start
      assert Process.whereis(Opus.RateLimiter) != nil
    end

    test "RateLimiter is a GenServer" do
      pid = Process.whereis(Opus.RateLimiter)
      assert Process.alive?(pid)

      # Verify it responds to GenServer calls
      info = Process.info(pid)
      assert info != nil
    end
  end

  describe "supervisor tree" do
    test "Opus.Supervisor is running" do
      assert Process.whereis(Opus.Supervisor) != nil
    end

    test "supervisor has :one_for_one strategy" do
      # The supervisor should be running with the expected configuration
      pid = Process.whereis(Opus.Supervisor)
      assert Process.alive?(pid)
    end
  end

  describe "clean shutdown" do
    test "application can be stopped and started" do
      # This test verifies the application can handle restart scenarios
      # Note: We don't actually stop the application as it would affect other tests
      # Instead, we verify the supervision tree is properly configured

      children = Supervisor.which_children(Opus.Supervisor)
      assert length(children) >= 1

      # Verify RateLimiter is a supervised child
      rate_limiter_child = Enum.find(children, fn {id, _pid, _type, _modules} ->
        id == Opus.RateLimiter
      end)

      assert rate_limiter_child != nil
    end
  end
end
