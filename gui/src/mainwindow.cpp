#include "mainwindow.h"

#include <QAction>
#include <QApplication>
#include <QCloseEvent>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFontDatabase>
#include <QFrame>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QIcon>
#include <QLabel>
#include <QLocale>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QKeySequence>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QScrollBar>
#include <QStandardPaths>
#include <QStatusBar>
#include <QStyle>
#include <QSysInfo>
#include <QSystemTrayIcon>
#include <QTextCursor>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

namespace {
constexpr int kStatusIconSize = 40;

QString cleanPath(const QString &path)
{
    if (path.isEmpty())
        return QString();
    const QFileInfo info(path);
    const QString canonical = info.canonicalFilePath();
    return canonical.isEmpty() ? info.absoluteFilePath() : canonical;
}
}

MainWindow::MainWindow(const QIcon &icon, QWidget *parent)
    : QMainWindow(parent)
    , m_settings()
{
    setWindowTitle(QStringLiteral("Maid AU"));
    setWindowIcon(icon);

    findTools();
    ensureAskpass();
    buildUi(icon);
    buildMenus();
    buildTray(icon);
    loadLastUpdate();

    if (m_updateScript.isEmpty()) {
        setStatus(QStringLiteral("Updater not found"),
                  QStringLiteral("update-all.sh was not found next to this app or in ~/.local/bin. Run install.sh first."),
                  QStringLiteral("dialog-error"));
    }

    if (m_settings.contains(QStringLiteral("window/geometry")))
        restoreGeometry(m_settings.value(QStringLiteral("window/geometry")).toByteArray());
    m_closeToTrayTipShown = m_settings.value(QStringLiteral("tray/tipShown"), false).toBool();
}

MainWindow::~MainWindow()
{
    m_settings.setValue(QStringLiteral("window/geometry"), saveGeometry());
    m_settings.sync();
}

bool MainWindow::trayAvailable() const
{
    return m_tray != nullptr;
}

void MainWindow::setQuitAfterCheck(bool enabled)
{
    m_quitAfterCheck = enabled;
}

void MainWindow::showTrayMessage(const QString &title, const QString &message)
{
    if (m_tray)
        m_tray->showMessage(title, message, QSystemTrayIcon::Information, 3500);
}

void MainWindow::findTools()
{
    const auto find = [this](const QString &name, const QString &envName) {
        const QString override = qEnvironmentVariable(envName.toUtf8().constData());
        if (!override.isEmpty() && QFileInfo(override).isExecutable())
            return cleanPath(override);

        const QString appDir = QCoreApplication::applicationDirPath();
        const QStringList candidates = {
            appDir + QLatin1Char('/') + name,
            QDir(appDir).filePath(QStringLiteral("../bin/") + name),
            QDir(appDir).filePath(QStringLiteral("../../bin/") + name),
            QDir::homePath() + QStringLiteral("/.local/bin/") + name,
        };
        for (const QString &candidate : candidates) {
            if (QFileInfo(candidate).isExecutable())
                return cleanPath(candidate);
        }
        return cleanPath(QStandardPaths::findExecutable(name));
    };

    m_updateScript = find(QStringLiteral("update-all.sh"),
                          QStringLiteral("MAID_AU_UPDATE_SCRIPT"));

    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    m_logPath = qEnvironmentVariable("MAID_AU_LOG");
    if (m_logPath.isEmpty())
        m_logPath = dataDir + QStringLiteral("/update-all.log");
    m_lastPath = dataDir + QStringLiteral("/update-all.last");
}

