# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Webhook do
  @moduledoc """
  The webhook wire shape this server agrees on with its callers.

  So far that is one name: the header an inbound webhook carries its HMAC
  signature in when the endpoint does not name another. It is a wire
  detail three sides read — the endpoint that verifies a signature, the
  row store that stamps the default onto a new endpoint, and the console
  that tells a person what to send — so it is declared once here.

  The secret, the digest and the grace window are not here: those are the
  identity domain's decisions, not a shape.
  """

  @default_signature_header "x-cyfr-signature"

  @doc "The header an inbound webhook's HMAC signature rides in by default."
  @spec default_signature_header() :: String.t()
  def default_signature_header, do: @default_signature_header
end
