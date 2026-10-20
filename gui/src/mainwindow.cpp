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
#include <QStyleFactory>
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

void MainWindow::setScreenshotMode(bool enabled)
{
    m_screenshotMode = enabled;
    // Screenshots are shared publicly: never ship this machine's hostname,
    // distro name, or home path in them.
    if (enabled && m_systemInfo) {
        m_systemInfo->setText(QStringLiteral("Linux"));
        m_footer->setText(QStringLiteral("Log: ~/.local/share/update-all.log"));
    }
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
    m_checkButton->setObjectName(QStringLiteral("checkButton"));
    m_checkButton->setDefault(true);
    m_updateButton = new QPushButton(QIcon::fromTheme(QStringLiteral("system-software-update")),
                                     QStringLiteral("Update now"), central);
    m_updateButton->setObjectName(QStringLiteral("primaryButton"));
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
    connect(quitAction, &QAction::triggered, this, &MainWindow::quitRequested);

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
    connect(m_trayQuitAction, &QAction::triggered, this, &MainWindow::quitRequested);

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

void MainWindow::setBusy(bool busy)
{
    m_checkButton->setEnabled(!busy);
    m_updateButton->setEnabled(!busy);
    m_cancelButton->setVisible(busy && !m_updating);
    m_cancelButton->setEnabled(!m_updating);
    m_progress->setVisible(busy);
    if (m_menuCheckAction)
        m_menuCheckAction->setEnabled(!busy);
    if (m_menuUpdateAction)
        m_menuUpdateAction->setEnabled(!busy);
    if (m_trayCheckAction)
        m_trayCheckAction->setEnabled(!busy);
    if (m_trayUpdateAction)
        m_trayUpdateAction->setEnabled(!busy);
}

void MainWindow::setChecking(bool checking)
{
    setBusy(checking);
    statusBar()->showMessage(checking ? QStringLiteral("Checking...")
                                      : QStringLiteral("Ready"));
}

QString MainWindow::scriptLabel() const
{
    return m_screenshotMode ? QStringLiteral("~/.local/bin/update-all.sh") : m_updateScript;
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
    if (m_check || m_update)
        return;

    if (m_updateScript.isEmpty()) {
        showError(QStringLiteral("Updater not found"),
                  QStringLiteral("update-all.sh was not found next to this app or in ~/.local/bin. Run install.sh first."));
        if (m_quitAfterCheck)
            QTimer::singleShot(0, qApp, &QApplication::quit);
        return;
    }

    m_checkCancelled = false;
    m_updating = false;
    m_checkBuffer.clear();
    m_output->clear();
    appendOutput(QStringLiteral("Running: %1 --check\n\n").arg(scriptLabel()));
    setChecking(true);
    setStatus(QStringLiteral("Checking for updates..."),
              QStringLiteral("Reading native packages, Flatpak, firmware, controllers, AppImages, and the Maid suite. This can take a minute."),
              QStringLiteral("view-refresh"));

    m_check = new QProcess(this);
    m_check->setProcessChannelMode(QProcess::MergedChannels);
    m_check->setWorkingDirectory(QDir::homePath());

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("UPDATE_NO_NOTIFY"), QStringLiteral("1"));
    if (!m_askpassPath.isEmpty()) {
        env.insert(QStringLiteral("MAID_AU_GUI"), QStringLiteral("1"));
        env.insert(QStringLiteral("SUDO_ASKPASS"), m_askpassPath);
    }
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
    if (m_check || m_update)
        return;

    if (m_updateScript.isEmpty()) {
        showError(QStringLiteral("Updater not found"),
                  QStringLiteral("update-all.sh was not found next to this app or in ~/.local/bin. Run install.sh first."));
        return;
    }

    if (!ensureAskpass() || m_askpassPath.isEmpty()) {
        showError(QStringLiteral("No password dialog available"),
                  QStringLiteral("Maid AU could not find or create a graphical sudo password helper. "
                                 "Install ksshaskpass or ssh-askpass, then try again."));
        return;
    }

    m_updateCancelled = false;
    m_updateBuffer.clear();
    m_output->clear();
    appendOutput(QStringLiteral("Running: %1\n\n").arg(scriptLabel()));
    appendOutput(QStringLiteral("Updates run inside this window. If sudo needs a password, "
                                "a graphical dialog will appear.\n\n"));

    m_updating = true;
    setBusy(true);
    setStatus(QStringLiteral("Updating..."),
              QStringLiteral("Keep this window open. The administrator password dialog may appear; live output is shown below."),
              QStringLiteral("system-software-update"));
    statusBar()->showMessage(QStringLiteral("Updating..."));

    m_update = new QProcess(this);
    m_update->setProcessChannelMode(QProcess::MergedChannels);
    m_update->setWorkingDirectory(QDir::homePath());

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("UPDATE_NO_NOTIFY"), QStringLiteral("1"));
    env.insert(QStringLiteral("MAID_AU_GUI"), QStringLiteral("1"));
    env.insert(QStringLiteral("SUDO_ASKPASS"), m_askpassPath);
    m_update->setProcessEnvironment(env);

    connect(m_update, &QProcess::readyReadStandardOutput,
            this, &MainWindow::readUpdateOutput);
    connect(m_update, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &MainWindow::updateFinished);
    connect(m_update, &QProcess::errorOccurred,
            this, &MainWindow::updateFailed);

    m_update->start(m_updateScript, QStringList());
    m_update->closeWriteChannel();
}

