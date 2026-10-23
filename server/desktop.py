"""LanCinema for Windows. Build as a standalone executable with PyInstaller."""
import ipaddress
import os
from pathlib import Path
import socket
import sys
import threading

from PySide6.QtCore import Qt, QTimer, QThread, Signal, QLockFile
from PySide6.QtGui import QIcon, QPixmap, QImage, QAction, QFont
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QCheckBox, QFileDialog, QComboBox, QSystemTrayIcon,
    QMenu, QMessageBox, QGroupBox)
import qrcode
from zeroconf import Zeroconf, ServiceInfo, IPVersion
from desktop_core import load_settings, save_settings, validate, set_autostart, config_path, connection_qr
from server import MediaServer


def addresses():
    values = set()
    for entry in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
        ip = entry[4][0]
        if ipaddress.ip_address(ip).is_private and not ip.startswith('127.'):
            values.add(ip)
    return sorted(values, key=lambda x: (not x.startswith('192.168.'), x))


class Service:
    def __init__(self):
        self.http = None
        self.zeroconf = None
        self.info = None
        self.settings = None

    def stop(self):
        if self.zeroconf:
            self.zeroconf.close()
            self.zeroconf = None
        if self.http:
            self.http.shutdown()
            self.http.server_close()
            self.http = None

    def start(self, settings):
        self.http = MediaServer(('0.0.0.0', 8123), settings['root'], settings['password'])
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.settings = settings
        self.advertise()

    def advertise(self):
        if self.zeroconf:
            self.zeroconf.close()
            self.zeroconf = None
        ips = addresses()
        if not ips:
            return '没有局域网地址，请连接 Wi-Fi 或网线。'
        try:
            self.zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
            self.info = ServiceInfo('_lancinema._tcp.local.', socket.gethostname()+'._lancinema._tcp.local.',
                addresses=[socket.inet_aton(ip) for ip in ips], port=8123,
                properties={'version': '2'}, server=socket.gethostname()+'.local.')
            self.zeroconf.register_service(self.info, allow_name_change=True)
            return ''
        except Exception:
            return '自动发现暂不可用，请扫码或手动填写电脑地址。'


class ApplyWorker(QThread):
    finished_apply = Signal(object, str)

    def __init__(self, service, settings, persist=True):
        super().__init__()
        self.service, self.settings, self.persist = service, settings, persist

    def run(self):
        old = self.service.settings
        try:
            checked = validate(self.settings)
            self.service.stop()
            self.service.start(checked)
            if self.persist:
                save_settings(checked)
                if getattr(sys, 'frozen', False):
                    set_autostart(checked['autostart'])
            self.finished_apply.emit(checked, '')
        except Exception as error:
            self.service.stop()
            if old:
                try:
                    self.service.start(old)
                    if self.persist:
                        save_settings(old)
                        if getattr(sys, 'frozen', False):
                            set_autostart(old['autostart'])
                except Exception:
                    pass
            message = '端口 8123 已被占用，请先退出旧版电脑文件服务。' if isinstance(error, OSError) and getattr(error, 'winerror', None) == 10048 else str(error)
            self.finished_apply.emit(None, message)


