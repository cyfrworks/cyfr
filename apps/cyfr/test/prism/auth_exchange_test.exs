defmodule Prism.AuthExchangeTest do
  use ExUnit.Case, async: true

  alias Prism.AuthExchange

  describe "create/1 and redeem/1" do
    test "round-trips a token" do
      token = "test_session_token_abc123"
      code = AuthExchange.create(token)

      assert is_binary(code)
      assert code != token
      assert {:ok, ^token} = AuthExchange.redeem(code)
    end

    test "rejects an invalid code" do
      assert :error = AuthExchange.redeem("totally_bogus_code")
    end

    test "rejects a tampered code" do
      code = AuthExchange.create("real_token")
      tampered = code <> "x"
      assert :error = AuthExchange.redeem(tampered)
    end
  end
end