bool MainWindow::ensureAskpass()
{
    QString helper = QStandardPaths::findExecutable(QStringLiteral("ksshaskpass"));
    if (helper.isEmpty())
        helper = QStandardPaths::findExecutable(QStringLiteral("ssh-askpass"));

    if (!helper.isEmpty()) {
        m_askpassPath = helper;
        return true;
    }

    // No system askpass: use this binary's small QInputDialog mode. sudo
    // needs a plain executable path, so wrap the --askpass argument in a
    // private script.
    const QString cacheDir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (!QDir().mkpath(cacheDir))
        return false;

    const QString wrapper = cacheDir + QStringLiteral("/askpass.sh");
    QFile file(wrapper);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;

    QString program = QCoreApplication::applicationFilePath();
    program.replace(QLatin1Char('\\'), QStringLiteral("\\\\"));
    program.replace(QLatin1Char('"'), QStringLiteral("\\\""));
    file.write("#!/bin/sh\nexec \"" + program.toUtf8() + "\" --askpass \"$@\"\n");
    file.close();
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner
                        | QFileDevice::ExeOwner);

    m_askpassPath = wrapper;
    return true;
}

void MainWindow::buildUi(const QIcon &icon)
{
    Q_UNUSED(icon)

    auto *central = new QWidget(this);
    setCentralWidget(central);

    auto *outer = new QVBoxLayout(central);
    outer->setContentsMargins(24, 22, 24, 18);
    outer->setSpacing(14);

    auto *title = new QLabel(QStringLiteral("Maid AU"), central);
    QFont titleFont = title->font();
    titleFont.setPointSize(titleFont.pointSize() + 10);
    titleFont.setBold(true);
    title->setFont(titleFont);

    auto *subtitle = new QLabel(
        QStringLiteral("One updater for everything on Linux: native packages, Flatpak, firmware, controllers, AppImages, and the Maid suite."),
        central);
    subtitle->setWordWrap(true);
    subtitle->setForegroundRole(QPalette::PlaceholderText);

    outer->addWidget(title);
    outer->addWidget(subtitle);

    auto *card = new QFrame(central);
    card->setObjectName(QStringLiteral("statusCard"));
    card->setFrameShape(QFrame::StyledPanel);
    auto *cardLayout = new QHBoxLayout(card);
    cardLayout->setContentsMargins(18, 16, 18, 16);
    cardLayout->setSpacing(16);

    m_statusIcon = new QLabel(card);
    m_statusIcon->setFixedSize(kStatusIconSize, kStatusIconSize);
    m_statusIcon->setAlignment(Qt::AlignTop | Qt::AlignHCenter);
    cardLayout->addWidget(m_statusIcon);

    auto *textColumn = new QVBoxLayout;
    textColumn->setSpacing(4);
    m_statusTitle = new QLabel(card);
    QFont statusFont = m_statusTitle->font();
    statusFont.setPointSize(statusFont.pointSize() + 5);
    statusFont.setBold(true);
    m_statusTitle->setFont(statusFont);
    m_statusDetail = new QLabel(card);
    m_statusDetail->setWordWrap(true);
    m_lastUpdate = new QLabel(card);
    m_lastUpdate->setWordWrap(true);
    m_lastUpdate->setForegroundRole(QPalette::PlaceholderText);

    textColumn->addWidget(m_statusTitle);
    textColumn->addWidget(m_statusDetail);
    textColumn->addSpacing(4);
    textColumn->addWidget(m_lastUpdate);
    cardLayout->addLayout(textColumn, 1);

    outer->addWidget(card);

    auto *buttons = new QHBoxLayout;
    buttons->setSpacing(8);

    m_checkButton = new QPushButton(QIcon::fromTheme(QStringLiteral("view-refresh")),
                                   QStringLiteral("Check for updates"), central);
    m_checkButton->setDefault(true);
    m_updateButton = new QPushButton(QIcon::fromTheme(QStringLiteral("system-software-update")),
                                     QStringLiteral("Update now"), central);
    m_cancelButton = new QPushButton(QStringLiteral("Cancel"), central);
    m_logButton = new QPushButton(QIcon::fromTheme(QStringLiteral("text-x-generic")),
                                  QStringLiteral("Open log"), central);
    m_cancelButton->setVisible(false);

    buttons->addWidget(m_checkButton);
    buttons->addWidget(m_updateButton);
    buttons->addWidget(m_cancelButton);
    buttons->addStretch(1);
    buttons->addWidget(m_logButton);
    outer->addLayout(buttons);

    m_progress = new QProgressBar(central);
    m_progress->setRange(0, 0);
    m_progress->setTextVisible(false);
    m_progress->setVisible(false);
    outer->addWidget(m_progress);

    auto *details = new QGroupBox(QStringLiteral("Check details"), central);
    auto *detailsLayout = new QVBoxLayout(details);
    detailsLayout->setContentsMargins(10, 12, 10, 10);
    m_output = new QPlainTextEdit(details);
    m_output->setReadOnly(true);
    m_output->setLineWrapMode(QPlainTextEdit::NoWrap);
    m_output->setMaximumBlockCount(6000);
    m_output->setMinimumHeight(210);
    m_output->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
    m_output->setPlaceholderText(QStringLiteral("Run a check to see its output here. Nothing is changed by a check."));
    detailsLayout->addWidget(m_output);
    outer->addWidget(details, 1);

    auto *footer = new QHBoxLayout;
    m_systemInfo = new QLabel(QSysInfo::prettyProductName(), central);
    m_systemInfo->setForegroundRole(QPalette::PlaceholderText);
    m_footer = new QLabel(central);
    m_footer->setTextFormat(Qt::PlainText);
    m_footer->setTextInteractionFlags(Qt::TextSelectableByMouse);
    m_footer->setForegroundRole(QPalette::PlaceholderText);
    m_footer->setText(QStringLiteral("Log: ") + m_logPath);
    m_footer->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    m_footer->setTextInteractionFlags(Qt::TextSelectableByMouse);
    footer->addWidget(m_systemInfo);
    footer->addStretch(1);
    footer->addWidget(m_footer);
    outer->addLayout(footer);

    connect(m_checkButton, &QPushButton::clicked, this, &MainWindow::startCheck);
    connect(m_updateButton, &QPushButton::clicked, this, &MainWindow::startUpdate);
    connect(m_cancelButton, &QPushButton::clicked, this, &MainWindow::cancelCheck);
    connect(m_logButton, &QPushButton::clicked, this, &MainWindow::openLog);

    setStatus(QStringLiteral("Ready to check"),
              QStringLiteral("Preview what would update. A check changes nothing and is safe to run any time."),
              QStringLiteral("dialog-information"));

    resize(840, 660);
    setMinimumSize(680, 520);
}

