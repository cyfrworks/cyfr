# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Audit.Event do
  @moduledoc """
  The one shape an audit event has when it reaches a sink.

  `Arca.AuditHandler` builds exactly one of these per audited telemetry
  event: the name, the measurements, and the emitter's metadata sanitized
  through `Cyfr.Sanitizer` — so a credential that rides an emitter's
  metadata never reaches an operator-added SIEM sink.

  Identity fields (`user_id`, `athanor_id`, the email on a door event)
  are audit *content*, not leakage: the trail exists to say who did what,
  and they survive sanitization deliberately. Credentials do not.
  """

  @enforce_keys [:name, :measurements, :metadata]
  defstruct [:name, :measurements, :metadata, :user_id, :athanor_id]

  @type t :: %__MODULE__{
          name: [atom(), ...],
          measurements: map(),
          metadata: map(),
          user_id: String.t() | nil,
          athanor_id: String.t() | nil
        }

  @doc ~S(Dotted rendering of the event name — `"cyfr.sanctum.auth"`.)
  @spec name_string(t()) :: String.t()
  def name_string(%__MODULE__{name: name}), do: Enum.join(name, ".")
end