void MainWindow::readUpdateOutput()
{
    if (!m_update)
        return;
    const QByteArray chunk = m_update->readAllStandardOutput();
    if (chunk.isEmpty())
        return;
    m_updateBuffer += chunk;
    appendOutput(QString::fromLocal8Bit(chunk));
}

void MainWindow::updateFinished(int exitCode, QProcess::ExitStatus status)
{
    if (!m_update)
        return;

    const QByteArray tail = m_update->readAllStandardOutput();
    if (!tail.isEmpty()) {
        m_updateBuffer += tail;
        appendOutput(QString::fromLocal8Bit(tail));
    }

    m_update->deleteLater();
    m_update = nullptr;
    m_updating = false;
    setBusy(false);
    loadLastUpdate();

    const QString output = QString::fromLocal8Bit(m_updateBuffer);
    const QRegularExpression summary(
        QStringLiteral("=== done \\(([^)]*)\\): failed=(\\d+) updated=(\\d+) important=(\\d+) ==="));
    const QRegularExpressionMatch match = summary.match(output);
    const bool failed = (status != QProcess::NormalExit) || exitCode != 0
        || (match.hasMatch() && match.captured(2).toInt() != 0);
    const int updated = match.hasMatch() ? match.captured(3).toInt() : -1;

    if (m_updateCancelled) {
        setStatus(QStringLiteral("Update stopped"),
                  QStringLiteral("The update process was stopped. Open the log to see what finished."),
                  QStringLiteral("dialog-warning"));
    } else if (failed) {
        setStatus(QStringLiteral("Update finished with errors"),
                  QStringLiteral("One or more steps failed. Read the details below or open the log; the system is not half-upgraded by a single failed dry run, but a failed package transaction should be checked."),
                  QStringLiteral("dialog-error"));
        QApplication::alert(this);
    } else if (updated == 0) {
        setStatus(QStringLiteral("Already up to date"),
                  QStringLiteral("No packages, Flatpak apps, firmware, controllers, or Maid repos needed updating."),
                  QStringLiteral("emblem-default"));
    } else {
        QString detail = QStringLiteral("Packages, Flatpak, firmware, controllers, AppImages, and the Maid suite finished successfully.");
        if (output.contains(QStringLiteral("reboot recommended"), Qt::CaseInsensitive))
            detail += QStringLiteral(" Reboot recommended when convenient.");
        setStatus(QStringLiteral("Update complete"), detail,
                  QStringLiteral("software-update-available"));
    }

    statusBar()->showMessage(QStringLiteral("Ready"));
    if (m_tray && !isVisible())
        showTrayMessage(m_statusTitle->text(), m_statusDetail->text());
}

void MainWindow::updateFailed(QProcess::ProcessError error)
{
    if (!m_update)
        return;

    if (error != QProcess::FailedToStart)
        return;

    const QString message = QStringLiteral("Could not start %1. Check that it is executable.")
                                .arg(m_updateScript);
    m_update->deleteLater();
    m_update = nullptr;
    m_updating = false;
    setBusy(false);
    appendOutput(message + QLatin1Char('\n'));
    setStatus(QStringLiteral("Update failed"), message, QStringLiteral("dialog-error"));
    showError(QStringLiteral("Update failed"), message);
}