void MainWindow::buildMenus()
{
    auto *fileMenu = menuBar()->addMenu(QStringLiteral("&File"));

    m_menuCheckAction = fileMenu->addAction(QIcon::fromTheme(QStringLiteral("view-refresh")),
                                            QStringLiteral("&Check for updates"));
    m_menuCheckAction->setShortcut(QKeySequence(QStringLiteral("Ctrl+R")));
    connect(m_menuCheckAction, &QAction::triggered, this, &MainWindow::startCheck);

    m_menuUpdateAction = fileMenu->addAction(QIcon::fromTheme(QStringLiteral("system-software-update")),
                                             QStringLiteral("&Update now"));
    m_menuUpdateAction->setShortcut(QKeySequence(QStringLiteral("Ctrl+U")));
    connect(m_menuUpdateAction, &QAction::triggered, this, &MainWindow::startUpdate);

    m_menuLogAction = fileMenu->addAction(QIcon::fromTheme(QStringLiteral("text-x-generic")),
                                          QStringLiteral("Open &log"));
    m_menuLogAction->setShortcut(QKeySequence(QStringLiteral("Ctrl+L")));
    connect(m_menuLogAction, &QAction::triggered, this, &MainWindow::openLog);

    fileMenu->addSeparator();
    auto *quitAction = fileMenu->addAction(QStringLiteral("&Quit"));
    quitAction->setShortcut(QKeySequence::Quit);
    connect(quitAction, &QAction::triggered, qApp, &QApplication::quit);

    auto *helpMenu = menuBar()->addMenu(QStringLiteral("&Help"));
    auto *aboutAction = helpMenu->addAction(QStringLiteral("&About Maid AU"));
    connect(aboutAction, &QAction::triggered, this, &MainWindow::showAbout);
}

