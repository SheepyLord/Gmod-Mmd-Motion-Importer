#!/usr/bin/env python3
"""Qt importer UI for baking, previewing, and caching VMD motions for GMod."""

from __future__ import annotations

import sys
import html
import json
import os
import re
import subprocess
import time
import traceback
from pathlib import Path

try:
    from PySide6 import QtCore, QtGui, QtWidgets
except Exception as exc:  # pragma: no cover - GUI dependency guard
    raise SystemExit("PySide6 is required. Install with: python -m pip install PySide6") from exc

try:
    import import_vmd
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import import_vmd  # type: ignore[no-redef]

try:
    from tools.preview.widget import PreviewWidget
except ModuleNotFoundError:
    from preview.widget import PreviewWidget  # type: ignore[no-redef]


DEFAULT_BAKE_STARTUP_SECONDS = 1.0
DEFAULT_BAKE_SECONDS_PER_FRAME = 1.0 / 1500.0
BAKE_TIMING_SAMPLE_LIMIT = 80
BAKE_TIMING_PRIOR_FRAME_COUNTS = (0, 5000, 15000, 30000)
# Bumped for the native baker so Blender-era timing samples are discarded.
BAKE_TIMING_MODEL_VERSION = 3
BAKED_FRAMES_PATTERN = re.compile(r"Baked frames (\d+)\.\.(\d+) of (\d+)")


def bundled_resource_path(*parts: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
    return base.joinpath(*parts)


class ImporterI18N:
    def __init__(self) -> None:
        self.language = "en"
        self.fallback = self._load_catalog("en")
        self.catalog = dict(self.fallback)

    def i18n_dir(self) -> Path:
        return bundled_resource_path("tools", "i18n")

    def _load_catalog(self, language: str) -> dict[str, str]:
        path = self.i18n_dir() / f"{language}.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        return {str(key): str(value) for key, value in data.items()}

    def available_languages(self) -> list[tuple[str, str]]:
        languages: list[tuple[str, str]] = []
        i18n_path = self.i18n_dir()
        for path in sorted(i18n_path.glob("*.json")) if i18n_path.exists() else []:
            code = path.stem
            catalog = self._load_catalog(code)
            languages.append((code, catalog.get("language.name", code)))
        return languages or [("en", self.fallback.get("language.name", "English"))]

    def set_language(self, language: str) -> None:
        language = str(language or "en").replace("-", "_").split("_", 1)[0].lower()
        catalog = self._load_catalog(language)
        if not catalog:
            language = "en"
            catalog = dict(self.fallback)
        self.language = language
        self.catalog = catalog

    def t(self, key: str, **kwargs: object) -> str:
        text = self.catalog.get(key, self.fallback.get(key, key))
        if kwargs:
            try:
                return text.format(**kwargs)
            except Exception:
                return text
        return text


I18N = ImporterI18N()


class ImportWorker(QtCore.QThread):
    log = QtCore.Signal(str)
    done = QtCore.Signal(dict)
    failed = QtCore.Signal(str)

    def __init__(self, settings: dict[str, object]) -> None:
        super().__init__()
        self.settings = settings
        self.cancel_requested = False

    def cancel(self) -> None:
        self.cancel_requested = True

    def _cancelled(self) -> bool:
        return self.cancel_requested

    def _log(self, message: str) -> None:
        self.log.emit(message)

    def run(self) -> None:
        try:
            body_vmd = Path(str(self.settings["body_vmd"]))
            if not body_vmd.exists():
                raise FileNotFoundError(I18N.t("error.select_body_vmd"))

            gmod_dir = Path(str(self.settings["gmod_dir"])) if self.settings.get("gmod_dir") else import_vmd.find_gmod_install()
            self._log(I18N.t("log.using_gmod", path=gmod_dir))

            # Build the camera track before the bake so a missing or corrupt
            # camera VMD fails fast instead of after the bake.
            camera_track = None
            camera_path_raw = str(self.settings.get("camera_vmd") or "")
            if camera_path_raw:
                camera_path = Path(camera_path_raw)
                if not camera_path.exists():
                    raise FileNotFoundError(I18N.t("error.camera_vmd_missing", path=camera_path_raw))
                camera_track = import_vmd.build_camera_track(camera_path, self._log)

            model_path = import_vmd.find_default_mmd_model()
            flex_vmds = [Path(str(path)) for path in self.settings.get("flex_vmds", [])]
            motion_name = str(self.settings.get("motion_name") or "").strip()
            audio_offset = float(self.settings.get("audio_offset") or 0.0)

            unify_ground = bool(self.settings.get("unify_ground"))
            try:
                rotation_document = import_vmd.bake_vmd_native(
                    body_vmd,
                    mmd_model=model_path,
                    progress=self._log,
                    cancel_check=self._cancelled,
                    disable_foot_ik=bool(self.settings.get("disable_foot_ik")),
                    unify_ground=unify_ground,
                )
            except RuntimeError:
                if self.cancel_requested:
                    raise RuntimeError(I18N.t("error.import_cancelled"))
                raise
            if self.cancel_requested:
                raise RuntimeError(I18N.t("error.import_cancelled"))
            ground_offsets = import_vmd.rotation_ground_offsets(rotation_document) if unify_ground else None
            if camera_track is not None and ground_offsets:
                # Lower the camera with the character every frame so it keeps
                # framing the dancer after the stage heights are cancelled.
                camera_track = import_vmd.build_camera_track(Path(camera_path_raw), self._log, ground_offsets=ground_offsets)

            music_metadata = None
            music_path_raw = str(self.settings.get("music_path") or "")
            motion_name_source = motion_name or body_vmd
            if music_path_raw:
                music_metadata = import_vmd.convert_music_to_gmod_mp3(Path(music_path_raw), gmod_dir, motion_name_source, self._log, vmd_path=body_vmd)

            output_dir = gmod_dir / "garrysmod" / "data" / "mmd_vmd_npc" / "motions"
            output_json = import_vmd.write_motion_json(
                rotation_document,
                output_dir,
                motion_name_source,
                body_vmd,
                extra_flex_vmd_paths=flex_vmds,
                music=music_metadata,
                audio_offset=audio_offset,
                is_addon=bool(self.settings.get("export_addon")),
                progress=self._log,
                camera_track=camera_track,
                meta=dict(self.settings.get("motion_meta") or {}),
            )
            self._log(I18N.t("log.wrote_motion_json", path=output_json))
            addon_gma = ""
            if self.settings.get("export_addon"):
                addon_gma_path = Path(str(self.settings.get("addon_gma_path") or ""))
                if not str(addon_gma_path):
                    raise RuntimeError(I18N.t("error.select_gma_output"))
                addon_output = import_vmd.export_motion_addon_gma(
                    output_json,
                    music_metadata,
                    gmod_dir,
                    motion_name_source,
                    addon_gma_path,
                    self._log,
                )
                addon_gma = str(addon_output)
            result = {
                "motion_json": str(output_json),
                "addon_gma": addon_gma,
                "motion_name": motion_name,
                "music": music_metadata or {},
            }
            self.done.emit(result)
        except Exception as exc:
            self.failed.emit(str(exc) + "\n\n" + traceback.format_exc())


class ManagerScanWorker(QtCore.QThread):
    """Scans the installed-motions folder off the UI thread. Reuses a per-file
    (mtime, size)-keyed header cache so repeat scans only re-read changed files."""

    results = QtCore.Signal(list)
    failed = QtCore.Signal(str)

    def __init__(self, motions_dir: Path, cache: dict) -> None:
        super().__init__()
        self.motions_dir = motions_dir
        # Snapshot so the worker never races the main thread's live cache.
        self.cache = dict(cache)

    def run(self) -> None:
        try:
            rows: list[dict] = []
            for path in sorted(self.motions_dir.glob("*.json")):
                if path.name.startswith("."):
                    continue
                try:
                    stat = path.stat()
                except OSError:
                    continue
                key = str(path)
                cached = self.cache.get(key)
                header: dict | None = None
                error: str | None = None
                if cached and cached.get("mtime") == stat.st_mtime and cached.get("size") == stat.st_size:
                    header = cached.get("header")
                if header is None:
                    try:
                        header = import_vmd.read_motion_header(path)
                    except Exception as exc:  # a single corrupt file must not fail the scan
                        error = str(exc)
                rows.append({
                    "path": key,
                    "mtime": stat.st_mtime,
                    "size": stat.st_size,
                    "header": header,
                    "error": error,
                })
            self.results.emit(rows)
        except Exception as exc:
            self.failed.emit(str(exc))


class SortableTableItem(QtWidgets.QTableWidgetItem):
    """Table cell that sorts by an explicit numeric key while showing formatted
    text (so '1:23' / '2.5 MB' columns sort by real magnitude, not lexically)."""

    def __init__(self, text: str, sort_key: float) -> None:
        super().__init__(text)
        self.sort_key = sort_key
        self.setFlags(QtCore.Qt.ItemFlag.ItemIsSelectable | QtCore.Qt.ItemFlag.ItemIsEnabled)

    def __lt__(self, other: QtWidgets.QTableWidgetItem) -> bool:
        if isinstance(other, SortableTableItem):
            return self.sort_key < other.sort_key
        return super().__lt__(other)


class PathRow(QtWidgets.QWidget):
    pathBrowsed = QtCore.Signal(str)

    def __init__(
        self,
        label: str,
        mode: str,
        file_filter: str = "All files (*.*)",
        default: str = "",
        required: bool = False,
        hint: str = "",
        required_text: str = "Required",
        optional_text: str = "Optional",
        browse_text: str = "Browse",
        select_folder_title: str = "Select folder",
        select_file_title: str = "Select file",
    ) -> None:
        super().__init__()
        self.mode = mode
        self.file_filter = file_filter
        self.required = required
        self.select_folder_title = select_folder_title
        self.select_file_title = select_file_title
        self.label = QtWidgets.QLabel(label)
        self.badge = QtWidgets.QLabel(required_text if required else optional_text)
        self.badge.setObjectName("requiredBadge" if required else "optionalBadge")
        self.hint = QtWidgets.QLabel(hint)
        self.hint.setObjectName("fieldHint")
        # Wrap long (translated) hints instead of forcing the whole form wider;
        # ignore the hint's width preference so it never inflates the min size.
        self.hint.setWordWrap(True)
        self.hint.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored, QtWidgets.QSizePolicy.Policy.Preferred)
        self.edit = QtWidgets.QLineEdit(default)
        self.button = QtWidgets.QPushButton(browse_text)
        layout = QtWidgets.QGridLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        header = QtWidgets.QHBoxLayout()
        header.addWidget(self.label)
        header.addWidget(self.badge)
        header.addWidget(self.hint, 1)
        layout.addLayout(header, 0, 0, 1, 3)
        layout.addWidget(self.edit, 1, 0, 1, 2)
        layout.addWidget(self.button, 1, 2)
        layout.setColumnStretch(1, 1)
        self.button.clicked.connect(self.browse)

    def value(self) -> str:
        return self.edit.text().strip()

    def set_value(self, value: str) -> None:
        self.edit.setText(value)

    def browse(self) -> None:
        if self.mode == "dir":
            path = QtWidgets.QFileDialog.getExistingDirectory(self, self.select_folder_title, self.value())
        else:
            path, _ = QtWidgets.QFileDialog.getOpenFileName(self, self.select_file_title, self.value(), self.file_filter)
        if path:
            self.set_value(path)
            self.pathBrowsed.emit(path)

    def retranslate(
        self,
        label: str,
        file_filter: str,
        required_text: str,
        optional_text: str,
        browse_text: str,
        select_folder_title: str,
        select_file_title: str,
        hint: str = "",
    ) -> None:
        self.file_filter = file_filter
        self.select_folder_title = select_folder_title
        self.select_file_title = select_file_title
        self.label.setText(label)
        self.badge.setText(required_text if self.required else optional_text)
        self.hint.setText(hint)
        self.button.setText(browse_text)


