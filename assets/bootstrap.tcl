# git-gui dark mode Tcl template.
# Read by git-gui-dark.ps1's `install` subcommand and rendered into the
# bootstrap at %LOCALAPPDATA%\git-gui-dark\bootstrap.tcl at install time.
# The Git installation is NOT modified. The rendered output is safe to
# delete; this template is the source of truth.

# Resolve the real git-gui.tcl and prepare argv0 so git-gui can find its lib dir.
# IMPORTANT: argv0 must end in "git-gui" (not "git-gui.tcl") - git-gui.tcl's
#   feature-option block uses a regex `^git-(.+)$` to derive the subcommand and
#   only normalizes "gui.sh" -> "gui", not "gui.tcl". Pointing argv0 at the
#   real launcher name avoids the "usage: ... [[blame|browser|...]]" dialog.
set ::__gitGuiDarkTcl [file normalize [list __GITGUI_TCL_PATH__]]
# Source the launcher (no extension) instead of git-gui.tcl directly - the
# launcher handles --working-dir before sourcing git-gui.tcl, which is what
# the Windows "Open Git GUI here" context menu relies on.
set ::__gitGuiLauncher [file join [file dirname $::__gitGuiDarkTcl] git-gui]
set ::argv0 $::__gitGuiLauncher

# Prepend Git's real bin directories to PATH. PowerShell only puts the .bat-shim
# dir (C:\Program Files\Git\cmd) on PATH, but git-gui.tcl uses a sanitized search
# path to call tools like cygpath.exe (in usr/bin) and the arch bin (e.g.
# ucrt64/bin). Without these, git-gui fails with "cygpath not found in PATH".
foreach __binDir {__GIT_BIN_PATHS__} {
    if {[file isdirectory $__binDir]} {
        set ::env(PATH) "$__binDir;$::env(PATH)"
    }
}
unset __binDir

# Force a dark palette as the global base. tk_setPalette updates the widget
# option database, so any widget created from this point on picks the colors up.
tk_setPalette \
    background          "#1e1e1e" \
    foreground          "#d4d4d4" \
    activeBackground    "#2d2d2d" \
    activeForeground    "#ffffff" \
    selectBackground    "#264f78" \
    selectForeground    "#ffffff" \
    troughColor         "#0c0c0c" \
    highlightBackground "#1e1e1e" \
    highlightColor      "#3c3c3c" \
    insertBackground    "#ffffff"

# Cover options that tk_setPalette doesn't apply to some widget classes.
option add *Menu.Background               "#1e1e1e"  widgetDefault
option add *Menu.Foreground               "#d4d4d4"  widgetDefault
option add *Menu.activeBackground         "#2d2d2d"  widgetDefault
option add *Menu.activeForeground         "#ffffff"  widgetDefault
option add *Menu.disabledForeground       "#7a7a7a"  widgetDefault
option add *Text.Background               "#1e1e1e"  widgetDefault
option add *Text.Foreground               "#d4d4d4"  widgetDefault
option add *Text.selectBackground         "#264f78"  widgetDefault
option add *Text.selectForeground         "#ffffff"  widgetDefault
option add *Text.inactiveSelectBackground "#3c3c3c"  widgetDefault
option add *Listbox.Background            "#1e1e1e"  widgetDefault
option add *Listbox.Foreground            "#d4d4d4"  widgetDefault
option add *Listbox.selectBackground      "#264f78"  widgetDefault
option add *Listbox.selectForeground      "#ffffff"  widgetDefault
option add *Canvas.Background             "#1e1e1e"  widgetDefault
option add *Label.Background              "#1e1e1e"  widgetDefault
option add *Label.Foreground              "#d4d4d4"  widgetDefault
option add *Label.disabledForeground      "#7a7a7a"  widgetDefault
option add *Button.Background             "#2d2d2d"  widgetDefault
option add *Button.Foreground             "#d4d4d4"  widgetDefault
option add *Button.activeBackground       "#3d3d3d"  widgetDefault
option add *Button.activeForeground       "#ffffff"  widgetDefault
option add *Button.disabledForeground     "#7a7a7a"  widgetDefault
option add *Entry.Background              "#1e1e1e"  widgetDefault
option add *Entry.Foreground              "#d4d4d4"  widgetDefault
option add *Entry.insertBackground        "#ffffff"  widgetDefault
option add *Entry.disabledForeground      "#7a7a7a"  widgetDefault
option add *Frame.Background              "#1e1e1e"  widgetDefault
option add *TLabel.foreground             "#d4d4d4"  widgetDefault
option add *TFrame.background             "#1e1e1e"  widgetDefault
option add *TButton.foreground            "#d4d4d4"  widgetDefault
option add *TCheckbutton.foreground       "#d4d4d4"  widgetDefault
option add *TRadiobutton.foreground       "#d4d4d4"  widgetDefault
option add *TEntry.foreground             "#d4d4d4"  widgetDefault

# Hand off via the launcher (which handles --working-dir before sourcing
# git-gui.tcl). The launcher's lib-path computation uses $argv0 above.
source $::__gitGuiLauncher