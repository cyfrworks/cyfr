# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ClaimNamespaceHTML do
  @moduledoc """
  The claim-namespace page: one form, in the same face as `/login`. Rendered
  by `PrismWeb.ClaimNamespaceController` inside the Prism root layout.
  """

  use PrismWeb, :html

  embed_templates "claim_namespace_html/*"
end
