"""LanCinema for Windows. Build as a standalone executable with PyInstaller."""
import ipaddress
import os
import plistlib
import sqlite3
import uuid
from pathlib import Path
import socket
import sys
import threading

from PySide6.QtCore import Qt, QTimer, QThread, Signal, QLockFile, QUrl
from PySide6.QtGui import QIcon, QPixmap, QImage, QAction, QFont, QDesktopServices
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QCheckBox, QFileDialog, QComboBox, QSystemTrayIcon,
    QMenu, QMessageBox, QGroupBox, QListWidget, QListWidgetItem, QScrollArea, QFrame, QLayout)
import qrcode
from zeroconf import Zeroconf, ServiceInfo, IPVersion
from desktop_core import load_settings, save_settings, validate, set_autostart, config_path, connection_qr
from server import MediaServer
from user_state import UserState, state_path
from legacy_backup import read_backup, save_archive, import_archive


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
        self.http = MediaServer(('0.0.0.0', 8123), settings.get('roots', settings['root']), settings['password'])
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
        except Exception as error:
            self.finished_apply.emit(None, str(error))
            return
        try:
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


class RecordImportWorker(QThread):
    completed = Signal(object, str)

    def __init__(self, source, apple):
        super().__init__()
        self.source, self.apple = source, apple

    def run(self):
        try:
            if self.apple:
                archive = read_backup(self.source)
            else:
                path = Path(self.source)
                if path.stat().st_size > 32 * 1024 * 1024:
                    raise ValueError('记录文件异常过大，请检查所选文件。')
                with path.open('rb') as stream:
                    archive = plistlib.load(stream)
            destination = state_path().parent / 'record-backups' / f'records-{uuid.uuid4()}.plist'
            save_archive(archive, destination)
            counts = import_archive(archive, UserState())
            self.completed.emit({**counts, 'backup': str(destination)}, '')
        except Exception as error:
            self.completed.emit(None, str(error))


