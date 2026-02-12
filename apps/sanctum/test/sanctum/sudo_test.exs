defmodule Sanctum.SudoTest do
  use ExUnit.Case, async: false

  alias Sanctum.Sudo
  alias Sanctum.Context

  setup do
    # Store original config
    original_require_sudo = Application.get_env(:sanctum, :require_sudo)
    original_sudo_secret = Application.get_env(:sanctum, :sudo_secret)

    on_exit(fn ->
      if original_require_sudo do
        Application.put_env(:sanctum, :require_sudo, original_require_sudo)
      else
        Application.delete_env(:sanctum, :require_sudo)
      end

      if original_sudo_secret do
        Application.put_env(:sanctum, :sudo_secret, original_sudo_secret)
      else
        Application.delete_env(:sanctum, :sudo_secret)
      end
    end)

    {:ok, ctx: Context.local()}
  end

  describe "verify/2" do
    test "returns :ok when credential matches configured secret", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "test-secret")

      assert :ok = Sudo.verify(ctx, "test-secret")
    end

    test "returns error when credential doesn't match", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "test-secret")

      assert {:error, "invalid sudo credential"} = Sudo.verify(ctx, "wrong-secret")
    end

    test "returns :ok when no secret is configured (dev mode)", %{ctx: ctx} do
      Application.delete_env(:sanctum, :sudo_secret)
      System.delete_env("CYFR_SUDO_SECRET")

      assert :ok = Sudo.verify(ctx, "any-credential")
    end

    test "returns error for empty credential", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "test-secret")

      assert {:error, "sudo_credential cannot be empty"} = Sudo.verify(ctx, "")
    end

    test "returns error for non-string credential", %{ctx: ctx} do
      assert {:error, "sudo_credential must be a string"} = Sudo.verify(ctx, 123)
      assert {:error, "sudo_credential must be a string"} = Sudo.verify(ctx, nil)
    end
  end

  describe "require!/3" do
    test "returns :ok when credential is valid", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "valid-secret")

      assert :ok = Sudo.require!(ctx, "valid-secret", "test.operation")
    end

    test "raises UnauthorizedError when credential is invalid", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "valid-secret")

      assert_raise Sanctum.UnauthorizedError, ~r/Sudo required for test.operation/, fn ->
        Sudo.require!(ctx, "invalid-secret", "test.operation")
      end
    end
  end

  describe "maybe_require/3" do
    test "verifies credential when provided in args", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "test-secret")
      Application.put_env(:sanctum, :require_sudo, true)

      args = %{"action" => "set", "sudo_credential" => "test-secret"}
      assert :ok = Sudo.maybe_require(ctx, args, "secret.set")
    end

    test "returns error when credential is invalid", %{ctx: ctx} do
      Application.put_env(:sanctum, :sudo_secret, "test-secret")
      Application.put_env(:sanctum, :require_sudo, true)

      args = %{"action" => "set", "sudo_credential" => "wrong-secret"}
      assert {:error, "invalid sudo credential"} = Sudo.maybe_require(ctx, args, "secret.set")
    end

    test "returns error when require_sudo is true and no credential", %{ctx: ctx} do
      Application.put_env(:sanctum, :require_sudo, true)

      args = %{"action" => "set"}
      assert {:error, "sudo_credential required for secret.set"} =
               Sudo.maybe_require(ctx, args, "secret.set")
    end

    test "allows operation when require_sudo is false (dev mode)", %{ctx: ctx} do
      Application.put_env(:sanctum, :require_sudo, false)

      args = %{"action" => "set"}
      assert :ok = Sudo.maybe_require(ctx, args, "secret.set")
    end

    test "defaults to allowing operations without sudo requirement", %{ctx: ctx} do
      Application.delete_env(:sanctum, :require_sudo)

      args = %{"action" => "set"}
      assert :ok = Sudo.maybe_require(ctx, args, "secret.set")
    end
  end

  describe "require_sudo?/0" do
    test "returns true when configured" do
      Application.put_env(:sanctum, :require_sudo, true)
      assert Sudo.require_sudo?() == true
    end

    test "returns false when configured" do
      Application.put_env(:sanctum, :require_sudo, false)
      assert Sudo.require_sudo?() == false
    end

    test "defaults to false" do
      Application.delete_env(:sanctum, :require_sudo)
      assert Sudo.require_sudo?() == false
    end
  end
end
