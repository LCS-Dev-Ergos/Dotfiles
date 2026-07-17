/*
 * ============================================================================
 * Document Threats - Starter YARA Ruleset
 * ============================================================================
 * Focused on the realistic attack surface for PDFs, EPUBs, and other
 * document/ebook files: embedded executables, known malicious-PDF JavaScript
 * API calls, auto-executing Office macros bundled inside a container, and a
 * sanity-check rule (EICAR) to confirm the scanning pipeline actually works.
 *
 * This is a starting point, not a replacement for a maintained ruleset like
 * the community "Yara-Rules" project. Extend it as you encounter new cases.
 *
 * Author: Claude (Anthropic)
 * Version: 1.0.0
 * ============================================================================
 */

rule Embedded_PE_Executable
{
    meta:
        description = "A Windows PE executable is embedded inside a non-executable file"
        severity = "critical"

    strings:
        $mz = { 4D 5A }
        $pe_marker = "This program cannot be run in DOS mode"

    condition:
        $mz at 0 or (any of ($mz) and $pe_marker)
}

rule Embedded_ELF_Executable
{
    meta:
        description = "An ELF (Linux) executable is embedded inside a non-executable file"
        severity = "critical"

    strings:
        $elf = { 7F 45 4C 46 }

    condition:
        $elf
}

rule PDF_Suspicious_JS_API
{
    meta:
        description = "PDF JavaScript calls commonly seen in known PDF exploits"
        severity = "critical"

    strings:
        $collab_exploit = "Collab.collectEmailInfo"
        $util_printf    = "util.printf"
        $launch_url     = "app.launchURL"
        $export_data    = "this.exportDataObject"
        $media_player    = "Media.newPlayer"
        $unescape        = "unescape("
        $heap_spray_hex  = /(%u[0-9a-fA-F]{4}){20,}/

    condition:
        any of them
}

rule Office_AutoExec_Macro
{
    meta:
        description = "Auto-executing VBA macro combined with shell/process execution"
        severity = "critical"

    strings:
        $auto1 = "AutoOpen" nocase
        $auto2 = "AutoExec" nocase
        $auto3 = "Document_Open" nocase
        $auto4 = "Workbook_Open" nocase
        $shell1 = "Shell(" nocase
        $shell2 = "CreateObject(" nocase
        $shell3 = "WScript.Shell" nocase

    condition:
        any of ($auto*) and any of ($shell*)
}

rule EICAR_Test_String
{
    meta:
        description = "Standard EICAR antivirus test string (not real malware, used to verify scanning works)"
        severity = "warning"

    strings:
        $eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

    condition:
        $eicar
}

/*
 * End of ruleset.
 */