class ImporterWindow(QtWidgets.QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.worker: ImportWorker | None = None
        self.settings_store = QtCore.QSettings("MMDVMDNPC", "Importer")
        self.i18n = I18N
        stored_language = str(self.settings_store.value("language", "", str) or "").strip()
        initial_language = stored_language or self.system_language_code()
        self.i18n.set_language(initial_language)
        self._apply_layout_direction(initial_language)
        self.setWindowTitle(self.tr("app.title"))
        self.apply_startup_geometry()
        self._loading_settings = False
        self._syncing_audio_offset = False
        self._motion_name_autofill = ""
        self.import_started_at = 0.0
        self.import_estimate_seconds = 0.0
        self.import_estimate_frames = 0
        self.import_estimate_detail = ""
        self.progress_floor = 0
        self.progress_stage = "Idle"
        self.progress_color = "#8f98a3"
        self.current_preview_frame = 0
        self.current_preview_seconds = 0.0
        self.path_rows: list[tuple[PathRow, str, str, bool, str]] = []
        self.output_title_labels: dict[str, QtWidgets.QLabel] = {}
        self.progress_timer = QtCore.QTimer(self)
        self.progress_timer.timeout.connect(self.update_import_progress)
        # Appending log lines to the QPlainTextEdit one at a time re-lays-out the
        # widget every line and makes the UI stutter on chatty steps. Buffer the
        # raw text and flush it in batches (~10 Hz); progress-bar detection still
        # runs per line so feedback stays live.
        self._log_buffer: list[str] = []
        self._log_flush_timer = QtCore.QTimer(self)
        self._log_flush_timer.setInterval(100)
        self._log_flush_timer.timeout.connect(self._flush_log_buffer)
        self._log_flush_timer.start()

        icon_path = self.importer_icon_path()
        if icon_path.exists():
            self.setWindowIcon(QtGui.QIcon(str(icon_path)))

        self.tabs = QtWidgets.QTabWidget()
        self.setCentralWidget(self.tabs)
        self.output_labels: dict[str, QtWidgets.QLabel] = {}

        # Motion Manager state.
        self._manager_worker: ManagerScanWorker | None = None
        self._manager_cache: dict = self._load_manager_index()
        self._manager_rows: list[dict] = []
        self._manager_scanned_once = False
        self._manager_refresh_pending = False

        self._build_inputs_tab()
        self._build_preview_tab()
        self._build_manager_tab()
        self.tabs.currentChanged.connect(self._on_tab_changed)
        self._apply_style()
        self._load_persisted_settings()
        self._wire_persisted_settings()
        QtCore.QTimer.singleShot(0, self.auto_detect_missing_paths)
        self.statusBar().showMessage(self.tr("status.ready"))

    def tr(self, key: str, **kwargs: object) -> str:
        return self.i18n.t(key, **kwargs)

    def apply_startup_geometry(self) -> None:
        app = QtWidgets.QApplication.instance()
        screen = app.primaryScreen() if app is not None else None
        if screen is None:
            self.setMinimumSize(900, 580)
            self.resize(1180, 720)
            return

        available = screen.availableGeometry()
        usable_width = max(760, available.width() - 40)
        usable_height = max(520, available.height() - 80)
        target_width = min(1180, usable_width)
        target_height = min(720, usable_height)
        min_width = min(900, usable_width)
        min_height = min(580, usable_height)

        self.setMinimumSize(min_width, min_height)
        self.resize(target_width, target_height)
        self.move(
            available.x() + max(0, (available.width() - target_width) // 2),
            available.y() + max(0, (available.height() - target_height) // 2),
        )

    def system_language_code(self) -> str:
        language = QtCore.QLocale.system().name().replace("-", "_").split("_", 1)[0].lower()
        available = {code for code, _name in self.i18n.available_languages()}
        return language if language in available else "en"

    def importer_icon_path(self) -> Path:
        return import_vmd.ROOT / "tools" / "assets" / "importer_icon.ico"

    def default_model_path(self) -> str:
        try:
            return str(import_vmd.find_default_mmd_model())
        except Exception:
            return ""

    def _apply_style(self) -> None:
        self.setStyleSheet(
            """
            QLabel#requiredBadge {
                background: #1f6feb;
                color: white;
                border-radius: 4px;
                padding: 2px 7px;
                font-weight: 600;
            }
            QLabel#optionalBadge {
                background: #3a3a3a;
                color: #d7d7d7;
                border-radius: 4px;
                padding: 2px 7px;
            }
            QLabel#fieldHint {
                color: #8f98a3;
            }
            QPushButton#importButton,
            QPushButton#previewButton {
                font-size: 16px;
                font-weight: 700;
                padding: 10px 18px;
            }
            QPushButton#previewPlayButton {
                background: #238636;
                color: white;
                border: 1px solid #2ea043;
                border-radius: 6px;
                font-size: 17px;
                font-weight: 800;
                padding: 8px 22px;
            }
            QPushButton#previewPlayButton:hover {
                background: #2ea043;
            }
            QPushButton#previewPlayButton:pressed {
                background: #196c2e;
            }
            QLabel#progressStatus {
                font-weight: 600;
            }
            """
        )

    def _build_language_panel(self) -> QtWidgets.QGroupBox:
        self.language_group = QtWidgets.QGroupBox(self.tr("language.panel.title"))
        layout = QtWidgets.QGridLayout(self.language_group)
        self.language_combo = QtWidgets.QComboBox()
        for code, name in self.i18n.available_languages():
            self.language_combo.addItem(name, code)
        current = self.i18n.language
        current_index = self.language_combo.findData(current)
        if current_index >= 0:
            self.language_combo.setCurrentIndex(current_index)

        self.language_hint = QtWidgets.QLabel(self.tr("language.panel.hint"))
        self.language_hint.setObjectName("fieldHint")
        self.language_hint.setWordWrap(True)
        self.language_title_label = QtWidgets.QLabel(self.tr("language.panel.title"))
        layout.addWidget(self.language_title_label, 0, 0)
        layout.addWidget(self.language_combo, 0, 1)
        layout.addWidget(self.language_hint, 1, 0, 1, 2)
        layout.setColumnStretch(1, 1)
        self.language_combo.currentIndexChanged.connect(self.change_language)
        return self.language_group

    def _apply_layout_direction(self, code: str) -> None:
        # Arabic (and any future RTL catalog) needs a right-to-left UI; without
        # this the whole layout renders mirrored-wrong left-to-right.
        app = QtWidgets.QApplication.instance()
        if app is None:
            return
        rtl = str(code or "").lower() in {"ar", "he", "fa", "ur"}
        app.setLayoutDirection(
            QtCore.Qt.LayoutDirection.RightToLeft if rtl else QtCore.Qt.LayoutDirection.LeftToRight
        )

    def change_language(self) -> None:
        if not hasattr(self, "language_combo"):
            return
        code = str(self.language_combo.currentData() or "en")
        self.i18n.set_language(code)
        self._apply_layout_direction(code)
        self.settings_store.setValue("language", code)
        self.settings_store.sync()
        self.retranslate_ui()
        self.statusBar().showMessage(
            self.tr("status.language_saved", language=self.language_combo.currentText())
        )

    def retranslate_path_rows(self) -> None:
        for row, label_key, file_filter_key, _required, hint_key in self.path_rows:
            row.retranslate(
                self.tr(label_key),
                self.tr(file_filter_key),
                self.tr("field.required"),
                self.tr("field.optional"),
                self.tr("button.browse"),
                self.tr("dialog.select_folder"),
                self.tr("dialog.select_file"),
                self.tr(hint_key) if hint_key else "",
            )

    def retranslate_ui(self) -> None:
        self.setWindowTitle(self.tr("app.title"))
        app = QtWidgets.QApplication.instance()
        if app is not None:
            app.setApplicationName(self.tr("app.title"))
        if hasattr(self, "tabs"):
            self.tabs.setTabText(0, self.tr("tab.inputs"))
            self.tabs.setTabText(1, self.tr("tab.preview"))
            self.tabs.setTabText(2, self.tr("tab.manager"))
        self.retranslate_manager()

        if hasattr(self, "language_group"):
            self.language_group.setTitle(self.tr("language.panel.title"))
            self.language_title_label.setText(self.tr("language.panel.title"))
            self.language_hint.setText(self.tr("language.panel.hint"))

        self.retranslate_path_rows()

        if hasattr(self, "motion_meta_label"):
            self.motion_meta_label.setText(self.tr("inputs.motion_meta.label"))
            self.motion_meta_badge.setText(self.tr("field.optional"))
            self.motion_meta_hint.setText(self.tr("inputs.motion_meta.hint"))
            self._retranslate_motion_meta_headers()
        if hasattr(self, "flex_group"):
            self.flex_group.setTitle(self.tr("inputs.flex_group.title"))
            self.add_flex_button.setText(self.tr("inputs.flex.add"))
            self.remove_flex_button.setText(self.tr("inputs.flex.remove"))

        for attr, key in (
            ("detect_gmod_button", "inputs.detect_gmod"),
            ("preview_button", "inputs.preview_motion"),
            ("import_button", "inputs.bake_import"),
            ("cancel_button", "inputs.cancel_import"),
            ("copy_log_button", "inputs.copy_log"),
            ("play_button", "preview.play"),
            ("pause_button", "preview.pause"),
            ("reset_view_button", "preview.reset_view"),
            ("loop_check", "preview.loop"),
            ("audio_check", "preview.audio"),
            ("bone_overlay_check", "preview.bones"),
            ("bone_names_check", "preview.bone_names"),
            ("follow_camera_check", "preview.follow_camera"),
        ):
            widget = getattr(self, attr, None)
            if widget is not None:
                widget.setText(self.tr(key))

        if hasattr(self, "follow_camera_check"):
            self.follow_camera_check.setToolTip(self.tr("preview.follow_camera.tooltip"))

        if hasattr(self, "detect_gmod_button"):
            self.detect_gmod_button.setToolTip(self.tr("inputs.detect_gmod.tooltip"))
            self.export_addon_check.setText(self.tr("inputs.export_addon"))
            self.export_addon_check.setToolTip(self.tr("inputs.export_addon.tooltip"))
            self.disable_foot_ik_check.setText(self.tr("inputs.disable_foot_ik"))
            self.disable_foot_ik_check.setToolTip(self.tr("inputs.disable_foot_ik.tooltip"))
            self.unify_ground_check.setText(self.tr("inputs.unify_ground"))
            self.unify_ground_check.setToolTip(self.tr("inputs.unify_ground.tooltip"))
            self.input_audio_offset_slider.setToolTip(self.tr("inputs.audio_offset.tooltip"))
            self.audio_offset_slider.setToolTip(self.tr("preview.audio_offset.tooltip"))

        self.set_audio_offset_value(int(round(self.current_audio_offset_seconds() * 100)))

        if hasattr(self, "progress_group"):
            self.progress_group.setTitle(self.tr("inputs.progress.title"))
            self.preview_progress_group.setTitle(self.tr("inputs.progress.title"))
            if self.import_started_at <= 0 and self.progress_bar.value() == 0:
                self.progress_label.setText(self.tr("inputs.progress.idle"))
                self.preview_progress_label.setText(self.tr("inputs.progress.idle"))
        if hasattr(self, "log_group"):
            self.log_group.setTitle(self.tr("inputs.log_output.title"))
            for key, label in (
                ("motion_json", self.tr("inputs.output.motion_json")),
                ("addon_gma", self.tr("inputs.output.addon_gma")),
                ("music", self.tr("inputs.output.music")),
            ):
                if key in self.output_title_labels:
                    self.output_title_labels[key].setText(label)

        if hasattr(self, "preview_link_hint"):
            self.preview_link_hint.setText(self.tr("preview.link_hint"))
            self.preview_audio_offset_hint.setText(self.tr("preview.audio_offset_hint"))
            self.preview_speed_label.setText(self.tr("preview.speed"))
            if self.current_preview_frame or self.current_preview_seconds:
                self.frame_label.setText(
                    self.tr("preview.frame_label", frame=self.current_preview_frame, seconds=self.current_preview_seconds)
                )
            else:
                self.frame_label.setText(self.tr("preview.frame_initial"))
            if self.preview_status_label.text() == self.i18n.fallback.get("preview.status_idle"):
                self.preview_status_label.setText(self.tr("preview.status_idle"))

    def make_path_row(
        self,
        label_key: str,
        mode: str,
        file_filter_key: str = "filter.all_files",
        required: bool = False,
        hint_key: str = "",
    ) -> PathRow:
        row = PathRow(
            self.tr(label_key),
            mode,
            self.tr(file_filter_key),
            required=required,
            hint=self.tr(hint_key) if hint_key else "",
            required_text=self.tr("field.required"),
            optional_text=self.tr("field.optional"),
            browse_text=self.tr("button.browse"),
            select_folder_title=self.tr("dialog.select_folder"),
            select_file_title=self.tr("dialog.select_file"),
        )
        self.path_rows.append((row, label_key, file_filter_key, required, hint_key))
        return row

    def _build_inputs_tab(self) -> None:
        tab = QtWidgets.QWidget()
        tab_layout = QtWidgets.QVBoxLayout(tab)
        tab_layout.setContentsMargins(0, 0, 0, 0)
        self.inputs_scroll = QtWidgets.QScrollArea()
        self.inputs_scroll.setWidgetResizable(True)
        self.inputs_scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        content = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(content)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        layout.addWidget(self._build_language_panel())

        self.body_row = self.make_path_row("inputs.body_vmd.label", "file", "filter.vmd_motion", required=True, hint_key="inputs.body_vmd.hint")
        self.gmod_row = self.make_path_row("inputs.gmod.label", "dir", required=True, hint_key="inputs.gmod.hint")
        self.music_row = self.make_path_row("inputs.music.label", "file", "filter.media", required=False, hint_key="inputs.music.hint")
        self.camera_row = self.make_path_row("inputs.camera_vmd.label", "file", "filter.vmd_motion", required=False, hint_key="inputs.camera_vmd.hint")
        for row in (self.body_row, self.gmod_row, self.music_row, self.camera_row):
            layout.addWidget(row)

        audio_offset_layout = QtWidgets.QGridLayout()
        self.input_audio_offset_label = QtWidgets.QLabel(self.tr("inputs.audio_offset.label", seconds=0.0))
        self.input_audio_offset_hint = QtWidgets.QLabel(self.tr("inputs.audio_offset.hint"))
        self.input_audio_offset_hint.setObjectName("fieldHint")
        self.input_audio_offset_slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.input_audio_offset_slider.setRange(-500, 500)
        self.input_audio_offset_slider.setValue(0)
        self.input_audio_offset_slider.setTickInterval(50)
        self.input_audio_offset_slider.setToolTip(self.tr("inputs.audio_offset.tooltip"))
        self.input_audio_offset_slider.valueChanged.connect(self.update_input_audio_offset)
        audio_offset_layout.addWidget(self.input_audio_offset_label, 0, 0)
        audio_offset_layout.addWidget(self.input_audio_offset_hint, 0, 1)
        audio_offset_layout.addWidget(self.input_audio_offset_slider, 1, 0, 1, 2)
        audio_offset_layout.setColumnStretch(1, 1)
        layout.addLayout(audio_offset_layout)

        name_layout = QtWidgets.QGridLayout()
        name_header = QtWidgets.QHBoxLayout()
        self.motion_meta_label = QtWidgets.QLabel(self.tr("inputs.motion_meta.label"))
        self.motion_meta_badge = QtWidgets.QLabel(self.tr("field.optional"))
        self.motion_meta_badge.setObjectName("optionalBadge")
        self.motion_meta_hint = QtWidgets.QLabel(self.tr("inputs.motion_meta.hint"))
        self.motion_meta_hint.setObjectName("fieldHint")
        name_header.addWidget(self.motion_meta_label)
        name_header.addWidget(self.motion_meta_badge)
        name_header.addWidget(self.motion_meta_hint, 1)
        self.motion_meta_table = QtWidgets.QTableWidget(1, len(import_vmd.MOTION_META_FIELDS))
        self.motion_meta_table.verticalHeader().setVisible(False)
        self.motion_meta_table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.Stretch)
        self.motion_meta_table.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.motion_meta_table.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.motion_meta_table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        self.motion_meta_table.setTabKeyNavigation(True)
        for column in range(len(import_vmd.MOTION_META_FIELDS)):
            self.motion_meta_table.setItem(0, column, QtWidgets.QTableWidgetItem(""))
        self._retranslate_motion_meta_headers()
        # One header row + one editable row; lock the height so the table reads
        # as a form field instead of a grid that grabs vertical space.
        self.motion_meta_table.resizeRowsToContents()
        meta_table_height = (
            self.motion_meta_table.horizontalHeader().sizeHint().height()
            + self.motion_meta_table.rowHeight(0)
            + 2 * self.motion_meta_table.frameWidth()
        )
        self.motion_meta_table.setFixedHeight(meta_table_height)
        name_layout.addLayout(name_header, 0, 0)
        name_layout.addWidget(self.motion_meta_table, 1, 0)
        layout.addLayout(name_layout)

        self.flex_group = QtWidgets.QGroupBox(self.tr("inputs.flex_group.title"))
        self.flex_group.setMaximumHeight(120)
        flex_layout = QtWidgets.QVBoxLayout(self.flex_group)
        flex_layout.setContentsMargins(8, 8, 8, 8)
        flex_layout.setSpacing(6)
        self.flex_list = QtWidgets.QListWidget()
        self.flex_list.setMaximumHeight(52)
        flex_buttons = QtWidgets.QHBoxLayout()
        self.add_flex_button = QtWidgets.QPushButton(self.tr("inputs.flex.add"))
        self.remove_flex_button = QtWidgets.QPushButton(self.tr("inputs.flex.remove"))
        self.add_flex_button.clicked.connect(self.add_flex_vmds)
        self.remove_flex_button.clicked.connect(self.remove_selected_flex_vmds)
        flex_buttons.addWidget(self.add_flex_button)
        flex_buttons.addWidget(self.remove_flex_button)
        flex_buttons.addStretch(1)
        flex_layout.addWidget(self.flex_list)
        flex_layout.addLayout(flex_buttons)
        layout.addWidget(self.flex_group)

        actions = QtWidgets.QHBoxLayout()
        self.detect_gmod_button = QtWidgets.QPushButton(self.tr("inputs.detect_gmod"))
        self.detect_gmod_button.setToolTip(self.tr("inputs.detect_gmod.tooltip"))
        self.preview_button = QtWidgets.QPushButton(self.tr("inputs.preview_motion"))
        self.preview_button.setObjectName("previewButton")
        self.preview_button.setMinimumHeight(48)
        self.import_button = QtWidgets.QPushButton(self.tr("inputs.bake_import"))
        self.import_button.setObjectName("importButton")
        self.import_button.setMinimumHeight(48)
        self.export_addon_check = QtWidgets.QCheckBox(self.tr("inputs.export_addon"))
        self.export_addon_check.setToolTip(self.tr("inputs.export_addon.tooltip"))
        self.disable_foot_ik_check = QtWidgets.QCheckBox(self.tr("inputs.disable_foot_ik"))
        self.disable_foot_ik_check.setToolTip(self.tr("inputs.disable_foot_ik.tooltip"))
        self.unify_ground_check = QtWidgets.QCheckBox(self.tr("inputs.unify_ground"))
        self.unify_ground_check.setToolTip(self.tr("inputs.unify_ground.tooltip"))
        self.cancel_button = QtWidgets.QPushButton(self.tr("inputs.cancel_import"))
        self.cancel_button.setEnabled(False)
        self.detect_gmod_button.clicked.connect(self.detect_gmod)
        self.preview_button.clicked.connect(self.load_preview)
        self.import_button.clicked.connect(self.start_import)
        self.cancel_button.clicked.connect(self.cancel_import)
        for button in (self.detect_gmod_button, self.preview_button, self.import_button):
            actions.addWidget(button)
        actions.addWidget(self.export_addon_check)
        actions.addWidget(self.cancel_button)
        actions.addStretch(1)
        layout.addLayout(actions)
        bake_options = QtWidgets.QHBoxLayout()
        bake_options.addWidget(self.disable_foot_ik_check)
        bake_options.addWidget(self.unify_ground_check)
        bake_options.addStretch(1)
        layout.addLayout(bake_options)

        self.progress_group = QtWidgets.QGroupBox(self.tr("inputs.progress.title"))
        progress_layout = QtWidgets.QVBoxLayout(self.progress_group)
        self.progress_bar = QtWidgets.QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_label = QtWidgets.QLabel(self.tr("inputs.progress.idle"))
        self.progress_label.setObjectName("progressStatus")
        self.progress_label.setTextFormat(QtCore.Qt.TextFormat.RichText)
        self.progress_label.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        progress_layout.addWidget(self.progress_bar)
        progress_layout.addWidget(self.progress_label)
        layout.addWidget(self.progress_group)

        self.log_group = QtWidgets.QGroupBox(self.tr("inputs.log_output.title"))
        log_layout = QtWidgets.QVBoxLayout(self.log_group)
        output_layout = QtWidgets.QFormLayout()
        for key, label in (
            ("motion_json", self.tr("inputs.output.motion_json")),
            ("addon_gma", self.tr("inputs.output.addon_gma")),
            ("music", self.tr("inputs.output.music")),
        ):
            title = QtWidgets.QLabel(label)
            value = QtWidgets.QLabel("")
            value.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
            self.output_title_labels[key] = title
            self.output_labels[key] = value
            output_layout.addRow(title, value)
        log_layout.addLayout(output_layout)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMinimumHeight(80)
        # Cap retained lines so a very long bake log stays cheap to render; old
        # lines scroll off automatically (the full text is still copyable live).
        self.log.setMaximumBlockCount(6000)
        self.copy_log_button = QtWidgets.QPushButton(self.tr("inputs.copy_log"))
        self.copy_log_button.clicked.connect(self.copy_log_to_clipboard)
        log_layout.addWidget(self.log, 1)
        log_layout.addWidget(self.copy_log_button, 0, QtCore.Qt.AlignRight)
        layout.addWidget(self.log_group, 1)

        self.inputs_scroll.setWidget(content)
        tab_layout.addWidget(self.inputs_scroll)
        self.tabs.addTab(tab, self.tr("tab.inputs"))

    def _build_preview_tab(self) -> None:
        tab = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(tab)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)
        self.preview_link_hint = QtWidgets.QLabel(
            self.tr("preview.link_hint")
        )
        self.preview_link_hint.setStyleSheet("color: #ffd33d; font-weight: 700;")
        self.preview_link_hint.setWordWrap(True)
        layout.addWidget(self.preview_link_hint)
        self.preview = PreviewWidget()
        # The preview is a native QOpenGLWindow inside a container so OpenGL
        # never forces the whole top-level window into GPU compositing (which
        # made every text-field repaint app-wide several times slower).
        self.preview_tab = tab
        self.preview_container = QtWidgets.QWidget.createWindowContainer(self.preview, tab)
        self.preview_container.setMinimumSize(480, 300)
        layout.addWidget(self.preview_container, 1)
        controls_top = QtWidgets.QHBoxLayout()
        controls_top.setSpacing(8)
        controls_scrub = QtWidgets.QHBoxLayout()
        controls_scrub.setSpacing(8)
        self.play_button = QtWidgets.QPushButton(self.tr("preview.play"))
        self.play_button.setObjectName("previewPlayButton")
        self.play_button.setMinimumSize(120, 44)
        self.pause_button = QtWidgets.QPushButton(self.tr("preview.pause"))
        self.reset_view_button = QtWidgets.QPushButton(self.tr("preview.reset_view"))
        self.loop_check = QtWidgets.QCheckBox(self.tr("preview.loop"))
        self.loop_check.setChecked(False)
        self.audio_check = QtWidgets.QCheckBox(self.tr("preview.audio"))
        self.audio_check.setChecked(True)
        self.bone_overlay_check = QtWidgets.QCheckBox(self.tr("preview.bones"))
        self.bone_overlay_check.setChecked(False)
        self.bone_names_check = QtWidgets.QCheckBox(self.tr("preview.bone_names"))
        self.bone_names_check.setChecked(False)
        self.follow_camera_check = QtWidgets.QCheckBox(self.tr("preview.follow_camera"))
        self.follow_camera_check.setChecked(True)
        self.follow_camera_check.setToolTip(self.tr("preview.follow_camera.tooltip"))
        self.speed_spin = QtWidgets.QDoubleSpinBox()
        self.speed_spin.setRange(0.05, 4.0)
        self.speed_spin.setValue(1.0)
        self.speed_spin.setSingleStep(0.05)
        self.scrubber = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.scrubber.setRange(0, 1000)
        self.frame_label = QtWidgets.QLabel(self.tr("preview.frame_initial"))
        self.audio_offset_label = QtWidgets.QLabel(self.tr("inputs.audio_offset.label", seconds=0.0))
        self.audio_offset_slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        self.audio_offset_slider.setRange(-500, 500)
        self.audio_offset_slider.setValue(0)
        self.audio_offset_slider.setTickInterval(50)
        self.audio_offset_slider.setToolTip(self.tr("preview.audio_offset.tooltip"))
        self.preview_status_label = QtWidgets.QLabel(self.tr("preview.status_idle"))
        self.preview_status_label.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        self.preview_speed_label = QtWidgets.QLabel(self.tr("preview.speed"))
        self.play_button.clicked.connect(self.preview.play)
        self.pause_button.clicked.connect(self.preview.pause)
        self.reset_view_button.clicked.connect(self.preview.reset_front_view)
        self.loop_check.toggled.connect(self.preview.set_loop)
        self.audio_check.toggled.connect(self.preview.set_audio_enabled)
        self.bone_overlay_check.toggled.connect(self.preview.set_bone_overlay_enabled)
        self.bone_names_check.toggled.connect(self.preview.set_bone_names_enabled)
        self.follow_camera_check.toggled.connect(self.preview.set_follow_camera)
        self.speed_spin.valueChanged.connect(self.preview.set_speed)
        self.scrubber.sliderMoved.connect(lambda value: self.preview.scrub_to_fraction(value / 1000.0))
        self.audio_offset_slider.valueChanged.connect(self.update_preview_audio_offset)
        self.preview.frameChanged.connect(self.update_preview_frame)
        self.preview.statsChanged.connect(self.preview_status_label.setText)
        for widget in (
            self.play_button,
            self.pause_button,
            self.reset_view_button,
            self.loop_check,
            self.audio_check,
            self.bone_overlay_check,
            self.bone_names_check,
            self.follow_camera_check,
            self.preview_speed_label,
            self.speed_spin,
        ):
            controls_top.addWidget(widget)
        controls_top.addStretch(1)
        controls_scrub.addWidget(self.scrubber, 1)
        controls_scrub.addWidget(self.frame_label)
        layout.addLayout(controls_top)
        layout.addLayout(controls_scrub)
        audio_controls = QtWidgets.QHBoxLayout()
        audio_controls.addWidget(self.audio_offset_label)
        audio_controls.addWidget(self.audio_offset_slider, 1)
        layout.addLayout(audio_controls)
        self.preview_audio_offset_hint = QtWidgets.QLabel(
            self.tr("preview.audio_offset_hint")
        )
        self.preview_audio_offset_hint.setStyleSheet("color: #b77dff; font-weight: 600;")
        self.preview_audio_offset_hint.setWordWrap(True)
        layout.addWidget(self.preview_audio_offset_hint)

        self.preview_progress_group = QtWidgets.QGroupBox(self.tr("inputs.progress.title"))
        preview_progress_layout = QtWidgets.QVBoxLayout(self.preview_progress_group)
        self.preview_progress_bar = QtWidgets.QProgressBar()
        self.preview_progress_bar.setRange(0, 100)
        self.preview_progress_label = QtWidgets.QLabel(self.tr("inputs.progress.idle"))
        self.preview_progress_label.setObjectName("progressStatus")
        self.preview_progress_label.setTextFormat(QtCore.Qt.TextFormat.RichText)
        self.preview_progress_label.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        preview_progress_layout.addWidget(self.preview_progress_bar)
        preview_progress_layout.addWidget(self.preview_progress_label)
        layout.addWidget(self.preview_progress_group)

        layout.addWidget(self.preview_status_label)
        self.tabs.addTab(tab, self.tr("tab.preview"))

    def add_flex_vmds(self) -> None:
        paths, _ = QtWidgets.QFileDialog.getOpenFileNames(
            self,
            self.tr("dialog.select_flex_vmds"),
            "",
            self.tr("filter.vmd_motion"),
        )
        existing = {self.flex_list.item(i).text() for i in range(self.flex_list.count())}
        for path in paths:
            if path not in existing:
                self.flex_list.addItem(path)
        self.save_persisted_settings()

    def remove_selected_flex_vmds(self) -> None:
        for item in self.flex_list.selectedItems():
            self.flex_list.takeItem(self.flex_list.row(item))
        self.save_persisted_settings()

    def flex_vmd_paths(self) -> list[str]:
        return [self.flex_list.item(i).text() for i in range(self.flex_list.count())]

    def current_audio_offset_seconds(self) -> float:
        slider = getattr(self, "audio_offset_slider", None) or getattr(self, "input_audio_offset_slider", None)
        return float(slider.value() if slider else 0) / 100.0

    def set_audio_offset_value(self, value: int, persist: bool = True) -> None:
        value = max(-500, min(500, int(value)))
        if self._syncing_audio_offset:
            return

        self._syncing_audio_offset = True
        try:
            for slider in (getattr(self, "input_audio_offset_slider", None), getattr(self, "audio_offset_slider", None)):
                if slider is not None and slider.value() != value:
                    slider.setValue(value)

            seconds = float(value) / 100.0
            label_text = self.tr("inputs.audio_offset.label", seconds=seconds)
            for label in (getattr(self, "input_audio_offset_label", None), getattr(self, "audio_offset_label", None)):
                if label is not None:
                    label.setText(label_text)
            if getattr(self, "preview", None) is not None:
                self.preview.set_audio_offset_seconds(seconds)
        finally:
            self._syncing_audio_offset = False

        if persist:
            self.save_persisted_settings()

    def update_input_audio_offset(self, value: int) -> None:
        self.set_audio_offset_value(value)

    def update_preview_audio_offset(self, value: int) -> None:
        self.set_audio_offset_value(value)

    def _path_rows(self) -> dict[str, PathRow]:
        return {
            "body_vmd": self.body_row,
            "music_path": self.music_row,
            "camera_vmd": self.camera_row,
            "gmod_dir": self.gmod_row,
        }

    def _load_persisted_settings(self) -> None:
        self._loading_settings = True
        try:
            for key, row in self._path_rows().items():
                value = self.settings_store.value(key, "", str)
                if value:
                    row.set_value(str(value))

            flex_values = self.settings_store.value("flex_vmds", [], list)
            if isinstance(flex_values, str):
                flex_values = [flex_values]
            for value in flex_values or []:
                if value:
                    self.flex_list.addItem(str(value))
            for field in import_vmd.MOTION_META_FIELDS:
                value = self.settings_store.value(f"meta_{field}", "", str)
                if value:
                    self.set_motion_meta_value(field, str(value))
            # Migrate the pre-table single "motion_name" setting into the
            # Display Name column the first time (never clobber a saved value).
            legacy_name = str(self.settings_store.value("motion_name", "", str) or "").strip()
            if legacy_name and not self.motion_meta_value("display_name"):
                self.set_motion_meta_value("display_name", legacy_name)
            display_name = self.motion_meta_value("display_name")
            if display_name:
                body_stem = Path(self.body_row.value()).stem.strip()
                if body_stem and display_name == body_stem:
                    self._motion_name_autofill = body_stem
            audio_offset = self.settings_store.value("audio_offset_centis", 0, int)
            self.set_audio_offset_value(int(audio_offset or 0), persist=False)
            export_addon = self.settings_store.value("export_addon", False, bool)
            self.export_addon_check.setChecked(bool(export_addon))
            disable_foot_ik = self.settings_store.value("disable_foot_ik", False, bool)
            self.disable_foot_ik_check.setChecked(bool(disable_foot_ik))
            unify_ground = self.settings_store.value("unify_ground", False, bool)
            self.unify_ground_check.setChecked(bool(unify_ground))
        finally:
            self._loading_settings = False

    def _wire_persisted_settings(self) -> None:
        for row in self._path_rows().values():
            row.edit.textChanged.connect(lambda _value: self.save_persisted_settings())
        self.body_row.edit.textChanged.connect(self.on_body_vmd_changed)
        # Wiping music/flex is destructive, so only do it when the user actually
        # picks a new body VMD via Browse — not on every keystroke of a typed path.
        self.body_row.pathBrowsed.connect(self.on_body_vmd_selected)
        self.motion_meta_table.itemChanged.connect(self._on_motion_meta_changed)
        self.export_addon_check.toggled.connect(lambda _value: self.save_persisted_settings())
        self.disable_foot_ik_check.toggled.connect(lambda _value: self.save_persisted_settings())
        self.unify_ground_check.toggled.connect(lambda _value: self.save_persisted_settings())
        self.unify_ground_check.toggled.connect(self.on_unify_ground_toggled)
        # Foot IK changes where the feet land, so a unified preview re-measures the floor.
        self.disable_foot_ik_check.toggled.connect(
            lambda _value: self.on_unify_ground_toggled(True) if self.unify_ground_check.isChecked() else None
        )

    def _retranslate_motion_meta_headers(self) -> None:
        for column, field in enumerate(import_vmd.MOTION_META_FIELDS):
            item = QtWidgets.QTableWidgetItem(self.tr(f"inputs.meta.{field}"))
            item.setToolTip(self.tr(f"inputs.meta.{field}.tooltip"))
            self.motion_meta_table.setHorizontalHeaderItem(column, item)

    def _motion_meta_item(self, field: str) -> QtWidgets.QTableWidgetItem:
        column = import_vmd.MOTION_META_FIELDS.index(field)
        item = self.motion_meta_table.item(0, column)
        if item is None:
            item = QtWidgets.QTableWidgetItem("")
            self.motion_meta_table.setItem(0, column, item)
        return item

    def motion_meta_value(self, field: str) -> str:
        return self._motion_meta_item(field).text().strip()

    def set_motion_meta_value(self, field: str, value: str) -> None:
        self._motion_meta_item(field).setText(str(value or ""))

    def motion_meta_dict(self) -> dict[str, str]:
        return {field: self.motion_meta_value(field) for field in import_vmd.MOTION_META_FIELDS}

    def _on_motion_meta_changed(self, _item: QtWidgets.QTableWidgetItem) -> None:
        if self._loading_settings:
            return
        self.save_persisted_settings()

    def _motion_name_is_autofilled(self) -> bool:
        current = self.motion_meta_value("display_name")
        return current == "" or current == (self._motion_name_autofill or "")

    def on_body_vmd_changed(self, value: str) -> None:
        if self._loading_settings:
            return

        # textChanged fires on every keystroke; only refresh the auto-filled
        # motion name (never a name the user typed themselves), and never touch
        # the music/flex selections here.
        candidate = Path(str(value or "")).stem.strip()
        if self._motion_name_is_autofilled():
            self._motion_name_autofill = candidate
            self.set_motion_meta_value("display_name", candidate)
        self.save_persisted_settings()

    def on_body_vmd_selected(self, value: str) -> None:
        if self._loading_settings:
            return

        candidate = Path(str(value or "")).stem.strip()
        if self._motion_name_is_autofilled():
            self._motion_name_autofill = candidate
            self.set_motion_meta_value("display_name", candidate)
        # A genuinely new source motion was chosen: its old music/flex/camera no longer apply.
        self.music_row.set_value("")
        self.camera_row.set_value("")
        self.flex_list.clear()
        self.save_persisted_settings()

    def save_persisted_settings(self) -> None:
        if self._loading_settings:
            return
        for key, row in self._path_rows().items():
            self.settings_store.setValue(key, row.value())
        for field in import_vmd.MOTION_META_FIELDS:
            self.settings_store.setValue(f"meta_{field}", self.motion_meta_value(field))
        self.settings_store.setValue("motion_name", self.motion_meta_value("display_name"))
        self.settings_store.setValue("audio_offset_centis", int(round(self.current_audio_offset_seconds() * 100)))
        self.settings_store.setValue("flex_vmds", self.flex_vmd_paths())
        self.settings_store.setValue("export_addon", self.export_addon_check.isChecked())
        self.settings_store.setValue("disable_foot_ik", self.disable_foot_ik_check.isChecked())
        self.settings_store.setValue("unify_ground", self.unify_ground_check.isChecked())
        self.settings_store.sync()

    def auto_detect_missing_paths(self) -> None:
        if not self.gmod_row.value():
            try:
                path = import_vmd.find_gmod_install()
                self.gmod_row.set_value(str(path))
                self.append_log(self.tr("log.detected_gmod", path=path))
            except Exception as exc:
                self.append_log(self.tr("log.gmod_autodetect_skipped", error=exc))

    def append_log(self, message: str) -> None:
        # Buffer the text (flushed in batches by the timer) but keep the live
        # feedback — status line and progress-bar stage — immediate.
        self._log_buffer.append(message)
        self.statusBar().showMessage(message[:160])
        self.update_progress_from_log(message)

    def _flush_log_buffer(self) -> None:
        if not self._log_buffer:
            return
        text = "\n".join(self._log_buffer)
        self._log_buffer.clear()
        self.log.appendPlainText(text)

    def copy_log_to_clipboard(self) -> None:
        self._flush_log_buffer()
        QtWidgets.QApplication.clipboard().setText(self.log.toPlainText())

    def progress_stage_from_log(self, message: str) -> tuple[int, str, str] | None:
        chunk = BAKED_FRAMES_PATTERN.search(message)
        if chunk:
            # Per-batch bake progress spans 20-84%.
            done, last = int(chunk.group(2)) + 1, int(chunk.group(3)) + 1
            return 20 + int(64 * min(1.0, done / max(1, last))), self.tr("progress.stage.baking_pose"), "#d29922"
        checks = [
            ("Starting native motion bake", 3, self.tr("progress.stage.baking_motion"), "#58a6ff"),
            ("Importing MMD model", 6, self.tr("progress.stage.importing_model"), "#58a6ff"),
            ("Imported MMD model", 10, self.tr("progress.stage.model_loaded"), "#2ea043"),
            ("Importing VMD motion", 12, self.tr("progress.stage.importing_motion"), "#58a6ff"),
            ("Imported VMD motion", 18, self.tr("progress.stage.motion_loaded"), "#2ea043"),
            ("Baking pose frames", 20, self.tr("progress.stage.baking_pose"), "#d29922"),
            ("Exporting parent-corrected bone rotations", 86, self.tr("progress.stage.exporting_transforms"), "#d29922"),
            ("Exported parent-corrected bone rotations", 89, self.tr("progress.stage.transforms_exported"), "#2ea043"),
            ("Native bake finished", 92, self.tr("progress.stage.pose_complete"), "#2ea043"),
            ("Parsed ", 96, self.tr("progress.stage.merging_flex"), "#58a6ff"),
            ("Converting music to MP3", 97, self.tr("progress.stage.converting_music"), "#58a6ff"),
            ("Wrote GMod sound", 98, self.tr("progress.stage.music_written"), "#2ea043"),
            ("Wrote motion JSON", 99, self.tr("progress.stage.json_written"), "#2ea043"),
        ]
        for needle, percent, stage, color in checks:
            if needle in message:
                return percent, stage, color
        if "Warning:" in message:
            return max(self.progress_floor, 1), self.tr("progress.stage.warning"), "#d29922"
        return None

    def update_progress_from_log(self, message: str) -> None:
        stage = self.progress_stage_from_log(message)
        if not stage or self.import_started_at <= 0:
            return
        percent, title, color = stage
        self.progress_floor = max(self.progress_floor, percent)
        self.progress_stage = title
        self.progress_color = color
        elapsed = time.monotonic() - self.import_started_at
        self.set_progress_value(
            max(self.progress_bar.value(), self.progress_floor),
            title,
            f"{message} | elapsed {self.format_duration(elapsed)}",
            color,
            complete=False,
        )

    def detect_gmod(self) -> None:
        try:
            path = import_vmd.find_gmod_install()
            self.gmod_row.set_value(str(path))
            self.append_log(self.tr("log.detected_gmod", path=path))
        except Exception as exc:
            self.show_error(self.tr("dialog.gmod_detection_failed.title"), str(exc))

    def load_preview(self) -> None:
        try:
            scene = self.preview.load_scene(
                import_vmd.find_default_mmd_model(),
                Path(self.body_row.value()),
                [Path(path) for path in self.flex_vmd_paths()],
                Path(self.music_row.value()) if self.music_row.value() else None,
                Path(self.camera_row.value()) if self.camera_row.value() else None,
                unify_ground=self.unify_ground_check.isChecked(),
                disable_ik=self.disable_foot_ik_check.isChecked(),
            )
            self.preview.set_follow_camera(self.follow_camera_check.isChecked())
            self.follow_camera_check.setEnabled(self.preview.has_camera_motion())
            self.tabs.setCurrentWidget(self.preview_tab)
            self.append_log(
                self.tr(
                    "log.preview_loaded",
                    model=scene.model_path.name,
                    bones=len(scene.bones),
                    flex_tracks=scene.flex_count,
                    textures=len(scene.textures),
                )
            )
        except Exception as exc:
            self.show_error(self.tr("dialog.preview_failed.title"), str(exc))

    def update_preview_frame(self, frame: int, seconds: float) -> None:
        self.current_preview_frame = frame
        self.current_preview_seconds = seconds
        self.frame_label.setText(self.tr("preview.frame_label", frame=frame, seconds=seconds))
        scene = self.preview.scene_data
        if scene and scene.frame_end > scene.frame_start and not self.scrubber.isSliderDown():
            fraction = (frame - scene.frame_start) / max(1, scene.frame_end - scene.frame_start)
            self.scrubber.setValue(max(0, min(1000, int(fraction * 1000))))

    def update_preview_audio_offset(self, value: int) -> None:
        self.set_audio_offset_value(value)

    def on_unify_ground_toggled(self, enabled: bool) -> None:
        if self._loading_settings or not self.preview.scene_data:
            return
        try:
            self.preview.set_ground_unified(bool(enabled), disable_ik=self.disable_foot_ik_check.isChecked())
        except Exception as exc:
            self.show_error(self.tr("dialog.preview_failed.title"), str(exc))

    def default_bake_estimate_seconds(self, frame_count: int) -> float:
        return DEFAULT_BAKE_STARTUP_SECONDS + max(0, int(frame_count)) * DEFAULT_BAKE_SECONDS_PER_FRAME

    def default_bake_timing_priors(self) -> list[dict[str, float]]:
        return [
            {"frames": float(frames), "seconds": self.default_bake_estimate_seconds(frames)}
            for frames in BAKE_TIMING_PRIOR_FRAME_COUNTS
        ]

    def load_bake_timing_samples(self) -> list[dict[str, float]]:
        version = self.settings_store.value("bake_timing_model_version", 0, int)
        if int(version or 0) != BAKE_TIMING_MODEL_VERSION:
            return []

        raw = self.settings_store.value("bake_timing_samples", "[]", str)
        try:
            parsed = json.loads(str(raw or "[]"))
        except (TypeError, ValueError):
            parsed = []

        samples: list[dict[str, float]] = []
        for item in parsed if isinstance(parsed, list) else []:
            if not isinstance(item, dict):
                continue
            try:
                frames = int(item.get("frames", 0))
                seconds = float(item.get("seconds", 0.0))
            except (TypeError, ValueError):
                continue
            if frames < 0 or seconds <= 0:
                continue
            samples.append({"frames": float(frames), "seconds": seconds})
        return samples[-BAKE_TIMING_SAMPLE_LIMIT:]

    def save_bake_timing_samples(self, samples: list[dict[str, float]]) -> None:
        clean = []
        for item in samples[-BAKE_TIMING_SAMPLE_LIMIT:]:
            clean.append({
                "frames": int(max(0, item.get("frames", 0))),
                "seconds": round(max(0.001, float(item.get("seconds", 0.001))), 3),
            })
        self.settings_store.setValue("bake_timing_samples", json.dumps(clean, separators=(",", ":")))
        self.settings_store.setValue("bake_timing_model_version", BAKE_TIMING_MODEL_VERSION)
        self.settings_store.sync()

    def fitted_bake_timing_model(self) -> tuple[float, float, int]:
        real_samples = self.load_bake_timing_samples()
        if not real_samples:
            return DEFAULT_BAKE_SECONDS_PER_FRAME, DEFAULT_BAKE_STARTUP_SECONDS, 0

        samples = self.default_bake_timing_priors() + real_samples

        count = float(len(samples))
        sum_x = sum(item["frames"] for item in samples)
        sum_y = sum(item["seconds"] for item in samples)
        sum_xx = sum(item["frames"] * item["frames"] for item in samples)
        sum_xy = sum(item["frames"] * item["seconds"] for item in samples)
        denom = count * sum_xx - sum_x * sum_x
        if abs(denom) <= 0.000001:
            return DEFAULT_BAKE_SECONDS_PER_FRAME, max(0.0, sum_y / count), len(real_samples)

        slope = (count * sum_xy - sum_x * sum_y) / denom
        intercept = (sum_y - slope * sum_x) / count
        if slope < 0:
            slope = DEFAULT_BAKE_SECONDS_PER_FRAME
        return max(0.00001, min(1.0, slope)), max(0.0, intercept), len(real_samples)

    def record_bake_timing_sample(self) -> str:
        if self.import_started_at <= 0:
            return ""
        elapsed = max(0.001, time.monotonic() - self.import_started_at)
        samples = self.load_bake_timing_samples()
        samples.append({"frames": float(max(0, self.import_estimate_frames)), "seconds": elapsed})
        self.save_bake_timing_samples(samples)
        slope, intercept, count = self.fitted_bake_timing_model()
        return self.tr(
            "log.timing_sample",
            frames=self.import_estimate_frames,
            elapsed=self.format_duration(elapsed),
            slope=slope,
            intercept=intercept,
            samples=count,
        )

    def estimate_bake_time(self) -> tuple[int, float, str]:
        body_path = Path(self.body_row.value())
        if not body_path.exists():
            return 0, DEFAULT_BAKE_STARTUP_SECONDS, self.tr("estimate.default_no_vmd")
        motion = import_vmd.parse_vmd(body_path)
        frame_count = max(1, int(motion.max_frame) + 1)
        slope, intercept, sample_count = self.fitted_bake_timing_model()
        estimate = max(1.0, slope * frame_count + intercept)
        if sample_count <= 0:
            return (
                frame_count,
                self.default_bake_estimate_seconds(frame_count),
                self.tr("estimate.default_model"),
            )
        return (
            frame_count,
            estimate,
            self.tr("estimate.learned_model", samples=sample_count, slope=slope, intercept=intercept),
        )

    def estimate_detail_suffix(self) -> str:
        return self.import_estimate_detail or self.tr("estimate.default_detail")

    def format_duration(self, seconds: float) -> str:
        seconds = max(0, int(round(seconds)))
        minutes, remainder = divmod(seconds, 60)
        if minutes:
            return f"{minutes}m {remainder:02d}s"
        return f"{remainder}s"

    def running_progress_curve(self, raw_percent: float) -> int:
        raw_percent = max(0.0, raw_percent)
        if raw_percent <= 90.0:
            return int(raw_percent)
        slowed = 90.0 + (raw_percent - 90.0) * 0.20
        return min(98, int(slowed))

    def set_progress_value(self, percent: int, title: str, detail: str, color: str, complete: bool = False) -> None:
        value = int(max(0, min(100 if complete else 98, percent)))
        text = (
            f'<span style="color:{color};">{html.escape(title)}</span>'
            f" - {value}%<br><span style=\"color:#8f98a3;\">{html.escape(detail)}</span>"
        )
        self.progress_bar.setValue(value)
        self.progress_label.setText(text)
        if hasattr(self, "preview_progress_bar"):
            self.preview_progress_bar.setValue(value)
        if hasattr(self, "preview_progress_label"):
            self.preview_progress_label.setText(text)

    def start_progress_estimate(self) -> None:
        try:
            self.import_estimate_frames, self.import_estimate_seconds, self.import_estimate_detail = self.estimate_bake_time()
        except Exception as exc:
            self.import_estimate_frames = 0
            self.import_estimate_seconds = DEFAULT_BAKE_STARTUP_SECONDS
            self.import_estimate_detail = self.tr("estimate.default_parse_error")
            self.append_log(self.tr("estimate.parse_error_log", error=exc))
        self.import_started_at = time.monotonic()
        self.progress_floor = 0
        self.progress_stage = self.tr("progress.stage.queued")
        self.progress_color = "#58a6ff"
        self.set_progress_value(
            0,
            self.tr("progress.stage.queued"),
            self.tr(
                "progress.estimated",
                duration=self.format_duration(self.import_estimate_seconds),
                frames=self.import_estimate_frames,
                detail=self.estimate_detail_suffix(),
            ),
            self.progress_color,
        )
        self.progress_timer.start(500)

    def update_import_progress(self) -> None:
        if self.import_started_at <= 0:
            return
        elapsed = time.monotonic() - self.import_started_at
        estimate = max(1.0, self.import_estimate_seconds)
        progress = max(self.progress_floor, self.running_progress_curve((elapsed / estimate) * 100.0))
        remaining = max(0.0, estimate - elapsed)
        self.set_progress_value(
            progress,
            self.progress_stage or self.tr("progress.stage.baking_motion"),
            self.tr(
                "progress.elapsed_remaining",
                elapsed=self.format_duration(elapsed),
                remaining=self.format_duration(remaining),
                frames=self.import_estimate_frames,
                detail=self.estimate_detail_suffix(),
            ),
            self.progress_color or "#58a6ff",
            complete=False,
        )

    def finish_progress(self, message: str, complete: bool) -> None:
        self.progress_timer.stop()
        self.set_progress_value(
            100 if complete else self.progress_bar.value(),
            self.tr("progress.import_complete") if complete else self.tr("progress.import_failed"),
            message,
            "#2ea043" if complete else "#f85149",
            complete=complete,
        )

    def start_import(self) -> None:
        if self.worker and self.worker.isRunning():
            return
        export_addon = self.export_addon_check.isChecked()
        addon_gma_path = ""
        if export_addon:
            default_name = import_vmd.slugify(self.motion_meta_value("display_name") or self.body_row.value() or "motion")
            default_path = Path.home() / "Desktop" / f"MMDMotionPlayer_{default_name}.gma"
            addon_gma_path, _ = QtWidgets.QFileDialog.getSaveFileName(
                self,
                self.tr("dialog.save_gma.title"),
                str(default_path),
                self.tr("filter.gma"),
            )
            if not addon_gma_path:
                self.statusBar().showMessage(self.tr("status.gma_export_cancelled"))
                return
            if not addon_gma_path.lower().endswith(".gma"):
                addon_gma_path += ".gma"
        self._log_buffer.clear()
        settings = {
            "body_vmd": self.body_row.value(),
            "music_path": self.music_row.value(),
            "camera_vmd": self.camera_row.value(),
            "motion_name": self.motion_meta_value("display_name"),
            "motion_meta": self.motion_meta_dict(),
            "audio_offset": self.current_audio_offset_seconds(),
            "gmod_dir": self.gmod_row.value(),
            "flex_vmds": self.flex_vmd_paths(),
            "export_addon": export_addon,
            "addon_gma_path": addon_gma_path,
            "disable_foot_ik": self.disable_foot_ik_check.isChecked(),
            "unify_ground": self.unify_ground_check.isChecked(),
        }
        self.log.clear()
        self.load_preview()
        self.start_progress_estimate()
        self.import_button.setEnabled(False)
        self.cancel_button.setEnabled(True)
        self.worker = ImportWorker(settings)
        self.worker.log.connect(self.append_log)
        self.worker.done.connect(self.import_done)
        self.worker.failed.connect(self.import_failed)
        self.worker.start()

    def cancel_import(self) -> None:
        if self.worker and self.worker.isRunning():
            self.worker.cancel()
            self.append_log(self.tr("log.cancel_requested"))

    # --- Motion Manager tab -------------------------------------------------
    def _build_manager_tab(self) -> None:
        self._manager_column_keys = [
            "manager.col.name",
            "manager.col.duration",
            "manager.col.fps",
            "manager.col.frames",
            "manager.col.music",
            "manager.col.camera",
            "manager.col.flexes",
            "manager.col.size",
            "manager.col.modified",
        ]
        tab = QtWidgets.QWidget()
        self.manager_tab = tab
        layout = QtWidgets.QVBoxLayout(tab)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(8)

        top = QtWidgets.QHBoxLayout()
        self.manager_hint = QtWidgets.QLabel(self.tr("manager.hint"))
        self.manager_hint.setObjectName("fieldHint")
        self.manager_hint.setWordWrap(True)
        self.manager_refresh_button = QtWidgets.QPushButton(self.tr("manager.refresh"))
        self.manager_refresh_button.clicked.connect(self.manager_refresh)
        self.manager_open_folder_button = QtWidgets.QPushButton(self.tr("manager.open_folder"))
        self.manager_open_folder_button.clicked.connect(self.manager_open_folder)
        top.addWidget(self.manager_hint, 1)
        top.addWidget(self.manager_refresh_button)
        top.addWidget(self.manager_open_folder_button)
        layout.addLayout(top)

        self.manager_table = QtWidgets.QTableWidget(0, len(self._manager_column_keys))
        self.manager_table.setHorizontalHeaderLabels([self.tr(k) for k in self._manager_column_keys])
        self.manager_table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.manager_table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectionBehavior.SelectRows)
        self.manager_table.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.ExtendedSelection)
        self.manager_table.setSortingEnabled(True)
        self.manager_table.setAlternatingRowColors(True)
        self.manager_table.verticalHeader().setVisible(False)
        header = self.manager_table.horizontalHeader()
        header.setStretchLastSection(True)
        header.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.Stretch)
        for column in range(1, len(self._manager_column_keys)):
            header.setSectionResizeMode(column, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.manager_table.itemSelectionChanged.connect(self._update_manager_buttons)
        self.manager_table.itemDoubleClicked.connect(lambda *_: self.manager_show_json())
        layout.addWidget(self.manager_table, 1)

        bottom = QtWidgets.QHBoxLayout()
        self.manager_rename_button = QtWidgets.QPushButton(self.tr("manager.rename"))
        self.manager_rename_button.clicked.connect(self.manager_rename)
        self.manager_remove_button = QtWidgets.QPushButton(self.tr("manager.remove"))
        self.manager_remove_button.clicked.connect(self.manager_remove)
        self.manager_show_json_button = QtWidgets.QPushButton(self.tr("manager.show_json"))
        self.manager_show_json_button.clicked.connect(self.manager_show_json)
        self.manager_show_music_button = QtWidgets.QPushButton(self.tr("manager.show_music"))
        self.manager_show_music_button.clicked.connect(self.manager_show_music)
        self.manager_status_label = QtWidgets.QLabel(self.tr("manager.status_idle"))
        self.manager_status_label.setObjectName("fieldHint")
        for button in (self.manager_rename_button, self.manager_remove_button, self.manager_show_json_button, self.manager_show_music_button):
            bottom.addWidget(button)
        bottom.addStretch(1)
        bottom.addWidget(self.manager_status_label)
        layout.addLayout(bottom)

        self._update_manager_buttons()
        self.tabs.addTab(tab, self.tr("tab.manager"))

    def retranslate_manager(self) -> None:
        if not hasattr(self, "manager_table"):
            return
        self.manager_table.setHorizontalHeaderLabels([self.tr(k) for k in self._manager_column_keys])
        self.manager_hint.setText(self.tr("manager.hint"))
        self.manager_refresh_button.setText(self.tr("manager.refresh"))
        self.manager_open_folder_button.setText(self.tr("manager.open_folder"))
        self.manager_rename_button.setText(self.tr("manager.rename"))
        self.manager_remove_button.setText(self.tr("manager.remove"))
        self.manager_show_json_button.setText(self.tr("manager.show_json"))
        self.manager_show_music_button.setText(self.tr("manager.show_music"))

    def _manager_index_path(self) -> Path:
        return import_vmd.app_local_dir() / "manager_index.json"

    def _load_manager_index(self) -> dict:
        try:
            path = self._manager_index_path()
            if path.is_file():
                data = json.loads(path.read_text(encoding="utf-8"))
                entries = data.get("entries")
                if isinstance(entries, dict):
                    return entries
        except Exception:
            pass
        return {}

    def _save_manager_index(self) -> None:
        try:
            path = self._manager_index_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"version": 1, "entries": self._manager_cache}, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    def _invalidate_manager_cache(self, path) -> None:
        if path:
            self._manager_cache.pop(str(path), None)

    def _resolve_gmod_dir(self) -> Path | None:
        value = self.gmod_row.value().strip()
        if value:
            return Path(value)
        try:
            return import_vmd.find_gmod_install()
        except Exception:
            return None

    def manager_motions_dir(self) -> Path | None:
        gmod = self._resolve_gmod_dir()
        if gmod is None:
            return None
        return import_vmd.gmod_motions_dir(gmod)

    def _on_tab_changed(self, index: int) -> None:
        if getattr(self, "manager_tab", None) is not None and self.tabs.widget(index) is self.manager_tab:
            # Lazily scan when the manager is first opened, and re-scan on return
            # so motions imported/edited elsewhere show up.
            self.manager_refresh()

    def manager_refresh(self) -> None:
        if self._manager_worker is not None and self._manager_worker.isRunning():
            # A scan is already running with a stale snapshot; queue one more so a
            # delete/rename/import that happened mid-scan is reflected afterwards.
            self._manager_refresh_pending = True
            return
        motions_dir = self.manager_motions_dir()
        if motions_dir is None or not motions_dir.is_dir():
            self._manager_rows = []
            self._populate_manager_table([])
            self.manager_status_label.setText(self.tr("manager.status_no_dir"))
            self._update_manager_buttons()
            return
        self.manager_status_label.setText(self.tr("manager.status_scanning"))
        self.manager_refresh_button.setEnabled(False)
        self._manager_scanned_once = True
        self._manager_worker = ManagerScanWorker(motions_dir, self._manager_cache)
        self._manager_worker.results.connect(self._on_manager_results)
        self._manager_worker.failed.connect(self._on_manager_failed)
        self._manager_worker.start()

    def _on_manager_results(self, rows: list) -> None:
        self.manager_refresh_button.setEnabled(True)
        # Rebuild the cache from the files that exist now (auto-prunes deleted ones).
        new_cache: dict = {}
        for row in rows:
            if row.get("header"):
                new_cache[row["path"]] = {"mtime": row["mtime"], "size": row["size"], "header": row["header"]}
        self._manager_cache = new_cache
        self._save_manager_index()
        self._manager_rows = rows
        self._populate_manager_table(rows)
        ok = sum(1 for row in rows if row.get("header"))
        self.manager_status_label.setText(self.tr("manager.status_count", count=ok))
        self._update_manager_buttons()
        if self._manager_refresh_pending:
            # A refresh requested during this scan (e.g. a mid-scan delete) was
            # deferred; run it now against current disk + the freshly pruned cache.
            self._manager_refresh_pending = False
            self.manager_refresh()

    def _on_manager_failed(self, message: str) -> None:
        self.manager_refresh_button.setEnabled(True)
        self.manager_status_label.setText(self.tr("manager.status_error", error=message))

    def _populate_manager_table(self, rows: list) -> None:
        table = self.manager_table
        table.setSortingEnabled(False)
        table.setRowCount(0)
        for row in rows:
            header = row.get("header") or {}
            r = table.rowCount()
            table.insertRow(r)
            display = str(header.get("display_name") or Path(row["path"]).stem)
            name_item = QtWidgets.QTableWidgetItem(display)
            name_item.setFlags(QtCore.Qt.ItemFlag.ItemIsSelectable | QtCore.Qt.ItemFlag.ItemIsEnabled)
            name_item.setData(QtCore.Qt.ItemDataRole.UserRole, row["path"])
            if row.get("error"):
                name_item.setToolTip(self.tr("manager.row_error", error=row["error"]))
            table.setItem(r, 0, name_item)

            dur = float(header.get("duration") or 0.0)
            table.setItem(r, 1, SortableTableItem(self._format_duration(dur), dur))
            fps = int(header.get("fps") or 0)
            table.setItem(r, 2, SortableTableItem(str(fps) if fps else "—", fps))
            frames = int(header.get("frame_count") or 0)
            table.setItem(r, 3, SortableTableItem(str(frames) if frames else "—", frames))
            has_music = bool(header.get("has_music"))
            table.setItem(r, 4, SortableTableItem(self.tr("manager.yes") if has_music else "—", 1 if has_music else 0))
            cam_keys = int(header.get("camera_key_count") or 0)
            cam_text = self.tr("manager.camera_keys", count=cam_keys) if cam_keys else "—"
            table.setItem(r, 5, SortableTableItem(cam_text, cam_keys))
            flexes = int(header.get("flex_count") or 0)
            table.setItem(r, 6, SortableTableItem(str(flexes), flexes))
            size = int(row.get("size") or 0)
            table.setItem(r, 7, SortableTableItem(self._format_size(size), size))
            mtime = float(row.get("mtime") or 0.0)
            table.setItem(r, 8, SortableTableItem(self._format_time(mtime), mtime))
        table.setSortingEnabled(True)

    def _selected_manager_paths(self) -> list[str]:
        paths: list[str] = []
        for item in self.manager_table.selectedItems():
            if item.column() == 0:
                value = item.data(QtCore.Qt.ItemDataRole.UserRole)
                if value:
                    paths.append(str(value))
        return paths

    def _header_for_path(self, path: str) -> dict | None:
        for row in self._manager_rows:
            if row.get("path") == path:
                return row.get("header")
        return None

    def _update_manager_buttons(self) -> None:
        if not hasattr(self, "manager_rename_button"):
            return
        paths = self._selected_manager_paths()
        single = len(paths) == 1
        self.manager_rename_button.setEnabled(single)
        self.manager_remove_button.setEnabled(len(paths) >= 1)
        self.manager_show_json_button.setEnabled(single)
        has_music = bool(single and (self._header_for_path(paths[0]) or {}).get("has_music"))
        self.manager_show_music_button.setEnabled(has_music)

    def manager_rename(self) -> None:
        paths = self._selected_manager_paths()
        if len(paths) != 1:
            return
        path = Path(paths[0])
        current = str((self._header_for_path(paths[0]) or {}).get("display_name") or path.stem)
        new_name, ok = QtWidgets.QInputDialog.getText(
            self, self.tr("manager.rename_title"), self.tr("manager.rename_prompt"), text=current
        )
        if not ok:
            return
        new_name = new_name.strip()
        if not new_name or new_name == current:
            return
        try:
            import_vmd.rename_motion_display_name(path, new_name)
        except Exception as exc:
            self.show_error(self.tr("manager.rename_failed_title"), str(exc))
            return
        self._invalidate_manager_cache(str(path))
        self.manager_refresh()
        self.statusBar().showMessage(self.tr("manager.renamed", name=new_name))

    def manager_remove(self) -> None:
        paths = self._selected_manager_paths()
        if not paths:
            return
        names = [str((self._header_for_path(p) or {}).get("display_name") or Path(p).stem) for p in paths]
        preview = "\n".join(names[:20])
        if len(names) > 20:
            preview += "\n…"
        if QtWidgets.QMessageBox.question(
            self,
            self.tr("manager.remove_title"),
            self.tr("manager.remove_confirm", count=len(paths), names=preview),
        ) != QtWidgets.QMessageBox.Yes:
            return
        gmod = self._resolve_gmod_dir()
        removed = 0
        errors: list[str] = []
        for path_str in paths:
            header = self._header_for_path(path_str) or {}
            path = Path(path_str)
            try:
                path.unlink(missing_ok=True)
                removed += 1
            except Exception as exc:
                errors.append(f"{path.name}: {exc}")
                continue
            sound_rel = str(header.get("music_sound") or "")
            if sound_rel and gmod is not None:
                try:
                    sound_root = (gmod / "garrysmod" / "sound").resolve()
                    sound_path = (sound_root / import_vmd.safe_relative_path(sound_rel)).resolve()
                    # Never delete outside the GMod sound tree, even if a shared
                    # motion carried a hostile music path.
                    if sound_root in sound_path.parents and sound_path.is_file():
                        sound_path.unlink()
                except Exception:
                    pass
            self._invalidate_manager_cache(path_str)
        self.manager_refresh()
        if errors:
            self.show_error(self.tr("manager.remove_failed_title"), "\n".join(errors))
        self.statusBar().showMessage(self.tr("manager.removed", count=removed))

    def manager_open_folder(self) -> None:
        motions_dir = self.manager_motions_dir()
        if motions_dir is None:
            self.manager_status_label.setText(self.tr("manager.status_no_dir"))
            return
        try:
            motions_dir.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass
        self._open_in_file_manager(motions_dir)

    def manager_show_json(self) -> None:
        paths = self._selected_manager_paths()
        if len(paths) == 1:
            self._reveal_in_file_manager(Path(paths[0]))

    def manager_show_music(self) -> None:
        paths = self._selected_manager_paths()
        if len(paths) != 1:
            return
        sound_rel = str((self._header_for_path(paths[0]) or {}).get("music_sound") or "")
        gmod = self._resolve_gmod_dir()
        if not sound_rel or gmod is None:
            return
        try:
            sound_path = gmod / "garrysmod" / "sound" / import_vmd.safe_relative_path(sound_rel)
        except Exception:
            return
        self._reveal_in_file_manager(sound_path)

    def _open_in_file_manager(self, path: Path) -> None:
        try:
            if sys.platform.startswith("win"):
                os.startfile(str(path))  # type: ignore[attr-defined]
            else:
                QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(str(path)))
        except Exception as exc:
            self.show_error(self.tr("manager.open_failed_title"), str(exc))

    def _reveal_in_file_manager(self, path: Path) -> None:
        try:
            if sys.platform.startswith("win") and path.exists():
                # explorer returns exit code 1 even on success, so fire-and-forget.
                subprocess.Popen(f'explorer /select,"{path}"')
            else:
                target = path if path.is_dir() else path.parent
                QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(str(target)))
        except Exception as exc:
            self.show_error(self.tr("manager.open_failed_title"), str(exc))

    @staticmethod
    def _format_duration(seconds: float) -> str:
        seconds = max(0.0, float(seconds))
        minutes = int(seconds // 60)
        return f"{minutes}:{seconds - minutes * 60:04.1f}"

    @staticmethod
    def _format_size(size: int) -> str:
        size = max(0, int(size))
        if size < 1024:
            return f"{size} B"
        if size < 1024 * 1024:
            return f"{size / 1024:.1f} KB"
        return f"{size / 1024 / 1024:.1f} MB"

    @staticmethod
    def _format_time(mtime: float) -> str:
        if not mtime:
            return "—"
        try:
            return time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime))
        except Exception:
            return "—"

    def closeEvent(self, event) -> None:
        # Destroying a still-running QThread makes Qt qFatal (hard crash). Ask the
        # running import to stop and wait for it to actually finish first.
        worker = self.worker
        if worker is not None and worker.isRunning():
            worker.cancel()
            if not worker.wait(5000):
                # The bake only polls cancel between frame batches (and music
                # conversion not at all); keep waiting rather than tearing the
                # thread down mid-run.
                worker.wait()
        manager_worker = self._manager_worker
        if manager_worker is not None and manager_worker.isRunning():
            manager_worker.wait()
        super().closeEvent(event)

    def import_done(self, result: dict) -> None:
        self.import_button.setEnabled(True)
        self.cancel_button.setEnabled(False)
        timing_message = self.record_bake_timing_sample()
        detail = self.tr("progress.complete_detail")
        if timing_message:
            self.append_log(timing_message)
            detail = f"{detail} {timing_message}"
        self.finish_progress(detail, True)
        self.output_labels["motion_json"].setText(str(result.get("motion_json", "")))
        self.output_labels["addon_gma"].setText(str(result.get("addon_gma", "")))
        music = result.get("music") or {}
        self.output_labels["music"].setText(str(music.get("sound", "")) if isinstance(music, dict) else "")
        # The newly written motion must show up in the manager next time it opens.
        self._invalidate_manager_cache(result.get("motion_json"))
        self.manager_refresh()
        QtWidgets.QMessageBox.information(
            self,
            self.tr("dialog.import_complete.title"),
            self.tr("dialog.import_complete.body"),
        )

    def import_failed(self, message: str) -> None:
        self.import_button.setEnabled(True)
        self.cancel_button.setEnabled(False)
        self.finish_progress(self.tr("progress.failed_detail"), False)
        self.show_error(self.tr("dialog.import_failed.title"), message)

    def show_error(self, title: str, message: str) -> None:
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle(title)
        # Clamp to the available screen so the dialog never extends past a small
        # display's edges (apply_startup_geometry supports widths down to 760).
        screen = self.screen() or QtWidgets.QApplication.primaryScreen()
        avail = screen.availableGeometry() if screen else None
        width = min(820, avail.width() - 40) if avail else 820
        height = min(540, avail.height() - 80) if avail else 540
        dialog.resize(max(360, width), max(240, height))
        layout = QtWidgets.QVBoxLayout(dialog)
        text = QtWidgets.QPlainTextEdit(message)
        text.setReadOnly(True)
        layout.addWidget(text, 1)
        buttons = QtWidgets.QHBoxLayout()
        copy_button = QtWidgets.QPushButton(self.tr("dialog.copy"))
        close_button = QtWidgets.QPushButton(self.tr("dialog.close"))
        copy_button.clicked.connect(lambda: QtWidgets.QApplication.clipboard().setText(message))
        close_button.clicked.connect(dialog.accept)
        buttons.addStretch(1)
        buttons.addWidget(copy_button)
        buttons.addWidget(close_button)
        layout.addLayout(buttons)
        dialog.exec()


def main() -> int:
    # The preview viewport is a native QOpenGLWindow in a window container, so
    # the top-level window keeps its fast raster backing store (a QOpenGLWidget
    # here — even on a hidden tab — forced the WHOLE window through GPU
    # compositing and made every text-field repaint several times slower).
    # Still disable vsync on the default format: it only affects the preview
    # window's own swapchain now, whose cadence comes from its 16 ms timer —
    # without this its paints would additionally block on the vertical blank.
    # Must run before the QApplication and any OpenGL context is created.
    surface_format = QtGui.QSurfaceFormat.defaultFormat()
    surface_format.setSwapInterval(0)
    QtGui.QSurfaceFormat.setDefaultFormat(surface_format)

    app = QtWidgets.QApplication(sys.argv)
    app.setOrganizationName("MMDVMDNPC")
    app.setApplicationName(I18N.t("app.title"))
    icon_path = import_vmd.ROOT / "tools" / "assets" / "importer_icon.ico"
    if icon_path.exists():
        app.setWindowIcon(QtGui.QIcon(str(icon_path)))
    window = ImporterWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
