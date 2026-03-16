defmodule Cyfr.OtelTenantHandlerTest do
  use ExUnit.Case, async: true

  alias Cyfr.OtelTenantHandler

  describe "attach/0" do
    test "does not crash when OpenTelemetry is not loaded" do
      # OpenTelemetry is typically not loaded in test
      assert :ok == OtelTenantHandler.attach()
    end
  end

  describe "handle_event/4" do
    test "tolerates missing conn in metadata" do
      assert is_nil(OtelTenantHandler.handle_event([:test], %{}, %{}, %{}))
    end

    test "tolerates conn without context assigns" do
      conn = %Plug.Conn{assigns: %{}}
      assert is_nil(OtelTenantHandler.handle_event([:test], %{}, %{conn: conn}, %{}))
    end
  end
end