void MainWindow::buildTray(const QIcon &icon)
{
    if (!QSystemTrayIcon::isSystemTrayAvailable())
        return;

    m_tray = new QSystemTrayIcon(icon, this);
    m_tray->setToolTip(QStringLiteral("Maid AU - system updater"));

    auto *menu = new QMenu(this);
    m_trayShowAction = menu->addAction(QStringLiteral("Show Maid AU"));
    connect(m_trayShowAction, &QAction::triggered, this, [this] {
        showNormal();
        raise();
        activateWindow();
    });

    menu->addSeparator();
    m_trayCheckAction = menu->addAction(QIcon::fromTheme(QStringLiteral("view-refresh")),
                                        QStringLiteral("Check for updates"));
    connect(m_trayCheckAction, &QAction::triggered, this, &MainWindow::startCheck);
    m_trayUpdateAction = menu->addAction(QIcon::fromTheme(QStringLiteral("system-software-update")),
                                         QStringLiteral("Update now"));
    connect(m_trayUpdateAction, &QAction::triggered, this, &MainWindow::startUpdate);

    menu->addSeparator();
    auto *logAction = menu->addAction(QStringLiteral("Open log"));
    connect(logAction, &QAction::triggered, this, &MainWindow::openLog);
    menu->addSeparator();
    m_trayQuitAction = menu->addAction(QStringLiteral("Quit"));
    connect(m_trayQuitAction, &QAction::triggered, qApp, &QApplication::quit);

    m_tray->setContextMenu(menu);
    connect(m_tray, &QSystemTrayIcon::activated,
            this, &MainWindow::trayActivated);
    m_tray->show();

    QApplication::setQuitOnLastWindowClosed(false);
}

void MainWindow::trayActivated(QSystemTrayIcon::ActivationReason reason)
{
    if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
        showNormal();
        raise();
        activateWindow();
    }
}

void MainWindow::loadLastUpdate()
{
    QFile file(m_lastPath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        m_lastUpdate->setText(QStringLiteral("No successful update recorded yet."));
        return;
    }

    bool ok = false;
    const qint64 epoch = QString::fromLocal8Bit(file.readLine()).trimmed().toLongLong(&ok);
    if (!ok || epoch <= 0) {
        m_lastUpdate->setText(QStringLiteral("No successful update recorded yet."));
        return;
    }

    const QDateTime when = QDateTime::fromSecsSinceEpoch(epoch);
    const qint64 ageDays = when.date().daysTo(QDate::currentDate());
    QString text = QStringLiteral("Last successful update: ")
        + QLocale().toString(when, QLocale::ShortFormat);
    if (ageDays >= 1)
        text += QStringLiteral(" (%1 day%2 ago)").arg(ageDays).arg(ageDays == 1 ? QString() : QStringLiteral("s"));
    if (ageDays > 3)
        text += QStringLiteral(" - consider updating.");
    m_lastUpdate->setText(text);
}

void MainWindow::setStatus(const QString &title, const QString &detail, const QString &iconName)
{
    m_statusTitle->setText(title);
    m_statusDetail->setText(detail);

    QIcon icon = QIcon::fromTheme(iconName);
    if (icon.isNull()) {
        QStyle::StandardPixmap fallback = QStyle::SP_MessageBoxInformation;
        if (iconName.contains(QStringLiteral("error")))
            fallback = QStyle::SP_MessageBoxCritical;
        else if (iconName.contains(QStringLiteral("update")))
            fallback = QStyle::SP_ComputerIcon;
        else if (iconName.contains(QStringLiteral("emblem-default")))
            fallback = QStyle::SP_DialogApplyButton;
        icon = QApplication::style()->standardIcon(fallback);
    }
    m_statusIcon->setPixmap(icon.pixmap(QSize(kStatusIconSize, kStatusIconSize)));
}

