# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The validator `Prima.Wasm` checks components with, as the applications
# that admit or compile components install it when they start.
:ok = Prima.ComponentFeatures.install!()

ExUnit.start()