class Window(QMainWindow):
    def __init__(self, settings, preview=False):
        super().__init__()
        self.settings, self.preview = settings, preview
        self.service = Service()
        self.worker = None
        self.import_worker = None
        self.setWindowTitle('局域影院 · 电脑端')
        self.setMinimumSize(760, 700)
        self.resize(900, 760)
        asset = Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'app.ico'
        self.setWindowIcon(QIcon(str(asset)))
        content = QWidget()
        content.setObjectName('desktopContent')
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setWidget(content)
        self.setCentralWidget(scroll)
        layout = QVBoxLayout(content)
        layout.setSizeConstraint(QLayout.SetMinimumSize)
        layout.setContentsMargins(32, 28, 32, 24)
        layout.setSpacing(14)
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
        form.setSpacing(10)
        folder_label = QLabel('共享文件夹')
        form.addWidget(folder_label)
        self.folders = QListWidget()
        self.folders.setAccessibleName('共享文件夹列表')
        self.folders.setWordWrap(True)
        self.folders.setTextElideMode(Qt.ElideNone)
        self.folders.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.folders.setMinimumHeight(108)
        self.folders.setMaximumHeight(132)
        folder_label.setBuddy(self.folders)
        form.addWidget(self.folders)
        folder_actions = QHBoxLayout()
        self.add_folder_button = QPushButton('添加文件夹…')
        self.add_folder_button.clicked.connect(self.choose_folder)
        folder_actions.addWidget(self.add_folder_button)
        self.remove_folder_button = QPushButton('移除所选')
        self.remove_folder_button.clicked.connect(self.remove_folder)
        folder_actions.addWidget(self.remove_folder_button)
        form.addLayout(folder_actions)
        self.folder_hint = QLabel()
        self.folder_hint.setWordWrap(True)
        self.folder_hint.setObjectName('secondary')
        form.addWidget(self.folder_hint)
        self.folders.currentRowChanged.connect(self.update_folder_state)
        for root in settings.get('roots', [settings.get('root', r'G:\123')]):
            self.add_folder(root)
        self.folders.setCurrentRow(0)
        self.folders.scrollToTop()
        self.update_folder_state()
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
        self.records_button = QPushButton('记录备份与恢复')
        record_menu = QMenu(self.records_button)
        record_menu.addAction('从 iPhone 的电脑备份导入…', lambda: self.import_records(True))
        record_menu.addAction('导入 App 导出的记录…', lambda: self.import_records(False))
        record_menu.addAction('导出电脑同步库副本…', self.export_records)
        record_menu.addAction('打开记录保存位置', self.open_records_folder)
        self.records_button.setMenu(record_menu)
        side.addWidget(self.records_button)
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
            self.status.setText(f'共享已开启 · {self.folders.count()} 个文件夹')
        self.network_timer = QTimer(self)
        self.network_timer.timeout.connect(self.refresh_network)
        if not preview:
            self.network_timer.start(30000)

    def show_window(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def open_records_folder(self):
        folder = state_path().parent
        folder.mkdir(parents=True, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(folder)))

    def export_records(self):
        source = state_path()
        if not source.exists():
            QMessageBox.information(self, '尚无电脑记录', '请先从旧 App 的电脑备份导入，或用支持同步的新版 App 连接。')
            return
        value, _ = QFileDialog.getSaveFileName(self, '导出电脑同步库副本', 'LanCinema-records.sqlite3', 'SQLite 数据库 (*.sqlite3)')
        if not value:
            return
        destination = Path(value).resolve()
        if destination == source.resolve():
            QMessageBox.warning(self, '请选择其他位置', '不能覆盖正在使用的同步数据库。')
            return
        try:
            # SQLite's backup API also takes a consistent copy during synchronization.
            with sqlite3.connect(source.as_uri() + '?mode=ro', uri=True) as src, sqlite3.connect(destination) as dst:
                src.backup(dst)
            QMessageBox.information(self, '已导出电脑记录', '副本已保存。收藏、观看进度和偏好均在此数据库内。')
        except Exception as error:
            QMessageBox.warning(self, '未能导出', str(error))

    def import_records(self, apple):
        if self.import_worker and self.import_worker.isRunning():
            return
        if apple:
            initial = Path.home() / 'Apple/MobileSync/Backup'
            if not initial.exists():
                initial = Path(os.environ.get('APPDATA', str(Path.home()))) / 'Apple Computer/MobileSync/Backup'
            value = QFileDialog.getExistingDirectory(self, '选择包含 Manifest.db 的已完成 iPhone 备份文件夹', str(initial))
        else:
            value, _ = QFileDialog.getOpenFileName(self, '选择局域影院导出的记录备份', '', '记录备份 (*.plist)')
        if not value:
            return
        self.records_button.setEnabled(False)
        self.import_worker = RecordImportWorker(value, apple)
        self.import_worker.completed.connect(self.records_imported)
        self.import_worker.start()

    def records_imported(self, counts, error):
        self.records_button.setEnabled(True)
        if error:
            QMessageBox.warning(self, '尚未完成备份导入', error + '\n\n请保留旧 App，确认记录可恢复后再升级。')
            return
        message = (f'已处理收藏 {counts["favorite"]} 条、观看进度 {counts["history"]} 条，涉及 {counts["libraries"]} 个共享目录配置。\n'
                   f'原始记录副本：\n{counts["backup"]}\n\n'
                   '重复项保留电脑已确认的记录。升级后连接同一共享目录配置即可同步；请先核对上述数量，并保留旧 App 和备份。')
        if counts['skipped']:
            message += f'\n\n有 {counts["skipped"]} 项格式异常未导入，已保留在原始副本，请先排查再升级。'
        QMessageBox.information(self, '记录已保存到电脑并读回校验', message)

    def choose_folder(self):
        selected = self.folders.currentItem()
        initial = selected.data(Qt.UserRole) if selected else str(Path.home())
        value = QFileDialog.getExistingDirectory(self, '添加共享文件夹（可选择任意盘符）', initial)
        if value:
            self.add_folder(value)

    def add_folder(self, value):
        value = str(Path(value).resolve())
        for index in range(self.folders.count()):
            if Path(self.folders.item(index).data(Qt.UserRole)) == Path(value):
                self.folders.setCurrentRow(index)
                return
        item = QListWidgetItem(value)
        item.setData(Qt.UserRole, value)
        item.setToolTip(value)
        self.folders.addItem(item)
        self.folders.setCurrentItem(item)
        self.update_folder_state()

    def remove_folder(self):
        row = self.folders.currentRow()
        if row >= 0:
            self.folders.takeItem(row)
        self.update_folder_state()

    def update_folder_state(self, *_):
        self.remove_folder_button.setEnabled(self.folders.currentRow() >= 0)
        self.folder_hint.setText('可继续添加其他盘符的文件夹。移除仅取消共享。' if self.folders.count()
                                 else '尚未添加文件夹，请至少添加一个后保存。')

    def apply(self):
        if self.worker and self.worker.isRunning():
            return
        proposed = {'roots': [self.folders.item(i).data(Qt.UserRole) for i in range(self.folders.count())],
                    'password': self.password.text(), 'autostart': self.autostart.isChecked()}
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
            self.status.setText(f'共享已开启 · {len(settings["roots"])} 个文件夹 · 设置已保存')
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
        if self.import_worker and self.import_worker.isRunning():
            self.status.setText('正在备份记录，请稍候再退出。')
            return
        if self.worker and self.worker.isRunning():
            self.status.setText('正在保存，请稍候再退出。')
            return
        self.network_timer.stop()
        self.service.stop()
        self.tray.hide()
        QApplication.quit()


STYLE = '''
QWidget { font-family: "Microsoft YaHei UI"; font-size: 14px; color: #192b30; }
QMainWindow, QWidget#desktopContent { background: #f6f8f8; }
QLabel#title { font-size: 28px; font-weight: 600; }
QLabel#secondary { color: #52656a; font-size: 13px; }
QLabel#status { color: #006c62; font-weight: 600; padding: 8px 0; }
QGroupBox { background: white; border: 1px solid #d4dfe0; border-radius: 8px; margin-top: 12px; padding: 20px 16px 16px; }
QGroupBox::title { subcontrol-origin: margin; left: 16px; padding: 0 4px; font-weight: 600; }
QLineEdit, QComboBox { border: 1px solid #899fa4; border-radius: 5px; padding: 8px; background: white; selection-background-color: #007f75; }
QLineEdit:focus, QComboBox:focus { border: 2px solid #007f75; padding: 7px; }
QListWidget { border: 1px solid #899fa4; border-radius: 5px; background: white; }
QListWidget:focus { border: 2px solid #007f75; }
QListWidget::item { padding: 9px 8px; }
QListWidget::item:selected { background: #d7eae6; color: #192b30; }
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