void MainWindow::setChecking(bool checking)
{
    m_checkButton->setEnabled(!checking);
    m_updateButton->setEnabled(!checking);
    m_cancelButton->setVisible(checking);
    m_progress->setVisible(checking);
    if (m_menuCheckAction)
        m_menuCheckAction->setEnabled(!checking);
    if (m_menuUpdateAction)
        m_menuUpdateAction->setEnabled(!checking);
    if (m_trayCheckAction)
        m_trayCheckAction->setEnabled(!checking);
    if (m_trayUpdateAction)
        m_trayUpdateAction->setEnabled(!checking);
    statusBar()->showMessage(checking ? QStringLiteral("Checking...") : QStringLiteral("Ready"));
}

void MainWindow::appendOutput(const QString &text)
{
    if (text.isEmpty())
        return;
    QTextCursor cursor(m_output->document());
    cursor.movePosition(QTextCursor::End);
    cursor.insertText(text);
    m_output->verticalScrollBar()->setValue(m_output->verticalScrollBar()->maximum());
}

void MainWindow::startCheck()
{
    if (m_check)
        return;

    if (m_updateScript.isEmpty()) {
        showError(QStringLiteral("Updater not found"),
                  QStringLiteral("update-all.sh was not found next to this app or in ~/.local/bin. Run install.sh first."));
        if (m_quitAfterCheck)
            QTimer::singleShot(0, qApp, &QApplication::quit);
        return;
    }

    m_checkCancelled = false;
    m_checkBuffer.clear();
    m_output->clear();
    appendOutput(QStringLiteral("Running: %1 --check\n\n").arg(m_updateScript));
    setChecking(true);
    setStatus(QStringLiteral("Checking for updates..."),
              QStringLiteral("Reading native packages, Flatpak, firmware, controllers, AppImages, and the Maid suite. This can take a minute."),
              QStringLiteral("view-refresh"));

    m_check = new QProcess(this);
    m_check->setProcessChannelMode(QProcess::MergedChannels);
    m_check->setWorkingDirectory(QDir::homePath());

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("UPDATE_NO_NOTIFY"), QStringLiteral("1"));
    m_check->setProcessEnvironment(env);

    connect(m_check, &QProcess::readyReadStandardOutput,
            this, &MainWindow::readCheckOutput);
    connect(m_check, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &MainWindow::checkFinished);
    connect(m_check, &QProcess::errorOccurred,
            this, &MainWindow::checkFailed);

    m_check->start(m_updateScript, QStringList{QStringLiteral("--check")});
    m_check->closeWriteChannel();
}

void MainWindow::readCheckOutput()
{
    if (!m_check)
        return;
    const QByteArray chunk = m_check->readAllStandardOutput();
    if (chunk.isEmpty())
        return;
    m_checkBuffer += chunk;
    appendOutput(QString::fromLocal8Bit(chunk));
}

void MainWindow::cancelCheck()
{
    if (!m_check || m_check->state() == QProcess::NotRunning)
        return;

    m_checkCancelled = true;
    m_cancelButton->setEnabled(false);
    statusBar()->showMessage(QStringLiteral("Stopping the check..."));
    m_check->terminate();
    QTimer::singleShot(1500, this, [this] {
        if (m_check && m_check->state() != QProcess::NotRunning)
            m_check->kill();
    });
}

void MainWindow::checkFinished(int exitCode, QProcess::ExitStatus status)
{
    if (!m_check)
        return;

    const QByteArray tail = m_check->readAllStandardOutput();
    if (!tail.isEmpty()) {
        m_checkBuffer += tail;
        appendOutput(QString::fromLocal8Bit(tail));
    }

    m_check->deleteLater();
    m_check = nullptr;
    m_cancelButton->setEnabled(true);
    setChecking(false);
    loadLastUpdate();

    if (m_checkCancelled) {
        setStatus(QStringLiteral("Check cancelled"),
                  QStringLiteral("Nothing was changed. Run the check again when you are ready."),
                  QStringLiteral("dialog-information"));
        appendOutput(QStringLiteral("\n[check cancelled]\n"));
    } else {
        parseCheckResult(exitCode, status == QProcess::NormalExit);
    }

    if (m_quitAfterCheck)
        QTimer::singleShot(0, qApp, &QApplication::quit);
}

