// SPDX-FileCopyrightText: Copyright 2026 Fritchii Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <string>
#include <vector>

namespace InputCommon {

class InputSubsystem;

/**
 * Automatically assigns connected game controllers (SDL devices) to player slots.
 *
 * Behaviour (only when Settings::values.auto_assign_controllers is enabled):
 *  - A player slot whose bindings already point at a connected controller keeps it, so
 *    controllers never jump between players while playing.
 *  - Every connected controller that is not bound to any slot is given the first free slot
 *    (up to auto_assign_max_players). Its bindings are taken from the input profile named in
 *    auto_assign_profile (re-targeted to the new controller), or, when no profile is set or it
 *    can't be read, from SDL's gamepad database (positional Xbox -> Switch layout).
 *  - Slots 2..N whose controller went away are disconnected, so games don't see ghost players.
 *    Their bindings are kept so the same controller resumes the slot when it reconnects.
 *
 * Only Settings::values.players is modified. The caller must reload the emulated controllers
 * (HIDCore::ReloadInputDevices) when this returns true.
 *
 * @returns true when any player configuration was changed.
 */
bool AutoAssignControllers(const InputSubsystem& input_subsystem);

/// Returns the names of the input profiles stored in <config>/input/*.ini.
std::vector<std::string> GetAutoAssignProfileNames();

} // namespace InputCommon
