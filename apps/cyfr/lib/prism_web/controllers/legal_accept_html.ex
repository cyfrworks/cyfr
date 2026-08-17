# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LegalAcceptHTML do
  @moduledoc """
  The cyfr.run policy-acceptance page and its error page, in the same face
  as `/login`. Rendered by `PrismWeb.LegalAcceptController` inside the
  Prism root layout. The policies fold open one at a time with plain
  `<details>` — no script, so the browser CSP stays what it is.
  """

  use PrismWeb, :html

  embed_templates "legal_accept_html/*"

  @doc "The checkbox field name for a policy: `ack_<name-with-underscores>`."
  def ack_field(name), do: "ack_" <> String.replace(name, "-", "_")
end