void MainWindow::checkFailed(QProcess::ProcessError error)
{
    if (!m_check)
        return;

    if (error == QProcess::FailedToStart) {
        const QString message = QStringLiteral("Could not start %1. Check that it is executable.")
                                    .arg(m_updateScript);
        m_check->deleteLater();
        m_check = nullptr;
        setChecking(false);
        appendOutput(message + QLatin1Char('\n'));
        setStatus(QStringLiteral("Check failed"), message, QStringLiteral("dialog-error"));
        showError(QStringLiteral("Check failed"), message);
        if (m_quitAfterCheck)
            QTimer::singleShot(0, qApp, &QApplication::quit);
    }
}

void MainWindow::parseCheckResult(int exitCode, bool normalExit)
{
    const QString output = QString::fromLocal8Bit(m_checkBuffer);
    const QRegularExpression summary(
        QStringLiteral("=== check done \\(([A-Za-z0-9_-]+)=(\\d+)"
                       " extra=(\\d+) flatpak=(\\d+) firmware=(\\d+)"
                       " controllers=(\\d+) appimg=(\\d+) maid=(\\d+)"
                       " system=(\\d+) failed=(\\d+)\\) ==="));
    const QRegularExpressionMatch match = summary.match(output);

    if (!normalExit) {
        setStatus(QStringLiteral("Check failed"),
                  QStringLiteral("The check process did not finish normally. See the details below."),
                  QStringLiteral("dialog-error"));
        QApplication::alert(this);
        return;
    }

    if (!match.hasMatch()) {
        if (output.contains(QStringLiteral("System up to date.")) && exitCode == 0) {
            setStatus(QStringLiteral("System up to date"),
                      QStringLiteral("Nothing to install right now."),
                      QStringLiteral("emblem-default"));
        } else if (output.contains(QStringLiteral("Check failed")) || exitCode != 0) {
            setStatus(QStringLiteral("Check failed"),
                      QStringLiteral("The package manager could not complete the preview. See the details below."),
                      QStringLiteral("dialog-error"));
            QApplication::alert(this);
        } else {
            setStatus(QStringLiteral("Check finished"),
                      QStringLiteral("See the details below for the result."),
                      QStringLiteral("dialog-information"));
        }
        if (m_tray && !isVisible())
            showTrayMessage(m_statusTitle->text(), m_statusDetail->text());
        return;
    }

    const QString pmName = match.captured(1);
    const int packages = match.captured(2).toInt();
    const int extra = match.captured(3).toInt();
    const int flatpak = match.captured(4).toInt();
    const int firmware = match.captured(5).toInt();
    const int controllers = match.captured(6).toInt();
    const int appimages = match.captured(7).toInt();
    const int maid = match.captured(8).toInt();
    const int system = match.captured(9).toInt();
    const bool failed = match.captured(10).toInt() != 0;
    const int total = packages + extra + flatpak + firmware
        + controllers + appimages + maid;

    if (failed || exitCode != 0) {
        setStatus(QStringLiteral("Check failed"),
                  QStringLiteral("%1 could not complete the preview. See the details below or open the log.").arg(pmName),
                  QStringLiteral("dialog-error"));
        QApplication::alert(this);
    } else if (total == 0) {
        setStatus(QStringLiteral("System up to date"),
                  QStringLiteral("Nothing to install right now."),
                  QStringLiteral("emblem-default"));
    } else {
        QStringList parts;
        const auto add = [&parts](int count, const QString &singular, const QString &plural) {
            if (count > 0)
                parts << QStringLiteral("%1 %2").arg(count).arg(count == 1 ? singular : plural);
        };
        add(packages, QStringLiteral("package"), QStringLiteral("packages"));
        add(extra, QStringLiteral("extra package"), QStringLiteral("extra packages"));
        add(flatpak, QStringLiteral("Flatpak app"), QStringLiteral("Flatpak apps"));
        add(firmware, QStringLiteral("firmware update"), QStringLiteral("firmware updates"));
        add(controllers, QStringLiteral("controller package"), QStringLiteral("controller packages"));
        add(appimages, QStringLiteral("AppImage"), QStringLiteral("AppImages"));
        add(maid, QStringLiteral("Maid repo"), QStringLiteral("Maid repos"));
        if (parts.isEmpty())
            parts << QStringLiteral("updates available");

        const QString detail = QStringLiteral("%1: %2").arg(pmName, parts.join(QStringLiteral("  •  ")));
        if (system == 1 || firmware > 0) {
            setStatus(QStringLiteral("System update available"), detail,
                      QStringLiteral("software-update-urgent"));
        } else {
            setStatus(QStringLiteral("Updates available"), detail,
                      QStringLiteral("software-update-available"));
        }
    }

    if (m_tray && !isVisible())
        showTrayMessage(m_statusTitle->text(), m_statusDetail->text());
}

