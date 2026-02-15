; Codex for Windows - NSIS Installer Script
; Bundles Electron runtime + app code. Per-user install, no admin required.

!include "MUI2.nsh"
!include "FileFunc.nsh"

; --- Build-time defines (passed via makensis -D) ---
; APP_VERSION  - e.g. "1.0.0"
; SOURCE_DIR   - absolute path to the assembled Electron distribution folder

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
!ifndef SOURCE_DIR
  !define SOURCE_DIR "codex-windows-x64"
!endif

; --- Application metadata ---
!define APP_NAME        "Codex"
!define APP_PUBLISHER   "Community contributors"
!define APP_EXE         "Codex.exe"
!define CLI_EXE         "resources\app\resources\bin\codex.exe"
!define UNINSTALL_KEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
; Optional: Path to custom icon (extracted from DMG or provided at build time)
; If not defined, will use the executable's icon
!ifndef APP_ICON
  !define APP_ICON ""
!endif

; If a custom icon was provided, apply it to the installer UI and the uninstaller.
; Note: APP_ICON is expected to be a path inside SOURCE_DIR (build-time) and inside
; $INSTDIR (install-time), e.g. "resources\app\resources\codex-icon.ico".
!if "${APP_ICON}" != ""
  !define _ICON_SRC "${SOURCE_DIR}\${APP_ICON}"
  !define MUI_ICON "${_ICON_SRC}"
  !define MUI_UNICON "${_ICON_SRC}"
  Icon "${_ICON_SRC}"
  UninstallIcon "${_ICON_SRC}"
!endif

Name "${APP_NAME} ${APP_VERSION}"
OutFile "Codex-Setup-${APP_VERSION}-x64.exe"
InstallDir "$LOCALAPPDATA\${APP_NAME}"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "${APP_NAME} Unofficial Installer"

!define MUI_TEXT_WELCOME_INFO_TITLE "${APP_NAME} (Community Build)"
!define MUI_TEXT_WELCOME_INFO_TEXT "${APP_NAME} for Windows${\r\n}${\r\n}This installer is provided as a community-maintained distribution.${\r\n}It is not official software from OpenAI and is not affiliated with, endorsed by, or sponsored by OpenAI, ChatGPT, or Codex."

; --- MUI pages ---
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${APP_NAME}"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ============================================================
; Install section
; ============================================================
Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${SOURCE_DIR}/*.*"

  ; Create uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Start Menu shortcuts
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"

  ; Main application shortcut - uses custom icon if available, else executable icon
  !if "${APP_ICON}" != ""
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" \
      "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_ICON}" 0
  !else
    CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" \
      "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  !endif

  ; CLI shortcut (optional - comment out if not needed)
  ; CreateShortCut "$SMPROGRAMS\${APP_NAME}\Codex CLI.lnk" \
  ;   "$INSTDIR\${CLI_EXE}" "" "$INSTDIR\${CLI_EXE}" 0

  CreateShortCut "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk" \
    "$INSTDIR\uninstall.exe"

  ; Add/Remove Programs registry
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName"            "${APP_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion"         "${APP_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher"               "${APP_PUBLISHER}"

  ; Use custom icon for Add/Remove Programs if available
  !if "${APP_ICON}" != ""
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon"           "$INSTDIR\${APP_ICON}"
  !else
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon"           "$INSTDIR\${APP_EXE}"
  !endif

  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation"         "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString"         '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString"    '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1

  ; Estimated size for Add/Remove Programs
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" $0
SectionEnd

; ============================================================
; Uninstall section
; ============================================================
Section "Uninstall"
  ; Remove Start Menu entries
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  ; CLI shortcut may not exist (optional), so use /REBOOTOK to suppress error
  Delete /REBOOTOK "$SMPROGRAMS\${APP_NAME}\Codex CLI.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\Uninstall ${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  ; Remove registry
  DeleteRegKey HKCU "${UNINSTALL_KEY}"

  ; Remove files (move out of INSTDIR first so it can be deleted)
  SetOutPath "$TEMP"
  RMDir /r "$INSTDIR"
SectionEnd
