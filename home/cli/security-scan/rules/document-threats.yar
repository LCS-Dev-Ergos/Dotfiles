/*
 * Document threats: patterns for the realistic attack surface of PDFs,
 * EPUBs, Office files and other documents. security-scan compiles this file
 * by default; --yara-rules replaces it.
 *
 * Each rule's meta drives the report: `severity` is info, warning or
 * critical, and `description` is the sentence shown for a match. YARA reads
 * raw bytes, so text inside compressed streams (most PDF JavaScript, Office
 * macros) is invisible here; the structural layer covers those containers.
 *
 * The external `software` is true for software packages and disk images
 * (APK, ISO, DMG, ZIP and the like), which carry programs by design.
 *
 * This is a focused starting point, not a maintained ruleset such as the
 * community Yara-Rules project.
 */

rule Embedded_PE_Executable
{
    meta:
        description = "Carries a Windows program inside"
        severity = "critical"

    strings:
        // A DOS header followed by its stub message: chance cannot produce
        // this, while a bare "MZ" turns up in any compressed data.
        $pe = { 4D 5A [60-200] 54 68 69 73 20 70 72 6F 67 72 61 6D 20 63 61
                6E 6E 6F 74 20 62 65 20 72 75 6E 20 69 6E 20 44 4F 53 }

    condition:
        // A program that carries others, such as an installer, is fine.
        not software and uint16(0) != 0x5A4D and $pe
}

rule Embedded_ELF_Executable
{
    meta:
        description = "Carries a Linux program inside"
        severity = "critical"

    strings:
        // The magic, then a valid class, byte order and version.
        $elf = { 7F 45 4C 46 (01 | 02) (01 | 02) 01 }

    condition:
        not software and uint32(0) != 0x464C457F and uint16(0) != 0x2123
            and $elf
}

rule PDF_Exploit_JavaScript
{
    meta:
        description = "Uses JavaScript calls known from PDF exploits"
        severity = "critical"

    strings:
        $pdf = "%PDF-"
        $collab = "Collab.collectEmailInfo"
        $printf = "util.printf"
        $media = "Media.newPlayer"
        $annots = "getAnnots"
        $spray = /(%u[0-9a-fA-F]{4}){20,}/

    condition:
        $pdf in (0..1024) and any of ($collab, $printf, $media, $annots, $spray)
}

rule PDF_Risky_JavaScript
{
    meta:
        description = "Uses JavaScript that opens links, extracts attachments or decodes hidden code"
        severity = "warning"

    strings:
        $pdf = "%PDF-"
        $launch = "app.launchURL"
        $export = "exportDataObject"
        $unescape = "unescape("
        $eval = "eval("

    condition:
        $pdf in (0..1024) and any of ($launch, $export, $unescape, $eval)
}

rule Office_AutoExec_Macro
{
    meta:
        description = "Has a macro that runs on open and starts programs"
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
        // Office 97-2003 files keep enough of their macro source readable;
        // in any other file these words are ordinary code or prose.
        uint32be(0) == 0xD0CF11E0 and any of ($auto*) and any of ($shell*)
}

rule EICAR_Test_String
{
    meta:
        description = "Holds the EICAR antivirus test string, which is harmless"
        severity = "warning"

    strings:
        $eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

    condition:
        $eicar
}