void MainWindow::startUpdate()
{
    if (m_terminalUpdater.isEmpty()) {
        showError(QStringLiteral("Terminal updater not found"),
                  QStringLiteral("system-updater was not found next to this app or in ~/.local/bin. Run install.sh first."));
        return;
    }

    const bool started = QProcess::startDetached(m_terminalUpdater, QStringList());
    if (!started) {
        showError(QStringLiteral("Could not start the updater"),
                  QStringLiteral("Tried to run:\n%1").arg(m_terminalUpdater));
        return;
    }

    appendOutput(QStringLiteral("\nStarted the terminal updater: %1\n").arg(m_terminalUpdater));
    setStatus(QStringLiteral("Update opened in a terminal"),
              QStringLiteral("The terminal handles sudo and shows live progress. Run Check again when it finishes."),
              QStringLiteral("system-software-update"));
    statusBar()->showMessage(QStringLiteral("Update started in a terminal"), 8000);
}

void MainWindow::openLog()
{
    if (!QFileInfo::exists(m_logPath)) {
        QMessageBox::information(this, QStringLiteral("No log yet"),
                                 QStringLiteral("There is no log at:\n%1\n\nRun a check or update first.")
                                     .arg(m_logPath));
        return;
    }
    QDesktopServices::openUrl(QUrl::fromLocalFile(m_logPath));
}

void MainWindow::showAbout()
{
    QMessageBox::about(
        this,
        QStringLiteral("About Maid AU"),
        QStringLiteral(
            "<h3>Maid AU %1</h3>"
            "<p>One updater for everything on Linux: native packages, Flatpak, "
            "firmware, controllers, AppImages, and the Maid suite.</p>"
            "<p>Checks are read-only. Updates run in a terminal so sudo and "
            "live output stay visible. Snapshots are taken by the updater "
            "before and after the run when snapper or timeshift is available.</p>"
            "<p>MIT licensed. <a href=\"https://github.com/Maidware-Project/Maid-AU\">"
            "github.com/Maidware-Project/Maid-AU</a></p>")
            .arg(QStringLiteral(MAID_AU_VERSION)));
}

void MainWindow::showError(const QString &title, const QString &message)
{
    statusBar()->showMessage(title, 8000);
    if (!m_quitAfterCheck)
        QMessageBox::critical(this, title, message);
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    if (m_tray) {
        hide();
        event->ignore();
        if (!m_closeToTrayTipShown) {
            m_closeToTrayTipShown = true;
            m_settings.setValue(QStringLiteral("tray/tipShown"), true);
            m_settings.sync();
            showTrayMessage(QStringLiteral("Maid AU"),
                            QStringLiteral("Still running in the tray. Double-click the icon to reopen or use its menu to quit."));
        }
        return;
    }

    m_settings.setValue(QStringLiteral("window/geometry"), saveGeometry());
    m_settings.sync();
    event->accept();
}
