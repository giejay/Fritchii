// SPDX-FileCopyrightText: Copyright 2026 Fritchii Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include <QComboBox>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QLabel>
#include <QVBoxLayout>

#include "common/settings.h"
#include "input_common/helpers/auto_assign.h"
#include "input_common/main.h"
#include "yuzu/controller_assign_dialog.h"

ControllerAssignDialog::ControllerAssignDialog(InputCommon::InputSubsystem& input_subsystem_,
                                               Common::ParamPackage device_, QWidget* parent)
    : QDialog(parent), input_subsystem{input_subsystem_}, device{std::move(device_)} {
    setWindowTitle(tr("Assign controller"));
    setWindowFlags(windowFlags() & ~Qt::WindowContextHelpButtonHint);

    auto* title = new QLabel(QString::fromStdString(device.Get("display", "Controller")));
    QFont title_font = title->font();
    title_font.setPointSizeF(title_font.pointSizeF() * 1.4);
    title_font.setBold(true);
    title->setFont(title_font);

    player_box = new QComboBox;
    for (std::size_t i = 0; i < 8; ++i) {
        const auto current = InputCommon::GetPlayerControllerName(input_subsystem, i);
        QString text = tr("Player %1").arg(i + 1);
        if (!current.empty()) {
            text += QStringLiteral("  (%1)").arg(QString::fromStdString(current));
        }
        player_box->addItem(text);
    }
    const auto current_player = InputCommon::FindPlayerForDevice(device);
    player_box->setCurrentIndex(current_player ? static_cast<int>(*current_player) : 0);

    profile_box = new QComboBox;
    profile_box->addItem(tr("Automatic (standard gamepad layout)"), QString{});
    for (const auto& name : InputCommon::GetAutoAssignProfileNames()) {
        const auto qname = QString::fromStdString(name);
        profile_box->addItem(qname, qname);
    }
    const auto default_profile =
        QString::fromStdString(Settings::values.auto_assign_profile.GetValue());
    const int profile_index = profile_box->findData(default_profile);
    profile_box->setCurrentIndex(profile_index >= 0 ? profile_index : 0);

    auto* form = new QFormLayout;
    form->addRow(tr("Player:"), player_box);
    form->addRow(tr("Profile:"), profile_box);

    auto* hint = new QLabel(tr("D-pad: choose   A: confirm   B: cancel"));
    hint->setAlignment(Qt::AlignCenter);

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    connect(buttons, &QDialogButtonBox::accepted, this, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);

    auto* layout = new QVBoxLayout(this);
    layout->addWidget(title);
    layout->addLayout(form);
    layout->addWidget(hint);
    layout->addWidget(buttons);
    setMinimumWidth(420);

    input_subsystem.SetMenuDevice(device);
    connect(&poll_timer, &QTimer::timeout, this, [this] { PollController(); });
    poll_timer.start(16);
    FocusRow(0);
}

ControllerAssignDialog::~ControllerAssignDialog() {
    poll_timer.stop();
    input_subsystem.SetMenuDevice(std::nullopt);
}

std::size_t ControllerAssignDialog::SelectedPlayer() const {
    return static_cast<std::size_t>(player_box->currentIndex());
}

std::string ControllerAssignDialog::SelectedProfile() const {
    return profile_box->currentData().toString().toStdString();
}

void ControllerAssignDialog::FocusRow(int row) {
    focused_row = row;
    (row == 0 ? player_box : profile_box)->setFocus();
}

void ControllerAssignDialog::PollController() {
    for (const auto button : input_subsystem.TakeMenuButtons()) {
        QComboBox* box = focused_row == 0 ? player_box : profile_box;
        const int count = box->count();
        switch (button) {
        case InputCommon::MenuButton::Up:
        case InputCommon::MenuButton::Down:
            FocusRow(focused_row == 0 ? 1 : 0);
            break;
        case InputCommon::MenuButton::Left:
            box->setCurrentIndex((box->currentIndex() + count - 1) % count);
            break;
        case InputCommon::MenuButton::Right:
            box->setCurrentIndex((box->currentIndex() + 1) % count);
            break;
        case InputCommon::MenuButton::Accept:
            accept();
            return;
        case InputCommon::MenuButton::Back:
            reject();
            return;
        }
    }
}
