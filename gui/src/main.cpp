#include "mainwindow.h"

#include <QApplication>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QDialog>
#include <QIcon>
#include <QInputDialog>
#include <QLineEdit>
#include <QStyle>
#include <QTextStream>
#include <QTimer>

#include <cstring>

namespace {
int runAskpass(int argc, char **argv, int optionIndex)
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("maid-au-askpass"));

    QInputDialog dialog;
    dialog.setWindowTitle(QStringLiteral("Maid AU - administrator password"));
    dialog.setInputMode(QInputDialog::TextInput);
    dialog.setTextEchoMode(QLineEdit::Password);
    dialog.setLabelText(optionIndex + 1 < argc
                            ? QString::fromLocal8Bit(argv[optionIndex + 1])
                            : QStringLiteral("Password:"));
    dialog.setWindowFlag(Qt::WindowStaysOnTopHint);
    dialog.show();
    dialog.raise();
    dialog.activateWindow();

    if (dialog.exec() != QDialog::Accepted)
        return 1;

    QTextStream out(stdout);
    out << dialog.textValue() << Qt::endl;
    return 0;
}

QIcon appIcon()
{
    QIcon icon = QIcon::fromTheme(QStringLiteral("software-update-available"));
    if (icon.isNull())
        icon = QIcon::fromTheme(QStringLiteral("system-software-update"));
    if (icon.isNull())
        icon = QApplication::style()->standardIcon(QStyle::SP_ComputerIcon);
    return icon;
}
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--askpass") == 0)
            return runAskpass(argc, argv, i);
    }

    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("maid-au"));
    QApplication::setApplicationDisplayName(QStringLiteral("Maid AU"));
    QApplication::setOrganizationName(QStringLiteral("Maidware"));
    QApplication::setApplicationVersion(QStringLiteral(MAID_AU_VERSION));
    QApplication::setDesktopFileName(QStringLiteral("maid-au"));

    const QIcon icon = appIcon();
    QApplication::setWindowIcon(icon);

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("One updater for everything on Linux."));
    parser.addHelpOption();
    parser.addVersionOption();

    const QCommandLineOption checkOption(
        QStringLiteral("check"),
        QStringLiteral("Start a package check immediately."));
    const QCommandLineOption updateOption(
        QStringLiteral("update"),
        QStringLiteral("Start an update immediately."));
    const QCommandLineOption trayOption(
        QStringLiteral("tray"),
        QStringLiteral("Start minimized to the system tray."));
    const QCommandLineOption quitAfterCheckOption(
        QStringLiteral("quit-after-check"),
        QStringLiteral("Exit after the automatic check finishes (for testing)."));
    const QCommandLineOption screenshotOption(
        QStringLiteral("screenshot"),
        QStringLiteral("Save a window screenshot and exit (testing)."),
        QStringLiteral("file"));
    const QCommandLineOption maidwareOption(
        QStringLiteral("maidware"),
        QStringLiteral("Use the Maidware dark theme for this run."));
    parser.addOption(checkOption);
    parser.addOption(updateOption);
    parser.addOption(trayOption);
    parser.addOption(quitAfterCheckOption);
    parser.addOption(screenshotOption);
    parser.addOption(maidwareOption);
    parser.process(app);

    if (parser.isSet(maidwareOption) || parser.isSet(screenshotOption)
        || qEnvironmentVariableIsSet("MAIDWARE_THEME"))
        applyMaidwareTheme(&app);

    MainWindow window(icon);
    window.setScreenshotMode(parser.isSet(screenshotOption));
    window.setQuitAfterCheck(parser.isSet(quitAfterCheckOption));

    if (!parser.isSet(trayOption) || parser.isSet(screenshotOption))
        window.show();
    else if (window.trayAvailable())
        window.showTrayMessage(QStringLiteral("Maid AU"),
                               QStringLiteral("Maid AU is running in the tray."));

    if (parser.isSet(checkOption))
        QTimer::singleShot(0, &window, &MainWindow::startCheck);
    else if (parser.isSet(updateOption))
        QTimer::singleShot(0, &window, &MainWindow::startUpdate);

    if (parser.isSet(screenshotOption)) {
        const QString path = parser.value(screenshotOption);
        QTimer::singleShot(1500, &window, [&window, path] {
            window.grab().save(path);
            QApplication::quit();
        });
    }

    return app.exec();
}