class Window(QMainWindow):
    def __init__(self, settings, preview=False):
        super().__init__()
        self.settings, self.preview = settings, preview
        self.service = Service()
        self.worker = None
        self.setWindowTitle('局域影院 · 电脑端')
        self.setMinimumSize(760, 600)
        self.resize(860, 670)
        asset = Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'app.ico'
        self.setWindowIcon(QIcon(str(asset)))
        content = QWidget()
        self.setCentralWidget(content)
        layout = QVBoxLayout(content)
        layout.setContentsMargins(32, 28, 32, 24)
        layout.setSpacing(16)
        title = QLabel('局域影院')
        title.setObjectName('title')
        layout.addWidget(title)
        intro = QLabel('把电脑里的视频，带到手机屏幕上。')
        intro.setObjectName('secondary')
        layout.addWidget(intro)
        self.status = QLabel('正在启动文件服务…')
        self.status.setWordWrap(True)
        self.status.setObjectName('status')
        layout.addWidget(self.status)
        columns = QHBoxLayout()
        columns.setSpacing(28)
        layout.addLayout(columns, 1)
        settings_group = QGroupBox('共享设置')
        form = QVBoxLayout(settings_group)
        form.setSpacing(12)
        folder_label = QLabel('共享文件夹')
        form.addWidget(folder_label)
        self.folder = QLineEdit(settings['root'])
        self.folder.setAccessibleName('共享文件夹')
        folder_label.setBuddy(self.folder)
        form.addWidget(self.folder)
        self.folder_full = QLabel(settings['root'])
        self.folder_full.setWordWrap(True)
        self.folder_full.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.folder_full.setObjectName('secondary')
        form.addWidget(self.folder_full)
        self.folder.textChanged.connect(self.folder_full.setText)
        choose = QPushButton('选择文件夹…')
        choose.clicked.connect(self.choose_folder)
        form.addWidget(choose)
        password_label = QLabel('连接密码（至少 8 位）')
        form.addWidget(password_label)
        self.password = QLineEdit(settings['password'])
        self.password.setEchoMode(QLineEdit.Password)
        self.password.setAccessibleName('连接密码')
        password_label.setBuddy(self.password)
        form.addWidget(self.password)
        reveal = QCheckBox('显示密码')
        reveal.toggled.connect(lambda checked: self.password.setEchoMode(QLineEdit.Normal if checked else QLineEdit.Password))
        form.addWidget(reveal)
        self.autostart = QCheckBox('登录 Windows 后自动启动')
        self.autostart.setChecked(settings['autostart'])
        form.addWidget(self.autostart)
        hint = QLabel('关闭窗口后仍在托盘运行。\n目录、密码和自启设置点击保存后生效。')
        hint.setWordWrap(True)
        hint.setObjectName('secondary')
        form.addWidget(hint)
        form.addStretch()
        self.save = QPushButton('保存并应用')
        self.save.setObjectName('primary')
        self.save.clicked.connect(self.apply)
        form.addWidget(self.save)
        columns.addWidget(settings_group, 1)
        connect = QGroupBox('连接手机')
        side = QVBoxLayout(connect)
        side.setSpacing(12)
        self.ip = QComboBox()
        self.ip.setAccessibleName('电脑局域网地址')
        self.ip.addItems(addresses() or ['127.0.0.1'])
        side.addWidget(self.ip)
        self.qr = QLabel()
        self.qr.setAlignment(Qt.AlignCenter)
        self.qr.setMinimumSize(240, 240)
        side.addWidget(self.qr)
        self.ip.currentTextChanged.connect(self.update_qr)
        note = QLabel('在手机 App 选择「扫码连接」\n或选择这台电脑后输入密码。\n\n手机与电脑需连接同一局域网。\n二维码含连接密码，请勿公开分享。')
        note.setWordWrap(True)
        note.setObjectName('secondary')
        side.addWidget(note)
        side.addStretch()
        columns.addWidget(connect, 1)
        self.notice = QLabel('仅共享所选目录及子目录，手机端不能修改电脑文件。')
        self.notice.setWordWrap(True)
        self.notice.setObjectName('secondary')
        layout.addWidget(self.notice)
        self.tray = QSystemTrayIcon(self.windowIcon(), self)
        menu = QMenu()
        show = menu.addAction('打开局域影院')
        show.triggered.connect(self.show_window)
        menu.addSeparator()
        quit_action = menu.addAction('退出并停止共享')
        quit_action.triggered.connect(self.exit_app)
        self.tray.setContextMenu(menu)
        self.tray.setToolTip('局域影院 · 电脑文件服务')
        self.tray.activated.connect(lambda reason: self.show_window() if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick) else None)
        if not preview:
            self.tray.show()
        self.update_qr()
        if not preview:
            QTimer.singleShot(0, self.apply)
        else:
            self.status.setText('共享已开启 · 设置已保存')
        self.network_timer = QTimer(self)
        self.network_timer.timeout.connect(self.refresh_network)
        if not preview:
            self.network_timer.start(30000)

    def show_window(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def choose_folder(self):
        value = QFileDialog.getExistingDirectory(self, '选择共享文件夹', self.folder.text())
        if value:
            self.folder.setText(value)

    def apply(self):
        if self.worker and self.worker.isRunning():
            return
        proposed = {'root': self.folder.text().strip(), 'password': self.password.text(), 'autostart': self.autostart.isChecked()}
        self.save.setEnabled(False)
        self.status.setText('正在应用设置…')
        self.worker = ApplyWorker(self.service, proposed)
        self.worker.finished_apply.connect(self.applied)
        self.worker.start()

    def applied(self, settings, error):
        self.save.setEnabled(True)
        if error:
            prefix = '保存失败，原设置仍在运行。' if self.service.http else '服务未启动。'
            self.status.setText(prefix + '\n' + error)
            self.show_window()
        else:
            self.settings = settings
            self.status.setText('共享已开启 · 设置已保存')
            self.update_qr()

    def update_qr(self):
        code = qrcode.QRCode(box_size=6, border=4)
        code.add_data(connection_qr(self.ip.currentText(), self.settings['password']))
        code.make(fit=True)
        bitmap = code.make_image(fill_color='black', back_color='white').convert('RGB')
        data = bitmap.tobytes()
        picture = QImage(data, bitmap.width, bitmap.height, bitmap.width*3, QImage.Format_RGB888).copy()
        self.qr.setPixmap(QPixmap.fromImage(picture).scaled(260, 260, Qt.KeepAspectRatio, Qt.FastTransformation))

    def refresh_network(self):
        if self.worker and self.worker.isRunning():
            return
        current = [self.ip.itemText(i) for i in range(self.ip.count())]
        new = addresses() or ['127.0.0.1']
        if current != new:
            self.ip.clear()
            self.ip.addItems(new)
            if self.service.http:
                threading.Thread(target=self.service.advertise, daemon=True).start()

    def closeEvent(self, event):
        if self.preview:
            event.accept()
            return
        if QSystemTrayIcon.isSystemTrayAvailable():
            event.ignore()
            self.hide()
        else:
            event.ignore()
            self.exit_app()

    def exit_app(self):
        if self.worker and self.worker.isRunning():
            self.status.setText('正在保存，请稍候再退出。')
            return
        self.network_timer.stop()
        self.service.stop()
        self.tray.hide()
        QApplication.quit()


STYLE = '''
QWidget { font-family: "Microsoft YaHei UI"; font-size: 14px; color: #192b30; }
QMainWindow { background: #f6f8f8; }
QLabel#title { font-size: 28px; font-weight: 600; }
QLabel#secondary { color: #52656a; font-size: 13px; }
QLabel#status { color: #006c62; font-weight: 600; padding: 8px 0; }
QGroupBox { background: white; border: 1px solid #d4dfe0; border-radius: 8px; margin-top: 12px; padding: 20px 16px 16px; }
QGroupBox::title { subcontrol-origin: margin; left: 16px; padding: 0 4px; font-weight: 600; }
QLineEdit, QComboBox { border: 1px solid #899fa4; border-radius: 5px; padding: 8px; background: white; selection-background-color: #007f75; }
QLineEdit:focus, QComboBox:focus { border: 2px solid #007f75; padding: 7px; }
QPushButton { min-height: 24px; padding: 8px 16px; border: 1px solid #899fa4; border-radius: 5px; background: white; }
QPushButton:hover { background: #edf6f4; }
QPushButton:pressed { background: #d7eae6; }
QPushButton:focus { border: 2px solid #007f75; }
QPushButton#primary { background: #00776d; color: white; border-color: #00776d; font-weight: 600; }
QPushButton#primary:hover { background: #00645c; }
QPushButton:disabled { color: #66787b; background: #e1e9e9; }
QCheckBox { spacing: 8px; min-height: 28px; }
'''


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setStyle('Fusion')
    app.setStyleSheet(STYLE)
    preview = '--preview' in sys.argv
    endpoint = 'LanCinemaDesktop-' + os.environ.get('USERNAME', 'user')
    channel = QLocalSocket()
    channel.connectToServer(endpoint)
    if not preview and channel.waitForConnected(250):
        channel.write(b'show')
        channel.waitForBytesWritten(500)
        return
    singleton = QLocalServer()
    if not preview:
        QLocalServer.removeServer(endpoint)
        singleton.listen(endpoint)
    try:
        settings = load_settings() if not preview else {'root': r'G:\123', 'password': 'preview-password', 'autostart': True}
    except Exception:
        QMessageBox.critical(None, '无法读取设置', '设置文件损坏或密码无法解密。请备份后移走以下文件再启动：\n'+str(config_path()))
        return
    window = Window(settings, preview)
    def show_existing():
        while singleton.hasPendingConnections():
            peer = singleton.nextPendingConnection()
            peer.disconnectFromServer()
            peer.deleteLater()
        window.show_window()
    singleton.newConnection.connect(show_existing)
    if '--background' not in sys.argv or preview:
        window.show()
    if preview:
        destination = sys.argv[sys.argv.index('--preview')+1]
        QTimer.singleShot(500, lambda: (window.grab().save(destination), app.quit()))
    sys.exit(app.exec())


if __name__ == '__main__':
    main()