void MainWindow::quitRequested()
{
    if (m_update) {
        QMessageBox::information(
            this, QStringLiteral("Update in progress"),
            QStringLiteral("Maid AU is still updating. Let it finish before quitting so the package transaction is not interrupted."));
        return;
    }
    qApp->quit();
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
            "<p>Checks are read-only. Updates run inside this window; sudo asks "
            "for the administrator password with a graphical dialog, so no "
            "terminal is needed. Live output stays visible below.</p>"
            "<p>Snapshots are taken by the updater "
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
    if (m_update) {
        QMessageBox::information(
            this, QStringLiteral("Update in progress"),
            QStringLiteral("Maid AU is still updating. Keep it open until the update finishes."));
        event->ignore();
        return;
    }

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


void applyMaidwareTheme(QApplication *app)
{
    // Maidware / Tokyo Night: deep ink, soft slates, one teal accent.
    // Fusion keeps this identical on Plasma, GNOME and plain X11.
    if (QStyle *fusion = QStyleFactory::create(QStringLiteral("Fusion")))
        app->setStyle(fusion);

    QPalette pal;
    const QColor bg(QStringLiteral("#1a1b26"));
    const QColor surface(QStringLiteral("#2c2d37"));
    const QColor base(QStringLiteral("#16161d"));
    const QColor text(QStringLiteral("#d7dae0"));
    const QColor muted(QStringLiteral("#9295ac"));
    const QColor accent(QStringLiteral("#5cb9ae"));
    const QColor border(QStringLiteral("#454654"));

    pal.setColor(QPalette::Window, bg);
    pal.setColor(QPalette::WindowText, text);
    pal.setColor(QPalette::Base, base);
    pal.setColor(QPalette::AlternateBase, surface);
    pal.setColor(QPalette::Text, text);
    pal.setColor(QPalette::Button, surface);
    pal.setColor(QPalette::ButtonText, text);
    pal.setColor(QPalette::BrightText, QColor(QStringLiteral("#ff7a85")));
    pal.setColor(QPalette::Highlight, accent);
    pal.setColor(QPalette::HighlightedText, bg);
    pal.setColor(QPalette::Link, accent);
    pal.setColor(QPalette::LinkVisited, QColor(QStringLiteral("#a7d8d2")));
    pal.setColor(QPalette::ToolTipBase, surface);
    pal.setColor(QPalette::ToolTipText, text);
    pal.setColor(QPalette::PlaceholderText, muted);
    pal.setColor(QPalette::Disabled, QPalette::Text, QColor(QStringLiteral("#6f7288")));
    pal.setColor(QPalette::Disabled, QPalette::ButtonText, QColor(QStringLiteral("#6f7288")));
    pal.setColor(QPalette::Disabled, QPalette::WindowText, QColor(QStringLiteral("#6f7288")));
    app->setPalette(pal);

    app->setStyleSheet(QStringLiteral(R"QSS(
QMainWindow, QDialog { background: #1a1b26; }
QWidget { color: #d7dae0; font-family: "Noto Sans", "Cantarell", sans-serif; font-size: 10pt; }
QLabel { background: transparent; }
QLabel:disabled { color: #6f7288; }
QFrame#statusCard {
    background: #2c2d37; border: 1px solid #454654; border-radius: 12px;
}
QGroupBox {
    background: #20212b; border: 1px solid #2c2d37; border-radius: 10px;
    margin-top: 14px; padding-top: 8px; font-weight: 600;
}
QGroupBox::title {
    subcontrol-origin: margin; subcontrol-position: top left;
    left: 12px; padding: 0 6px; color: #9295ac;
}
QPushButton {
    background: #2c2d37; color: #d7dae0; border: 1px solid #454654;
    border-radius: 7px; padding: 7px 15px; min-height: 18px;
}
QPushButton:hover { background: #353642; border-color: #5b5d70; }
QPushButton:pressed { background: #252631; }
QPushButton:default, QPushButton#checkButton { border-color: #5cb9ae; }
QPushButton#primaryButton {
    background: #5cb9ae; color: #12131a; border-color: #5cb9ae; font-weight: 700;
}
QPushButton#primaryButton:hover { background: #73cbc0; border-color: #73cbc0; }
QPushButton#primaryButton:pressed { background: #4aa49a; }
QPushButton:disabled {
    background: #242530; color: #6f7288; border-color: #2c2d37;
}
QPlainTextEdit {
    background: #16161d; color: #d7dae0; border: 1px solid #2c2d37;
    border-radius: 8px; padding: 8px;
    selection-background-color: #5cb9ae; selection-color: #1a1b26;
    font-family: "DejaVu Sans Mono", "Noto Sans Mono", monospace; font-size: 9.5pt;
}
QProgressBar {
    background: #2c2d37; border: none; border-radius: 3px; min-height: 6px; max-height: 6px;
}
QProgressBar::chunk { background: #5cb9ae; border-radius: 3px; }
QMenuBar { background: #16161d; color: #9295ac; border-bottom: 1px solid #2c2d37; }
QMenuBar::item { padding: 5px 10px; background: transparent; border-radius: 5px; }
QMenuBar::item:selected { background: #2c2d37; color: #d7dae0; }
QMenu { background: #20212b; border: 1px solid #454654; padding: 5px; }
QMenu::item { padding: 6px 26px 6px 12px; border-radius: 5px; }
QMenu::item:selected { background: #2c2d37; }
QMenu::separator { height: 1px; background: #2c2d37; margin: 5px 8px; }
QStatusBar { background: #16161d; color: #9295ac; border-top: 1px solid #2c2d37; }
QToolTip { background: #2c2d37; color: #d7dae0; border: 1px solid #454654; padding: 5px 8px; }
QScrollBar:vertical { background: transparent; width: 10px; margin: 2px; }
QScrollBar::handle:vertical { background: #454654; border-radius: 4px; min-height: 24px; }
QScrollBar::handle:vertical:hover { background: #5b5d70; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar:horizontal { background: transparent; height: 10px; margin: 2px; }
QScrollBar::handle:horizontal { background: #454654; border-radius: 4px; min-width: 24px; }
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal { width: 0; }
)QSS"));
}
