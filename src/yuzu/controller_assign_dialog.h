// SPDX-FileCopyrightText: Copyright 2026 Fritchii Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <cstddef>
#include <string>

#include <QDialog>
#include <QTimer>

#include "common/param_package.h"

class QComboBox;

namespace InputCommon {
class InputSubsystem;
}

/// Opened with L + R + Start: picks the player slot and profile for the controller that pressed
/// it. That controller drives the window (D-pad, A to confirm, B to cancel).
class ControllerAssignDialog : public QDialog {
public:
    explicit ControllerAssignDialog(InputCommon::InputSubsystem& input_subsystem,
                                    Common::ParamPackage device, QWidget* parent = nullptr);
    ~ControllerAssignDialog() override;

    std::size_t SelectedPlayer() const;
    std::string SelectedProfile() const;

private:
    void PollController();
    void FocusRow(int row);

    InputCommon::InputSubsystem& input_subsystem;
    Common::ParamPackage device;
    QComboBox* player_box{};
    QComboBox* profile_box{};
    QTimer poll_timer;
    int focused_row{};
};
