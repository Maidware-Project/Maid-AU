#pragma once

#include <QIcon>
#include <QMainWindow>
#include <QProcess>
#include <QSettings>
#include <QString>
#include <QSystemTrayIcon>

class QAction;
class QLabel;
class QPlainTextEdit;
class QProgressBar;
class QPushButton;

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(const QIcon &icon, QWidget *parent = nullptr);
    ~MainWindow() override;

    bool trayAvailable() const;
    void setQuitAfterCheck(bool enabled);
    void showTrayMessage(const QString &title, const QString &message);

public slots:
    void startCheck();

protected:
    void closeEvent(QCloseEvent *event) override;

private slots:
    void cancelCheck();
    void startUpdate();
    void cancelUpdate();
    void openLog();
    void showAbout();
    void trayActivated(QSystemTrayIcon::ActivationReason reason);
    void readCheckOutput();
    void checkFinished(int exitCode, QProcess::ExitStatus status);
    void checkFailed(QProcess::ProcessError error);
    void readUpdateOutput();
    void updateFinished(int exitCode, QProcess::ExitStatus status);
    void updateFailed(QProcess::ProcessError error);
    void loadLastUpdate();

private:
    void buildUi(const QIcon &icon);
    void buildTray(const QIcon &icon);
    void buildMenus();
    void findTools();
    bool ensureAskpass();
    void setBusy(bool busy);
    void setChecking(bool checking);
    void setStatus(const QString &title, const QString &detail, const QString &iconName);
    void appendOutput(const QString &text);
    void parseCheckResult(int exitCode, bool normalExit);
    void showError(const QString &title, const QString &message);

    QProcess *m_check = nullptr;
    QProcess *m_update = nullptr;
    QByteArray m_checkBuffer;
    QByteArray m_updateBuffer;
    bool m_checkCancelled = false;
    bool m_updateCancelled = false;
    bool m_updating = false;
    bool m_quitAfterCheck = false;
    bool m_closeToTrayTipShown = false;

    QString m_updateScript;
    QString m_askpassPath;
    QString m_logPath;
    QString m_lastPath;

    QLabel *m_statusIcon = nullptr;
    QLabel *m_statusTitle = nullptr;
    QLabel *m_statusDetail = nullptr;
    QLabel *m_lastUpdate = nullptr;
    QLabel *m_systemInfo = nullptr;
    QLabel *m_footer = nullptr;
    QPushButton *m_checkButton = nullptr;
    QPushButton *m_updateButton = nullptr;
    QPushButton *m_cancelButton = nullptr;
    QPushButton *m_logButton = nullptr;
    QProgressBar *m_progress = nullptr;
    QPlainTextEdit *m_output = nullptr;

    QSystemTrayIcon *m_tray = nullptr;
    QAction *m_trayCheckAction = nullptr;
    QAction *m_trayUpdateAction = nullptr;
    QAction *m_trayShowAction = nullptr;
    QAction *m_trayQuitAction = nullptr;
    QAction *m_menuCheckAction = nullptr;
    QAction *m_menuUpdateAction = nullptr;
    QAction *m_menuLogAction = nullptr;

    QSettings m_settings;
};
