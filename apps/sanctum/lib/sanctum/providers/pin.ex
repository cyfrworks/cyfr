# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Pin do
  @moduledoc """
  The `pin` tool: a six-digit PIN this home evaluates for a remote software
  device of yours (`Sanctum.DevicePin`).

    * `enroll` gives the calling device a new evaluator, or a replacement,
      under a fresh `device_pin` confirmation given on this device or
      another of yours, and answers `evaluator`, the identifier the device
      keeps to reach evaluation while it is locked. It takes no arguments:
      the device is the one the call's own credential names, its device
      channel's client or the client its unlocked session was issued to.

  The evaluation itself and its reset are no operation: a locked device
  holds no session, so it reaches them at `POST /device/pin/evaluate` and
  `POST /device/pin/reset` (`Emissary.Web.DevicePinController`).
  """

  alias Prima.Operation
  alias Sanctum.Context

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        Operation.new(
          "pin",
          "enroll",
          "Give this device a PIN this CYFR evaluates",
          [],
          kind: :write,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "A six-digit PIN for a device of yours without a chip, which this CYFR evaluates and counts so a copy of the device's disk cannot guess it offline: enroll this device, or replace its PIN.",
      title: "Device PIN"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "enroll"} = args) when map_size(args) == 1 do
    case Sanctum.DevicePin.enroll(ctx) do
      {:ok, %{evaluator: evaluator}} -> {:ok, %{evaluator: evaluator}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def handle(_ctx, %{"action" => "enroll"}),
    do: {:error, {:invalid_argument, "enroll takes no arguments"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "pin.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  defp refusal(:not_a_device),
    do:
      refused(
        :forbidden,
        :not_a_device,
        "Only a protected device itself, unlocked, gives itself a PIN"
      )

  defp refusal(:not_software),
    do:
      refused(
        :forbidden,
        :not_software,
        "This device keeps its key in its chip, which counts wrong PINs itself"
      )

  defp refusal(:not_standing),
    do: refused(:forbidden, :not_standing, "This device's pairing no longer stands here")

  defp refusal(reason), do: reason

  defp refused(class, reason, message),
    do: %Prima.Refusal{class: class, reason: reason, message: message}
end
